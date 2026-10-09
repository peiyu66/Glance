import SwiftUI
import Observation
@preconcurrency import AVFoundation
@preconcurrency import Vision

@MainActor @Observable final class CameraController {
    let capture = CameraCapture()
    let account = SIWCController()
    var running = false
    var permissionDenied = false
    var visible: RecognitionResult?
    var diagnostic = "尚未辨識"
    var requestCount = 0
    var lastLatency: Double?
    var firstResultLatency: Double?
    var cacheLatency: Double?
    private var completedTargets = Set<String>()
    private var acquisitionTimes: [String: Double] = [:]
    private var fixtureTime: Double?
    private var fixtureProvider: ((Data) async throws -> RecognitionResult)?
    private var fixtureWaiter: CheckedContinuation<RecognitionResult, Error>?
    private func timeNow() -> Double { fixtureTime ?? ProcessInfo.processInfo.systemUptime }
    private var returningCachedTarget = false
    var showingSettings = false
    private var captureStats = CaptureStatistics()
    private var lastFingerprint: SceneFingerprint?
    private var targetChanges = 0
    private var newTargets = 0
    private var knownTargets = Set<String>()
    private var completedCount = 0
    private var emptyCount = 0
    private var displayCount = 0
    private var motionRejected = 0
    private var matchedAtCompletion = false
    private var resultFieldCounts: [String: Int] = [:]
    private var lastFeatureDistance: Float?
    private var lastMotionDistance: Float?
    private var lastDiagnosticAt = 0.0
    private var pipelineStage = "idle"
    private var memory = TargetMemory()
    private var state = RecognitionState()
    private var features: [String: VNFeaturePrintObservation] = [:]
    private var generation = UUID()
    private var work: Task<Void, Never>?
    private var inflight = false
    private var inflightTarget: String?
    private var blocked = false
    private var nextRequestAt = 0.0
    private var wantsRunning = false
    private var currentTarget: String?
    private var targetSeenAt = 0.0
    private var lastFrameAt = 0.0
    private var watchdog: Task<Void, Never>?
    init() {
        account.load()
        capture.onFrame = { [weak self] frame, generation, stats in
            Task { @MainActor in self?.frame(frame, generation: generation, stats: stats) }
        }
        capture.onFailure = { [weak self] code in Task { @MainActor in self?.diagnostic = code } }
    }
    func start() async {
        guard account.authenticated, account.planEnabled, account.planOnlyConfirmed else { showingSettings = true; return }
        let authorization = AVCaptureDevice.authorizationStatus(for: .video)
        var granted = authorization == .authorized
        if authorization == .notDetermined { granted = await AVCaptureDevice.requestAccess(for: .video) }
        guard granted else { permissionDenied = true; saveDiagnostic(phase: "camera-permission-denied"); return }
        permissionDenied = false; blocked = false; wantsRunning = true; resume()
    }
    private func resume() {
        guard wantsRunning, !showingSettings, !running else { return }
        generation = UUID(); running = true; lastFingerprint = nil; capture.start(generation: generation)
        lastFrameAt = timeNow()
        saveDiagnostic(phase: "camera-starting")
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                if self.timeNow() - self.lastFrameAt > 0.75 {
                    _ = self.state.observe(nil, at: self.timeNow(), allowRequest: false); self.visible = nil
                    let now = self.timeNow()
                    if now - self.lastDiagnosticAt >= 1 { self.saveDiagnostic(phase: "no-recent-camera-frames"); self.lastDiagnosticAt = now }
                }
            }
        }
    }
    func stop(userInitiated: Bool = false) {
        if userInitiated { wantsRunning = false }
        generation = UUID(); running = false; capture.stop(); work?.cancel(); work = nil
        watchdog?.cancel(); watchdog = nil
        state.leaveForeground(); memory.clear(); features = [:]; visible = nil; currentTarget = nil; completedTargets = []; acquisitionTimes = [:]; knownTargets = []; lastFingerprint = nil
        saveDiagnostic(phase: "paused")
        // Keep inflight true until the cancelled provider returns; never overlap old and new calls.
    }
    func foreground(_ active: Bool) { if active { resume() } else { stop() } }
    func settingsChanged(_ shown: Bool) { if shown { stop() } else { account.load(); resume() } }
    private func frame(_ frame: CameraFrame?, generation: UUID, stats: CaptureStatistics) {
        guard running, self.generation == generation else { return }
        let now = timeNow(); lastFrameAt = now
        captureStats = stats
        guard frame == nil || fixtureTime != nil || now - (frame?.time ?? now) <= 0.75 else {
            _ = state.observe(nil, at: now, allowRequest: false); visible = nil; currentTarget = nil; lastFingerprint = nil
            pipelineStage = "stale-local-frame"; return
        }
        defer {
            if now - lastDiagnosticAt >= 1 { saveDiagnostic(phase: pipelineStage); lastDiagnosticAt = now }
        }
        guard let frame else {
            _ = state.observe(nil, at: now, allowRequest: false); visible = nil; currentTarget = nil; lastFingerprint = nil
            pipelineStage = "local-quality-or-saliency-rejected"; return
        }
        let motion = lastFingerprint.map { frame.fingerprint.distance(to: $0, allowRotation: false, allowTranslation: false) }
        lastFingerprint = frame.fingerprint; lastMotionDistance = motion
        if let motion, motion > 0.035 {
            motionRejected += 1; _ = state.observe(nil, at: now, allowRequest: false); visible = nil; currentTarget = nil
            pipelineStage = "roi-motion"; return
        }
        guard frame.feature != nil || fixtureProvider != nil else {
            _ = state.observe(nil, at: now, allowRequest: false); visible = nil; currentTarget = nil
            pipelineStage = "feature-unavailable"; return
        }
        lastFeatureDistance = nil
        let target = memory.resolve(frame.fingerprint, at: now, protectedID: inflightTarget, labelSignature: frame.labelSignature) { id in
            if frame.feature == nil && fixtureProvider != nil { return true } // explicit offline fixture only
            guard let previous = features[id], let currentFeature = frame.feature else { return false }
            var distance: Float = .infinity
            do { try currentFeature.computeDistance(&distance, to: previous); lastFeatureDistance = min(lastFeatureDistance ?? .infinity, distance); return distance < 0.12 } catch { return false }
        }
        if let target, !knownTargets.contains(target) { features[target] = frame.feature; knownTargets.insert(target); newTargets += 1 }
        let valid = Set(memory.entries.map(\.id)); features = features.filter { valid.contains($0.key) }
        knownTargets = knownTargets.intersection(valid)
        completedTargets = completedTargets.intersection(valid); acquisitionTimes = acquisitionTimes.filter { valid.contains($0.key) }
        if target != currentTarget { targetChanges += 1; currentTarget = target; targetSeenAt = now; returningCachedTarget = target.map { completedTargets.contains($0) } ?? false }
        let policy = RequestAdmission(trialLimit: ProcessInfo.processInfo.arguments.contains("--camera-trial-once") ? 1 : nil)
        let trialAvailable = policy.trialLimit.map { requestCount < $0 } ?? true
        let request = state.observe(target, at: now, allowRequest: policy.allows(sent: requestCount, inflight: inflight, blocked: blocked, now: now, nextAllowed: nextRequestAt))
        pipelineStage = target == nil ? "ambiguous-match" : inflight ? "inflight" : blocked ? "provider-blocked" : !trialAvailable ? "trial-request-limit" : "stability-or-dedup"
        let wasVisible = visible != nil; visible = state.visible
        if !wasVisible, visible != nil {
            displayCount += 1; pipelineStage = "result-visible"
            if returningCachedTarget { cacheLatency = now - targetSeenAt }
            else { firstResultLatency = now - (target.flatMap { acquisitionTimes[$0] } ?? targetSeenAt) }
            saveDiagnostic(phase: returningCachedTarget ? "cache-visible" : "first-result-visible")
        }
        guard let request, let jpeg = UIImage(cgImage: frame.image).jpegData(compressionQuality: 0.82) else { return }
        acquisitionTimes[request.target] = targetSeenAt
        inflight = true; inflightTarget = request.target; nextRequestAt = now + 4; requestCount += 1
        pipelineStage = "request-started"; saveDiagnostic(phase: pipelineStage)
        let epoch = self.generation
        work = Task { [weak self] in
            guard let self else { return }
            defer { self.inflight = false; self.inflightTarget = nil }
            do {
                let answer: RecognitionResult
                if let provider = self.fixtureProvider { answer = try await provider(jpeg) }
                else { answer = try await self.account.recognize(jpeg: jpeg) }
                guard !Task.isCancelled, self.generation == epoch, self.running else { return }
                self.completedCount += 1
                if answer.lines.isEmpty { self.emptyCount += 1 }
                self.resultFieldCounts = ["names": answer.names.count, "text": answer.text.count, "barcodes": answer.barcodes.count]
                self.matchedAtCompletion = self.currentTarget == request.target
                self.state.complete(request, result: answer)
                if !answer.lines.isEmpty { self.completedTargets.insert(request.target) }
                self.lastLatency = self.timeNow() - now
                self.diagnostic = "辨識完成 · \(String(format: "%.2f", self.lastLatency ?? 0)) 秒"
                self.pipelineStage = "completed"
                self.saveDiagnostic(phase: "completed")
            } catch {
                guard self.generation == epoch, !Task.isCancelled else { return }
                self.state.complete(request, result: nil)
                self.nextRequestAt = self.timeNow() + 30
                let detail = SIWCHTTP.shared.diagnostics
                let code = detail["errorCode"] as? String ?? detail["errorCategory"] as? String ?? "local-validation"
                self.diagnostic = "已停止 · \(code)"
                if let http = error as? SIWCHTTPError, [400,401,403,429].contains(http.status) { self.blocked = true }
                if let terminal = error as? SIWCStreamFailure, terminal.code?.hasPrefix("subscription_sharing_") == true { self.blocked = true }
                if error as? SIWCError == .planDisabled || error as? SIWCError == .modelUnavailable || error as? SIWCError == .invalidIdentity { self.blocked = true }
                if !(error is URLError) { self.blocked = true }
                self.pipelineStage = "stopped"
                self.saveDiagnostic(phase: "stopped")
            }
        }
    }
    func runSyntheticFixture() async {
        guard ProcessInfo.processInfo.arguments.contains("--camera-fixture") else { return }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 768, height: 768))
        let image = renderer.image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 768, height: 768))
            UIColor.red.setFill(); context.fill(CGRect(x: 180, y: 100, width: 300, height: 300))
            ("GLANCE 123" as NSString).draw(at: CGPoint(x: 100, y: 500), withAttributes: [.font: UIFont.systemFont(ofSize: 64), .foregroundColor: UIColor.black])
        }
        var report: [String: Any] = ["fixture": "generated-red-square", "restoredSession": account.authenticated]
        do {
            guard let jpeg = image.jpegData(compressionQuality: 0.85) else { throw SIWCError.invalidResponse }
            let start = ProcessInfo.processInfo.systemUptime
            let result = try await account.recognize(jpeg: jpeg)
            visible = result; report["phase"] = "completed"
            report["names"] = result.names; report["text"] = result.text; report["barcodes"] = result.barcodes
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - start
        } catch { report["phase"] = "stopped" }
        report["request"] = SIWCHTTP.shared.diagnostics
        report["successfulRefreshCount"] = account.refreshCount
        if let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("camera-fixture.json"), options: .atomic)
        }
    }
    func runLocalMatcherFixture() async {
        guard ProcessInfo.processInfo.arguments.contains("--camera-local-fixture") else { return }
        var memory = TargetMemory(); var prints: [String: VNFeaturePrintObservation] = [:]
        var visionAvailable = true
        var cases: [[String: Any]] = []; var firstID: String?; var generatedFrames: [CameraFrame] = []
        for (index, dx) in [0.0, 10.0, -10.0, 0.0, 0.0, 0.0].enumerated() {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512))
            let image = renderer.image { ctx in
                UIColor(white: 0.93, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
                (index == 4 ? UIColor.systemRed : UIColor.systemBlue).setFill(); ctx.fill(CGRect(x: 130+dx, y: 60, width: 250, height: 390))
                UIColor.white.setFill(); ctx.fill(CGRect(x: 150+dx, y: 180, width: 210, height: 150))
                ((index == 5 ? "GLANCE 128" : "GLANCE 123") as NSString).draw(at: CGPoint(x: 157+dx, y: 225), withAttributes: [.font: UIFont.systemFont(ofSize: 28), .foregroundColor: UIColor.black])
            }
            do {
                guard let cg = image.cgImage, let fp = CameraCapture.fingerprint(cg), let fine = CameraCapture.fingerprint(cg, side: 128) else { throw SIWCError.invalidResponse }
                let request = VNGenerateImageFeaturePrintRequest()
                var observation: VNFeaturePrintObservation?
                var visionError: [String: Any] = [:]
                do {
                    try VNImageRequestHandler(cgImage: cg, orientation: .up).perform([request])
                    observation = request.results?.first as? VNFeaturePrintObservation
                } catch {
                    let ns = error as NSError; visionError = ["domain": ns.domain, "code": ns.code]
                }
                if observation == nil { visionAvailable = false }
                let label = try CameraCapture.labelSignature(cg)
                let textProbe = VNRecognizeTextRequest()
                textProbe.recognitionLevel = .accurate; textProbe.usesLanguageCorrection = false
                textProbe.recognitionLanguages = ["zh-Hant", "en-US"]
                try VNImageRequestHandler(cgImage: cg, orientation: .up).perform([textProbe])
                let textCandidates = (textProbe.results ?? []).compactMap { $0.topCandidates(1).first }
                generatedFrames.append(CameraFrame(image: cg, fingerprint: fp, feature: observation, labelSignature: label, time: 0))
                var featureDistance: Float = 0
                let id = memory.resolve(fp, at: Double(index), labelSignature: label) { key in
                    guard let observation else { return true } // fingerprint-only fixture is labelled below
                    guard let prior = prints[key] else { return false }
                    do { try observation.computeDistance(&featureDistance, to: prior); return featureDistance < 0.12 } catch { return false }
                }
                if let id, prints[id] == nil { prints[id] = observation }
                if index == 0 { firstID = id }
                cases.append(["identityMatchesExpected": id != nil && ((id == firstID) == (index < 4)), "expectedSameTarget": index < 4, "textCandidateCount": textCandidates.count, "textMaxConfidence": textCandidates.map(\.confidence).max() ?? 0, "labelEvidencePresent": !label.isEmpty, "visionError": visionError, "case": index, "sameTarget": id == firstID && id != nil, "clear": SceneQuality(fine).usable, "featureDistance": featureDistance, "fingerprintDistance": memory.bestDistance ?? 0])
            } catch { cases.append(["case": index, "error": "local-fixture-validation"]) }
        }
        var checks: [String: Bool] = [:]
        var simulatedTiming: [String: Double] = [:]
        if generatedFrames.count == 6 {
            // Exercise the actual controller with generated frames and a deterministic
            // provider continuation. No capture session or network provider is started.
            fixtureTime = 0; running = true; generation = UUID()
            fixtureProvider = { [weak self] _ in
                try await withCheckedThrowingContinuation { continuation in self?.fixtureWaiter = continuation }
            }
            var stats = CaptureStatistics()
            func feed(_ index: Int?, _ time: Double) async {
                fixtureTime = time; stats.frames += 1; stats.samples += 1
                if index != nil { stats.accepted += 1 }
                frame(index.map { generatedFrames[$0] }, generation: generation, stats: stats)
                for _ in 0..<3 { await Task.yield() }
            }
            func finish(_ result: RecognitionResult, _ time: Double) async -> Bool {
                fixtureTime = time
                for _ in 0..<10 where fixtureWaiter == nil { await Task.yield() }
                guard let continuation = fixtureWaiter else { return false }
                fixtureWaiter = nil; continuation.resume(returning: result)
                let completing = work; await completing?.value
                return true
            }
            for t in [0.0,0.25,0.5,0.75,1.0] { await feed(0,t) }
            checks["oneRequestAfterStable"] = requestCount == 1 && inflight
            await feed(nil,1.25)
            for t in [1.5,1.75,2.0,2.25,2.5] { await feed(1,t) }
            checks["oneInflightDuringFocusGap"] = requestCount == 1
            checks["firstCompletionDelivered"] = await finish(RecognitionResult(names: ["fixture-A"]),3.5)
            await feed(1,3.75)
            checks["firstResultVisible"] = visible?.names == ["fixture-A"]
            simulatedTiming["firstResultSeconds"] = firstResultLatency
            await feed(nil,4)
            checks["hiddenOnRemoval"] = visible == nil
            for t in [4.25,4.5,4.75,5.0,5.25] { await feed(4,t) }
            checks["newObjectRequestsOnce"] = requestCount == 2 && visible == nil
            await feed(nil,5.5)
            for t in [5.75,6.0,6.25,6.5,6.75] { await feed(0,t) }
            checks["returnUsesCacheWithoutRequest"] = visible?.names == ["fixture-A"] && requestCount == 2
            simulatedTiming["cacheReturnSeconds"] = cacheLatency
            checks["secondCompletionDelivered"] = await finish(RecognitionResult(names: ["fixture-B"]),7)
            await feed(0,7.25)
            checks["lateBNeverOverwritesA"] = visible?.names == ["fixture-A"]
            stop(userInitiated: true)
            checks["pauseClearsResultsAndMemory"] = visible == nil && self.memory.entries.isEmpty && !running
            fixtureTime = 8; running = true; generation = UUID()
            for t in [8.0,8.25,8.5,8.75,9.0,9.25] { await feed(0,t) }
            let cancelledWork = work
            stop(userInitiated: true)
            if let continuation = fixtureWaiter { fixtureWaiter = nil; continuation.resume(returning: RecognitionResult(names: ["too-late"])) }
            await cancelledWork?.value
            checks["cancelledResultNeverRevives"] = visible == nil && !running && !inflight
            checks["productionAllowsMultipleTargets"] = requestCount == 3
            fixtureProvider = nil; fixtureTime = nil
        }
        if let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: ["fixture": "generated-card-motion", "networkRequests": 0, "visionAvailable": visionAvailable, "matcherPassed": cases.count == 6 && cases.allSatisfy { ($0["identityMatchesExpected"] as? Bool) == true }, "readyForCameraTrial": visionAvailable && cases.count == 6 && cases.allSatisfy { ($0["identityMatchesExpected"] as? Bool) == true && ($0["labelEvidencePresent"] as? Bool) == true } && checks.count == 12 && checks.values.allSatisfy { $0 }, "cases": cases, "controllerChecks": checks, "simulatedTiming": simulatedTiming], options: [.sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("camera-local-fixture.json"), options: .atomic)
        }
    }
    private func saveDiagnostic(phase: String) {
        // Only timing/status categories. Never store recognition text, target IDs or photos.
        var value: [String: Any] = ["source": fixtureTime == nil ? "camera" : "local-fixture", "phase": phase, "requestCount": requestCount,
            "request": SIWCHTTP.shared.diagnostics, "recordedAt": ISO8601DateFormatter().string(from: Date())]
        value["cameraAuthorization"] = AVCaptureDevice.authorizationStatus(for: .video).rawValue
        value["cameraRunning"] = running
        value["frames"] = captureStats.frames; value["samples"] = captureStats.samples
        value["localProcessingMS"] = captureStats.localProcessingMS
        value["qualityContrast"] = captureStats.contrast; value["qualityEdgeScore"] = captureStats.edgeScore
        value["qualityRejected"] = captureStats.qualityRejected; value["saliencyRejected"] = captureStats.saliencyRejected
        value["visionRejected"] = captureStats.visionRejected; value["eligibleSamples"] = captureStats.accepted
        value["motionRejected"] = motionRejected; value["targetChanges"] = targetChanges; value["newTargets"] = newTargets
        value["completedCount"] = completedCount; value["emptyResultCount"] = emptyCount; value["displayCount"] = displayCount
        value["inflight"] = inflight; value["providerBlocked"] = blocked; value["matchedAtLastCompletion"] = matchedAtCompletion
        value["lastResultFieldCounts"] = resultFieldCounts; value["resultVisible"] = visible != nil
        value["featureDistance"] = lastFeatureDistance; value["fingerprintDistance"] = memory.bestDistance
        value["frameMotionDistance"] = lastMotionDistance
        value["firstResultSeconds"] = firstResultLatency
        value["cacheReturnSeconds"] = cacheLatency
        if let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("camera-diagnostic.json"), options: .atomic)
        }
    }
}

struct CameraView: View {
    @State private var model = CameraController()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 12) {
                    ZStack {
                        CameraPreview(session: model.capture.session)
                        if !model.running { Color.black; Image(systemName: "viewfinder").font(.system(size: 48)).foregroundStyle(.white.opacity(0.5)) }
                        Rectangle().stroke(.white.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, dash: [12, 6]))
                            .frame(width: geometry.size.width * 0.78, height: geometry.size.width * 0.78)
                    }.frame(width: geometry.size.width, height: geometry.size.width).clipped()
                    if !model.running {
                        Text("對準安全可拍的物品，中央穩定約一秒後送出單張辨識。影像經 ChatGPT 方案處理，不儲存照片。").font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                        Button(model.permissionDenied ? "在系統設定允許相機" : "開始取景") {
                            if model.permissionDenied { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                            else { Task { await model.start() } }
                        }.buttonStyle(.borderedProminent)
                    }
                    Spacer(minLength: 0)
                    if let result = model.visible {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(result.lines.enumerated()), id: \.offset) { _, line in Text(line).textSelection(.enabled) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding()
                        }.frame(maxHeight: 190).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16)).padding(.horizontal)
                            .accessibilityIdentifier("recognitionResult")
                    }
                }.padding(.bottom)
            }.navigationTitle("Glance").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { if model.running { Button("暫停") { model.stop(userInitiated: true) } } }
                    ToolbarItem(placement: .topBarTrailing) { Button { model.showingSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("設定與診斷") }
                }
                .sheet(isPresented: $model.showingSettings) {
                    NavigationStack {
                        Form {
                            Section("ChatGPT") {
                                Label(model.account.authenticated ? "已登入，使用保存的會話" : "尚未登入", systemImage: "person.crop.circle")
                                Text("辨識固定使用 gpt-6-luna · none。方案不足即停止，不切換其他模型或API。官方額外點數設定不會由此App更改。").font(.footnote)
                                NavigationLink("帳戶與權限") { SIWCView() }
                            }
                            Section("本次診斷") {
                                Text(model.diagnostic).textSelection(.enabled)
                                Text("已送出 \(model.requestCount) 張")
                                if let latency = model.firstResultLatency { Text("目標進入到首次顯示：\(String(format: "%.2f", latency)) 秒") }
                                if let latency = model.lastLatency { Text("上次請求到完成：\(String(format: "%.2f", latency)) 秒") }
                                if let latency = model.cacheLatency { Text("回看穩定到顯示：\(String(format: "%.2f", latency)) 秒") }
                                Text("辨識中的等待、失敗或查無不在取景畫面顯示。暫停／背景會清除暫存。門檻仍待實機校準。").font(.footnote)
                            }
                        }.navigationTitle("設定").toolbar { Button("完成") { model.showingSettings = false } }
                    }
                }.onChange(of: model.showingSettings) { _, shown in model.settingsChanged(shown) }
                .onChange(of: scenePhase) { _, phase in model.foreground(phase == .active) }
                .task {
                    if ProcessInfo.processInfo.arguments.contains("--camera-local-fixture") { await model.runLocalMatcherFixture() }
                    else if ProcessInfo.processInfo.arguments.contains("--camera-fixture") { await model.runSyntheticFixture() }
                }
        }
    }
}

import SwiftUI
import UniformTypeIdentifiers
import Observation
@preconcurrency import AVFoundation
@preconcurrency import Vision

// Diagnostic-only serial wrapper around Apple's stateful tracker. No appearance gate.
private final class VisionBaselineImage: @unchecked Sendable {
    let image:CGImage
    init(_ image:CGImage) { self.image=image }
}
private struct VisionBaselineSample: Sendable {
    var box:CGRect?;var confidence:Float?;var visionMS:Double=0;var revision:Int=0
    var terminal=false;var reason="tracked";var processed=false
}
private final class VisionBaselineSession: @unchecked Sendable {
    private let queue=DispatchQueue(label:"Glance.vision-baseline",qos:.userInitiated)
    private let sequence=VNSequenceRequestHandler()
    private var observation:VNDetectedObjectObservation
    private var terminal=false
    init(seed:CGRect) { observation=VNDetectedObjectObservation(boundingBox:seed) }
    func process(_ frame:VisionBaselineImage) async -> VisionBaselineSample {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                var sample=VisionBaselineSample()
                guard !terminal else { sample.terminal=true;sample.reason="previously-lost-no-reseed";continuation.resume(returning:sample);return }
                let request=VNTrackObjectRequest(detectedObjectObservation:observation)
                request.trackingLevel = .accurate
                sample.revision=request.revision;sample.processed=true
                let begin=ProcessInfo.processInfo.systemUptime
                do {
                    try sequence.perform([request],on:frame.image,orientation:.up)
                    sample.visionMS=(ProcessInfo.processInfo.systemUptime-begin)*1000
                    if let result=request.results?.first as? VNDetectedObjectObservation {
                        sample.box=result.boundingBox;sample.confidence=result.confidence
                        let b=result.boundingBox
                        if result.confidence<=0 || b.isEmpty || b.intersection(CGRect(x:0,y:0,width:1,height:1)).isEmpty {
                            terminal=true;sample.reason="zero-confidence-or-outside"
                        } else { observation=result }
                    } else { terminal=true;sample.reason="no-observation" }
                } catch { terminal=true;sample.reason="vision-error";sample.visionMS=(ProcessInfo.processInfo.systemUptime-begin)*1000 }
                sample.terminal=terminal;continuation.resume(returning:sample)
            }
        }
    }
}

@MainActor @Observable final class CameraController {
    /// Generated pixels, scripted scene fingerprints and real foreground ORB worker.
    /// This does not claim Apple segmentation quality or start AVCaptureSession.
    func runORBFixture() async {
        guard ProcessInfo.processInfo.arguments.contains("--camera-orb-fixture") else { return }
        var checks: [String: Bool] = [:], timings: [Double] = []
        var errorCategory: String?
        let width = 512
        func bitmap(_ foreground: UInt64, _ background: UInt64) -> UIImage {
            var fg = foreground, bg = background, bytes = [UInt8](repeating: 0, count: width * width * 3)
            for y in 0..<width { for x in 0..<width { for c in 0..<3 {
                let center = (128..<384).contains(x) && (128..<384).contains(y)
                if center { fg = fg &* 6364136223846793005 &+ 1442695040888963407 }
                else { bg = bg &* 6364136223846793005 &+ 1442695040888963407 }
                bytes[(y * width + x) * 3 + c] = UInt8(truncatingIfNeeded: (center ? fg : bg) >> 32)
            } } }
            let provider = CGDataProvider(data: Data(bytes) as CFData)!
            return UIImage(cgImage: CGImage(width: width, height: width, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!)
        }
        let images = ["A": bitmap(13,25), "A2": bitmap(13,77), "B": bitmap(89,25), "C": bitmap(171,25)]
        var mask = [UInt8](repeating: 0, count: width * width)
        for y in 128..<384 { for x in 128..<384 { mask[y * width + x] = 255 } }
        let maskData = Data(mask)
        func reset() async {
            let old = work; stop(userInitiated: true)
            fixtureWaiter?.resume(throwing: CancellationError()); fixtureWaiter = nil
            await old?.value
            liveSession = LiveRecognitionSession(); syncFixedReferences(); capture.resetLiveRegistration()
            liveEvents = []; liveRequestLifecycles = []; liveEpisodeReasonCounts = [:]; liveFrameCount = 0
            fixtureUsesWallClock = false; fixtureTime = 0; blocked = false; inflight = false
            generation = UUID(); running = true; beginCaptureRun()
            fixtureProvider = { [weak self] _ in
                guard let self else { throw CancellationError() }
                return try await withCheckedThrowingContinuation { self.fixtureWaiter = $0 }
            }
        }
        func feed(_ key: String, _ time: Double) throws {
            fixtureTime = time
            let image = images[key]!, offset = key == "B" ? 3 : key == "C" ? 6 : 0
            let fp = SceneFingerprint(rgb: (0..<192).map { (($0 / 3 + offset) % 11) < 5 ? 0.15 : 0.85 }, side: 8)
            let identity = try capture.syntheticIdentity(image.pngData()!, mask: maskData, time: time)
            timings.append(identity.milliseconds)
            frame(CameraFrame(image: image.cgImage!, fingerprint: fp, feature: nil, time: time, identity: identity), generation: generation, stats: CaptureStatistics())
        }
        func stable(_ key: String, _ start: Double) throws {
            for t in stride(from: start, through: start + 1, by: 0.25) { try feed(key, t) }
        }
        func waitForProvider() async {
            for _ in 0..<30 { if fixtureWaiter != nil { return }; await Task.yield() }
        }
        func finish(_ name: String?, _ time: Double) async {
            await waitForProvider(); fixtureTime = time
            if let name { fixtureWaiter?.resume(returning: RecognitionResult(names: [name], summary: "台灣繁中合成解說：" + name)) }
            else { fixtureWaiter?.resume(throwing: SIWCError.invalidResponse) }
            fixtureWaiter = nil; await work?.value
        }
        do {
            await reset(); try stable("A", 0); await finish("A", 1.1)
            let aID = liveSession.history.latest?.id
            try stable("B", 3); await finish("B", 4.1); try feed("A2", 6)
            checks["ABA_reuses_A_from_original_snapshot"] = visible?.names == ["A"] && !showingPreviousResult && liveSession.sentCount == 2 && liveSession.history.entries.count == 2 && liveSession.visibleRequestID == aID
            fixtureTime = 6.25; frame(nil, generation: generation, stats: CaptureStatistics())
            checks["movement_preserves_paid_card"] = visible?.names == ["A"] && showingPreviousResult
            try stable("C", 8); await finish("C", 9.1); try feed("A2", 11)
            checks["at_budget_three_cache_still_reuses"] = liveSession.sentCount == 3 && visible?.names == ["A"] && !showingPreviousResult
            memoryWarning()
            checks["memory_keeps_history_budget_releases_features"] = liveSession.history.entries.count == 3 && liveSession.sentCount == 3 && visible?.names == ["A"] && showingPreviousResult && fixedReferenceFeatures.isEmpty
            try feed("A", 12)
            checks["worker_memory_clear_applied"] = liveLastFrame["referenceMatchCount"] as? Int == 0

            await reset(); try stable("A", 0); await waitForProvider()
            let pending = liveSession.inflightRequest, originalFeatures = pending.flatMap { fixedReferenceFeatures[$0.intent.id] }
            try stable("B", 3); checks["B_waits_behind_A"] = liveSession.queuedIntent != nil && liveSession.sentCount == 1
            try stable("A2", 5)
            checks["pending_A_return_deduplicated"] = liveSession.queuedIntent == nil && liveSession.sentCount == 1 && visible == nil
            await finish("A", 6.1); try feed("A2", 6.25); try feed("A2", 8)
            checks["AAA_one_send_reference_never_updated"] = liveSession.sentCount == 1 && visible?.names == ["A"] && !showingPreviousResult && pending.flatMap { fixedReferenceFeatures[$0.intent.id] } === originalFeatures
            checks["late_reply_bound_to_capture_not_return"] = liveSession.references.entries.first?.capturedAt == 1 && liveSession.history.latest?.capturedAt == 1
            fixtureTime = 91; liveSession.expire(at: 91); syncLiveVisible(at: 91)
            checks["TTL_keeps_answer_and_history"] = visible?.names == ["A"] && liveSession.history.entries.count == 1 && fixedReferenceFeatures.isEmpty && showingPreviousResult

            await reset(); try stable("A", 0); await waitForProvider(); try stable("B", 3); try stable("C", 6)
            await finish("A", 7.1); try feed("C", 7.25)
            checks["latest_intent_uses_latest_C_snapshot"] = liveSession.inflightRequest?.snapshotCapturedAt == 7.25 && liveSession.sentCount == 2
            await finish("C", 7.4); try feed("C", 7.5)
            checks["late_A_history_and_C_result_both_saved"] = liveSession.history.entries.map { $0.result.names.first ?? "" } == ["A","C"] && visible?.names == ["C"]

            await reset(); try stable("A", 0); await finish("A", 1.1); try stable("B", 3); await finish(nil, 4.1)
            checks["failed_B_keeps_A_no_pending_reference"] = visible?.names == ["A"] && showingPreviousResult && liveSession.references.entries.count == 1 && liveSession.sentCount == 2
            try stable("C", 6); await waitForProvider()
            let old = work; stop(userInitiated: true)
            checks["pause_zero_text_kept_transport_held"] = liveSession.sentCount == 0 && liveSession.history.entries.count == 1 && fixedReferenceFeatures.isEmpty && inflight && liveSession.inflightRequest != nil
            fixtureWaiter?.resume(returning: RecognitionResult(names: ["OLD C"])); fixtureWaiter = nil; await old?.value
            checks["cancelled_late_reply_never_revives"] = !inflight && liveSession.history.entries.count == 1 && liveSession.references.entries.isEmpty
            running = true; try stable("B", 9); await finish("B", 10.1)
            checks["restart_new_batch_global_sequence_history"] = liveSession.sentCount == 1 && liveSession.lifetimeSentCount == 4 && liveSession.history.entries.map(\.sequence) == [1,4]
            settingsChanged(true)
            checks["settings_clears_text_refs_keeps_budget"] = visible == nil && liveSession.references.entries.isEmpty && fixedReferenceFeatures.isEmpty && liveSession.sentCount == 1 && !running
            checks["camera_session_never_started"] = !capture.session.isRunning

            let blank = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512)).image { ctx in UIColor.black.setFill(); ctx.fill(CGRect(x:0,y:0,width:512,height:512)) }
            let probe = capture.fixtureMaskProbe(blank.cgImage!, time: 101)
            checks["Apple_blank_mask_no_whole_image_fallback"] = probe.features == nil && probe.matches.isEmpty && probe.milliseconds.isFinite && probe.milliseconds > 0
            timings.append(probe.milliseconds)
        } catch { errorCategory = String(describing: type(of: error)) }
        let pending = work; stop(userInitiated: true)
        fixtureWaiter?.resume(throwing: CancellationError()); fixtureWaiter = nil; await pending?.value
        fixtureProvider = nil; fixtureTime = nil; fixtureUsesWallClock = false
        let report: [String: Any] = ["fixture":"fixed-foreground-controller-worker", "revision":1, "complete":errorCategory == nil, "passed":errorCategory == nil && checks.count >= 18 && checks.values.allSatisfy { $0 }, "checks":checks, "errorCategory":errorCategory ?? "none", "cameraStarted":false, "networkRequests":0, "processID":ProcessInfo.processInfo.processIdentifier, "nativeProcessingMS":timings, "scope":"Generated textures and known synthetic masks through real OpenCV/serial worker/controller. Scene fingerprints scripted. Apple blank-mask failure path measured separately. No real camera or AI; not segmentation accuracy." ]
        if let root = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first, let data = try? JSONSerialization.data(withJSONObject: report,options:[.sortedKeys]) { try? data.write(to:root.appendingPathComponent("camera-orb-fixture.json"),options:.atomic) }
        saveDiagnostic(phase:"orb-fixture-finished")
    }

    /// Generated movie -> AVAssetReader BGRA -> production central crop/preparation/controller.
    /// No camera session or network is started by this diagnostic entry point.
    private func makeLiveMovie(micro: Bool, earlyReturn: Bool = false, combined: Bool = false, budgetReturn: Bool = false) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glance-generated-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL:url,fileType:.mov)
        let input = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:1080,AVVideoHeightKey:1920])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:1080,kCVPixelBufferHeightKey as String:1920,kCVPixelBufferIOSurfacePropertiesKey as String:[:]])
        writer.add(input)
        guard writer.startWriting() else { throw SIWCError.invalidResponse }
        writer.startSession(atSourceTime:.zero)
        let context=CIContext(options:[.cacheIntermediates:false])
        let format=UIGraphicsImageRendererFormat();format.scale=1
        let returnAt: Double = earlyReturn ? 5 : 11
        for index in 0..<(budgetReturn ? 80 : micro ? (combined ? 48 : 16) : 60) {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw SIWCError.invalidResponse }
                try await Task.sleep(for:.milliseconds(2))
            }
            let t=Double(index)/4
            let changed = !micro && ((t>=3 && t<returnAt+1) || (budgetReturn && t>=16))
            let motionTime=max(0,t-1.5)
            var dx = micro ? (combined ? sin(motionTime*2.2)*8 : sin(Double(index)*0.7)*4) : 0
            if !micro && t>=2 && t<3 { dx = -(t-2+0.25)*950 }
            if !micro && t>=returnAt && t<returnAt+1 { dx = -(t-returnAt+0.25)*950 }
            if budgetReturn && t>=15 && t<16 { dx = -(t-15+0.25)*950 }
            let bitmap=regionalBitmap(scenario:"different-object",index:0,changed:changed,digit:changed ? "456" : "123",dx:dx,scale:1,objectScale:combined ? 1+sin(motionTime*1.3)*0.02 : 1,rotation:combined ? sin(motionTime*2.2)*2 * .pi/180 : 0)
            let full=UIGraphicsImageRenderer(size:CGSize(width:1080,height:1920),format:format).image { ctx in
                UIColor(white:0.92,alpha:1).setFill();ctx.fill(CGRect(x:0,y:0,width:1080,height:1920))
                bitmap.draw(in:CGRect(x:118.8,y:538.8,width:842.4,height:842.4))
            }
            var buffer: CVPixelBuffer?
            guard let pool=adaptor.pixelBufferPool,CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,pool,&buffer)==kCVReturnSuccess,let buffer else { throw SIWCError.invalidResponse }
            context.render(CIImage(cgImage:full.cgImage!),to:buffer)
            guard adaptor.append(buffer,withPresentationTime:CMTime(value:Int64(index),timescale:4)) else { throw SIWCError.invalidResponse }
        }
        input.markAsFinished();await writer.finishWriting()
        guard writer.status == .completed else { throw SIWCError.invalidResponse }
        return url
    }
    func runLiveFixture() async {
        guard ProcessInfo.processInfo.arguments.contains("--camera-live-fixture") else { return }
        let pending=work;stop(userInitiated:true);await pending?.value
        var reports: [[String:Any]]=[]
        var movies: [URL]=[]
        defer { for url in movies { try? FileManager.default.removeItem(at:url) } }
        do {
            let normal=try await makeLiveMovie(micro:false);movies.append(normal)
            let micro=try await makeLiveMovie(micro:true);movies.append(micro)
            let latest=try await makeLiveMovie(micro:false,earlyReturn:true);movies.append(latest)
            let combined=try await makeLiveMovie(micro:true,combined:true);movies.append(combined)
            let budget=try await makeLiveMovie(micro:false,budgetReturn:true);movies.append(budget)
            for (name,delay) in [("normal",0.1),("delayed-4",4.0),("delayed-8",8.0),("latest-queued",8.0),("micro",0.1),("combined-micro-8",8.0),("empty",0.1),("failed",0.1),("stop",8.0),("background",8.0),("retain-empty-B",0.1),("retain-failed-B",0.1),("retain-budget",0.1),("retained-stop",0.1),("retained-background",0.1),("pause-budget",0.1),("pause-inflight",8.0)] {
                let old=work;stop(userInitiated:true);await old?.value
                capture.resetLiveRegistration();liveSession=LiveRecognitionSession();liveEvents=[];liveRequestLifecycles=[];liveEpisodeReasonCounts=[:];liveLastFrame=[:];liveFrameCount=0;liveMaximumAgeMS=0
                fixtureUsesWallClock=true;fixtureTime=0;blocked=false;inflight=false
                generation=UUID();running=true;beginCaptureRun()
                let before=requestCount
                fixtureProvider = { [weak self] jpeg in
                    guard let self,UIImage(data:jpeg) != nil else { throw SIWCError.invalidResponse }
                    let target=self.liveFixtureTarget
                    let ordinal=self.liveSession.lifetimeSentCount
                    let wait=ordinal==1 ? delay : (["retained-stop","retained-background"].contains(name) && ordinal==2 ? 8.0 : 0.1)
                    // Deliberately uncancellable transport exercises late return after stop.
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global().asyncAfter(deadline:.now()+wait) { continuation.resume() }
                    }
                    let empty=name=="empty" || (name=="retain-empty-B" && ordinal==2)
                    let failed=name=="failed" || (name=="retain-failed-B" && ordinal==2)
                    let answer=try JSONSerialization.data(withJSONObject:["names":empty ? [] : [target],"summary":empty ? "" : "這是合成測試中的物件，標示為\(target)。","text":[],"barcodes":[]])
                    let delta=try JSONSerialization.data(withJSONObject:["type":"response.output_text.delta","delta":String(decoding:answer,as:UTF8.self)])
                    let end=failed ? #"data: {"type":"response.failed","response":{"error":{"code":"generated_test"}}}"# : #"data: {"type":"response.completed"}"#
                    let bytes=Array(("data: "+String(decoding:delta,as:UTF8.self)+"\n\n"+end+"\n\n").utf8)
                    var cursor=0
                    let value=try await SIWCStreamReader.read(nextByte:{
                        guard cursor<bytes.count else { return nil };defer { cursor += 1 };return bytes[cursor]
                    },progress:{ _,_,_ in })
                    return try CameraAnswer.parse(value)
                }
                let microCase=["micro","combined-micro-8","empty","failed"].contains(name)
                let budgetMovie=["retain-budget","pause-budget"].contains(name)
                let asset=AVURLAsset(url:budgetMovie ? budget : name=="combined-micro-8" ? combined : microCase ? micro : name=="latest-queued" ? latest : normal)
                let tracks=try await asset.loadTracks(withMediaType:.video)
                guard let track=tracks.first else { throw SIWCError.invalidResponse }
                let reader=try AVAssetReader(asset:asset)
                let output=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
                output.alwaysCopiesSampleData=false;reader.add(output)
                guard reader.startReading() else { throw SIWCError.invalidResponse }
                let context=CIContext(options:[.cacheIntermediates:false]),start=timeNow()
                var samples:[[String:Any]]=[],index=0,wrongVisible=0,preparationFailures=0
                var pauseChecks:[String:Bool]=[:],didPause=false
                while reader.status == .reading {
                    let targetTime=start+Double(index)/4
                    if timeNow()<targetTime { try await Task.sleep(for:.seconds(targetTime-timeNow())) }
                    let captured=timeNow()
                    guard let sample=output.copyNextSampleBuffer(),let pixel=CMSampleBufferGetImageBuffer(sample) else { break }
                    let t=CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    let returnAt: Double=name=="latest-queued" ? 5 : 11
                    let moving = !microCase && ((t>=2 && t<3) || (t>=returnAt && t<returnAt+1) || (budgetMovie && t>=15 && t<16))
                    let target=moving ? "" : !microCase && ((t>=3 && t<returnAt) || (budgetMovie && t>=16)) ? "B" : "A"
                    liveFixtureTarget=target
                    var stats=CaptureStatistics();stats.frames=index+1;stats.samples=index+1
                    if let image=CameraCapture.centralImage(CIImage(cvPixelBuffer:pixel),context:context),let prepared=try? capture.prepareLiveFrame(image,time:captured) {
                        stats.accepted=1
                        if ProcessInfo.processInfo.arguments.contains("--camera-live-fixture-fallback") {
                            // Exercise the original unknown/no-descriptor request path. Optical
                            // extraction still runs above; positive reuse has its own ORB fixture.
                            let unknown=FixedForegroundMatcher.Observation(features:nil,matches:[],evaluated:[],milliseconds:prepared.identity?.milliseconds ?? 0)
                            frame(CameraFrame(image:prepared.image,fingerprint:prepared.fingerprint,feature:nil,time:prepared.time,registration:prepared.registration,identity:unknown),generation:generation,stats:stats)
                        } else { frame(prepared,generation:generation,stats:stats) }
                    } else { preparationFailures += 1;frame(nil,generation:generation,stats:stats) }
                    let isWrong=visible != nil && !showingPreviousResult && (target.isEmpty || visible?.names.first != target)
                    if isWrong { wrongVisible += 1 }
                    samples.append(["movieAt":t,"capturedAt":captured,"processedAt":timeNow(),"expectedTarget":target,"moving":moving,"visible":visible != nil,"isPrevious":showingPreviousResult,"visibleMatchesCurrent":visible?.names.first == target,"wrongVisible":isWrong,"historyCount":liveSession.history.entries.count,"latestSuccessfulSequence":liveSession.history.latest?.sequence ?? 0,"adopted":liveSession.adoptedCount,"sent":liveSession.sentCount,"queued":liveSession.queuedIntent != nil,"gate":liveSession.gate,"geometry":liveLastFrame])
                    index += 1
                    if !didPause && ((name=="pause-budget" && t>=14.5) || (name=="pause-inflight" && t>=1.5)) {
                        didPause=true
                        let records=liveSession.history.entries,sequence=liveSession.lifetimeSentCount,slot=liveSession.inflightRequest
                        pauseChecks["beforePauseExpectedState"] = name=="pause-budget" ? liveSession.sentCount==3 && records.count==3 && slot==nil : liveSession.sentCount==1 && slot != nil
                        stop(userInitiated:true)
                        pauseChecks["pauseZeroAndHistoryPreserved"] = liveSession.sentCount==0 && liveTrialStatus=="已送 0/3" && liveSession.history.entries==records
                        pauseChecks["pauseDoesNotReleaseTransport"] = liveSession.inflightRequest==slot
                        stop(userInitiated:true)
                        pauseChecks["repeatedPauseIsSafe"] = liveSession.sentCount==0 && liveSession.lifetimeSentCount==sequence && liveSession.history.entries==records
                        running=true;beginCaptureRun()
                        liveEvent("fixture-resumed-after-manual-pause",at:timeNow(),fields:["batchSent":liveSession.sentCount,"lifetimeSent":liveSession.lifetimeSentCount,"historyCount":liveSession.history.entries.count])
                    }
                    if ["stop","background","retained-stop","retained-background"].contains(name),t>=4.5 {
                        let task=work
                        stop(userInitiated:name=="stop" || name=="retained-stop",reason:.sceneBackground)
                        await task?.value;reader.cancelReading();break
                    }
                }
                await work?.value
                reports.append(["scenario":name,"firstResponseDelaySeconds":delay,"requests":requestCount-before,"wrongVisibleFrames":wrongVisible,
                    "pauseChecks":pauseChecks,"preparationFailures":preparationFailures,"readerStatus":reader.status.rawValue,"finalVisible":visible != nil,"summary":liveSummary(),"samples":samples])
                // Checkpoint each completed case; a locked/terminated device does not lose prior evidence.
                writeLiveFixture(reports,error:nil,complete:false)
            }
            writeLiveFixture(reports,error:nil,complete:true)
        } catch { writeLiveFixture(reports,error:String(describing:type(of:error)),complete:false) }
        let task=work;stop(userInitiated:true);await task?.value
        fixtureProvider=nil;fixtureTime=nil;fixtureUsesWallClock=false
    }
    private func writeLiveFixture(_ cases:[[String:Any]],error:String?,complete:Bool) {
        var report:[String:Any]=["fixture":"live-current-video-controller","revision":6,"identityPolicy":ProcessInfo.processInfo.arguments.contains("--camera-live-fixture-fallback") ? "forced-unknown-fallback-after-full-extraction" : "fixed-foreground-orb","budgetPolicy":"manual-pause-resets-batch-global-sequence-preserved","answerSchema":"names-summary-text-barcodes","displayPolicy":"all-active-successes-in-history-latest-by-request-pause-retains-background-clears","complete":complete,
            "processID":ProcessInfo.processInfo.processIdentifier,"recordedAt":ISO8601DateFormatter().string(from:Date()),
            "networkRequests":0,"cameraStarted":false,"source":"generated H264 1080x1920 -> AVAssetReader BGRA -> central768 -> prepareLiveFrame/native-registration -> production frame/liveFrame -> SSE reader -> answer parse -> visible",
            "clock":"real monotonic, 4fps movie presentation pacing, continuous frames during delayed responses","cases":cases]
        report["errorCategory"]=error
        if let root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first,let data=try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) {
            try? data.write(to:root.appendingPathComponent("camera-live-fixture.json"),options:.atomic)
        }
    }

    private var cameraPipelineMode: CameraPipelineMode { .resolve(arguments: ProcessInfo.processInfo.arguments) }
    private var liveCurrentEnabled: Bool { cameraPipelineMode == .liveCurrent }
    private var liveSession = LiveRecognitionSession()
    private var fixedReferenceFeatures: [UUID: ForegroundORBFeatures] = [:]
    private var publishedReferenceIDs: Set<UUID> = []
    private func syncFixedReferences() {
        let ids = Set(liveSession.references.entries.map(\.id))
        fixedReferenceFeatures = fixedReferenceFeatures.filter { ids.contains($0.key) }
        guard ids != publishedReferenceIDs else { return }
        publishedReferenceIDs = ids
        capture.updateFixedReferences(liveSession.references.entries.compactMap { entry in
            fixedReferenceFeatures[entry.id].map { .init(id: entry.id, capturedAt: entry.capturedAt, features: $0) }
        })
    }
    private var liveEvents: [[String: Any]] = []
    private var liveRequestLifecycles: [[String: Any]] = []
    private var liveEpisodeReasonCounts: [String:Int] = [:]
    private var liveLastFrame: [String:Any] = [:]
    var showingPreviousResult = false
    var sessionRecords: [RecognitionHistory.Entry] = []
    private var liveDisplayedRequestID: UUID?
    private var liveFrameCount = 0
    private var liveMaximumAgeMS = 0.0
    private var liveFixtureTarget = ""
    var liveTrialStatus: String? {
        guard liveCurrentEnabled else { return nil }
        return "已送 \(liveSession.sentCount)/\(liveSession.limit)"
    }
    private func liveEvent(_ kind: String, at time: Double, fields: [String: Any] = [:]) {
        var event = fields; event["kind"] = kind; event["at"] = time
        liveEvents.append(event); liveEvents = Array(liveEvents.suffix(80))
    }
    private func liveSummary() -> [String: Any] {
        ["gate":liveSession.gate, "adopted":liveSession.adoptedCount, "sent":liveSession.sentCount,"lifetimeSent":liveSession.lifetimeSentCount,"budgetLabel":liveTrialStatus ?? "",
         "finished":liveSession.completedCount, "discarded":liveSession.discardedCount,
         "limit":liveSession.limit, "queued":liveSession.queuedIntent != nil, "inflight":liveSession.inflightRequest != nil,
         "visible":visible != nil, "visibleIsPrevious":showingPreviousResult, "frames":liveFrameCount, "maximumAgeMS":liveMaximumAgeMS,
         "events":liveEvents, "requestLifecycles":liveRequestLifecycles, "episodeReasonCounts":liveEpisodeReasonCounts,
         "lastFrame":liveLastFrame, "lastCompletionReason":liveSession.lastCompletionReason,
         "displayEnabled":true, "cacheEnabled":true, "referenceCount":liveSession.references.entries.count, "pendingReferences":liveSession.references.entries.filter { $0.status == .pending }.count, "historyCount":liveSession.history.entries.count,
         "latestSuccessfulSequence":liveSession.history.latest?.sequence ?? 0,
         "history":liveSession.history.entries.map { ["sequence":$0.sequence,"names":$0.result.names.count,"summaryCharacters":$0.result.summary.count,"text":$0.result.text.count,"barcodes":$0.result.barcodes.count] }]
    }
    private func syncLiveVisible(at now: Double) {
        syncFixedReferences()
        let next=liveSession.visible,previous=liveSession.visibleIsPrevious,nextID=liveSession.visibleRequestID
        if visible != next || liveDisplayedRequestID != nextID {
            let kind=next == nil ? "hidden" : visible == nil ? "visible" : "replaced"
            liveEvent(kind,at:now,fields:["gate":liveSession.gate,"episodeReason":liveSession.lastEpisodeReason])
            if next != nil { displayCount += 1 }
        }
        if next != nil && showingPreviousResult != previous {
            liveEvent(previous ? "marked-previous" : "marked-current",at:now,fields:["episodeReason":liveSession.lastEpisodeReason])
        }
        // One synchronous actor turn: never clear the old card between valid results.
        visible=next;showingPreviousResult=previous;liveDisplayedRequestID=nextID
        if sessionRecords != liveSession.history.entries { sessionRecords=liveSession.history.entries }
    }
    private func liveFrame(_ frame: CameraFrame?, now: Double) {
        liveFrameCount += 1
        if let frame { liveMaximumAgeMS = max(liveMaximumAgeMS, (now-frame.time)*1000) }
        let previousEpisode = liveSession.episode
        let previousCapturedAt = liveSession.lastObservedAt
        let adopted = liveSession.observe(frame?.fingerprint, capturedAt: frame?.time ?? now, now: now, sceneChangeReason: frame?.registration?.sceneChanged == true ? frame?.registration?.reason : nil, matchingReferenceIDs: frame?.identity?.matches ?? [], evaluatedReferenceIDs: frame?.identity?.evaluated)
        liveLastFrame = ["capturedAt":frame?.time ?? now,"processedAt":now,"ageMS":frame.map { (now-$0.time)*1000 } ?? 0,
            "usable":frame != nil,"stableMS":liveSession.stableElapsed*1000,"gate":liveSession.gate]
        liveLastFrame["gapMS"] = previousCapturedAt.map { ((frame?.time ?? now)-$0)*1000 }
        liveLastFrame["distance"] = liveSession.lastDistance
        liveLastFrame["foregroundORBMS"] = frame?.identity?.milliseconds
        liveLastFrame["referenceMatchCount"] = frame?.identity?.matches.count
        if let registration=frame?.registration {
            liveLastFrame["registrationReason"]=registration.reason;liveLastFrame["registrationMS"]=registration.milliseconds
            liveLastFrame["registeredDistance"]=registration.distance;liveLastFrame["cornerMotionPixels"]=registration.maximumCornerMotion
        }
        if previousEpisode != liveSession.episode {
            let reason=liveSession.lastEpisodeReason;liveEpisodeReasonCounts[reason,default:0] += 1
            var detail=liveLastFrame;detail["reason"]=reason;detail["distance"]=liveSession.lastEpisodeDistance
            detail["endedInflightEpisode"]=liveSession.inflightRequest != nil
            liveEvent("episode-changed",at:now,fields:detail)
        }
        if let adopted { liveEvent("adopted", at: now, fields:["adoptedAt":adopted.adoptedAt,"ordinal":liveSession.adoptedCount,"transportBusy":inflight]) }
        syncLiveVisible(at: now); pipelineStage = "live-" + liveSession.gate
        defer { if now-lastDiagnosticAt >= 1 { lastDiagnosticAt=now;saveDiagnostic(phase:pipelineStage) } }
        guard !pauseIfCaptureTimeExpired(), let frame, liveSession.queuedIntent != nil, !inflight, !blocked else { return }
        let encodingStart = timeNow()
        let encoded = fixtureJPEGEncoder.map { $0(frame.image) } ?? UIImage(cgImage:frame.image).jpegData(compressionQuality:0.82)
        guard let jpeg = encoded, !jpeg.isEmpty else { liveSession.discardQueuedIntent(); return }
        guard acceptsFrameFocus(frame) else { liveSession.interruptAcquisitionForFocus(); return }
        guard !pauseIfCaptureTimeExpired(), let request = liveSession.startRequest(snapshotCapturedAt:frame.time, at:timeNow(), referenceAvailable:frame.identity?.features != nil) else { return }
        if let features = frame.identity?.features { fixedReferenceFeatures[request.intent.id] = features }; syncFixedReferences()
        inflight = true; requestCount += 1; requestID = request.intent.id.uuidString
        beginRecognitionPreview(id: request.intent.id, jpeg: jpeg)
        liveEvent("started", at:request.startedAt, fields:["adoptedAt":request.intent.adoptedAt,"snapshotCapturedAt":request.snapshotCapturedAt,
            "startedAt":request.startedAt,"ordinal":request.sequence,"batchOrdinal":request.batchSequence,"jpegBytes":jpeg.count,"imageWidth":frame.image.width,"imageHeight":frame.image.height,
            "encodingMS":(request.startedAt-encodingStart)*1000,"provider":fixtureProvider == nil ? "real-pro" : "offline-mock"])
        let requestOrdinal=request.sequence
        liveRequestLifecycles.append(["ordinal":requestOrdinal,"batchOrdinal":request.batchSequence,"requestID":request.intent.id.uuidString,"episodeID":request.intent.episode.uuidString,"generationID":request.intent.generation.uuidString,"adoptedAt":request.intent.adoptedAt,
            "snapshotCapturedAt":request.snapshotCapturedAt,"startedAt":request.startedAt,"phase":"started"])
        liveRequestLifecycles=Array(liveRequestLifecycles.suffix(12))
        let provider = fixtureProvider
        let captureEpoch = generation
        work = Task { [weak self] in
            guard let self else { return }
            var result: RecognitionResult?
            var outcome = "failed"
            var focusRejectedBeforeSend = false
            let validateBeforeImageSend = {
                try Task.checkCancellation()
                guard self.running, self.generation == captureEpoch, !self.pauseIfCaptureTimeExpired() else { throw CancellationError() }
                try self.requireFrameFocus(frame)
            }
            do {
                if self.pauseIfCaptureTimeExpired() { throw CancellationError() }
                try Task.checkCancellation()
                let value: RecognitionResult
                if let provider {
                    await self.fixtureBeforeImageSend?()
                    try validateBeforeImageSend()
                    value = try await provider(jpeg)
                } else { value = try await self.account.recognize(jpeg:jpeg,requestID:request.intent.id.uuidString,validateBeforeImageSend:validateBeforeImageSend) }
                if self.pauseIfCaptureTimeExpired() { throw CancellationError() }
                try Task.checkCancellation()
                result = value.withSourceImage(request.intent.id); outcome = value.lines.isEmpty ? "empty" : "parsed-nonempty"
            } catch is CameraFocusGate.Rejection {
                focusRejectedBeforeSend = true; outcome = "focus-changed-before-image-send"
                self.liveSession.releaseBeforeImageSend(request, at: self.timeNow())
                self.requestCount = max(0, self.requestCount - 1)
                self.focusBeforeSendRejections += 1
            } catch {
                outcome = Task.isCancelled ? "cancelled" : "failed"
                if !Task.isCancelled, provider == nil {
                    if let http = error as? SIWCHTTPError, [400,401,403,429].contains(http.status) { self.blocked = true }
                    if let terminal = error as? SIWCStreamFailure, terminal.code?.hasPrefix("subscription_sharing_") == true { self.blocked = true }
                    if !(error is URLError) { self.blocked = true }
                }
            }
            let finished = self.timeNow()
            let generationCurrent=request.intent.generation == self.liveSession.generation
            let episodeCurrent=request.intent.episode == self.liveSession.episode
            let accepted = focusRejectedBeforeSend ? false : self.liveSession.complete(request,result:result,at:finished)
            if accepted { self.sourceImages.insert(jpeg, for:request.intent.id) }
            self.finishRecognitionPreview(id: request.intent.id)
            self.inflight = false
            self.lastLatency = finished-request.startedAt
            var fields: [String:Any] = ["outcome":outcome,"acceptedReply":accepted,"acceptedAsHistory":accepted,
                "acceptedCurrentEpisode":accepted && request.intent.episode == self.liveSession.episode,"historyCount":self.liveSession.history.entries.count,"startedAt":request.startedAt,
                "fieldCounts":["summaryCharacters":result?.summary.count ?? 0,"names":result?.names.count ?? 0,"text":result?.text.count ?? 0,"barcodes":result?.barcodes.count ?? 0],
                "ordinal":requestOrdinal,"generationCurrent":generationCurrent,"episodeCurrentBeforeExpiry":episodeCurrent,
                "completionReason":self.liveSession.lastCompletionReason,"episodeReason":self.liveSession.lastEpisodeReason]
            fields["lastFrameAgeMS"]=self.liveSession.lastCompletionFrameAge.map { $0*1000 }
            if provider == nil { fields["transport"] = self.firstCaptureRealTransport(requestID:request.intent.id) }
            if let index=self.liveRequestLifecycles.firstIndex(where: { $0["ordinal"] as? Int == requestOrdinal }) {
                for (key,value) in fields { self.liveRequestLifecycles[index][key]=value }
                self.liveRequestLifecycles[index]["finishedAt"]=finished
                self.liveRequestLifecycles[index]["phase"]="completed"
            }
            self.liveEvent("completed",at:finished,fields:fields)
            self.syncLiveVisible(at:finished)
            self.diagnostic = accepted ? "答案已加入本次紀錄" : "回應已結束"
            self.saveDiagnostic(phase:self.running ? "live-response-finished" : "paused")
        }
    }



    private var firstCaptureEnabled: Bool { cameraPipelineMode == .firstCapture }
    var firstCaptureTrialStatus: String? {
        guard ProcessInfo.processInfo.arguments.contains("--camera-first-capture") else { return nil }
        if let event = firstCaptureEvents.last {
            let transport = event["transport"] as? [String:Any]
            if event["outcome"] as? String == "parsed-nonempty", transport?["terminalEvent"] as? String == "response.completed" {
                return "單張驗證完成；本次不顯示辨識內容"
            }
            return "單張驗證已結束，請回報；不會再次送出"
        }
        if inflight { return "已送出一張，等待回應；請保持App在前景" }
        if firstCapture.sentCount >= 1 { return "本次一張額度已用完" }
        return running ? "取景中：請對準物品並保持穩定" : "單張驗證待開始；本次不顯示辨識內容"
    }
    private var firstCapture = FirstCaptureGate()
    private var firstCaptureEvents: [[String: Any]] = []
    private var firstTransportMetrics: [String: Any] = [:]
    private var firstCaptureLastFrame: [String: Any] = [:]
    private func firstCaptureSummary() -> [String: Any] {
        ["gate": firstCapture.gate, "stableMS": Int(firstCapture.stableElapsed*1000), "sent": firstCapture.sentCount,
         "limit": firstCapture.limit, "running": running, "inflight": inflight, "manualCameraTrial": ProcessInfo.processInfo.arguments.contains("--camera-first-capture"),
         "finished": firstCapture.completedCount, "discarded": firstCapture.discardedCount,
         "displayEnabled": false, "cacheEnabled": false, "events": firstCaptureEvents, "lastFrame": firstCaptureLastFrame]
    }
    private func firstCaptureFrame(_ frame: CameraFrame?, now: Double) {
        defer { if now-lastDiagnosticAt >= 1 { saveDiagnostic(phase:pipelineStage) } }
        visible = nil
        let ticket = firstCapture.observe(frame?.fingerprint, capturedAt: frame?.time ?? now, now: now)
        firstCaptureLastFrame = ["ageMS": frame.map { (now-$0.time)*1000 } ?? 0,
                                 "width": frame?.image.width ?? 0, "height": frame?.image.height ?? 0,
                                 "gate": firstCapture.gate, "stableMS": Int(firstCapture.stableElapsed*1000)]
        pipelineStage = "first-capture-" + firstCapture.gate
        guard let ticket, let frame else { return }
        guard !inflight, !blocked else { firstCapture.releaseUnsent(ticket); return }
        let encodingStart = timeNow()
        let encoded = fixtureJPEGEncoder.map { $0(frame.image) } ?? UIImage(cgImage: frame.image).jpegData(compressionQuality: 0.82)
        guard let jpeg = encoded, !jpeg.isEmpty else {
            firstCapture.releaseUnsent(ticket); countBranch("first-capture-jpeg-failed"); return
        }
        guard acceptsFrameFocus(frame) else { firstCapture.releaseUnsent(ticket); return }
        guard firstCapture.markSent(ticket, at: timeNow()) else { countBranch("first-capture-aged-during-encoding"); return }
        requestCount += 1; inflight = true; pipelineStage = "first-capture-request-started"
        saveDiagnostic(phase: pipelineStage)
        let epoch = generation, start = timeNow()
        let realProvider = fixtureProvider == nil
        var event: [String: Any] = ["capturedAt": ticket.capturedAt, "startedAt": start,
            "stableMS": Int(firstCapture.stableElapsed*1000), "encodingMS": (start-encodingStart)*1000,
            "imageWidth": frame.image.width, "imageHeight": frame.image.height, "jpegBytes": jpeg.count,
            "displayEnabled": false, "provider": fixtureProvider == nil ? "real-pro" : "offline-sse-injection"]
        firstTransportMetrics = [:]
        work = Task { [weak self] in
            guard let self else { return }
            defer {
                self.inflight = false
                let accepted = self.firstCapture.complete(ticket)
                event["finishedAt"] = self.timeNow(); event["durationMS"] = (self.timeNow()-start)*1000
                event["completionAccepted"] = accepted; event["generationCurrent"] = self.generation == epoch
                if realProvider { self.firstTransportMetrics = self.firstCaptureRealTransport(requestID: ticket.id) }
                event["transport"] = self.firstTransportMetrics
                self.firstCaptureEvents.append(event); self.firstCaptureEvents = Array(self.firstCaptureEvents.suffix(8))
                self.visible = nil; self.saveDiagnostic(phase: "first-capture-finished-display-disabled")
            }
            do {
                let result: RecognitionResult
                let validate = {
                    try Task.checkCancellation()
                    guard self.running, self.generation == epoch, !self.pauseIfCaptureTimeExpired() else { throw CancellationError() }
                    try self.requireFrameFocus(frame)
                }
                try validate()
                if let provider = self.fixtureProvider { result = try await provider(jpeg) }
                else { result = try await self.account.recognize(jpeg: jpeg, requestID: ticket.id.uuidString, validateBeforeImageSend: validate) }
                try Task.checkCancellation()
                guard self.generation == epoch, self.running else { event["outcome"] = "discarded-after-stop"; return }
                event["outcome"] = result.lines.isEmpty ? "empty" : "parsed-nonempty"
                event["fieldCounts"] = ["summaryCharacters":result.summary.count,"names":result.names.count,"text":result.text.count,"barcodes":result.barcodes.count]
                self.diagnostic = "第一關回應完成，結果展示尚未驗收"
                // Preserve the accepted first-stage baseline: display remains disabled in this mode.
            } catch is CameraFocusGate.Rejection {
                self.firstCapture.releaseBeforeImageSend(ticket); self.requestCount = max(0,self.requestCount-1)
                self.focusBeforeSendRejections += 1; event["outcome"] = "focus-changed-before-image-send"
            } catch {
                event["outcome"] = Task.isCancelled ? "cancelled" : "failed"
                self.diagnostic = "第一關已停止"
            }
        }
    }

    let sourceImages = RecognitionSourceStore()
    let shareSession = RecognitionShareSession.shared
    let capture = CameraCapture()
    let account: SIWCController
    private let captureClock: () -> TimeInterval
    private let requestCameraAccess: () async -> Bool
    private let beginCaptureOverride: ((UUID, Bool, Bool) -> Void)?
    private let endCaptureOverride: (() -> Void)?
    private var captureTimeLimit = CaptureTimeLimit()
    private var startAttempt: UUID?
    private var appIsActive = true
    var captureTimeLimitStatus: String? { captureTimeLimit.expired ? "已取景5分鐘，自動暫停" : nil }
    var running = false
    var permissionDenied = false
    var visible: RecognitionResult?
    private(set) var pendingRecognition: PendingRecognitionPreview?
    private func beginRecognitionPreview(id: UUID, jpeg: Data) {
        pendingRecognition = PendingRecognitionPreview(id: id, jpeg: jpeg)
    }
    private func finishRecognitionPreview(id: UUID) {
        guard pendingRecognition?.id == id else { return }
        pendingRecognition = nil
    }
    var diagnostic = "尚未辨識"
    var requestCount = 0
    private let diagnosticRunID = UUID().uuidString
    private let controllerStartedAt = ISO8601DateFormatter().string(from: Date())
    private var captureRun = 0
    private var captureRunMotionRejected = 0
    private var captureRunTargetChanges = 0
    private var captureRunNewTargets = 0
    private var localBranches: [String: Int] = [:]
    private var stableMaximumMS = 0
    private var lastStableGate = "unobserved"
    private var lastStableElapsedMS = 0
    private var lastMatcherMS = 0.0
    private var maximumMatcherMS = 0.0
    private var lastLabel: String?
    private var lastRegionalText: RegionalText?
    private var lastResultEvidenceAllowed = false
    private var fixtureJPEGEncoder: ((CGImage) -> Data?)?
    @ObservationIgnored private var previewStabilization: [String: Any] = [:]
    func recordPreviewStabilization(_ supported: Bool, _ preferred: Int, _ active: Int) {
        previewStabilization = ["supported": supported, "preferred": preferred, "active": active, "observedAt": "preview-layout"]
    }
    private func countBranch(_ name: String) { localBranches[name, default: 0] += 1 }
    private func observe(_ target: String?, at time: Double, allowRequest: Bool = true, allowDisplay: Bool = true) -> RecognitionState.Request? {
        let request = state.observe(target, at: time, allowRequest: allowRequest, allowDisplay: allowDisplay)
        lastStableGate = state.lastGate; lastStableElapsedMS = Int(state.stableElapsed * 1000)
        stableMaximumMS = max(stableMaximumMS, lastStableElapsedMS)
        countBranch("stability-" + state.lastGate)
        return request
    }
    private var captureRunStartedAt: String?
    private var captureRunStartRequestCount = 0
    private var captureHistory: [[String: Any]] = []
    private var archivedCaptureRun = 0
    private var requestCaptureRun: Int?
    private var requestStartState: [String: Any] = [:]
    private var completionCaptureRun: Int?
    private var completionTargetRelation: String?
    private var completionSuppression: String?
    private var completionLocalState: [String: Any] = [:]
    private var fixtureUsesWallClock = false
    private var fixtureRequestLimit: Int?
    private func captureSummary() -> [String: Any] {
        var value: [String: Any] = ["captureRun": captureRun, "frames": captureStats.frames, "samples": captureStats.samples, "eligible": captureStats.accepted, "newTargets": captureRunNewTargets, "targetChanges": captureRunTargetChanges, "motionRejected": captureRunMotionRejected, "branches": localBranches, "maximumStableMS": stableMaximumMS, "lastStableMS": lastStableElapsedMS, "lastGate": lastStableGate, "pipelineStage": pipelineStage, "hasCurrentTarget": currentTarget != nil, "requestCountAtStart": captureRunStartRequestCount, "requestCountAtEnd": requestCount]
        value["startedAt"] = captureRunStartedAt
        return value
    }
    private func archiveCaptureRun(reason: String) {
        guard captureRun > 0, archivedCaptureRun != captureRun else { return }
        var value = captureSummary(); value["endedAt"] = ISO8601DateFormatter().string(from: Date()); value["endReason"] = reason
        captureHistory.append(value); captureHistory = Array(captureHistory.suffix(6)); archivedCaptureRun = captureRun
    }
    private var requestID: String?
    private var requestStartedAt: String?
    private var requestStartUptime: TimeInterval?
    private var requestFinishedAt: String?
    private var requestDurationMS: Int?
    private var requestCancellationReason: String?
    private var requestCancellationAt: String?
    private var requestCancellationMS: Int?
    private var lastStopReason: String?
    private var lastStopAt: String?
    private var completionDisposition = "not-completed"
    private var requestHistory: [[String: Any]] = []
    var lastLatency: Double?
    var firstResultLatency: Double?
    var cacheLatency: Double?
    private var completedTargets = Set<String>()
    private var acquisitionTimes: [String: Double] = [:]
    private var fixtureTime: Double?
    private var fixtureProvider: ((Data) async throws -> RecognitionResult)?
    private var fixtureBeforeImageSend: (() async -> Void)?
    private var fixtureWaiter: CheckedContinuation<RecognitionResult, Error>?
    private func timeNow() -> Double { fixtureUsesWallClock ? ProcessInfo.processInfo.systemUptime : fixtureTime ?? ProcessInfo.processInfo.systemUptime }
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
    private var lastAlignedMotionDistance: Float?
    private var lastMotionAlignmentMS = 0.0
    private var lastMotionDistance: Float?
    private var lastDiagnosticAt = 0.0
    private var pipelineStage = "idle"
    private var memory = TargetMemory(requiresConfirmation: true)
    private var state = RecognitionState()
    private var features: [String: VNFeaturePrintObservation] = [:]
    private var generation = UUID()
    private var observedFocusRevision: UInt64?
    private var focusBeforeSendRejections = 0
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
    init(account: SIWCController = SIWCController(), captureClock: @escaping () -> TimeInterval = CaptureContinuousTime.now,
         requestCameraAccess: @escaping () async -> Bool = CameraController.cameraAccess,
         beginCapture: ((UUID, Bool, Bool) -> Void)? = nil, endCapture: (() -> Void)? = nil) {
        self.account = account; self.captureClock = captureClock; self.requestCameraAccess = requestCameraAccess
        self.beginCaptureOverride = beginCapture; self.endCaptureOverride = endCapture
        account.load()
        capture.onFrame = { [weak self] frame, generation, stats in
            Task { @MainActor in self?.frame(frame, generation: generation, stats: stats) }
        }
        capture.onFailure = { [weak self] code in Task { @MainActor in self?.diagnostic = code } }
        capture.onFocusChange = { [weak self] _, epoch in
            Task { @MainActor in self?.focusChanged(generation: epoch) }
        }
    }
    private func focusChanged(generation epoch: UUID) {
        guard running, generation == epoch else { return }
        // Read latest state, because actor-delivered notifications can be delayed.
        let focus = capture.focusGate.snapshot
        guard focus.session == epoch, focus.active, observedFocusRevision != focus.revision else { return }
        observedFocusRevision = focus.revision
        liveSession.interruptAcquisitionForFocus(); firstCapture.invalidate("focus-changed")
        state.interruptAcquisitionForFocus()
        currentTarget = nil; lastFingerprint = nil; lastRegionalText = nil
        if liveCurrentEnabled { syncLiveVisible(at: timeNow()) }
        pipelineStage = focus.adjusting ? "focus-adjusting" : "focus-awaiting-new-stability"
    }
    private func acceptsFrameFocus(_ frame: CameraFrame) -> Bool {
        guard let stamp = frame.focusStamp else { return true } // Existing offline/engineering fixtures.
        focusChanged(generation: generation)
        guard capture.focusGate.allows(stamp) else { pipelineStage = "focus-stale-frame"; return false }
        return true
    }
    private func requireFrameFocus(_ frame: CameraFrame) throws {
        guard acceptsFrameFocus(frame) else { throw CameraFocusGate.Rejection.changedBeforeSend }
    }
    private static func cameraAccess() async -> Bool {
        let authorization = AVCaptureDevice.authorizationStatus(for: .video)
        if authorization == .authorized { return true }
        if authorization == .notDetermined { return await AVCaptureDevice.requestAccess(for: .video) }
        return false
    }
    var canStartCapture: Bool {
        account.planAccessReady && !account.busy && !wantsRunning && startAttempt == nil && appIsActive && !showingSettings
    }
    func start() async {
        guard !wantsRunning, startAttempt == nil, appIsActive, !showingSettings else { return }
        guard account.planAccessReady, !account.busy else { showingSettings = true; return }
        let intent = UUID(); startAttempt = intent
        defer { if startAttempt == intent { startAttempt = nil } }
        let granted = await requestCameraAccess()
        guard startAttempt == intent, appIsActive, !showingSettings, !Task.isCancelled else { return }
        guard granted else { permissionDenied = true; saveDiagnostic(phase: "camera-permission-denied"); return }
        guard captureTimeLimit.begin(at: captureClock()) else { return }
        permissionDenied = false; blocked = false; wantsRunning = true; resume()
    }
    @discardableResult private func pauseIfCaptureTimeExpired() -> Bool {
        guard captureTimeLimit.expireIfNeeded(at: captureClock()) else { return false }
        stop(reason: .durationLimit); return true
    }
    private func resume() {
        guard !pauseIfCaptureTimeExpired(), wantsRunning, appIsActive, !showingSettings, !running else { return }
        beginCaptureRun()
        generation = UUID(); running = true; lastFingerprint = nil
        if let beginCaptureOverride { beginCaptureOverride(generation, firstCaptureEnabled || liveCurrentEnabled, liveCurrentEnabled) }
        else { capture.start(generation: generation, firstCaptureOnly: firstCaptureEnabled || liveCurrentEnabled, liveCurrent: liveCurrentEnabled) }
        lastFrameAt = timeNow()
        saveDiagnostic(phase: "camera-starting")
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                guard !self.pauseIfCaptureTimeExpired() else { return }
                if self.timeNow() - self.lastFrameAt > 0.75 {
                    if self.firstCaptureEnabled { self.firstCapture.invalidate("frame-timeout") }
                    if self.liveCurrentEnabled { self.liveSession.expire(at:self.timeNow()); self.syncLiveVisible(at:self.timeNow()) }
                    if !self.liveCurrentEnabled { _ = self.observe(nil, at:self.timeNow(),allowRequest:false);self.visible=nil;self.currentTarget=nil }
                    self.pipelineStage = "no-recent-camera-frames"
                    let now = self.timeNow()
                    if now - self.lastDiagnosticAt >= 1 { self.saveDiagnostic(phase: "no-recent-camera-frames"); self.lastDiagnosticAt = now }
                }
            }
        }
    }
    private func beginCaptureRun() {
        archiveCaptureRun(reason: "replaced")
        captureRunStartedAt = ISO8601DateFormatter().string(from: Date()); captureRunStartRequestCount = requestCount
        captureRun += 1; captureStats = CaptureStatistics()
        captureRunMotionRejected = 0; captureRunTargetChanges = 0; captureRunNewTargets = 0
        localBranches = [:]; stableMaximumMS = 0; lastLabel = nil
        lastStableGate = "unobserved"; lastStableElapsedMS = 0; lastMatcherMS = 0; maximumMatcherMS = 0
    }
    enum StopReason: String { case userPause = "user-pause", durationLimit = "duration-limit", sceneInactive = "scene-inactive", sceneBackground = "scene-background", settings = "settings" }
    func stop(userInitiated: Bool = false, reason: StopReason = .sceneInactive) {
        startAttempt = nil
        pendingRecognition = nil
        let retainingPause = userInitiated || reason == .durationLimit
        if retainingPause { wantsRunning = false }
        else { sourceImages.removeAll() }
        if userInitiated { captureTimeLimit.manualPause() }
        let stopReason = userInitiated ? StopReason.userPause.rawValue : reason.rawValue
        lastStopReason = stopReason; lastStopAt = ISO8601DateFormatter().string(from: Date())
        if inflight, work != nil, requestCancellationReason == nil {
            requestCancellationReason = stopReason; requestCancellationAt = lastStopAt
            requestCancellationMS = requestStartUptime.map { Int((ProcessInfo.processInfo.systemUptime - $0) * 1000) }
        }
        archiveCaptureRun(reason: stopReason)
        generation = UUID(); running = false
        capture.focusGate.stop(); observedFocusRevision = nil
        if let endCaptureOverride { endCaptureOverride() } else { capture.stop() }
        work?.cancel(); work = nil
        watchdog?.cancel(); watchdog = nil
        if firstCaptureEnabled { firstCapture.stop() }
        if liveCurrentEnabled { capture.resetLiveRegistration();liveSession.stop(preservingHistory:retainingPause,resetBudget:retainingPause); liveEvent("stopped",at:timeNow(),fields:["reason":stopReason]) }
        state.leaveForeground(); memory.clear(); features = [:]; if !liveCurrentEnabled { visible = nil }; currentTarget = nil; completedTargets = []; acquisitionTimes = [:]; knownTargets = []; lastFingerprint = nil; lastRegionalText = nil; lastResultEvidenceAllowed = false
        if liveCurrentEnabled { syncLiveVisible(at:timeNow()) }
        saveDiagnostic(phase: "paused")
        // Keep inflight true until the cancelled provider returns; never overlap old and new calls.
    }
    func memoryWarning() {
        pendingRecognition?.jpeg = nil
        sourceImages.removeAll()
        liveSession.purgeReferences(); syncLiveVisible(at: timeNow())
        liveEvent("reference-memory-purge", at: timeNow(), fields: ["historyCount": liveSession.history.entries.count])
        saveDiagnostic(phase: running ? "live-memory-purge" : "paused-memory-purge")
    }
    func foreground(_ phase: ScenePhase) {
        appIsActive = phase == .active
        if pauseIfCaptureTimeExpired() { return }
        if phase == .active { resume() }
        else { stop(reason: phase == .background ? .sceneBackground : .sceneInactive) }
    }
    func settingsChanged(_ shown: Bool) {
        if pauseIfCaptureTimeExpired() { return }
        if shown { stop(reason: .settings) } else { account.load(); resume() }
    }
    private func frame(_ frame: CameraFrame?, generation: UUID, stats: CaptureStatistics) {
        guard running, self.generation == generation else { return }
        guard !pauseIfCaptureTimeExpired() else { return }
        let now = timeNow(); lastFrameAt = now
        focusChanged(generation: generation)
        if capture.focusGate.snapshot.active && capture.focusGate.snapshot.adjusting {
            captureStats = stats; pipelineStage = "focus-adjusting"; return
        }
        if let frame, !acceptsFrameFocus(frame) { captureStats = stats; return }
        if liveCurrentEnabled { captureStats = stats; liveFrame(frame,now:now); return }
        if firstCaptureEnabled { captureStats = stats; firstCaptureFrame(frame, now: now); return }
        captureStats = stats; lastResultEvidenceAllowed = false; lastFeatureDistance = nil; lastAlignedMotionDistance = nil; lastMotionAlignmentMS = 0
        guard frame == nil || (fixtureTime != nil && !fixtureUsesWallClock) || now - (frame?.time ?? now) <= 0.75 else {
            _ = observe(nil, at: now, allowRequest: false); visible = nil; currentTarget = nil; lastFingerprint = nil
            countBranch("stale-local-frame"); pipelineStage = "stale-local-frame"; return
        }
        defer {
            if now - lastDiagnosticAt >= 1 { saveDiagnostic(phase: pipelineStage); lastDiagnosticAt = now }
        }
        guard let frame else {
            _ = observe(nil, at: now, allowRequest: false); visible = nil; currentTarget = nil; lastFingerprint = nil
            countBranch("local-quality-or-saliency-rejected"); pipelineStage = "local-quality-or-saliency-rejected"; return
        }
        if let lastLabel {
            let transition = lastLabel.isEmpty ? (frame.labelSignature.isEmpty ? "missing-to-missing" : "missing-to-present") : (frame.labelSignature.isEmpty ? "present-to-missing" : lastLabel == frame.labelSignature ? "present-same" : "present-changed")
            countBranch("ocr-" + transition)
        } else { countBranch(frame.labelSignature.isEmpty ? "ocr-initial-missing" : "ocr-initial-present") }
        let previousLabel = lastLabel, previousFingerprint = lastFingerprint, previousRegional = lastRegionalText
        lastRegionalText = frame.regionalText
        lastLabel = frame.labelSignature
        let motion = previousFingerprint.map { frame.fingerprint.distance(to: $0, allowRotation: false, allowTranslation: false) }
        lastFingerprint = frame.fingerprint; lastMotionDistance = motion
        guard frame.feature != nil || fixtureProvider != nil else {
            _ = observe(nil, at: now, allowRequest: false); visible = nil; currentTarget = nil
            countBranch("feature-unavailable"); pipelineStage = "feature-unavailable"; return
        }
        lastFeatureDistance = nil
        let matchingStart = ProcessInfo.processInfo.systemUptime
        let target = memory.resolve(frame.fingerprint, at: now, protectedID: inflightTarget, labelSignature: frame.labelSignature, allowCreation: motion.map { $0 <= 0.035 } ?? true, regional: frame.regionalText, continuityID: currentTarget, previousRegional: previousRegional) { id in
            if frame.feature == nil && fixtureProvider != nil { return true } // explicit offline fixture only
            guard let previous = features[id], let currentFeature = frame.feature else { countBranch("visual-missing"); return false }
            var distance: Float = .infinity
            do { try currentFeature.computeDistance(&distance, to: previous); lastFeatureDistance = min(lastFeatureDistance ?? .infinity, distance); let accepted = FeatureEvidence.accepts(distance, identicalReadableLabel: !frame.labelSignature.isEmpty); countBranch(accepted ? "visual-accepted" : "visual-distance-rejected"); return accepted } catch { countBranch("visual-comparison-error"); return false }
        }
        lastMatcherMS = (ProcessInfo.processInfo.systemUptime - matchingStart) * 1000
        maximumMatcherMS = max(maximumMatcherMS, lastMatcherMS)
        countBranch("identity-" + memory.lastDecision)
        countBranch("text-evidence-" + memory.lastTextDecision)
        localBranches["spatial-direct-comparisons", default: 0] += memory.directComparisons
        localBranches["spatial-alignment-comparisons", default: 0] += memory.alignmentComparisons
        localBranches["discarded-unstable-candidates", default: 0] += memory.discardedCandidates
        if let motion, motion > 0.035 {
            // A raw pixel change may be camera translation, but compensate only
            // after matching an existing identity with independent visual evidence.
            // Unknown/readably changed labels never borrow the previous target.
            let regionalContinuity = frame.regionalText.flatMap { current in previousRegional.map { current.compare(to:$0).acquisitionCompatible } }
            let unlabeledContinuity = memory.lastTextDecision == "continuous-unlabeled-visual"
            if target != nil, memory.lastDecision == "matched", (!frame.labelSignature.isEmpty || unlabeledContinuity),
               (unlabeledContinuity || (regionalContinuity ?? (previousLabel == frame.labelSignature))), let previousFingerprint {
                let start = ProcessInfo.processInfo.systemUptime
                lastAlignedMotionDistance = (unlabeledContinuity ? frame.fingerprint : frame.fingerprint.layout()).distance(to: unlabeledContinuity ? previousFingerprint : previousFingerprint.layout(), allowRotation: false)
                lastMotionAlignmentMS = (ProcessInfo.processInfo.systemUptime-start)*1000
            }
            guard let aligned = lastAlignedMotionDistance, aligned.isFinite, aligned <= 0.035 else {
                motionRejected += 1; captureRunMotionRejected += 1; _ = observe(nil, at: now, allowRequest: false); visible = nil; currentTarget = nil
                countBranch("roi-motion"); pipelineStage = "roi-motion"; return
            }
            countBranch("motion-compensated-verified-identity")
        }
        if let target, !knownTargets.contains(target) { features[target] = frame.feature; knownTargets.insert(target); newTargets += 1; captureRunNewTargets += 1 }
        let valid = Set(memory.entries.map(\.id)); features = features.filter { valid.contains($0.key) }
        knownTargets = knownTargets.intersection(valid)
        completedTargets = completedTargets.intersection(valid); acquisitionTimes = acquisitionTimes.filter { valid.contains($0.key) }
        if target != currentTarget { targetChanges += 1; captureRunTargetChanges += 1; currentTarget = target; targetSeenAt = now; returningCachedTarget = target.map { completedTargets.contains($0) } ?? false }
        let policy = RequestAdmission(trialLimit: ProcessInfo.processInfo.arguments.contains("--camera-trial-once") ? 1 : fixtureRequestLimit)
        let trialAvailable = policy.trialLimit.map { requestCount < $0 } ?? true
        lastResultEvidenceAllowed = memory.permitsResult(target, regional: frame.regionalText)
        let request = observe(target, at: now, allowRequest: policy.allows(sent: requestCount, inflight: inflight, blocked: blocked, now: now, nextAllowed: nextRequestAt), allowDisplay: lastResultEvidenceAllowed)
        if let target, state.stableElapsed >= state.stableDuration { memory.confirm(target) }
        pipelineStage = target == nil ? "ambiguous-match" : inflight ? "inflight" : blocked ? "provider-blocked" : !trialAvailable ? "trial-request-limit" : "stability-or-dedup"
        let wasVisible = visible != nil; visible = state.visible
        if !wasVisible, visible != nil {
            displayCount += 1; pipelineStage = "result-visible"
            if returningCachedTarget { cacheLatency = now - targetSeenAt }
            else { firstResultLatency = now - (target.flatMap { acquisitionTimes[$0] } ?? targetSeenAt) }
            saveDiagnostic(phase: returningCachedTarget ? "cache-visible" : "first-result-visible")
        }
        guard let request else { return }
        countBranch("jpeg-attempt")
        let encoded: Data?
        if let fixtureJPEGEncoder { encoded = fixtureJPEGEncoder(frame.image) }
        else { encoded = UIImage(cgImage: frame.image).jpegData(compressionQuality: 0.82) }
        guard let jpeg = encoded, !jpeg.isEmpty else {
            countBranch("jpeg-failed"); state.releaseUnsent(request)
            nextRequestAt = now + 1; pipelineStage = "jpeg-encoding-failed"; return
        }
        countBranch("jpeg-succeeded")
        guard acceptsFrameFocus(frame) else { state.releaseUnsent(request); return }
        memory.bindResultEvidence(request.target, regional: frame.regionalText)
        acquisitionTimes[request.target] = targetSeenAt
        if requestID != nil { requestHistory.append(requestDiagnostic()); requestHistory = Array(requestHistory.suffix(4)) }
        inflight = true; inflightTarget = request.target; nextRequestAt = now + 4; requestCount += 1
        requestCaptureRun = captureRun; requestStartState = captureSummary()
        completionCaptureRun = nil; completionTargetRelation = nil; completionSuppression = nil; completionLocalState = [:]
        requestID = UUID().uuidString; requestStartedAt = ISO8601DateFormatter().string(from: Date())
        requestStartUptime = ProcessInfo.processInfo.systemUptime; requestFinishedAt = nil; requestDurationMS = nil
        requestCancellationReason = nil; requestCancellationAt = nil; requestCancellationMS = nil
        completionDisposition = "pending"; resultFieldCounts = [:]; matchedAtCompletion = false; lastLatency = nil
        pipelineStage = "request-started"; saveDiagnostic(phase: pipelineStage)
        let epoch = self.generation
        work = Task { [weak self] in
            guard let self else { return }
            defer {
                self.inflight = false; self.inflightTarget = nil
                self.requestFinishedAt = ISO8601DateFormatter().string(from: Date())
                self.requestDurationMS = self.requestStartUptime.map { Int((ProcessInfo.processInfo.systemUptime - $0) * 1000) }
                // Persist after cancellation/cleanup too. Old code returned before
                // saving and left an earlier snapshot marked in-flight.
                self.saveDiagnostic(phase: self.running ? self.pipelineStage : "paused")
            }
            do {
                let answer: RecognitionResult
                let validate = {
                    try Task.checkCancellation()
                    guard self.running, self.generation == epoch, !self.pauseIfCaptureTimeExpired() else { throw CancellationError() }
                    try self.requireFrameFocus(frame)
                }
                try validate()
                if let provider = self.fixtureProvider { answer = try await provider(jpeg) }
                else { answer = try await self.account.recognize(jpeg: jpeg, requestID: self.requestID, validateBeforeImageSend: validate) }
                guard !Task.isCancelled, self.generation == epoch, self.running else {
                    self.completionDisposition = "discarded-after-stop"; return
                }
                self.completionCaptureRun = self.captureRun
                self.completionTargetRelation = self.currentTarget == nil ? "no-current-target" : self.currentTarget == request.target ? "same-target" : "different-target"
                self.completionSuppression = self.currentTarget == request.target ? (self.lastResultEvidenceAllowed ? "awaiting-verified-frame" : "incomplete-regional-result-evidence") : self.completionTargetRelation
                self.completionLocalState = self.captureSummary()
                self.completedCount += 1
                if answer.lines.isEmpty { self.emptyCount += 1 }
                self.resultFieldCounts = ["summaryCharacters": answer.summary.count,"names": answer.names.count, "text": answer.text.count, "barcodes": answer.barcodes.count]
                self.matchedAtCompletion = self.currentTarget == request.target
                self.completionDisposition = answer.lines.isEmpty ? "empty" : self.matchedAtCompletion ? "cached-current-target" : "cached-other-target"
                let boundAnswer = answer.withSourceImage(request.id)
                self.state.complete(request, result: boundAnswer)
                if !answer.lines.isEmpty { self.sourceImages.insert(jpeg, for:request.id) }
                if !answer.lines.isEmpty { self.completedTargets.insert(request.target) }
                self.lastLatency = self.timeNow() - now
                self.diagnostic = "辨識完成 · \(String(format: "%.2f", self.lastLatency ?? 0)) 秒"
                self.pipelineStage = "completed"
                self.saveDiagnostic(phase: "completed")
            } catch is CameraFocusGate.Rejection {
                self.state.releaseUnsent(request); self.requestCount = max(0,self.requestCount-1)
                self.focusBeforeSendRejections += 1; self.nextRequestAt = 0
                self.completionDisposition = "focus-changed-before-image-send"
            } catch {
                guard self.generation == epoch, !Task.isCancelled else {
                    self.completionDisposition = "cancelled-after-stop"; return
                }
                self.completionDisposition = "provider-failed"
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
        for (index, dx) in [0.0, 10.0, -10.0, 0.0, 0.0, 0.0, 10.0].enumerated() {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512))
            let image = renderer.image { ctx in
                UIColor(white: 0.93, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
                (index == 4 ? UIColor.systemRed : UIColor.systemBlue).setFill(); ctx.fill(CGRect(x: 130+dx, y: 60, width: 250, height: 390))
                UIColor.white.setFill(); ctx.fill(CGRect(x: 150+dx, y: 180, width: 210, height: 150))
                ((index >= 5 ? "GLANCE 128" : "GLANCE 123") as NSString).draw(at: CGPoint(x: 157+dx, y: 225), withAttributes: [.font: UIFont.systemFont(ofSize: 28), .foregroundColor: UIColor.black])
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
                // Compare the production reader against each previous setting, using
                // generated text only. Do not substitute expected labels into frames.
                let reading = try CameraCapture.labelReading(cg)
                let previousHeight = try CameraCapture.labelReading(cg, minimumHeight: 0.02)
                let previousConfidence = try CameraCapture.labelReading(cg, minimumConfidence: 0.8)
                let label = reading.signature
                let expected = CameraCapture.labelDigest([index >= 5 ? "glance128" : "glance123"])
                generatedFrames.append(CameraFrame(image: cg, fingerprint: fp, feature: observation, labelSignature: label, time: 0))
                var featureDistance: Float = 0
                let id = memory.resolve(fp, at: Double(index), labelSignature: label) { key in
                    guard let observation else { return true } // fingerprint-only fixture is labelled below
                    guard let prior = prints[key] else { return false }
                    do { try observation.computeDistance(&featureDistance, to: prior); return FeatureEvidence.accepts(featureDistance, identicalReadableLabel: !label.isEmpty) } catch { return false }
                }
                if let id, prints[id] == nil { prints[id] = observation }
                if index == 0 { firstID = id }
                cases.append(["identityMatchesExpected": id != nil && ((id == firstID) == (index < 4)), "expectedSameTarget": index < 4, "labelMatchesGeneratedText": label == expected, "oldMinimumHeightHasEvidence": !previousHeight.signature.isEmpty, "oldConfidenceFilterHasEvidence": !previousConfidence.signature.isEmpty, "textProcessingMS": reading.processingMS, "textCandidateCount": reading.candidateCount, "textMaxConfidence": reading.maximumConfidence, "labelEvidencePresent": !label.isEmpty, "visionError": visionError, "case": index, "sameTarget": id == firstID && id != nil, "clear": SceneQuality(fine).usable, "featureDistance": featureDistance, "fingerprintDistance": memory.bestDistance ?? 0])
            } catch { cases.append(["case": index, "error": "local-fixture-validation"]) }
        }
        var checks: [String: Bool] = [:]
        var simulatedTiming: [String: Double] = [:]
        if generatedFrames.count == 7 {
            // Exercise the actual controller with generated frames and a deterministic
            // provider continuation. No capture session or network provider is started.
            beginCaptureRun()
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
            let firstCaptureRun = captureRun
            beginCaptureRun()
            checks["captureCountersResetIndependently"] = captureRun == firstCaptureRun + 1 && captureStats.samples == 0 && captureRunTargetChanges == 0 && requestCount == 2
            stats = CaptureStatistics()
            fixtureTime = 8; running = true; generation = UUID()
            for t in [8.0,8.25,8.5,8.75,9.0,9.25] { await feed(0,t) }
            let cancelledWork = work
            stop(userInitiated: true)
            if let continuation = fixtureWaiter { fixtureWaiter = nil; continuation.resume(returning: RecognitionResult(names: ["too-late"])) }
            await cancelledWork?.value
            checks["cancelledResultNeverRevives"] = visible == nil && !running && !inflight
            checks["productionAllowsMultipleTargets"] = requestCount == 3
            checks["cancelReasonAndCompletionSaved"] = requestCancellationReason == "user-pause" && requestFinishedAt != nil && completionDisposition == "discarded-after-stop"
            if let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let data = try? Data(contentsOf: root.appendingPathComponent("camera-diagnostic.json")),
               let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let lifecycle = saved["requestLifecycle"] as? [String: Any]
                checks["cancelSnapshotIsFinal"] = saved["inflight"] as? Bool == false && saved["processID"] as? Int == Int(ProcessInfo.processInfo.processIdentifier) && lifecycle?["finishedAt"] != nil
            } else { checks["cancelSnapshotIsFinal"] = false }
            for reason in [StopReason.sceneInactive, .sceneBackground, .settings] {
                fixtureTime = (fixtureTime ?? 9.25) + 5
                beginCaptureRun(); stats = CaptureStatistics(); running = true; generation = UUID()
                let start = fixtureTime!
                for delta in [0.0, 0.25, 0.5, 0.75, 1.0] { await feed(0, start + delta) }
                let pendingWork = work
                let hadInflight = inflight && fixtureWaiter != nil
                stop(reason: reason)
                // A subsequent lifecycle callback must not overwrite the first
                // reason that cancelled this request.
                stop(reason: .sceneBackground)
                if let continuation = fixtureWaiter { fixtureWaiter = nil; continuation.resume(throwing: CancellationError()) }
                await pendingWork?.value
                checks["cancellation-" + reason.rawValue] = hadInflight && requestCancellationReason == reason.rawValue && !inflight && !running && visible == nil && completionDisposition == "cancelled-after-stop"
            }
            checks["recentRequestHistoryBounded"] = requestHistory.count <= 4 && requestHistory.last?["sequence"] as? Int == requestCount - 1
            fixtureProvider = nil; fixtureTime = nil
        }
        if let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: ["fixture": "generated-card-motion", "fixtureRevision": 3, "recordedAt": ISO8601DateFormatter().string(from: Date()), "networkRequests": 0, "visionAvailable": visionAvailable, "matcherPassed": cases.count == 7 && cases.allSatisfy { ($0["identityMatchesExpected"] as? Bool) == true }, "readyForCameraTrial": visionAvailable && cases.count == 7 && cases.allSatisfy { ($0["identityMatchesExpected"] as? Bool) == true && ($0["labelMatchesGeneratedText"] as? Bool) == true } && checks.count == 19 && checks.values.allSatisfy { $0 }, "cases": cases, "controllerChecks": checks, "simulatedTiming": simulatedTiming], options: [.sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("camera-local-fixture.json"), options: .atomic)
        }
    }
    func runContinuousFixture() async {
        guard ProcessInfo.processInfo.arguments.contains("--camera-continuous-fixture") else { return }
        var reports: [[String: Any]] = []
        let scenarios = ["translation", "scale", "rotation", "lighting", "handheld-combined", "handheld-production-ocr", "ocr-missing-present", "jpeg-first-failure", "one-digit-negative"]
        for scenario in scenarios {
            stop(userInitiated: true)
            beginCaptureRun(); fixtureTime = 0; running = true; generation = UUID(); nextRequestAt = 0; blocked = false
            let before = requestCount
            fixtureProvider = { _ in RecognitionResult(names: ["generated-answer"]) }
            var encodingCalls = 0
            fixtureJPEGEncoder = scenario == "jpeg-first-failure" ? { image in
                encodingCalls += 1
                return encodingCalls == 1 ? nil : UIImage(cgImage: image).jpegData(compressionQuality: 0.82)
            } : nil
            var samples: [[String: Any]] = []
            var stats = CaptureStatistics()
            var actualVisionAvailable = true
            var incorrectVisible = false
            for index in 0..<25 {
                let phase = Double(index) * 0.8
                let combined = scenario.hasPrefix("handheld")
                let dx = (scenario == "translation" || combined) ? sin(phase) * 3 : 0
                let dy = combined ? cos(phase * 0.7) * 2 : 0
                let scale = (scenario == "scale" || combined) ? 1 + sin(phase * 0.8) * 0.018 : 1
                let angle = (scenario == "rotation" || combined) ? sin(phase * 0.6) * 1.2 * .pi / 180 : 0
                let light = (scenario == "lighting" || combined) ? sin(phase * 0.4) * 0.025 : 0
                let changedDigit = scenario == "one-digit-negative" && index >= 10
                let rendered = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512)).image { ctx in
                    UIColor(white: 0.93 + light, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
                    ctx.cgContext.translateBy(x: 256 + dx, y: 256 + dy)
                    ctx.cgContext.rotate(by: angle); ctx.cgContext.scaleBy(x: scale, y: scale)
                    ctx.cgContext.translateBy(x: -256, y: -256)
                    UIColor(red: 0.1 + light, green: 0.4 + light, blue: 0.8 + light, alpha: 1).setFill(); ctx.fill(CGRect(x: 130, y: 60, width: 250, height: 390))
                    UIColor(white: 0.99 + min(0,light), alpha: 1).setFill(); ctx.fill(CGRect(x: 150, y: 180, width: 210, height: 150))
                    ((changedDigit ? "GLANCE 128" : "GLANCE 123") as NSString).draw(at: CGPoint(x: 157, y: 225), withAttributes: [.font: UIFont.systemFont(ofSize: 28), .foregroundColor: UIColor.black])
                }
                guard let image = rendered.cgImage, let fingerprint = CameraCapture.fingerprint(image) else { continue }
                var feature: VNFeaturePrintObservation?
                let visionStart = ProcessInfo.processInfo.systemUptime
                if actualVisionAvailable {
                    let request = VNGenerateImageFeaturePrintRequest()
                    do { try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request]); feature = request.results?.first as? VNFeaturePrintObservation } catch {}
                    if feature == nil { actualVisionAvailable = false }
                }
                let visionMS = (ProcessInfo.processInfo.systemUptime - visionStart) * 1000
                let label: String
                var reading: CameraCapture.LabelReading?
                if scenario == "handheld-production-ocr" { reading = try? CameraCapture.labelReading(image); label = reading?.signature ?? "" }
                else if scenario == "ocr-missing-present", index % 4 < 2 { label = "" }
                else { label = CameraCapture.labelDigest([changedDigit ? "glance128" : "glance123"]) }
                fixtureTime = Double(index) * 0.25; stats.frames += 1; stats.samples += 1; stats.accepted += 1
                frame(CameraFrame(image: image, fingerprint: fingerprint, feature: feature, labelSignature: label, time: fixtureTime!), generation: generation, stats: stats)
                await work?.value
                if changedDigit, index < 14, visible != nil { incorrectVisible = true }
                var sample: [String: Any] = ["sample": index, "identityDecision": memory.lastDecision, "stabilityGate": state.lastGate, "stableMS": Int(state.stableElapsed * 1000), "requests": requestCount - before, "visible": visible != nil, "ocrPresent": !label.isEmpty]
                sample["spatialDistance"] = memory.bestDistance; sample["motionDistance"] = lastMotionDistance
                sample["featureDistance"] = lastFeatureDistance; sample["visionMS"] = visionMS
                sample["featureAvailable"] = feature != nil; sample["matcherMS"] = lastMatcherMS
                sample["pipelineStage"] = pipelineStage
                sample["ocrMS"] = reading?.processingMS; sample["ocrCandidateCount"] = reading?.candidateCount
                sample["ocrMaximumConfidence"] = reading?.maximumConfidence
                samples.append(sample)
            }
            reports.append(["scenario": scenario, "frames": samples.count, "requestCount": requestCount - before, "visibleAtEnd": visible != nil, "incorrectEarlyDigitResult": incorrectVisible, "newTargets": captureRunNewTargets, "targetChanges": captureRunTargetChanges, "maxStableMS": stableMaximumMS, "maximumMatcherMS": maximumMatcherMS, "retainedAnchors": memory.entries.count, "confirmedAnchors": memory.entries.filter { $0.confirmed }.count, "branches": localBranches, "visionAvailable": actualVisionAvailable, "visualGate": actualVisionAvailable ? "production" : "bypassed-offline-fixture-only", "labelSource": scenario == "handheld-production-ocr" ? "production-ocr" : "controlled-generated-evidence", "samples": samples])
            fixtureJPEGEncoder = nil
        }
        stop(userInitiated: true); fixtureProvider = nil; fixtureTime = nil
        if let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: ["fixture": "continuous-generated-handheld", "fixtureRevision": 4, "processID": ProcessInfo.processInfo.processIdentifier, "runID": diagnosticRunID, "controllerStartedAt": controllerStartedAt, "recordedAt": ISO8601DateFormatter().string(from: Date()), "networkRequests": 0, "cameraStarted": false, "sampleIntervalSeconds": 0.25, "sequenceSeconds": 6, "translationPixels": 3, "verticalPixels": 2, "scalePercent": 1.8, "rotationDegrees": 1.2, "brightnessDelta": 0.025, "scenarios": reports], options: [.sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("camera-continuous-fixture.json"), options: .atomic)
        }
    }

    func runDelayedFixture() async {
        guard ProcessInfo.processInfo.arguments.contains("--camera-delayed-fixture") else { return }
        // Every bitmap is generated locally. Reuse frames so this test exercises
        // controller scheduling and delayed completion, not repeated renderer work.
        var generated: [[CameraFrame]] = []
        var visionAvailable = true
        for kind in 0..<3 {
            var variants: [CameraFrame] = []
            for dx in [-8.0, 0.0, 8.0] {
                let rendered = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512)).image { ctx in
                    UIColor(white: 0.93, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
                    (kind == 1 ? UIColor.systemRed : UIColor.systemBlue).setFill(); ctx.fill(CGRect(x: 130+dx, y: 60, width: 250, height: 390))
                    UIColor.white.setFill(); ctx.fill(CGRect(x: 150+dx, y: 180, width: 210, height: 150))
                    ((kind == 2 ? "GLANCE 128" : "GLANCE 123") as NSString).draw(at: CGPoint(x: 157+dx, y: 225), withAttributes: [.font: UIFont.systemFont(ofSize: 28), .foregroundColor: UIColor.black])
                }
                guard let image = rendered.cgImage, let fp = CameraCapture.fingerprint(image) else { return }
                let request = VNGenerateImageFeaturePrintRequest(); var feature: VNFeaturePrintObservation?
                do { try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request]); feature = request.results?.first as? VNFeaturePrintObservation } catch {}
                if feature == nil { visionAvailable = false }
                variants.append(CameraFrame(image: image, fingerprint: fp, feature: feature, labelSignature: CameraCapture.labelDigest([kind == 2 ? "glance128" : "glance123"]), time: 0))
            }
            generated.append(variants)
        }
        var reports: [[String: Any]] = []
        let cases: [(String, Double, Double)] = [("handheld",4,7), ("gap-return",6,10), ("different-object-return",8,12), ("one-digit-return",6,10), ("unknown-return",4,9)]
        fixtureUsesWallClock = true
        for (name, delay, duration) in cases {
            stop(userInitiated: true); beginCaptureRun()
            fixtureTime = 0; running = true; generation = UUID(); nextRequestAt = 0; blocked = false
            let before = requestCount; fixtureRequestLimit = before + 1
            fixtureProvider = { _ in try await Task.sleep(for: .seconds(delay)); return RecognitionResult(names: ["delayed-A"]) }
            let start = ProcessInfo.processInfo.systemUptime
            var stats = CaptureStatistics(); var samples: [[String: Any]] = []
            var wrongVisible = false; var firstVisible: Double?; var nilFrames = 0
            var index = 0
            while ProcessInfo.processInfo.systemUptime - start <= duration {
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                var kind = 0; var absent = false; var missing = false
                if name == "gap-return" && elapsed >= 2 && elapsed < 4 { absent = true }
                if name == "different-object-return" && elapsed >= 2 && elapsed < 9.5 { kind = 1 }
                if name == "one-digit-return" && elapsed >= 2 && elapsed < 7.5 { kind = 2 }
                if name == "unknown-return" && elapsed >= 2 && elapsed < 6 { missing = true }
                let variant = elapsed < 1.25 ? 1 : index.isMultiple(of: 2) ? 0 : 2
                let base = generated[kind][variant]
                stats.frames += 1; stats.samples += 1
                let input: CameraFrame?
                if absent { input = nil; nilFrames += 1 }
                else { stats.accepted += 1; input = CameraFrame(image: base.image, fingerprint: base.fingerprint, feature: base.feature, labelSignature: missing ? "" : base.labelSignature, time: ProcessInfo.processInfo.systemUptime) }
                frame(input, generation: generation, stats: stats)
                if visible != nil {
                    if kind != 0 || absent || missing { wrongVisible = true }
                    if firstVisible == nil { firstVisible = elapsed }
                }
                var sample: [String: Any] = ["elapsedSeconds": elapsed, "input": absent ? "absent" : missing ? "unknown" : kind == 0 ? "original" : kind == 1 ? "different-object" : "different-digit", "visible": visible != nil, "requests": requestCount-before, "stage": pipelineStage, "gate": lastStableGate, "stableMS": lastStableElapsedMS, "matcherMS": lastMatcherMS]
                sample["motionDistance"] = lastMotionDistance; sample["featureDistance"] = lastFeatureDistance
                sample["alignedMotionDistance"] = lastAlignedMotionDistance; sample["motionAlignmentMS"] = lastMotionAlignmentMS
                samples.append(sample); index += 1
                try? await Task.sleep(for: .milliseconds(250))
            }
            await work?.value
            var report: [String: Any] = ["scenario": name, "providerDelaySeconds": delay, "clock": "real-monotonic", "requests": requestCount-before, "firstResultEventuallyVisible": firstVisible != nil, "wrongTargetVisible": wrongVisible, "visibleAtEnd": visible != nil, "nilFrames": nilFrames, "lifecycle": requestDiagnostic(), "runState": captureSummary(), "samples": samples]
            report["firstVisibleSeconds"] = firstVisible
            reports.append(report)
            stop(userInitiated: true)
        }
        fixtureProvider = nil; fixtureRequestLimit = nil; fixtureTime = nil; fixtureUsesWallClock = false
        if let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: ["fixture": "delayed-generated-controller", "fixtureRevision": 2, "processID": ProcessInfo.processInfo.processIdentifier, "runID": diagnosticRunID, "recordedAt": ISO8601DateFormatter().string(from: Date()), "networkRequests": 0, "cameraStarted": false, "visionAvailable": visionAvailable, "visualGate": visionAvailable ? "production" : "bypassed-offline-fixture-only", "labelSource": "controlled-generated-evidence", "translationPixels": 8, "scenarios": reports], options: [.sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("camera-delayed-fixture.json"), options: .atomic)
        }
    }

    private func regionalBitmap(scenario:String,index:Int,changed:Bool,digit:String,dx:Double,scale:CGFloat?=nil,objectScale:Double=1,rotation:Double=0,brightness:Double=0) -> UIImage {
        let format=UIGraphicsImageRendererFormat()
        if let scale { format.scale=scale }
        return UIGraphicsImageRenderer(size:CGSize(width:768,height:768),format:format).image { ctx in

                    UIColor(white:0.92,alpha:1).setFill();ctx.fill(CGRect(x:0,y:0,width:768,height:768))
                    let bg=index.isMultiple(of:2) ? "SALE TODAY" : "NEW ITEMS"
                    (bg as NSString).draw(at:CGPoint(x:20,y:25),withAttributes:[.font:UIFont.systemFont(ofSize:28),.foregroundColor:UIColor.black])
                    ctx.cgContext.translateBy(x:384+dx,y:384)
                    ctx.cgContext.rotate(by:rotation);ctx.cgContext.scaleBy(x:objectScale,y:objectScale)
                    ctx.cgContext.translateBy(x:-384,y:-384)
                    (["different-object","unlabeled-switch"].contains(scenario) && changed ? UIColor.systemRed : UIColor.systemBlue).setFill()
                    ctx.fill(CGRect(x:160,y:115,width:448,height:540))
                    UIColor.white.setFill();ctx.fill(CGRect(x:182,y:190,width:406,height:410))
                    if !scenario.hasPrefix("unlabeled") && !(scenario=="unknown-text" && changed) {
                        ("GLANCE" as NSString).draw(at:CGPoint(x:220,y:225),withAttributes:[.font:UIFont.systemFont(ofSize:42),.foregroundColor:UIColor.black])
                        if !(scenario=="occluded-label" && changed) {
                            let ink:UIColor=scenario=="low-contrast-digit" && changed ? UIColor(white:0.88,alpha:1) : .black
                            (("CODE "+digit) as NSString).draw(at:CGPoint(x:220,y:330),withAttributes:[.font:UIFont.systemFont(ofSize:38),.foregroundColor:ink])
                        }
                        ("500 ml" as NSString).draw(at:CGPoint(x:220,y:430),withAttributes:[.font:UIFont.systemFont(ofSize:32),.foregroundColor:UIColor.black])
                        ("EXP 2028" as NSString).draw(at:CGPoint(x:485,y:570),withAttributes:[.font:UIFont.systemFont(ofSize:24),.foregroundColor:UIColor.black])
                    }
                    if scenario=="unlabeled-occlusion" && changed {
                        UIColor(white:0.35,alpha:1).setFill();ctx.fill(CGRect(x:300,y:250,width:290,height:300))
                    }
                    // Generated barcode stays within the central target. Neither
                    // its payload nor any OCR text is written into the report.
                    if !scenario.hasPrefix("unlabeled"), let filter=CIFilter(name:"CICode128BarcodeGenerator") {
                        filter.setValue(Data("GLANCE123".utf8),forKey:"inputMessage")
                        if let code=filter.outputImage, let cg=CIContext().createCGImage(code,from:code.extent) {
                            UIImage(cgImage:cg).draw(in:CGRect(x:215,y:505,width:280,height:48))
                        }
                    }
                    if brightness != 0 {
                        UIColor(white:brightness>0 ? 1 : 0,alpha:abs(brightness)).setFill()
                        ctx.fill(CGRect(x:-1000,y:-1000,width:3000,height:3000))
                    }
        }
    }


    private func firstCaptureRealTransport(requestID: UUID) -> [String:Any] {
        let raw = SIWCHTTP.shared.diagnostics
        var safe: [String:Any] = ["source":"real-pro", "requestIDMatched":raw["cameraRequestID"] as? String == requestID.uuidString]
        for key in ["operation","phase","httpStatus","terminalEvent","streamCounts","eventCount","receivedBytes",
                    "headersMilliseconds","firstDataMilliseconds","lastDataMilliseconds","terminalMilliseconds","elapsedMilliseconds",
                    "requestTimeoutSeconds","resourceTimeoutSeconds","errorCategory","errorCode","failureStage"] {
            if let value = raw[key] { safe[key] = value }
        }
        return safe
    }

    /// Explicit, bounded generated-data probe. Never starts AVCaptureSession.
    /// It feeds the new frame()/FirstCaptureGate path, not the older imageTest().
    func runFirstCaptureGeneratedProbe(real: Bool) async {
        let args = ProcessInfo.processInfo.arguments
        let requested = args.contains(real ? "--camera-first-capture-generated-real" : "--camera-first-capture-generated-check")
        guard requested, requestCount == 0 else { return }
        stop(userInitiated:true)
        let planReady = account.planAccessReady
        var samples: [[String:Any]] = []
        var preparationFailures = 0
        let started = ProcessInfo.processInfo.systemUptime
        if !real || planReady {
            firstCapture = FirstCaptureGate(limit:1); firstCaptureEvents=[];firstTransportMetrics=[:]
            fixtureTime=nil;fixtureUsesWallClock=true;fixtureJPEGEncoder=nil;fixtureProvider=nil
            if !real {
                fixtureProvider = { [weak self] _ in
                    let wire = #"data: {"type":"response.output_text.delta","delta":"{\"names\":[\"generated\"],\"text\":[],\"barcodes\":[]}"}"# + "\n\n" + #"data: {"type":"response.completed"}"# + "\n\n"
                    let bytes=Array(wire.utf8);var index=0
                    let result=try await SIWCStreamReader.read(nextByte:{
                        guard index<bytes.count else{return nil};defer{index+=1};return bytes[index]
                    },progress:{counts,terminal,_ in self?.firstTransportMetrics=["source":"offline-generated-sse","counts":counts,"terminal":terminal ?? "none"]})
                    return try CameraAnswer.parse(result)
                }
            }
            blocked=false;generation=UUID();running=true;beginCaptureRun()
            let context=CIContext(options:[.cacheIntermediates:false])
            while requestCount == 0 && timeNow()-started < 6 {
                let capturedAt=timeNow()
                let bitmap=regionalBitmap(scenario:"background-text",index:0,changed:false,digit:"123",dx:0,scale:1)
                let format=UIGraphicsImageRendererFormat();format.scale=1
                let full=UIGraphicsImageRenderer(size:CGSize(width:1080,height:1920),format:format).image { ctx in
                    UIColor(white:0.92,alpha:1).setFill();ctx.fill(CGRect(x:0,y:0,width:1080,height:1920))
                    bitmap.draw(in:CGRect(x:118.8,y:538.8,width:842.4,height:842.4))
                }
                do {
                    guard let cg=full.cgImage,let image=CameraCapture.centralImage(CIImage(cgImage:cg),context:context) else {throw CameraCapture.PreparationFailure.invalidCrop}
                    let prepared=try CameraCapture.prepareFirstCapture(image,time:capturedAt)
                    frame(prepared,generation:generation,stats:CaptureStatistics())
                } catch { preparationFailures+=1;frame(nil,generation:generation,stats:CaptureStatistics()) }
                var sample=firstCaptureLastFrame;sample["elapsedSeconds"]=capturedAt-started
                sample["requestCount"]=requestCount;sample["visible"]=visible != nil;samples.append(sample)
                if requestCount == 0 { try? await Task.sleep(for:.milliseconds(250)) }
            }
            await work?.value
        }
        let report: [String:Any] = ["probe":"first-capture-generated-card","revision":1,"mode":real ? "real-pro-once" : "offline-preflight",
            "processID":ProcessInfo.processInfo.processIdentifier,"recordedAt":ISO8601DateFormatter().string(from:Date()),
            "route":"shared centralImage -> prepareFirstCapture -> frame -> FirstCaptureGate -> JPEG -> provider -> SSE -> parse",
            "cameraStarted":false,"planReadyAtStart":planReady,"modelRequestAttempts":real ? requestCount : 0,"providerAttempts":requestCount,
            "maximumModelRequests":1,"automaticRetries":0,"displayEnabled":false,"cacheEnabled":false,"preparationFailures":preparationFailures,
            "samples":samples,"events":firstCaptureEvents,"gate":firstCapture.gate,"durationSeconds":timeNow()-started]
        stop(userInitiated:true);fixtureProvider=nil;fixtureTime=nil;fixtureUsesWallClock=false
        if let root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first,
           let data=try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) {
            try? data.write(to:root.appendingPathComponent(real ? "camera-first-capture-real.json" : "camera-first-capture-preflight.json"),options:.atomic)
        }
    }

    func runFirstCaptureFixture() async {
        guard ProcessInfo.processInfo.arguments.contains("--camera-first-capture-fixture") else { return }
        fixtureUsesWallClock = true; fixtureTime = 0
        let imageContext = CIContext(options: [.cacheIntermediates:false])
        var cases: [(String, Double, Int)] = []
        for name in ["unlabeled-object", "text-appearance", "background-text", "micro-motion"] {
            for (repeatIndex, delay) in [0.0,4.0,8.0].enumerated() { cases.append((name,delay,repeatIndex)) }
        }
        for name in ["switch-before-stable", "blurred", "stale", "frame-gap", "empty", "failed", "cancelled", "restart-budget"] { cases.append((name,name == "cancelled" ? 8 : 0,0)) }
        var reports: [[String:Any]] = []
        for (name, delay, repeatIndex) in cases {
            stop(userInitiated:true); await work?.value
            firstCapture = FirstCaptureGate(); firstCaptureEvents = []; firstTransportMetrics = [:]
            fixtureUsesWallClock = true; fixtureTime = 0; blocked = false
            generation = UUID(); running = true; beginCaptureRun()
            let before = requestCount
            fixtureProvider = { [weak self] jpeg in
                guard !jpeg.isEmpty else { throw SIWCError.invalidResponse }
                try await Task.sleep(for:.seconds(delay))
                let answer = name == "empty" ? #"{"names":[],"text":[],"barcodes":[]}"# : #"{"names":["generated"],"text":[],"barcodes":[]}"#
                let delta = try JSONSerialization.data(withJSONObject:["type":"response.output_text.delta","delta":answer],options:[.sortedKeys])
                var wire = "data: " + String(decoding:delta,as:UTF8.self) + "\n\n"
                wire += name == "failed" ? #"data: {"type":"response.failed","response":{"error":{"code":"generated_test"}}}"# + "\n\n" : #"data: {"type":"response.completed"}"# + "\n\n"
                let bytes = Array(wire.utf8); var cursor = 0
                let result = try await SIWCStreamReader.read(nextByte:{
                    guard cursor < bytes.count else { return nil }
                    defer { cursor += 1 }; return bytes[cursor]
                },progress:{ counts, terminal, _ in
                    self?.firstTransportMetrics = ["source":"offline-generated-sse","counts":counts,"terminal":terminal ?? "none"]
                })
                return try CameraAnswer.parse(result)
            }
            let start = timeNow(); var index = 0; var samples: [[String:Any]] = []
            var failures = 0, canceled = false
            let duration = ["blurred","stale","frame-gap"].contains(name) ? 1.95 : 2.75
            while timeNow()-start < duration {
                let capturedAt = timeNow(); let elapsed = capturedAt-start
                let dx = name == "micro-motion" ? sin(Double(index)*0.7)*4 : 0
                let scenario = name == "unlabeled-object" ? "unlabeled-object" : name == "switch-before-stable" ? "different-object" : "background-text"
                let bitmap = regionalBitmap(scenario:scenario,index:name == "background-text" ? index : 0,changed:name == "switch-before-stable" && elapsed>=0.5,digit:"123",dx:dx,scale:1)
                let format=UIGraphicsImageRendererFormat();format.scale=1
                let full=UIGraphicsImageRenderer(size:CGSize(width:1080,height:1920),format:format).image { ctx in
                    UIColor(white:0.92,alpha:1).setFill();ctx.fill(CGRect(x:0,y:0,width:1080,height:1920))
                    bitmap.draw(in:CGRect(x:118.8,y:538.8,width:842.4,height:842.4))
                }
                var source=CIImage(cgImage:full.cgImage!)
                if name == "blurred" || name == "text-appearance" {
                    let radius:Double = name == "blurred" ? 64 : Double(index%3)*0.4
                    source=source.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius]).cropped(to:source.extent)
                }
                var stats=CaptureStatistics();stats.frames=index+1;stats.samples=index+1
                do {
                    guard let image=CameraCapture.centralImage(source,context:imageContext) else { throw CameraCapture.PreparationFailure.invalidCrop }
                    let prepared=try CameraCapture.prepareFirstCapture(image,time:name == "stale" ? capturedAt-1 : capturedAt)
                    stats.accepted=1;stats.localProcessingMS=(timeNow()-capturedAt)*1000
                    frame(prepared,generation:generation,stats:stats)
                } catch { failures += 1;frame(nil,generation:generation,stats:stats) }
                var sample=firstCaptureLastFrame
                sample["elapsedSeconds"]=elapsed;sample["requestCount"]=requestCount-before;sample["visible"]=visible != nil
                samples.append(sample);index += 1
                if name == "cancelled", requestCount > before, elapsed>=1.6 { let pending = work; stop(userInitiated:true); await pending?.value; canceled=true;break }
                try? await Task.sleep(for:.milliseconds(name == "frame-gap" && index==2 ? 850 : 250))
            }
            await work?.value
            if name == "restart-budget" {
                stop(userInitiated:true);generation=UUID();running=true
                let again=timeNow()
                while timeNow()-again < 1.5 {
                    let now=timeNow()
                    let bitmap=regionalBitmap(scenario:"unlabeled-object",index:0,changed:false,digit:"123",dx:0,scale:1)
                    let format=UIGraphicsImageRendererFormat();format.scale=1
                    let full=UIGraphicsImageRenderer(size:CGSize(width:1080,height:1920),format:format).image { ctx in
                        UIColor(white:0.92,alpha:1).setFill();ctx.fill(CGRect(x:0,y:0,width:1080,height:1920))
                        bitmap.draw(in:CGRect(x:118.8,y:538.8,width:842.4,height:842.4))
                    }
                    if let cg=full.cgImage,let image=CameraCapture.centralImage(CIImage(cgImage:cg),context:imageContext),let prepared=try? CameraCapture.prepareFirstCapture(image,time:now) { frame(prepared,generation:generation,stats:CaptureStatistics()) }
                    try? await Task.sleep(for:.milliseconds(250))
                }
            }
            var report: [String:Any] = ["scenario":name,"repeat":repeatIndex,"providerDelaySeconds":delay,"requests":requestCount-before,
                "preparationFailures":failures,"samples":samples,"events":firstCaptureEvents,"gate":firstCapture.gate,
                "displayed":visible != nil,"cancelTriggered":canceled,"sentBudget":firstCapture.sentCount]
            report["firstRequestSeconds"]=(firstCaptureEvents.first?["startedAt"] as? Double).map { $0-start }
            reports.append(report);stop(userInitiated:true)
        }
        fixtureProvider=nil;fixtureTime=nil;fixtureUsesWallClock=false
        if let root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first,
           let data=try? JSONSerialization.data(withJSONObject:["fixture":"first-capture-production-path","revision":1,"processID":ProcessInfo.processInfo.processIdentifier,
               "recordedAt":ISO8601DateFormatter().string(from:Date()),"cameraStarted":false,"networkRequests":0,
               "input":"generated 1080x1920 pixels through shared 78 percent central crop and max768 preparation","clock":"real-monotonic",
               "displayEnabled":false,"cacheEnabled":false,"budgetScope":"fresh gate per case; restart-budget preserves one gate across stop/start","cases":reports],options:[.sortedKeys]) {
            try? data.write(to:root.appendingPathComponent("camera-first-capture-fixture.json"),options:.atomic)
        }
    }

    func runOfficialVisionBaseline() async {
        guard ProcessInfo.processInfo.arguments.contains("--camera-vision-baseline") else { return }
        stop(userInitiated:true)
        let clock={ProcessInfo.processInfo.systemUptime}
        let context=CIContext(options:[.cacheIntermediates:false])
        let base=CGRect(x:160,y:115,width:448,height:540)
        let seed=CGRect(x:base.minX/768,y:(768-base.maxY)/768,width:base.width/768,height:base.height/768)
        var cases:[[String:Any]]=[]
        let names=["static","text-micro","unlabeled-micro","scale","rotation","exit-return","full-occlusion-return","partial-label-occlusion","different-object","similar-digit","unlabeled-switch"]
        for fps in [15,30] {
            for name in names {
                let tracker=VisionBaselineSession(seed:seed)
                let start=clock(),duration=3.4,period=1/Double(fps)
                var nextSlot=0,dropped=0
                var samples:[[String:Any]]=[]
                var lifecycleEnded=false
                var lastCapture:Double?
                while clock()-start<duration {
                    let desired=start+Double(nextSlot)*period
                    if clock()<desired { try? await Task.sleep(for:.seconds(desired-clock())) }
                    let captured=clock(),elapsed=captured-start
                    if elapsed>=duration { break }
                    let slot=max(nextSlot,Int(floor(elapsed/period)))
                    let skipped=slot-nextSlot;dropped+=skipped;nextSlot=slot+1
                    let changed=elapsed>=1.2
                    var dx:Double=0,scale:Double=1,angle:Double=0
                    if name.contains("micro") { dx=sin(elapsed*2 * .pi)*8 }
                    if name=="scale" { scale=1+sin(elapsed*2.2)*0.04 }
                    if name=="rotation" { angle=sin(elapsed*2.2)*3 * .pi/180 }
                    if name=="exit-return" {
                        if elapsed>=0.8 && elapsed<1.8 { dx=(elapsed-0.8)*950 }
                        else if elapsed>=1.8 && elapsed<2.6 { dx=950 }
                    }
                    let fullCover=name=="full-occlusion-return" && elapsed>=1.2 && elapsed<2.6
                    let partial=name=="partial-label-occlusion" && changed
                    let replaced=["different-object","similar-digit","unlabeled-switch"].contains(name) && changed
                    let scene=name.hasPrefix("unlabeled") ? name : name=="different-object" ? "different-object" : "background-text"
                    let bitmap=regionalBitmap(scenario:scene,index:0,changed:replaced,digit:name=="similar-digit" && changed ? "128" : "123",dx:dx,scale:1,objectScale:scale,rotation:angle)
                    let format=UIGraphicsImageRendererFormat();format.scale=1
                    let decorated=UIGraphicsImageRenderer(size:CGSize(width:768,height:768),format:format).image { ctx in
                        bitmap.draw(at:.zero)
                        if fullCover { UIColor(white:0.4,alpha:1).setFill();ctx.fill(CGRect(x:140,y:95,width:488,height:580)) }
                        if partial { UIColor(white:0.4,alpha:1).setFill();ctx.fill(CGRect(x:205,y:325,width:340,height:60)) }
                    }
                    let full=UIGraphicsImageRenderer(size:CGSize(width:1080,height:1920),format:format).image { ctx in
                        UIColor(white:0.92,alpha:1).setFill();ctx.fill(CGRect(x:0,y:0,width:1080,height:1920))
                        decorated.draw(in:CGRect(x:118.8,y:538.8,width:842.4,height:842.4))
                    }
                    let transformed=base.applying(CGAffineTransform(translationX:384+dx,y:384).rotated(by:angle).scaledBy(x:scale,y:scale).translatedBy(x:-384,y:-384))
                    let rawTruth=CGRect(x:transformed.minX/768,y:(768-transformed.maxY)/768,width:transformed.width/768,height:transformed.height/768)
                    let truth=rawTruth.intersection(CGRect(x:0,y:0,width:1,height:1))
                    let visibleFraction=truth.isNull ? 0 : truth.width*truth.height/(rawTruth.width*rawTruth.height)
                    let referenceContentAvailable=visibleFraction>=0.95 && !fullCover && !partial && !replaced
                    if (name=="exit-return" && visibleFraction<=0.01) || fullCover || replaced || partial { lifecycleEnded=true }
                    let gap=lastCapture.map { captured-$0 } ?? 0;lastCapture=captured
                    var row:[String:Any]=["elapsedSeconds":elapsed,"slot":slot,"skippedBefore":skipped,"gapMS":gap*1000,"generatedDX":dx,"generatedScale":scale,"generatedRotationDegrees":angle*180 / .pi,"visibleFraction":visibleFraction,"referenceContentAvailable":referenceContentAvailable,"groundTruthEpisodeEnded":lifecycleEnded,"knownFullOcclusion":fullCover,"knownPartialOcclusion":partial,"knownReplacement":replaced]
                    if let image=CameraCapture.centralImage(CIImage(cgImage:full.cgImage!),context:context) {
                        let prepared=clock();row["width"]=image.width;row["height"]=image.height
                        row["generationAndCentralCropMS"]=(prepared-captured)*1000
                        let result=await tracker.process(VisionBaselineImage(image))
                        let finished=clock(),age=finished-captured
                        row["visionMS"]=result.visionMS;row["revision"]=result.revision;row["processed"]=result.processed
                        row["terminal"]=result.terminal;row["reason"]=result.reason;row["frameAgeMS"]=age*1000;row["fresh750ms"]=age<=0.75
                        row["confidence"]=result.confidence.map { Double($0) }
                        row["exampleSolidStyle"]=result.confidence.map { $0>0.5 } ?? false
                        row["trackerRetained"]=result.processed && !result.terminal
                        row["unsafeRetentionIfConfidenceAlone"]=lifecycleEnded && result.processed && !result.terminal
                        if let b=result.box {
                            row["box"]=[Double(b.minX),Double(b.minY),Double(b.width),Double(b.height)]
                            if !truth.isNull {
                                let intersection=b.intersection(truth)
                                let area=intersection.isNull ? 0 : intersection.width*intersection.height
                                let union=b.width*b.height+truth.width*truth.height-area
                                row["iouWithGeneratedBounds"]=union>0 ? Double(area/union) : 0
                                row["centerErrorPixels"]=Double(hypot(b.midX-truth.midX,b.midY-truth.midY)*768)
                            }
                        }
                    } else { row["errorCategory"]="central-image-failed" }
                    samples.append(row)
                }
                cases.append(["scenario":name,"nominalFPS":fps,"elapsedSeconds":clock()-start,"sampledFrames":samples.count,"skippedSlots":dropped,"maximumInflight":1,"seed":[Double(seed.minX),Double(seed.minY),Double(seed.width),Double(seed.height)],"samples":samples])
            }
        }
        if let root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first,
           let data=try? JSONSerialization.data(withJSONObject:["fixture":"official-vision-tracker-baseline","revision":1,"processID":ProcessInfo.processInfo.processIdentifier,"recordedAt":ISO8601DateFormatter().string(from:Date()),"cameraStarted":false,"networkRequests":0,"displayEnabled":false,"cacheEnabled":false,"seed":"known tight generated object bounds, analogous to official manual nomination; no per-frame crop or saliency","coordinates":"shared full768 central image, up orientation, normalized bottom-left Vision boxes","clock":"real monotonic; serial background Vision; latest scheduled slot only; synthetic slots, not independent camera producer","appearanceGate":"none; confidence0.5 recorded only as official example style; no reseed after terminal","cases":cases],options:[.sortedKeys]) {
            try? data.write(to:root.appendingPathComponent("camera-vision-baseline.json"),options:.atomic)
        }
    }

    func runGeometryProfile() async {
        guard ProcessInfo.processInfo.arguments.contains("--camera-geometry-profile") else { return }
        stop(userInitiated:true)
        let clock={ProcessInfo.processInfo.systemUptime}
        let context=CIContext(options:[.cacheIntermediates:false])
        var rows:[[String:Any]]=[]
        func generated(_ scenario:String,dx:Double=0,scale:Double=1,rotation:Double=0,digit:String="123") throws -> CGImage {
            let bitmap=regionalBitmap(scenario:scenario,index:0,changed:false,digit:digit,dx:dx,scale:1,objectScale:scale,rotation:rotation)
            let format=UIGraphicsImageRendererFormat();format.scale=1
            let full=UIGraphicsImageRenderer(size:CGSize(width:1080,height:1920),format:format).image { ctx in
                UIColor(white:0.92,alpha:1).setFill();ctx.fill(CGRect(x:0,y:0,width:1080,height:1920))
                bitmap.draw(in:CGRect(x:118.8,y:538.8,width:842.4,height:842.4))
            }
            guard let image=CameraCapture.centralImage(CIImage(cgImage:full.cgImage!),context:context) else { throw CameraCapture.PreparationFailure.invalidCrop }
            return image
        }
        for name in ["identical-cold","identical-warm","whole-image-translation","object-only-translation","bare-object-translation","object-scale","object-rotation","one-digit","identical-tail"] {
            do {
                let scenario=name=="bare-object-translation" ? "unlabeled-object" : "background-text"
                let reference=try generated(scenario)
                let capturedAt=clock()
                let image:CGImage
                if name.hasPrefix("identical") { image=reference }
                else if name=="whole-image-translation" {
                    let ci=CIImage(cgImage:reference)
                    guard let shifted=context.createCGImage(ci.transformed(by:CGAffineTransform(translationX:4,y:0)),from:ci.extent) else { throw CameraCapture.PreparationFailure.invalidCrop }
                    image=shifted
                } else {
                    image=try generated(scenario,dx:name.contains("translation") ? 4 : 0,scale:name=="object-scale" ? 1.02 : 1,rotation:name=="object-rotation" ? 2 * .pi/180 : 0,digit:name=="one-digit" ? "128" : "123")
                }
                let generatedAt=clock()
                _=try CameraCapture.prepareFirstCapture(image,time:capturedAt)
                let preparedAt=clock()
                let request=VNTranslationalImageRegistrationRequest(targetedCGImage:image,options:[:],completionHandler:nil)
                try VNImageRequestHandler(cgImage:reference,orientation:.up).perform([request])
                guard let observation=request.results?.first else { throw CameraCapture.PreparationFailure.featureUnavailable }
                let registeredAt=clock(),transform=observation.alignmentTransform
                let fixed=CIImage(cgImage:reference),floating=CIImage(cgImage:image).transformed(by:transform)
                let common=fixed.extent.intersection(floating.extent).insetBy(dx:1,dy:1)
                let info:[String:Any]=["scenario":name,"width":image.width,"height":image.height,"translationX":Double(transform.tx),"translationY":Double(transform.ty),"generationMS":(generatedAt-capturedAt)*1000,"preparationMS":(preparedAt-generatedAt)*1000,"registrationMS":(registeredAt-preparedAt)*1000,"postRegistrationAgeMS":(registeredAt-capturedAt)*1000,"commonFraction":common.width*common.height/(768*768)]
                for (regionName,region,sides) in [("full",common,[256,128,32]),("known-object-only-diagnostic",common.intersection(CGRect(x:150,y:100,width:470,height:570)),[256])] {
                    let cropStart=clock()
                    guard let a=context.createCGImage(floating,from:region),let b=context.createCGImage(fixed,from:region) else { throw CameraCapture.PreparationFailure.invalidCrop }
                    let cropMS=(clock()-cropStart)*1000
                    for side in sides {
                        let fpStart=clock()
                        guard let currentPixels=CameraCapture.fingerprint(a,side:side),let referencePixels=CameraCapture.fingerprint(b,side:side) else { throw CameraCapture.PreparationFailure.invalidCrop }
                        let fpEnd=clock()
                        let evidence=DisplayPixelEvidence(current:currentPixels,reference:referencePixels)
                        let comparedAt=clock()
                        var row=info
                        row["region"]=regionName;row["side"]=side;row["cropMS"]=cropMS
                        row["fingerprintsMS"]=(fpEnd-fpStart)*1000;row["comparisonMS"]=(comparedAt-fpEnd)*1000
                        row["distance"]=Double(evidence.distance);row["globalDistance"]=Double(evidence.globalDistance)
                        row["maximumLocalDifference"]=Double(evidence.maximumLocalDifference);row["pixelMatches"]=evidence.matches
                        row["patchWidthInSourcePixels"]=region.width*3/Double(side)
                        row["patchHeightInSourcePixels"]=region.height*3/Double(side)
                        row["ageIncludingEarlierDiagnosticArmsMS"]=(comparedAt-capturedAt)*1000
                        row["firstProductionSizedArm"]=regionName=="full" && side==256
                        if regionName=="full" && side==256 { row["productionArmFresh"]=(comparedAt-capturedAt)<=0.75 }
                        rows.append(row)
                    }
                }
            } catch { rows.append(["scenario":name,"errorCategory":String(describing:type(of:error))+":"+String(describing:error)]) }
            try? await Task.sleep(for:.milliseconds(250))
        }
        #if DEBUG
        let buildMode="Debug-Onone"
        #else
        let buildMode="non-DEBUG-check-build-settings"
        #endif
        if let root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first,
           let data=try? JSONSerialization.data(withJSONObject:["fixture":"geometry-timing-profile","revision":1,"processID":ProcessInfo.processInfo.processIdentifier,"recordedAt":ISO8601DateFormatter().string(from:Date()),"buildMode":buildMode,"cameraStarted":false,"networkRequests":0,"displayEnabled":false,"cacheEnabled":false,"scope":"nine generated pairs; production256 arm first; other resolutions and known-object region diagnostic only, not frame-age acceptance","rows":rows],options:[.sortedKeys]) {
            try? data.write(to:root.appendingPathComponent("camera-geometry-profile.json"),options:.atomic)
        }
    }

    func runCurrentImageFixture() async {
        guard ProcessInfo.processInfo.arguments.contains("--camera-current-image-fixture") else { return }
        stop(userInitiated:true)
        let context=CIContext(options:[.cacheIntermediates:false])
        let names=["text-static","text-micro-motion","unlabeled-micro-motion","text-scale","unlabeled-scale","text-rotation","unlabeled-rotation","text-lighting","unlabeled-lighting","different-object","same-region-digit","occluded-label","unlabeled-occlusion","edge-change"]
        let negatives=["different-object","same-region-digit","occluded-label","unlabeled-occlusion","edge-change"]
        var rows:[[String:Any]]=[]
        for name in names {
            var reference:CGImage?
            var referenceTime:Double?
            for index in 0..<9 {
                let capturedAt=ProcessInfo.processInfo.systemUptime
                let modified=negatives.contains(name) && index>=4
                let phase=Double(index)*0.8
                let dx=name.contains("micro-motion") ? sin(phase)*4 : 0
                let objectScale=name.contains("scale") ? 1+sin(phase)*0.02 : 1
                let rotation=name.contains("rotation") ? sin(phase)*2 * .pi/180 : 0
                let exposureEV=name.contains("lighting") ? sin(phase)*0.1 : 0
                let bitmap=regionalBitmap(scenario:name,index:0,changed:modified,digit:name=="same-region-digit" && modified ? "128" : "123",dx:dx,scale:1,objectScale:objectScale,rotation:rotation)
                let format=UIGraphicsImageRendererFormat();format.scale=1
                let decorated=UIGraphicsImageRenderer(size:CGSize(width:768,height:768),format:format).image { ctx in
                    bitmap.draw(at:.zero)
                    if name=="edge-change",modified {
                        UIColor.black.setFill();ctx.fill(CGRect(x:0,y:340,width:5,height:70))
                    }
                }
                let full=UIGraphicsImageRenderer(size:CGSize(width:1080,height:1920),format:format).image { ctx in
                    UIColor(white:0.92,alpha:1).setFill();ctx.fill(CGRect(x:0,y:0,width:1080,height:1920))
                    decorated.draw(in:CGRect(x:118.8,y:538.8,width:842.4,height:842.4))
                }
                var source=CIImage(cgImage:full.cgImage!)
                if exposureEV != 0 { source=source.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:exposureEV]).cropped(to:source.extent) }
                var row:[String:Any]=["scenario":name,"index":index,"modified":modified,"expectedMatch":!modified,"capturedAt":capturedAt,"dx":dx,"scale":objectScale,"rotationRadians":rotation,"exposureEV":exposureEV,"sourceWidth":full.cgImage!.width,"sourceHeight":full.cgImage!.height]
                do {
                    guard let image=CameraCapture.centralImage(source,context:context) else { throw CameraCapture.PreparationFailure.invalidCrop }
                    let prepared=try CameraCapture.prepareFirstCapture(image,time:capturedAt)
                    row["width"]=image.width;row["height"]=image.height
                    row["preparationMS"]=(ProcessInfo.processInfo.systemUptime-capturedAt)*1000
                    if let reference,let referenceTime {
                        let evidence=try CameraCapture.compareCurrentImage(prepared.image,to:reference,context:context)
                        let age=ProcessInfo.processInfo.systemUptime-capturedAt
                        row["referenceCapturedAt"]=referenceTime;row["frameAgeMS"]=age*1000
                        row["fresh"]=age<=0.75;row["pixelMatches"]=evidence.pixels.matches
                        row["matches"]=age<=0.75 && evidence.pixels.matches
                        row["distance"]=Double(evidence.pixels.distance)
                        row["globalDistance"]=Double(evidence.pixels.globalDistance)
                        row["maximumLocalDifference"]=Double(evidence.pixels.maximumLocalDifference)
                        row["translationX"]=evidence.translationX;row["translationY"]=evidence.translationY
                        row["commonFraction"]=evidence.commonFraction;row["comparisonMS"]=evidence.processingMS
                    } else {
                        let age=ProcessInfo.processInfo.systemUptime-capturedAt
                        row["frameAgeMS"]=age*1000;row["fresh"]=age<=0.75
                        if age<=0.75 && !modified { reference=prepared.image;referenceTime=capturedAt;row["anchor"]=true }
                        else { row["anchor"]=false;row["errorCategory"]="no-fresh-reference" }
                    }
                } catch {
                    row["errorCategory"]=String(describing:type(of:error))+":"+String(describing:error)
                    row["matches"]=false;row["frameAgeMS"]=(ProcessInfo.processInfo.systemUptime-capturedAt)*1000
                }
                rows.append(row)
                try? await Task.sleep(for:.milliseconds(250))
            }
        }
        if let root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first,
           let data=try? JSONSerialization.data(withJSONObject:["fixture":"current-image-discrimination","revision":1,"processID":ProcessInfo.processInfo.processIdentifier,
               "recordedAt":ISO8601DateFormatter().string(from:Date()),"cameraStarted":false,"networkRequests":0,"displayEnabled":false,"cacheEnabled":false,
               "input":"generated1080x1920 shared78percent central crop max768 prepareFirstCapture","clock":"real-monotonic","reference":"first fresh prepared frame per case; never replaced","rows":rows],options:[.sortedKeys]) {
            try? data.write(to:root.appendingPathComponent("camera-current-image-fixture.json"),options:.atomic)
        }
    }

    func runROITrace() async {
        guard ProcessInfo.processInfo.arguments.contains("--camera-roi-trace") else { return }
        stop(userInitiated:true)
        var reports:[[String:Any]]=[]
        for scenario in ["unlabeled-translation","unlabeled-scale","unlabeled-rotation","unlabeled-lighting","unlabeled-switch","same-region-digit","occluded-label","unlabeled-occlusion"] {
            let scale:CGFloat=1
            let sequenceStart=ProcessInfo.processInfo.systemUptime
            var first:[String:CameraFrame]=[:], previous:[String:CameraFrame]=[:]
            let trackingSequence=VNSequenceRequestHandler();var tracked:VNDetectedObjectObservation?
            for index in 0..<8 {
                let dx=sin(Double(index)*0.7)*4
                let negative=["unlabeled-switch","same-region-digit","occluded-label","unlabeled-occlusion"].contains(scenario)
                let modified=negative && index>=4
                let objectScale=scenario=="unlabeled-scale" ? 1+sin(Double(index)*0.8)*0.02 : 1
                let rotation=scenario=="unlabeled-rotation" ? sin(Double(index)*0.8)*2 * .pi/180 : 0
                let brightness=scenario=="unlabeled-lighting" ? sin(Double(index)*0.8)*0.035 : 0
                let bitmap=regionalBitmap(scenario:scenario,index:index,changed:modified,digit:scenario=="same-region-digit" && modified ? "128" : "123",dx:dx,scale:1,objectScale:objectScale,rotation:rotation,brightness:brightness)
                guard let image=bitmap.cgImage else { continue }
                let sourceCapturedAt=ProcessInfo.processInfo.systemUptime
                for arm in ["auto-crop","tracked-crop"] {
                    var row:[String:Any]=["scenario":scenario,"rendererScale":scale,"sourceWidth":image.width,"sourceHeight":image.height,"sample":index,"arm":arm,"knownModifiedTarget":modified,"objectScale":objectScale,"rotationDegrees":rotation*180 / .pi,"brightness":brightness,"frameStartSeconds":sourceCapturedAt-sequenceStart]
                    do {
                        let armStart=ProcessInfo.processInfo.systemUptime
                        let known=CGRect(x:(160+dx)/768,y:(768-655)/768.0,width:448/768.0,height:540/768.0)
                        var nextTracked=tracked
                        var region: CGRect?=arm=="known-crop" ? known : nil
                        if arm=="tracked-crop", let tracked {
                            let request=VNTrackObjectRequest(detectedObjectObservation:tracked);request.trackingLevel = .accurate
                            try trackingSequence.perform([request],on:image,orientation:.up)
                            guard let observation=request.results?.first as? VNDetectedObjectObservation else { throw CameraCapture.PreparationFailure.noCentralObject }
                            region=observation.boundingBox
                            row["trackingConfidence"]=observation.confidence
                            row["trackingBounds"]=[Double(region!.minX),Double(region!.minY),Double(region!.width),Double(region!.height)]
                            // carry the actual observation into the next sequence request
                            nextTracked=observation
                        }
                        let prepared=try CameraCapture.prepareTarget(image,time:sourceCapturedAt,diagnosticRegion:region,fixedCanvas:arm=="fixed-canvas-mask")
                        if arm=="auto-crop", tracked==nil { tracked=VNDetectedObjectObservation(boundingBox:prepared.crop) }
                        if arm=="tracked-crop" { tracked=nextTracked }
                        let current=prepared.frame
                        row["roi"]=[Double(prepared.crop.minX),Double(prepared.crop.minY),Double(prepared.crop.width),Double(prepared.crop.height)]
                        row["targetWidth"]=current.image.width;row["targetHeight"]=current.image.height
                        row["readableLines"]=prepared.reading.regional.lines.filter { $0.confidence>=0.5 }.count
                        row["minimumConfidence"]=prepared.reading.regional.lines.map(\.confidence).min()
                        row["processingMS"]=prepared.stageMS["total"]
                        row["inputAgeMS"]=(ProcessInfo.processInfo.systemUptime-sourceCapturedAt)*1000
                        row["meetsProductionFrameAge"]=(ProcessInfo.processInfo.systemUptime-sourceCapturedAt)<=0.75
                        if let initial=first[arm] {
                            let spatial=current.fingerprint.distance(to:initial.fingerprint)
                            row["spatialToFirst"]=spatial
                            row["passesTrackedSpatialGate"]=arm=="tracked-crop" && spatial<=0.035 && ((row["trackingConfidence"] as? Float) ?? 0)>0
                            if let a=current.feature,let b=initial.feature {
                                var distance:Float=0;try a.computeDistance(&distance,to:b)
                                row["featureToFirst"]=distance;row["passesExistingUnlabeledIdentityGates"]=spatial<=0.035 && FeatureEvidence.accepts(distance,identicalReadableLabel:false)
                            }
                            let initialText=initial.regionalText ?? RegionalText(lines:[]), currentText=current.regionalText ?? RegionalText(lines:[])
                            let complete=currentText.compare(to:initialText).resultCompatible
                            row["completeRegionalEvidence"]=complete
                            let semanticOK=initialText.lines.isEmpty && currentText.lines.isEmpty || complete
                            row["passesTrackingPixelsAndExistingSemantics"]=(row["passesTrackedSpatialGate"] as? Bool)==true && semanticOK && (row["meetsProductionFrameAge"] as? Bool)==true
                            row["semanticConflictCount"]=currentText.compare(to:initialText).conflicts
                            row["weakCandidateEqualsInitialText"]=currentText.lines.filter { $0.confidence<0.5 }.allSatisfy { line in initialText.lines.contains { $0.text==line.text && $0.box.comparable(line.box) } }
                        } else { first[arm]=current }
                        if let last=previous[arm] { row["rawMotion"]=current.fingerprint.distance(to:last.fingerprint,allowRotation:false,allowTranslation:false) }
                        previous[arm]=current
                    } catch { row["errorDomain"]=(error as NSError).domain;row["errorCode"]=(error as NSError).code }
                    reports.append(row)
                }
                try? await Task.sleep(for:.milliseconds(250))
            }
        }
        if let root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first,
           let data=try? JSONSerialization.data(withJSONObject:["fixture":"tracking-feasibility-768","revision":1,"representationScope":"two serial diagnostic arms; independent real processing age, not production throughput","processID":ProcessInfo.processInfo.processIdentifier,"recordedAt":ISO8601DateFormatter().string(from:Date()),"cameraStarted":false,"networkRequests":0,"geometry":"automatic saliency seed plus actual VNTrackObjectRequest; no known-box injection","rows":reports],options:[.sortedKeys]) {
            try? data.write(to:root.appendingPathComponent("camera-roi-trace.json"),options:.atomic)
        }
    }

    func runRegionalFixture() async {
        guard ProcessInfo.processInfo.arguments.contains("--camera-regional-fixture") else { return }
        #if targetEnvironment(simulator)
        let allowMissingFeature=true
        #else
        let allowMissingFeature=false
        #endif
        let cases=["background-text", "occluded-label", "low-contrast-digit", "same-region-digit", "unknown-text", "different-object", "unlabeled-object", "unlabeled-switch"]
        var reports:[[String:Any]]=[]
        fixtureUsesWallClock=true
        for scenario in cases {
            stop(userInitiated:true);beginCaptureRun()
            fixtureTime=0;running=true;generation=UUID();nextRequestAt=0;blocked=false
            let before=requestCount;fixtureRequestLimit=before+1
            fixtureProvider={ _ in try await Task.sleep(for:.seconds(4));return RecognitionResult(names:["generated-original"],text:["generated-text"],barcodes:["generated-barcode"]) }
            let start=ProcessInfo.processInfo.systemUptime
            var stats=CaptureStatistics(), samples:[[String:Any]]=[]
            var wrongVisible=false, firstVisible:Double?, previousSource:String?, previousTarget:String?
            var sourceChanges=0,targetChanges=0, failures=0, visionMissing=0, lowConfidenceFrames=0
            var firstPrepared:Double?
            var index=0
            while ProcessInfo.processInfo.systemUptime-start < 12 {
                let elapsed=ProcessInfo.processInfo.systemUptime-start
                let changed=elapsed>=2 && elapsed<7
                let unsafe=changed && !["background-text","unlabeled-object"].contains(scenario)
                let digit=changed && ["low-contrast-digit","same-region-digit"].contains(scenario) ? "128" : "123"
                let dx=sin(Double(index)*0.7)*4
                let bitmap=regionalBitmap(scenario:scenario,index:index,changed:changed,digit:digit,dx:dx)
                stats.frames += 1;stats.samples += 1
                var sample:[String:Any]=["elapsedSeconds":elapsed,"modifiedTarget":unsafe]
                do {
                    guard let image=bitmap.cgImage else { throw CameraCapture.PreparationFailure.invalidCrop }
                    let preparingAt=timeNow()
                    let prepared=try CameraCapture.prepareTarget(image,time:preparingAt,allowMissingFeature:allowMissingFeature)
                    stats.localProcessingMS=(timeNow()-preparingAt)*1000
                    sample["preparationMS"]=stats.localProcessingMS
                    sample["preparationStagesMS"]=prepared.stageMS
                    if firstPrepared==nil { firstPrepared=timeNow()-start }
                    if prepared.frame.feature==nil { visionMissing += 1 }
                    let confidence=prepared.reading.regional.lines.map(\.confidence).min()
                    if let confidence, confidence<0.8 { lowConfidenceFrames += 1 }
                    if let previousSource, previousSource != prepared.sourceSignature { sourceChanges += 1 }
                    if let previousTarget, previousTarget != prepared.reading.signature { targetChanges += 1 }
                    previousSource=prepared.sourceSignature;previousTarget=prepared.reading.signature
                    sample["cropFraction"]=Double(prepared.crop.width*prepared.crop.height)
                    sample["includedTextBoxes"]=prepared.includedTextBoxes;sample["includedBarcodeBoxes"]=prepared.includedBarcodeBoxes
                    sample["ocrCandidates"]=prepared.reading.candidateCount;sample["minimumConfidence"]=confidence
                    sample["readableLines"]=prepared.reading.regional.lines.filter { $0.confidence>=0.5 }.count
                    // Expected strings are used only as assertions after actual OCR.
                    // They are never substituted into evidence supplied to frame().
                    let observed=Set(prepared.reading.regional.lines.filter { $0.confidence>=0.5 }.map(\.text))
                    sample["generatedMainLabelRead"]=observed.contains("glance")
                    sample["generatedEdgeLabelRead"]=observed.contains("exp2028")
                    sample["generatedDigitRead"]=observed.contains("code"+digit)
                    sample["rawGeneratedDigitRead"]=prepared.reading.regional.lines.contains { $0.text=="code"+digit }
                    sample["originalDigitCandidateConfidence"]=prepared.reading.regional.lines.filter { $0.text=="code123" }.map(\.confidence).max()
                    sample["generatedDigitCandidateConfidence"]=prepared.reading.regional.lines.filter { $0.text=="code"+digit }.map(\.confidence).max()
                    let controllerStart=timeNow()

                    stats.accepted += 1
                    frame(prepared.frame,generation:generation,stats:stats)
                    sample["controllerMS"]=(timeNow()-controllerStart)*1000
                } catch {
                    failures += 1;stats.visionRejected += 1;sample["preparationFailed"]=true
                    frame(nil,generation:generation,stats:stats)
                }
                if visible != nil { if unsafe { wrongVisible=true };if firstVisible==nil { firstVisible=timeNow()-start } }
                sample["observedAtSeconds"]=timeNow()-start
                sample["visible"]=visible != nil;sample["requestCount"]=requestCount-before
                sample["identityDecision"]=memory.lastDecision;sample["textDecision"]=memory.lastTextDecision
                sample["gate"]=lastStableGate;sample["stableMS"]=lastStableElapsedMS
                sample["resultEvidenceAllowed"]=lastResultEvidenceAllowed
                samples.append(sample);index += 1
                try? await Task.sleep(for:.milliseconds(250))
            }
            await work?.value
            var report:[String:Any]=["scenario":scenario,"requests":requestCount-before,"visibleAtEnd":visible != nil,"wrongTargetVisible":wrongVisible,"preparationFailures":failures,"visionMissingFrames":visionMissing,"sourceSignatureChanges":sourceChanges,"targetSignatureChanges":targetChanges,"lowConfidenceFrames":lowConfidenceFrames,"samples":samples,"runState":captureSummary(),"lifecycle":requestCount>before ? requestDiagnostic() : [:]]
            report["firstVisibleSeconds"]=firstVisible;report["firstPreparedFrameSeconds"]=firstPrepared
            if requestCount>before, let requestStartUptime {
                let requested=requestStartUptime-start
                report["requestStartSeconds"]=requested
                report["preRequestAfterFirstFrameSeconds"]=firstPrepared.map { requested-$0 }
                if let requestDurationMS {
                    let completed=requested+Double(requestDurationMS)/1000
                    report["completionSeconds"]=completed
                    report["postCompletionUntilVisibleSeconds"]=firstVisible.map { $0-completed }
                }
            }
            reports.append(report);stop(userInitiated:true)
        }
        fixtureProvider=nil;fixtureRequestLimit=nil;fixtureTime=nil;fixtureUsesWallClock=false
        if let root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first,
           let data=try? JSONSerialization.data(withJSONObject:["fixture":"regional-production-ocr","revision":2,"processID":ProcessInfo.processInfo.processIdentifier,"runID":diagnosticRunID,"recordedAt":ISO8601DateFormatter().string(from:Date()),"cameraStarted":false,"networkRequests":0,"labelSource":"production-ocr-on-generated-bitmaps","clock":"real-monotonic","providerDelaySeconds":4,"scenarios":reports],options:[.sortedKeys]) {
            try? data.write(to:root.appendingPathComponent("camera-regional-fixture.json"),options:.atomic)
        }
    }

    func recordReady() { if !running && requestCount == 0 { saveDiagnostic(phase: "ready") } }
    private func requestDiagnostic() -> [String: Any] {
        var value: [String: Any] = ["sequence": requestCount, "completionDisposition": completionDisposition]
        value["captureRun"] = requestCaptureRun; value["startState"] = requestStartState
        value["completionCaptureRun"] = completionCaptureRun; value["completionTargetRelation"] = completionTargetRelation
        value["completionSuppression"] = completionSuppression; value["completionState"] = completionLocalState
        value["id"] = requestID; value["startedAt"] = requestStartedAt
        value["finishedAt"] = requestFinishedAt; value["durationMS"] = requestDurationMS
        value["cancellationReason"] = requestCancellationReason; value["cancellationAt"] = requestCancellationAt
        value["cancellationMS"] = requestCancellationMS
        return value
    }
    private func saveDiagnostic(phase: String) {
        // Only timing/status categories. Never store recognition text, target IDs or photos.
        var value: [String: Any] = ["source": fixtureTime == nil ? "camera" : "local-fixture", "phase": phase, "requestCount": requestCount,
            "request": SIWCHTTP.shared.diagnostics, "recordedAt": ISO8601DateFormatter().string(from: Date())]
        if let requestID, SIWCHTTP.shared.diagnostics["cameraRequestID"] as? String != requestID {
            value["request"] = ["phase": "preparing-or-unavailable", "cameraRequestID": requestID]
        }
        value["schemaVersion"] = 5
        value["accountRevision"] = SIWCController.accountRevision
        value["captureLimitRevision"] = "T1"
        value["captureLimitSeconds"] = CaptureTimeLimit.seconds
        value["captureLimitExpired"] = captureTimeLimit.expired
        value["captureLimitArmed"] = captureTimeLimit.deadline != nil
        if firstCaptureEnabled { value["firstCapture"] = firstCaptureSummary() }
        if liveCurrentEnabled { value["liveCurrent"] = liveSummary() }
        value["regionalResultEvidenceAllowed"] = lastResultEvidenceAllowed
        value["captureRunHistory"] = captureHistory
        value["captureRunState"] = captureSummary()
        value["localBranchCounters"] = localBranches
        value["matcherProcessingMS"] = ["last": lastMatcherMS, "maximum": maximumMatcherMS]
        value["stability"] = ["lastGate": lastStableGate, "lastElapsedMS": lastStableElapsedMS, "maximumObservedMS": stableMaximumMS, "requiredMS": Int(state.stableDuration * 1000)]
        var stabilization: [String: Any] = ["preview": previewStabilization, "policy": "low-latency-if-connection-and-format-support-otherwise-off"]
        var dataOutput: [String: Any] = [:]
        dataOutput["supported"] = captureStats.stabilizationSupported; dataOutput["preferred"] = captureStats.stabilizationPreferred
        dataOutput["active"] = captureStats.stabilizationActive; dataOutput["standardSupportedByFormat"] = captureStats.standardStabilizationSupported
        dataOutput["requested"] = captureStats.stabilizationRequested; dataOutput["selectionReason"] = captureStats.stabilizationSelectionReason
        dataOutput["lowLatencySupportedByFormat"] = captureStats.lowLatencyStabilizationSupported
        stabilization["videoDataOutput"] = dataOutput; value["stabilization"] = stabilization
        value["processID"] = ProcessInfo.processInfo.processIdentifier
        value["runID"] = diagnosticRunID; value["controllerStartedAt"] = controllerStartedAt
        value["trialLimit"] = liveCurrentEnabled ? liveSession.limit : firstCaptureEnabled ? firstCapture.limit : (ProcessInfo.processInfo.arguments.contains("--camera-trial-once") ? 1 : NSNull())
        value["cameraPipeline"] = cameraPipelineMode.rawValue
        value["explicitCameraModeArgument"] = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--camera-") }
        value["requestLifecycle"] = requestDiagnostic(); value["previousRequestLifecycles"] = requestHistory
        if liveCurrentEnabled, let latest=liveRequestLifecycles.last {
            value["requestLifecycle"] = ["id":latest["requestID"] ?? NSNull(),"sequence":latest["ordinal"] ?? NSNull(),
                "completionDisposition":latest["completionReason"] ?? "pending","phase":latest["phase"] ?? "pending"]
        }
        value["authenticated"] = account.authenticated; value["planEnabled"] = account.planEnabled
        value["legacyPlanOnlyConfirmed"] = account.account?.planOnlyConfirmed == true
        value["usageWarningRevision"] = SIWCController.usageWarningRevision
        value["cameraPromptRevision"] = CameraAnswer.promptRevision
        value["focusRevision"] = "F1"
        let focus = capture.focusGate.snapshot
        value["focus"] = ["active":focus.active,"adjusting":focus.adjusting,"autofocusSupported":focus.autofocusSupported,
            "generation":focus.revision,"changedAtHostTime":focus.changedAt,"rejectedSamples":captureStats.focusRejected,
            "beforeSendRejections":focusBeforeSendRejections] as [String:Any]
        value["continuousAutoFocusSupported"] = captureStats.continuousAutoFocusSupported
        value["focusModeBefore"] = captureStats.focusModeBefore
        value["focusModeActive"] = captureStats.focusModeActive
        value["shareRevision"] = "R2"
        value["sourceImageCount"] = sourceImages.images.count
        value["sourceImageBytes"] = sourceImages.images.byteCount
        value["planConfirmationRequired"] = false
        value["canStartCapture"] = canStartCapture
        value["captureRun"] = captureRun
        value["counterScopes"] = ["frames/samples/eligible/quality/saliency/vision": "capture-run", "motionRejected/targetChanges/newTargets/requestCount/completedCount/displayCount": "controller-run"]
        value["captureRunCounters"] = ["motionRejected": captureRunMotionRejected, "targetChanges": captureRunTargetChanges, "newTargets": captureRunNewTargets]
        value["lastStopReason"] = lastStopReason; value["lastStopAt"] = lastStopAt
        value["pipelineStage"] = pipelineStage
        value["cameraAuthorization"] = AVCaptureDevice.authorizationStatus(for: .video).rawValue
        value["cameraRunning"] = capture.session.isRunning
        value["controllerRunning"] = running
        value["frames"] = captureStats.frames; value["samples"] = captureStats.samples
        value["localProcessingMS"] = captureStats.localProcessingMS
        value["targetCropFraction"] = captureStats.targetCropFraction; value["targetTextBoxes"] = captureStats.targetTextBoxes; value["targetBarcodeBoxes"] = captureStats.targetBarcodeBoxes
        value["qualityContrast"] = captureStats.contrast; value["qualityEdgeScore"] = captureStats.edgeScore
        value["qualityRejected"] = captureStats.qualityRejected; value["saliencyRejected"] = captureStats.saliencyRejected
        value["visionRejected"] = captureStats.visionRejected; value["eligibleSamples"] = captureStats.accepted
        value["motionRejected"] = motionRejected; value["targetChanges"] = targetChanges; value["newTargets"] = newTargets
        value["completedCount"] = completedCount; value["emptyResultCount"] = emptyCount; value["displayCount"] = displayCount
        value["inflight"] = inflight; value["providerBlocked"] = blocked; value["matchedAtLastCompletion"] = matchedAtCompletion
        value["lastResultFieldCounts"] = resultFieldCounts; value["resultVisible"] = visible != nil
        value["featureDistance"] = lastFeatureDistance; value["fingerprintDistance"] = memory.bestDistance
        value["frameMotionDistance"] = lastMotionDistance
        value["alignedMotionDistance"] = lastAlignedMotionDistance; value["motionAlignmentMS"] = lastMotionAlignmentMS
        value["firstResultSeconds"] = firstResultLatency
        value["cacheReturnSeconds"] = cacheLatency
        if let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("camera-diagnostic.json"), options: .atomic)
        }
    }
}

struct CameraView: View {
    var readingFixture: SummaryReadingFixtureState? = nil
    @State private var model: CameraController
    init(readingFixture: SummaryReadingFixtureState? = nil, model: CameraController = CameraController()) {
        self.readingFixture = readingFixture; _model = State(initialValue: model)
    }
    @State private var showingHistory = false
    @State private var enlargedImage: RecognitionImageSnapshot?
    private var records: [RecognitionHistory.Entry] { readingFixture?.records ?? model.sessionRecords }
    private var sources: RecognitionSourceStore { readingFixture?.sources ?? model.sourceImages }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                // Reserve reading space on small phones and with accessibility fonts.
                let readingPaused = (readingFixture?.paused ?? !model.running) && !records.isEmpty
                let hasCard = (readingFixture?.result ?? model.visible) != nil || (readingFixture?.pending ?? model.pendingRecognition) != nil
                let previewSide = min(geometry.size.width, geometry.size.height * (readingPaused ? 0.16 : dynamicTypeSize.isAccessibilitySize ? 0.22 : hasCard ? 0.30 : 0.46))
                VStack(spacing: 12) {
                    ZStack {
                        if readingFixture != nil { Color.black; Text("合成閱讀測試").foregroundStyle(.white).font(.caption) }
                        else { CameraPreview(session: model.capture.session, onStabilization: model.recordPreviewStabilization) }
                        if readingFixture == nil && !model.running { Color.black; Image(systemName: "viewfinder").font(.system(size: 48)).foregroundStyle(.white.opacity(0.5)) }
                        Rectangle().stroke(.white.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, dash: [12, 6]))
                            .frame(width: previewSide * 0.78, height: previewSide * 0.78)
                    }.frame(width: previewSide, height: previewSide).clipped().frame(maxWidth: .infinity)
                    if let status = model.captureTimeLimitStatus {
                        Text(status).font(.footnote).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("captureTimeLimitStatus")
                    }
                    if readingFixture?.paused ?? !model.running {
                        if records.isEmpty {
                        Text(dynamicTypeSize.isAccessibilitySize ? "對準物品後開始取景。" : "對準安全可拍的物品，中央穩定約一秒後送出單張辨識。影像經 ChatGPT 方案處理；來源圖片僅於本次工作暫存。").font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                        }
                        Button(model.permissionDenied ? "在系統設定允許相機" : "開始取景") {
                            if readingFixture != nil { return }
                            if model.permissionDenied { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                            else { Task { await model.start() } }
                        }.buttonStyle(.borderedProminent)
                    }
                    if let status = model.firstCaptureTrialStatus { Text(status).font(.footnote).foregroundStyle(.secondary).padding(.horizontal).accessibilityIdentifier("firstCaptureTrialStatus") }
                    if let status = readingFixture != nil ? "已送 0/3" : model.liveTrialStatus { Text(status).font(.footnote).foregroundStyle(.secondary).padding(.horizontal).accessibilityIdentifier("liveTrialStatus") }
                    if !records.isEmpty {
                        Button("本次紀錄 \(records.count)") { showingHistory=true }
                            .font(.subheadline).accessibilityIdentifier("sessionHistoryButton")
                    }
                    if let pending = readingFixture?.pending ?? model.pendingRecognition {
                        RecognitionWaitingCard(preview: pending, onOpenImage: { enlargedImage = $0 }).padding(.horizontal)
                    }
                    if let result = readingFixture?.result ?? model.visible {
                        RecognitionResultCard(result: result, isPrevious: readingFixture?.previous ?? model.showingPreviousResult, sourceImages:sources, fixtureProbe: readingFixture?.probe, onOpenImage: { enlargedImage = $0; readingFixture?.probe.imagePresented?($0.jpeg) })
                            // Content, not frame/request events, owns reading state.
                            // Identical answers and the previous label preserve scroll;
                            // a genuinely different answer starts at the top, collapsed.
                            .id(result)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.horizontal)
                    } else { Spacer(minLength: 0) }
                }.padding(.bottom)
            }.navigationTitle("Glance").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { if readingFixture?.paused == false || model.running { Button("暫停") { if readingFixture == nil { model.stop(userInitiated: true) } } } }
                    ToolbarItem(placement: .topBarTrailing) { Button { if readingFixture == nil { model.showingSettings = true } } label: { Image(systemName: "gearshape") }.accessibilityLabel("設定與診斷") }
                }
                .sheet(isPresented: $model.showingSettings) {
                    NavigationStack {
                        Form {
                            Section("ChatGPT") {
                                Label(model.account.authenticated ? "已登入，使用保存的會話" : "尚未登入", systemImage: "person.crop.circle")
                                Text("辨識固定使用 gpt-6-luna · none。方案不足即停止，不切換其他模型或 API。").font(.footnote)
                                NavigationLink("帳戶與權限") { SIWCView() }
                            }
                            Section("本次診斷") {
                                Text(model.diagnostic).textSelection(.enabled)
                                Text("累計送出 \(model.requestCount) 次")
                                if let budget=model.liveTrialStatus { Text("本批："+budget+"；手動暫停後清零") }
                                if let latency = model.firstResultLatency { Text("目標進入到首次顯示：\(String(format: "%.2f", latency)) 秒") }
                                if let latency = model.lastLatency { Text("上次請求到完成：\(String(format: "%.2f", latency)) 秒") }
                                if let latency = model.cacheLatency { Text("回看穩定到顯示：\(String(format: "%.2f", latency)) 秒") }
                                Text("辨識中會顯示來源縮圖與等待提示；失敗或查無不新增結果卡。手動暫停保留本次紀錄，背景／設定清除。門檻仍待實機校準。").font(.footnote)
                            }
                        }.navigationTitle("設定").toolbar { Button("完成") { model.showingSettings = false } }
                    }
                }.onChange(of: model.showingSettings) { _, shown in model.settingsChanged(shown) }
                .sheet(item: $enlargedImage) { RecognitionImageViewer(snapshot: $0) }
                .sheet(isPresented:$showingHistory) { RecognitionHistorySheet(records:records,sourceImages:sources,fixtureProbe:readingFixture?.historyProbe) }
                .onChange(of: records.isEmpty) { _, empty in if empty && !model.shareSession.active { showingHistory=false } }
                .onChange(of: model.shareSession.active) { _, active in if !active && records.isEmpty { showingHistory=false } }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { enlargedImage = nil }
                    if readingFixture == nil { model.foreground(phase) }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in if readingFixture == nil { model.memoryWarning() } }
                .task {
                    guard readingFixture == nil else { return }
                    if ProcessInfo.processInfo.arguments.contains("--camera-orb-fixture") { await model.runORBFixture() }
                    else if ProcessInfo.processInfo.arguments.contains("--camera-live-fixture") { await model.runLiveFixture() }
                    else if ProcessInfo.processInfo.arguments.contains("--camera-vision-baseline") { await model.runOfficialVisionBaseline() }
                    else if ProcessInfo.processInfo.arguments.contains("--camera-geometry-profile") { await model.runGeometryProfile() }
                    else if ProcessInfo.processInfo.arguments.contains("--camera-current-image-fixture") { await model.runCurrentImageFixture() }
                    else if ProcessInfo.processInfo.arguments.contains("--camera-first-capture-generated-check") { await model.runFirstCaptureGeneratedProbe(real:false) }
                    else if ProcessInfo.processInfo.arguments.contains("--camera-first-capture-generated-real") { await model.runFirstCaptureGeneratedProbe(real:true) }
                    else if ProcessInfo.processInfo.arguments.contains("--camera-first-capture-fixture") { await model.runFirstCaptureFixture() }
                    else if ProcessInfo.processInfo.arguments.contains("--camera-roi-trace") { await model.runROITrace() }
                    else if ProcessInfo.processInfo.arguments.contains("--camera-regional-fixture") { await model.runRegionalFixture() }
                    else if ProcessInfo.processInfo.arguments.contains("--camera-delayed-fixture") { await model.runDelayedFixture() }
                    else if ProcessInfo.processInfo.arguments.contains("--camera-continuous-fixture") { await model.runContinuousFixture() }
                else if ProcessInfo.processInfo.arguments.contains("--camera-local-fixture") { await model.runLocalMatcherFixture() }
                    else if ProcessInfo.processInfo.arguments.contains("--camera-fixture") { await model.runSyntheticFixture() }
                    else { model.recordReady() }
                }
        }
    }
}


/// Reading-only gestures never start a capture or request. Caller keys by result content.
struct RecognitionResultCard: View {
    let result: RecognitionResult
    let isPrevious: Bool
    @Environment(\.dynamicTypeSize) private var sharingTypeSize
    @State private var originalExpanded: Bool
    let fixtureProbe: SummaryCardProbe?
    let sourceImages: RecognitionSourceStore?
    let onOpenImage: ((RecognitionImageSnapshot) -> Void)?

    init(result: RecognitionResult, isPrevious: Bool, initiallyExpanded: Bool = false, sourceImages: RecognitionSourceStore? = nil, fixtureProbe: SummaryCardProbe? = nil, onOpenImage: ((RecognitionImageSnapshot) -> Void)? = nil) {
        self.result = result; self.isPrevious = isPrevious; self.fixtureProbe = fixtureProbe; self.sourceImages = sourceImages; self.onOpenImage = onOpenImage
        _originalExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let id = result.sourceImageID, let jpeg = sourceImages?.images.image(for: id) {
                HStack {
                    RecognitionSourceThumbnail(snapshot: .init(id: id, jpeg: jpeg), onOpenImage: onOpenImage)
                    Text("辨識來源").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    shareActions
                }.padding([.horizontal, .top]).padding(.bottom, 8)
            }
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                if isPrevious {
                    Text("上次辨識").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("previousRecognitionLabel")
                }
                ForEach(Array(result.names.enumerated()), id: \.offset) { _, name in
                    RecognitionWebText(text: name).font(.headline).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if !result.summary.isEmpty {
                    RecognitionWebText(text: result.summary).font(.body).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled).accessibilityIdentifier("recognitionSummary")
                }
                if sourceImages?.images.image(for: result.sourceImageID) == nil {
                    shareActions.frame(maxWidth:.infinity,alignment:.leading)
                }
                if !result.text.isEmpty {
                    DisclosureGroup(isExpanded: $originalExpanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(result.text.enumerated()), id: \.offset) { _, line in
                                RecognitionWebText(text: line).font(.body).fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    } label: {
                        Text("查看原文").font(.subheadline).frame(minHeight: 44)
                    }.accessibilityIdentifier("recognitionOriginalText")
                }
                if !result.barcodes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("【條碼】").font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(result.barcodes.enumerated()), id: \.offset) { _, barcode in
                            RecognitionBarcodeValue(text: barcode)
                        }
                    }.accessibilityIdentifier("recognitionBarcodes")
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
        }.scrollIndicators(.visible).scrollBounceBehavior(.basedOnSize)
            .accessibilityIdentifier("recognitionResult")
        }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .onAppear {
                fixtureProbe?.expanded = originalExpanded
                fixtureProbe?.toggleOriginal = { originalExpanded.toggle() }
            }
            .onChange(of: originalExpanded) { _, expanded in fixtureProbe?.expanded = expanded }
    }
    @ViewBuilder private var shareActions: some View {
        RecognitionShareButton(text:result.shareText,image:{ sourceImages?.images.image(for:result.sourceImageID) },
            imageAvailable:sourceImages?.images.image(for:result.sourceImageID) != nil,probe:fixtureProbe)
            .fixedSize().frame(minWidth:44,minHeight:44)
            .disabled(result.shareText.isEmpty && sourceImages?.images.image(for:result.sourceImageID) == nil)
            .accessibilityIdentifier("shareRecognitionResult")
    }
}

struct PendingRecognitionPreview: Identifiable {
    let id: UUID
    var jpeg: Data?
}

struct RecognitionImageSnapshot: Identifiable {
    let id: UUID
    let jpeg: Data
    var allowsImageSharing = false
}

struct RecognitionSourceThumbnail: View {
    let snapshot: RecognitionImageSnapshot
    var onOpenImage: ((RecognitionImageSnapshot) -> Void)? = nil
    @State private var enlarged: RecognitionImageSnapshot?
    var body: some View {
        Button { if let onOpenImage { onOpenImage(snapshot) } else { enlarged = snapshot } } label: {
            if let image = UIImage(data: snapshot.jpeg) {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(width: 64, height: 64)
                    .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
        }.buttonStyle(.plain)
            .accessibilityLabel("放大辨識來源圖片")
            .accessibilityIdentifier("recognitionSourceThumbnail")
            .sheet(item: $enlarged) { RecognitionImageViewer(snapshot: $0) }
    }
}

struct RecognitionImageViewer: View {
    let snapshot: RecognitionImageSnapshot
    var shareProbe: SummaryCardProbe? = nil
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if let image = UIImage(data: snapshot.jpeg) {
                    Image(uiImage: image).resizable().scaledToFit().padding()
                        .accessibilityLabel("辨識來源圖片")
                        .accessibilityValue(snapshot.id.uuidString)
                        .accessibilityIdentifier("recognitionSourceEnlarged")
                } else {
                    ContentUnavailableView("無法讀取這張圖片", systemImage: "photo.badge.exclamationmark")
                        .accessibilityIdentifier("recognitionSourceUnavailable")
                }
            }
            .navigationTitle("辨識來源").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if snapshot.allowsImageSharing, UIImage(data: snapshot.jpeg) != nil {
                        RecognitionShareButton(text: "", imageAvailable: true, probe: shareProbe,
                            snapshot: { .init(text: "", jpeg: snapshot.jpeg) }, imageOnly: true)
                            .frame(width: 44, height: 44)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("closeRecognitionImage")
                }
            }
        }
    }
}

private struct RecognitionWaitingCard: View {
    let preview: PendingRecognitionPreview
    let onOpenImage: (RecognitionImageSnapshot) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 12) {
            if let jpeg = preview.jpeg {
                RecognitionSourceThumbnail(snapshot: .init(id: preview.id, jpeg: jpeg), onOpenImage: onOpenImage)
            }
            Text("辨識中").font(.subheadline).accessibilityIdentifier("recognitionWaiting")
            TimelineView(.animation(minimumInterval: 0.35, paused: reduceMotion)) { timeline in
                let phase = Int(timeline.date.timeIntervalSinceReferenceDate / 0.35) % 3
                HStack(spacing: 5) {
                    ForEach(0..<3) { index in
                        Circle().fill(.secondary.opacity(reduceMotion || phase == index ? 0.85 : 0.25))
                            .frame(width: 5, height: 5)
                    }
                }
            }.accessibilityHidden(true)
            Spacer(minLength: 0)
        }.padding(12).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

@MainActor @Observable final class RecognitionSourceStore {
    private(set) var images = RecognitionSourceImages()
    func insert(_ data:Data,for id:UUID) { images.insert(data,for:id) }
    func removeAll() { images.removeAll() }
}

@MainActor @Observable final class RecognitionShareSession {
    static let shared = RecognitionShareSession()
    private(set) var active = false
    private init() { RecognitionShareFile.removeOrphans() }
    func begin() { active=true }
    func finish() { active=false }
}

/// Completion owns the file even if the original result view disappears in the background.
@MainActor final class RecognitionShareLifetime: NSObject, UIAdaptivePresentationControllerDelegate {
    let file:RecognitionShareFile?
    let didFinish:(() -> Void)?
    private var finished=false
    init(file:RecognitionShareFile?,didFinish:(() -> Void)?) { self.file=file;self.didFinish=didFinish }
    func finish() {
        guard !finished else { return };finished=true
        file?.finish();RecognitionShareSession.shared.finish();didFinish?()
    }
    func presentationControllerDidDismiss(_ presentationController:UIPresentationController) { finish() }
}
@MainActor final class RecognitionActivityController:UIActivityViewController {
    var lifetime:RecognitionShareLifetime?
    override func viewDidDisappear(_ animated:Bool) {
        super.viewDidDisappear(animated)
        // Presenting an extension does not end the activity or delete its input.
        if isBeingDismissed || presentingViewController == nil { lifetime?.finish() }
    }
}

/// UIKit owns the standard share sheet and iPad anchor.
struct RecognitionShareContent {
    let text: String
    let jpeg: Data?
    var document: RecognitionShareDocument? = nil
}

/// Providers keep all text representations on one item; the image remains independent.
@MainActor enum RecognitionShareProviders {
    static func textRepresentations(_ document: RecognitionShareDocument) -> [String: Any] {
        var representations: [String: Any] = [UTType.html.identifier: Data(document.html.utf8),
            UTType.utf8PlainText.identifier: document.plainText]
        let attributed = NSMutableAttributedString(string: document.body)
        for link in document.links {
            if attributed.length > 0 { attributed.append(NSAttributedString(string: "\n\n")) }
            attributed.append(NSAttributedString(string: link.label, attributes: [.link: link.url]))
        }
        if let rtf = try? attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            representations[UTType.rtf.identifier] = rtf
        }
        return representations
    }
    static func text(_ document: RecognitionShareDocument) -> NSItemProvider { text(textRepresentations(document)) }
    static func text(_ representations: [String: Any]) -> NSItemProvider {
        let provider = NSItemProvider()
        // Higher fidelity first. Share destinations choose their representation.
        for type in [UTType.rtf.identifier, UTType.html.identifier] {
            if let data = representations[type] as? Data {
                provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { completion in completion(data, nil); return nil }
            }
        }
        if let plain = representations[UTType.utf8PlainText.identifier] as? String {
            provider.registerObject(plain as NSString, visibility: .all)
        }
        return provider
    }
    /// Only a successful explicit system Copy replaces its own generated clipboard.
    /// Never reads the clipboard; the immutable items were prepared at the share tap.
    static func finishCopy(kind: UIActivity.ActivityType?, completed: Bool, error: Error?, items: [[String: Any]],
                           write: ([[String: Any]]) -> Void = { UIPasteboard.general.items = $0 }) {
        guard kind == .copyToPasteboard, completed, error == nil, !items.isEmpty else { return }
        write(items)
    }
    static func image(_ image: UIImage, jpeg: Data) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { completion in completion(jpeg, nil); return nil }
        provider.registerObject(image, visibility: .all)
        return provider
    }
}

struct RecognitionCardActionAppearance {
    let accessibilitySize: Bool
    var size: CGSize { accessibilitySize ? .init(width: 64, height: 64) : .init(width: 44, height: 36) }
    var pointSize: CGFloat { accessibilitySize ? 24 : 16 }
    var font: Font { .system(size: pointSize, weight: .semibold) }
    func color(enabled: Bool) -> UIColor { enabled ? .systemBlue : .systemGray }
    func apply(to button: UIButton) {
        let symbol = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold, scale: .medium)
        let foreground = color(enabled: button.isEnabled)
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "square.and.arrow.up", withConfiguration: symbol)
        configuration.preferredSymbolConfigurationForImage = symbol
        configuration.baseForegroundColor = foreground
        configuration.imageColorTransformer = UIConfigurationColorTransformer { _ in foreground }
        configuration.contentInsets = .zero
        button.configuration = configuration
        button.imageView?.adjustsImageSizeForAccessibilityContentSizeCategory = false
    }
}

struct RecognitionCardActionLabel: ViewModifier {
    let appearance: RecognitionCardActionAppearance
    let enabled: Bool
    func body(content: Content) -> some View {
        content
            .font(appearance.font)
            .imageScale(.medium)
            .foregroundStyle(Color(uiColor: appearance.color(enabled: enabled)))
            .frame(width: appearance.size.width, height: appearance.size.height)
            .contentShape(Rectangle())
    }
}

/// The label owns both enabled and disabled colors; do not add plain-style dimming.
struct RecognitionCardActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

struct RecognitionShareButton: UIViewRepresentable {
    var text:String
    var image:(() -> Data?)? = nil
    var imageAvailable=false
    var probe:SummaryCardProbe? = nil
    /// Resolve once at the tap, then keep text/image fixed while the sheet is open.
    var snapshot: (() -> RecognitionShareContent?)? = nil
    var imageOnly = false
    var plainTextOnly = false
    var cardActionAppearance: RecognitionCardActionAppearance? = nil
    var actionsEnabled = true
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        cardActionAppearance?.size
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context:Context) -> UIButton {
        let button=UIButton(type:.system)
        var configuration=UIButton.Configuration.plain()
        configuration.image=UIImage(systemName:"square.and.arrow.up")
        button.configuration=configuration
        button.titleLabel?.font = .preferredFont(forTextStyle:.subheadline)
        button.titleLabel?.adjustsFontForContentSizeCategory=true
        button.addTarget(context.coordinator,action:#selector(Coordinator.share(_:)),for:.touchUpInside)
        return button
    }
    func updateUIView(_ button:UIButton,context:Context) {
        context.coordinator.value=self
        button.configuration?.title=nil
        button.accessibilityLabel=imageOnly ? "分享圖片" : "分享結果"
        button.accessibilityHint=imageOnly ? "只分享這張來源圖片，可在系統選單儲存影像" : imageAvailable ? "來源圖片與完整文字，包含原文及條碼" : "來源圖片已無法取得，分享完整文字、原文與條碼"
        button.accessibilityIdentifier=imageOnly ? "shareRecognitionImage" : "shareRecognitionResult"
        if plainTextOnly {
            button.accessibilityLabel = "分享 JSON 純文字"
            button.accessibilityHint = "只分享完整模型原始回覆"
            button.accessibilityIdentifier = "shareRecognitionJSON"
        }
        button.isEnabled = actionsEnabled && (imageOnly ? imageAvailable : imageAvailable || !text.isEmpty)
        if let cardActionAppearance {
            cardActionAppearance.apply(to: button)
            if !actionsEnabled {
                button.accessibilityLabel = "完成辨識後可分享"
                button.accessibilityHint = nil
            }
        }
    }
    @MainActor final class Coordinator:NSObject {
        var value:RecognitionShareButton
        init(_ value:RecognitionShareButton) { self.value=value }
        @objc func share(_ button:UIButton) {
            guard !RecognitionShareSession.shared.active else { return }
            var responder:UIResponder?=button
            while responder != nil && !(responder is UIViewController) { responder=responder?.next }
            guard let presenter=responder as? UIViewController,presenter.presentedViewController == nil else { return }
            var file:RecognitionShareFile?
            var items:[Any]=[]
            var copyItems:[[String:Any]]=[]
            let content: RecognitionShareContent
            if let snapshot = value.snapshot {
                guard let current = snapshot() else { return }
                content = current
            } else { content = .init(text: value.text, jpeg: value.image?()) }
            guard !value.plainTextOnly || (content.jpeg == nil && content.document == nil) else { return }
            if value.probe?.interceptPreparedShare?(content) == true { return }
            guard !value.imageOnly || content.jpeg != nil else { return }
            let text=value.imageOnly ? "" : content.document?.plainText ?? content.text
            do {
                // Keep the direct share and explicit Copy order identical.
                // Receiver apps decide how many independent items they consume.
                if let jpeg=content.jpeg {
                    let source=try RecognitionShareFile(jpeg:jpeg);file=source
                    guard let image=UIImage(contentsOfFile:source.url.path) else { throw CocoaError(.fileReadCorruptFile) }
                    items.append(image)
                    copyItems.append([UTType.jpeg.identifier: jpeg])
                }
                if !text.isEmpty {
                    let representations = value.plainTextOnly ? [UTType.utf8PlainText.identifier: text] : RecognitionShareProviders.textRepresentations(content.document ?? .init(body: text))
                    items.append(text)
                    copyItems.append(representations)
                }
                guard !items.isEmpty else { return }
            } catch {
                file?.finish()
                let alert=UIAlertController(title:"無法準備來源圖片",message:"暫存檔建立失敗，請稍後再試。",preferredStyle:.alert)
                alert.addAction(UIAlertAction(title:"好",style:.default));presenter.present(alert,animated:true);return
            }
            let lifetime=RecognitionShareLifetime(file:file,didFinish:value.probe?.shareFinished)
            let probe=value.probe
            // Standard UIKit objects for direct share; Copy retains its richer frozen snapshot below.
            let activity=RecognitionActivityController(activityItems: items, applicationActivities: nil)
            activity.lifetime=lifetime
            let frozenCopyItems = copyItems
            activity.completionWithItemsHandler={ kind,completed,_,error in
                RecognitionShareProviders.finishCopy(kind: kind, completed: completed, error: error, items: frozenCopyItems)
                lifetime.finish();probe?.activityCompleted?(kind?.rawValue,completed)
            }
            if let popover=activity.popoverPresentationController {
                popover.sourceView=button;popover.sourceRect=button.bounds;popover.permittedArrowDirections=[.up,.down]
            }
            activity.presentationController?.delegate=lifetime
            RecognitionShareSession.shared.begin()
            presenter.present(activity,animated:true) {
                probe?.combinedPresented?(text,file?.url,items.count)
                probe?.itemsPresented?(items, frozenCopyItems)
                probe?.activityPresented?(activity, button)
            }
        }
    }
}

/// A selected immutable entry keeps its reading position while new answers arrive.
struct RecognitionHistorySheet: View {
    let records: [RecognitionHistory.Entry]
    var sourceImages:RecognitionSourceStore? = nil
    var fixtureProbe: HistoryReadingProbe? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var selected: RecognitionHistory.Entry?
    @State private var enlargedImage: RecognitionImageSnapshot?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(records.reversed()) { entry in
                        Button { selected=entry } label: {
                            VStack(alignment:.leading,spacing:6) {
                                Text("第 \(entry.sequence) 次辨識").font(.caption).foregroundStyle(.secondary)
                                Text(entry.result.names.first ?? "辨識結果").font(.headline).foregroundStyle(.primary)
                                if !entry.result.summary.isEmpty { Text(entry.result.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                            }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,4)
                        }.accessibilityIdentifier("historyEntry-\(entry.sequence)")
                    }
                } footer: {
                    Text("閱讀紀錄不會暫停取景。手動暫停後可再辨識三次，已完成紀錄仍保留；離開 App 或開啟設定會清除本次紀錄。")
                }
            }.navigationTitle("本次紀錄").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("完成") { dismiss() } } }
                .navigationDestination(item:$selected) { entry in
                    RecognitionResultCard(result:entry.result,isPrevious:true,sourceImages:sourceImages,fixtureProbe:fixtureProbe?.card,onOpenImage:{ enlargedImage = $0; fixtureProbe?.card.imagePresented?($0.jpeg) })
                        .id(entry.id).padding().navigationTitle("第 \(entry.sequence) 次辨識")
                        .navigationBarTitleDisplayMode(.inline)
                }
        }.sheet(item: $enlargedImage) { RecognitionImageViewer(snapshot: $0) }
        .onAppear {
            fixtureProbe?.select = { id in selected=records.first { $0.id == id } }
            fixtureProbe?.returnToList = { selected=nil }
            fixtureProbe?.recordCount=records.count
        }.onChange(of: records) { _, current in
            fixtureProbe?.recordCount=current.count
            fixtureProbe?.select = { id in selected=current.first { $0.id == id } }
        }
            .onChange(of: selected) { _, value in fixtureProbe?.selectedID=value?.id }
            .onChange(of: scenePhase) { _, phase in if phase != .active { enlargedImage = nil } }
    }
}
@MainActor final class HistoryReadingProbe {
    var select: ((UUID)->Void)?
    var returnToList: (()->Void)?
    var selectedID: UUID?
    var recordCount=0
    let card=SummaryCardProbe()
}

@MainActor @Observable final class SummaryReadingFixtureState {
    var pending: PendingRecognitionPreview?
    var result: RecognitionResult
    var previous = false
    var paused = false
    var records: [RecognitionHistory.Entry] = []
    let probe = SummaryCardProbe()
    let historyProbe = HistoryReadingProbe()
    let sources = RecognitionSourceStore()
    init(_ result: RecognitionResult) { self.result = result }
}
struct HistoryReadingFixtureHost:View {
    let state:SummaryReadingFixtureState
    let probe:HistoryReadingProbe
    var body:some View { RecognitionHistorySheet(records:state.records,fixtureProbe:probe) }
}
@MainActor final class SummaryCardProbe {
    // Explicit verification views may inspect the real tap snapshot without a share sheet.
    var interceptPreparedShare: ((RecognitionShareContent) -> Bool)?
    var toggleOriginal: (() -> Void)?
    var expanded = false
    var imagePresented: ((Data) -> Void)?
    var combinedPresented: ((String,URL?,Int) -> Void)?
    var itemsPresented: (([Any], [[String: Any]]) -> Void)?
    var activityPresented: ((UIActivityViewController, UIButton) -> Void)?
    var activityCompleted: ((String?,Bool) -> Void)?
    var shareFinished: (() -> Void)?
}

/// Runs only with an explicit engineering flag. All text and pixels are authored fixtures.
struct SummaryReadingFixtureView: View {
    @State private var status = "正在驗證合成閱讀畫面"
    var body: some View { Text(status).padding().task {
        status = await SummaryReadingUIChecks.run() ? "合成閱讀UI通過" : "合成閱讀UI待檢查"
    } }
}

/// Match the iPhone app's portrait contract instead of UIHostingController's
/// default all-orientations policy, which rotates the first iPad fixture window.
@MainActor final class PortraitFixtureHost<Content: View>: UIHostingController<Content> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .portrait }
}

@MainActor enum SummaryReadingUIChecks {
    static func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap { descendants($0) } }
    static func settle() async { try? await Task.sleep(for: .milliseconds(350)) }
    static func historyCases(scene:UIWindowScene,folder:URL,long:String,original:String) async -> [[String:Any]] {
        var reports:[[String:Any]]=[]
        for (name,width,height,type) in [("history",CGFloat(375),CGFloat(812),DynamicTypeSize.large),("history-maximum-type",CGFloat(320),CGFloat(568),DynamicTypeSize.accessibility5)] {
            let state=SummaryReadingFixtureState(.init(names:["第一筆合成答案"],summary:long,text:[original]))
            let first=RecognitionHistory.Entry(id:UUID(),sequence:1,capturedAt:1,completedAt:2,result:state.result)
            let second=RecognitionHistory.Entry(id:UUID(),sequence:2,capturedAt:3,completedAt:4,result:.init(names:["第二筆合成答案"],summary:"較新的成功答案",text:[original]))
            let third=RecognitionHistory.Entry(id:UUID(),sequence:3,capturedAt:5,completedAt:6,result:.init(names:["第三筆合成答案"],summary:"閱讀時新加入的成功答案",text:[original]))
            let fourth=RecognitionHistory.Entry(id:UUID(),sequence:4,capturedAt:7,completedAt:8,result:.init(names:["第四筆合成答案"],summary:"暫停再開始後的新一批答案",text:[original]))
            state.records=[first,second,third]
            let probe=HistoryReadingProbe()
            let host=PortraitFixtureHost(rootView:HistoryReadingFixtureHost(state:state,probe:probe).environment(\.dynamicTypeSize,type))
            let window=UIWindow(windowScene:scene);window.frame=CGRect(x:0,y:0,width:width,height:height)
            window.rootViewController=host;window.makeKeyAndVisible();await settle()
            window.frame=CGRect(x:0,y:0,width:width,height:height);window.bounds=CGRect(x:0,y:0,width:width,height:height);host.view.setNeedsLayout();host.view.layoutIfNeeded();await settle()
            func scroll()->UIScrollView? {
                descendants(host.view).compactMap { $0 as? UIScrollView }.filter { $0.bounds.height>30 && $0.contentSize.height>0 }.max { $0.contentSize.height<$1.contentSize.height }
            }
            func snapshot(_ suffix:String) {
                let format=UIGraphicsImageRendererFormat();format.scale=1
                let image=UIGraphicsImageRenderer(bounds:host.view.bounds,format:format).image { _ in host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true) }
                if let data=image.pngData() { try? data.write(to:folder.appendingPathComponent(name+"-"+suffix+".png"),options:.atomic) }
            }
            var checks:[String:Bool]=[:];var metrics:[String:Double]=[:]
            checks["windowSizeMatchesRequested"] = abs(host.view.bounds.width-width)<1 && abs(host.view.bounds.height-height)<1
            metrics["actualWidth"]=Double(host.view.bounds.width);metrics["actualHeight"]=Double(host.view.bounds.height)
            metrics["windowFrameWidth"]=Double(window.frame.width);metrics["windowFrameHeight"]=Double(window.frame.height);metrics["windowTransformB"]=Double(window.transform.b);metrics["windowTransformC"]=Double(window.transform.c)
            checks["threeRecordsListed"]=probe.recordCount==3;snapshot("list")
            probe.select?(first.id);await settle();await settle()
            checks["selectedEarlierRecord"]=probe.selectedID==first.id
            checks["originalInitiallyCollapsed"] = !probe.card.expanded && probe.card.toggleOriginal != nil
            probe.card.toggleOriginal?();await settle()
            if let s=scroll() {
                checks["expandedAndScrollable"]=probe.card.expanded && s.contentSize.height>s.bounds.height+180
                checks["noHorizontalOverflow"]=s.contentSize.width<=s.bounds.width+1
                let frame=s.convert(s.bounds,to:host.view)
                checks["detailWithinScreen"]=frame.minX>=0 && frame.maxX<=width+1 && frame.maxY<=height+1 && s.bounds.height>=90
                s.setContentOffset(CGPoint(x:0,y:180),animated:false);await settle()
                let offset=s.contentOffset.y;metrics["readingOffsetBefore"]=Double(offset)
                state.records.append(fourth);await settle()
                metrics["readingOffsetAfter"]=Double(scroll()?.contentOffset.y ?? -999)
                checks["incomingAnswerAdded"]=probe.recordCount==4
                checks["incomingAnswerKeepsSelectedRecord"]=probe.selectedID==first.id
                checks["incomingAnswerKeepsExpansion"]=probe.card.expanded
                checks["incomingAnswerKeepsScroll"]=abs((scroll()?.contentOffset.y ?? -999)-offset)<2
                snapshot("new-answer-while-reading")
            } else { checks["detailScrollFound"]=false }
            probe.returnToList?();await settle();await settle();snapshot("four-records")
            probe.select?(fourth.id);await settle();await settle()
            checks["newRecordCanBeSelected"]=probe.selectedID==fourth.id
            checks["newSelectionCollapsesOriginal"] = !probe.card.expanded
            checks["newSelectionStartsAtTop"]=abs(scroll()?.contentOffset.y ?? -999)<2
            snapshot("new-selection")
            reports.append(["scenario":name,"checks":checks,"metrics":metrics,"passed":!checks.isEmpty && checks.values.allSatisfy { $0 }])
            window.isHidden=true;window.rootViewController=nil
        }
        return reports
    }
    static func run() async -> Bool {
        guard ProcessInfo.processInfo.arguments.contains("--camera-summary-ui-fixture"),
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return false }
        // The first extra UIWindow in iPhone-on-iPad compatibility adopts the
        // scene's initial geometry instead of its requested test size. Settle
        // that transition with an empty host before measuring actual cards.
        let bootstrap = UIWindow(windowScene: scene)
        let bootstrapHost = PortraitFixtureHost(rootView: Color.clear)
        bootstrap.rootViewController = bootstrapHost; bootstrap.makeKeyAndVisible()
        bootstrapHost.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        await settle(); await settle()
        bootstrap.isHidden = true; bootstrap.rootViewController = nil
        let folder = root.appendingPathComponent("summary-ui-fixture", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let long = String(repeating: "這是合成閱讀測試的日文標籤瓶子。簡介只整理可辨識的包裝資訊，不推測成分、療效或服用方式。\n\n", count: 12)
        let original = String(repeating: "合成サンプル・実在の医薬品ではありません。ラベルに書かれた原文をそのまま表示します。\n", count: 16)
        var reports: [[String: Any]] = []
        let cases: [(String, CGFloat, CGFloat, DynamicTypeSize, String)] = [
            ("short",375,812,.large,"日文標示的合成瓶子。標籤上的其餘細節無法確認。"),
            ("long",375,812,.large,long),
            ("small-long",320,568,.large,long),
            ("large-type",375,812,.accessibility3,long),
            ("maximum-type",320,568,.accessibility5,long),
            ("empty-summary",375,812,.large,""),
            ("paused-long",375,812,.large,long),
            ("paused-maximum-type",320,568,.accessibility5,long)]
        for (name,width,height,type,summary) in cases {
            let state = SummaryReadingFixtureState(.init(names:["日文標示藥瓶（合成）"],summary:summary,text:[original,"ABC-001"],barcodes:["0012345678905"]))
            state.paused=name.hasPrefix("paused-")
            state.records=[.init(id:UUID(),sequence:1,capturedAt:1,completedAt:2,result:state.result)]
            let host = PortraitFixtureHost(rootView: CameraView(readingFixture: state).environment(\.dynamicTypeSize,type))
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x:0,y:0,width:width,height:height)
            window.rootViewController = host; window.makeKeyAndVisible()
            await settle(); window.frame=CGRect(x:0,y:0,width:width,height:height); window.bounds=CGRect(x:0,y:0,width:width,height:height); host.view.setNeedsLayout(); host.view.layoutIfNeeded(); await settle()
            func scroll() -> UIScrollView? {
                descendants(host.view).compactMap { $0 as? UIScrollView }.filter { $0.bounds.height > 30 && $0.contentSize.height > 0 }.max { $0.contentSize.height < $1.contentSize.height }
            }
            func snapshot(_ suffix: String) {
                let format=UIGraphicsImageRendererFormat();format.scale=1
                let image=UIGraphicsImageRenderer(bounds:host.view.bounds,format:format).image { _ in host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true) }
                if let data=image.pngData() { try? data.write(to:folder.appendingPathComponent(name+"-"+suffix+".png"),options:.atomic) }
            }
            var checks: [String:Bool] = [:]
            var metrics: [String:Double] = [:]
            checks["windowSizeMatchesRequested"] = abs(host.view.bounds.width-width)<1 && abs(host.view.bounds.height-height)<1
            metrics["actualWidth"]=Double(host.view.bounds.width);metrics["actualHeight"]=Double(host.view.bounds.height)
            metrics["windowFrameWidth"]=Double(window.frame.width);metrics["windowFrameHeight"]=Double(window.frame.height);metrics["windowTransformB"]=Double(window.transform.b);metrics["windowTransformC"]=Double(window.transform.c)
            if let s=scroll() {
                let card=s.convert(s.bounds,to:host.view)
                let bars=descendants(host.view).compactMap { $0 as? UINavigationBar }
                let navBottom=bars.map { $0.convert($0.bounds,to:host.view).maxY }.max() ?? 0
                checks["readingViewportUsable"] = s.bounds.height >= 90 && s.bounds.width >= 250
                checks["cardInsideScreen"] = card.minX >= -1 && card.maxX <= width+1 && card.maxY <= height+1
                checks["navigationControlsUncovered"] = !bars.isEmpty && card.minY >= navBottom
                checks["noHorizontalOverflow"] = s.contentSize.width <= s.bounds.width+1
                checks["originalInitiallyCollapsed"] = !state.probe.expanded && state.probe.toggleOriginal != nil
                metrics["viewportHeight"] = Double(s.bounds.height);metrics["contentHeightCollapsed"] = Double(s.contentSize.height)
                snapshot("top")
                let before=s.contentSize.height
                state.probe.toggleOriginal?();await settle()
                checks["originalBindingExpands"] = state.probe.expanded && (scroll()?.contentSize.height ?? 0)>before+100
                snapshot("expanded")
                if let expanded=scroll() {
                    let bottom=max(0,expanded.contentSize.height-expanded.bounds.height+expanded.adjustedContentInset.bottom)
                    expanded.setContentOffset(CGPoint(x:0,y:bottom),animated:false);await settle()
                    checks["canReachBottom"] = abs(expanded.contentOffset.y-bottom)<2
                    checks["expandedNoHorizontalOverflow"] = expanded.contentSize.width <= expanded.bounds.width+1
                    snapshot("bottom")
                    expanded.setContentOffset(CGPoint(x:0,y:min(180,bottom)),animated:false);await settle()
                    let offset=expanded.contentOffset.y
                    let same=state.result;state.result=same;await settle()
                    checks["sameContentKeepsOffset"] = abs((scroll()?.contentOffset.y ?? -999)-offset)<2 && state.probe.expanded
                    state.previous=true;await settle()
                    checks["previousLabelKeepsOffset"] = abs((scroll()?.contentOffset.y ?? -999)-offset)<2 && state.probe.expanded
                    snapshot("previous")
                    state.result = .init(names:["新物件（合成）"],summary:"這是下一件物品的有效簡介。",text:[original],barcodes:["0099"])
                    await settle()
                    checks["newResultResetsTop"] = abs(scroll()?.contentOffset.y ?? -999)<2
                    checks["newResultCollapsesOriginal"] = !state.probe.expanded
                    snapshot("replacement")
                }
                state.probe.toggleOriginal?();await settle()
                let openHeight=scroll()?.contentSize.height ?? 0
                state.probe.toggleOriginal?();await settle()
                checks["originalBindingCollapses"] = !state.probe.expanded && (scroll()?.contentSize.height ?? 99999)<openHeight
            } else { checks["scrollViewFound"] = false }
            reports.append(["scenario":name,"width":width,"height":height,"checks":checks,"metrics":metrics,"passed":!checks.isEmpty && checks.values.allSatisfy { $0 }])
            window.isHidden=true;window.rootViewController=nil
        }
        reports += await historyCases(scene:scene,folder:folder,long:long,original:original)
        let passed = reports.count==cases.count+2 && reports.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String:Any] = ["fixture":"summary-reading-production-swiftui","revision":7,"processID":ProcessInfo.processInfo.processIdentifier,"recordedAt":ISO8601DateFormatter().string(from:Date()),"complete":true,"allPassed":passed,"cameraStarted":false,"networkRequests":0,"cases":reports,"scope":"Actual CameraView layout and RecognitionResultCard with synthetic preview/content. UIKit scroll offsets and production disclosure binding; not a physical finger gesture or real-camera acceptance."]
        if let data=try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) { try? data.write(to:folder.appendingPathComponent("report.json"),options:.atomic) }
        return passed
    }
}

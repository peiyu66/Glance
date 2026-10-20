import SwiftUI

/// Uses the app's own protected session in place, only after a valid single-use permit.
/// A consumed v2 permit may allow one existing-grant refresh, persisted in place.
/// No sign-in, credential export, or ordinary-history access exists here.
@MainActor final class TextTrialSession {
    private let load: () throws -> SIWCSaved?
    private let client: SIWCHTTP
    private let save: (SIWCSaved) throws -> Void
    private var updateEnabled = false
    private var updateFailed = false
    private var updateStage = SIWCExistingGrantSession.Stage.readiness
    private var updateReason: String?
    private var updateWriteStatus: OSStatus?
    private(set) var refreshRequests = 0
    private(set) var refreshes = 0
    private var authRequests: [String:Int] = [:]
    private var identity: String?
    private var listed = false
    private let now: () -> Date
    private var readiness: [String: Any] = [:]
    private var readinessFailed = false
    private var catalogRequestStarted = false
    private struct ReadinessFailure: Error { }
    init(load: @escaping () throws -> SIWCSaved? = SIWCKeychain.loadForTextTrial, client: SIWCHTTP = SIWCHTTP(), now: @escaping () -> Date = { Date() }, save: @escaping (SIWCSaved) throws -> Void = SIWCKeychain.saveForTextTrial) {
        self.load = load; self.client = client; self.now = now; self.save = save
    }
    private func failReadiness(_ reason: String) throws -> Never {
        readiness["readinessReason"] = reason; readinessFailed = true; throw ReadinessFailure()
    }
    private func account(stage: String, requireFresh: Bool = true) throws -> SIWCAccount {
        readiness = ["readinessStage": stage, "readinessReason": "checking", "refreshPolicy": updateEnabled ? "existing-grant-once" : "disabled-for-trial"]
        readinessFailed = false
        let saved: SIWCSaved?
        do { saved = try load() }
        catch let error as SIWCTrialSessionReadError {
            readiness["keychainStatus"] = error.status
            try failReadiness(error.kind.rawValue)
        } catch { try failReadiness("session-read-failed") }
        guard let saved else { try failReadiness("saved-session-missing") }
        guard let id = saved.selected else { try failReadiness("selected-account-missing") }
        guard let account = saved.accounts.first(where: { $0.id == id }) else { try failReadiness("selected-account-not-found") }
        guard let token = account.tokens else { try failReadiness("tokens-missing") }
        readiness["refreshCredentialPresent"] = token.refresh != nil
        readiness["planScopePresent"] = SIWCProtocol.hasPlan(token.scope)
        let remaining = token.expiresAt.timeIntervalSince(now())
        guard remaining.isFinite else { try failReadiness("access-expiry-invalid") }
        readiness["accessLifetimeBand"] = remaining <= 0 ? "expired" : remaining <= 60 ? "within-60-seconds" : "over-60-seconds"
        if requireFresh {
            guard remaining > 0 else { try failReadiness(updateEnabled ? "access-expired-after-session-update" : "access-expired-refresh-disabled") }
            guard remaining > 60 else { try failReadiness(updateEnabled ? "access-expiring-after-session-update" : "access-expiring-refresh-disabled") }
        }
        guard SIWCProtocol.hasPlan(token.scope) else { try failReadiness("plan-scope-missing") }
        guard identity == nil || identity == account.id + ":" + (account.authenticationTraceID?.uuidString ?? "none") else { try failReadiness("account-changed") }
        readiness["readinessReason"] = "ready"
        return account
    }
    /// Local account check only. No catalog, HTTP, refresh, login, or credential write.
    func checkReadiness() throws { _ = try account(stage: "local-preflight") }
    func prepare(validate: () throws -> Void, claimRefresh: () throws -> Void = { throw TextTrialStore.Failure.invalidPermit }) async throws {
        #if GLANCE_READINESS_DIAGNOSTIC
        throw SIWCReadinessNetworkDisabled()
        #else
        updateEnabled = true
        try validate(); let initial = try account(stage:"before-session-update", requireFresh:false)
        identity = initial.id + ":" + (initial.authenticationTraceID?.uuidString ?? "none")
        do {
            _ = try await SIWCExistingGrantSession.usable(account:initial,http:client,now:now,validate:{
                try validate(); _ = try self.account(stage:"session-update",requireFresh:false)
            },claimRefresh:{
                guard self.refreshRequests == 0 else { throw TextTrialStore.Failure.exhausted }
                try claimRefresh()
            },stage:{ self.updateStage = $0 },request:{
                self.authRequests[$0.rawValue,default:0] += 1
                if $0 == .refresh { self.refreshRequests += 1 }
            },save:{ replacement in
                guard var next = try self.load(), next.selected == initial.id,
                      let i = next.accounts.firstIndex(where: { $0.id == initial.id }),
                      next.accounts[i].authenticationTraceID == initial.authenticationTraceID,
                      next.accounts[i].tokens?.access == initial.tokens?.access,
                      next.accounts[i].tokens?.refresh == initial.tokens?.refresh else { throw SIWCError.invalidIdentity }
                next.accounts[i].tokens = replacement
                try self.save(next); self.refreshes += 1
            })
        } catch {
            updateFailed = true
            if let failure = error as? SIWCExistingGrantSession.Failure { updateReason = failure.rawValue }
            else if let failure = error as? SIWCTrialSessionWriteError { updateReason = "session-save-failed"; updateWriteStatus = failure.status }
            else if error is CancellationError { updateReason = "cancelled" }
            else { updateReason = "session-update-" + updateStage.rawValue + "-failed" }
            throw error
        }
        let account = try account(stage:"before-catalog")
        catalogRequestStarted = true
        let data = try await client.data(url: SIWCProtocol.resource + "/models", bearer: account.tokens!.access)
        try validate(); _ = try self.account(stage: "after-catalog")
        listed = try JSONDecoder().decode(SIWCCatalog.self, from: data).models.contains { $0.slug == "gpt-6-luna" && $0.visibility == "list" }
        guard listed else { throw SIWCError.modelUnavailable }
        #endif
    }
    func send(_ body: Data, willSend: @escaping () throws -> Void) async throws -> String {
        #if GLANCE_READINESS_DIAGNOSTIC
        throw SIWCReadinessNetworkDisabled()
        #else
        guard listed else { throw SIWCError.modelUnavailable }
        _ = try TextTrialContract.sources(in: body)
        let account = try account(stage: "before-response")
        let raw = try await client.stream(body: body, bearer: account.tokens!.access, operation: "bounded-text-review", validateBeforeImageSend: willSend)
        _ = try self.account(stage: "after-response")
        return raw
        #endif
    }
    func cancel() { client.cancelRequests() }
    var safeDiagnostic: [String: Any] {
        let allowed: Set<String> = ["phase", "httpStatus", "errorCategory", "errorCode", "errorParameter", "terminalEvent", "elapsedMilliseconds", "receivedBytes", "eventCount", "contentTypeClass", "streamCounts"]
        var result = client.diagnostics.filter { allowed.contains($0.key) }
        for (key, value) in readiness { result[key] = value }
        result["catalogRequestStarted"] = catalogRequestStarted
        if readinessFailed { result["errorCategory"] = "local-readiness" }
        if updateEnabled {
            result["sessionUpdateStage"] = updateStage.rawValue
            result["sessionUpdateFailed"] = updateFailed
            result["refreshRequests"] = refreshRequests; result["refreshes"] = refreshes
            result["authRequests"] = authRequests
            result["rotatedSessionPersisted"] = refreshes == 1
            result["refreshOutcomeMayBeUncertain"] = refreshRequests > 0 && refreshes == 0
            if let updateReason { result["sessionUpdateReason"] = updateReason }
            if let updateWriteStatus { result["keychainWriteStatus"] = updateWriteStatus }
        }
        return result
    }
    var readinessMessage: String? {
        guard readinessFailed, let reason = readiness["readinessReason"] as? String else { return nil }
        let detail: String
        switch reason {
        case "saved-session-missing": detail = "沒有已保存的本機會話。"
        case "selected-account-missing", "selected-account-not-found": detail = "沒有可用的已選帳戶。"
        case "tokens-missing": detail = "已選帳戶沒有可用憑證。"
        case "access-expired-refresh-disabled": detail = "現有會話已到期；本試驗不會更新憑證。"
        case "access-expiring-refresh-disabled": detail = "現有會話剩餘有效期不超過60秒；本試驗不會更新憑證。"
        case "plan-scope-missing": detail = "已存會話未包含本次需要的方案使用權限。"
        case "account-changed": detail = "檢查期間帳戶已變更。"
        case "session-decode-failed", "session-data-missing": detail = "本機會話資料無法解析；原資料保持。"
        case "keychain-interaction-unavailable": detail = "安全儲存暫不允許讀取；尚不能判定為登入失敗。"
        case "keychain-entitlement-missing": detail = "安全儲存權限設定不符合讀取要求。"
        default: detail = "本機帳戶狀態讀取失敗；原因已分類保存。"
        }
        return "試驗已停止：" + detail + "不會重送。"
    }
    func recordFailure(_ error: Error) { client.recordFailure(error) }
}

@MainActor @Observable final class TextTrialCoordinator {
    #if GLANCE_READINESS_DIAGNOSTIC
    private(set) var status = "帳戶前檢待開始；一般啟動不會讀取帳戶或傳送資料。"
    #else
    private(set) var status = "文字試驗待許可；一般啟動不會傳送資料。"
    #endif
    private(set) var phase = "idle"
    private(set) var submitted: [Int] = []
    private(set) var completed = false
    private(set) var preflightFinished = false
    private(set) var rows: [[String: Any]] = []
    private(set) var store: TextTrialStore?
    private let arguments: [String]
    private let documents: URL
    private let build: String
    private let cases: [TextTrialCase]
    private let sessionFactory: () -> TextTrialSession
    private let beforeWrite: (URL) throws -> Void
    private let timeout: Duration
    private var session: TextTrialSession?
    private var started = false
    private var cancelled = false
    private var work: Task<Void, Never>?
    init(arguments: [String], documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
         build: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
         cases: [TextTrialCase] = FixedTextTrialCatalog.cases, timeout: Duration = .seconds(70),
         sessionFactory: @escaping () -> TextTrialSession = { TextTrialSession() }, beforeWrite: @escaping (URL) throws -> Void = { _ in }) {
        self.arguments = arguments; self.documents = documents; self.build = build; self.cases = cases
        self.timeout = timeout; self.sessionFactory = sessionFactory; self.beforeWrite = beforeWrite
    }
    func start() { guard work == nil, !started else { return }; work = Task { await run() } }
    func run() async {
        guard !started else { return }; started = true
        let preflight = arguments.filter { $0.hasPrefix("--text-trial-readiness=") }
        if !preflight.isEmpty { runReadinessOnly(preflight); return }
        #if GLANCE_READINESS_DIAGNOSTIC
        if arguments.contains(where: { $0.hasPrefix("--text-trial-run=") || $0.hasPrefix("--text-trial-permit-sha=") }) {
            phase = "readiness-unavailable"; status = "此版本只提供本機帳戶前檢；模型試驗入口已停用。"
        }
        return
        #else
        let ids = arguments.filter { $0.hasPrefix("--text-trial-run=") }
        let hashes = arguments.filter { $0.hasPrefix("--text-trial-permit-sha=") }
        if ids.isEmpty && hashes.isEmpty { return }
        do {
            phase = "permit"
            guard !cancelled, ids.count == 1, hashes.count == 1,
                  let id = UUID(uuidString: String(ids[0].dropFirst("--text-trial-run=".count))) else { throw TextTrialStore.Failure.invalidPermit }
            let store = try TextTrialStore(base: documents.appendingPathComponent("GlanceTextTrial48"), runID: id,
                permitSHA256: String(hashes[0].dropFirst("--text-trial-permit-sha=".count)), build: build, cases: cases, beforeWrite: beforeWrite)
            self.store = store
            phase = "account"; status = "正在確認既有帳戶；必要時依本次許可更新既有會話一次。"; try report()
            try validate()
            let session = sessionFactory(); self.session = session
            let timeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(350)); self?.stop(reason: "timeout") } catch { }
            }
            defer { timeoutTask.cancel(); session.cancel() }
            try await session.prepare(validate:{ try self.validate() },claimRefresh:{ try self.validate(); try store.claimRefresh(); try self.report() })
            for sample in store.prepared {
                try validate(); try store.claim(sample.spec.sequence)
                phase = "request"; status = "文字試驗 \(submitted.count + 1)/4；不會重送。"; try report()
                let began = Date()
                let deadline = Task { [weak self] in
                    do { try await Task.sleep(for: self?.timeout ?? .seconds(70)); self?.stop(reason: "timeout") } catch { }
                }
                defer { deadline.cancel() }
                let raw = try await session.send(sample.body) {
                    try self.validate(); try store.validateClaim(sample.spec.sequence)
                    guard !self.submitted.contains(sample.spec.sequence), self.submitted.count < 4 else { throw TextTrialStore.Failure.exhausted }
                    self.submitted.append(sample.spec.sequence)
                }
                deadline.cancel()
                try validate(); try store.validateClaim(sample.spec.sequence)
                let data = Data(raw.utf8)
                guard data.count <= 32768 else { throw SIWCError.sseSizeLimit }
                try store.save(data, name: "response-\(sample.spec.sequence).json")
                let answer = try WikipediaSemanticReview.parse(raw, sources: sample.sources)
                try store.finish(sample.spec.sequence)
                rows.append(["sequence": sample.spec.sequence, "requestSHA256": sample.spec.bodySHA256,
                    "rawSHA256": RecognitionArchive.hash(data), "rawBytes": data.count,
                    "decision": answer.decision.rawValue, "elapsedMilliseconds": Int(Date().timeIntervalSince(began) * 1000),
                    "mechanicalContractPassed": true, "semanticContentAccepted": false])
                try report()
            }
            try store.stop(); completed = true; phase = "completed"; status = "四筆文字試驗完成；等待內容驗收。"; try report()
        } catch {
            session?.recordFailure(error); session?.cancel(); try? store?.stop()
            if !cancelled { phase = "failed"; status = session?.readinessMessage ?? "試驗已停止，不會重送；原紀錄保持。" }
            try? report()
        }
        #endif
    }
    /// Explicit single-use local diagnostic. Deliberately never calls prepare/send or opens a model permit.
    private func runReadinessOnly(_ flags: [String]) {
        defer { preflightFinished = true }
        do {
            guard flags.count == 1, !arguments.contains(where: { $0.hasPrefix("--text-trial-run=") || $0.hasPrefix("--text-trial-permit-sha=") }),
                  let id = UUID(uuidString: String(flags[0].dropFirst("--text-trial-readiness=".count))) else { throw TextTrialStore.Failure.invalidPermit }
            let base = documents.appendingPathComponent("GlanceTextTrialReadiness")
            if !FileManager.default.fileExists(atPath: base.path) { try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false) }
            let kind = try base.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard kind.isDirectory == true, kind.isSymbolicLink != true else { throw TextTrialStore.Failure.sourceMismatch }
            let folder = base.appendingPathComponent(id.uuidString)
            guard !FileManager.default.fileExists(atPath: folder.path) else { throw TextTrialStore.Failure.alreadyConsumed }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let file = folder.appendingPathComponent("summary.json")
            func save(_ value: [String: Any]) throws {
                try beforeWrite(file); try BoundedReplayStore.write(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]), to: file)
            }
            try save(["diagnosticRevision":"readiness-v1", "runID":id.uuidString, "phase":"started", "networkRequests":0, "modelRequests":0])
            let session = sessionFactory(); self.session = session
            defer { session.cancel() }
            do {
                try session.checkReadiness(); phase = "readiness-ready"
                status = "本機帳戶前置條件通過；沒有查模型或送出請求。"
            } catch {
                session.recordFailure(error); phase = "readiness-failed"
                status = session.readinessMessage ?? "本機帳戶檢查停止；沒有送出請求。"
            }
            try save(["diagnosticRevision":"readiness-v1", "appBuild":build, "runID":id.uuidString, "phase":phase,
                "networkRequests":0, "modelRequests":0, "refreshes":0, "newLogins":0, "credentialExports":0,
                "historyOpened":false, "modelPermitOpened":false, "diagnostic":session.safeDiagnostic,
                "recordedUTC":ISO8601DateFormatter().string(from:Date())])
        } catch { phase = "readiness-unavailable"; status = "本機狀態檢查無法執行或保存；未送出請求，不會重試。" }
    }
    private func validate() throws {
        try Task.checkCancellation()
        guard !cancelled, let store, !store.state.terminal, store.permit.expiresAt > Date().timeIntervalSince1970 else { throw TextTrialStore.Failure.stopped }
    }
    func stop(reason: String = "cancelled") {
        guard started, !completed else { return }
        cancelled = true; phase = reason; status = "試驗已停止，不會重送；原紀錄保持。"
        try? store?.stop(); session?.cancel(); work?.cancel(); try? report()
    }
    private func report() throws {
        guard let store else { return }
        let result: [String: Any] = ["trialRevision": TextTrialContract.revision, "appBuild": build,
            "runID": store.permit.runID.uuidString, "phase": phase, "completed": completed,
            "claims": store.state.claimed, "finished": store.state.finished, "submitted": submitted,
            "maximumRequests": 4, "maximumOutputTokensPerRequest": TextTrialContract.maxOutputTokens,
            "automaticRetries": 0, "imageRequests": 0, "cameraStarts": 0, "credentialExports": 0,
            "newLogins": 0, "refreshes": session?.refreshes ?? 0, "refreshRequests": session?.refreshRequests ?? 0, "refreshClaimed": store.state.refreshClaimed, "maximumRefreshRequests": 1, "ordinaryHistoryOpened": false, "globalConsentChanged": false,
            "results": rows, "diagnostic": session?.safeDiagnostic ?? [:], "recordedUTC": ISO8601DateFormatter().string(from: Date())]
        try store.save(JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]), name: "summary.json")
    }
}

struct BoundedTextTrialView: View {
    @State var coordinator: TextTrialCoordinator
    @Environment(\.scenePhase) private var scenePhase
    init(arguments: [String]) { _coordinator = State(initialValue: TextTrialCoordinator(arguments: arguments)) }
    init(coordinator: TextTrialCoordinator) { _coordinator = State(initialValue: coordinator) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                #if GLANCE_READINESS_DIAGNOSTIC
                Text("Glance 帳戶前檢").font(.title)
                #else
                Text("Glance 文字試驗").font(.title)
                #endif
                Text(coordinator.status).accessibilityIdentifier("textTrialStatus")
                #if GLANCE_READINESS_DIAGNOSTIC
                Text("只檢查此App的既有帳戶狀態，保存分類原因與必要狀態，不保存憑證或帳號個資。")
                Text("不連網、不登入、不更新憑證、不查詢模型、不取景；原辨識紀錄保持。須以本次單次檢查啟動，完成後不會自動進行其他測試。")
                #else
                Text("只處理已核准的四份文字資料。最多四次模型請求，每次輸出上限 8,192 tokens；不拍照、不重送圖片、不更動原辨識紀錄。")
                Text("必要時只更新既有會話一次；不建立新授權。更新失敗即停止，成功後最多再查一次模型清單。")
                Text("本測試包不提供一般辨識功能。沒有當次單次許可就不會讀取帳戶或傳送。")
                #endif
                if coordinator.phase != "idle", !coordinator.completed, !coordinator.preflightFinished {
                    Button("停止本次試驗") { coordinator.stop() }.accessibilityIdentifier("stopTextTrial")
                }
            }.padding()
        }.task { if scenePhase == .active { coordinator.start() } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { coordinator.start() } else { coordinator.stop(reason: "background") }
            }
    }
}

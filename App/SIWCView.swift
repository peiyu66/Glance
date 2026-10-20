import SwiftUI
import AuthenticationServices
import Observation

@MainActor @Observable final class SIWCController: NSObject, ASWebAuthenticationPresentationContextProviding {
    var authDiagnostic = SIWCAuthDiagnostic()
    private let authHTTPClient: SIWCHTTP
    private let allowsDataTransfer: () -> Bool
    private let dataTransferRevision: () -> UUID
    private let beginSignInOverride: (() -> Void)?
    private let authSaveSession: (SIWCSaved) throws -> Void
    private let authLoadSession: () throws -> SIWCSaved?
    private var authAuthorizationURL: URL?
    private var authControllerAttempt = 0
    private var authExchangeOrdinal = 0
    private var authTraceID: UUID?
    private var authenticatedTraceID: UUID?
    private var previousSubject: String?
    var attemptIdentityEmail: String?
    var confirmsDiagnosticAccount = false
    private var catalogTraceID: UUID?
    var latestAccountMatches: Bool {
        guard let latest = authDiagnostic.latestSignIn, latest.outcome == .succeeded,
              let trace = account?.authenticationTraceID else { return false }
        return latest.traceID == trace && authenticatedTraceID == trace && planAccessReady
    }
    var diagnosticReady: Bool { latestAccountMatches && confirmsDiagnosticAccount }
    var diagnosticImageReady: Bool { diagnosticReady && catalogTraceID == account?.authenticationTraceID && selectedModel == "gpt-6-luna" }
    var signInResultText: String {
        authActive ? "正在更換帳戶；完成前仍保留現行帳戶。" : authDiagnostic.signInResultText
    }
    private func requireDiagnosticAccount(_ trace: UUID) throws {
        guard allowsDataTransfer(), diagnosticReady, account?.authenticationTraceID == trace else { throw SIWCError.invalidIdentity }
    }
    private var authStartedAt: TimeInterval?
    private var authBrowserAt: TimeInterval?
    private var authCallbackAt: TimeInterval?
    private var authCodeObservation = SIWCAuthCodeObservation()
    init(beginSignIn: (() -> Void)? = nil, dataTransferRevision: @escaping () -> UUID = { DataConsentController.shared.epoch }, allowsDataTransfer: @escaping () -> Bool = { DataConsentController.shared.allowsTransfer }, authHTTPClient: SIWCHTTP = .shared, authSaveSession: @escaping (SIWCSaved) throws -> Void = SIWCKeychain.save,
         authLoadSession: @escaping () throws -> SIWCSaved? = SIWCKeychain.load) {
        self.dataTransferRevision = dataTransferRevision; self.beginSignInOverride = beginSignIn; self.allowsDataTransfer = allowsDataTransfer; self.authHTTPClient = authHTTPClient; self.authSaveSession = authSaveSession; self.authLoadSession = authLoadSession
        super.init()
    }
    private var authStage: SIWCAuthStage = .storage
    private var authActive = false
    private var authCallbackCategory: SIWCAuthCategory?
    private var authCallbackCode: String?
    private var authCallbackDescription: SIWCErrorDescriptionDiagnostic?
    var saved: SIWCSaved?
    var selectedID = ""
    var catalog: [SIWCModel] = []
    var selectedModel = ""
    var status = "準備就緒；尚未開啟官方授權。"
    private(set) var refreshCount = 0
    var busy = false
    var output = ""
    private var restoredSession = false
    private var fixtureChecks: [String: Bool] = [:]
    private var attempt = UUID()
    private var work: Task<Void, Never>?
    private var browser: ASWebAuthenticationSession?
    private var listener: SIWCLoopback?
    private var currentPending: SIWCPending?
    private var discovery: SIWCDiscovery?
    static let accountRevision = "S1"
    static let usageWarningRevision = "W2"
    static let usageWarning = "額度與額外點數由 ChatGPT 設定控制，請確認額外點數已停用。"
    private var registrationID: String?
    private var registrationLabel: String?
    private var unsavedPending: [SIWCPendingRegistration] = []
    private var storageUnavailable = false
    private var authSelectedClientID: String?
    private var authSelectedClientSource: SIWCAuthClientSource = .newRegistration
    private var authExpectedSubject: String?
    private var authSameAccountWorkspaceConfirmed = false
    private var authCodeCheck: (previouslySubmitted: Bool, comparedCount: Int)?
    var registrationRetryID: String? {
        guard !storageUnavailable, let id = saved?.recoveryRegistrationID,
              let pending = saved?.pendingRegistrations.first(where: { $0.id == id }),
              pending.retry?.state == .available, !pending.clientID.isEmpty,
              pending.clientID != "dynamic_agent_client", pending.clientID.count <= 256 else { return nil }
        return id
    }
    var pendingRegistrations: [SIWCPendingRegistration] {
        let persisted = saved?.pendingRegistrations ?? []
        return persisted + unsavedPending.filter { p in !persisted.contains { $0.id == p.id } }
    }
    private var originalIdle = false
    var account: SIWCAccount? { saved?.accounts.first { $0.id == selectedID } }
    var authenticated: Bool { account?.tokens != nil }
    var planEnabled: Bool { SIWCProtocol.hasPlan(account?.tokens?.scope ?? "") }
    var planAccessReady: Bool { !storageUnavailable && authenticated && planEnabled }

    func load() {
        if !authActive { restoreAuthDiagnostic() }
        do {
            var loaded = try authLoadSession(); loaded?.assignMissingLabels()
            saved = loaded; selectedID = loaded?.selected ?? ""; storageUnavailable = false
            restoredSession = authenticated
            authenticatedTraceID = account?.authenticationTraceID
            if !authActive {
                if let failure = authDiagnostic.latestSignIn?.failure { status = failure.text }
                else if authDiagnostic.latestSignIn == nil { status = authenticated ? "" : "登入後才能使用方案額度。" }
                else if status == "準備就緒；尚未開啟官方授權。" { status = "" }
            }
            report("ready")
        }
        catch { storageUnavailable = true; status = "無法讀取 Glance 本機安全會話；保留原資料，請解鎖裝置後重試。"; report("storage-unavailable") }
    }
    /// One active account; no legacy account or pending-registration picker.
    func beginNewAccount() { begin() }
    func retryRegistration(_ id: String, confirmedSameAccountAndWorkspace: Bool) {
        guard !busy else { return }
        guard confirmedSameAccountAndWorkspace, registrationRetryID == id else {
            status = "這次續試未確認或已不可用；沒有開始登入。"; return
        }
        begin(recoveryID: id, confirmedSameAccountAndWorkspace: true)
    }
    private func prepareRegistrationAttempt(recoveryID: String? = nil, confirmedSameAccountAndWorkspace: Bool = false) throws {
        guard !storageUnavailable else { throw SIWCError.invalidResponse }
        authSelectedClientID = nil; authSelectedClientSource = .newRegistration
        authExpectedSubject = nil; authSameAccountWorkspaceConfirmed = false
        if let recoveryID {
            guard var next = saved, next.recoveryRegistrationID == recoveryID,
                  let index = next.pendingRegistrations.firstIndex(where: { $0.id == recoveryID }),
                  var retry = next.pendingRegistrations[index].retry,
                  retry.consume(confirmedSameAccountAndWorkspace: confirmedSameAccountAndWorkspace) else { throw SIWCError.invalidResponse }
            let pending = next.pendingRegistrations[index]
            guard !pending.clientID.isEmpty, pending.clientID != "dynamic_agent_client", pending.clientID.count <= 256 else { throw SIWCError.invalidResponse }
            next.pendingRegistrations[index].retry = retry
            // Persist consumption before any discovery, listener or browser work.
            do { try authSaveSession(next) } catch { storageUnavailable = true; authStage = .storage; throw error }
            saved = next; registrationID = pending.id; registrationLabel = pending.label
            authSelectedClientID = pending.clientID; authSelectedClientSource = .retainedRetry
            authExpectedSubject = next.accounts.first(where: { $0.clientID == pending.clientID })?.subject
            authSameAccountWorkspaceConfirmed = true
            return
        }
        // A deliberate new registration supersedes only the offer, never credentials.
        if var next = saved, next.recoveryRegistrationID != nil {
            next.recoveryRegistrationID = nil
            do { try authSaveSession(next) } catch { storageUnavailable = true; authStage = .storage; throw error }
            saved = next
        }
        registrationID = UUID().uuidString
        let occupied = Set((saved?.accounts.compactMap(\.label) ?? []) + pendingRegistrations.map(\.label))
        var index = 1; while occupied.contains("連線 \(index)") { index += 1 }
        registrationLabel = "連線 \(index)"
    }
    private func retainRetryAfterFirstFailure(_ error: Error) -> Bool {
        guard authStage == .tokenExchange, authSelectedClientSource == .newRegistration,
              let http = error as? SIWCHTTPError, http.status == 400, let registrationID,
              var next = saved, let index = next.pendingRegistrations.firstIndex(where: { $0.id == registrationID }),
              var retry = next.pendingRegistrations[index].retry,
              retry.recordExchangeFailure(errorCode: http.code, exchangeOrdinal: authExchangeOrdinal) else { return true }
        next.pendingRegistrations[index].retry = retry; next.recoveryRegistrationID = registrationID
        var binding = SIWCAuthBindingChecks()
        do {
            try authSaveSession(next); saved = next
            binding.retryAvailable = true; binding.retryStatePersisted = true
            authRecord(.registration, .checked, binding: binding)
            return true
        } catch {
            storageUnavailable = true
            binding.retryAvailable = false; binding.retryStatePersisted = false
            authRecord(.storage, .checked, binding: binding)
            return false
        }
    }
    private func persistRegistrationState() throws {
        guard !storageUnavailable else { throw SIWCError.invalidResponse }
        var next = saved ?? SIWCSaved(hostID: "urn:uuid:" + UUID().uuidString.lowercased(), accounts: [], selected: nil)
        next.pendingRegistrations = pendingRegistrations
        next.assignMissingLabels()
        try authSaveSession(next); saved = next; unsavedPending = []
    }
    private func checkpointRegistration(issued: String, selected: SIWCAccount?) throws {
        if let selected {
            guard selected.clientID == issued else { throw SIWCError.invalidIdentity }
            return
        }
        guard let id = registrationID, let label = registrationLabel else { throw SIWCError.invalidResponse }
        if let existing = pendingRegistrations.first(where: { $0.id == id }) {
            guard existing.clientID == issued else { throw SIWCError.invalidIdentity }
        } else {
            unsavedPending.append(SIWCPendingRegistration(id: id, label: label, clientID: issued, savedAt: Date(), retry: SIWCRegistrationRetry()))
        }
        // A storage failure keeps metadata in memory and stops before consuming the code.
        try persistRegistrationState()
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    /// Called only by the user's button, or a launch explicitly authorized for this sign-in attempt.
    func begin() { begin(recoveryID: nil, confirmedSameAccountAndWorkspace: false) }
    private func begin(recoveryID: String?, confirmedSameAccountAndWorkspace: Bool) {
        guard allowsDataTransfer() else { status = "請先閱讀並同意資料處理說明。"; return }
        guard !busy else { return }
        if let beginSignInOverride { beginSignInOverride(); return }
        busy = true; output = ""; let transaction = UUID(); attempt = transaction
        originalIdle = UIApplication.shared.isIdleTimerDisabled
        prepareAuthDiagnostics(); authStep(.registration)
        do { try prepareRegistrationAttempt(recoveryID: recoveryID, confirmedSameAccountAndWorkspace: confirmedSameAccountAndWorkspace); authRecord(.registration, .succeeded) }
        catch { fail(error); endAttempt(); return }
        authStep(.storage)
        originalIdle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        status = "準備官方登入；密碼與同意請本人操作。"; report("preparing")
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try persistRegistrationState()
                guard let saved = self.saved else { throw SIWCError.invalidResponse }
                authStep(.discovery)
                let discovery = try await SIWCDiscovery.load(observeHTTP: { [weak self] status in self?.authHTTP(status, stage: .discovery, transaction: transaction) }, http: authHTTPClient)
                guard self.attempt == transaction, !Task.isCancelled else { return }
                self.discovery = discovery
                authRecord(.discovery, .succeeded)
                authStep(.listener)
                let selected: SIWCAccount? = nil // Pending recovery never borrows an active account hint or credential.
                let listener = SIWCLoopback(diagnostic: { [weak self] detail in
                    Task { @MainActor in self?.authCallback(detail, transaction: transaction) }
                }) { [weak self] result in
                    Task { @MainActor in
                        self?.loopbackReturned(result, selected: selected, transaction: transaction)
                    }
                }
                self.listener = listener
                listener.start(clientID: self.authClientSelection().id) { [weak self] pending in
                    Task { @MainActor in
                        guard let self, self.attempt == transaction else { return }
                        self.currentPending = pending
                        self.authRecord(.listener, .succeeded)
                        self.authStep(.browser)
                        let url = pending.authorize(hostID: saved.hostID, idTokenHint: selected?.tokens?.idToken)
                        self.recordAuthorizationBindings(url: url, pending: pending)
                        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, error in
                            Task { @MainActor in
                                guard let self, self.attempt == transaction, self.browser != nil else { return }
                                self.browserFinished(error)
                                self.endAttempt()
                            }
                        }
                        session.presentationContextProvider = self
                        self.browser = session
                        guard session.start() else { self.fail(SIWCError.invalidResponse); self.endAttempt(); return }
                        self.status = "請在 auth.openai.com 官方頁面自行登入並決定授權。"
                        self.report("awaiting-user-in-official-window")
                    }
                }
            } catch { guard self.attempt == transaction else { return }; self.fail(error); self.endAttempt() }
        }
    }
    private func loopbackReturned(_ result: Result<(SIWCPending, String, String), Error>, selected: SIWCAccount?, transaction: UUID) {
        guard attempt == transaction else { return }
        switch result {
        case .success(let (pending, code, issued)):
            authCallbackAt = ProcessInfo.processInfo.systemUptime
            var binding = SIWCAuthBindingChecks(); binding.callbackStateValidated = true
            binding.authorizationToCallbackMilliseconds = milliseconds(since: authBrowserAt)
            authRecord(.callback, .succeeded, binding: binding)
            currentPending = nil; listener?.stop(); listener = nil
            // Clear before cancel so the browser callback cannot abort exchange.
            let browser = self.browser; self.browser = nil; browser?.cancel()
            work = Task { await self.exchange(pending: pending, code: code, issued: issued, selected: selected, transaction: transaction) }
        case .failure(let error): loopbackFailed(error, transaction: transaction); endAttempt()
        }
    }
    private func exchange(pending: SIWCPending, code: String, issued: String, selected: SIWCAccount?, transaction: UUID) async {
        do {
            guard let discovery else { throw SIWCError.invalidResponse }
            guard attempt == transaction, !Task.isCancelled else { return }
            try checkpointRegistration(issued: issued, selected: selected)
            status = "驗證官方回應與身份…"; report("validating")
            authStep(.tokenExchange)
            let observed = authCodeObservation.observe(code)
            authCodeCheck = (observed.previouslySubmitted, observed.comparedCount)
            guard !observed.previouslySubmitted else {
                var binding = SIWCAuthBindingChecks(); binding.codePreviouslySubmittedInWindow = true
                binding.codeComparisonWindowCount = observed.comparedCount
                authRecord(.tokenExchange, .failed, category: .callbackConsumed, binding: binding)
                status = "收到已使用的授權碼，已停止且未送出交換。"
                if authenticated { status += "原帳戶已保留。" }
                endAttempt(); return
            }
            let data = try await authHTTPClient.data(url: discovery.token_endpoint, body: pending.codeExchange(code: code, issuedClientID: issued), form: true,
                observeRequest: { [weak self] request in self?.recordExchangeBindings(request: request, pending: pending, code: code, issued: issued, transaction: transaction) },
                observeResponse: { [weak self] response in
                    guard let self, self.attempt == transaction, self.authActive else { return }
                    self.authRecord(.tokenExchange, .response, httpStatus: response.status, service: response)
                })
            guard attempt == transaction, !Task.isCancelled else { return }
            authRecord(.tokenExchange, .succeeded); authStep(.tokenDecode)
            let response = try JSONDecoder().decode(SIWCTokenResponse.self, from: data)
            let tokens = try response.tokens()
            authRecord(.tokenDecode, .succeeded); authStep(.jwks)
            let jwks = try await authHTTPClient.data(url: discovery.jwks_uri, observeHTTP: { [weak self] status in self?.authHTTP(status, stage: .jwks, transaction: transaction) })
            guard attempt == transaction, !Task.isCancelled else { return }
            authRecord(.jwks, .succeeded); authStep(.identity)
            let identity = try SIWCIdentityVerifier.verify(tokens.idToken, jwks: jwks, clientID: issued, nonce: pending.nonce, expectedSubject: authExpectedSubject)
            guard attempt == transaction, !Task.isCancelled else { return }
            attemptIdentityEmail = identity.email
            authDiagnostic.recordIdentityComparison(sameSubjectAsPrevious: previousSubject.map { $0 == identity.subject })
            authRecord(.identity, .succeeded)
            authStep(.permission)
            guard SIWCProtocol.hasPlan(tokens.scope) else { throw SIWCError.planDisabled }
            authStep(.saveSession)
            let account = SIWCAccount(clientID: issued, subject: identity.subject, email: identity.email, tokens: tokens, planOnlyConfirmed: false, label: registrationLabel, authenticationTraceID: authTraceID)
            guard var next = saved else { throw SIWCError.invalidResponse }
            next.accounts.removeAll { $0.id == account.id }; next.accounts.append(account); next.selected = account.id
            if let registrationID {
                next.pendingRegistrations.removeAll { $0.id == registrationID }
                if next.recoveryRegistrationID == registrationID { next.recoveryRegistrationID = nil }
            }
            try authSaveSession(next); saved = next; selectedID = account.id
            authenticatedTraceID = authTraceID
            if let registrationID { unsavedPending.removeAll { $0.id == registrationID } }
            catalog = []; selectedModel = ""
            authRecord(.saveSession, .succeeded)
            authRecord(.permission, .succeeded, category: SIWCProtocol.hasPlan(tokens.scope) ? .planEnabled : .planDisabled)
            status = "登入完成。"
            report(SIWCProtocol.hasPlan(tokens.scope) ? "authenticated-plan-enabled" : "authenticated-plan-disabled")
            endAttempt()
        } catch {
            guard attempt == transaction else { return }
            let retryStateSaved = retainRetryAfterFirstFailure(error)
            fail(error)
            if !retryStateSaved { status += "無法保存續試狀態；已停止，不會開啟另一個登入。" }
            else if authSelectedClientSource == .retainedRetry { status += "這次續試已結束，不會自動重試。" }
            endAttempt()
        }
    }
    func cancel() { if authActive { authRecord(authStage, .cancelled, category: .userCancelled) }; status = "已取消目前操作。"; report("cancelled"); work?.cancel(); endAttempt() }
    private func endAttempt() {
        authActive = false
        attempt = UUID(); listener?.stop(); listener = nil; currentPending = nil; authAuthorizationURL = nil
        let old = browser; browser = nil; old?.cancel(); busy = false
        UIApplication.shared.isIdleTimerDisabled = originalIdle
    }
    func foreground() {
        if let pending = currentPending, pending.deadline <= Date() { authRecord(.callback, .failed, category: .timeout); status = "登入嘗試已逾時，請重新開始。"; report("timeout"); endAttempt() }
    }
    private func usableTokens() async throws -> SIWCTokens {
        guard let account, account.tokens != nil else { throw SIWCError.invalidIdentity }
        do {
            return try await SIWCExistingGrantSession.usable(account:account) { replacement in
                guard var next = self.saved, let index = next.accounts.firstIndex(where: { $0.id == account.id }) else { throw SIWCError.invalidIdentity }
                next.accounts[index].tokens = replacement
                try SIWCKeychain.save(next); self.saved = next; self.refreshCount += 1
            }
        } catch let error as SIWCHTTPError where error.terminalRefresh {
            try clearTokens(accountID: account.id); throw error
        }
    }
    func models() {
        guard !busy, diagnosticReady, let trace = account?.authenticationTraceID else {
            status = "尚未確認此次成功換入的帳戶；沒有讀取模型，亦不使用原帳戶代測。"; return
        }
        busy = true; catalog = []; selectedModel = ""; catalogTraceID = nil
        var operation = SIWCValidationEvidence(operationID: UUID()); operation.sessionAuthenticationTraceID = trace
        authRecord(.modelCatalog, .started, validation: operation)
        work = Task {
            defer { busy = false }
            do {
                let tokens = try await usableTokens(); guard SIWCProtocol.hasPlan(tokens.scope) else { throw SIWCError.planDisabled }
                try requireDiagnosticAccount(trace); try Task.checkCancellation()
                let data = try await authHTTPClient.data(url: SIWCProtocol.resource + "/models", bearer: tokens.access,
                    observeResponse: { self.authRecord(.modelCatalog, .response, httpStatus: $0.status, service: $0, validation: operation) })
                let models = try JSONDecoder().decode(SIWCCatalog.self, from: data).models.filter { $0.visibility == "list" }
                try Task.checkCancellation(); try requireDiagnosticAccount(trace)
                catalog = models; catalogTraceID = trace
                selectedModel = models.contains { $0.slug == "gpt-6-luna" } ? "gpt-6-luna" : ""
                var evidence = operation; evidence.visibleModelCount = models.count; evidence.candidateListed = !selectedModel.isEmpty
                authRecord(.modelCatalog, .succeeded, validation: evidence)
                status = selectedModel.isEmpty ? "已讀取模型；候選 gpt-6-luna 不在清單，尚未選擇替代模型。" : "帳戶提供 gpt-6-luna；none 與影像能力仍待最小測試。"
                report("catalog-loaded")
            } catch { validationFailure(error, stage: .modelCatalog, evidence: operation); fail(error) }
        }
    }
    /// One explicitly authorized diagnostic retry; never enabled for ordinary launches.
    func runAuthorizedSyntheticTest() async {
        guard diagnosticReady else { status = "尚未確認此次成功換入的帳戶；未啟動受控測試。"; report("test-not-started"); return }
        models()
        let catalogWork = work; await catalogWork?.value
        guard !Task.isCancelled, !selectedModel.isEmpty, !busy else { return }
        imageTest()
        let imageWork = work; await imageWork?.value
    }
    func imageTest() {
        guard allowsDataTransfer(), !busy, diagnosticImageReady, let trace = account?.authenticationTraceID else {
            status = "此次帳戶尚未完成模型清單驗證；沒有送圖，亦不使用原帳戶代測。"; return
        }
        busy = true; output = ""; fixtureChecks = [:]
        let model = selectedModel
        var operation = SIWCValidationEvidence(operationID: UUID()); operation.sessionAuthenticationTraceID = trace
        authRecord(.syntheticImage, .started, validation: operation)
        work = Task {
            defer { busy = false }
            do {
                let tokens = try await usableTokens(); guard SIWCProtocol.hasPlan(tokens.scope) else { throw SIWCError.planDisabled }
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256))
                let png = renderer.pngData { context in
                    UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
                    UIColor.red.setFill(); context.fill(CGRect(x: 32, y: 32, width: 100, height: 100))
                    ("GLANCE 123" as NSString).draw(at: CGPoint(x: 24, y: 180), withAttributes: [.font: UIFont.systemFont(ofSize: 28), .foregroundColor: UIColor.black])
                }
                let body = try SIWCInference.body(model: model, catalog: catalog, png: png)
                status = "傳送一張程式生成的測試圖；不讀相機或相簿。"; report("synthetic-image-request")
                try requireDiagnosticAccount(trace); try Task.checkCancellation()
                let text = try await authHTTPClient.stream(body: body, bearer: tokens.access,
                    validateBeforeImageSend: { try self.requireDiagnosticAccount(trace) },
                    observeResponse: { self.authRecord(.syntheticImage, .response, httpStatus: $0.status, service: $0, validation: operation) })
                try Task.checkCancellation(); try requireDiagnosticAccount(trace); output = text
                let lower = text.lowercased()
                fixtureChecks = ["red": lower.contains("red") || text.contains("紅") || text.contains("红"),
                                 "square": lower.contains("square") || text.contains("方形"),
                                 "text": lower.contains("glance") && text.contains("123")]
                var evidence = operation; evidence.completed = true
                evidence.red = fixtureChecks["red"]; evidence.square = fixtureChecks["square"]; evidence.text = fixtureChecks["text"]
                authRecord(.syntheticImage, .succeeded, validation: evidence)
                status = "此帳戶已收到 response.completed；合成圖內容檢查另列於安全診斷。這不等於證實帳戶方案名稱。"; report("synthetic-image-completed")
            } catch { validationFailure(error, stage: .syntheticImage, evidence: operation); fail(error) }
        }
    }
    /// Camera provider uses the same Keychain account and serialized refresh path.
    func recognize(jpeg: Data, requestID: String? = nil, searchEvidence: BarcodeSearchEvidence? = nil, validateBeforeImageSend: (() throws -> Void)? = nil, capturePreparseResponse: ((String) -> Void)? = nil) async throws -> RecognitionResult {
        let callerValidation = validateBeforeImageSend
        let consentEpoch = dataTransferRevision()
        let validateBeforeImageSend = { [self] in
            guard allowsDataTransfer(), dataTransferRevision() == consentEpoch else { throw CancellationError() }
            try callerValidation?()
        }
        try validateBeforeImageSend()
        guard !busy, planAccessReady else { throw SIWCError.planDisabled }
        busy = true; defer { busy = false }
        SIWCHTTP.shared.prepareCameraRequest(requestID)
        do {
            let tokens = try await usableTokens()
            guard SIWCProtocol.hasPlan(tokens.scope) else { throw SIWCError.planDisabled }
            if catalog.isEmpty {
                let data = try await SIWCHTTP.shared.data(url: SIWCProtocol.resource + "/models", bearer: tokens.access)
                catalog = try JSONDecoder().decode(SIWCCatalog.self, from: data).models.filter { $0.visibility == "list" }
            }
            try Task.checkCancellation()
            let body = try CameraAnswer.request(model: "gpt-6-luna", catalog: catalog, jpeg: jpeg, searchEvidence: searchEvidence)
            let answer = try await SIWCHTTP.shared.stream(body: body, bearer: tokens.access, operation: "camera-image", cameraRequestID: requestID, validateBeforeImageSend: validateBeforeImageSend)
            try Task.checkCancellation()
            guard allowsDataTransfer(), dataTransferRevision() == consentEpoch else { throw CancellationError() }
            capturePreparseResponse?(answer)
            SIWCHTTP.shared.markStage("result-json-parse")
            let result = try CameraAnswer.parse(answer, expectingStructured: true, searchEvidence: searchEvidence)
            SIWCHTTP.shared.markStage("result-parsed")
            return result
        } catch { SIWCHTTP.shared.recordFailure(error); throw error }
    }
    /// Text-only optional enrichment uses an independent transport and the current
    /// already-usable session. It never races a rotating refresh token or starts auth.
    var recognitionAccountIdentity: String { selectedID + ":" + (account?.authenticationTraceID?.uuidString ?? "none") }
    func reviewWikipedia(input: Data, validate: @escaping () throws -> Void,
                         willSend: @escaping () async throws -> Void, transportStarted: @escaping () -> Void) async throws -> String {
        let identity = recognitionAccountIdentity, epoch = dataTransferRevision()
        let validateRequest = { [self] in
            try Task.checkCancellation(); try validate()
            guard allowsDataTransfer(), dataTransferRevision() == epoch, recognitionAccountIdentity == identity,
                  planAccessReady else { throw CancellationError() }
        }
        try validateRequest()
        guard !busy, let tokens = account?.tokens, tokens.expiresAt > Date().addingTimeInterval(60), SIWCProtocol.hasPlan(tokens.scope) else { throw SIWCError.planDisabled }
        let body = try WikipediaSemanticReview.request(input: input, catalog: catalog)
        try await willSend()
        try validateRequest()
        let client = SIWCHTTP()
        defer { client.cancelRequests() }
        return try await withTaskCancellationHandler {
            let answer = try await client.stream(body: body, bearer: tokens.access, operation: "wikipedia-text-review", validateBeforeImageSend: validateRequest, transportStarted: transportStarted)
            try validateRequest()
            return answer
        } onCancel: { Task { @MainActor in client.cancelRequests() } }
    }
    func signOut() {
        guard !busy, let account else { return }; busy = true; catalog = []; selectedModel = ""; output = ""
        work = Task {
            defer { busy = false }
            var revoked = account.tokens?.refresh == nil
            if let refresh = account.tokens?.refresh {
                for tryIndex in 0..<2 {
                    do {
                        let config = try await SIWCDiscovery.load()
                        _ = try await SIWCHTTP.shared.data(url: config.revocation_endpoint,
                            body: SIWCProtocol.form(["token": refresh, "token_type_hint": "refresh_token", "client_id": account.clientID]), form: true)
                        revoked = true; break
                    } catch let error as SIWCHTTPError { if error.status < 500 { break } }
                    catch {}
                    if tryIndex == 0 { try? await Task.sleep(for: .seconds(1)) }
                }
            }
            do { try clearTokens(accountID: account.id); status = revoked ? "已結束可續期會話並清除本機 tokens。" : "本機已登出，但遠端撤銷未確認；請到 ChatGPT 設定斷開 Glance。"; report(revoked ? "signed-out" : "signed-out-revocation-unconfirmed") }
            catch { status = "無法清除本機會話，請重試；亦可先在 ChatGPT 設定斷開 Glance。"; report("storage-unavailable") }
        }
    }
    private func clearTokens(accountID: String) throws {
        guard var next = saved, let index = next.accounts.firstIndex(where: { $0.id == accountID }) else { return }
        next.accounts[index].tokens = nil
        try authSaveSession(next); saved = next
    }
    /// Exercises production diagnostic handlers only. Never calls begin/load/network/Keychain.
    func runAuthDiagnosticFixture() -> (checks: [String: Bool], examples: [SIWCAuthDiagnostic]) {
        precondition(ProcessInfo.processInfo.arguments.contains("--siwc-auth-fixture"))
        var checks: [String: Bool] = [:]; var examples: [SIWCAuthDiagnostic] = []
        func start() { authDiagnostic = SIWCAuthDiagnostic(); authDiagnostic.begin(); authActive = true; attempt = UUID(); authCallbackCategory = nil; authCallbackCode = nil; authCallbackDescription = nil }
        start(); let transaction = attempt
        for stage in [SIWCAuthStage.discovery, .callback, .tokenExchange, .tokenDecode, .jwks, .identity, .saveSession] {
            authStep(stage)
            if [.discovery, .tokenExchange, .jwks].contains(stage) { authHTTP(200, stage:stage, transaction:transaction) }
            authRecord(stage,.succeeded)
        }
        authRecord(.permission,.succeeded,category:.planEnabled)
        checks["success_complete_stages"] = authDiagnostic.events.last?.category == .planEnabled && authDiagnostic.events.filter { $0.outcome == .response }.count == 3
        examples.append(authDiagnostic)
        start();authStep(.tokenExchange)
        authHTTP(404,stage:.tokenExchange,transaction:attempt)
        authFailure(SIWCHTTPError(status:404,code:nil,requestID:"private-request-marker",parameter:nil,bodyShape:"non-object"))
        checks["token_404_exact_stage"] = authDiagnostic.events.last?.httpStatus == 404 && authDiagnostic.events.last?.stage == .tokenExchange
        checks["http_404_visible"] = authDiagnostic.events.last?.text.contains("HTTP 404") == true
        examples.append(authDiagnostic)
        start();authStep(.jwks);authFailure(URLError(.cannotConnectToHost))
        checks["transport_no_invented_http"] = authDiagnostic.events.last?.category == .transport && authDiagnostic.events.last?.httpStatus == nil
        examples.append(authDiagnostic)
        start();browserFinished(NSError(domain:ASWebAuthenticationSessionError.errorDomain,code:ASWebAuthenticationSessionError.Code.canceledLogin.rawValue))
        checks["browser_cancel_classified"] = authDiagnostic.events.last?.outcome == .cancelled && authDiagnostic.events.last?.category == .userCancelled
        examples.append(authDiagnostic)
        start();browserFinished(NSError(domain:ASWebAuthenticationSessionError.errorDomain,code:ASWebAuthenticationSessionError.Code.presentationContextInvalid.rawValue))
        checks["browser_error_not_cancel"] = authDiagnostic.events.last?.outcome == .failed && authDiagnostic.events.last?.category == .browser
        examples.append(authDiagnostic)
        start();browserFinished(nil)
        checks["empty_browser_return_not_user_cancel"] = authDiagnostic.events.last?.outcome == .failed
        start();authStep(.identity);authFailure(SIWCError.invalidIdentity)
        checks["identity_error_no_http"] = authDiagnostic.events.last?.category == .identity && authDiagnostic.events.last?.httpStatus == nil
        examples.append(authDiagnostic)
        start();authStep(.tokenDecode);authFailure(SIWCError.invalidResponse)
        checks["parse_error_no_inherited_http"] = authDiagnostic.events.last?.category == .invalidResponse && authDiagnostic.events.last?.httpStatus == nil
        start();loopbackFailed(SIWCLoopbackDenial(diagnostic:.init(accepted:false,category:.oauthError,errorCode:"3p_login_workspace_scope_denied")),transaction:attempt)
        checks["service_denial_not_user_cancel"] = authDiagnostic.events.last?.category == .oauthError && authDiagnostic.events.last?.errorCode == "3p_login_workspace_scope_denied"
        examples.append(authDiagnostic)
        start();authCallback(.init(accepted:false,category:.callbackState),transaction:attempt)
        checks["callback_rejection_visible"] = authDiagnostic.events.last?.category == .callbackState
        authCallback(.init(accepted:false,category:.repeatedReturn),transaction:attempt)
        checks["repeated_return_ignored"] = authDiagnostic.events.last?.outcome == .ignored && authDiagnostic.events.last?.category == .repeatedReturn
        examples.append(authDiagnostic)
        let old = attempt; attempt = UUID(); let count = authDiagnostic.events.count
        authHTTP(404,stage:.tokenExchange,transaction:old)
        authCallback(.init(accepted:false,category:.oauthError,errorCode:"access_denied"),transaction:old)
        checks["old_attempt_cannot_pollute_new"] = authDiagnostic.events.count == count
        authActive=false;authHTTP(404,stage:.tokenExchange,transaction:attempt)
        checks["finished_attempt_ignores_http"] = authDiagnostic.events.count == count
        start();authRecord(.permission,.succeeded,category:.planDisabled)
        checks["identity_without_plan_not_failed"] = authDiagnostic.events.last?.outcome == .succeeded && authDiagnostic.events.last?.category == .planDisabled
        let encoded=(try? JSONEncoder().encode(examples)).map { String(decoding:$0,as:UTF8.self) } ?? "private-request-marker"
        checks["request_identifier_not_serialized"] = !encoded.contains("private-request-marker")
        checks["no_saved_account_or_keychain_load"] = saved == nil && selectedID.isEmpty && !authenticated
        checks["no_model_or_image_work"] = catalog.isEmpty && output.isEmpty && !busy && work == nil && browser == nil && listener == nil
        authActive=false
        return (checks,examples)
    }

    private func prepareAuthDiagnostics() {
        previousSubject = account?.subject; attemptIdentityEmail = nil; confirmsDiagnosticAccount = false
        catalogTraceID = nil; catalog = []; selectedModel = ""; output = ""
        let trace = UUID(); authDiagnostic.begin(traceID: trace)
        authActive = true; authCallbackCategory = nil; authCallbackCode = nil; authCallbackDescription = nil
        authControllerAttempt += 1; authExchangeOrdinal = 0; authAuthorizationURL = nil; authCodeCheck = nil
        authTraceID = trace; authStartedAt = ProcessInfo.processInfo.systemUptime
        authBrowserAt = nil; authCallbackAt = nil
    }
    private func authClientSelection() -> (id: String?, source: SIWCAuthClientSource) {
        (authSelectedClientID, authSelectedClientSource)
    }
    private func recordAuthorizationBindings(url: URL, pending: SIWCPending) {
        authAuthorizationURL = url; authBrowserAt = ProcessInfo.processInfo.systemUptime
        var checks = SIWCAuthBindingInspector.authorization(url:url,pending:pending)
        checks.clientSource = authClientSelection().source; checks.controllerAttempt = authControllerAttempt
        if authSelectedClientSource == .retainedRetry {
            checks.retryBudgetConsumed = true; checks.retryStatePersisted = true
            checks.sameAccountWorkspaceConfirmedByUser = authSameAccountWorkspaceConfirmed
        }
        authRecord(.browser,.checked,binding:checks)
    }
    private func recordExchangeBindings(request: URLRequest, pending: SIWCPending, code: String, issued: String, transaction: UUID) {
        guard attempt == transaction, authActive else { return }
        authExchangeOrdinal += 1
        var checks = SIWCAuthBindingInspector.exchange(request:request,authorizationURL:authAuthorizationURL,pending:pending,code:code,issued:issued)
        checks.exchangeOrdinal = authExchangeOrdinal; checks.controllerAttempt = authControllerAttempt
        checks.codePreviouslySubmittedInWindow = authCodeCheck?.previouslySubmitted
        checks.codeComparisonWindowCount = authCodeCheck?.comparedCount
        checks.callbackToExchangeMilliseconds = milliseconds(since: authCallbackAt)
        checks.registrationCheckpointMatches = registrationID.flatMap { id in
            saved?.pendingRegistrations.first(where: { $0.id == id })?.clientID
        } == issued
        authRecord(.tokenExchange,.checked,binding:checks)
    }
    private var authDiagnosticURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("siwc-auth-diagnostic.json")
    }
    private func restoreAuthDiagnostic() {
        guard !ProcessInfo.processInfo.arguments.contains("--siwc-auth-fixture") else { return }
        guard let url = authDiagnosticURL, let data = try? Data(contentsOf: url), data.count <= 131072,
              let decoded = try? JSONDecoder().decode(SIWCAuthDiagnostic.self, from: data) else { return }
        authDiagnostic = decoded
    }
    private func authRecord(_ stage: SIWCAuthStage, _ outcome: SIWCAuthOutcome, category: SIWCAuthCategory? = nil,
                            httpStatus: Int? = nil, errorCode: String? = nil, numericCode: Int? = nil, binding: SIWCAuthBindingChecks? = nil,
                            service: SIWCServiceDiagnostic? = nil, validation: SIWCValidationEvidence? = nil,
                            errorDescription: SIWCErrorDescriptionDiagnostic? = nil) {
        authDiagnostic.record(stage: stage, outcome: outcome, category: category, httpStatus: httpStatus, errorCode: errorCode, numericCode: numericCode, binding: binding,
                              traceID: authActive ? authTraceID : nil,
                              elapsedMilliseconds: authActive ? milliseconds(since: authStartedAt) : nil,
                              service: service, validation: validation, errorDescription: errorDescription)
        // Only the typed allowlisted event schema is encoded. Never serialize HTTP dictionaries or errors.
        guard !ProcessInfo.processInfo.arguments.contains("--siwc-auth-fixture"), let url = authDiagnosticURL,
              let data = try? JSONEncoder().encode(authDiagnostic) else { return }
        try? data.write(to: url, options: .atomic)
    }
    private func milliseconds(since start: TimeInterval?) -> Int? {
        start.map { max(0, Int((ProcessInfo.processInfo.systemUptime - $0) * 1000)) }
    }
    private func authStep(_ stage: SIWCAuthStage) { authStage = stage; authRecord(stage, .started) }
    private func authHTTP(_ status: Int, stage: SIWCAuthStage, transaction: UUID) {
        guard attempt == transaction, authActive else { return }
        authRecord(stage, .response, httpStatus: status)
    }
    private func authCallback(_ detail: SIWCCallbackDiagnostic, transaction: UUID) {
        guard attempt == transaction, authActive, !detail.accepted else { return }
        authCallbackCategory = detail.category; authCallbackCode = detail.errorCode; authCallbackDescription = detail.errorDescription
        authRecord(.callback, detail.category == .repeatedReturn ? .ignored : .failed,
                   category: detail.category, errorCode: detail.errorCode, errorDescription: detail.errorDescription)
    }
    private func loopbackFailed(_ error: Error, transaction: UUID) {
        guard attempt == transaction, authActive else { return }
        if let denial = error as? SIWCLoopbackDenial {
            // One main-actor event preserves the callback code before terminal classification.
            authCallback(denial.diagnostic, transaction: transaction)
            fail(SIWCError.denied)
        } else { fail(error) }
    }
    private func authFailure(_ error: Error) {
        if let http = error as? SIWCHTTPError {
            authRecord(authStage, .failed, category: .http, httpStatus: http.status, errorCode: http.code, service: http.responseDiagnostic,
                       errorDescription: http.errorDescription)
        } else if error is CancellationError {
            authRecord(authStage, .cancelled, category: .userCancelled)
        } else if let network = error as? URLError {
            authRecord(authStage, .failed, category: .transport, numericCode: network.code.rawValue)
        } else if let validation = error as? SIWCError {
            let category: SIWCAuthCategory
            switch validation {
            case .invalidIdentity: category = .identity
            case .planDisabled: category = .planDisabled
            case .denied: category = authCallbackCategory ?? .oauthError
            case .invalidCallback: category = currentPending.map { $0.deadline <= Date() } == true ? .timeout : .callbackRejected
            default: category = authStage == .storage || authStage == .saveSession ? .storage : .invalidResponse
            }
            authRecord(validation == .denied || validation == .invalidCallback ? .callback : authStage, .failed,
                       category: category, errorCode: validation == .denied ? authCallbackCode : nil,
                       errorDescription: validation == .denied ? authCallbackDescription : nil)
        } else {
            authRecord(authStage, .failed, category: error is DecodingError ? .invalidResponse : .unknown)
        }
    }
    private func browserFinished(_ error: Error?) {
        let ns = error as NSError?
        if ns?.domain == ASWebAuthenticationSessionError.errorDomain,
           ns?.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue {
            authRecord(.browser, .cancelled, category: .userCancelled)
            status = "官方登入視窗已取消；沒有啟動辨識。"; report("cancelled")
        } else {
            authRecord(.browser, .failed, category: .browser, numericCode: ns?.code)
            status = "官方登入視窗未完成回呼；請查看登入診斷。這不表示本人拒絕授權。"; report("browser-failed")
        }
    }

    private func fail(_ error: Error) {
        if authActive {
            authFailure(error)
            if let http = error as? SIWCHTTPError {
                status = "授權未完成（HTTP \(http.status)，\(http.code ?? "未提供錯誤代碼")）。"
            } else if error as? SIWCError == .planDisabled { status = "未取得方案使用權限。" }
            else if error is CancellationError { status = "已取消。" }
            else { status = "登入未完成，請查看安全診斷。" }
            if authenticated { status += "原帳戶已保留。" }
            report("stopped"); return
        }
        SIWCHTTP.shared.recordFailure(error)
        if let http = error as? SIWCHTTPError {
            status = "官方請求停止（HTTP \(http.status)，\(http.code ?? "未提供錯誤代碼")）。不會重試其他付費方式。"
        } else if let stream = error as? SIWCStreamFailure {
            status = "串流已停止（\(stream.terminal)，\(stream.code ?? "未提供錯誤代碼")）；不會自動重送。"
        } else if error as? SIWCError == .incompleteStream {
            status = "串流結束但未收到 response.completed；這次未能確認完成，不會自動重送。"
        } else if error as? SIWCError == .planDisabled { status = "未取得方案使用權限；原帳戶仍保留。" }
        else if error is CancellationError { status = "已取消。" }
        else if error as? SIWCError == .denied { status = "官方授權回呼未通過；請查看下方登入診斷，不會送出辨識。" }
        else { status = "驗證或連線未通過；會話不會因暫時網路錯誤被清除，請檢查後重試。" }
        report("stopped")
    }
    private func validationFailure(_ error: Error, stage: SIWCAuthStage, evidence: SIWCValidationEvidence) {
        var evidence = evidence
        if stage == .syntheticImage { evidence.completed = false }
        if let http = error as? SIWCHTTPError {
            authRecord(stage, .failed, category: .http, httpStatus: http.status, errorCode: http.code, service: http.responseDiagnostic, validation: evidence)
        } else if let stream = error as? SIWCStreamFailure {
            authRecord(stage, .failed, category: .invalidResponse, errorCode: stream.code, validation: evidence)
        } else if let network = error as? URLError {
            authRecord(stage, .failed, category: .transport, numericCode: network.code.rawValue, validation: evidence)
        } else {
            authRecord(stage, error is CancellationError ? .cancelled : .failed,
                category: error as? SIWCError == .planDisabled ? .planDisabled : .invalidResponse, validation: evidence)
        }
    }
    private func report(_ phase: String) {
        // Opt-in test diagnostics: no URL, code, token, email, subject, response text or model list.
        guard ProcessInfo.processInfo.arguments.contains("--siwc-diagnostics") else { return }
        var value: [String: Any] = ["restoredSessionAtLaunch": restoredSession, "syntheticFixtureChecks": fixtureChecks, "request": SIWCHTTP.shared.diagnostics, "phase": phase, "authenticated": authenticated, "planEnabled": planEnabled, "availableModelCount": catalog.count, "legacyPlanOnlyConfirmed": account?.planOnlyConfirmed == true, "planConfirmationRequired": false, "usageWarningRevision": Self.usageWarningRevision, "planAccessReady": planAccessReady, "candidateListed": catalog.contains { $0.slug == "gpt-6-luna" }, "recordedAt": ISO8601DateFormatter().string(from: Date())]
        // Only this explicit synthetic-fixture diagnostic can persist its short plain-text answer.
        // Ordinary responses, images, envelopes and account data are never written.
        if phase == "synthetic-image-completed", ProcessInfo.processInfo.arguments.contains("--siwc-test-once"), output.utf8.count <= 4096 {
            value["syntheticText"] = output
        }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: root.appendingPathComponent("siwc-status.json"), options: .atomic)
        }
    }
}

struct SIWCView: View {
    @State private var model: SIWCController
    @Environment(\.scenePhase) private var scenePhase
    @State private var loaded = false
    init(model: SIWCController = SIWCController()) { _model = State(initialValue: model) }
    var body: some View {
        NavigationStack {
            Form {
                Section("帳戶") {
                    SIWCAccountActions(model: model)
                    if !model.status.isEmpty {
                        Text(model.status).font(.footnote).accessibilityIdentifier("siwcStatus").textSelection(.enabled)
                    }
                }
                if model.authenticated {
                    Section("用量提醒") {
                        PlanUsageWarning()
                        Link("開啟 ChatGPT 用量設定", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                    }
                }
                SIWCSettingsDiagnostic(model: model)

            }.navigationTitle("ChatGPT 帳戶 · S1")
                .task {
                    guard !loaded else { return }; loaded = true; model.load()
                    if ProcessInfo.processInfo.arguments.contains("--siwc-start") { model.begin() }
                    else if ProcessInfo.processInfo.arguments.contains("--siwc-test-once") { await model.runAuthorizedSyntheticTest() }
                }.onChange(of: scenePhase) { _, phase in if phase == .active { model.foreground() } }
                .onDisappear { if model.busy { model.cancel() } }
        }
    }
}

struct PlanUsageWarning: View {
    var body: some View {
        Label {
            Text(SIWCController.usageWarning).font(.footnote.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine).accessibilityIdentifier("planUsageWarning")
    }
}

struct SIWCAccountActions: View {
    let model: SIWCController
    @State private var retryConfirmationID: String?
    @State private var showingRetryConfirmation = false
    var body: some View {
        if model.authenticated {
            VStack(alignment: .leading, spacing: 6) {
                Label("已登入 ChatGPT", systemImage: "checkmark.circle.fill")
                if let email = model.account?.email {
                    Text(email).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("siwcAccountSummary")
        }
        VStack(alignment: .leading, spacing: 6) {
            if let retryID = model.registrationRetryID {
                Text("這次登入未完成。如果仍使用剛才的帳戶與工作區，可以沿用這次註冊重試一次。")
                    .font(.footnote).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("siwcRetryExplanation")
                Button("以同一帳戶與工作區重試一次") {
                    retryConfirmationID = retryID; showingRetryConfirmation = true
                }.frame(minHeight: 44, alignment: .leading).disabled(model.busy)
                    .accessibilityIdentifier("siwc-retry-registration")
            }
            Button(model.authenticated ? "更換帳戶" : "登入 ChatGPT") { model.beginNewAccount() }
                .buttonStyle(.borderless).frame(minHeight: 44, alignment: .leading)
                .disabled(model.busy).accessibilityIdentifier("siwc-authenticate-account")
            if model.authenticated {
                Text("完成新的官方授權後才會更換；取消或失敗會保留原帳戶。")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("siwcAccountSwitchExplanation")
            }
            if model.busy { Button("取消") { model.cancel() }.accessibilityIdentifier("siwc-cancel-account") }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("siwcAccountSwitchRow")
            .confirmationDialog("仍使用剛才的帳戶與工作區？", isPresented: $showingRetryConfirmation, titleVisibility: .visible) {
                Button("是，同一帳戶與工作區") {
                    guard let id = retryConfirmationID else { return }
                    model.retryRegistration(id, confirmedSameAccountAndWorkspace: true)
                    retryConfirmationID = nil
                }
                Button("取消", role: .cancel) { retryConfirmationID = nil }
            } message: {
                Text("請在官方頁面選擇相同帳戶。這次只重試一次；取消或再次失敗都會停止，原帳戶仍保留。若要改選帳戶或工作區，請取消後按更換帳戶。")
            }
    }
}

struct SIWCAuthDiagnosticView: View {
    let diagnostic: SIWCAuthDiagnostic
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("登入診斷 \(SIWCAuthDiagnostic.revision) · B2 · \(SIWCProtocol.callbackRevision) · 第 \(diagnostic.attempt) 次嘗試").font(.headline).accessibilityIdentifier("authDiagnosticRevision")
            Text("只記階段、耗時、綁定比較與安全服務識別碼；不含帳戶、憑證或網頁內容。授權碼重複比較僅涵蓋本控制器最近64筆，重開後未知。舊紀錄請以時間區分。")
                .font(.footnote).foregroundStyle(.secondary)
            if diagnostic.events.isEmpty { Text("尚無本版登入事件；按 Continue with ChatGPT 才開始。").accessibilityIdentifier("authDiagnosticEmpty") }
            ForEach(diagnostic.events.reversed()) { event in
                VStack(alignment: .leading, spacing: 3) {
                    Text("第 \(event.attempt) 次 · \(event.recordedAt.formatted(date: .abbreviated, time: .standard))").font(.caption).foregroundStyle(.secondary)
                    Text(event.text).font(.footnote).textSelection(.enabled)
                }.fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .combine)
                    .accessibilityIdentifier("authDiagnosticEvent-\(event.id)")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// No automatic request. Each diagnostic stage requires an explicit user action
/// and is bound to the latest successfully persisted authentication trace.
struct SIWCSettingsDiagnostic: View {
    let model: SIWCController
    var body: some View {
        Section("最近更換帳戶") {
            Text(model.signInResultText).accessibilityIdentifier("siwcRecentSignIn")
            if !model.status.isEmpty { Text(model.status).font(.footnote).textSelection(.enabled).accessibilityIdentifier("siwcStatus") }
            if let email = model.attemptIdentityEmail { LabeledContent("此次已驗證身分", value: email) }
            Text(model.latestAccountMatches ? "現行帳戶與此次成功登入一致。" : "尚未確認現行帳戶就是此次要換入的帳戶；診斷測試未開放。")
                .font(.footnote).accessibilityIdentifier("siwcIdentityMatch")
            if let same = model.authDiagnostic.latestSignIn?.sameSubjectAsPrevious {
                Text(same ? "此次授權身分與更換前相同。" : "此次授權身分與更換前不同。").font(.footnote)
            }
        }
        Section {
            DisclosureGroup("安全診斷與帳戶驗證") {
                Text("先核對上方現行帳戶。Glance 不會從登入成功推定 Free 或 Pro；以下各步只驗證此次帳戶的實際能力。")
                    .font(.footnote)
                ForEach(Array(stages.enumerated()), id: \.offset) { _, item in
                    let event = model.authDiagnostic.latestSignInEvents.last { item.1.contains($0.stage) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.0)
                        Text(stageText(event)).font(.footnote).foregroundStyle(.secondary)
                    }.fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .combine)
                }
                Toggle("我確認現行帳戶就是要驗證的帳戶", isOn: Binding(get: { model.confirmsDiagnosticAccount }, set: { model.confirmsDiagnosticAccount = $0 }))
                    .disabled(!model.latestAccountMatches || model.busy).accessibilityIdentifier("siwcConfirmDiagnosticAccount")
                Button("讀取此帳戶的可用模型") { model.models() }
                    .disabled(model.busy || !model.diagnosticReady).accessibilityIdentifier("siwcReadModels")
                Text("下一步會使用此帳戶額度，送出一張程式生成的測試圖；不讀取相機或相簿。請先確認 ChatGPT 額外點數已停用。")
                    .font(.footnote)
                Button("傳送一張合成圖驗證") { model.imageTest() }
                    .disabled(model.busy || !model.diagnosticImageReady).accessibilityIdentifier("siwcTestSyntheticImage")
                SIWCAuthDiagnosticView(diagnostic: model.authDiagnostic)
            }
        }
    }
    private func stageText(_ event: SIWCAuthDiagnostic.Event?) -> String {
        guard let event else { return "尚未執行" }
        if event.stage == .syntheticImage, let evidence = event.validation, evidence.completed == true {
            let contentMatches = evidence.red == true && evidence.square == true && evidence.text == true
            return "已收到完整回覆；內容檢查" + (contentMatches ? "通過" : "未通過")
        }
        return event.outcome.title + (event.httpStatus.map { " · HTTP \($0)" } ?? "")
    }
    private var stages: [(String, [SIWCAuthStage])] { [
        ("1 · 準備註冊", [.registration, .storage, .discovery, .listener]),
        ("2 · 官方授權與返回", [.browser, .callback]),
        ("3 · token 交換", [.tokenExchange, .tokenDecode]),
        ("4 · 身分與方案權限", [.jwks, .identity, .permission, .saveSession]),
        ("5 · 模型清單", [.modelCatalog]),
        ("6 · 合成圖完成", [.syntheticImage])
    ] }
}

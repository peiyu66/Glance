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
    private var authTraceID: UUID?
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
    var saved: SIWCSaved?
    var selectedID = ""
    var catalog: [SIWCModel] = []
    var selectedModel = ""
    var status = "準備就緒；尚未開啟官方授權。"
    private(set) var refreshCount = 0
    var busy = false
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
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            SIWCLegacyDiagnosticCleanup.removeKnownFiles(in: documents)
        }
        do {
            var loaded = try authLoadSession(); loaded?.assignMissingLabels()
            saved = loaded; selectedID = loaded?.selected ?? ""; storageUnavailable = false
            if !authActive {
                if let failure = authDiagnostic.latestSignIn?.failure { status = SIWCSignInMessage.failure(stage: failure.stage, category: failure.category, httpStatus: failure.httpStatus, errorCode: failure.errorCode) + (authenticated ? "原帳戶已保留。" : "") }
                else if authDiagnostic.latestSignIn == nil { status = authenticated ? "" : "登入後才能使用方案額度。" }
                else if status == "準備就緒；尚未開啟官方授權。" { status = "" }
            }
        }
        catch { storageUnavailable = true; status = "無法讀取 Glance 本機安全會話；保留原資料，請解鎖裝置後重試。" }
    }
    /// One active account; no legacy account or pending-registration picker.
    func beginNewAccount() { begin() }
    private func prepareRegistrationAttempt() throws {
        guard !storageUnavailable else { throw SIWCError.invalidResponse }
        // Legacy retry metadata is decoded for compatibility but never opens a retry path.
        saved?.recoveryRegistrationID = nil
        registrationID = UUID().uuidString
        let occupied = Set((saved?.accounts.compactMap(\.label) ?? []) + pendingRegistrations.map(\.label))
        var index = 1; while occupied.contains("連線 \(index)") { index += 1 }
        registrationLabel = "連線 \(index)"
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
            unsavedPending.append(SIWCPendingRegistration(id: id, label: label, clientID: issued, savedAt: Date()))
        }
        // A storage failure keeps metadata in memory and stops before consuming the code.
        try persistRegistrationState()
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    /// Called only by the user's sign-in button.
    func begin() {
        guard allowsDataTransfer() else { status = "請先閱讀並同意資料處理說明。"; return }
        guard !busy else { return }
        if let beginSignInOverride { beginSignInOverride(); return }
        busy = true; let transaction = UUID(); attempt = transaction
        originalIdle = UIApplication.shared.isIdleTimerDisabled
        prepareSignInState(); authStep(.registration)
        do { try prepareRegistrationAttempt(); authRecord(.registration, .succeeded) }
        catch { fail(error); endAttempt(); return }
        authStep(.storage)
        originalIdle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        status = "準備官方登入；密碼與同意請本人操作。"
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
                listener.start(clientID: nil) { [weak self] pending in
                    Task { @MainActor in
                        guard let self, self.attempt == transaction else { return }
                        self.currentPending = pending
                        self.authRecord(.listener, .succeeded)
                        self.authStep(.browser)
                        let url = pending.authorize(hostID: saved.hostID, idTokenHint: selected?.tokens?.idToken)
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
                    }
                }
            } catch { guard self.attempt == transaction else { return }; self.fail(error); self.endAttempt() }
        }
    }
    private func loopbackReturned(_ result: Result<(SIWCPending, String, String), Error>, selected: SIWCAccount?, transaction: UUID) {
        guard attempt == transaction else { return }
        switch result {
        case .success(let (pending, code, issued)):
            authRecord(.callback, .succeeded)
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
            do { try checkpointRegistration(issued: issued, selected: selected) }
            catch { authStage = .storage; throw error }
            status = "驗證官方回應與身份…"
            authStep(.tokenExchange)
            let observed = authCodeObservation.observe(code)
            guard !observed.previouslySubmitted else {
                authRecord(.tokenExchange, .failed, category: .callbackConsumed)
                status = "收到已使用的授權碼，已停止且未送出交換。"
                if authenticated { status += "原帳戶已保留。" }
                endAttempt(); return
            }
            let data = try await authHTTPClient.data(url: discovery.token_endpoint, body: pending.codeExchange(code: code, issuedClientID: issued), form: true,
                observeResponse: { [weak self] response in
                    guard let self, self.attempt == transaction, self.authActive else { return }
                    self.authRecord(.tokenExchange, .response, httpStatus: response.status)
                })
            guard attempt == transaction, !Task.isCancelled else { return }
            authRecord(.tokenExchange, .succeeded); authStep(.tokenDecode)
            let response = try JSONDecoder().decode(SIWCTokenResponse.self, from: data)
            let tokens = try response.tokens()
            authRecord(.tokenDecode, .succeeded); authStep(.jwks)
            let jwks = try await authHTTPClient.data(url: discovery.jwks_uri, observeHTTP: { [weak self] status in self?.authHTTP(status, stage: .jwks, transaction: transaction) })
            guard attempt == transaction, !Task.isCancelled else { return }
            authRecord(.jwks, .succeeded); authStep(.identity)
            let identity = try SIWCIdentityVerifier.verify(tokens.idToken, jwks: jwks, clientID: issued, nonce: pending.nonce, expectedSubject: nil)
            guard attempt == transaction, !Task.isCancelled else { return }
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
            if let registrationID { unsavedPending.removeAll { $0.id == registrationID } }
            catalog = []; selectedModel = ""
            authRecord(.saveSession, .succeeded)
            authRecord(.permission, .succeeded, category: SIWCProtocol.hasPlan(tokens.scope) ? .planEnabled : .planDisabled)
            status = "登入完成。"
            endAttempt()
        } catch {
            guard attempt == transaction else { return }
            fail(error)
            endAttempt()
        }
    }
    func cancel() { if authActive { authRecord(authStage, .cancelled, category: .userCancelled) }; status = "已取消目前操作。"; work?.cancel(); endAttempt() }
    private func endAttempt() {
        authActive = false
        attempt = UUID(); listener?.stop(); listener = nil; currentPending = nil
        let old = browser; browser = nil; old?.cancel(); busy = false
        UIApplication.shared.isIdleTimerDisabled = originalIdle
    }
    func foreground() {
        if let pending = currentPending, pending.deadline <= Date() { authRecord(.callback, .failed, category: .timeout); status = "登入嘗試已逾時，請重新開始。"; endAttempt() }
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
    /// Camera provider uses the same Keychain account and serialized refresh path.
    func recognize(jpeg: Data, requestID: String? = nil, searchEvidence: BarcodeSearchEvidence? = nil, validateBeforeImageSend: (() throws -> Void)? = nil, transportStarted: (() throws -> Void)? = nil, capturePreparseResponse: ((String) -> Void)? = nil) async throws -> RecognitionResult {
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
            let answer = try await SIWCHTTP.shared.stream(body: body, bearer: tokens.access, operation: "camera-image", cameraRequestID: requestID, validateBeforeImageSend: validateBeforeImageSend, transportStarted: transportStarted)
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
                         willSend: @escaping () async throws -> Void, transportStarted: @escaping () throws -> Void) async throws -> String {
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
        guard !busy, let account else { return }; busy = true; catalog = []; selectedModel = ""
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
            do { try clearTokens(accountID: account.id); status = revoked ? "已結束可續期會話並清除本機 tokens。" : "本機已登出，但遠端撤銷未確認；請到 ChatGPT 設定斷開 Glance。" }
            catch { status = "無法清除本機會話，請重試；亦可先在 ChatGPT 設定斷開 Glance。" }
        }
    }
    private func clearTokens(accountID: String) throws {
        guard var next = saved, let index = next.accounts.firstIndex(where: { $0.id == accountID }) else { return }
        next.accounts[index].tokens = nil
        try authSaveSession(next); saved = next
    }
    private func prepareSignInState() {
        catalog = []; selectedModel = ""
        let trace = UUID(); authDiagnostic = SIWCAuthDiagnostic(); authDiagnostic.begin(traceID: trace)
        authActive = true; authCallbackCategory = nil; authCallbackCode = nil
        authTraceID = trace
    }
    private func authRecord(_ stage: SIWCAuthStage, _ outcome: SIWCAuthOutcome, category: SIWCAuthCategory? = nil,
                            httpStatus: Int? = nil, errorCode: String? = nil, numericCode: Int? = nil) {
        // Transient typed state supports ordinary failure messages; no trace or disk log.
        authDiagnostic.record(stage: stage, outcome: outcome, category: category, httpStatus: httpStatus,
                              errorCode: errorCode, numericCode: numericCode, traceID: authActive ? authTraceID : nil)
    }
    private func authStep(_ stage: SIWCAuthStage) { authStage = stage; authRecord(stage, .started) }
    private func authHTTP(_ status: Int, stage: SIWCAuthStage, transaction: UUID) {
        guard attempt == transaction, authActive else { return }
        authRecord(stage, .response, httpStatus: status)
    }
    private func authCallback(_ detail: SIWCCallbackDiagnostic, transaction: UUID) {
        guard attempt == transaction, authActive, !detail.accepted else { return }
        authCallbackCategory = detail.category; authCallbackCode = detail.errorCode
        authRecord(.callback, detail.category == .repeatedReturn ? .ignored : .failed,
                   category: detail.category, errorCode: detail.errorCode)
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
            authRecord(authStage, .failed, category: .http, httpStatus: http.status, errorCode: http.code)
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
                       category: category, errorCode: validation == .denied ? authCallbackCode : nil)
        } else {
            authRecord(authStage, .failed, category: error is DecodingError ? .invalidResponse : .unknown)
        }
    }
    private func browserFinished(_ error: Error?) {
        let ns = error as NSError?
        if ns?.domain == ASWebAuthenticationSessionError.errorDomain,
           ns?.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue {
            authRecord(.browser, .cancelled, category: .userCancelled)
            status = "官方登入視窗已取消；沒有啟動辨識。"
        } else {
            authRecord(.browser, .failed, category: .browser, numericCode: ns?.code)
            status = SIWCSignInMessage.failure(stage: .browser, category: .browser)
        }
    }

    private func fail(_ error: Error) {
        if authActive {
            authFailure(error)
            let failure = authDiagnostic.latestSignIn?.failure
            status = SIWCSignInMessage.failure(stage: failure?.stage ?? authStage, category: failure?.category,
                                               httpStatus: failure?.httpStatus, errorCode: failure?.errorCode)
            if authenticated { status += "原帳戶已保留。" }
            return
        }
        SIWCHTTP.shared.recordFailure(error)
        if let http = error as? SIWCHTTPError {
            status = "官方請求停止（HTTP \(http.status)，\(http.code ?? "未提供錯誤代碼")）。不會重試其他付費方式。"
        } else if let stream = error as? SIWCStreamFailure {
            status = "串流已停止（\(stream.terminal)，\(stream.code ?? "未提供錯誤代碼")）；不會自動重送。"
        } else if error as? SIWCError == .incompleteStream {
            status = "串流結束但未收到 response.completed；這次未能確認完成，不會自動重送。"
        } else if error as? SIWCError == .planDisabled { status = SIWCSignInMessage.failure(stage: .permission, category: .planDisabled) }
        else if error is CancellationError { status = "已取消。" }
        else if error as? SIWCError == .denied { status = SIWCSignInMessage.failure(stage: .callback, category: .oauthError) }
        else { status = "驗證或連線未通過；會話不會因暫時網路錯誤被清除，請檢查後重試。" }
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

            }.navigationTitle("ChatGPT 帳戶 · S1")
                .task {
                    guard !loaded else { return }; loaded = true; model.load()
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
        Text(SIWCSignInMessage.requirement).font(.footnote)
            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("siwcPaidRequirement")
        VStack(alignment: .leading, spacing: 6) {
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
    }
}

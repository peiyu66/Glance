import SwiftUI
import AuthenticationServices
import Observation

@MainActor @Observable final class SIWCController: NSObject, ASWebAuthenticationPresentationContextProviding {
    var saved: SIWCSaved?
    var selectedID = ""
    var catalog: [SIWCModel] = []
    var selectedModel = ""
    var status = "準備就緒；尚未開啟官方授權。"
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
    private var retryClientID: String?
    private var originalIdle = false
    var account: SIWCAccount? { saved?.accounts.first { $0.id == selectedID } }
    var authenticated: Bool { account?.tokens != nil }
    var planEnabled: Bool { SIWCProtocol.hasPlan(account?.tokens?.scope ?? "") }
    var planOnlyConfirmed: Bool { account?.planOnlyConfirmed == true }

    func load() {
        do {
            saved = try SIWCKeychain.load(); selectedID = saved?.selected ?? ""
            restoredSession = authenticated
            status = authenticated ? "已從此 iPhone 的 Keychain 恢復登入會話；不需再次登入。" : "尚未登入；首次授權請本人操作。"
            report("ready")
        }
        catch { status = "無法讀取 Glance 本機安全會話；請解鎖裝置後重試。"; report("storage-unavailable") }
    }
    func select(_ id: String) {
        guard !busy else { return }; retryClientID = nil; selectedID = id; saved?.selected = id
        catalog = []; selectedModel = ""; output = ""
        if let saved { do { try SIWCKeychain.save(saved) } catch { status = "無法保存帳戶選擇。" } }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    /// Called only by the user's button, or a launch explicitly authorized for this sign-in attempt.
    func begin() {
        guard !busy else { return }
        busy = true; output = ""; let transaction = UUID(); attempt = transaction
        originalIdle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        status = "準備官方登入；密碼與同意請本人操作。"; report("preparing")
        work = Task { [weak self] in
            guard let self else { return }
            do {
                if self.saved == nil { self.saved = SIWCSaved(hostID: "urn:uuid:" + UUID().uuidString.lowercased(), accounts: [], selected: nil) }
                guard let saved = self.saved else { throw SIWCError.invalidResponse }
                try SIWCKeychain.save(saved)
                let discovery = try await SIWCDiscovery.load()
                guard self.attempt == transaction, !Task.isCancelled else { return }
                self.discovery = discovery
                let selected = self.account
                let listener = SIWCLoopback { [weak self] result in
                    Task { @MainActor in
                        guard let self, self.attempt == transaction else { return }
                        switch result {
                        case .success(let (pending, code, issued)):
                            self.currentPending = nil; self.listener?.stop(); self.listener = nil
                            // Clear the session before cancel: its cancellation handler must not abort the code exchange.
                            let browser = self.browser; self.browser = nil; browser?.cancel()
                            self.work = Task { await self.exchange(pending: pending, code: code, issued: issued, selected: selected, transaction: transaction) }
                        case .failure(let error): self.fail(error); self.endAttempt()
                        }
                    }
                }
                self.listener = listener
                listener.start(clientID: selected?.clientID ?? self.retryClientID) { [weak self] pending in
                    Task { @MainActor in
                        guard let self, self.attempt == transaction else { return }
                        self.currentPending = pending
                        let url = pending.authorize(hostID: saved.hostID, idTokenHint: selected?.tokens?.idToken)
                        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, _ in
                            Task { @MainActor in
                                guard let self, self.attempt == transaction, self.browser != nil else { return }
                                self.status = "官方登入已取消；沒有啟動圖片測試。"; self.report("cancelled"); self.endAttempt()
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
    private func exchange(pending: SIWCPending, code: String, issued: String, selected: SIWCAccount?, transaction: UUID) async {
        do {
            guard let discovery else { throw SIWCError.invalidResponse }
            retryClientID = issued
            status = "驗證官方回應與身份…"; report("validating")
            let data = try await SIWCHTTP.shared.data(url: discovery.token_endpoint, body: pending.codeExchange(code: code, issuedClientID: issued), form: true)
            let response = try JSONDecoder().decode(SIWCTokenResponse.self, from: data)
            let tokens = try response.tokens()
            let jwks = try await SIWCHTTP.shared.data(url: discovery.jwks_uri)
            let identity = try SIWCIdentityVerifier.verify(tokens.idToken, jwks: jwks, clientID: issued, nonce: pending.nonce, expectedSubject: selected?.subject)
            guard attempt == transaction, !Task.isCancelled else { return }
            let account = SIWCAccount(clientID: issued, subject: identity.subject, email: identity.email, tokens: tokens, planOnlyConfirmed: selected?.planOnlyConfirmed ?? false)
            guard var next = saved else { throw SIWCError.invalidResponse }
            next.accounts.removeAll { $0.id == account.id }; next.accounts.append(account); next.selected = account.id
            try SIWCKeychain.save(next); saved = next; selectedID = account.id; retryClientID = nil
            catalog = []; selectedModel = ""
            status = SIWCProtocol.hasPlan(tokens.scope) ? "登入與方案權限已驗證。可讀取模型；送圖前請確認官方頁面已停用額外點數。" : "身份已驗證，但未授予 ChatGPT 方案權限；不會送出辨識。"
            report(SIWCProtocol.hasPlan(tokens.scope) ? "authenticated-plan-enabled" : "authenticated-plan-disabled")
            endAttempt()
        } catch { guard attempt == transaction else { return }; fail(error); endAttempt() }
    }
    func cancel() { status = "已取消目前操作。"; report("cancelled"); work?.cancel(); endAttempt() }
    private func endAttempt() {
        attempt = UUID(); listener?.stop(); listener = nil; currentPending = nil
        let old = browser; browser = nil; old?.cancel(); busy = false
        UIApplication.shared.isIdleTimerDisabled = originalIdle
    }
    func foreground() {
        if let pending = currentPending, pending.deadline <= Date() { status = "登入嘗試已逾時，請重新開始。"; report("timeout"); endAttempt() }
    }
    func confirmPlanOnly(_ confirmed: Bool) {
        guard !busy, var next = saved, let index = next.accounts.firstIndex(where: { $0.id == selectedID }) else { return }
        next.accounts[index].planOnlyConfirmed = confirmed
        do { try SIWCKeychain.save(next); saved = next } catch { status = "無法保存方案用量確認。" }
    }
    private func usableTokens() async throws -> SIWCTokens {
        guard let account, let old = account.tokens else { throw SIWCError.invalidIdentity }
        if old.expiresAt > Date().addingTimeInterval(60) { return old }
        if let earliest = old.earliestRefreshAt, earliest > Date() {
            if old.expiresAt > Date() { return old }; throw SIWCError.invalidResponse
        }
        guard let refresh = old.refresh else { throw SIWCError.invalidIdentity }
        do {
            let config = try await SIWCDiscovery.load()
            let body = SIWCProtocol.form(["grant_type": "refresh_token", "client_id": account.clientID, "refresh_token": refresh, "resource": SIWCProtocol.resource])
            let data = try await SIWCHTTP.shared.data(url: config.token_endpoint, body: body, form: true)
            let response = try JSONDecoder().decode(SIWCTokenResponse.self, from: data)
            let replacement = try response.tokens(retainedID: old.idToken, retainedScope: old.scope)
            guard replacement.refresh != nil else { throw SIWCError.invalidResponse }
            if response.id_token != nil {
                let keys = try await SIWCHTTP.shared.data(url: config.jwks_uri)
                _ = try SIWCIdentityVerifier.verify(replacement.idToken, jwks: keys, clientID: account.clientID, nonce: nil, expectedSubject: account.subject)
            }
            guard var next = saved, let index = next.accounts.firstIndex(where: { $0.id == account.id }) else { throw SIWCError.invalidIdentity }
            try Task.checkCancellation()
            next.accounts[index].tokens = replacement
            try SIWCKeychain.save(next); saved = next
            return replacement
        } catch let error as SIWCHTTPError where error.terminalRefresh {
            try clearTokens(accountID: account.id); throw error
        }
    }
    func models() {
        guard !busy, planEnabled else { return }; busy = true
        work = Task {
            defer { busy = false }
            do {
                let tokens = try await usableTokens(); guard SIWCProtocol.hasPlan(tokens.scope) else { throw SIWCError.planDisabled }
                let data = try await SIWCHTTP.shared.data(url: SIWCProtocol.resource + "/models", bearer: tokens.access)
                let models = try JSONDecoder().decode(SIWCCatalog.self, from: data).models.filter { $0.visibility == "list" }
                try Task.checkCancellation(); catalog = models
                selectedModel = models.contains { $0.slug == "gpt-6-luna" } ? "gpt-6-luna" : ""
                status = selectedModel.isEmpty ? "已讀取模型；候選 gpt-6-luna 不在清單，尚未選擇替代模型。" : "帳戶提供 gpt-6-luna；none 與影像能力仍待最小測試。"
                report("catalog-loaded")
            } catch { fail(error) }
        }
    }
    /// One explicitly authorized diagnostic retry; never enabled for ordinary launches.
    func runAuthorizedSyntheticTest() async {
        guard authenticated, planEnabled, planOnlyConfirmed else { status = "會話或方案確認不足；未啟動受控測試。"; report("test-not-started"); return }
        models()
        let catalogWork = work; await catalogWork?.value
        guard !Task.isCancelled, !selectedModel.isEmpty, !busy else { return }
        imageTest()
        let imageWork = work; await imageWork?.value
    }
    func imageTest() {
        guard !busy, planEnabled, planOnlyConfirmed, !selectedModel.isEmpty else { return }; busy = true; output = ""; fixtureChecks = [:]
        let model = selectedModel
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
                let text = try await SIWCHTTP.shared.stream(body: body, bearer: tokens.access)
                try Task.checkCancellation(); output = text
                let lower = text.lowercased()
                fixtureChecks = ["red": lower.contains("red") || text.contains("紅") || text.contains("红"),
                                 "square": lower.contains("square") || text.contains("方形"),
                                 "text": lower.contains("glance") && text.contains("123")]
                status = "已收到 response.completed；正式影像最小測試完成。"; report("synthetic-image-completed")
            } catch { fail(error) }
        }
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
        try SIWCKeychain.save(next); saved = next
    }
    private func fail(_ error: Error) {
        SIWCHTTP.shared.recordFailure(error)
        if let http = error as? SIWCHTTPError {
            status = "官方請求停止（HTTP \(http.status)，\(http.code ?? "未提供錯誤代碼")）。不會重試其他付費方式。"
        } else if let stream = error as? SIWCStreamFailure {
            status = "串流已停止（\(stream.terminal)，\(stream.code ?? "未提供錯誤代碼")）；不會自動重送。"
        } else if error as? SIWCError == .incompleteStream {
            status = "串流結束但未收到 response.completed；這次未能確認完成，不會自動重送。"
        } else if error is CancellationError { status = "已取消。" }
        else if error as? SIWCError == .denied { status = "使用者未授權；不會送出辨識。" }
        else { status = "驗證或連線未通過；會話不會因暫時網路錯誤被清除，請檢查後重試。" }
        report("stopped")
    }
    private func report(_ phase: String) {
        // Opt-in test diagnostics: no URL, code, token, email, subject, response text or model list.
        guard ProcessInfo.processInfo.arguments.contains("--siwc-diagnostics") else { return }
        var value: [String: Any] = ["restoredSessionAtLaunch": restoredSession, "syntheticFixtureChecks": fixtureChecks, "request": SIWCHTTP.shared.diagnostics, "phase": phase, "authenticated": authenticated, "planEnabled": planEnabled, "availableModelCount": catalog.count, "planOnlyConfirmed": planOnlyConfirmed, "candidateListed": catalog.contains { $0.slug == "gpt-6-luna" }, "recordedAt": ISO8601DateFormatter().string(from: Date())]
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
    @State private var model = SIWCController()
    @Environment(\.scenePhase) private var scenePhase
    @State private var loaded = false
    var body: some View {
        NavigationStack {
            Form {
                Section(model.authenticated ? "ChatGPT 會話" : "首次授權由你操作") {
                    Text("在 iPhone 的 auth.openai.com 官方視窗登入；Glance 不讀其他 app 憑證，不使用 API key。")
                    Text("權限：基本身份（openid/profile/email）、會話續期（offline_access）、ChatGPT 方案模型呼叫（resource.invoke/chatgpt.tokens.use.direct）。").font(.footnote)
                    Text("同意後，Glance 將 access／refresh／ID token 與帳戶/client 對應保存在此 iPhone Keychain，僅解鎖時可讀、不同步 iCloud。日後自動續期，不每次測試重登；可登出撤銷。尚未連接相機。 ").font(.footnote)
                    Picker("ChatGPT 帳戶", selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                        Text("新增帳戶").tag("")
                        ForEach(Array((model.saved?.accounts ?? []).enumerated()), id: \.element.id) { index, account in
                            Text("帳戶 \(index + 1) · \(account.email ?? "已驗證帳戶")").tag(account.id)
                        }
                    }.disabled(model.busy)
                    if model.authenticated {
                        Label("已登入 ChatGPT", systemImage: "checkmark.circle.fill")
                        Text("會話已安全保留；不需要每次測試重新登入。失效時才重新驗證。").font(.footnote)
                    } else {
                        Button("Continue with ChatGPT") { model.begin() }.disabled(model.busy)
                    }
                    if model.busy { Button("取消目前操作") { model.cancel() } }
                }
                Section("目前狀態") {
                    Text(model.status).accessibilityIdentifier("siwcStatus").textSelection(.enabled)
                    Text("測試只記錄階段、HTTP狀態、安全錯誤分類、耗時及終止事件；不保存圖片或原始回應。").font(.footnote)
                }
                if model.authenticated {
                    Section("只使用方案額度") {
                        Link("開啟 ChatGPT 用量與 App 權限設定", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                        Text("請在官方 Usage 頁確認已停用應用程式超出方案上限後使用點數。下方勾選僅記錄你的確認，不會改動官方設定；目前已查文件沒有可讀取此開關的 API。方案不足時停止，不切換付費方式。").font(.footnote)
                        Toggle("我已在官方頁面確認：額外點數已停用", isOn: Binding(get: { model.planOnlyConfirmed }, set: { model.confirmPlanOnly($0) })).disabled(model.busy)
                    }
                    Section("最小驗證") {
                        Button("讀取可用模型") { model.models() }.disabled(model.busy || !model.planEnabled)
                        Picker("模型", selection: $model.selectedModel) {
                            Text("未選擇").tag("")
                            ForEach(model.catalog) { Text($0.display_name).tag($0.slug) }
                        }.disabled(model.busy)
                        Text("reasoning.effort = none；首次只用程式畫的紅色方形與 GLANCE 123，不讀照片。能力不支援就停止。").font(.footnote)
                        Button("測試一張合成圖片") { model.imageTest() }.disabled(model.busy || !model.planOnlyConfirmed || !model.planEnabled || model.selectedModel.isEmpty)
                        if !model.output.isEmpty { Text(model.output) }
                    }
                    Button("登出並撤銷可續期會話", role: .destructive) { model.signOut() }.disabled(model.busy)
                }
            }.navigationTitle("ChatGPT 登入驗證")
                .task {
                    guard !loaded else { return }; loaded = true; model.load()
                    if ProcessInfo.processInfo.arguments.contains("--siwc-start") { model.begin() }
                    else if ProcessInfo.processInfo.arguments.contains("--siwc-test-once") { await model.runAuthorizedSyntheticTest() }
                }.onChange(of: scenePhase) { _, phase in if phase == .active { model.foreground() } }
        }
    }
}

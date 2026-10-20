// Appended to the fixture copy of SIWCView.swift so these checks exercise its
// actual private orchestration without adding production test APIs or a browser.
import Security

private final class RecoveryWire: @unchecked Sendable {
    static let shared = RecoveryWire()
    private let lock = NSLock()
    private var response = Data(#"{"error":"invalid_grant"}"#.utf8)
    private var status = 400
    private var jwks = Data()
    private var requests: [URLRequest] = []
    func configure(status: Int = 400, response: Data = Data(#"{"error":"invalid_grant"}"#.utf8), jwks: Data = Data()) {
        lock.lock(); defer { lock.unlock() }
        self.status = status; self.response = response; self.jwks = jwks; requests = []
    }
    func receive(_ request: URLRequest) -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }; requests.append(request)
        if request.url?.path == "/api/accounts/oauth/token" { return (status, response) }
        if request.url?.path == "/.well-known/jwks.json" { return (200, jwks) }
        // The UI test's public begin() must stop at discovery, before a listener
        // or ASWebAuthenticationSession could be created.
        return (503, Data(#"{"error":"temporarily_unavailable"}"#.utf8))
    }
    var captured: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}

private final class RecoveryProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var copy = request
        if copy.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
            }
            copy.httpBody = bytes
        }
        let (status, data) = RecoveryWire.shared.receive(copy)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor private final class RecoveryStore {
    var value: SIWCSaved
    var writes = 0
    var reject: ((SIWCSaved) -> Bool)?
    init(knownPendingIdentity: Bool = false) {
        let old = SIWCAccount(clientID: "old-pro-client-secret", subject: "old-pro-subject-secret", email: "previous@example.invalid",
            tokens: SIWCTokens(access: "old-pro-access-secret", refresh: "old-pro-refresh-secret", idToken: "old-pro-id-secret", scope: SIWCProtocol.scopes, expiresAt: Date().addingTimeInterval(3600)), label: "連線 1")
        var accounts = [old]
        if knownPendingIdentity {
            accounts.append(SIWCAccount(clientID: "recovery-test-client", subject: "expected-same-subject", tokens: nil, label: "連線 2"))
        }
        value = SIWCSaved(hostID: "synthetic-stable-host-secret", accounts: accounts, selected: old.id)
    }
    func save(_ next: SIWCSaved) throws {
        writes += 1
        if reject?(next) == true { throw SIWCError.invalidResponse }
        // Round-trip the actual storage schema on every successful write.
        value = try JSONDecoder().decode(SIWCSaved.self, from: JSONEncoder().encode(next))
    }
    func controller() -> SIWCController {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RecoveryProtocol.self]
        let model = SIWCController(allowsDataTransfer: { true }, authHTTPClient: SIWCHTTP(configuration: config), authSaveSession: { try self.save($0) }, authLoadSession: { self.value })
        model.load(); return model
    }
    var oldPreserved: Bool {
        value.selected == "old-pro-client-secret:old-pro-subject-secret" && value.accounts.first?.tokens?.access == "old-pro-access-secret"
    }
}

extension SIWCController {
    fileprivate func recoveryFixtureStart(id: String? = nil, confirmed: Bool = false, port: UInt16 = 42001) throws -> SIWCPending {
        busy = true; attempt = UUID(); prepareAuthDiagnostics(); authStep(.registration)
        try prepareRegistrationAttempt(recoveryID: id, confirmedSameAccountAndWorkspace: confirmed)
        authStep(.storage); try persistRegistrationState()
        discovery = SIWCDiscovery(issuer: SIWCProtocol.issuer, authorization_endpoint: SIWCProtocol.issuer + "/api/accounts/authorize",
            token_endpoint: SIWCProtocol.issuer + "/api/accounts/oauth/token", jwks_uri: SIWCProtocol.issuer + "/.well-known/jwks.json", revocation_endpoint: SIWCProtocol.issuer + "/oauth/revoke")
        let pending = try SIWCPending.fresh(port: port, clientID: authClientSelection().id)
        currentPending = pending; authStep(.browser)
        recordAuthorizationBindings(url: pending.authorize(hostID: saved!.hostID), pending: pending)
        return pending
    }
    fileprivate func recoveryFixtureSubmit(_ original: SIWCPending, code: String, client: String? = "recovery-test-client", state: String? = nil) async {
        var pending = original
        var fields = ["state": state ?? pending.state, "code": code]
        if let client { fields["client_id"] = client }
        let target = "/auth/callback?" + String(decoding: SIWCProtocol.form(fields), as: UTF8.self)
        do {
            let callback = try pending.callback(target: target)
            authCallbackAt = ProcessInfo.processInfo.systemUptime
            authRecord(.callback, .succeeded); currentPending = nil
            await exchange(pending: pending, code: callback.code, issued: callback.clientID, selected: nil, transaction: attempt)
        } catch { fail(error); endAttempt() }
    }
}

private struct RecoverySigner {
    let key: SecKey
    let jwks: Data
    init() throws {
        guard let key = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil),
              let publicKey = SecKeyCopyPublicKey(key), let raw = SecKeyCopyExternalRepresentation(publicKey, nil) else { throw SIWCError.invalidIdentity }
        self.key = key
        func read(_ data: Data, _ index: inout Int) -> Data {
            index += 1; var length = Int(data[index]); index += 1
            if length & 128 != 0 {
                let count = length & 127; length = 0
                for _ in 0..<count { length = (length << 8) | Int(data[index]); index += 1 }
            }
            let result = Data(data[index..<(index + length)]); index += length; return result
        }
        var i = 0; let sequence = read(raw as Data, &i); var j = 0
        var modulus = read(sequence, &j), exponent = read(sequence, &j)
        while modulus.first == 0 { modulus.removeFirst() }; while exponent.first == 0 { exponent.removeFirst() }
        jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kid": "recovery-fixture", "kty": "RSA", "alg": "RS256", "use": "sig", "n": SIWCProtocol.encode(modulus), "e": SIWCProtocol.encode(exponent)]]])
    }
    func response(pending: SIWCPending, mode: String = "success") throws -> Data {
        let now = Date().timeIntervalSince1970
        var claims: [String: Any] = ["iss": SIWCProtocol.issuer, "sub": "new-subject-secret", "aud": "recovery-test-client", "nonce": pending.nonce, "iat": now, "exp": now + 3600]
        if mode == "nonce" { claims["nonce"] = "wrong-nonce" }
        if mode == "audience" { claims["aud"] = "other-client" }
        let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "recovery-fixture"])
        let signed = SIWCProtocol.encode(header) + "." + SIWCProtocol.encode(try JSONSerialization.data(withJSONObject: claims))
        guard let raw = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(signed.utf8) as CFData, nil) else { throw SIWCError.invalidIdentity }
        var signature = raw as Data
        if mode == "signature" { signature[0] ^= 1 }
        let token = signed + "." + SIWCProtocol.encode(signature)
        return try JSONSerialization.data(withJSONObject: ["access_token": "new-access-secret", "refresh_token": "new-refresh-secret", "id_token": token, "token_type": "Bearer", "expires_in": 3600,
            "scope": mode == "scope" ? "openid profile email" : SIWCProtocol.scopes])
    }
}

@MainActor private enum RecoveryChecks {
    static func eligible(knownIdentity: Bool = false) async throws -> (RecoveryStore, SIWCController, SIWCPending) {
        let store = RecoveryStore(knownPendingIdentity: knownIdentity), model = store.controller()
        RecoveryWire.shared.configure()
        let pending = try model.recoveryFixtureStart()
        await model.recoveryFixtureSubmit(pending, code: "first-code-secret")
        return (store, model, pending)
    }
    static func run() async throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let signer = try RecoverySigner()
        let (store, model, first) = try await eligible()
        let id = model.registrationRetryID!
        checks["first_invalid_grant_offers_one_retry"] = store.value.recoveryRegistrationID == id && store.value.pendingRegistrations.first?.retry?.state == .available
        checks["first_failure_preserves_pro_and_has_one_exchange"] = store.oldPreserved && RecoveryWire.shared.captured.count == 1 && model.authDiagnostic.latestSignIn?.failure?.httpStatus == 400
        checks["reload_keeps_exact_registration_offer"] = store.controller().registrationRetryID == id
        let writes = store.writes, calls = RecoveryWire.shared.captured.count
        model.retryRegistration(id, confirmedSameAccountAndWorkspace: false)
        model.retryRegistration("unrelated-registration", confirmedSameAccountAndWorkspace: true)
        checks["unconfirmed_or_stale_choice_has_no_effect"] = store.writes == writes && RecoveryWire.shared.captured.count == calls && model.registrationRetryID == id
        let retry = try model.recoveryFixtureStart(id: id, confirmed: true, port: 42002)
        checks["permit_consumed_and_persisted_before_transport"] = store.value.pendingRegistrations.first?.retry?.state == .consumed && RecoveryWire.shared.captured.count == calls
        checks["restart_does_not_restore_consumed_offer"] = store.controller().registrationRetryID == nil
        checks["fresh_state_nonce_pkce_and_redirect"] = first.state != retry.state && first.nonce != retry.nonce && first.verifier != retry.verifier && first.redirect != retry.redirect
        let auth = URLComponents(url: retry.authorize(hostID: store.value.hostID), resolvingAgainstBaseURL: false)!.queryItems!
        checks["same_client_host_no_pro_hint"] = retry.clientID == "recovery-test-client" && store.value.hostID == "synthetic-stable-host-secret" && !auth.contains { $0.name == "id_token_hint" }
        RecoveryWire.shared.configure()
        await model.recoveryFixtureSubmit(retry, code: "second-code-secret", client: nil)
        let wire = RecoveryWire.shared.captured
        var formURL = URLComponents(); formURL.percentEncodedQuery = String(decoding: wire.first?.httpBody ?? Data(), as: UTF8.self)
        let form = Dictionary(uniqueKeysWithValues: (formURL.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        checks["actual_retry_wire_uses_new_code_and_bound_client_pkce_redirect"] = form["code"] == "second-code-secret" && form["client_id"] == retry.clientID && form["code_verifier"] == retry.verifier && form["redirect_uri"] == retry.redirect && wire.count == 1
        checks["second_failure_never_reoffers_or_auto_retries"] = model.registrationRetryID == nil && store.oldPreserved && !model.busy && model.status.contains("不會自動重試")
        model.retryRegistration(id, confirmedSameAccountAndWorkspace: true)
        checks["third_start_refused"] = RecoveryWire.shared.captured.count == 1 && !model.busy
        let bindings = model.authDiagnostic.events.compactMap(\.binding)
        checks["diagnostic_marks_retained_client_and_user_confirmation_only"] = bindings.contains { $0.clientSource == .retainedRetry && $0.retryBudgetConsumed == true && $0.retryStatePersisted == true && $0.sameAccountWorkspaceConfirmedByUser == true }
        let encoded = String(decoding: try JSONEncoder().encode(model.authDiagnostic), as: UTF8.self)
        checks["diagnostic_contains_no_secrets_or_raw_identity"] = !["old-pro-access-secret", "old-pro-refresh-secret", "old-pro-id-secret", "old-pro-client-secret", "old-pro-subject-secret", "synthetic-stable-host-secret", "recovery-test-client", "first-code-secret", "second-code-secret", first.state, retry.nonce, retry.verifier].contains { encoded.contains($0) }
        let pendingJSON = String(decoding: try JSONEncoder().encode(store.value.pendingRegistrations), as: UTF8.self)
        checks["pending_records_never_store_code_or_pkce_or_token"] = !["first-code-secret", "second-code-secret", first.verifier, retry.verifier, "access", "id_token"].contains { pendingJSON.contains($0) }

        for mode in ["success", "nonce", "audience", "signature", "scope", "subject", "save"] {
            let (s, m, _) = try await eligible(knownIdentity: mode == "subject")
            let p = try m.recoveryFixtureStart(id: m.registrationRetryID!, confirmed: true)
            if mode == "save" { s.reject = { $0.selected != "old-pro-client-secret:old-pro-subject-secret" } }
            RecoveryWire.shared.configure(status: 200, response: try signer.response(pending: p, mode: mode), jwks: signer.jwks)
            await m.recoveryFixtureSubmit(p, code: "fresh-retry-code")
            let paths = RecoveryWire.shared.captured.compactMap { $0.url?.path }
            if mode == "success" {
                checks["verified_new_identity_switches_only_after_save"] = m.account?.subject == "new-subject-secret" && s.value.selected == m.account?.id && m.authDiagnostic.latestSignIn?.outcome == .succeeded
                checks["success_keeps_old_pro_record_and_clears_pending"] = s.value.accounts.contains { $0.clientID == "old-pro-client-secret" && $0.tokens?.access == "old-pro-access-secret" } && s.value.pendingRegistrations.isEmpty && s.value.recoveryRegistrationID == nil
            } else { checks["retry_\(mode)_failure_keeps_old_credentials"] = s.oldPreserved && m.account?.clientID == "old-pro-client-secret" && m.authDiagnostic.latestSignIn?.outcome == .failed && m.registrationRetryID == nil }
            checks["retry_\(mode)_has_no_models_or_ai_or_extra_token_calls"] = paths == ["/api/accounts/oauth/token", "/.well-known/jwks.json"]
        }
        for mode in ["cancel", "wrong_client", "wrong_state", "reused_code", "consume_save", "discovery"] {
            let (s, m, _) = try await eligible(); let id = m.registrationRetryID!
            RecoveryWire.shared.configure()
            if mode == "consume_save" {
                s.reject = { $0.pendingRegistrations.contains { $0.retry?.state == .consumed } }
                m.retryRegistration(id, confirmedSameAccountAndWorkspace: true)
                checks["consumption_save_failure_stops_before_network"] = !m.busy && RecoveryWire.shared.captured.isEmpty && s.oldPreserved && m.registrationRetryID == nil && s.value.pendingRegistrations.first?.retry?.state == .available
            } else if mode == "discovery" {
                m.retryRegistration(id, confirmedSameAccountAndWorkspace: true)
                m.retryRegistration(id, confirmedSameAccountAndWorkspace: true)
                for _ in 0..<200 { if !m.busy { break }; try? await Task.sleep(for: .milliseconds(10)) }
                checks["double_tap_and_discovery_failure_consume_once_before_browser"] = !m.busy && m.registrationRetryID == nil && s.oldPreserved && RecoveryWire.shared.captured.compactMap { $0.url?.path } == ["/.well-known/openid-configuration"]
            } else {
                let p = try m.recoveryFixtureStart(id: id, confirmed: true)
                if mode == "cancel" { m.cancel() }
                else { await m.recoveryFixtureSubmit(p, code: mode == "reused_code" ? "first-code-secret" : "fresh-retry-code", client: mode == "wrong_client" ? "other-client" : nil, state: mode == "wrong_state" ? "stale-state" : nil) }
                checks["\(mode)_stops_without_token_exchange_or_restoring_offer"] = RecoveryWire.shared.captured.isEmpty && m.registrationRetryID == nil && !m.busy && s.oldPreserved && s.controller().registrationRetryID == nil
            }
        }
        do {
            let s = RecoveryStore(), m = s.controller(); RecoveryWire.shared.configure()
            let p = try m.recoveryFixtureStart()
            s.reject = { $0.pendingRegistrations.contains { $0.retry?.state == .available } }
            await m.recoveryFixtureSubmit(p, code: "one-code")
            checks["offer_save_failure_keeps_400_and_original_credentials"] = m.registrationRetryID == nil && s.oldPreserved && m.authDiagnostic.latestSignIn?.failure?.httpStatus == 400 && m.status.contains("無法保存續試狀態")
        }
        do {
            let s = RecoveryStore()
            s.value.pendingRegistrations = [SIWCPendingRegistration(id: "legacy", label: "連線 2", clientID: "legacy-client", savedAt: Date())]
            s.value.recoveryRegistrationID = "legacy"
            let restored = try JSONDecoder().decode(SIWCSaved.self, from: JSONEncoder().encode(s.value))
            s.value = restored
            checks["legacy_pending_never_guessed_as_retryable"] = s.controller().registrationRetryID == nil && restored.pendingRegistrations.first?.retry == nil
        }
        for (status, code) in [(400, "invalid_client"), (403, "access_denied"), (500, "invalid_grant")] {
            let s = RecoveryStore(), m = s.controller()
            RecoveryWire.shared.configure(status: status, response: try JSONSerialization.data(withJSONObject: ["error": code]))
            let p = try m.recoveryFixtureStart()
            await m.recoveryFixtureSubmit(p, code: "first-other-error-code")
            checks["http_\(status)_\(code)_never_opens_retry"] = m.registrationRetryID == nil && s.oldPreserved && RecoveryWire.shared.captured.count == 1
        }
        do {
            let (s, m, _) = try await eligible()
            let oldID = m.registrationRetryID!, oldCount = s.value.pendingRegistrations.count
            let fresh = try m.recoveryFixtureStart()
            checks["explicit_new_account_clears_offer_without_deleting_credentials"] = fresh.clientID == nil && m.registrationRetryID == nil && s.oldPreserved && s.value.pendingRegistrations.count == oldCount && s.value.pendingRegistrations.first?.id == oldID
            m.cancel()
        }
        checks["default_network_guard_never_triggered"] = C8NetworkProbe.shared.count == 0
        return checks
    }
}

struct AuthRecoveryChecksView: View {
    @State private var status = "running"
    var body: some View {
        Text(status).accessibilityIdentifier("auth-recovery-result").task {
            do {
                let checks = try await RecoveryChecks.run(), passed = checks.values.allSatisfy { $0 }
                let report: [String: Any] = ["passed": passed, "checks": checks, "count": checks.count, "realNetworkRequests": 0, "keychainAccess": false, "browserStarted": false]
                let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("auth-recovery-checks.json")
                try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: url)
                status = passed ? "passed \(checks.count)" : "FAILED " + checks.filter { !$0.value }.map(\.key).sorted().joined(separator: ",")
            } catch { status = "FAILED fixture setup" }
        }
    }
}

struct AuthRecoveryUIFixture: View {
    @State private var model: SIWCController?
    var body: some View {
        Form {
            if let model {
                SIWCAccountActions(model: model)
                Text(model.status).accessibilityIdentifier("recoveryStatus")
                Text(model.registrationRetryID == nil ? "consumed" : "available").accessibilityIdentifier("recoveryPermit")
            } else { Text("preparing") }
        }.environment(\.dynamicTypeSize, ProcessInfo.processInfo.arguments.contains("--maximum-type") ? .accessibility5 : .large)
        .task { model = try? await RecoveryChecks.eligible().1 }
    }
}

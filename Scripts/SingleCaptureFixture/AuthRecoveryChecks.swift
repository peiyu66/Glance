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
        if status == -1 { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
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
    fileprivate func recoveryFixtureStart(port: UInt16 = 42001, expired: Bool = false) throws -> SIWCPending {
        busy = true; attempt = UUID(); prepareSignInState(); authStep(.registration)
        try prepareRegistrationAttempt()
        authStep(.storage); try persistRegistrationState()
        discovery = SIWCDiscovery(issuer: SIWCProtocol.issuer, authorization_endpoint: SIWCProtocol.issuer + "/api/accounts/authorize",
            token_endpoint: SIWCProtocol.issuer + "/api/accounts/oauth/token", jwks_uri: SIWCProtocol.issuer + "/.well-known/jwks.json", revocation_endpoint: SIWCProtocol.issuer + "/oauth/revoke")
        let pending = try SIWCPending.fresh(port: port, clientID: nil, now: expired ? Date().addingTimeInterval(-600) : Date())
        currentPending = pending; authStep(.browser)
        return pending
    }
    fileprivate func recoveryFixtureSubmit(_ original: SIWCPending, code: String, client: String? = "recovery-test-client", state: String? = nil) async {
        var pending = original
        var fields = ["state": state ?? pending.state, "code": code]
        if let client { fields["client_id"] = client }
        let target = "/auth/callback?" + String(decoding: SIWCProtocol.form(fields), as: UTF8.self)
        do {
            let callback = try pending.callback(target: target)
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
    static func run() async throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let signer = try RecoverySigner()
        for (label, status) in [("invalid_grant",400),("server",503),("transport",-1)] {
            let store=RecoveryStore(), model=store.controller()
            RecoveryWire.shared.configure(status:status)
            let pending=try model.recoveryFixtureStart()
            model.beginNewAccount()
            checks[label+"_busy_begin_does_not_start_second_login"] = RecoveryWire.shared.captured.isEmpty
            await model.recoveryFixtureSubmit(pending,code:"unique-"+label)
            checks[label+"_once_and_original_account_preserved"] = RecoveryWire.shared.captured.count == 1 && store.oldPreserved && !model.busy
            checks[label+"_paid_requirement_is_guidance"] = model.status.contains(SIWCSignInMessage.requirement) && model.status.contains("確認目前登入的帳戶")
            checks[label+"_no_retained_client_retry"] = store.value.recoveryRegistrationID == nil && store.value.pendingRegistrations.allSatisfy { $0.retry == nil }
            if label == "transport" { checks["network_not_invented_http_or_free_detection"] = model.status.contains("網路") && !model.status.contains("HTTP") }
            if label == "server" { checks["server_classification_preserved"] = model.status.contains("服務暫時") && model.status.contains("503") }
            let requests=RecoveryWire.shared.captured.count
            model.load()
            checks[label+"_reload_no_request_and_keeps_failure"] = RecoveryWire.shared.captured.count == requests && model.status.contains("原帳戶已保留")
        }
        for mode in ["success","scope","signature","nonce","audience"] {
            let store=RecoveryStore(), model=store.controller(), pending=try model.recoveryFixtureStart()
            RecoveryWire.shared.configure(status:200,response:try signer.response(pending:pending,mode:mode),jwks:signer.jwks)
            await model.recoveryFixtureSubmit(pending,code:"code-"+mode)
            checks[mode+"_exact_exchange_and_jwks"] = RecoveryWire.shared.captured.map { $0.url!.path } == ["/api/accounts/oauth/token","/.well-known/jwks.json"]
            if mode == "success" {
                checks["valid_success_persists_and_changes_account"] = model.account?.subject == "new-subject-secret" && model.planAccessReady && model.status == "登入完成。"
            } else {
                checks[mode+"_preserves_valid_original_credentials"] = store.oldPreserved && model.status.contains(SIWCSignInMessage.requirement)
            }
        }
        do {
            let store=RecoveryStore(), model=store.controller()
            RecoveryWire.shared.configure()
            let first=try model.recoveryFixtureStart()
            await model.recoveryFixtureSubmit(first,code:"same-code")
            let second=try model.recoveryFixtureStart(port:42002)
            await model.recoveryFixtureSubmit(second,code:"same-code")
            checks["duplicate_code_never_exchanged_twice"] = RecoveryWire.shared.captured.count == 1 && store.oldPreserved && model.status.contains("已使用")
        }
        do {
            let store=RecoveryStore(), model=store.controller()
            RecoveryWire.shared.configure()
            _=try model.recoveryFixtureStart();model.cancel()
            checks["cancel_does_not_exchange_or_replace_account"] = RecoveryWire.shared.captured.isEmpty && store.oldPreserved && !model.busy && model.status.contains("取消")
        }
        do {
            let store=RecoveryStore(), model=store.controller()
            RecoveryWire.shared.configure()
            let expired=try model.recoveryFixtureStart(expired:true)
            await model.recoveryFixtureSubmit(expired,code:"expired-code")
            checks["expired_callback_never_exchanged"] = RecoveryWire.shared.captured.isEmpty && store.oldPreserved && model.status.contains("逾時")
        }
        do {
            let store=RecoveryStore(), model=store.controller()
            RecoveryWire.shared.configure()
            let pending=try model.recoveryFixtureStart()
            await model.recoveryFixtureSubmit(pending,code:"wrong-state-code",state:"wrong")
            checks["wrong_state_never_exchanged"] = RecoveryWire.shared.captured.isEmpty && store.oldPreserved
        }
        for afterExchange in [false, true] {
            let store=RecoveryStore(), model=store.controller(), pending=try model.recoveryFixtureStart()
            store.reject = { next in afterExchange ? next.accounts.contains { $0.subject == "new-subject-secret" } : !next.pendingRegistrations.isEmpty }
            RecoveryWire.shared.configure(status:200,response:try signer.response(pending:pending),jwks:signer.jwks)
            await model.recoveryFixtureSubmit(pending,code:afterExchange ? "save-failure" : "checkpoint-failure")
            let label=afterExchange ? "session_save_failure" : "registration_checkpoint_failure"
            checks[label+"_preserves_old_account_and_storage_reason"] = store.oldPreserved && !model.busy && model.status.contains("本機安全會話") && !model.status.contains(SIWCSignInMessage.requirement)
            checks[label+"_request_count"] = RecoveryWire.shared.captured.count == (afterExchange ? 2 : 0)
        }
        checks["default_network_guard_never_triggered"] = C8NetworkProbe.shared.count == 0
        return checks
    }
}

struct AuthRecoveryChecksView: View {
    @State private var status="running"
    var body: some View {
        Text(status).accessibilityIdentifier("auth-recovery-result").task {
            do {
                let checks=try await RecoveryChecks.run();let passed=checks.values.allSatisfy { $0 }
                let report: [String:Any] = ["passed":passed,"checks":checks,"count":checks.count,"realNetworkRequests":0,"keychainAccess":false]
                let root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
                try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:root.appendingPathComponent("paid70-auth-checks.json"))
                status=passed ? "passed \(checks.count)" : "FAILED " + checks.filter { !$0.value }.map(\.key).sorted().joined(separator:",")
            } catch { status="FAILED local fixture" }
        }
    }
}

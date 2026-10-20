import SwiftUI
import Security

final class TextTrialWire: @unchecked Sendable {
    static let shared = TextTrialWire()
    private let lock = NSLock()
    private var paths: [String] = []
    private var bodies: [Data] = []
    private var refreshBodies: [Data] = []
    private var mode = "success"
    func reset(_ mode: String) { lock.withLock { paths = []; bodies = []; refreshBodies = []; self.mode = mode } }
    func record(_ request: URLRequest, _ body: Data) -> String { lock.withLock {
        paths.append(request.url?.path ?? "unknown"); if request.url?.path == "/v1/responses" { bodies.append(body) }; if request.url?.path == "/api/accounts/oauth/token" { refreshBodies.append(body) }; return mode
    } }
    var snapshot: (paths: [String], bodies: [Data], refreshBodies: [Data]) { lock.withLock { (paths, bodies, refreshBodies) } }
}
// Immutable in-memory SecKey; only platform signing reads it across URLProtocol calls.
struct TrialSigningFixture: @unchecked Sendable {
    let key: SecKey
    let jwks: Data
    init() throws {
        key = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048, kSecAttrIsPermanent: false] as CFDictionary, nil)!
        let publicKey = SecKeyCopyPublicKey(key)!
        let der = SecKeyCopyExternalRepresentation(publicKey, nil)! as Data
        var i = 0
        func field() -> Data {
            i += 1; var length = Int(der[i]); i += 1
            if length & 128 != 0 { let count = length & 127; length = 0; for _ in 0..<count { length = (length << 8) | Int(der[i]); i += 1 } }
            let result = der[i..<(i+length)]; i += length; return Data(result)
        }
        let sequence = field(); var integers: [Data] = []; var j = 0
        while j < sequence.count {
            j += 1; var length = Int(sequence[j]); j += 1
            if length & 128 != 0 { let count = length & 127; length = 0; for _ in 0..<count { length = length << 8 | Int(sequence[j]); j += 1 } }
            var data = Data(sequence[j..<(j+length)]); j += length
            while data.first == 0 { data.removeFirst() }; integers.append(data)
        }
        jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kid": "test-key", "kty": "RSA", "alg": "RS256", "use": "sig", "n": SIWCProtocol.encode(integers[0]), "e": SIWCProtocol.encode(integers[1])]]])
    }
    func token(_ overrides: [String: Any] = [:], alg: String = "RS256") throws -> String {
        var claims: [String: Any] = ["iss": SIWCProtocol.issuer, "sub": "test-sub", "aud": "test-client", "nonce": "test-nonce", "iat": 1000.0, "exp": 2000.0]
        for (key,value) in overrides { claims[key] = value }
        let header = try JSONSerialization.data(withJSONObject: ["alg": alg, "kid": "test-key"])
        let payload = try JSONSerialization.data(withJSONObject: claims)
        let signed = SIWCProtocol.encode(header) + "." + SIWCProtocol.encode(payload)
        let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(signed.utf8) as CFData, nil)! as Data
        return signed + "." + SIWCProtocol.encode(signature)
    }
}

final class TextTrialProtocol: URLProtocol, @unchecked Sendable {
    private static let signer = try! TrialSigningFixture()
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(contentsOf: buffer.prefix(n)) }
        }
        let mode = TextTrialWire.shared.record(request, body)
        if request.url?.host == "auth.openai.com" {
            let path = request.url!.path
            if path == "/.well-known/openid-configuration" {
                if mode == "refresh-discovery-http" { respond("{}",status:503,mime:"application/json");return }
                let token = mode == "refresh-discovery-invalid" ? "https://evil.invalid/token" : SIWCProtocol.issuer + "/api/accounts/oauth/token"
                let value = ["issuer":SIWCProtocol.issuer,"authorization_endpoint":SIWCProtocol.issuer + "/api/accounts/authorize","token_endpoint":token,"jwks_uri":SIWCProtocol.issuer + "/.well-known/jwks.json","revocation_endpoint":SIWCProtocol.issuer + "/api/accounts/oauth/revoke"]
                respond(String(decoding:try! JSONSerialization.data(withJSONObject:value),as:UTF8.self),mime:"application/json");return
            }
            if path == "/api/accounts/oauth/token" {
                if mode == "refresh-invalid-grant" { respond(#"{"error":"invalid_grant"}"#,status:400,mime:"application/json");return }
                if mode == "refresh-http500" { respond(#"{"error":"server_error"}"#,status:500,mime:"application/json");return }
                if mode == "refresh-malformed" { respond("{",mime:"application/json");return }
                if mode == "refresh-network" { client?.urlProtocol(self,didFailWithError:URLError(.timedOut));return }
                var value: [String:Any] = ["access_token":"synthetic-new-access","refresh_token":"synthetic-rotated-refresh","token_type":"Bearer","expires_in":3600]
                if mode == "refresh-no-rotation" { value.removeValue(forKey:"refresh_token") }
                if mode == "refresh-scope" { value["scope"] = "openid offline_access" }
                if ["refresh-id","refresh-identity","refresh-jwks"].contains(mode) {
                    value["id_token"] = try! Self.signer.token(["aud":"synthetic-client","sub":mode == "refresh-identity" ? "different-synthetic-subject" : "synthetic-subject","iat":Date().timeIntervalSince1970-1,"exp":Date().timeIntervalSince1970+3600])
                }
                let text = String(decoding:try! JSONSerialization.data(withJSONObject:value),as:UTF8.self)
                if mode == "refresh-slow" { DispatchQueue.global().asyncAfter(deadline:.now()+0.6) { [weak self] in self?.respond(text,mime:"application/json") } }
                else { respond(text,mime:"application/json") };return
            }
            if path == "/.well-known/jwks.json" {
                if mode == "refresh-jwks" { respond("{}",status:503,mime:"application/json") }
                else { respond(String(decoding:Self.signer.jwks,as:UTF8.self),mime:"application/json") };return
            }
            client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return
        }
        guard request.url?.host == "api.openai.com", ["/v1/models", "/v1/responses"].contains(request.url?.path ?? "") else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        if request.url?.path == "/v1/models" {
            if mode == "catalog-auth-rejected" { respond(#"{"error":{"code":"invalid_api_key"}}"#, status: 401, mime: "application/json"); return }
            respond(mode == "unlisted" ? #"{"models":[]}"# : #"{"models":[{"slug":"gpt-6-luna","display_name":"Synthetic","visibility":"list"}]}"#, status: 200, mime: "application/json"); return
        }
        if mode == "refresh-model401" { respond(#"{"error":{"code":"invalid_api_key"}}"#,status:401,mime:"application/json");return }
        if mode == "unsupported" { respond(#"{"error":{"code":"invalid_request_error","param":"max_output_tokens"}}"#, status: 400, mime: "application/json"); return }
        if mode == "rate" { respond(#"{"error":{"code":"rate_limit_exceeded"}}"#, status: 429, mime: "application/json"); return }
        if mode == "incomplete" { respond("data: {\"type\":\"response.incomplete\",\"response\":{\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}\n\n"); return }
        let answer = mode == "malformed" ? "{" : String(decoding: try! JSONEncoder().encode(WikipediaReviewAnswer(decision: .no_match)), as: UTF8.self)
        let event = try! JSONSerialization.data(withJSONObject: ["type":"response.output_text.delta", "delta": answer])
        let text = "data: " + String(decoding: event, as: UTF8.self) + "\n\ndata: {\"type\":\"response.completed\"}\n\n"
        if mode == "slow" { DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.respond(text) } }
        else { respond(text) }
    }
    private func respond(_ text: String, status: Int = 200, mime: String = "text/event-stream") {
        lock.withLock {
            guard !stopped else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8)); client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.withLock { stopped = true } }
}

@MainActor final class TextTrialFixture {
    let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("synthetic-text-" + UUID().uuidString)
    var cases: [TextTrialCase] = []
    var bodies: [Data] = []
    var args: [String] = []
    var saved: SIWCSaved?
    var accountLoads = 0
    var accountSaves = 0
    var failSave = false
    var originalPermit = Data()
    var history = Data("synthetic untouched history sentinel".utf8)
    func prepare(_ scenario: String = "success") throws {
        let base = root.appendingPathComponent("GlanceTextTrial48")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("input"), withIntermediateDirectories: true)
        try history.write(to: root.appendingPathComponent("history.json"))
        let result = RecognitionResult(names: ["曙光"], summary: "原始簡介", text: ["AURORA"], searchContractVersion: 17, searchEntities: [.init(kind: .brand, name: "曙光", sourceText: "AURORA")])
        let source = WikipediaReviewSource(pageID: 4501, title: "曙光公司", url: URL(string:"https://zh.wikipedia.org/wiki/Aurora")!, fetchedAt: Date(), excerpts: [.init(id:"p0", text:"曙光公司持有曙光品牌，產品包含合成驗證用零食。")])
        for sequence in [152,153,149,147] {
            let raw = try WikipediaSemanticReview.request(result: result, rawStageOne: "{\"synthetic\":\(sequence)}", sources: [source], catalog: [.init(slug:"gpt-6-luna", display_name:"Synthetic", visibility:"list")])
            var object = try JSONSerialization.jsonObject(with: raw) as! [String:Any]; object["max_output_tokens"] = 8192
            let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]); bodies.append(body)
            cases.append(.init(sequence: sequence, bodySHA256: RecognitionArchive.hash(body), byteCount:body.count))
            try body.write(to: base.appendingPathComponent("input/\(sequence).json"))
        }
        let now = Date().timeIntervalSince1970, id = UUID()
        let permit: [String:Any] = ["schemaVersion":2,"runID":id.uuidString,"appBuild":"48","catalogSHA256":try TextTrialContract.catalogHash(cases),"issuedAt":now-1,"expiresAt":now+300,"consentRevision":TextTrialContract.revision,"allowsFourTextRequests":true,"allowsExistingGrantRefresh":true,"maximumRefreshRequests":1,"maximumRequests":4,"maximumOutputTokens":8192]
        originalPermit = try JSONSerialization.data(withJSONObject:permit, options:[.sortedKeys]); try originalPermit.write(to:base.appendingPathComponent("permit.json"))
        args = ["--text-trial-run=" + id.uuidString,"--text-trial-permit-sha=" + RecognitionArchive.hash(originalPermit)]
        let token = SIWCTokens(access:"synthetic-access", refresh:nil, idToken:"synthetic-id", scope:SIWCProtocol.scopes, expiresAt:Date().addingTimeInterval(scenario == "expired" ? -10 : 3600))
        let account = SIWCAccount(clientID:"synthetic-client", subject:"synthetic-subject", email:nil, tokens:token, authenticationTraceID: UUID())
        saved = scenario == "missing" ? nil : SIWCSaved(hostID:"synthetic-host", accounts:[account], selected:account.id)
    }
    func coordinator(arguments: [String]? = nil, timeout: Duration = .seconds(70), beforeWrite: @escaping (URL) throws -> Void = { _ in }) -> TextTrialCoordinator {
        #if GLANCE_READINESS_DIAGNOSTIC
        let build = "47"
        #else
        let build = "48"
        #endif
        return TextTrialCoordinator(arguments:arguments ?? args, documents:root, build:build, cases:cases, timeout:timeout, sessionFactory:{
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TextTrialProtocol.self]
            return TextTrialSession(load:{ self.accountLoads += 1; return self.saved }, client:SIWCHTTP(configuration:config),save:{ value in
                if self.failSave { throw SIWCTrialSessionWriteError(status:errSecInteractionNotAllowed) }
                self.saved = value; self.accountSaves += 1
            })
        }, beforeWrite:beforeWrite)
    }
    func cleanup() { try? FileManager.default.removeItem(at:root) }
}

@MainActor @Observable final class TextTrialChecks {
    var result = "running"
    var checks: [[String:Any]] = []
    func check(_ name: String, _ passed: Bool) { checks.append(["name":name,"passed":passed]) }
    func readinessChecks() async throws {
        let f = TextTrialFixture(); try f.prepare(); defer { f.cleanup() }
        let clock = Date(timeIntervalSince1970: 2_000_000), original = f.saved!
        let cases: [(String, String, Double?)] = [
            ("ready", "ready", 61), ("missing", "saved-session-missing", nil),
            ("selected-nil", "selected-account-missing", nil), ("selected-absent", "selected-account-not-found", nil),
            ("tokens-nil", "tokens-missing", nil), ("expired", "access-expired-refresh-disabled", -1),
            ("expiry-zero", "access-expired-refresh-disabled", 0), ("expiry-60", "access-expiring-refresh-disabled", 60),
            ("expiry-30", "access-expiring-refresh-disabled", 30), ("scope", "plan-scope-missing", 3600),
            ("generic-read", "session-read-failed", nil), ("keychain-interaction", "keychain-interaction-unavailable", nil),
            ("keychain-auth", "keychain-access-denied", nil), ("keychain-entitlement", "keychain-entitlement-missing", nil),
            ("keychain-unavailable", "keychain-service-unavailable", nil), ("keychain-other", "keychain-other-status", nil),
            ("data-missing", "session-data-missing", nil), ("decode", "session-decode-failed", nil),
            ("keychain-item-absent", "saved-session-missing", nil)
        ]
        for (name, expected, lifetime) in cases {
            var saved: SIWCSaved? = original
            saved?.accounts[0].tokens?.expiresAt = clock.addingTimeInterval(lifetime ?? 3600)
            saved?.accounts[0].tokens?.refresh = "synthetic-refresh-private"
            saved?.accounts[0].email = "diagnostic-private@example.invalid"
            if name == "missing" { saved = nil }
            if name == "selected-nil" { saved?.selected = nil }
            if name == "selected-absent" { saved?.selected = "different-private-id" }
            if name == "tokens-nil" { saved?.accounts[0].tokens = nil }
            if name == "scope" { saved?.accounts[0].tokens?.scope = "openid offline_access" }
            TextTrialWire.shared.reset("success")
            let session = TextTrialSession(load: {
                switch name {
                case "generic-read": throw CocoaError(.fileReadNoPermission)
                case "keychain-interaction": return try SIWCTrialSessionRead.decode(status: errSecInteractionNotAllowed, data: nil)
                case "keychain-auth": return try SIWCTrialSessionRead.decode(status: errSecAuthFailed, data: nil)
                case "keychain-entitlement": return try SIWCTrialSessionRead.decode(status: errSecMissingEntitlement, data: nil)
                case "keychain-unavailable": return try SIWCTrialSessionRead.decode(status: errSecNotAvailable, data: nil)
                case "keychain-other": return try SIWCTrialSessionRead.decode(status: -99999, data: nil)
                case "keychain-item-absent": return try SIWCTrialSessionRead.decode(status: errSecItemNotFound, data: nil)
                case "data-missing": return try SIWCTrialSessionRead.decode(status: errSecSuccess, data: nil)
                case "decode": return try SIWCTrialSessionRead.decode(status: errSecSuccess, data: Data("private malformed session".utf8))
                default: return saved
                }
            }, now: { clock })
            var failed = false
            do { try session.checkReadiness() } catch { failed = true; session.recordFailure(error) }
            let safe = session.safeDiagnostic
            check("readiness-" + name + "-specific-reason", safe["readinessReason"] as? String == expected && failed == (name != "ready"))
            check("readiness-" + name + "-zero-network", TextTrialWire.shared.snapshot.paths.isEmpty && safe["catalogRequestStarted"] as? Bool == false)
            let encoded = String(decoding:try JSONSerialization.data(withJSONObject:safe,options:[.sortedKeys]),as:UTF8.self)
            let forbidden = ["synthetic-access", "synthetic-id", "synthetic-client", "synthetic-subject", "synthetic-refresh-private", "diagnostic-private@example.invalid", "private malformed session", "different-private-id", original.accounts[0].authenticationTraceID!.uuidString]
            check("readiness-" + name + "-no-private-values", forbidden.allSatisfy { !encoded.contains($0) })
            if name.hasPrefix("expiry") || name == "expired" { check("readiness-" + name + "-refresh-not-used", safe["refreshCredentialPresent"] as? Bool == true && safe["refreshPolicy"] as? String == "disabled-for-trial") }
            session.cancel()
        }
        let encoded = try JSONEncoder().encode(original)
        let decoded = try SIWCTrialSessionRead.decode(status:errSecSuccess,data:encoded)
        check("readiness-valid-record-decoded-without-rewriting", decoded?.selected == original.selected && decoded?.accounts[0].tokens?.access == "synthetic-access")
        #if !GLANCE_READINESS_DIAGNOSTIC
        var current = original
        current.accounts[0].tokens?.expiresAt = clock.addingTimeInterval(3600)
        TextTrialWire.shared.reset("success")
        let changed = TextTrialSession(load:{current},now:{clock}); try await changed.prepare { }
        current.accounts[0].authenticationTraceID = UUID()
        do { _ = try await changed.send(f.bodies[0]) { }; check("readiness-account-change-stops-before-model",false) }
        catch { changed.recordFailure(error); check("readiness-account-change-stops-before-model",changed.safeDiagnostic["readinessReason"] as? String == "account-changed" && TextTrialWire.shared.snapshot.bodies.isEmpty) }
        changed.cancel()
        var time = clock
        TextTrialWire.shared.reset("success")
        let expiring = TextTrialSession(load:{current},now:{time}); try await expiring.prepare {}
        time = clock.addingTimeInterval(7200)
        do { _ = try await expiring.send(f.bodies[0]) {}; check("readiness-expiry-after-catalog-is-specific",false) }
        catch { expiring.recordFailure(error); check("readiness-expiry-after-catalog-is-specific", expiring.safeDiagnostic["readinessReason"] as? String == "access-expired-after-session-update" && expiring.safeDiagnostic["readinessStage"] as? String == "before-response" && TextTrialWire.shared.snapshot.paths == ["/v1/models"]) }
        expiring.cancel()
        TextTrialWire.shared.reset("catalog-auth-rejected")
        let rejected = TextTrialSession(load:{current},now:{clock})
        do { try await rejected.prepare { }; check("service-401-distinct-from-local-readiness",false) }
        catch { rejected.recordFailure(error); let safe=rejected.safeDiagnostic; check("service-401-distinct-from-local-readiness",safe["readinessReason"] as? String == "ready" && safe["errorCategory"] as? String == "http" && safe["httpStatus"] as? Int == 401 && TextTrialWire.shared.snapshot.bodies.isEmpty) }
        rejected.cancel()
        #endif
    }
    func preflightChecks() async throws {
        for scenario in ["success", "expired", "missing"] {
            let f = TextTrialFixture(); try f.prepare(scenario); defer { f.cleanup() }
            let id = UUID(), flag = "--text-trial-readiness=" + id.uuidString
            let permit = try Data(contentsOf:f.root.appendingPathComponent("GlanceTextTrial48/permit.json"))
            TextTrialWire.shared.reset("success")
            let c = f.coordinator(arguments:[flag]); await c.run()
            let file = f.root.appendingPathComponent("GlanceTextTrialReadiness/" + id.uuidString + "/summary.json")
            let report = try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
            let expected = scenario == "success" ? "ready" : scenario == "expired" ? "access-expired-refresh-disabled" : "saved-session-missing"
            check("preflight-" + scenario + "-specific-result", (report["diagnostic"] as? [String:Any])?["readinessReason"] as? String == expected)
            check("preflight-" + scenario + "-no-network-or-model", TextTrialWire.shared.snapshot.paths.isEmpty && c.submitted.isEmpty && !c.completed && report["networkRequests"] as? Int == 0)
            check("preflight-" + scenario + "-permit-and-history-untouched", try Data(contentsOf:f.root.appendingPathComponent("GlanceTextTrial48/permit.json")) == permit && Data(contentsOf:f.root.appendingPathComponent("history.json")) == f.history && c.store == nil)
            let loads = f.accountLoads, again = f.coordinator(arguments:[flag]); await again.run()
            check("preflight-" + scenario + "-single-use", again.phase == "readiness-unavailable" && f.accountLoads == loads)
        }
        let f = TextTrialFixture(); try f.prepare(); defer { f.cleanup() }; TextTrialWire.shared.reset("success")
        let mixed = f.coordinator(arguments:["--text-trial-readiness=" + UUID().uuidString]+f.args); await mixed.run()
        check("preflight-mixed-model-arguments-rejected", mixed.phase == "readiness-unavailable" && f.accountLoads == 0 && TextTrialWire.shared.snapshot.paths.isEmpty)
        let bad = f.coordinator(arguments:["--text-trial-readiness=not-a-uuid"]); await bad.run()
        check("preflight-malformed-arguments-no-account-read", bad.phase == "readiness-unavailable" && f.accountLoads == 0)
        let unwritable = f.coordinator(arguments:["--text-trial-readiness=" + UUID().uuidString], beforeWrite:{_ in throw CocoaError(.fileWriteOutOfSpace)}); await unwritable.run()
        check("preflight-write-failure-before-account-read", unwritable.phase == "readiness-unavailable" && f.accountLoads == 0 && TextTrialWire.shared.snapshot.paths.isEmpty)
    }
    #if GLANCE_READINESS_DIAGNOSTIC
    func diagnosticIsolationChecks() async throws {
        let f = TextTrialFixture(); try f.prepare(); defer { f.cleanup() }; TextTrialWire.shared.reset("success")
        let permitPath = f.root.appendingPathComponent("GlanceTextTrial48/permit.json"), permit = try Data(contentsOf:permitPath)
        let blocked = f.coordinator(); await blocked.run()
        check("diagnostic-build-model-launch-disabled",blocked.phase == "readiness-unavailable" && f.accountLoads == 0 && blocked.submitted.isEmpty)
        check("diagnostic-build-model-permit-not-consumed",try Data(contentsOf:permitPath) == permit && blocked.store == nil)
        for argument in ["--siwc-validation","--camera-start","--mock","--bounded-saved-replay=" + UUID().uuidString] {
            let c = f.coordinator(arguments:[argument]);await c.run()
            check("diagnostic-legacy-flag-ignored-" + argument.split(separator:"=")[0],c.phase == "idle" && f.accountLoads == 0 && TextTrialWire.shared.snapshot.paths.isEmpty)
        }
        var loaded = 0, callback = 0
        let session = TextTrialSession(load:{loaded += 1;return f.saved})
        do {try await session.prepare {};check("diagnostic-session-catalog-disabled",false)}
        catch {check("diagnostic-session-catalog-disabled",error is SIWCReadinessNetworkDisabled && loaded == 0)}
        do {_ = try await session.send(f.bodies[0]) {callback += 1};check("diagnostic-session-model-disabled",false)}
        catch {check("diagnostic-session-model-disabled",error is SIWCReadinessNetworkDisabled && loaded == 0 && callback == 0)}
        let client = SIWCHTTP()
        for url in [SIWCProtocol.resource + "/models", "https://auth.openai.com/oauth/token"] {
            do {_ = try await client.data(url:url,body:Data("synthetic-only".utf8),observeRequest:{_ in callback += 1});check("diagnostic-HTTP-disabled-" + url,false)}
            catch {check("diagnostic-HTTP-disabled-" + url,error is SIWCReadinessNetworkDisabled && callback == 0 && client.diagnostics.isEmpty)}
        }
        do {_ = try await client.stream(body:f.bodies[0],bearer:"synthetic-access",validateBeforeImageSend:{callback += 1});check("diagnostic-stream-disabled",false)}
        catch {check("diagnostic-stream-disabled",error is SIWCReadinessNetworkDisabled && callback == 0 && client.diagnostics.isEmpty)}
        session.cancel();client.cancelRequests()
        check("diagnostic-all-transport-probes-zero-network",TextTrialWire.shared.snapshot.paths.isEmpty)
    }
    #endif
    #if !GLANCE_READINESS_DIAGNOSTIC
    func refreshChecks() async throws {
        let scenarios = ["refresh-success","refresh-id","refresh-invalid-grant","refresh-http500","refresh-malformed","refresh-no-rotation","refresh-identity","refresh-jwks","refresh-network","refresh-discovery-invalid","refresh-discovery-http","refresh-save","refresh-claim","refresh-cancel","refresh-background","refresh-timeout","refresh-account-change","refresh-too-early","refresh-scope","refresh-model401"]
        for scenario in scenarios {
            let f = TextTrialFixture();try f.prepare();defer { f.cleanup() }
            f.saved!.accounts[0].tokens!.expiresAt = Date().addingTimeInterval(-10)
            f.saved!.accounts[0].tokens!.refresh = "synthetic-old-refresh-private"
            f.saved!.pendingRegistrations = [.init(id:"synthetic-pending",label:"private-label",clientID:"different-client",savedAt:Date())]
            if scenario == "refresh-too-early" { f.saved!.accounts[0].tokens!.earliestRefreshAt = Date().addingTimeInterval(300) }
            f.failSave = scenario == "refresh-save"
            let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
            let original = try encoder.encode(f.saved!)
            let slow = ["refresh-cancel","refresh-background","refresh-timeout","refresh-account-change"].contains(scenario)
            TextTrialWire.shared.reset(slow ? "refresh-slow" : scenario)
            var stateWrites = 0
            let controller = f.coordinator(beforeWrite:{ url in
                if url.lastPathComponent == "state.json" { stateWrites += 1; if scenario == "refresh-claim" && stateWrites == 2 { throw CocoaError(.fileWriteOutOfSpace) } }
            })
            if slow {
                let work = Task { await controller.run() }
                for _ in 0..<100 { if !TextTrialWire.shared.snapshot.refreshBodies.isEmpty { break };try await Task.sleep(for:.milliseconds(10)) }
                if scenario == "refresh-account-change" { f.saved!.accounts[0].authenticationTraceID = UUID() }
                else { controller.stop(reason:scenario.replacingOccurrences(of:"refresh-",with:"")) }
                await work.value
            } else { await controller.run() }
            let wire = TextTrialWire.shared.snapshot
            let success = ["refresh-success","refresh-id"].contains(scenario)
            let sent = success ? 4 : scenario == "refresh-model401" ? 1 : 0
            let post = ["refresh-too-early","refresh-discovery-invalid","refresh-discovery-http","refresh-claim"].contains(scenario) ? 0 : 1
            let saved = success || ["refresh-scope","refresh-model401"].contains(scenario)
            check(scenario + "-exact-bounded-requests",wire.bodies.count == sent && wire.refreshBodies.count == post && controller.submitted.count == sent)
            check(scenario + "-exact-original-texts",wire.bodies == Array(f.bodies.prefix(sent)))
            check(scenario + "-one-refresh-and-no-login",wire.paths.filter{$0 == "/api/accounts/oauth/token"}.count <= 1 && wire.paths.allSatisfy{["/.well-known/openid-configuration","/api/accounts/oauth/token","/.well-known/jwks.json","/v1/models","/v1/responses"].contains($0)})
            check(scenario + "-in-place-save-count",f.accountSaves == (saved ? 1 : 0))
            check(scenario + "-completed-only-when-all-four",controller.completed == success && controller.store?.state.terminal == true)
            check(scenario + "-history-preserved",try Data(contentsOf:f.root.appendingPathComponent("history.json")) == f.history)
            if post == 1 {
                let text = String(decoding:wire.refreshBodies[0],as:UTF8.self)
                let fields = Dictionary(uniqueKeysWithValues:text.split(separator:"&").map { field -> (String,String) in let pair=field.split(separator:"=",maxSplits:1,omittingEmptySubsequences:false);return (String(pair[0]),String(pair[1]).removingPercentEncoding!) })
                check(scenario + "-same-grant-form-only",Set(fields.keys)==["grant_type","client_id","refresh_token","resource"] && fields["grant_type"]=="refresh_token" && fields["client_id"]=="synthetic-client" && fields["refresh_token"]=="synthetic-old-refresh-private" && fields["resource"]==SIWCProtocol.resource)
                check(scenario + "-claim-persisted",controller.store?.state.refreshClaimed == true)
            }
            if saved {
                check(scenario + "-rotation-and-identity-preserved",f.saved!.accounts[0].tokens!.refresh == "synthetic-rotated-refresh" && f.saved!.accounts[0].clientID == "synthetic-client" && f.saved!.accounts[0].subject == "synthetic-subject" && f.saved!.hostID == "synthetic-host" && f.saved!.pendingRegistrations.count == 1)
            } else if scenario != "refresh-account-change" { check(scenario + "-original-session-not-cleared",try encoder.encode(f.saved!) == original) }
            guard let store = controller.store else { check(scenario + "-has-store",false);continue }
            let data = try Data(contentsOf:store.runDirectory.appendingPathComponent("summary.json"))
            let report = try JSONSerialization.jsonObject(with:data) as! [String:Any], diagnostic = report["diagnostic"] as! [String:Any]
            let encoded = String(decoding:data,as:UTF8.self)
            check(scenario + "-summary-has-no-credentials-or-identities",["synthetic-old-refresh-private","synthetic-rotated-refresh","synthetic-new-access","synthetic-client","synthetic-subject","private-label","different-client"].allSatisfy{!encoded.contains($0)})
            check(scenario + "-counts-honest",report["refreshRequests"] as? Int == post && report["refreshes"] as? Int == (saved ? 1 : 0) && report["maximumRefreshRequests"] as? Int == 1)
            if scenario == "refresh-save" { check("refresh-save-exact-stage-and-status",diagnostic["sessionUpdateStage"] as? String == "save" && diagnostic["sessionUpdateReason"] as? String == "session-save-failed" && diagnostic["keychainWriteStatus"] as? Int == Int(errSecInteractionNotAllowed)) }
            if scenario == "refresh-identity" { check("refresh-identity-before-save",diagnostic["sessionUpdateStage"] as? String == "identity" && f.accountSaves == 0 && wire.paths.contains("/.well-known/jwks.json")) }
            if scenario == "refresh-invalid-grant" { check("refresh-terminal-error-not-new-login",diagnostic["httpStatus"] as? Int == 400 && diagnostic["errorCode"] as? String == "invalid_grant" && diagnostic["sessionUpdateStage"] as? String == "refresh") }
            if scenario == "refresh-id" { check("refresh-new-id-verified-through-real-signature",wire.paths.filter{$0 == "/.well-known/jwks.json"}.count == 1 && f.accountSaves == 1) }
            if scenario == "refresh-success" { check("refresh-retained-id-and-scope-no-jwks",f.saved!.accounts[0].tokens!.idToken == "synthetic-id" && f.saved!.accounts[0].tokens!.scope == SIWCProtocol.scopes && !wire.paths.contains("/.well-known/jwks.json")) }
            if slow { try await Task.sleep(for:.milliseconds(700));check(scenario + "-no-late-save-or-model",f.accountSaves == 0 && TextTrialWire.shared.snapshot.bodies.isEmpty) }
        }
    }
    #endif
    func run() async {
        do {
            try await readinessChecks()
            try await preflightChecks()
            #if !GLANCE_READINESS_DIAGNOSTIC
            try await refreshChecks()
            #endif
            let ordinary = TextTrialFixture(); defer { ordinary.cleanup() }
            TextTrialWire.shared.reset("success")
            let idle = ordinary.coordinator(arguments:[]); await idle.run()
            check("ordinary-launch-no-account-network-or-files", idle.phase == "idle" && ordinary.accountLoads == 0 && TextTrialWire.shared.snapshot.paths.isEmpty && !FileManager.default.fileExists(atPath:ordinary.root.path))
            let malformed = ordinary.coordinator(arguments:["--text-trial-run=invalid"]); await malformed.run()
            #if GLANCE_READINESS_DIAGNOSTIC
            check("malformed-arguments-zero-account-or-network", malformed.phase == "readiness-unavailable" && ordinary.accountLoads == 0 && TextTrialWire.shared.snapshot.paths.isEmpty)
            #else
            check("malformed-arguments-zero-account-or-network", malformed.phase == "failed" && ordinary.accountLoads == 0 && TextTrialWire.shared.snapshot.paths.isEmpty)
            #endif
            #if GLANCE_READINESS_DIAGNOSTIC
            try await diagnosticIsolationChecks()
            #else
            for scenario in ["success","unsupported","rate","incomplete","malformed","unlisted","expired","missing","claim-write","response-write","cancel","background","timeout","account-change"] {
                let f = TextTrialFixture(); defer { f.cleanup() }; try f.prepare(scenario)
                let slow = ["cancel","background","timeout","account-change"].contains(scenario)
                TextTrialWire.shared.reset(slow ? "slow" : scenario)
                var stateWrites = 0
                let c = f.coordinator(timeout:scenario == "timeout" ? .milliseconds(60) : .seconds(70), beforeWrite:{ url in
                    if url.lastPathComponent == "state.json" { stateWrites += 1; if scenario == "claim-write" && stateWrites == 2 { throw CocoaError(.fileWriteOutOfSpace) } }
                    if scenario == "response-write" && url.lastPathComponent.hasPrefix("response-") { throw CocoaError(.fileWriteOutOfSpace) }
                })
                if slow && scenario != "timeout" {
                    let work = Task { await c.run() }
                    for _ in 0..<100 { if !TextTrialWire.shared.snapshot.bodies.isEmpty { break }; try await Task.sleep(for:.milliseconds(10)) }
                    if scenario == "account-change" { f.saved?.selected = "different" } else { c.stop(reason:scenario == "background" ? "background" : "cancelled") }
                    await work.value
                } else { await c.run() }
                let wire = TextTrialWire.shared.snapshot
                let expected = scenario == "success" ? 4 : ["unlisted","expired","missing","claim-write"].contains(scenario) ? 0 : 1
                check(scenario + "-bounded-count", wire.bodies.count == expected && c.submitted.count == expected)
                check(scenario + "-exact-text-bodies", Array(f.bodies.prefix(expected)) == wire.bodies)
                check(scenario + "-history-preserved", try Data(contentsOf:f.root.appendingPathComponent("history.json")) == f.history)
                check(scenario + "-only-models-and-responses", wire.paths.allSatisfy { ["/v1/models","/v1/responses"].contains($0) })
                check(scenario + "-completion", c.completed == (scenario == "success"))
                check(scenario + "-terminal", c.store?.state.terminal == true)
                if ["expired", "missing"].contains(scenario), let store = c.store {
                    let summary = try JSONSerialization.jsonObject(with:Data(contentsOf:store.runDirectory.appendingPathComponent("summary.json"))) as! [String:Any]
                    let diagnostic = summary["diagnostic"] as! [String:Any]
                    let specific = scenario == "expired" ? diagnostic["sessionUpdateReason"] as? String == "refresh-credential-missing" : diagnostic["readinessReason"] as? String == "saved-session-missing"
                    check(scenario + "-specific-cause-persisted", specific && diagnostic["catalogRequestStarted"] as? Bool == false)

                }
                if scenario == "success" {
                    check("success-four-mechanical-contracts", c.rows.count == 4 && c.rows.allSatisfy { $0["mechanicalContractPassed"] as? Bool == true && $0["semanticContentAccepted"] as? Bool == false })
                    try f.originalPermit.write(to:f.root.appendingPathComponent("GlanceTextTrial48/permit.json"))
                    let loads = f.accountLoads; let rerun = f.coordinator(); await rerun.run()
                    check("consumed-run-cannot-restart", rerun.phase == "failed" && f.accountLoads == loads && TextTrialWire.shared.snapshot.bodies.count == 4)
                }
                if scenario == "unsupported", let store = c.store {
                    let summary = try JSONSerialization.jsonObject(with:Data(contentsOf:store.runDirectory.appendingPathComponent("summary.json"))) as! [String:Any]
                    check("unsupported-cap-reported-no-fallback", (summary["diagnostic"] as? [String:Any])?["errorParameter"] as? String == "max_output_tokens")
                }
                if slow { try await Task.sleep(for:.milliseconds(700)); check(scenario + "-no-late-write-or-retry", TextTrialWire.shared.snapshot.bodies.count == 1 && c.rows.isEmpty) }
            }
            #endif
        } catch { checks.append(["name":"unexpected-fixture-error","passed":false,"type":String(describing:type(of:error))]) }
        let failed = checks.filter { $0["passed"] as? Bool != true }
        result = failed.isEmpty ? "PASS \(checks.count)" : "FAIL \(failed.count)/\(checks.count): " + failed.compactMap { $0["name"] as? String }.joined(separator:", ")
        let summary: [String:Any] = ["passed":failed.isEmpty,"checks":checks,"count":checks.count,"credentialSource":"synthetic-only","externalNetwork":false]
        let url = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("text-trial-checks.json")
        try? JSONSerialization.data(withJSONObject:summary,options:[.sortedKeys,.prettyPrinted]).write(to:url)
    }
}
@main struct TextTrialFixtureApp: App {
    @State private var checks = TextTrialChecks()
    var body: some Scene { WindowGroup {
        if ProcessInfo.processInfo.arguments.contains("--checks") {
            ScrollView { Text(checks.result).accessibilityIdentifier("fixtureResult").padding() }.task { await checks.run() }
        } else { BoundedTextTrialView(arguments:[]) }
    } }
}

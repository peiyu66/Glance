import Foundation
import Security
import Testing
@testable import GlanceCore

private func pending(client: String? = nil, expiry: Date = Date().addingTimeInterval(60)) -> SIWCPending {
    SIWCPending(state: "expected-state", nonce: "expected-nonce", verifier: "verifier", port: 54321, clientID: client, deadline: expiry)
}
@Test func pkceAndAuthorizationBinding() throws {
    #expect(SIWCProtocol.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    let url = pending().authorize(hostID: "test-host")
    let q = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
    #expect(q["client_id"] == "dynamic_agent_client")
    #expect(q["redirect_uri"] == "http://127.0.0.1:54321/auth/callback")
    #expect(q["agent_name_hint"] == "Glance")
    #expect(q["scope"] == SIWCProtocol.scopes)
    let again = URLComponents(url: pending(client: "issued-client").authorize(hostID: "test-host", idTokenHint: "synthetic-hint"), resolvingAgainstBaseURL: false)!.queryItems!
    #expect(!again.contains { $0.name == "agent_name_hint" })
    #expect(again.first { $0.name == "client_id" }?.value == "issued-client")
    #expect(String(data: SIWCProtocol.form(["v": "a+b &c"]), encoding: .utf8) == "v=a%2Bb%20%26c")
}
@Test func callbackRejectsMismatchReplayAndExpiry() throws {
    var p = pending()
    #expect(throws: SIWCError.self) { try p.callback(target: "/auth/callback?state=wrong&code=c&client_id=issued") }
    #expect(throws: SIWCError.self) { try p.callback(target: "/auth/callback?state=expected-state&code=c") }
    #expect(throws: SIWCError.self) { try p.callback(target: "/auth/callback?state=expected-state&state=expected-state&code=c&client_id=issued") }
    let valid = try p.callback(target: "/auth/callback?state=expected-state&code=c&client_id=issued")
    #expect(valid.clientID == "issued")
    #expect(throws: SIWCError.self) { try p.callback(target: "/auth/callback?state=expected-state&code=c&client_id=issued") }
    var returning = pending(client: "original")
    #expect(throws: SIWCError.self) { try returning.callback(target: "/auth/callback?state=expected-state&code=c&client_id=other") }
    let same = try returning.callback(target: "/auth/callback?state=expected-state&code=c")
    #expect(same.clientID == "original")
    var expired = pending(expiry: Date(timeIntervalSince1970: 0))
    #expect(throws: SIWCError.self) { try expired.callback(target: "/auth/callback?state=expected-state&code=c&client_id=issued") }
    var denied = pending()
    #expect(throws: SIWCError.denied) { try denied.callback(target: "/auth/callback?state=expected-state&error=access_denied") }
}
@Test func planScopeAndSafeImageBody() throws {
    #expect(!SIWCProtocol.hasPlan("openid profile email"))
    #expect(SIWCProtocol.hasPlan(SIWCProtocol.scopes))
    let catalog = try JSONDecoder().decode(SIWCCatalog.self, from: Data(#"{"models":[{"slug":"gpt-6-luna","display_name":"Candidate","visibility":"list"}]}"#.utf8))
    let body = try SIWCInference.body(model: "gpt-6-luna", catalog: catalog.models, png: Data([1,2,3]))
    let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
    #expect(json["store"] as? Bool == false); #expect(json["stream"] as? Bool == true)
    #expect(Set(json.keys) == Set(["model", "reasoning", "store", "stream", "input"]))
    #expect(throws: SIWCError.modelUnavailable) { try SIWCInference.body(model: "not-in-account", catalog: catalog.models, png: Data([1])) }
}
@Test func streamRequiresCompletedEvent() throws {
    var s = SIWCStream()
    try s.line(#"data: {"type":"response.output_text.delta","delta":"red square"}"#); try s.line("")
    #expect(throws: SIWCError.incompleteStream) { try s.finish() }
    try s.line(#"data: {"type":"response.completed"}"#); try s.line("")
    let result = try s.finish(); #expect(result == "red square")
    var failed = SIWCStream()
    try failed.line(#"data: {"type":"response.failed"}"#)
    #expect(throws: SIWCStreamFailure.self) { try failed.line("") }
}

private struct SigningFixture {
    let key: SecKey
    let jwks: Data
    init() throws {
        key = try #require(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        let der = try #require(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
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
        let signature = try #require(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(signed.utf8) as CFData, nil)) as Data
        return signed + "." + SIWCProtocol.encode(signature)
    }
}
@Test func oidcSignatureAndClaimsFailClosed() throws {
    let f = try SigningFixture(); let now = Date(timeIntervalSince1970: 1500)
    let good = try f.token()
    let identity = try SIWCIdentityVerifier.verify(good, jwks: f.jwks, clientID: "test-client", nonce: "test-nonce", now: now)
    #expect(identity.subject == "test-sub")
    for claims: [String: Any] in [["iss":"https://example.com"], ["aud":"other"], ["exp":1400.0], ["nonce":"other"], ["iat":1600.0], ["sub":""], ["azp":"other"], ["nbf":1600.0]] {
        let token = try f.token(claims)
        #expect(throws: SIWCError.self) { try SIWCIdentityVerifier.verify(token, jwks: f.jwks, clientID: "test-client", nonce: "test-nonce", now: now) }
    }
    let wrongAlg = try f.token(alg: "none")
    #expect(throws: SIWCError.self) { try SIWCIdentityVerifier.verify(wrongAlg, jwks: f.jwks, clientID: "test-client", nonce: "test-nonce", now: now) }
    let pieces = good.split(separator: ".").map(String.init)
    let tampered = pieces[0] + "." + SIWCProtocol.encode(Data(#"{"sub":"intruder"}"#.utf8)) + "." + pieces[2]
    #expect(throws: SIWCError.self) { try SIWCIdentityVerifier.verify(tampered, jwks: f.jwks, clientID: "test-client", nonce: "test-nonce", now: now) }
    #expect(throws: SIWCError.self) { try SIWCIdentityVerifier.verify(good, jwks: f.jwks, clientID: "test-client", nonce: "test-nonce", expectedSubject: "other-account", now: now) }
}

@Test func sseByteFramingPreservesEmptyLinesAndUnicode() throws {
    for newline in ["\n", "\r\n", "\r"] {
        let fixture = [": heartbeat", "", "event: response.output_text.delta", #"data: {"type":"response.output_text.delta","delta":"紅色方形 GLANCE 123"}"#, "", #"data: {"type":"response.completed"}"#, "", ""].joined(separator: newline)
        var parser = SIWCStream()
        for byte in fixture.utf8 { try parser.byte(byte) }
        #expect(try parser.finish() == "紅色方形 GLANCE 123")
        #expect(parser.terminal == "response.completed")
    }
}
@Test func sseFailuresRetainOnlySafeStructuredFields() throws {
    let fixture = #"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"private ignored payload","param":"model"}}}"# + "\n\n"
    var parser = SIWCStream()
    do {
        for byte in fixture.utf8 { try parser.byte(byte) }
        Issue.record("A failed terminal must throw")
    } catch let failure as SIWCStreamFailure {
        #expect(failure.terminal == "response.failed")
        #expect(failure.code == "subscription_sharing_usage_limit_exceeded")
        #expect(failure.parameter == "model")
    }
    #expect(SIWCSafeDiagnostic.code("arbitrary_private_content") == "unrecognized_error_code")
    #expect(SIWCSafeDiagnostic.parameter("private@example.invalid") == "unrecognized_parameter")
    var incomplete = SIWCStream()
    for byte in (#"data: {"type":"response.output_text.delta","delta":"partial"}"# + "\n\n").utf8 { try incomplete.byte(byte) }
    #expect(throws: SIWCError.incompleteStream) { try incomplete.finish() }
    var doneOnly = SIWCStream()
    for byte in "data: [DONE]\n\n".utf8 { try doneOnly.byte(byte) }
    #expect(throws: SIWCError.incompleteStream) { try doneOnly.finish() }
}

@Test func sseDiagnosticCategoriesDoNotNeedRawPayloads() throws {
    var invalid = SIWCStream()
    #expect(throws: SIWCError.sseInvalidJSON) {
        for byte in "data: {not-json}\n\n".utf8 { try invalid.byte(byte) }
    }
    var missing = SIWCStream()
    #expect(throws: SIWCError.sseMissingType) {
        for byte in "data: {}\n\n".utf8 { try missing.byte(byte) }
    }
    var utf8 = SIWCStream()
    #expect(throws: SIWCError.sseInvalidUTF8) {
        for byte: UInt8 in [0xff, 10] { try utf8.byte(byte) }
    }
}

@Test func missingContentTypeStillRequiresValidCompletedSSE() throws {
    #expect(SIWCStream.acceptsContentType(nil))
    #expect(SIWCStream.acceptsContentType("text/event-stream; charset=utf-8"))
    #expect(!SIWCStream.acceptsContentType("application/json"))
    var parser = SIWCStream()
    for byte in (#"data: {"type":"response.output_text.delta","delta":"red square; GLANCE 123"}"# + "\n\n" + #"data: {"type":"response.completed"}"# + "\n\n").utf8 { try parser.byte(byte) }
    #expect(try parser.finish() == "red square; GLANCE 123")
    var json = SIWCStream()
    for byte in #"{"status":"completed"}"#.utf8 { try json.byte(byte) }
    #expect(throws: SIWCError.incompleteStream) { try json.finish() }
}

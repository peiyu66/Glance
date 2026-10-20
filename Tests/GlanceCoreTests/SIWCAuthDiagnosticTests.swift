import Foundation
import Testing
@testable import GlanceCore

private func attempt() -> SIWCPending {
    SIWCPending(state: "state-private", nonce: "nonce-private", verifier: "verifier-private", port: 54321, clientID: nil, deadline: Date(timeIntervalSince1970: 2000))
}
@Test func authCallbackClassificationPreservesValidation() throws {
    var p = attempt(); var details: [SIWCCallbackDiagnostic] = []
    let now = Date(timeIntervalSince1970: 1000)
    #expect(throws: SIWCError.invalidCallback) { try p.callback(target: "/auth/callback?state=wrong&code=secret&client_id=private-client", now: now, diagnostic: { details.append($0) }) }
    #expect(details.last?.category == .callbackState)
    #expect(throws: SIWCError.invalidCallback) { try p.callback(target: "/other?state=state-private", now: now, diagnostic: { details.append($0) }) }
    #expect(details.last?.category == .callbackShape)
    let result = try p.callback(target: "/auth/callback?state=state-private&code=secret&client_id=private-client", now: now, diagnostic: { details.append($0) })
    #expect(result.clientID == "private-client"); #expect(details.last?.accepted == true)
    #expect(throws: SIWCError.invalidCallback) { try p.callback(target: "/auth/callback?state=state-private&code=secret&client_id=private-client", now: now, diagnostic: { details.append($0) }) }
    #expect(details.last?.category == .callbackConsumed)
}
@Test func authCallbackErrorDoesNotImplyUserCancellation() throws {
    for (code,category) in [("access_denied",SIWCAuthCategory.oauthDenied),("3p_login_workspace_scope_denied",.oauthError),("private@example.invalid",.oauthError)] {
        var p = attempt(); var d: SIWCCallbackDiagnostic?
        #expect(throws: SIWCError.denied) { try p.callback(target: "/auth/callback?state=state-private&error=" + code, now: Date(timeIntervalSince1970:1000), diagnostic: { d = $0 }) }
        #expect(d?.category == category)
        #expect(d?.errorCode == (code.contains("@") ? "unrecognized_error_code" : code))
    }
}
@Test func authCallbackExpiryMissingCodeAndClient() throws {
    var p = attempt(); var d: SIWCCallbackDiagnostic?
    #expect(throws: SIWCError.invalidCallback) { try p.callback(target: "/auth/callback?state=state-private", now:Date(timeIntervalSince1970:2001),diagnostic:{d=$0}) }
    #expect(d?.category == .callbackExpired)
    #expect(throws: SIWCError.invalidCallback) { try p.callback(target: "/auth/callback?state=state-private&code=secret", now:Date(timeIntervalSince1970:1000),diagnostic:{d=$0}) }
    #expect(d?.category == .callbackClient)
    #expect(throws: SIWCError.invalidCallback) { try p.callback(target: "/auth/callback?state=state-private&client_id=client", now:Date(timeIntervalSince1970:1000),diagnostic:{d=$0}) }
    #expect(d?.category == .callbackMissingCode)
}
@Test func authHTTP404AndTransportRemainDistinct() {
    var trace = SIWCAuthDiagnostic(); trace.begin()
    trace.record(stage:.tokenExchange,outcome:.failed,category:.http,httpStatus:404)
    trace.record(stage:.browser,outcome:.failed,category:.transport,numericCode:-1004)
    #expect(trace.events[0].text.contains("HTTP 404"))
    #expect(trace.events[1].httpStatus == nil)
    #expect(trace.events[1].category == .transport)
}
@Test func authHistoryHasBoundedOrderedAttempts() throws {
    var trace = SIWCAuthDiagnostic()
    for _ in 0..<10 { trace.begin(); for _ in 0..<12 { trace.record(stage:.browser,outcome:.started) } }
    #expect(trace.events.count == 64)
    #expect(trace.events.last?.id == 120); #expect(trace.events.last?.attempt == 10)
    let restored = try JSONDecoder().decode(SIWCAuthDiagnostic.self,from:JSONEncoder().encode(trace))
    #expect(restored.events.count == 64); #expect(restored.attempt == 10)
}
@Test func authOnlyAllowlistedErrorValuesAreSerialized() throws {
    var trace = SIWCAuthDiagnostic();trace.begin()
    for secret in ["private@example.invalid","Bearer fake-secret","https://example.invalid/?code=private","cookie=private","eyJhbGciOi.test.signature"] {
        trace.record(stage:.tokenExchange,outcome:.failed,category:.http,httpStatus:404,errorCode:secret)
    }
    trace.record(stage:.browser,outcome:.failed,httpStatus:999,errorCode:"3p_login_workspace_scope_denied")
    let text=String(decoding:try JSONEncoder().encode(trace),as:UTF8.self)
    for secret in ["private@example.invalid","fake-secret","example.invalid","cookie=","eyJhbGciOi"] { #expect(!text.contains(secret)) }
    #expect(trace.events.last?.httpStatus == nil)
    #expect(trace.events.last?.errorCode == "3p_login_workspace_scope_denied")
}
@Test func authSuccessAndDisabledPlanRemainSeparate() {
    var trace=SIWCAuthDiagnostic();trace.begin()
    trace.record(stage:.identity,outcome:.succeeded)
    trace.record(stage:.permission,outcome:.succeeded,category:.planDisabled)
    #expect(trace.events.last?.text.contains("未授予方案權限") == true)
    #expect(trace.events.allSatisfy { $0.outcome == .succeeded })
}

@Test func serviceRequestIDsAreStrictlyAllowlisted() throws {
    let safe = "req_0123456789abcdef0123456789abcdef"
    for value in [safe, "9175C24C-DA33-40DB-85B1-044E9317E483"] {
        #expect(SIWCServiceDiagnostic.safeRequestID(value) == value)
    }
    for value in ["Bearer fake-token", "private@example.invalid", "req_secret", "https://auth.openai.com/?code=secret", safe + "\n", "eyJhbGciOi.test.signature"] {
        let service = SIWCServiceDiagnostic(endpoint: .token, status: 400, rawRequestID: value)
        #expect(service.requestID == nil && service.requestIDState == .omittedUnrecognized)
        #expect(!String(decoding: try JSONEncoder().encode(service), as: UTF8.self).contains(value))
    }
    #expect(SIWCServiceDiagnostic(endpoint: .token, status: 400, rawRequestID: nil).requestIDState == .absent)
}

@Test func codeObservationIsBoundedAndStartsUnknownAcrossControllerLifetimes() {
    var first = SIWCAuthCodeObservation()
    #expect(!first.observe("generated-A").previouslySubmitted)
    #expect(first.observe("generated-A").previouslySubmitted)
    #expect(!first.observe("generated-B").previouslySubmitted)
    for i in 0..<64 { _ = first.observe("generated-\(i)") }
    let evicted = first.observe("generated-A")
    #expect(!evicted.previouslySubmitted && evicted.comparedCount == 64)
    var next = SIWCAuthCodeObservation()
    #expect(!next.observe("generated-A").previouslySubmitted)
}

@Test func D2KeepsOldEventsReadableAndValidationSeparateFromFailedLogin() throws {
    var trace = SIWCAuthDiagnostic(); trace.begin()
    let id = UUID()
    trace.record(stage: .tokenExchange, outcome: .failed, category: .http, httpStatus: 400,
                 errorCode: "invalid_grant", traceID: id, elapsedMilliseconds: 123,
                 service: .init(endpoint: .token, status: 400, rawRequestID: "req_0123456789abcdef0123456789abcdef"))
    var validation = SIWCValidationEvidence(operationID: UUID())
    validation.candidateListed = false; validation.visibleModelCount = 3
    trace.record(stage: .modelCatalog, outcome: .succeeded, validation: validation)
    #expect(trace.events.last?.traceID == nil)
    #expect(trace.events.last?.validation?.sessionAuthenticationTraceID == nil)
    #expect(trace.events.last?.validation?.candidateListed == false)
    var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(trace)) as? [String: Any])
    old["events"] = try #require(old["events"] as? [[String: Any]]).map { event in
        var event = event
        for key in ["traceID", "elapsedMilliseconds", "service", "validation"] { event.removeValue(forKey: key) }
        return event
    }
    let restored = try JSONDecoder().decode(SIWCAuthDiagnostic.self, from: JSONSerialization.data(withJSONObject: old))
    #expect(restored.events.count == 2 && restored.events.allSatisfy { $0.traceID == nil && $0.service == nil })
}

@Test func latestSignInResultSurvivesOtherAccountValidationAndHistoryEviction() throws {
    var diagnostic = SIWCAuthDiagnostic(); let trace = UUID()
    diagnostic.begin(traceID: trace)
    diagnostic.record(stage: .tokenExchange, outcome: .failed, category: .http, httpStatus: 400, errorCode: "invalid_grant", traceID: trace)
    for _ in 0..<70 { diagnostic.record(stage: .syntheticImage, outcome: .succeeded) }
    let loaded = try JSONDecoder().decode(SIWCAuthDiagnostic.self, from: JSONEncoder().encode(diagnostic))
    #expect(loaded.latestSignIn?.outcome == .failed)
    #expect(loaded.signInResultText.contains("失敗"))
    #expect(loaded.latestSignIn?.failure?.errorCode == "invalid_grant")
    #expect(loaded.latestSignIn?.failure?.httpStatus == 400)
    #expect(loaded.latestSignInEvents.isEmpty)
}
@Test func newAttemptCannotInheritPreviousSuccessfulValidation() {
    var diagnostic = SIWCAuthDiagnostic(); let old = UUID(), new = UUID()
    diagnostic.begin(traceID: old)
    diagnostic.record(stage: .permission, outcome: .succeeded, category: .planEnabled, traceID: old)
    var evidence = SIWCValidationEvidence(operationID: UUID()); evidence.sessionAuthenticationTraceID = old
    diagnostic.record(stage: .syntheticImage, outcome: .succeeded, validation: evidence)
    diagnostic.begin(traceID: new)
    diagnostic.record(stage: .browser, outcome: .cancelled, category: .userCancelled, traceID: new)
    #expect(diagnostic.latestSignIn?.outcome == .cancelled)
    #expect(diagnostic.latestSignInEvents.count == 1)
    #expect(diagnostic.latestSignInEvents.allSatisfy { $0.stage != .syntheticImage })
}

private func descriptionResponse(_ fields: [String: Any]) throws -> SIWCErrorDescriptionDiagnostic {
    .tokenResponse(try JSONSerialization.data(withJSONObject: fields))
}
@Test func errorDescriptionSeparatesAbsentEmptyAndSafeContent() throws {
    let absent = try descriptionResponse(["error": "invalid_grant"])
    #expect(absent.version == 1 && absent.state == .absent && absent.reason == nil)
    for value in ["", " \t\n"] {
        #expect(try descriptionResponse(["error_description": value]).state == .presentEmpty)
    }
    for message in SIWCErrorDescriptionDiagnostic.SafeMessage.allCases {
        let diagnostic = try descriptionResponse(["error_description": " \n" + message.text.uppercased() + "\t"])
        #expect(diagnostic.state == .presentSanitized && diagnostic.safeMessage == message && diagnostic.reason == nil)
        #expect(diagnostic.text.contains(message.text))
    }
    let nested = try descriptionResponse(["error": ["code": "invalid_grant", "error_description": "Invalid grant"]])
    #expect(nested.safeMessage == .invalidGrant)
}
@Test func errorDescriptionMalformedResponsesNeverBecomeAbsent() throws {
    for data in [Data(), Data("{".utf8), Data("<html>temporary error</html>".utf8)] {
        let diagnostic = SIWCErrorDescriptionDiagnostic.tokenResponse(data)
        #expect(diagnostic.state == .unreadable && diagnostic.reason == .invalidJSON)
    }
    for data in [Data("[]".utf8), Data("null".utf8), Data("true".utf8), Data(#""description""#.utf8)] {
        #expect(SIWCErrorDescriptionDiagnostic.tokenResponse(data).reason == .nonObjectJSON)
    }
    for value: Any in [NSNull(), 1, false, [], ["message": "Invalid grant"]] {
        let diagnostic = try descriptionResponse(["error_description": value])
        #expect(diagnostic.state == .unreadable && diagnostic.reason == .invalidType)
    }
    let ambiguous = try descriptionResponse(["error_description": "Invalid grant", "error": ["error_description": "Access denied"]])
    #expect(ambiguous.state == .unreadable && ambiguous.reason == .ambiguousFields)
    #expect(SIWCErrorDescriptionDiagnostic.tokenResponse(Data(repeating: 32, count: 65_537)).reason == .bodyTooLarge)
}
@Test func errorDescriptionUnknownAndSensitiveValuesCannotReachEncodedDiagnostics() throws {
    let values = ["private@example.invalid", "Bearer generated-private-token", "https://example.invalid/?code=private",
                  "cookie=private", "eyJhbGciOi.generated.signature", "Invalid grant: private@example.invalid",
                  "Access denied; secret=generated-private", "Invalid grant additional text", "任意錯誤說明",
                  String(repeating: "s", count: 513), String(repeating: "密", count: 400)]
    var diagnostic = SIWCAuthDiagnostic(); let trace = UUID(); diagnostic.begin(traceID: trace)
    for raw in values {
        let detail = try descriptionResponse(["error_description": raw, "access_token": "generated-never-store"])
        #expect(detail.state == .presentSuppressed && detail.safeMessage == nil)
        diagnostic.record(stage: .tokenExchange, outcome: .failed, category: .http, traceID: trace, errorDescription: detail)
    }
    let encoded = String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self)
    for raw in values + ["generated-never-store"] { #expect(!encoded.contains(raw)) }
    #expect(diagnostic.events[0].errorDescription?.reason == .sensitiveContent)
    #expect(diagnostic.events[7].errorDescription?.reason == .unrecognizedText)
    #expect(diagnostic.events.last?.errorDescription?.reason == .descriptionTooLong)
}
@Test func errorDescriptionLegacyRecordAndLatestFailureStayDistinctAfterEviction() throws {
    var diagnostic = SIWCAuthDiagnostic(); let trace = UUID(); diagnostic.begin(traceID: trace)
    diagnostic.record(stage: .tokenExchange, outcome: .failed, category: .http, traceID: trace,
                      errorDescription: try descriptionResponse(["error_description": "Invalid grant"]))
    var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(diagnostic)) as? [String: Any])
    old["events"] = try #require(old["events"] as? [[String: Any]]).map { event in
        var event = event; event.removeValue(forKey: "errorDescription"); return event
    }
    var signIn = try #require(old["latestSignIn"] as? [String: Any])
    var failure = try #require(signIn["failure"] as? [String: Any])
    failure.removeValue(forKey: "errorDescription"); signIn["failure"] = failure; old["latestSignIn"] = signIn
    let loadedOld = try JSONDecoder().decode(SIWCAuthDiagnostic.self, from: JSONSerialization.data(withJSONObject: old))
    #expect(loadedOld.events[0].errorDescription == nil)
    #expect(loadedOld.events[0].errorDescriptionDiagnostic?.state == .legacyNotRecorded)
    #expect(loadedOld.latestSignIn?.failure?.errorDescriptionDiagnostic?.state == .legacyNotRecorded)
    #expect(loadedOld.events[0].text.contains("服務是否提供未知"))
    for _ in 0..<70 { diagnostic.record(stage: .syntheticImage, outcome: .succeeded) }
    let loadedNew = try JSONDecoder().decode(SIWCAuthDiagnostic.self, from: JSONEncoder().encode(diagnostic))
    #expect(loadedNew.events.count == 64 && loadedNew.events.allSatisfy { $0.errorDescriptionDiagnostic == nil })
    #expect(loadedNew.latestSignIn?.failure?.errorDescription?.safeMessage == .invalidGrant)
}
@Test func errorDescriptionCallbackRequiresValidStateAndUniqueFields() throws {
    let cases: [(String, SIWCErrorDescriptionDiagnostic.State, SIWCErrorDescriptionDiagnostic.Reason?)] = [
        ("", .absent, nil), ("&error_description=", .presentEmpty, nil),
        ("&error_description=Access+denied", .presentSanitized, nil),
        ("&error_description=private%40example.invalid", .presentSuppressed, .sensitiveContent),
        ("&error_description", .unreadable, .invalidType)
    ]
    for (suffix, state, reason) in cases {
        var p = attempt(); var detail: SIWCCallbackDiagnostic?
        #expect(throws: SIWCError.denied) {
            try p.callback(target: "/auth/callback?state=state-private&error=access_denied" + suffix,
                           now: Date(timeIntervalSince1970: 1000), diagnostic: { detail = $0 })
        }
        #expect(detail?.errorDescription?.state == state && detail?.errorDescription?.reason == reason)
    }
    for target in ["/auth/callback?state=wrong&error=access_denied&error_description=Access+denied",
                   "/auth/callback?state=state-private&error=access_denied&error_description=one&error_description=two"] {
        var p = attempt(); var detail: SIWCCallbackDiagnostic?
        #expect(throws: SIWCError.invalidCallback) {
            try p.callback(target: target, now: Date(timeIntervalSince1970: 1000), diagnostic: { detail = $0 })
        }
        #expect(detail?.category == .callbackState && detail?.errorDescription == nil)
    }
}

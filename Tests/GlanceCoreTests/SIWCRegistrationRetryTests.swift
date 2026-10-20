import Foundation
import Testing
@testable import GlanceCore

@Test func registrationRetryRequiresFirstInvalidGrant() {
    for code: String? in [nil, "invalid_client", "access_denied", "server_error"] {
        var value = SIWCRegistrationRetry()
        let transition1 = !value.recordExchangeFailure(errorCode: code, exchangeOrdinal: 1)
        #expect(transition1)
        #expect(value.state == .awaitingExchange)
        let transition2 = !value.consume(confirmedSameAccountAndWorkspace: true)
        #expect(transition2)
    }
    for ordinal in [0, 2, 3] {
        var value = SIWCRegistrationRetry()
        let transition3 = !value.recordExchangeFailure(errorCode: "invalid_grant", exchangeOrdinal: ordinal)
        #expect(transition3)
    }
}

@Test func registrationRetryConsumesOnlyOnceWithExplicitConfirmation() throws {
    var value = SIWCRegistrationRetry()
    let transition4 = value.recordExchangeFailure(errorCode: "invalid_grant", exchangeOrdinal: 1)
    #expect(transition4)
    let transition5 = !value.consume(confirmedSameAccountAndWorkspace: false)
    #expect(transition5)
    #expect(value.state == .available)
    let available = try JSONDecoder().decode(SIWCRegistrationRetry.self, from: JSONEncoder().encode(value))
    #expect(available.state == .available)
    let transition6 = value.consume(confirmedSameAccountAndWorkspace: true)
    #expect(transition6)
    var restored = try JSONDecoder().decode(SIWCRegistrationRetry.self, from: JSONEncoder().encode(value))
    #expect(restored.state == .consumed)
    let transition7 = !restored.consume(confirmedSameAccountAndWorkspace: true)
    #expect(transition7)
    let transition8 = !restored.recordExchangeFailure(errorCode: "invalid_grant", exchangeOrdinal: 1)
    #expect(transition8)
}

@Test func registrationRetryUnknownOrMissingStateFailsClosed() {
    for raw in [#"{}"#, #"{"state":"retry_forever"}"#, #"{"state":null}"#] {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SIWCRegistrationRetry.self, from: Data(raw.utf8))
        }
    }
}

@Test func recoveryUsesFreshSecretsAndStableRegistration() throws {
    let first = try SIWCPending.fresh(port: 41001, clientID: nil)
    let retry = try SIWCPending.fresh(port: 41002, clientID: "synthetic-issued-client")
    #expect(first.state != retry.state && first.nonce != retry.nonce && first.verifier != retry.verifier)
    let fields = Dictionary(uniqueKeysWithValues: URLComponents(url: retry.authorize(hostID: "synthetic-host"), resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
    #expect(fields["client_id"] == "synthetic-issued-client")
    #expect(fields["ext_agent_host_id"] == "synthetic-host")
    #expect(fields["id_token_hint"] == nil && fields["agent_name_hint"] == nil)
    #expect(fields["code_challenge"] == SIWCProtocol.challenge(retry.verifier))
    #expect(fields["redirect_uri"] == retry.redirect && retry.redirect != first.redirect)
}

@Test func retryCallbackRequiresBoundClientAndNewStateAndConsumesReturn() throws {
    let original = try SIWCPending.fresh(port: 41003, clientID: "synthetic-client")
    var pending = original
    #expect(throws: SIWCError.self) { try pending.callback(target: "/auth/callback?state=stale&code=new") }
    #expect(throws: SIWCError.self) { try pending.callback(target: "/auth/callback?state=\(pending.state)&client_id=other&code=new") }
    let accepted = try pending.callback(target: "/auth/callback?state=\(pending.state)&code=new")
    #expect(accepted.clientID == original.clientID && accepted.code == "new")
    #expect(throws: SIWCError.self) { try pending.callback(target: "/auth/callback?state=\(pending.state)&code=another") }
}

@Test func retryDiagnosticsRemainOptionalAndDescribeAttestation() throws {
    let old = try JSONDecoder().decode(SIWCAuthBindingChecks.self, from: Data(#"{"clientSource":"newRegistration"}"#.utf8))
    #expect(old.retryAvailable == nil && old.sameAccountWorkspaceConfirmedByUser == nil)
    var checks = SIWCAuthBindingChecks()
    checks.clientSource = .retainedRetry; checks.retryBudgetConsumed = true
    checks.retryStatePersisted = true; checks.sameAccountWorkspaceConfirmedByUser = true
    #expect(checks.text.contains("非服務端驗證"))
    let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(checks)) as? [String: Any])
    #expect(Set(json.keys) == ["clientSource", "retryBudgetConsumed", "retryStatePersisted", "sameAccountWorkspaceConfirmedByUser"])
}

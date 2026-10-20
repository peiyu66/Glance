import Foundation
import Testing
@testable import GlanceCore

@Test func consentStartsClosedEvenWithExistingAccount() throws {
    var state = DataConsent(); state.accountChanged(ready: true)
    #expect(!state.allowsTransfer && !state.setupCompleted)
}
@Test func consentAcceptAndLoginAreSeparatePersistedSteps() throws {
    var state = DataConsent(); state.accept(at: Date(timeIntervalSince1970: 100), accountReady: false)
    #expect(state.allowsTransfer && !state.setupCompleted)
    var restored = try JSONDecoder().decode(DataConsent.self, from: JSONEncoder().encode(state))
    restored.accountChanged(ready: true)
    #expect(restored.allowsTransfer && restored.setupCompleted && restored.acceptedAt == state.acceptedAt)
    restored.accountChanged(ready: false)
    #expect(restored.allowsTransfer && !restored.setupCompleted)
}
@Test func consentUpgradeKeepsValidLoginAndWithdrawalClearsPermission() throws {
    var state = DataConsent(); state.accept(accountReady: true)
    #expect(state.setupCompleted)
    state.withdraw()
    let restored = try JSONDecoder().decode(DataConsent.self, from: JSONEncoder().encode(state))
    #expect(!restored.allowsTransfer && !restored.setupCompleted && restored.acceptedAt == nil)
}
@Test(arguments: ["2026-10-01.1", "", "future-version"])
func consentChangedVersionRequiresNewExplicitAcceptance(version: String) throws {
    var state = DataConsent(); state.accept(accountReady: true)
    var root = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
    root["acceptedVersion"] = version
    let restored = try JSONDecoder().decode(DataConsent.self, from: JSONSerialization.data(withJSONObject: root))
    #expect(!restored.allowsTransfer)
}

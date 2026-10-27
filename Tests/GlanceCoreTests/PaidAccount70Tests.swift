import Foundation
import Testing
@testable import GlanceCore

@Test func paid70CredentialFailureStatesProductRequirementWithoutTierDetection() {
    let message = SIWCSignInMessage.failure(stage: .tokenExchange, category: .http, httpStatus: 400, errorCode: "invalid_grant")
    #expect(message.contains("憑證交換未完成")); #expect(message.contains("確認目前登入的帳戶"))
    #expect(message.contains(SIWCSignInMessage.requirement)); #expect(message.contains("invalid_grant"))
    #expect(!message.contains("偵測到")); #expect(!message.contains("你的帳戶是免費"))
}
@Test func paid70MissingScopeStatesRequirementWithoutClaimingSubscriptionTier() {
    let message = SIWCSignInMessage.failure(stage: .permission, category: .planDisabled)
    #expect(message.contains("未取得方案使用權限")); #expect(message.contains(SIWCSignInMessage.requirement))
}
@Test func paid70NetworkAndServerErrorsKeepTheirOwnCause() {
    let network = SIWCSignInMessage.failure(stage: .tokenExchange, category: .transport)
    let server = SIWCSignInMessage.failure(stage: .tokenExchange, category: .http, httpStatus: 503, errorCode: "server_error")
    #expect(network.hasPrefix("登入連線未完成")); #expect(!network.contains("HTTP"))
    #expect(server.hasPrefix("官方登入服務暫時")); #expect(server.contains("HTTP 503"))
    #expect(network.contains("使用要求：")); #expect(server.contains("使用要求："))
}
@Test func paid70CancellationExpiryAndRepeatedCallbackAreNotPlanFailures() {
    for category in [SIWCAuthCategory.userCancelled, .timeout, .callbackExpired, .callbackConsumed, .repeatedReturn] {
        let message = SIWCSignInMessage.failure(stage: .callback, category: category)
        #expect(!message.contains("免費")); #expect(!message.contains("付費"))
    }
}
@Test func paid70DiscoveryFailureDoesNotMislabelCredentialsOrFree() {
    let message = SIWCSignInMessage.failure(stage: .discovery, category: .http, httpStatus: 503)
    #expect(message.contains("HTTP 503")); #expect(!message.contains("憑證交換")); #expect(!message.contains("免費"))
}
@Test func paid70RawErrorTextDoesNotEnterUserMessage() {
    let message = SIWCSignInMessage.failure(stage: .tokenExchange, category: .http, httpStatus: 400, errorCode: "secret@example.invalid token=synthetic")
    #expect(!message.contains("secret@example")); #expect(!message.contains("token="))
}
@Test func paid70CleanupOnlyDeletesKnownRegularDiagnosticFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in SIWCLegacyDiagnosticCleanup.filenames { try Data("synthetic".utf8).write(to: root.appendingPathComponent(name)) }
    for name in ["record.json", "model-responses.json", "image.jpg", "unrelated.json"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
    #expect(SIWCLegacyDiagnosticCleanup.removeKnownFiles(in: root) == SIWCLegacyDiagnosticCleanup.filenames.count)
    #expect(SIWCLegacyDiagnosticCleanup.removeKnownFiles(in: root) == 0)
    for name in ["record.json", "model-responses.json", "image.jpg", "unrelated.json"] {
        #expect(try Data(contentsOf: root.appendingPathComponent(name)) == Data(name.utf8))
    }
}
@Test func paid70CleanupDoesNotFollowSymlinksOrDeleteDirectories() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("keep.json"); try Data("keep".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("siwc-status.json"), withDestinationURL: target)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("siwc-auth-diagnostic.json"), withIntermediateDirectories: true)
    #expect(SIWCLegacyDiagnosticCleanup.removeKnownFiles(in: root) == 0)
    #expect(try Data(contentsOf: target) == Data("keep".utf8))
}

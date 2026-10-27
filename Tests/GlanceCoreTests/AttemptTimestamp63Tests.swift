import Foundation
import Testing
@testable import GlanceCore

private let attempt63Start = Date(timeIntervalSince1970: 1_792_479_900)
private let attempt63Locale = Locale(identifier: "en_GB")
private let attempt63Zone = TimeZone(secondsFromGMT: 0)!

@Test(arguments: [true, false])
func attempt63StartSurvivesCompletionFailureAndReload(success: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID(), attempt = UUID()
    let captured = attempt63Start.addingTimeInterval(-172_800), image = Data([6, 3, 0, 1])
    _ = try await archive.create(id: id, jpeg: image, capturedAt: captured, imageSource: .photoLibrary)
    let original = try await archive.complete(id: id, result: .init(names: ["原成功結果"]), message: nil)
    #expect(original.attemptNumber == 1 && original.retryAttemptSummary() == nil)
    let pending = try await archive.beginRetry(id: id, attemptID: attempt, at: attempt63Start)
    let summary = try #require(pending.retryAttemptSummary(locale: attempt63Locale, timeZone: attempt63Zone))
    #expect(summary.hasPrefix("本圖第 2 次辨識・"))
    #expect(pending.displayRecord.attemptNumber == 1)
    #expect(pending.attempts?.last?.startedAt == attempt63Start)
    let live = try #require(try await archive.load(liveAttemptIDs: [attempt]).records.first)
    #expect(live.retryAttemptSummary(locale: attempt63Locale, timeZone: attempt63Zone) == summary)
    let completed = try await archive.complete(id: id, result: success ? .init(names: ["新成功結果"]) : nil,
        message: success ? nil : "合成失敗", at: attempt63Start.addingTimeInterval(7_200), attemptID: attempt)
    let reopened = try #require(try await RecognitionArchive(root: root).load().records.first)
    #expect(reopened == completed && reopened.attempts?.last?.startedAt == attempt63Start)
    #expect(reopened.retryAttemptSummary(locale: attempt63Locale, timeZone: attempt63Zone) == summary)
    #expect(reopened.capturedAt == captured && reopened.source == .photoLibrary)
    #expect(reopened.captureTimestamp() == original.captureTimestamp())
    #expect(try await archive.image(for: reopened) == image)
    if !success { #expect(reopened.displayRecord.result == original.result) }
}

@Test func attempt63ColdPendingRecoveryKeepsStartAndNextExplicitRetryChangesIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID()
    _ = try await archive.create(id: id, jpeg: Data([6, 3]), capturedAt: attempt63Start.addingTimeInterval(-86400))
    _ = try await archive.complete(id: id, result: nil, message: "第一次失敗")
    _ = try await archive.beginRetry(id: id, attemptID: UUID(), at: attempt63Start)
    let rebooted = RecognitionArchive(root: root)
    let interrupted = try #require(try await rebooted.load().records.first)
    #expect(interrupted.status == .interrupted && interrupted.attempts?.last?.startedAt == attempt63Start)
    let nextDate = attempt63Start.addingTimeInterval(86400)
    let next = try await rebooted.beginRetry(id: id, attemptID: UUID(), at: nextDate)
    #expect(next.attemptNumber == 3 && next.attempts?.last?.startedAt == nextDate)
    #expect(next.retryAttemptSummary()?.hasPrefix("本圖第 3 次辨識・") == true)
    #expect(next.capturedAt == interrupted.capturedAt)
    #expect(next.retryAttemptSummary() != interrupted.retryAttemptSummary())
}

@Test func attempt63MissingLegacyDateKeepsAttemptIdentityWithoutInventingTime() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID(), attempt = UUID()
    _ = try await archive.create(id: id, jpeg: Data([6, 3]), capturedAt: attempt63Start)
    _ = try await archive.complete(id: id, result: nil, message: "第一次失敗")
    _ = try await archive.beginRetry(id: id, attemptID: attempt, at: attempt63Start)
    _ = try await archive.complete(id: id, result: nil, message: "第二次失敗", attemptID: attempt)
    let file = root.appendingPathComponent(id.uuidString).appendingPathComponent("record.json")
    var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    var attempts = try #require(json["attempts"] as? [[String: Any]])
    attempts[1].removeValue(forKey: "startedAt")
    json["attempts"] = attempts
    try JSONSerialization.data(withJSONObject: json).write(to: file)
    let reopened = try #require(try await RecognitionArchive(root: root).load().records.first)
    #expect(reopened.currentAttemptID == attempt && reopened.attemptNumber == 2)
    #expect(reopened.attempts?.last?.startedAt == nil)
    #expect(reopened.retryAttemptSummary() == "本圖第 2 次辨識")
    let encoded = try JSONEncoder().encode(reopened)
    #expect(try JSONDecoder().decode(ArchivedRecognition.self, from: encoded).retryAttemptSummary() == "本圖第 2 次辨識")
    json.removeValue(forKey: "attempts")
    try JSONSerialization.data(withJSONObject: json).write(to: file)
    let legacy = try #require(try await RecognitionArchive(root: root).load().records.first)
    #expect(legacy.attempts == nil && legacy.retryAttemptSummary() == nil)
    let explicitRetry = try await archive.beginRetry(id: id, attemptID: UUID(), at: attempt63Start.addingTimeInterval(3600))
    #expect(explicitRetry.attempts?.first?.startedAt == nil)
    #expect(explicitRetry.attempts?.last?.startedAt == attempt63Start.addingTimeInterval(3600))
}

@Test func attempt63FormattingUsesRequestedLocalDateTimeInsteadOfCaptureOrCompletion() throws {
    let date = try #require(ISO8601DateFormatter().date(from: "2026-10-20T01:05:00Z"))
    let id = UUID()
    var record = ArchivedRecognition(schemaVersion: 1, id: id, sequence: 1, capturedAt: date.addingTimeInterval(-86400),
        imageSHA256: "hash", imageByteCount: 1, status: .failed, result: nil, message: nil, completedAt: date.addingTimeInterval(3600))
    record.attempts = [.init(id: id, startedAt: nil, outcome: .failed), .init(id: UUID(), startedAt: date, outcome: .failed)]
    let plusEight = try #require(record.retryAttemptSummary(locale: attempt63Locale, timeZone: TimeZone(secondsFromGMT: 8 * 3600)!))
    let minusSeven = try #require(record.retryAttemptSummary(locale: attempt63Locale, timeZone: TimeZone(secondsFromGMT: -7 * 3600)!))
    #expect(plusEight.contains("20/10/2026") && plusEight.contains("09:05"))
    #expect(minusSeven.contains("19/10/2026") && minusSeven.contains("18:05"))
    let local = try #require(record.retryAttemptSummary(locale: Locale(identifier: "zh_TW"), timeZone: attempt63Zone))
    #expect(local.contains("2026/10/20") && local != plusEight)
}

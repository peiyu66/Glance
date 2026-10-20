import Foundation
import Testing
@testable import GlanceCore

private func json45Record(_ raw: String? = nil, status: ArchivedRecognition.Status = .succeeded) -> ArchivedRecognition {
    let id = UUID()
    var record = ArchivedRecognition(schemaVersion: 1, id: id, sequence: 12, capturedAt: Date(), imageSHA256: "private-image-hash", imageByteCount: 3,
        status: status, result: .init(names: ["程式解析結果，不是原始回覆"]), message: nil, completedAt: Date())
    if let raw { record.modelResponses = [.capture(raw, sourceImageID: id, attemptID: id, appVersion: "0.1.0", appBuild: "45")] }
    return record
}

@Test func json45RawExportAndFormattingPreserveUnicodeEscapesAndNumberTokens() throws {
    let raw = #" {"names":["摩訶止觀 👩🏽‍🔬 日本語"],"text":["line\nquote\"slash\\","\u4e2d"],"large":9007199254740993,"number":1.00e+09,"duplicate":1,"duplicate":2} "#
    let record = json45Record(raw), document = record.modelJSONDocument
    #expect(document.rawText == raw)
    let pretty = try #require(document.formattedText)
    #expect(pretty.contains("\n") && pretty.contains("摩訶止觀 👩🏽‍🔬 日本語"))
    #expect(pretty.contains("9007199254740993") && pretty.contains("1.00e+09") && pretty.contains(#"\u4e2d"#))
    #expect(pretty.components(separatedBy: "\"duplicate\"").count == 3)
    #expect(try JSONSerialization.jsonObject(with: Data(pretty.utf8)) is [String: Any])
    #expect(!record.shareText().contains("duplicate") && !raw.contains(record.id.uuidString))
    #expect(!raw.contains(record.imageSHA256) && !raw.contains("程式解析結果"))
}

@Test func json45LegacyAndPendingNeverReconstructOrExposeOldAttempt() throws {
    var record = json45Record(#"{"old":true}"#)
    record.attempts = [.init(id: record.id, startedAt: Date(), outcome: .failed), .init(id: UUID(), startedAt: Date(), outcome: .pending)]
    record.status = .pending
    #expect(record.modelJSONDocument.rawText == nil && record.modelJSONDocument.message.contains("尚未完成"))
    record.status = .failed
    #expect(record.modelJSONDocument.rawText == nil && record.modelJSONDocument.message.contains("未保存"))
    let legacy = json45Record()
    #expect(legacy.modelJSONDocument.rawText == nil && legacy.modelJSONDocument.message.contains("無法從解析結果還原"))
}

@Test func json45CurrentAttemptAndImageBindingAreRequired() throws {
    var record = json45Record(#"{"old":true}"#)
    let attempt = UUID()
    record.attempts = [.init(id: attempt, startedAt: Date(), outcome: .succeeded)]
    record.modelResponses?.append(.capture(#"{"wrongImage":true}"#, sourceImageID: UUID(), attemptID: attempt, appVersion: "0.1", appBuild: "45"))
    #expect(record.modelJSONDocument.rawText == nil)
    let latest = #"{"current":true}"#
    let currentID = record.id
    record.modelResponses?.append(.capture(latest, sourceImageID: currentID, attemptID: attempt, appVersion: "0.1", appBuild: "45"))
    #expect(record.modelJSONDocument.rawText == latest)
    let loaded = try JSONDecoder().decode(ArchivedRecognition.self, from: JSONEncoder().encode(record))
    #expect(loaded.modelJSONDocument.rawText == latest)
}

@Test func json45FailedMalformedResponseIsPreservedWithoutPretendingToBeJSON() {
    let raw = "{broken 原始 👩🏽‍🔬", document = json45Record(raw, status: .failed).modelJSONDocument
    #expect(document.rawText == raw && document.formattedText == raw)
    #expect(document.message.contains("不是有效 JSON"))
}

@Test func json45OversizeAndInvalidHashHaveNoExport() throws {
    let large = json45Record(String(repeating: "x", count: 32769))
    #expect(large.modelJSONDocument.rawText == nil && large.modelJSONDocument.message.contains("超過保存上限"))
    var record = json45Record(#"{"valid":true}"#)
    var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record.modelResponses![0])) as! [String: Any]
    value["rawResponse"] = #"{"changed":true}"#
    record.modelResponses = [try JSONDecoder().decode(RecognitionModelResponse.self, from: JSONSerialization.data(withJSONObject: value))]
    #expect(record.modelJSONDocument.rawText == nil && record.modelJSONDocument.message.contains("完整性檢查"))
}

@Test func json45LongTextDoesNotTruncateAndDoesNotAlterArchive() throws {
    let rows = (1...300).map { "第\($0)行 日本語 繁中 👩🏽‍🔬 \\\"" }
    let raw = String(decoding: try JSONSerialization.data(withJSONObject: ["text": rows], options: [.sortedKeys]), as: UTF8.self)
    #expect(raw.utf8.count < 32768)
    let record = json45Record(raw), before = try JSONEncoder().encode(record)
    let doc = record.modelJSONDocument
    let after = try JSONDecoder().decode(ArchivedRecognition.self, from: before)
    #expect(after == record && doc.rawText == raw && doc.formattedText?.contains("第300行") == true)
    let decoded = try JSONSerialization.jsonObject(with: Data(doc.formattedText!.utf8)) as! [String: [String]]
    #expect(decoded["text"] == rows)
}

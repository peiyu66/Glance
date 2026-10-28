import Foundation
import Testing
@testable import GlanceCore

private let status73Zone = TimeZone(secondsFromGMT: 0)!
private let status73Date = Date(timeIntervalSince1970: 1_793_175_600) // fixed, synthetic
private func status73Record() async throws -> ArchivedRecognition {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID()
    _ = try await archive.create(id: id, jpeg: Data([1]), capturedAt: status73Date)
    let result = RecognitionResult(names: ["曙光旋脆片"], summary: "合成資料", text: ["AURORA"], sourceImageID: id, searchContractVersion: 17,
        searchEntities: [.init(kind: .product, name: "曙光旋脆片", basis: .logo, sourceText: "AURORA")])
    var record = try await archive.complete(id: id, result: result, message: nil, at: status73Date)
    record.semanticReview = .init(recordID: id, attemptID: id, at: status73Date)
    return record
}
private func status73Suffix() -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = status73Zone; f.dateFormat = "yyyy/MM/dd HH:mm"
    return " (" + f.string(from: status73Date) + ")"
}
@Test func status73FirstInterruptionAndRepeatedFailureUseRetryCountExcludingInitialRun() async throws {
    var r = try await status73Record()
    r.semanticReview?.state = .cancelled; r.semanticReview?.runNumber = 1; r.semanticReview?.finishedAt = status73Date
    #expect(r.recognitionStatusSummary(timeZone: status73Zone) == "第 1 次辨識・第二階段已中斷" + status73Suffix())
    r.semanticReview?.state = .failed; r.semanticReview?.runNumber = 2
    #expect(r.recognitionStatusSummary(timeZone: status73Zone) == "第 1 次辨識・第二階段失敗・累計重試 1 次" + status73Suffix())
    r.semanticReview?.runNumber = 6
    #expect(r.recognitionStatusSummary(timeZone: status73Zone).contains("累計重試 5 次"))
    r.semanticReview?.finishedAt = status73Date.addingTimeInterval(60)
    #expect(!r.recognitionStatusSummary(timeZone: status73Zone).hasSuffix(status73Suffix()))
}
@Test(arguments: [RecognitionSemanticReview.State.noMatch, .insufficientEvidence])
func status73CompletedConclusionsHideRetryCountAndUseLastCompletion(_ state: RecognitionSemanticReview.State) async throws {
    var r = try await status73Record()
    r.semanticReview?.state = state; r.semanticReview?.runNumber = 8; r.semanticReview?.finishedAt = status73Date
    r.semanticReview?.answer = .init(decision: state == .noMatch ? .no_match : .insufficient_evidence)
    #expect(r.recognitionStatusSummary(timeZone: status73Zone) == "第 1 次辨識・已完成" + status73Suffix())
    #expect(r.semanticReview?.runNumber == 8) // Display does not mutate diagnostic evidence.
    r.semanticReview?.finishedAt = nil
    #expect(r.recognitionStatusSummary(timeZone: status73Zone) == "第 1 次辨識・已完成")
}
@Test func status73LegacyMissingCounterAndTimeNeverInventsEither() async throws {
    var r = try await status73Record()
    r.semanticReview?.state = .interrupted
    #expect(r.recognitionStatusSummary(timeZone: status73Zone) == "第 1 次辨識・第二階段已中斷")
    r.semanticReview?.runNumber = Int.min
    #expect(!r.recognitionStatusSummary().contains("重試"))
    r.semanticReview = nil
    #expect(r.recognitionStatusSummary() == "第 1 次辨識・第二階段未完成")
}
@Test func status73PendingAndNewImageAttemptDoNotShowPriorCompletion() async throws {
    var r = try await status73Record()
    r.semanticReview?.finishedAt = status73Date; r.semanticReview?.runNumber = 9
    #expect(r.recognitionStatusSummary() == "第 1 次辨識・第二階段正在尋找資料…")
    r.semanticReview?.state = .reviewing
    #expect(r.recognitionStatusSummary() == "第 1 次辨識・第二階段正在核對資料…")
    r.attempts?.append(.init(id: UUID(), startedAt: status73Date, outcome: .pending)); r.status = .pending
    #expect(r.recognitionStatusSummary() == "第 2 次辨識・辨識中…")
    r.status = .failed; r.message = "連線失敗"; r.completedAt = status73Date
    #expect(r.recognitionStatusSummary(timeZone: status73Zone) == "第 2 次辨識・第一階段失敗：連線失敗" + status73Suffix())
    r.completedAt = nil
    #expect(!r.recognitionStatusSummary().contains("("))
}

import Foundation
import Testing
@testable import GlanceCore

private func result62(_ name: String, id: UUID) -> RecognitionResult {
    .init(names: [name], summary: name + "簡介", text: [name], sourceImageID: id,
          searchContractVersion: 17, searchEntities: [.init(kind: .brand, name: name, sourceText: name)])
}
private func raw62(_ name: String, id: UUID, attempt: UUID) -> RecognitionModelResponse {
    .capture("{\"names\":[\"\(name)\"]}", sourceImageID: id, attemptID: attempt, appVersion: "0.1.0", appBuild: "62")
}
private func seed62(_ archive: RecognitionArchive, id: UUID) async throws -> ArchivedRecognition {
    _ = try await archive.create(id: id, jpeg: Data([6,2,0,1]), capturedAt: Date(timeIntervalSince1970: 12345), imageSource: .photoLibrary)
    return try await archive.complete(id: id, result: result62("舊品牌", id: id), message: nil, modelResponse: raw62("舊品牌", id: id, attempt: id))
}
private func attach62(_ archive: RecognitionArchive, record: ArchivedRecognition) async throws -> ArchivedRecognition {
    let run = UUID(), id = record.id
    _ = try await archive.beginSemanticReview(id: id, attemptID: record.currentAttemptID, runID: run, expectedResult: record.result!)
    let quote = "舊品牌是這段合成測試摘錄中的品牌。"
    let source = WikipediaReviewSource(pageID: 6201, title: "舊品牌百科", url: URL(string: "https://zh.wikipedia.org/wiki/OldFixture")!, fetchedAt: Date(), excerpts: [.init(id: "p0", text: quote)])
    _ = try await archive.updateSemanticReview(id: id, attemptID: record.currentAttemptID, runID: run, state: .reviewing, sources: [source])
    let answer = WikipediaReviewAnswer(decision: .selected, sourceID: source.id, relationship: .same_entity, searchName: "舊品牌", summary: "舊百科的合成簡介。", citations: [.init(excerptID: "p0", quote: quote)])
    let raw = RecognitionModelResponse.capture(String(decoding: try JSONEncoder().encode(answer), as: UTF8.self), sourceImageID: id, attemptID: record.currentAttemptID, appVersion: "0.1.0", appBuild: "62", promptRevision: WikipediaSemanticReview.promptRevision)
    return try await archive.updateSemanticReview(id: id, attemptID: record.currentAttemptID, runID: run, state: .succeeded, answer: answer, response: raw)
}

@Test func refresh62RetainsSuccessfulCardAndExactJSONDuringPendingFailureAndRelaunch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID(), attempt = UUID()
    let original = try await attach62(archive, record: seed62(archive, id: id))
    let pending = try await archive.beginRetry(id: id, attemptID: attempt)
    #expect(pending.currentAttemptID == attempt && pending.status == .pending)
    #expect(pending.retainedResultNotice == "重新辨識中，暫時顯示上次辨識結果。")
    #expect(pending.result == nil && pending.semanticReview == nil)
    #expect(pending.presentationResult == original.presentationResult)
    #expect(pending.shareDocument() == original.shareDocument())
    #expect(pending.modelJSONDocument.rawText == original.modelJSONDocument.rawText)
    #expect(pending.semanticJSONDocument?.rawText == original.semanticJSONDocument?.rawText)
    #expect(pending.combinedJSONShareText.contains(id.uuidString) && pending.combinedJSONShareText.contains(attempt.uuidString))
    #expect(pending.canShare && !pending.canRetryImage)
    let failed = try await archive.complete(id: id, result: nil, message: "合成失敗", attemptID: attempt)
    let reopened = try #require(try await RecognitionArchive(root: root).load().records.first)
    #expect(reopened == failed && failed.canRetryImage)
    #expect(reopened.shareDocument() == original.shareDocument())
    #expect(reopened.retainedSuccess?.result == original.result)
    #expect(reopened.capturedAt == original.capturedAt && reopened.source == .photoLibrary)
    #expect(try await archive.image(for: reopened) == Data([6,2,0,1]))
    let next = try await archive.beginRetry(id: id, attemptID: UUID())
    #expect(next.retainedSuccess == failed.retainedSuccess && next.id == id && next.sequence == original.sequence)
}

@Test func refresh62FirstStageSuccessReplacesOldAttemptWithoutOldWikiOrLateCallbackPollution() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID(), next = UUID()
    let old = try await attach62(archive, record: seed62(archive, id: id))
    _ = try await archive.beginRetry(id: id, attemptID: next)
    let late = try await archive.complete(id: id, result: old.result, message: nil, attemptID: id)
    #expect(late.status == .pending && late.currentAttemptID == next)
    await #expect(throws: Error.self) {
        try await archive.updateSemanticReview(id: id, attemptID: id, runID: old.semanticReview!.runID, state: .succeeded, answer: old.semanticReview?.answer)
    }
    let fresh = try await archive.complete(id: id, result: result62("新品牌", id: id), message: nil, attemptID: next, modelResponse: raw62("新品牌", id: id, attempt: next))
    #expect(fresh.retainedSuccess == nil && fresh.semanticReview == nil && fresh.wikipedia == nil)
    #expect(fresh.shareText().contains("新品牌") && !fresh.shareText().contains("OldFixture"))
    #expect(fresh.semanticJSONDocument == nil && fresh.modelJSONDocument.rawText == #"{"names":["新品牌"]}"#)
    let duplicate = try await archive.complete(id: id, result: result62("錯誤晚回", id: id), message: nil, attemptID: next)
    #expect(duplicate == fresh)
    let run = UUID()
    _ = try await archive.beginSemanticReview(id: id, attemptID: next, runID: run, expectedResult: fresh.result!)
    let cancelled = try await archive.updateSemanticReview(id: id, attemptID: next, runID: run, state: .cancelled, stopReason: .backgroundTimeExpired)
    #expect(cancelled.status == .succeeded && cancelled.result == fresh.result)
    #expect(cancelled.currentSemanticReview?.source == nil && !cancelled.shareText().contains("OldFixture"))
    #expect(cancelled.semanticReview?.stopReason == .backgroundTimeExpired)
}

@Test func recovery62PreservesLiveAttemptAndRunButColdLoadRepairsOnlyOrphans() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), pending = UUID(), complete = UUID(), run = UUID()
    _ = try await archive.create(id: pending, jpeg: Data([1]), capturedAt: Date())
    let first = try await seed62(archive, id: complete)
    _ = try await archive.beginSemanticReview(id: complete, attemptID: complete, runID: run, expectedResult: first.result!)
    let live = try await archive.load(liveAttemptIDs: [pending], liveSemanticRunIDs: [run])
    #expect(live.records.first { $0.id == pending }?.status == .pending)
    #expect(live.records.first { $0.id == complete }?.semanticReview?.isPending == true)
    let cold = try await RecognitionArchive(root: root).load()
    let interrupted = try #require(cold.records.first { $0.id == pending })
    #expect(interrupted.status == .interrupted && interrupted.message?.contains("辨識中斷，尚未完成") == true)
    #expect(interrupted.attempts?.last?.stopReason == .processInterrupted)
    let usable = try #require(cold.records.first { $0.id == complete })
    #expect(usable.status == .succeeded && usable.result == first.result)
    #expect(usable.semanticReview?.state == .interrupted && usable.semanticReview?.stopReason == .processInterrupted)
    #expect(usable.shareResult == first.shareResult)
}

@Test func refresh62BackgroundExpiryKeepsPriorSuccessAndReasonAfterColdLoad() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID(), attempt = UUID()
    let original = try await seed62(archive, id: id)
    _ = try await archive.beginRetry(id: id, attemptID: attempt)
    let expired = try await archive.complete(id: id, result: nil, message: "辨識中斷，尚未完成", attemptID: attempt, stopReason: .backgroundTimeExpired)
    #expect(expired.status == .interrupted && expired.attempts?.last?.stopReason == .backgroundTimeExpired)
    #expect(expired.shareDocument() == original.shareDocument() && expired.canRetryImage)
    #expect(try await RecognitionArchive(root: root).load().records.first == expired)
}

@Test func refresh62MissingImageDoesNotBeginOrEraseExistingResult() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID()
    let old = try await seed62(archive, id: id)
    try FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString).appendingPathComponent("source.jpg"))
    await #expect(throws: Error.self) { try await archive.beginRetry(id: id, attemptID: UUID()) }
    let load = try await archive.load()
    #expect(load.missingImageIDs == [id])
    #expect(load.records.first == old)
}

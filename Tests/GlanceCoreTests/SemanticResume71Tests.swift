import Foundation
import Testing
@testable import GlanceCore

private func resume71Result(_ id: UUID) -> RecognitionResult {
    .init(names: ["曙光旋脆片"], summary: "保留原本的初步簡介。", text: ["AURORA"], sourceImageID: id,
          searchContractVersion: 17, searchEntities: [.init(kind: .product, name: "曙光旋脆片", basis: .logo, sourceText: "AURORA")])
}
private func resume71Archive() async throws -> (RecognitionArchive, URL, ArchivedRecognition) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let archive = RecognitionArchive(root: root), id = UUID()
    _ = try await archive.create(id: id, jpeg: Data([1, 2, 3]), capturedAt: Date())
    let raw = RecognitionModelResponse.capture("{\"summary\":\"原始文字\"}", sourceImageID: id, attemptID: id, appVersion: "0.1.0", appBuild: "70")
    return (archive, root, try await archive.complete(id: id, result: resume71Result(id), message: nil, modelResponse: raw))
}
@Test func resume71PreservesStageOneAndRejectsDuplicateClaimAndLateResponse() async throws {
    let (archive, root, base) = try await resume71Archive(); defer { try? FileManager.default.removeItem(at: root) }
    let old = UUID(), next = UUID()
    _ = try await archive.beginSemanticReview(id: base.id, attemptID: base.id, runID: old, expectedResult: base.result!)
    _ = try await archive.updateSemanticReview(id: base.id, attemptID: base.id, runID: old, state: .cancelled)
    let resumed = try await archive.resumeSemanticReview(id: base.id, attemptID: base.id, runID: next, previousRunID: old, expectedResult: base.result!)
    #expect(resumed.result == base.result && resumed.attempts == base.attempts && resumed.modelResponses == base.modelResponses)
    #expect(resumed.imageSHA256 == base.imageSHA256 && resumed.sequence == base.sequence && resumed.capturedAt == base.capturedAt)
    #expect(resumed.semanticReview?.generation == 2)
    #expect(try await archive.image(for: resumed) == Data([1, 2, 3]))
    await #expect(throws: Error.self) { try await archive.resumeSemanticReview(id: base.id, attemptID: base.id, runID: UUID(), previousRunID: old, expectedResult: base.result!) }
    await #expect(throws: Error.self) { try await archive.updateSemanticReview(id: base.id, attemptID: base.id, runID: old, state: .cancelled) }
    #expect(try await archive.load(liveSemanticRunIDs: [next]).records.first?.semanticReview?.runID == next)
}
@Test func resume71RestartAndLegacyArchiveNeverAutoReplay() async throws {
    let (archive, root, base) = try await resume71Archive(); defer { try? FileManager.default.removeItem(at: root) }
    #expect(base.canContinueSemanticReview) // First stage saved, second stage not admitted.
    let run = UUID()
    var started = try await archive.beginSemanticReview(id: base.id, attemptID: base.id, runID: run, expectedResult: base.result!)
    started.semanticReview?.runNumber = nil // Actual old archive representation.
    let encoded = try JSONEncoder().encode(started)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("runNumber"))
    let legacy = try JSONDecoder().decode(ArchivedRecognition.self, from: encoded)
    #expect(legacy.semanticReview?.generation == 1 && legacy.canContinueSemanticReview)
    let restored = try #require(try await RecognitionArchive(root: root).load().records.first)
    #expect(restored.semanticReview?.state == .interrupted && restored.canContinueSemanticReview)
    #expect(restored.result == base.result && restored.attemptNumber == 1)
    let resumed = try await archive.resumeSemanticReview(id: base.id, attemptID: base.id, runID: UUID(), previousRunID: run, expectedResult: base.result!)
    #expect(resumed.semanticReview?.generation == 2)
}
@Test func resume71CompletedDecisionsDoNotPromptContinuation() async throws {
    let (archive, root, base) = try await resume71Archive(); defer { try? FileManager.default.removeItem(at: root) }
    for state in [RecognitionSemanticReview.State.noMatch, .insufficientEvidence] {
        var value = base
        value.semanticReview = .init(recordID: base.id, attemptID: base.id, runID: UUID())
        value.semanticReview?.state = state
        value.semanticReview?.answer = .init(decision: state == .noMatch ? .no_match : .insufficient_evidence)
        #expect(!value.canContinueSemanticReview)
    }
    let run = UUID()
    _ = try await archive.beginSemanticReview(id: base.id, attemptID: base.id, runID: run, expectedResult: base.result!)
    let done = try await archive.updateSemanticReview(id: base.id, attemptID: base.id, runID: run, state: .insufficientEvidence, sources: [])
    #expect(!done.canContinueSemanticReview)
    await #expect(throws: Error.self) { try await archive.resumeSemanticReview(id: base.id, attemptID: base.id, runID: UUID(), previousRunID: run, expectedResult: base.result!) }
}
@Test func resume71EligibilityRequiresUsableCurrentStageOneAndReliableCompletion() async throws {
    let (_, root, base) = try await resume71Archive(); defer { try? FileManager.default.removeItem(at: root) }
    for state in [ArchivedRecognition.Status.pending, .failed, .interrupted] {
        var value = base; value.status = state; #expect(!value.canContinueSemanticReview)
    }
    var value = base; value.result = .init(names: ["舊卡"], summary: "沒有結構化搜尋實體")
    #expect(!value.canContinueSemanticReview)
    value = base; value.semanticReview = .init(recordID: base.id, attemptID: base.id, runID: UUID())
    for state in [RecognitionSemanticReview.State.failed, .cancelled, .collecting, .reviewing, .interrupted, .succeeded, .noMatch] {
        value.semanticReview?.state = state
        #expect(value.canContinueSemanticReview) // Terminal success without valid evidence is not completion.
    }
}
@Test func resume71NewImageAttemptAndDeletionInvalidateOldContinuation() async throws {
    let (archive, root, base) = try await resume71Archive(); defer { try? FileManager.default.removeItem(at: root) }
    let run = UUID()
    _ = try await archive.beginSemanticReview(id: base.id, attemptID: base.id, runID: run, expectedResult: base.result!)
    _ = try await archive.updateSemanticReview(id: base.id, attemptID: base.id, runID: run, state: .failed)
    let attempt = UUID(); _ = try await archive.beginRetry(id: base.id, attemptID: attempt)
    await #expect(throws: Error.self) { try await archive.resumeSemanticReview(id: base.id, attemptID: base.id, runID: UUID(), previousRunID: run, expectedResult: base.result!) }
    _ = try await archive.complete(id: base.id, result: resume71Result(base.id), message: nil, attemptID: attempt)
    _ = try await archive.delete(ids: [base.id], resetSequenceWhenEmpty: true)
    await #expect(throws: Error.self) { try await archive.resumeSemanticReview(id: base.id, attemptID: attempt, runID: UUID(), previousRunID: nil, expectedResult: base.result!) }
    let fresh = try await archive.create(id: UUID(), jpeg: Data([7]), capturedAt: Date())
    #expect(fresh.sequence == 1 && fresh.id != base.id)
}

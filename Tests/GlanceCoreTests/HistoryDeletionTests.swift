import Foundation
import Testing
@testable import GlanceCore

private func deletionRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("Glance-delete-test-" + UUID().uuidString) }
private func saved(_ store: RecognitionArchive, image: Data = Data([1, 2, 3]), source: ArchivedRecognition.ImageSource = .camera) async throws -> ArchivedRecognition {
    let id = UUID()
    _ = try await store.create(id: id, jpeg: image, capturedAt: Date(), imageSource: source)
    return try await store.complete(id: id, result: .init(names: ["合成紀錄"], summary: "完整文字", text: ["Original"], searchQuery: PublicSearchQuery(query: "合成紀錄", category: "object")), message: nil)
}
private final class DeletionFault: @unchecked Sendable {
    private let lock = NSLock()
    private var mode = 0
    func set(_ mode: Int) { lock.withLock { self.mode = mode } }
    func check(_ url: URL) throws {
        let mode = lock.withLock { mode }
        if mode == 1 || (mode == 2 && url.lastPathComponent.hasPrefix(".deleted-")) { throw CocoaError(.fileWriteNoPermission) }
    }
}

@Test func deletionRemovesOnlyChosenRecordImageLinksAndKeepsExternalCopiesAfterReopen() async throws {
    let root = deletionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = RecognitionArchive(root: root.appendingPathComponent("history"))
    let photo = root.appendingPathComponent("synthetic-album-original.jpg")
    let a = try await saved(store, source: .photoLibrary), b = try await saved(store, image: Data([9]))
    try Data([1, 2, 3]).write(to: photo)
    let shared = a.shareDocument(), sharedFile = root.appendingPathComponent("synthetic-already-shared.txt")
    try shared.plainText.write(to: sharedFile, atomically: true, encoding: .utf8)
    let result = try await store.delete(ids: [a.id])
    #expect(result.deletedIDs == [a.id] && result.issues.isEmpty && !result.cleanupPending)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("history/" + a.id.uuidString).path))
    let reopened = RecognitionArchive(root: root.appendingPathComponent("history"))
    #expect(try await reopened.load().records == [b])
    #expect(try await reopened.image(for: b) == Data([9]))
    #expect(try Data(contentsOf: photo) == Data([1, 2, 3]))
    #expect(try String(contentsOf: sharedFile, encoding: .utf8) == shared.plainText)
}

@Test func deletionBatchRejectsPendingBeforeDeletingAnyOtherRecord() async throws {
    let root = deletionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = RecognitionArchive(root: root), a = try await saved(store), pending = UUID()
    _ = try await store.create(id: pending, jpeg: Data([7]), capturedAt: Date())
    await #expect(throws: RecognitionArchive.Failure.recognitionInProgress) { _ = try await store.delete(ids: [a.id, pending]) }
    #expect(Set(try await store.load(recoverPending: false).records.map(\.id)) == [a.id, pending])
    // Completed older cards remain deletable while another record is pending.
    #expect(try await store.delete(ids: [a.id]).deletedIDs == [a.id])
    #expect(try await store.load(recoverPending: false).records.map(\.id) == [pending])
}

@Test func deletionOfAllSurvivesReopenAndAllowsNewRecordsWithoutRevivingOldIDs() async throws {
    let root = deletionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = RecognitionArchive(root: root), a = try await saved(store), b = try await saved(store)
    #expect(try await store.delete(ids: [a.id, b.id]).issues.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    let reopened = RecognitionArchive(root: root)
    #expect(try await reopened.load().records.isEmpty)
    #expect(try await reopened.delete(ids: []).deletedIDs.isEmpty)
    let c = try await saved(reopened)
    await #expect(throws: Error.self) { _ = try await store.complete(id: a.id, result: .init(names: ["late"]), message: nil) }
    await #expect(throws: Error.self) { _ = try await store.beginRetry(id: b.id, attemptID: UUID()) }
    #expect(try await reopened.load().records == [c])
}

@Test func deletionWriteFailurePreservesWholeRecordAndCanBeRetried() async throws {
    let root = deletionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fault = DeletionFault(), store = RecognitionArchive(root: root, beforeWrite: { try fault.check($0) })
    let a = try await saved(store)
    fault.set(1)
    await #expect(throws: Error.self) { _ = try await store.delete(ids: [a.id]) }
    #expect(try await store.load().records == [a])
    #expect(try await store.image(for: a) == Data([1, 2, 3]))
    fault.set(0)
    #expect(try await store.delete(ids: [a.id]).deletedIDs == [a.id])
}

@Test func deletionCleanupFailureDoesNotResurrectRecordAndReopenRetriesCleanup() async throws {
    let root = deletionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fault = DeletionFault(), store = RecognitionArchive(root: root, beforeWrite: { try fault.check($0) })
    let a = try await saved(store)
    fault.set(2)
    let result = try await store.delete(ids: [a.id])
    #expect(result.deletedIDs == [a.id] && result.cleanupPending && !result.issues.isEmpty)
    #expect(try await store.load().records.isEmpty)
    #expect(!(try await store.load().deletionIssues.isEmpty))
    await #expect(throws: Error.self) { _ = try await store.complete(id: a.id, result: .init(names: ["late"]), message: nil) }
    let remaining = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    #expect(remaining.count == 1 && remaining[0].lastPathComponent.hasPrefix(".deleted-"))
    let reopened = RecognitionArchive(root: root)
    #expect(try await reopened.load().deletionIssues.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@Test func deletionRejectsSymlinkAndLeavesOutsideDataUntouched() async throws {
    let root = deletionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.appendingPathComponent("outside"), inside = root.appendingPathComponent("history")
    let original = try await saved(RecognitionArchive(root: outside))
    let store = RecognitionArchive(root: inside); _ = try await store.load()
    try FileManager.default.createSymbolicLink(at: inside.appendingPathComponent(original.id.uuidString), withDestinationURL: outside.appendingPathComponent(original.id.uuidString))
    await #expect(throws: Error.self) { _ = try await store.delete(ids: [original.id]) }
    #expect(try await RecognitionArchive(root: outside).load().records == [original])
}

@Test func explicitClearResetsNextSequenceImmediatelyWithoutReusingIDsOrRevivingLateWork() async throws {
    let root = deletionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = RecognitionArchive(root: root), a = try await saved(store), b = try await saved(store)
    let run = UUID()
    _ = try await store.beginSemanticReview(id: b.id, attemptID: b.currentAttemptID, runID: run, expectedResult: b.result!)
    let deleted = try await store.delete(ids: [a.id, b.id], resetSequenceWhenEmpty: true)
    #expect(deleted.deletedIDs == [a.id, b.id] && deleted.issues.isEmpty && !deleted.cleanupPending)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    let c = try await saved(store)
    #expect(c.sequence == 1 && c.id != a.id && c.id != b.id)
    await #expect(throws: Error.self) { _ = try await store.complete(id: a.id, result: .init(names: ["late stage one"]), message: nil) }
    await #expect(throws: Error.self) { _ = try await store.updateSemanticReview(id: b.id, attemptID: b.currentAttemptID, runID: run, state: .cancelled) }
    #expect(try await store.load().records == [c])
    #expect(try await saved(RecognitionArchive(root: root)).sequence == 2)
}

@Test func singleDeletesIncludingLastRecordDoNotResetSequence() async throws {
    let root = deletionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = RecognitionArchive(root: root), a = try await saved(store), b = try await saved(store)
    _ = try await store.delete(ids: [b.id])
    #expect(try await store.load().records == [a])
    _ = try await store.delete(ids: [a.id])
    #expect(try await saved(store).sequence == 3)
}

@Test func clearWithStaleIDsReportsRemainingRecordAndDoesNotResetSequence() async throws {
    let root = deletionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = RecognitionArchive(root: root), a = try await saved(store), b = try await saved(store)
    let deletion = try await store.delete(ids: [a.id], resetSequenceWhenEmpty: true)
    #expect(!deletion.issues.isEmpty && deletion.deletedIDs == [a.id])
    #expect(try await store.load().records == [b])
    #expect(try await saved(store).sequence == 3)
}

@Test func clearFailureKeepsCounterAndHistoryThenSuccessfulRetryResets() async throws {
    let root = deletionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fault = DeletionFault(), store = RecognitionArchive(root: root, beforeWrite: { try fault.check($0) })
    let a = try await saved(store)
    fault.set(1)
    await #expect(throws: Error.self) { _ = try await store.delete(ids: [a.id], resetSequenceWhenEmpty: true) }
    fault.set(0)
    let b = try await saved(store)
    #expect(b.sequence == 2)
    #expect(try await store.delete(ids: [a.id, b.id], resetSequenceWhenEmpty: true).issues.isEmpty)
    #expect(try await saved(store).sequence == 1)
}

@Test func clearCleanupFailureDoesNotClaimSuccessOrResetCounter() async throws {
    let root = deletionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fault = DeletionFault(), store = RecognitionArchive(root: root, beforeWrite: { try fault.check($0) })
    let a = try await saved(store)
    fault.set(2)
    let deletion = try await store.delete(ids: [a.id], resetSequenceWhenEmpty: true)
    #expect(deletion.cleanupPending && !deletion.issues.isEmpty)
    fault.set(0)
    _ = try await store.delete(ids: [])
    #expect(try await saved(store).sequence == 2)
}

@Test func clearWithPendingRecordRejectsEntireBatchWithoutReset() async throws {
    let root = deletionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = RecognitionArchive(root: root), a = try await saved(store), pending = UUID()
    _ = try await store.create(id: pending, jpeg: Data([1]), capturedAt: Date())
    await #expect(throws: RecognitionArchive.Failure.recognitionInProgress) {
        _ = try await store.delete(ids: [a.id, pending], resetSequenceWhenEmpty: true)
    }
    #expect(try await store.load(recoverPending: false).records.count == 2)
    #expect(try await saved(store).sequence == 3)
}

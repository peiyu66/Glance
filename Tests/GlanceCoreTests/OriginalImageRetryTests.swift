import Foundation
import Testing
@testable import GlanceCore

private func retryTestRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("Glance-original-image-retry-" + UUID().uuidString)
}

@Test func originalImageRetrySuccessKeepsRecordIdentityCaptureDateAndExactBytes() async throws {
    let root = retryTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID(), attempt = UUID()
    let image = Data([0xff, 0xd8, 0, 12, 255, 42, 0xff, 0xd9])
    let captured = Date(timeIntervalSince1970: 123)
    let original = try await archive.create(id: id, jpeg: image, capturedAt: captured, decodedBarcodes: ["00123"])
    _ = try await archive.complete(id: id, result: nil, message: "initial failure")
    let pending = try await archive.beginRetry(id: id, attemptID: attempt, at: captured.addingTimeInterval(60))
    #expect(pending.status == .pending && !pending.canRetryImage && !pending.canShare)
    let result = try await archive.complete(id: id, result: .init(names: ["重試成功"], barcodes: ["untrusted"]), message: nil, attemptID: attempt)
    #expect(result.status == .succeeded && !result.canRetryImage)
    #expect(result.id == original.id && result.sequence == original.sequence && result.capturedAt == captured)
    #expect(result.imageSHA256 == original.imageSHA256 && result.imageByteCount == image.count)
    #expect(result.result?.sourceImageID == id && result.result?.barcodes == ["00123"])
    #expect(result.attempts?.map(\.outcome) == [.failed, .succeeded])
    #expect(try await archive.image(for: result) == image)
    #expect(try await RecognitionArchive(root: root).load().records == [result])
}

@Test func originalImageRetrySecondFailureRetainsSourceAndAllowsAnotherExplicitAttempt() async throws {
    let root = retryTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID(), attempt = UUID(), image = Data([7, 0, 8])
    _ = try await archive.create(id: id, jpeg: image, capturedAt: Date())
    _ = try await archive.complete(id: id, result: nil, message: "initial failure")
    _ = try await archive.beginRetry(id: id, attemptID: attempt)
    let failed = try await archive.complete(id: id, result: nil, message: "retry failure", attemptID: attempt)
    #expect(failed.canRetryImage && failed.result == nil && failed.message == "retry failure")
    #expect(failed.attempts?.map(\.outcome) == [.failed, .failed])
    #expect(try await archive.image(for: failed) == image)
    #expect(try await archive.load().records.count == 1)
    let next = try await archive.beginRetry(id: id, attemptID: UUID())
    #expect(next.attemptNumber == 3 && next.status == .pending)
}

@Test func originalImageRetryTimeoutCannotCompleteOrOverwriteANewerAttempt() async throws {
    let root = retryTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID(), a = UUID(), b = UUID()
    _ = try await archive.create(id: id, jpeg: Data([3, 2, 1]), capturedAt: Date())
    _ = try await archive.complete(id: id, result: nil, message: "initial failure")
    _ = try await archive.beginRetry(id: id, attemptID: a)
    let timeout = try await archive.complete(id: id, result: nil, message: "timeout", attemptID: a, timedOut: true)
    #expect(timeout.attempts?.last?.outcome == .timedOut && timeout.canRetryImage)
    #expect(try await archive.complete(id: id, result: .init(names: ["late A"]), message: nil, attemptID: a) == timeout)
    let pending = try await archive.beginRetry(id: id, attemptID: b)
    #expect(try await archive.complete(id: id, result: .init(names: ["late A"]), message: nil, attemptID: a) == pending)
    #expect(try await archive.complete(id: id, result: .init(names: ["late original"]), message: nil) == pending)
    let winner = try await archive.complete(id: id, result: .init(names: ["B"]), message: nil, attemptID: b)
    #expect(try await archive.complete(id: id, result: nil, message: "late A failure", attemptID: a) == winner)
    #expect(winner.result?.names == ["B"] && winner.attempts?.map(\.outcome) == [.failed, .timedOut, .succeeded])
}

@Test func originalImageRetryRejectsDuplicateAttemptAndConcurrentBegin() async throws {
    let root = retryTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID(), attempt = UUID()
    _ = try await archive.create(id: id, jpeg: Data([8]), capturedAt: Date())
    _ = try await archive.complete(id: id, result: nil, message: nil)
    await #expect(throws: Error.self) { _ = try await archive.beginRetry(id: id, attemptID: id) }
    let pending = try await archive.beginRetry(id: id, attemptID: attempt)
    await #expect(throws: Error.self) { _ = try await archive.beginRetry(id: id, attemptID: UUID()) }
    #expect(try await archive.load(recoverPending: false).records == [pending])
    _ = try await archive.complete(id: id, result: nil, message: nil, attemptID: attempt)
    await #expect(throws: Error.self) { _ = try await archive.beginRetry(id: id, attemptID: attempt) }
}

@Test func originalImageRetryRebootRecoversAttemptWithoutAutomaticReplay() async throws {
    let root = retryTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID(), attempt = UUID(), image = Data([0, 42, 255])
    _ = try await archive.create(id: id, jpeg: image, capturedAt: Date())
    _ = try await archive.complete(id: id, result: nil, message: nil)
    _ = try await archive.beginRetry(id: id, attemptID: attempt)
    let rebooted = RecognitionArchive(root: root)
    let recovered = try #require(try await rebooted.load().records.first)
    #expect(recovered.id == id && recovered.status == .interrupted && recovered.canRetryImage)
    #expect(recovered.currentAttemptID == attempt && recovered.attempts?.map(\.outcome) == [.failed, .interrupted])
    #expect(try await rebooted.load().records == [recovered])
    #expect(try await rebooted.image(for: recovered) == image)
    let pending = try await rebooted.beginRetry(id: id, attemptID: UUID())
    #expect(pending.attemptNumber == 3 && pending.id == id)
}

@Test func originalImageRetryMigratesLegacyRecordOnlyAfterExplicitBegin() async throws {
    let root = retryTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID(), image = Data([4, 9])
    _ = try await archive.create(id: id, jpeg: image, capturedAt: Date())
    _ = try await archive.complete(id: id, result: nil, message: "legacy failure")
    let file = root.appendingPathComponent(id.uuidString).appendingPathComponent("record.json")
    var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    json.removeValue(forKey: "attempts")
    try JSONSerialization.data(withJSONObject: json).write(to: file)
    let legacy = try #require(try await RecognitionArchive(root: root).load().records.first)
    #expect(legacy.attempts == nil && legacy.canRetryImage && legacy.currentAttemptID == id)
    let retried = try await archive.beginRetry(id: id, attemptID: UUID())
    #expect(retried.attempts?.first?.outcome == .failed && retried.attemptNumber == 2)
    #expect(try await archive.image(for: retried) == image)
}

@Test func originalImageRetryRejectsChangedBytesWithoutMutatingRecord() async throws {
    let root = retryTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID()
    _ = try await archive.create(id: id, jpeg: Data([1, 2]), capturedAt: Date())
    let failed = try await archive.complete(id: id, result: nil, message: nil)
    let folder = root.appendingPathComponent(id.uuidString)
    let recordBefore = try Data(contentsOf: folder.appendingPathComponent("record.json"))
    try Data([1, 3]).write(to: folder.appendingPathComponent("source.jpg"))
    await #expect(throws: Error.self) { _ = try await archive.beginRetry(id: id, attemptID: UUID()) }
    #expect(try Data(contentsOf: folder.appendingPathComponent("record.json")) == recordBefore)
    #expect(try await archive.load().records == [failed])
}

@Test func originalImageRetryCycleReservesOnceWithoutOpeningCameraAndOwnsItsSlot() {
    var cycle = SingleCaptureCycle(); let id = UUID(), other = UUID()
    let reserved = cycle.reserveArchived(id: id); #expect(reserved)
    #expect(cycle.preview == .closed && cycle.deadline == nil && !cycle.analyzesFrames)
    let duplicate = cycle.reserveArchived(id: id), competing = cycle.reserveArchived(id: other), armed = cycle.arm()
    #expect(!duplicate && !competing && !armed)
    let wrongWaiting = cycle.waiting(id: other), wrongFinish = cycle.finish(id: other)
    #expect(!wrongWaiting && !wrongFinish)
    let waiting = cycle.waiting(id: id); #expect(waiting); cycle.closePreview(expired: true)
    let reservedWhileClosed = cycle.reserveArchived(id: other)
    #expect(cycle.activeID == id && !reservedWhileClosed)
    let finished = cycle.finish(id: id), reservedNext = cycle.reserveArchived(id: other)
    #expect(finished && reservedNext)
    #expect(cycle.preview == .expired && cycle.deadline == nil && !cycle.analyzesFrames)
}

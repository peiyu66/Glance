import Foundation
import Testing
@testable import GlanceCore

private func archiveTestRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("Glance-C2-test-" + UUID().uuidString) }
private final class ArchiveWriteFault: @unchecked Sendable {
    private let lock = NSLock(); private var fail = false
    func set(_ flag: Bool) { lock.withLock { fail = flag } }
    func check(_: URL) throws { if lock.withLock({ fail }) { throw CocoaError(.fileWriteOutOfSpace) } }
}
@Test func archiveReopensExactImageAndFullUnicodeResult() async throws {
    let root = archiveTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = RecognitionArchive(root: root); let id = UUID(); let image = Data([0,1,2,3,255])
    let pending = try await store.create(id: id, jpeg: image, capturedAt: Date(timeIntervalSince1970: 10))
    #expect(!pending.canShare)
    let answer = RecognitionResult(names: ["茶"], summary: "繁體簡介", text: ["原語言\nABC 👩🏽‍🔬"], barcodes: ["00123"])
    let completed = try await store.complete(id: id, result: answer, message: nil)
    let rebooted = RecognitionArchive(root: root); let loaded = try await rebooted.load()
    #expect(loaded.issues.isEmpty); #expect(loaded.records == [completed]); #expect(completed.canShare)
    #expect(completed.result?.sourceImageID == id); #expect(completed.result?.shareText == answer.shareText)
    #expect(try await rebooted.image(for: completed) == image)
}
@Test func archiveRestoresPendingAsInterruptedWithoutResendingOrLosingImage() async throws {
    let root = archiveTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = RecognitionArchive(root: root); let data = Data("synthetic A".utf8)
    _ = try await store.create(id: UUID(), jpeg: data, capturedAt: Date())
    let loaded = try await RecognitionArchive(root: root).load(); let row = try #require(loaded.records.first)
    #expect(row.status == .interrupted); #expect(!row.canShare)
    #expect(try await store.image(for: row) == data)
    let again = try await RecognitionArchive(root: root).load(); #expect(again.records == loaded.records)
}
@Test func archiveOutOfOrderCompletionsKeepCaptureOrderAndOwnImages() async throws {
    let root = archiveTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let s = RecognitionArchive(root: root); let a = UUID(), b = UUID()
    let ra = try await s.create(id: a, jpeg: Data("A".utf8), capturedAt: Date(timeIntervalSince1970: 10))
    let rb = try await s.create(id: b, jpeg: Data("B".utf8), capturedAt: Date(timeIntervalSince1970: 5))
    _ = try await s.complete(id: b, result: .init(names:["B"]), message:nil)
    _ = try await s.complete(id: a, result: .init(names:["A"]), message:nil)
    let rows = try await s.load().records; #expect(rows.map(\.id) == [b,a]); #expect(rows.map(\.sequence) == [2,1])
    #expect(try await s.image(for: ra) == Data("A".utf8)); #expect(try await s.image(for: rb) == Data("B".utf8))
}
@Test func archiveDuplicateTerminalReplyCannotOverwritePaidResult() async throws {
    let root = archiveTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let s = RecognitionArchive(root: root); let id = UUID(); _ = try await s.create(id:id,jpeg:Data([1]),capturedAt:Date())
    let original = try await s.complete(id:id,result:.init(names:["paid"]),message:nil)
    #expect(try await s.complete(id:id,result:nil,message:"late failure") == original)
    #expect(try await s.complete(id:id,result:.init(names:["wrong"]),message:nil) == original)
}
@Test func archiveSaveFailureDoesNotReplaceGoodRecordAndCanRetry() async throws {
    let root = archiveTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fault = ArchiveWriteFault(); let s = RecognitionArchive(root:root,beforeWrite: { try fault.check($0) })
    let id = UUID(); let pending = try await s.create(id:id,jpeg:Data([1,2]),capturedAt:Date())
    fault.set(true)
    await #expect(throws: Error.self) { _ = try await s.complete(id:id,result:.init(names:["kept in memory"]),message:nil) }
    let afterFailure = try await s.load(recoverPending:false); #expect(afterFailure.records == [pending])
    fault.set(false); let result = try await s.complete(id:id,result:.init(names:["kept in memory"]),message:nil)
    #expect(result.status == .succeeded)
}
@Test func archiveCreateFailurePublishesNoPartialRow() async throws {
    let root = archiveTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fault = ArchiveWriteFault(); let s = RecognitionArchive(root:root,beforeWrite: { try fault.check($0) })
    _ = try await s.load(); fault.set(true)
    await #expect(throws: Error.self) { _ = try await s.create(id:UUID(),jpeg:Data([1]),capturedAt:Date()) }
    #expect(try FileManager.default.contentsOfDirectory(atPath:root.path).isEmpty)
}
@Test func archiveCorruptionAndMissingImageAreReportedWithoutDeletion() async throws {
    let root = archiveTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let s = RecognitionArchive(root:root); let a = UUID(), b = UUID()
    _ = try await s.create(id:a,jpeg:Data([1]),capturedAt:Date()); _ = try await s.complete(id:a,result:.init(names:["A"]),message:nil)
    _ = try await s.create(id:b,jpeg:Data([2]),capturedAt:Date()); _ = try await s.complete(id:b,result:.init(names:["B"]),message:nil)
    let broken = root.appendingPathComponent(a.uuidString).appendingPathComponent("record.json")
    try Data("bad JSON".utf8).write(to:broken)
    try Data("changed image".utf8).write(to:root.appendingPathComponent(b.uuidString).appendingPathComponent("source.jpg"))
    let loaded = try await RecognitionArchive(root:root).load()
    #expect(loaded.records.count == 1); #expect(loaded.issues.count == 2)
    #expect(try Data(contentsOf:broken) == Data("bad JSON".utf8))
    #expect(FileManager.default.fileExists(atPath:root.appendingPathComponent(b.uuidString).path))
}
@Test func archiveMoreThanOldMemoryLimitSurvivesReboot() async throws {
    let root = archiveTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let s = RecognitionArchive(root:root)
    for i in 1...16 {
        let id = UUID(); _ = try await s.create(id:id,jpeg:Data([UInt8(i)]),capturedAt:Date())
        _ = try await s.complete(id:id,result:.init(names:["row \(i)"]),message:nil)
    }
    let loaded = try await RecognitionArchive(root:root).load()
    #expect(loaded.records.count == 16); #expect(loaded.records.first?.sequence == 16)
    let next = try await RecognitionArchive(root:root).create(id:UUID(),jpeg:Data([99]),capturedAt:Date())
    #expect(next.sequence == 17)
}
@Test func archiveFailedRequestRetainsImageAndDoesNotPermitSharing() async throws {
    let root = archiveTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let s = RecognitionArchive(root:root); let id = UUID(); _ = try await s.create(id:id,jpeg:Data([7]),capturedAt:Date())
    let row = try await s.complete(id:id,result:nil,message:"timed out")
    #expect(row.status == .failed); #expect(!row.canShare); #expect(try await s.image(for:row) == Data([7]))
    #expect(try await RecognitionArchive(root:root).load().records == [row])
}

@Test func decodedBarcodeSurvivesAIOmissionAndAppearsInShare() async throws {
    let root = archiveTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let s = RecognitionArchive(root: root); let id = UUID()
    let pending = try await s.create(id: id, jpeg: Data([3,4]), capturedAt: Date(), decodedBarcodes: ["0012345678905"])
    #expect(pending.barcodes == ["0012345678905"]); #expect(!pending.canShare)
    let done = try await s.complete(id: id, result: .init(names: ["same photo"], barcodes: []), message: nil)
    #expect(done.result?.barcodes == ["0012345678905"])
    #expect(done.shareResult?.shareText.contains("【條碼】\n\n0012345678905") == true)
    #expect(done.shareResult?.sourceImageID == id)
    #expect(try await RecognitionArchive(root: root).load().records == [done])
}
@Test func newSourceDoesNotAcceptUnverifiedAIBarcodeOrBorrowOtherCards() async throws {
    let root = archiveTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let s = RecognitionArchive(root: root); let a = UUID(), b = UUID()
    _ = try await s.create(id: a, jpeg: Data([1]), capturedAt: Date(), decodedBarcodes: ["00001"])
    _ = try await s.create(id: b, jpeg: Data([2]), capturedAt: Date(), decodedBarcodes: [])
    let rb = try await s.complete(id: b, result: .init(names: ["B"], barcodes: ["00001", "guessed"]), message: nil)
    let ra = try await s.complete(id: a, result: .init(names: ["A"], barcodes: ["wrong"]), message: nil)
    #expect(rb.barcodes.isEmpty); #expect(rb.result?.barcodes.isEmpty == true)
    #expect(ra.barcodes == ["00001"]); #expect(ra.result?.barcodes == ["00001"])
    #expect(try await s.complete(id: a, result: .init(barcodes: ["late wrong"]), message: nil) == ra)
    let rows = try await RecognitionArchive(root: root).load().records
    #expect(rows.map(\.id) == [b, a]); #expect(rows.map(\.barcodes) == [[], ["00001"]])
}
@Test func decodedBarcodeSurvivesFailureAndCanBeSharedWithoutAI() async throws {
    let root = archiveTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let s = RecognitionArchive(root: root); let id = UUID()
    _ = try await s.create(id: id, jpeg: Data([9]), capturedAt: Date(), decodedBarcodes: ["CODE-A"])
    let failed = try await s.complete(id: id, result: nil, message: "timeout")
    #expect(failed.status == .failed); #expect(failed.canShare)
    #expect(failed.shareResult?.shareText == "【條碼】\n\nCODE-A")
    #expect(try await RecognitionArchive(root: root).load().records == [failed])
}
@Test func decodedBarcodeSurvivesInterruptedPendingRecord() async throws {
    let root = archiveTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let s = RecognitionArchive(root: root)
    _ = try await s.create(id: UUID(), jpeg: Data([8]), capturedAt: Date(), decodedBarcodes: ["0022"])
    let record = try #require(try await RecognitionArchive(root: root).load().records.first)
    #expect(record.status == .interrupted); #expect(record.barcodes == ["0022"])
    #expect(record.canShare); #expect(record.shareResult?.sourceImageID == record.id)
}
@Test func legacyArchiveWithoutDecodedFieldRemainsReadable() async throws {
    let root = archiveTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let s = RecognitionArchive(root: root); let id = UUID()
    _ = try await s.create(id: id, jpeg: Data([4]), capturedAt: Date())
    _ = try await s.complete(id: id, result: .init(names: ["legacy"], barcodes: ["00123"]), message: nil)
    let file = root.appendingPathComponent(id.uuidString).appendingPathComponent("record.json")
    var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    json.removeValue(forKey: "decodedBarcodes")
    try JSONSerialization.data(withJSONObject: json).write(to: file)
    let record = try #require(try await RecognitionArchive(root: root).load().records.first)
    #expect(record.decodedBarcodes == nil); #expect(record.barcodes == ["00123"])
    #expect(record.shareResult?.shareText.contains("00123") == true)
}
@Test func capturedDateAndLocalTimeSurviveCompletionAndRestartAcrossDay() async throws {
    let root = archiveTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let s = RecognitionArchive(root: root); let id = UUID()
    let date = try #require(ISO8601DateFormatter().date(from: "2026-10-13T23:00:00Z"))
    _ = try await s.create(id: id, jpeg: Data([1]), capturedAt: date)
    _ = try await s.complete(id: id, result: .init(names: ["date"]), message: nil, at: date.addingTimeInterval(86400))
    let record = try #require(try await RecognitionArchive(root: root).load().records.first)
    #expect(record.capturedAt == date)
    #expect(record.captureTimestamp(timeZone: TimeZone(identifier: "Asia/Taipei")!) == "2026/10/14 07:00")
    #expect(record.captureTimestamp(timeZone: TimeZone(identifier: "America/Los_Angeles")!) == "2026/10/13 16:00")
}

import Foundation
import Testing
@testable import GlanceCore

private func photoSourceRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("Glance-photo-source-" + UUID().uuidString)
}

@Test func photoLibrarySourceSurvivesCompletionAndReopenWithExactBytes() async throws {
    let root = photoSourceRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID(), bytes = Data("generated photo source".utf8)
    let initial = try await archive.create(id: id, jpeg: bytes, capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
        decodedBarcodes: ["verified-source"], imageSource: .photoLibrary)
    #expect(initial.source == .photoLibrary && initial.imageSource == .photoLibrary)
    let finished = try await archive.complete(id: id, result: .init(names: ["合成相簿圖片"], barcodes: ["untrusted-guess"]), message: nil)
    let reopened = RecognitionArchive(root: root)
    let loaded = try await reopened.load()
    #expect(loaded.issues.isEmpty && loaded.records == [finished])
    #expect(finished.source == .photoLibrary && finished.result?.sourceImageID == id)
    #expect(finished.result?.barcodes == ["verified-source"])
    #expect(try await reopened.image(for: finished) == bytes)
}

@Test func legacyMissingPhotoSourceDecodesAsCameraWithoutRewritingImage() async throws {
    let root = photoSourceRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID(), bytes = Data("generated legacy camera".utf8)
    _ = try await archive.create(id: id, jpeg: bytes, capturedAt: Date())
    _ = try await archive.complete(id: id, result: .init(names: ["舊相機紀錄"]), message: nil)
    let url = root.appendingPathComponent(id.uuidString).appendingPathComponent("record.json")
    var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    object.removeValue(forKey: "imageSource")
    try JSONSerialization.data(withJSONObject: object).write(to: url)
    let reopened = RecognitionArchive(root: root)
    let record = try #require(try await reopened.load().records.first)
    #expect(record.imageSource == nil && record.source == .camera)
    #expect(record.status == .succeeded && record.result?.names == ["舊相機紀錄"])
    #expect(try await reopened.image(for: record) == bytes)
}

@Test func photoLibraryRetryAndInterruptedRecoveryKeepOriginalSource() async throws {
    let root = photoSourceRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID(), retry = UUID(), bytes = Data("generated retry photo".utf8)
    let original = try await archive.create(id: id, jpeg: bytes, capturedAt: Date(timeIntervalSince1970: 1_700_000_000), imageSource: .photoLibrary)
    let rebooted = RecognitionArchive(root: root)
    let interrupted = try #require(try await rebooted.load().records.first)
    #expect(interrupted.source == .photoLibrary && interrupted.status == .interrupted)
    let pending = try await rebooted.beginRetry(id: id, attemptID: retry)
    #expect(pending.source == .photoLibrary && pending.currentAttemptID == retry)
    let finished = try await rebooted.complete(id: id, result: .init(names: ["相簿重試"]), message: nil, attemptID: retry)
    #expect(finished.id == original.id && finished.sequence == original.sequence && finished.capturedAt == original.capturedAt)
    #expect(finished.source == .photoLibrary && finished.attempts?.map(\.outcome) == [.interrupted, .succeeded])
    #expect(try await RecognitionArchive(root: root).load().records == [finished])
    #expect(try await rebooted.image(for: finished) == bytes)
}

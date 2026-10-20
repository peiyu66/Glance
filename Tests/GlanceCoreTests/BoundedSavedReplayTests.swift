import Foundation
import Testing
@testable import GlanceCore

private struct ReplayFiles {
    let root: URL
    let history: URL
    let permit: URL
    let request: BoundedReplayRequest
    let hash: String
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let history = root.appendingPathComponent("history"), permit = root.appendingPathComponent("request.json")
        let archive = RecognitionArchive(root: history)
        var samples: [BoundedReplayRequest.Sample] = []
        for index in 0..<2 {
            let id = UUID(), jpeg = Data([1,2,UInt8(index)])
            _ = try await archive.create(id: id, jpeg: jpeg, capturedAt: Date())
            let record = try await archive.complete(id: id, result: .init(names: ["Synthetic"], searchContractVersion: 14, searchEntities: []), message: nil)
            let bytes = try Data(contentsOf: history.appendingPathComponent(id.uuidString + "/record.json"))
            samples.append(.init(id: id, sequence: record.sequence, recordSHA256: RecognitionArchive.hash(bytes), imageSHA256: record.imageSHA256, imageByteCount: record.imageByteCount))
        }
        let request = BoundedReplayRequest(schemaVersion: 1, runID: UUID(), appBuild: "39", promptRevision: CameraAnswer.promptRevision,
            expiresAt: Date().addingTimeInterval(300).timeIntervalSince1970, samples: samples)
        let data = try JSONEncoder().encode(request); try data.write(to: permit)
        return .init(root: root, history: history, permit: permit, request: request, hash: RecognitionArchive.hash(data))
    }
    func open(hash: String? = nil, runID: UUID? = nil, build: String = "39", now: Date = Date(), beforeWrite: @escaping (URL) throws -> Void = { _ in }) throws -> BoundedReplayStore {
        try .init(requestURL: permit, runsRoot: root.appendingPathComponent("runs"), historyRoot: history,
            runID: runID ?? request.runID, expectedRequestSHA256: hash ?? self.hash, build: build, now: now, beforeWrite: beforeWrite)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
@Test func boundedReplayClaimsExactlyOnceAndPreservesOriginals() async throws {
    let f = try await ReplayFiles.make(); defer { f.remove() }
    let run = try f.open()
    #expect(run.prepared.count == 2 && run.originalsUnchanged())
    #expect(!FileManager.default.fileExists(atPath: f.permit.path))
    for sample in f.request.samples {
        try run.claim(sample.id); try run.validateClaim(sample.id)
        #expect(throws: BoundedReplayStore.Failure.self) { try run.claim(sample.id) }
        try run.finish(sample.id)
        #expect(throws: BoundedReplayStore.Failure.self) { try run.validateClaim(sample.id) }
    }
    #expect(throws: BoundedReplayStore.Failure.self) { try run.claim(UUID()) }
    try run.stop(); #expect(run.state.terminal && run.state.claimed.count == 2 && run.originalsUnchanged())
}
@Test func boundedReplayRestartAndRestagedPermitNeverResume() async throws {
    let f = try await ReplayFiles.make(); defer { f.remove() }
    let raw = try Data(contentsOf: f.permit), run = try f.open()
    try run.claim(f.request.samples[0].id)
    #expect(throws: (any Error).self) { try f.open() }
    try raw.write(to: f.permit)
    #expect(throws: BoundedReplayStore.Failure.self) { try f.open() }
    let saved = try JSONDecoder().decode(BoundedReplayStore.State.self, from: Data(contentsOf: run.runDirectory.appendingPathComponent("state.json")))
    #expect(saved.claimed == [f.request.samples[0].id] && saved.finished.isEmpty)
}
@Test func boundedReplayRejectsWrongDigestNonceVersionAndExpiry() async throws {
    let f = try await ReplayFiles.make(); defer { f.remove() }
    #expect(throws: BoundedReplayStore.Failure.self) { try f.open(hash: String(repeating: "0", count: 64)) }
    #expect(throws: BoundedReplayStore.Failure.self) { try f.open(runID: UUID()) }
    #expect(throws: BoundedReplayStore.Failure.self) { try f.open(build: "38") }
    #expect(throws: BoundedReplayStore.Failure.self) { try f.open(now: Date().addingTimeInterval(400)) }
    #expect(throws: BoundedReplayStore.Failure.self) { try f.open(now: Date().addingTimeInterval(-1000)) }
    #expect(FileManager.default.fileExists(atPath: f.permit.path))
}
@Test func boundedReplayRequiresExactlyTwoDistinctPinnedSamples() async throws {
    let f = try await ReplayFiles.make(); defer { f.remove() }
    for samples in [[], [f.request.samples[0]], f.request.samples + [f.request.samples[0]], [f.request.samples[0], f.request.samples[0]]] {
        let r = BoundedReplayRequest(schemaVersion: 1, runID: f.request.runID, appBuild: "39", promptRevision: CameraAnswer.promptRevision, expiresAt: f.request.expiresAt, samples: samples)
        #expect(throws: BoundedReplayStore.Failure.self) { try r.validate(runID: r.runID, build: "39", now: Date()) }
    }
}
@Test func boundedReplayChecksBothSourcesBeforeConsumingOrSending() async throws {
    let f = try await ReplayFiles.make(); defer { f.remove() }
    let image = f.history.appendingPathComponent(f.request.samples[1].id.uuidString + "/source.jpg")
    try Data([1,2,99]).write(to: image)
    #expect(throws: BoundedReplayStore.Failure.self) { try f.open() }
    #expect(FileManager.default.fileExists(atPath: f.permit.path))
    #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("runs").path))
}
@Test func boundedReplayRejectsChangedRecordsAndSymlinkImages() async throws {
    for symlink in [false,true] {
        let f = try await ReplayFiles.make(); defer { f.remove() }
        let folder = f.history.appendingPathComponent(f.request.samples[0].id.uuidString)
        if symlink {
            let file = folder.appendingPathComponent("source.jpg"), other = f.root.appendingPathComponent("other.jpg")
            try FileManager.default.moveItem(at: file, to: other)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        } else {
            let file = folder.appendingPathComponent("record.json")
            var data = try Data(contentsOf: file); data.append(10); try data.write(to: file)
        }
        #expect(throws: BoundedReplayStore.Failure.self) { try f.open() }
    }
}
@Test func boundedReplayCannotSendWhenDurableClaimWriteFails() async throws {
    let f = try await ReplayFiles.make(); defer { f.remove() }
    var writes = 0
    let run = try f.open(beforeWrite: { _ in writes += 1; if writes > 1 { throw CocoaError(.fileWriteOutOfSpace) } })
    #expect(throws: (any Error).self) { try run.claim(f.request.samples[0].id) }
    #expect(run.state.claimed.isEmpty)
    #expect(throws: BoundedReplayStore.Failure.self) { try run.validateClaim(f.request.samples[0].id) }
}
@Test func boundedReplayStopAndPermitTimeoutDisableRemainingSample() async throws {
    let f = try await ReplayFiles.make(); defer { f.remove() }
    let run = try f.open(); try run.claim(f.request.samples[0].id)
    #expect(throws: BoundedReplayStore.Failure.self) { try run.validateClaim(f.request.samples[0].id, now: Date().addingTimeInterval(400)) }
    try run.stop()
    #expect(throws: BoundedReplayStore.Failure.self) { try run.claim(f.request.samples[1].id) }
    #expect(run.originalsUnchanged())
}

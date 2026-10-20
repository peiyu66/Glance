import Foundation

/// An external, per-run permit. No private sample identifiers or image bytes are bundled.
public struct BoundedReplayRequest: Codable, Equatable, Sendable {
    public struct Sample: Codable, Equatable, Sendable {
        public let id: UUID
        public let sequence: Int
        public let recordSHA256: String
        public let imageSHA256: String
        public let imageByteCount: Int
    }
    public let schemaVersion: Int
    public let runID: UUID
    public let appBuild: String
    public let promptRevision: String
    public let expiresAt: Double
    public let samples: [Sample]

    public func validate(runID: UUID, build: String, now: Date) throws {
        func hash(_ value: String) -> Bool { value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }
        guard schemaVersion == 1, self.runID == runID, appBuild == build,
              promptRevision == CameraAnswer.promptRevision, expiresAt.isFinite,
              expiresAt > now.timeIntervalSince1970, expiresAt <= now.timeIntervalSince1970 + 900,
              samples.count == 2, Set(samples.map(\.id)).count == 2,
              Set(samples.map(\.sequence)).count == 2,
              samples.allSatisfy({ $0.sequence > 0 && hash($0.recordSHA256) && hash($0.imageSHA256) && (1...8_000_000).contains($0.imageByteCount) }) else {
            throw BoundedReplayStore.Failure.invalidPermit
        }
    }
}

/// Synchronous durable claims are made on the replay coordinator's main actor before a request.
/// The request is moved away before execution; an existing run directory can never be resumed.
public final class BoundedReplayStore {
    public enum Failure: Error { case invalidPermit, alreadyConsumed, sourceMismatch, exhausted, stopped }
    public struct Prepared: Sendable {
        public let source: ArchivedRecognition
        public let jpeg: Data
    }
    public struct State: Codable, Equatable, Sendable {
        public let runID: UUID
        public let requestSHA256: String
        public var claimed: [UUID] = []
        public var finished: [UUID] = []
        public var terminal = false
    }
    public let request: BoundedReplayRequest
    public let prepared: [Prepared]
    public let runDirectory: URL
    public private(set) var state: State
    private let historyRoot: URL
    private let beforeWrite: (URL) throws -> Void

    public init(requestURL: URL, runsRoot: URL, historyRoot: URL, runID: UUID,
                expectedRequestSHA256: String, build: String, now: Date = Date(),
                beforeWrite: @escaping (URL) throws -> Void = { _ in }) throws {
        let raw = try Self.regularFile(requestURL, maximum: 8192)
        guard RecognitionArchive.hash(raw) == expectedRequestSHA256 else { throw Failure.invalidPermit }
        let request = try JSONDecoder().decode(BoundedReplayRequest.self, from: raw)
        try request.validate(runID: runID, build: build, now: now)
        let run = runsRoot.appendingPathComponent(runID.uuidString, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: run.path) else { throw Failure.alreadyConsumed }
        let prepared = try request.samples.map { sample -> Prepared in
            let folder = historyRoot.appendingPathComponent(sample.id.uuidString, isDirectory: true)
            let properties = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard properties.isDirectory == true, properties.isSymbolicLink != true else { throw Failure.sourceMismatch }
            let recordData = try Self.regularFile(folder.appendingPathComponent("record.json"), maximum: 1_000_000)
            let source = try JSONDecoder().decode(ArchivedRecognition.self, from: recordData)
            let jpeg = try Self.regularFile(folder.appendingPathComponent("source.jpg"), maximum: 8_000_000)
            guard RecognitionArchive.hash(recordData) == sample.recordSHA256,
                  source.id == sample.id, source.sequence == sample.sequence,
                  source.status == .succeeded, source.result?.sourceImageID == sample.id,
                  source.imageSHA256 == sample.imageSHA256, source.imageByteCount == sample.imageByteCount,
                  jpeg.count == sample.imageByteCount, RecognitionArchive.hash(jpeg) == sample.imageSHA256 else { throw Failure.sourceMismatch }
            return Prepared(source: source, jpeg: jpeg)
        }
        self.request = request; self.prepared = prepared; self.runDirectory = run
        self.historyRoot = historyRoot; self.beforeWrite = beforeWrite
        self.state = State(runID: runID, requestSHA256: expectedRequestSHA256)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        try Self.protect(run)
        // No fall-back to the original request if either the move or state write fails.
        try FileManager.default.moveItem(at: requestURL, to: run.appendingPathComponent("request.json"))
        try Self.protect(run.appendingPathComponent("request.json"))
        try persist(state)
    }
    public func claim(_ sourceID: UUID, now: Date = Date()) throws {
        guard !state.terminal else { throw Failure.stopped }
        guard request.expiresAt > now.timeIntervalSince1970,
              request.samples.contains(where: { $0.id == sourceID }),
              !state.claimed.contains(sourceID), state.claimed.count < 2 else { throw Failure.exhausted }
        var next = state; next.claimed.append(sourceID)
        try persist(next); state = next
    }
    public func validateClaim(_ sourceID: UUID, now: Date = Date()) throws {
        guard !state.terminal, request.expiresAt > now.timeIntervalSince1970,
              state.claimed.contains(sourceID), !state.finished.contains(sourceID) else { throw Failure.stopped }
    }
    public func finish(_ sourceID: UUID) throws {
        guard state.claimed.contains(sourceID), !state.finished.contains(sourceID) else { throw Failure.exhausted }
        var next = state; next.finished.append(sourceID)
        try persist(next); state = next
    }
    public func stop() throws { var next = state; next.terminal = true; try persist(next); state = next }
    public func originalsUnchanged() -> Bool {
        request.samples.allSatisfy { sample in
            let folder = historyRoot.appendingPathComponent(sample.id.uuidString)
            guard let record = try? Self.regularFile(folder.appendingPathComponent("record.json"), maximum: 1_000_000),
                  let image = try? Self.regularFile(folder.appendingPathComponent("source.jpg"), maximum: 8_000_000) else { return false }
            return RecognitionArchive.hash(record) == sample.recordSHA256 && RecognitionArchive.hash(image) == sample.imageSHA256
        }
    }
    private func persist(_ next: State) throws {
        let url = runDirectory.appendingPathComponent("state.json")
        try beforeWrite(url)
        try Self.write(try JSONEncoder().encode(next), to: url)
    }
    public static func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try protect(url)
    }
    private static func regularFile(_ url: URL, maximum: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let count = values.fileSize, count > 0, count <= maximum else { throw Failure.sourceMismatch }
        let data = try Data(contentsOf: url)
        guard data.count == count else { throw Failure.sourceMismatch }; return data
    }
    private static func protect(_ url: URL) throws {
        var value = URLResourceValues(); value.isExcludedFromBackup = true
        var target = url; try target.setResourceValues(value)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
}

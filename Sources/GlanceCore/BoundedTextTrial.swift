import Foundation

/// The executable pins the four bodies; the external permit supplies only time and run identity.
public struct TextTrialCase: Codable, Equatable, Sendable {
    public let sequence: Int
    public let bodySHA256: String
    public let byteCount: Int
    public init(sequence: Int, bodySHA256: String, byteCount: Int) {
        self.sequence = sequence; self.bodySHA256 = bodySHA256; self.byteCount = byteCount
    }
}
public struct TextTrialPermit: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let runID: UUID
    public let appBuild: String
    public let catalogSHA256: String
    public let issuedAt: Double
    public let expiresAt: Double
    public let consentRevision: String
    public let allowsFourTextRequests: Bool
    public let allowsExistingGrantRefresh: Bool
    public let maximumRefreshRequests: Int
    public let maximumRequests: Int
    public let maximumOutputTokens: Int
}
public enum TextTrialContract {
    public static let revision = "W1-text-trial-refresh-v2"
    public static let maxOutputTokens = 8192
    public static let maxRequests = 4
    public static func catalogHash(_ cases: [TextTrialCase]) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return RecognitionArchive.hash(try encoder.encode(cases))
    }
    /// Validates the frozen wire format without rebuilding or normalizing its bytes.
    public static func sources(in body: Data) throws -> [WikipediaReviewSource] {
        guard body.count <= 128_000,
              let value = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              Set(value.keys) == ["model", "reasoning", "store", "stream", "text", "input", "max_output_tokens"],
              value["model"] as? String == "gpt-6-luna", value["store"] as? Bool == false, value["stream"] as? Bool == true,
              value["max_output_tokens"] as? Int == maxOutputTokens,
              (value["reasoning"] as? NSDictionary) == ["effort": "none"] as NSDictionary,
              let text = value["text"] as? [String: Any], Set(text.keys) == ["format"],
              (text["format"] as? NSDictionary) == WikipediaSemanticReview.legacyFormatW1 as NSDictionary,
              let input = value["input"] as? [[String: Any]], input.count == 2 else { throw TextTrialStore.Failure.invalidBody }
        var texts: [String] = []
        for (index, item) in input.enumerated() {
            guard Set(item.keys) == ["role", "content"], item["role"] as? String == (index == 0 ? "developer" : "user"),
                  let content = item["content"] as? [[String: String]], content.count == 1,
                  Set(content[0].keys) == ["type", "text"], content[0]["type"] == "input_text", let string = content[0]["text"] else { throw TextTrialStore.Failure.invalidBody }
            texts.append(string)
        }
        guard texts[0] == WikipediaSemanticReview.legacyPromptW1,
              let payload = try JSONSerialization.jsonObject(with: Data(texts[1].utf8)) as? [String: Any],
              Set(payload.keys) == ["input_version", "stage_one", "raw_stage_one_json", "sources"], payload["input_version"] as? Int == 1,
              let rows = payload["sources"] as? [[String: Any]], (1...3).contains(rows.count) else { throw TextTrialStore.Failure.invalidBody }
        let sources = try rows.map { row -> WikipediaReviewSource in
            guard Set(row.keys) == ["source_id", "title", "url", "partial", "excerpts"],
                  let id = row["source_id"] as? String, id.hasPrefix("zhwiki:"), let pageID = Int(id.dropFirst(7)),
                  let title = row["title"] as? String, let rawURL = row["url"] as? String, let url = URL(string: rawURL),
                  let partial = row["partial"] as? Bool, let excerpts = row["excerpts"] as? [[String: String]],
                  excerpts.allSatisfy({ Set($0.keys) == ["excerpt_id", "text"] }) else { throw TextTrialStore.Failure.invalidBody }
            let source = WikipediaReviewSource(pageID: pageID, title: title, url: url, fetchedAt: Date(timeIntervalSince1970: 0),
                excerpts: excerpts.map { .init(id: $0["excerpt_id"]!, text: $0["text"]!) }, partial: partial)
            guard source.valid else { throw TextTrialStore.Failure.invalidBody }; return source
        }
        guard Set(sources.map(\.id)).count == sources.count else { throw TextTrialStore.Failure.invalidBody }
        return sources
    }
}

/// Used on the main actor by the trial coordinator. Never opens the recognition archive.
public final class TextTrialStore {
    public enum Failure: String, Error { case invalidPermit, invalidBody, sourceMismatch, alreadyConsumed, exhausted, stopped }
    public struct Prepared: Sendable {
        public let spec: TextTrialCase
        public let body: Data
        public let sources: [WikipediaReviewSource]
    }
    public struct State: Codable, Equatable, Sendable {
        public let runID: UUID
        public let permitSHA256: String
        public var claimed: [Int] = []
        public var finished: [Int] = []
        public var refreshClaimed = false
        public var terminal = false
    }
    public let permit: TextTrialPermit
    public let prepared: [Prepared]
    public let runDirectory: URL
    public private(set) var state: State
    private let beforeWrite: (URL) throws -> Void
    public init(base: URL, runID: UUID, permitSHA256: String, build: String, cases: [TextTrialCase], now: Date = Date(),
                beforeWrite: @escaping (URL) throws -> Void = { _ in }) throws {
        guard cases.count == 4, Set(cases.map(\.sequence)).count == 4,
              cases.allSatisfy({ $0.sequence > 0 && (1...128_000).contains($0.byteCount) && $0.bodySHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }) else { throw Failure.invalidPermit }
        try Self.directory(base); let input = base.appendingPathComponent("input", isDirectory: true); try Self.directory(input)
        let raw = try Self.file(base.appendingPathComponent("permit.json"), maximum: 4096)
        guard RecognitionArchive.hash(raw) == permitSHA256 else { throw Failure.invalidPermit }
        let permit = try JSONDecoder().decode(TextTrialPermit.self, from: raw)
        guard permit.schemaVersion == 2, permit.runID == runID, permit.appBuild == build,
              permit.catalogSHA256 == (try TextTrialContract.catalogHash(cases)),
              permit.consentRevision == TextTrialContract.revision, permit.allowsFourTextRequests,
              permit.allowsExistingGrantRefresh, permit.maximumRefreshRequests == 1,
              permit.maximumRequests == 4, permit.maximumOutputTokens == TextTrialContract.maxOutputTokens,
              permit.issuedAt.isFinite, permit.expiresAt.isFinite, permit.issuedAt <= now.timeIntervalSince1970,
              permit.expiresAt > now.timeIntervalSince1970, permit.expiresAt - permit.issuedAt <= 900 else { throw Failure.invalidPermit }
        self.prepared = try cases.map { spec in
            let body = try Self.file(input.appendingPathComponent("\(spec.sequence).json"), maximum: 128_000)
            guard body.count == spec.byteCount, RecognitionArchive.hash(body) == spec.bodySHA256 else { throw Failure.sourceMismatch }
            return Prepared(spec: spec, body: body, sources: try TextTrialContract.sources(in: body))
        }
        let runs = base.appendingPathComponent("runs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: runs.path) { try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: false) }
        try Self.directory(runs)
        let run = runs.appendingPathComponent(runID.uuidString, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: run.path) else { throw Failure.alreadyConsumed }
        self.permit = permit; self.runDirectory = run; self.beforeWrite = beforeWrite
        self.state = State(runID: runID, permitSHA256: permitSHA256)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: base.appendingPathComponent("permit.json"), to: run.appendingPathComponent("permit.json"))
        try persist(state) // A failure still consumes the run; there is no fallback or resume.
    }
    /// Persist before a refresh POST; consumed even when its response or save fails.
    public func claimRefresh(now: Date = Date()) throws {
        guard !state.terminal, permit.expiresAt > now.timeIntervalSince1970,
              permit.allowsExistingGrantRefresh, permit.maximumRefreshRequests == 1,
              !state.refreshClaimed, state.claimed.isEmpty else { throw Failure.exhausted }
        var next = state; next.refreshClaimed = true; try persist(next); state = next
    }
    public func claim(_ sequence: Int, now: Date = Date()) throws {
        guard !state.terminal, permit.expiresAt > now.timeIntervalSince1970,
              state.claimed.count < prepared.count, state.claimed.count == state.finished.count,
              prepared[state.claimed.count].spec.sequence == sequence else { throw Failure.exhausted }
        var next = state; next.claimed.append(sequence); try persist(next); state = next
    }
    public func validateClaim(_ sequence: Int, now: Date = Date()) throws {
        guard !state.terminal, permit.expiresAt > now.timeIntervalSince1970,
              state.claimed.last == sequence, !state.finished.contains(sequence) else { throw Failure.stopped }
    }
    public func finish(_ sequence: Int) throws {
        try validateClaim(sequence)
        var next = state; next.finished.append(sequence); try persist(next); state = next
    }
    public func stop() throws { state.terminal = true; try persist(state) }
    public func save(_ data: Data, name: String) throws {
        guard name.range(of: "^[a-z0-9-]+\\.json$", options: .regularExpression) != nil else { throw Failure.sourceMismatch }
        let file = runDirectory.appendingPathComponent(name); try beforeWrite(file); try BoundedReplayStore.write(data, to: file)
    }
    private func persist(_ value: State) throws { try save(try JSONEncoder().encode(value), name: "state.json") }
    private static func directory(_ url: URL) throws {
        let v = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]); guard v.isDirectory == true, v.isSymbolicLink != true else { throw Failure.sourceMismatch }
    }
    private static func file(_ url: URL, maximum: Int) throws -> Data {
        let v = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard v.isRegularFile == true, v.isSymbolicLink != true, let size = v.fileSize, size > 0, size <= maximum else { throw Failure.sourceMismatch }
        let data = try Data(contentsOf: url); guard data.count == size else { throw Failure.sourceMismatch }; return data
    }
}

import Foundation

public struct RecognitionResult: Codable, Equatable, Hashable, Sendable {
    public var usesEntitySearch: Bool { [14, 15, 16, 17].contains(searchContractVersion ?? -1) }
    public let names: [String]
    public let summary: String
    public let text: [String]
    public let barcodes: [String]
    public let sourceImageID: UUID?
    public let searchContractVersion: Int?
    public let searchCandidates: [SearchCandidate]?
    public let searchEntities: [SearchEntity]?
    public let entityDiagnostics: [EntitySearchDiagnostic]?
    public let candidateQRFields: [String: String]?
    public let candidateDiagnostics: [CandidateSearchDiagnostic]?
    public let searchQuery: PublicSearchQuery?
    public let searchRestriction: ManualSearchRestriction?
    public let searchIdentity: SearchIdentity?
    public let searchDiagnostic: SearchParseDiagnostic?
    public let textWikipediaPolicy: SearchIdentity.WikipediaPolicy?
    public let textWikipediaCandidates: [TextWikipediaCandidate]?
    public let textWikipediaCandidateStatus: WikipediaCandidateStatus?
    public let wikipediaTopics: WikipediaTopics?
    public let wikipediaCandidateStatus: WikipediaCandidateStatus?
    public init(names: [String] = [], summary: String = "", text: [String] = [], barcodes: [String] = [], sourceImageID: UUID? = nil, searchQuery: PublicSearchQuery? = nil, wikipediaTopics: WikipediaTopics? = nil, searchRestriction: ManualSearchRestriction? = nil, wikipediaCandidateStatus: WikipediaCandidateStatus? = nil, searchIdentity: SearchIdentity? = nil, searchDiagnostic: SearchParseDiagnostic? = nil, textWikipediaPolicy: SearchIdentity.WikipediaPolicy? = nil, textWikipediaCandidates: [TextWikipediaCandidate]? = nil, textWikipediaCandidateStatus: WikipediaCandidateStatus? = nil, searchContractVersion: Int? = nil, searchCandidates: [SearchCandidate]? = nil, candidateQRFields: [String: String]? = nil, candidateDiagnostics: [CandidateSearchDiagnostic]? = nil, searchEntities: [SearchEntity]? = nil, entityDiagnostics: [EntitySearchDiagnostic]? = nil) {
        self.searchEntities = searchEntities; self.entityDiagnostics = entityDiagnostics
        self.searchContractVersion = searchContractVersion; self.searchCandidates = searchCandidates
        self.candidateQRFields = candidateQRFields; self.candidateDiagnostics = candidateDiagnostics
        self.names = names; self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines); self.text = text; self.barcodes = barcodes
        self.sourceImageID = sourceImageID; self.searchQuery = searchQuery; self.wikipediaTopics = wikipediaTopics
        self.searchRestriction = searchRestriction
        self.wikipediaCandidateStatus = wikipediaCandidateStatus
        self.searchIdentity = searchIdentity; self.searchDiagnostic = searchDiagnostic
        self.textWikipediaPolicy = textWikipediaPolicy; self.textWikipediaCandidates = textWikipediaCandidates
        self.textWikipediaCandidateStatus = textWikipediaCandidateStatus
    }
    enum CodingKeys: String, CodingKey { case searchEntities, entityDiagnostics, searchContractVersion, searchCandidates, candidateQRFields, candidateDiagnostics, names, summary, text, barcodes, sourceImageID, searchQuery, wikipediaTopics, searchRestriction, wikipediaCandidateStatus, searchIdentity, searchDiagnostic, textWikipediaPolicy, textWikipediaCandidates, textWikipediaCandidateStatus }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        searchContractVersion = values.contains(.searchContractVersion) ? ((try? values.decode(Int.self, forKey: .searchContractVersion)) ?? -1) : nil
        searchEntities = try? values.decodeIfPresent([SearchEntity].self, forKey: .searchEntities)
        entityDiagnostics = try? values.decodeIfPresent([EntitySearchDiagnostic].self, forKey: .entityDiagnostics)
        searchCandidates = try? values.decodeIfPresent([SearchCandidate].self, forKey: .searchCandidates)
        candidateQRFields = try? values.decodeIfPresent([String: String].self, forKey: .candidateQRFields)
        candidateDiagnostics = try? values.decodeIfPresent([CandidateSearchDiagnostic].self, forKey: .candidateDiagnostics)
        names = try values.decode([String].self, forKey: .names)
        summary = try values.decode(String.self, forKey: .summary)
        text = try values.decode([String].self, forKey: .text)
        barcodes = try values.decode([String].self, forKey: .barcodes)
        sourceImageID = try values.decodeIfPresent(UUID.self, forKey: .sourceImageID)
        searchQuery = try values.decodeIfPresent(PublicSearchQuery.self, forKey: .searchQuery)
        if values.contains(.searchRestriction), (try? values.decodeNil(forKey: .searchRestriction)) != true {
            searchRestriction = (try? values.decode(ManualSearchRestriction.self, forKey: .searchRestriction)) ?? .invalidRestriction
        } else { searchRestriction = nil }
        // Optional new hints must not make an older or damaged card unreadable.
        searchIdentity = try? values.decodeIfPresent(SearchIdentity.self, forKey: .searchIdentity)
        searchDiagnostic = try? values.decodeIfPresent(SearchParseDiagnostic.self, forKey: .searchDiagnostic)
        textWikipediaPolicy = try? values.decodeIfPresent(SearchIdentity.WikipediaPolicy.self, forKey: .textWikipediaPolicy)
        textWikipediaCandidates = try? values.decodeIfPresent([TextWikipediaCandidate].self, forKey: .textWikipediaCandidates)
        textWikipediaCandidateStatus = try? values.decodeIfPresent(WikipediaCandidateStatus.self, forKey: .textWikipediaCandidateStatus)
        wikipediaTopics = try? values.decodeIfPresent(WikipediaTopics.self, forKey: .wikipediaTopics)
        wikipediaCandidateStatus = try? values.decodeIfPresent(WikipediaCandidateStatus.self, forKey: .wikipediaCandidateStatus)
    }
    public func withSourceImage(_ id: UUID) -> Self { .init(names:names,summary:summary,text:text,barcodes:barcodes,sourceImageID:id,searchQuery:searchQuery,wikipediaTopics:wikipediaTopics,searchRestriction:searchRestriction,wikipediaCandidateStatus:wikipediaCandidateStatus,searchIdentity:searchIdentity,searchDiagnostic:searchDiagnostic,textWikipediaPolicy:textWikipediaPolicy,textWikipediaCandidates:textWikipediaCandidates,textWikipediaCandidateStatus:textWikipediaCandidateStatus,searchContractVersion:searchContractVersion,searchCandidates:searchCandidates,candidateQRFields:candidateQRFields,candidateDiagnostics:candidateDiagnostics,searchEntities:searchEntities,entityDiagnostics:entityDiagnostics) }
    public func withSummary(_ value: String) -> Self { .init(names:names,summary:value,text:text,barcodes:barcodes,sourceImageID:sourceImageID,searchQuery:searchQuery,wikipediaTopics:wikipediaTopics,searchRestriction:searchRestriction,wikipediaCandidateStatus:wikipediaCandidateStatus,searchIdentity:searchIdentity,searchDiagnostic:searchDiagnostic,textWikipediaPolicy:textWikipediaPolicy,textWikipediaCandidates:textWikipediaCandidates,textWikipediaCandidateStatus:textWikipediaCandidateStatus,searchContractVersion:searchContractVersion,searchCandidates:searchCandidates,candidateQRFields:candidateQRFields,candidateDiagnostics:candidateDiagnostics,searchEntities:searchEntities,entityDiagnostics:entityDiagnostics) }
    public func withBarcodes(_ values: [String]) -> Self { .init(names:names,summary:summary,text:text,barcodes:values,sourceImageID:sourceImageID,searchQuery:searchQuery,wikipediaTopics:wikipediaTopics,searchRestriction:searchRestriction,wikipediaCandidateStatus:wikipediaCandidateStatus,searchIdentity:searchIdentity,searchDiagnostic:searchDiagnostic,textWikipediaPolicy:textWikipediaPolicy,textWikipediaCandidates:textWikipediaCandidates,textWikipediaCandidateStatus:textWikipediaCandidateStatus,searchContractVersion:searchContractVersion,searchCandidates:searchCandidates,candidateQRFields:candidateQRFields,candidateDiagnostics:candidateDiagnostics,searchEntities:searchEntities,entityDiagnostics:entityDiagnostics) }
    public var lines: [String] { (names + [summary] + text + barcodes).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    /// Share only this immutable result, keeping existing text, Unicode and line breaks intact.
    public var shareText: String {
        let sections: [(String?, [String])] = [(nil, names), (nil, [summary]), ("【原文】", text), ("【條碼】", barcodes)]
        return sections.compactMap { title, values in
            let present = values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !present.isEmpty else { return nil }
            return (title.map { $0 + "\n\n" } ?? "") + present.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

/// Text/history contain only an opaque ID. Original request bytes have separate bounded storage.
public struct RecognitionSourceImages {
    public let maximumCount: Int
    public let maximumBytes: Int
    private var images: [UUID:Data] = [:]
    private var order: [UUID] = []
    public private(set) var byteCount = 0
    public var count: Int { images.count }
    public init(maximumCount:Int = 12, maximumBytes:Int = 8 * 1024 * 1024) {
        self.maximumCount=max(0,maximumCount);self.maximumBytes=max(0,maximumBytes)
    }
    public func image(for id:UUID?) -> Data? { id.flatMap { images[$0] } }
    @discardableResult public mutating func insert(_ data:Data, for id:UUID) -> Bool {
        guard images[id] == nil, !data.isEmpty, maximumCount > 0, data.count <= maximumBytes else { return false }
        while count >= maximumCount || byteCount + data.count > maximumBytes {
            let oldest=order.removeFirst();byteCount -= images.removeValue(forKey:oldest)!.count
        }
        images[id]=data;order.append(id);byteCount += data.count;return true
    }
    public mutating func removeAll() { images.removeAll();order.removeAll();byteCount=0 }
}

/// A user-initiated share owns one exact JPEG file until the system activity finishes.
public final class RecognitionShareFile {
    public static var directory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("GlanceShareSources",isDirectory:true) }
    public let url:URL
    public init(jpeg:Data, directory:URL = RecognitionShareFile.directory) throws {
        let folder=directory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        url=folder.appendingPathComponent("Glance-辨識來源.jpg")
        do { try jpeg.write(to:url,options:.atomic) }
        catch { try? FileManager.default.removeItem(at:folder);throw error }
    }
    public func finish() { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
    /// Call once at process startup before creating any live shares, scoped to our own namespace.
    public static func removeOrphans(directory:URL = RecognitionShareFile.directory) {
        try? FileManager.default.removeItem(at:directory)
    }
}

/// Target IDs are supplied by the on-device matcher; this core does not recognize images.
public struct RecognitionState {
    public struct Request: Equatable, Sendable {
        public let id: UUID
        public let target: String
    }
    public var stableDuration: TimeInterval
    public let capacity: Int
    public private(set) var visible: RecognitionResult?
    public private(set) var lastGate = "unobserved"
    public private(set) var stableElapsed: TimeInterval = 0
    private var current: String?
    private var since: TimeInterval = 0
    private var displaySince: TimeInterval?
    private var cache: [String: RecognitionResult] = [:]
    private var attempted: Set<String> = []
    private var order: [String] = []
    private var created: [String: TimeInterval] = [:]
    private var pending: [String: Request] = [:]

    public init(stableDuration: TimeInterval = 1, capacity: Int = 8) {
        self.stableDuration = max(0, stableDuration); self.capacity = max(1, capacity)
    }
    /// Caller supplies monotonic time and nil immediately when the center loses its target.
    public mutating func observe(_ target: String?, at time: TimeInterval, allowRequest: Bool = true, allowDisplay: Bool = true) -> Request? {
        for (id, stamp) in created where time - stamp >= 90 {
            cache.removeValue(forKey: id); attempted.remove(id); pending.removeValue(forKey: id); created.removeValue(forKey: id); order.removeAll { $0 == id }
        }
        if target != current {
            current = target; since = time; visible = nil; displaySince = nil
        }
        if !allowDisplay || target == nil { displaySince = nil }
        else if displaySince == nil { displaySince = time }
        stableElapsed = target == nil ? 0 : max(0, time - since)
        guard let target else { lastGate = "no-target"; return nil }
        visible = nil
        guard stableElapsed >= stableDuration else { lastGate = "stabilizing"; return nil }
        if let result = cache[target] {
            guard allowDisplay, let displaySince, time-displaySince >= stableDuration else {
                lastGate = "cached-evidence-incomplete"; return nil
            }
            visible = result; lastGate = "cached-visible"; return nil
        }
        guard allowRequest else { lastGate = "admission-blocked"; return nil }
        guard !attempted.contains(target) else { lastGate = "already-attempted"; return nil }
        lastGate = "request-ready"
        attempted.insert(target); order.append(target); created[target] = time
        while order.count > capacity {
            let old = order.removeFirst()
            cache.removeValue(forKey: old); attempted.remove(old); pending.removeValue(forKey: old); created.removeValue(forKey: old)
        }
        let request = Request(id: UUID(), target: target)
        pending[target] = request
        return request
    }
    /// Encoding failed before any provider call. Release only this pending token;
    /// stale tokens cannot undo a newer attempt or a completed result.
    public mutating func releaseUnsent(_ request: Request) {
        guard pending[request.target] == request else { return }
        pending.removeValue(forKey: request.target); attempted.remove(request.target)
        created.removeValue(forKey: request.target); order.removeAll { $0 == request.target }
    }
    public mutating func interruptAcquisitionForFocus() {
        current = nil; displaySince = nil; stableElapsed = 0; lastGate = "focus-changed"
    }
    /// nil/empty/error is silent and deduplicated until eviction or foreground reset.
    public mutating func complete(_ request: Request, result: RecognitionResult?) {
        guard pending[request.target] == request else { return }
        pending.removeValue(forKey: request.target)
        guard let result, !result.lines.isEmpty else { return }
        cache[request.target] = result
        // observe() owns visibility, including stability on returning to a cached target.
    }
    public mutating func leaveForeground() {
        current = nil; visible = nil; displaySince = nil; cache.removeAll(); attempted.removeAll()
        pending.removeAll(); order.removeAll(); created.removeAll()
    }
}

/// Stage-one acquisition only. An episode is continuous viewing, never a cache identity.
/// This type cannot display or cache a result. Sent budget survives capture restarts.
public struct FirstCaptureGate {
    public struct Request: Equatable, Sendable {
        public let id: UUID
        public let generation: UUID
        public let episode: UUID
        public let capturedAt: TimeInterval
    }
    public private(set) var generation = UUID()
    public private(set) var episode: UUID?
    public private(set) var stableElapsed: TimeInterval = 0
    public private(set) var gate = "unobserved"
    public private(set) var sentCount = 0
    public private(set) var completedCount = 0
    public private(set) var discardedCount = 0
    public private(set) var lastDistance: Float?
    public let stableDuration: TimeInterval
    public let maximumAge: TimeInterval
    public let limit: Int
    public private(set) var invalidationCount = 0
    public private(set) var lastInvalidationReason: String?
    public private(set) var lastInvalidationDistance: Float?
    private let threshold: Float = 0.035
    private var anchor: SceneFingerprint?
    private var previous: SceneFingerprint?
    private var beganAt: TimeInterval = 0
    private var lastCapturedAt: TimeInterval?
    private var pending: Request?
    private var submitted = false
    public init(stableDuration: TimeInterval = 1, maximumAge: TimeInterval = 0.75, limit: Int = 1) {
        self.stableDuration = max(0, stableDuration)
        self.maximumAge = max(0, maximumAge); self.limit = max(0, limit)
    }
    public mutating func invalidate(_ reason: String) {
        invalidationCount += 1; lastInvalidationReason = reason
        lastInvalidationDistance = reason == "scene-changed" ? lastDistance : nil
        episode = nil; anchor = nil; previous = nil; lastCapturedAt = nil
        stableElapsed = 0; lastDistance = nil; gate = reason
    }
    public mutating func stop() {
        generation = UUID(); invalidate("stopped")
        if !submitted { pending = nil }
        // Submitted transport retains its slot until its completion/cancellation returns.
    }
    public mutating func observe(_ fingerprint: SceneFingerprint?, capturedAt: TimeInterval, now: TimeInterval) -> Request? {
        guard now.isFinite, capturedAt.isFinite, now >= capturedAt, now-capturedAt <= maximumAge else {
            invalidate("stale-frame"); return nil
        }
        guard let fingerprint, fingerprint.usable else { invalidate("invalid-frame"); return nil }
        if let lastCapturedAt {
            guard capturedAt > lastCapturedAt else { invalidate("out-of-order-frame"); return nil }
            if capturedAt-lastCapturedAt > maximumAge { invalidate("frame-gap") }
        }
        if let anchor, let previous {
            let distance = max(fingerprint.distance(to: anchor, allowRotation: false), fingerprint.distance(to: previous, allowRotation: false))
            lastDistance = distance
            if !distance.isFinite || distance > threshold { invalidate("scene-changed") }
        }
        if episode == nil {
            episode = UUID(); anchor = fingerprint; beganAt = capturedAt
            gate = "stabilizing"
        }
        previous = fingerprint; lastCapturedAt = capturedAt
        stableElapsed = capturedAt-beganAt
        guard stableElapsed >= stableDuration else { gate = "stabilizing"; return nil }
        guard pending == nil else { gate = "inflight-or-encoding"; return nil }
        guard sentCount < limit else { gate = "lifetime-request-limit"; return nil }
        let request = Request(id: UUID(), generation: generation, episode: episode!, capturedAt: capturedAt)
        pending = request; submitted = false; gate = "snapshot-ready"
        return request
    }
    /// Encoding does not spend the request budget; an aged snapshot cannot be sent.
    public mutating func markSent(_ request: Request, at time: TimeInterval) -> Bool {
        guard pending == request, !submitted, request.generation == generation,
              request.episode == episode, time.isFinite, time >= request.capturedAt,
              time-request.capturedAt <= maximumAge, sentCount < limit else {
            releaseUnsent(request); return false
        }
        submitted = true; sentCount += 1; gate = "request-started"; return true
    }
    public mutating func releaseUnsent(_ request: Request) {
        guard pending == request, !submitted else { return }
        pending = nil; gate = "encoding-failed-or-expired"
    }
    public mutating func releaseBeforeImageSend(_ request: Request) {
        guard pending == request else { return }
        if submitted { sentCount = max(0, sentCount - 1) }
        pending = nil; submitted = false; invalidate("focus-changed-before-send")
    }
    /// Completion is transport evidence only, never permission to show a result.
    @discardableResult public mutating func complete(_ request: Request) -> Bool {
        guard pending == request, submitted else { return false }
        pending = nil; submitted = false
        guard request.generation == generation else { discardedCount += 1; gate = "discarded-after-stop"; return false }
        completedCount += 1; gate = "response-finished-display-disabled"; return true
    }
}

/// A one-shot visibility lease for a still-continuous view of the submitted image.
/// It never creates a request or reacquires a result after uncertainty.
public struct CurrentDisplayGate {
    public private(set) var visible: RecognitionResult?
    public private(set) var reason = "unbound"
    public private(set) var revoked = false
    public private(set) var lastVerifiedAt: TimeInterval?
    private var request: FirstCaptureGate.Request?
    private var result: RecognitionResult?
    private var completedAt: TimeInterval?
    private let maximumAge: TimeInterval
    public init(maximumAge: TimeInterval = 0.75) { self.maximumAge = max(0, maximumAge) }
    public mutating func bind(_ request: FirstCaptureGate.Request) {
        self.request = request; result = nil; visible = nil; completedAt = nil
        revoked = false; lastVerifiedAt = request.capturedAt; reason = "awaiting-response"
    }
    public mutating func revoke(_ reason: String) {
        revoked = true; visible = nil; result = nil; self.reason = reason
    }
    public mutating func stop() { revoke("stopped"); request = nil; completedAt = nil; lastVerifiedAt = nil }
    /// Arrival alone cannot present a result, even when the submitted frame is recent.
    public mutating func complete(_ request: FirstCaptureGate.Request, result: RecognitionResult?, at time: TimeInterval) {
        guard self.request == request, !revoked, time.isFinite else { return }
        guard let result, !result.lines.isEmpty else { revoke("empty-or-failed"); return }
        self.result = result; completedAt = time; visible = nil; reason = "awaiting-post-response-frame"
    }
    public mutating func observe(matchesSnapshot: Bool?, capturedAt: TimeInterval, now: TimeInterval, generation: UUID) {
        guard let request, !revoked else { return }
        guard request.generation == generation else { revoke("generation-changed"); return }
        guard now.isFinite, capturedAt.isFinite, capturedAt >= request.capturedAt, now >= capturedAt, now-capturedAt <= maximumAge else { revoke("stale-frame"); return }
        if let lastVerifiedAt {
            guard capturedAt > lastVerifiedAt else { revoke("out-of-order-frame"); return }
            guard capturedAt-lastVerifiedAt <= maximumAge else { revoke("frame-gap"); return }
        }
        guard let matchesSnapshot else { revoke("unknown-evidence"); return }
        guard matchesSnapshot else { revoke("snapshot-mismatch"); return }
        lastVerifiedAt = capturedAt
        guard let result, let completedAt, capturedAt > completedAt else { visible = nil; reason = "awaiting-post-response-frame"; return }
        visible = result; reason = "verified-current-result"
    }
    public mutating func expire(at time: TimeInterval) {
        guard request != nil, !revoked, let lastVerifiedAt else { return }
        if !time.isFinite || time-lastVerifiedAt > maximumAge { revoke("frame-timeout") }
    }
}

/// Successful answers only, kept in memory and ordered by captured request sequence.
/// Arrival order never changes which answer is latest. No image data is retained.
public struct RecognitionHistory: Sendable {
    public struct Entry: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let sequence: Int
        public let capturedAt: TimeInterval
        public let completedAt: TimeInterval
        public let result: RecognitionResult
        public init(id: UUID, sequence: Int, capturedAt: TimeInterval, completedAt: TimeInterval, result: RecognitionResult) {
            self.id=id;self.sequence=sequence;self.capturedAt=capturedAt;self.completedAt=completedAt;self.result=result
        }
    }
    public private(set) var entries: [Entry] = []
    public var latest: Entry? { entries.last }
    private let capacity: Int?
    public init(capacity: Int? = 3) { self.capacity=capacity.map { max(0,$0) } }
    @discardableResult public mutating func insert(_ entry: Entry) -> Bool {
        guard entry.sequence > 0, entry.capturedAt.isFinite, entry.completedAt.isFinite,
              entry.completedAt >= entry.capturedAt, !entry.result.lines.isEmpty,
              capacity.map({ entries.count < $0 }) ?? true, !entries.contains(where: { $0.id == entry.id || $0.sequence == entry.sequence }) else { return false }
        entries.append(entry);entries.sort { $0.sequence < $1.sequence };return true
    }
    public mutating func clear() { entries.removeAll() }
}

/// Current-view queries. Adoption is independent of the single transport slot.
/// Uses the passed first-capture stability rule; episodes are never cache identities.
public struct LiveRecognitionSession {
    public struct Intent: Equatable, Sendable {
        public let id: UUID
        public let generation: UUID
        public let episode: UUID
        public let adoptedAt: TimeInterval
    }
    public struct Request: Equatable, Sendable {
        public let intent: Intent
        public let sequence: Int
        public let batchSequence: Int
        public let snapshotCapturedAt: TimeInterval
        public let startedAt: TimeInterval
    }
    public private(set) var generation = UUID()
    public private(set) var queuedIntent: Intent?
    public private(set) var inflightRequest: Request?
    public private(set) var history: RecognitionHistory
    public private(set) var references = FixedReferenceCatalog()
    private var selectedHistoryID: UUID?
    private var verifiedReferenceID: UUID?
    public var visible: RecognitionResult? { history.entries.first { $0.id == visibleRequestID }?.result }
    private var displayedRequest: Request?
    private var displayedVerifiedCurrent = false
    public var visibleRequestID: UUID? { selectedHistoryID ?? history.latest?.id }
    public var visibleIsPrevious: Bool {
        visible != nil && (!displayedVerifiedCurrent || (verifiedReferenceID != visibleRequestID && (displayedRequest?.intent.id != visibleRequestID || displayedRequest?.intent.generation != generation || displayedRequest?.intent.episode != stability.episode)))
    }
    public private(set) var adoptedCount = 0
    /// Attempts in the current user-controlled batch. Manual pause resets only this count.
    public private(set) var sentCount = 0
    public private(set) var lifetimeSentCount = 0
    public private(set) var completedCount = 0
    public private(set) var discardedCount = 0
    public private(set) var gate = "unobserved"
    public private(set) var lastEpisodeReason = "unobserved"
    public private(set) var lastEpisodeDistance: Float?
    public private(set) var lastCompletionReason = "not-completed"
    public private(set) var lastCompletionFrameAge: TimeInterval?
    public var lastObservedAt: TimeInterval? { lastCapturedAt }
    public let limit: Int
    private var stability = FirstCaptureGate(limit: 0)
    private var adoptedEpisode: UUID?
    private var lastCapturedAt: TimeInterval?
    private var response: (request: Request, completedAt: TimeInterval)?
    public var episode: UUID? { stability.episode }
    public var stableElapsed: TimeInterval { stability.stableElapsed }
    public var lastDistance: Float? { stability.lastDistance }
    public init(limit: Int = 3) { self.limit = max(0, limit);history=RecognitionHistory(capacity:nil) }

    /// End current eligibility while retaining the last committed card in foreground.
    private mutating func clearCurrentEligibility() {
        queuedIntent = nil; response = nil; displayedVerifiedCurrent = false; verifiedReferenceID = nil
        adoptedEpisode = nil; lastCapturedAt = nil
    }
    /// Returns a newly adopted intent even while an older transport is in flight.
    @discardableResult public mutating func observe(_ fingerprint: SceneFingerprint?, capturedAt: TimeInterval, now: TimeInterval, sceneChangeReason: String? = nil, matchingReferenceIDs: [UUID] = [], evaluatedReferenceIDs: Set<UUID>? = nil) -> Intent? {
        references.expire(at: now)
        if verifiedReferenceID != nil { displayedVerifiedCurrent = false; verifiedReferenceID = nil }
        let previousEpisode = stability.episode
        let previousInvalidations = stability.invalidationCount
        if let sceneChangeReason { stability.invalidate(sceneChangeReason) }
        _ = stability.observe(fingerprint, capturedAt: capturedAt, now: now)
        if stability.episode != previousEpisode {
            lastEpisodeReason = stability.invalidationCount != previousInvalidations ? (stability.lastInvalidationReason ?? "unknown") : "initial-view"
            lastEpisodeDistance = stability.invalidationCount != previousInvalidations ? stability.lastInvalidationDistance : nil
            clearCurrentEligibility()
        }
        guard let episode = stability.episode else { gate = stability.gate; return nil }
        lastCapturedAt = capturedAt
        if let evaluatedReferenceIDs, evaluatedReferenceIDs != Set(references.entries.map(\.id)) {
            if queuedIntent != nil { adoptedEpisode = nil }
            queuedIntent = nil; gate = "awaiting-reference-evaluation"; return nil
        }
        if let reference = references.uniqueMatch(matchingReferenceIDs, generation: generation) {
            if queuedIntent != nil { adoptedEpisode = nil }
            queuedIntent = nil
            if reference.status == .answered, history.entries.contains(where: { $0.id == reference.id }) {
                selectedHistoryID = reference.id; verifiedReferenceID = reference.id; displayedVerifiedCurrent = true
                gate = "fixed-reference-reused"
            } else { gate = "same-reference-pending" }
            return nil
        }
        if let response, response.request.intent.generation == generation,
           response.request.intent.episode == episode, capturedAt > response.completedAt,
           visibleRequestID == response.request.intent.id {
            displayedVerifiedCurrent = true
        }
        guard stability.stableElapsed >= stability.stableDuration else { gate = "stabilizing"; return nil }
        guard adoptedEpisode != episode else {
            gate = queuedIntent != nil ? "adopted-awaiting-transport" : (visible == nil ? "episode-already-adopted" : "current-result-visible")
            return nil
        }
        guard sentCount < limit else { gate = "batch-request-limit"; return nil }
        let intent = Intent(id: UUID(), generation: generation, episode: episode, adoptedAt: capturedAt)
        adoptedEpisode = episode; queuedIntent = intent; adoptedCount += 1
        gate = "intent-adopted"; return intent
    }
    /// Encode the latest observed frame before calling. Waiting does not retain an old JPEG.
    public mutating func startRequest(snapshotCapturedAt: TimeInterval, at time: TimeInterval, referenceAvailable: Bool = false) -> Request? {
        guard let intent = queuedIntent, inflightRequest == nil, sentCount < limit,
              intent.generation == generation, intent.episode == stability.episode,
              snapshotCapturedAt == lastCapturedAt, time.isFinite, time >= snapshotCapturedAt,
              time-snapshotCapturedAt <= stability.maximumAge else { return nil }
        let request = Request(intent: intent, sequence: lifetimeSentCount+1, batchSequence: sentCount+1, snapshotCapturedAt: snapshotCapturedAt, startedAt: time)
        if referenceAvailable { references.begin(id: request.intent.id, generation: generation, capturedAt: snapshotCapturedAt, now: time) }
        queuedIntent = nil; inflightRequest = request; sentCount += 1; lifetimeSentCount += 1; gate = "request-started"
        return request
    }
    /// Failed encoding remains deduplicated for this episode and spends no budget.
    public mutating func discardQueuedIntent() { queuedIntent = nil; gate = "encoding-failed" }
    /// Focus loss invalidates only acquisition. Paid references/history and inflight
    /// work belong to the same session generation and remain eligible to complete.
    public mutating func interruptAcquisitionForFocus() {
        stability.invalidate("focus-changed"); clearCurrentEligibility()
        lastEpisodeReason = "focus-changed"; lastEpisodeDistance = nil; gate = "focus-changed"
    }
    /// Only used for a proven rejection before the image transport starts.
    /// Sequence IDs remain monotonic; no actual sent request is refunded.
    public mutating func releaseBeforeImageSend(_ request: Request, at time: TimeInterval) {
        guard inflightRequest == request else { return }
        inflightRequest = nil
        references.complete(id: request.intent.id, generation: request.intent.generation, accepted: false, now: time)
        if request.intent.generation == generation { sentCount = max(0, sentCount - 1) }
        interruptAcquisitionForFocus()
    }
    /// Success is readable as history in the same active generation. Only a later
    /// fresh same-episode frame may label the latest answer as current.
    @discardableResult public mutating func complete(_ request: Request, result: RecognitionResult?, at time: TimeInterval) -> Bool {
        guard inflightRequest == request else { lastCompletionReason = "unknown-or-duplicate-request"; return false }
        inflightRequest = nil; completedCount += 1
        // A failed, invalid or old-generation answer must never promote a pending identity.
        var promoteReference = false
        defer { references.complete(id: request.intent.id, generation: request.intent.generation, accepted: promoteReference, now: time) }
        lastCompletionFrameAge = lastCapturedAt.map { time-$0 }
        expire(at: time)
        guard request.intent.generation == generation else {
            discardedCount += 1
            lastCompletionReason = "generation-stopped"
            gate = "discarded-stopped-generation"; return false
        }
        guard let result, !result.lines.isEmpty else { lastCompletionReason = "empty-or-failed"; gate = "empty-or-failed"; return false }
        let entry=RecognitionHistory.Entry(id:request.intent.id,sequence:request.sequence,capturedAt:request.snapshotCapturedAt,completedAt:time,result:result)
        guard history.insert(entry) else { lastCompletionReason="duplicate-or-invalid-history";return false }
        promoteReference = true
        if history.latest?.id == request.intent.id && !(displayedVerifiedCurrent && verifiedReferenceID != nil && verifiedReferenceID != request.intent.id) {
            selectedHistoryID = request.intent.id; verifiedReferenceID = nil
            displayedRequest=request;displayedVerifiedCurrent=false
            response = (request, time)
        }
        lastCompletionReason = request.intent.episode == stability.episode ? "accepted-history-awaiting-new-frame" : "accepted-history-ended-episode"
        gate = "successful-answer-recorded"
        return true
    }
    public mutating func expire(at time: TimeInterval) {
        references.expire(at: time)
        if let verifiedReferenceID, !references.entries.contains(where: { $0.id == verifiedReferenceID }) {
            self.verifiedReferenceID = nil; displayedVerifiedCurrent = false
        }
        guard let lastCapturedAt else { return }
        if !time.isFinite || time < lastCapturedAt || time-lastCapturedAt > stability.maximumAge {
            stability.invalidate("frame-timeout"); clearCurrentEligibility(); gate = "frame-timeout"
            lastEpisodeReason = "frame-timeout"; lastEpisodeDistance = nil
        }
    }
    /// Memory pressure evicts optical payload eligibility, never paid-for text.
    /// A pending transport may still finish into history, but cannot recreate a reference.
    public mutating func purgeReferences() {
        references.clear(); verifiedReferenceID = nil; displayedVerifiedCurrent = false; response = nil
    }
    public mutating func stop(preservingHistory: Bool = false, resetBudget: Bool = false) {
        generation = UUID(); references.clear(); stability.stop(); clearCurrentEligibility(); gate = "stopped"
        if !preservingHistory { history.clear();displayedRequest = nil;selectedHistoryID = nil }
        if resetBudget { sentCount = 0 }
        lastEpisodeReason = "stopped"; lastEpisodeDistance = nil
        // Keep the actual in-flight slot until transport returns. Sequence never resets.
    }
}

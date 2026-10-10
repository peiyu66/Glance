import Foundation

public struct RecognitionResult: Equatable, Hashable, Sendable {
    public let names: [String]
    public let summary: String
    public let text: [String]
    public let barcodes: [String]
    public init(names: [String] = [], summary: String = "", text: [String] = [], barcodes: [String] = []) {
        self.names = names; self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines); self.text = text; self.barcodes = barcodes
    }
    public var lines: [String] { (names + [summary] + text + barcodes).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
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
    private let capacity: Int
    public init(capacity: Int = 3) { self.capacity=max(0,capacity) }
    @discardableResult public mutating func insert(_ entry: Entry) -> Bool {
        guard entry.sequence > 0, entry.capturedAt.isFinite, entry.completedAt.isFinite,
              entry.completedAt >= entry.capturedAt, !entry.result.lines.isEmpty,
              entries.count < capacity, !entries.contains(where: { $0.id == entry.id || $0.sequence == entry.sequence }) else { return false }
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
        public let snapshotCapturedAt: TimeInterval
        public let startedAt: TimeInterval
    }
    public private(set) var generation = UUID()
    public private(set) var queuedIntent: Intent?
    public private(set) var inflightRequest: Request?
    public private(set) var history: RecognitionHistory
    public var visible: RecognitionResult? { history.latest?.result }
    private var displayedRequest: Request?
    private var displayedVerifiedCurrent = false
    public var visibleRequestID: UUID? { history.latest?.id }
    public var visibleIsPrevious: Bool {
        visible != nil && (!displayedVerifiedCurrent || displayedRequest?.intent.generation != generation || displayedRequest?.intent.episode != stability.episode)
    }
    public private(set) var adoptedCount = 0
    public private(set) var sentCount = 0
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
    public init(limit: Int = 3) { self.limit = max(0, limit);history=RecognitionHistory(capacity:max(0,limit)) }

    /// End current eligibility while retaining the last committed card in foreground.
    private mutating func clearCurrentEligibility() {
        queuedIntent = nil; response = nil; displayedVerifiedCurrent = false
        adoptedEpisode = nil; lastCapturedAt = nil
    }
    /// Returns a newly adopted intent even while an older transport is in flight.
    @discardableResult public mutating func observe(_ fingerprint: SceneFingerprint?, capturedAt: TimeInterval, now: TimeInterval, sceneChangeReason: String? = nil) -> Intent? {
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
        if let response, response.request.intent.generation == generation,
           response.request.intent.episode == episode, capturedAt > response.completedAt,
           history.latest?.id == response.request.intent.id {
            displayedVerifiedCurrent = true
        }
        guard stability.stableElapsed >= stability.stableDuration else { gate = "stabilizing"; return nil }
        guard adoptedEpisode != episode else {
            gate = queuedIntent != nil ? "adopted-awaiting-transport" : (visible == nil ? "episode-already-adopted" : "current-result-visible")
            return nil
        }
        guard sentCount < limit else { gate = "lifetime-request-limit"; return nil }
        let intent = Intent(id: UUID(), generation: generation, episode: episode, adoptedAt: capturedAt)
        adoptedEpisode = episode; queuedIntent = intent; adoptedCount += 1
        gate = "intent-adopted"; return intent
    }
    /// Encode the latest observed frame before calling. Waiting does not retain an old JPEG.
    public mutating func startRequest(snapshotCapturedAt: TimeInterval, at time: TimeInterval) -> Request? {
        guard let intent = queuedIntent, inflightRequest == nil, sentCount < limit,
              intent.generation == generation, intent.episode == stability.episode,
              snapshotCapturedAt == lastCapturedAt, time.isFinite, time >= snapshotCapturedAt,
              time-snapshotCapturedAt <= stability.maximumAge else { return nil }
        let request = Request(intent: intent, sequence: sentCount+1, snapshotCapturedAt: snapshotCapturedAt, startedAt: time)
        queuedIntent = nil; inflightRequest = request; sentCount += 1; gate = "request-started"
        return request
    }
    /// Failed encoding remains deduplicated for this episode and spends no budget.
    public mutating func discardQueuedIntent() { queuedIntent = nil; gate = "encoding-failed" }
    /// Success is readable as history in the same active generation. Only a later
    /// fresh same-episode frame may label the latest answer as current.
    @discardableResult public mutating func complete(_ request: Request, result: RecognitionResult?, at time: TimeInterval) -> Bool {
        guard inflightRequest == request else { lastCompletionReason = "unknown-or-duplicate-request"; return false }
        inflightRequest = nil; completedCount += 1
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
        if history.latest?.id == request.intent.id {
            displayedRequest=request;displayedVerifiedCurrent=false
            response = (request, time)
        }
        lastCompletionReason = request.intent.episode == stability.episode ? "accepted-history-awaiting-new-frame" : "accepted-history-ended-episode"
        gate = "successful-answer-recorded"
        return true
    }
    public mutating func expire(at time: TimeInterval) {
        guard let lastCapturedAt else { return }
        if !time.isFinite || time < lastCapturedAt || time-lastCapturedAt > stability.maximumAge {
            stability.invalidate("frame-timeout"); clearCurrentEligibility(); gate = "frame-timeout"
            lastEpisodeReason = "frame-timeout"; lastEpisodeDistance = nil
        }
    }
    public mutating func stop(preservingHistory: Bool = false) {
        generation = UUID(); stability.stop(); clearCurrentEligibility(); gate = "stopped"
        if !preservingHistory { history.clear();displayedRequest = nil }
        lastEpisodeReason = "stopped"; lastEpisodeDistance = nil
        // Keep the actual in-flight slot and spent budget until transport returns.
    }
}

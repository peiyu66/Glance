import Foundation

/// Relative detail evidence for one central ROI, not a measurement of lens focus.
/// Metrics come from OpenCV after a small, fixed Gaussian noise prefilter.
public struct CentralFocusQuality: Equatable, Sendable {
    public enum State: String, Sendable { case detail, blurred, unknown }
    public enum Reason: String, Sendable { case measured, softEdges, lowTexture, dark, bright, unavailable }
    public let state: State
    public let reason: Reason
    public let score: Double
    public let mean: Double
    public let variance: Double
    public let tenengrad: Double
    public let laplacianVariance: Double
    public static let unavailable = Self(mean: .nan, variance: .nan, tenengrad: .nan, laplacianVariance: .nan)

    public init(mean: Double, variance: Double, tenengrad: Double, laplacianVariance: Double) {
        self.mean = mean; self.variance = variance; self.tenengrad = tenengrad; self.laplacianVariance = laplacianVariance
        guard [mean, variance, tenengrad, laplacianVariance].allSatisfy(\.isFinite),
              (0...1).contains(mean), variance >= 0, tenengrad >= 0, laplacianVariance >= 0 else {
            state = .unknown; reason = .unavailable; score = 0; return
        }
        score = laplacianVariance / max(variance, 0.000001)
        if mean < 0.08 { state = .unknown; reason = .dark }
        else if mean > 0.94 { state = .unknown; reason = .bright }
        else if variance < 0.0025 || tenengrad < 0.00001 || tenengrad / max(variance, 0.000001) < 0.05 { state = .unknown; reason = .lowTexture }
        else if laplacianVariance / max(tenengrad, 0.000001) < 0.0025 {
            // Only broad, measurable edges support this soft-detail heuristic.
            // Flat, dark and unavailable measurements never become "blurred".
            state = .blurred; reason = .softEdges
        } else { state = .detail; reason = .measured }
    }
}

/// Bounded memory for the current button intent. It grants no request permission;
/// the existing one-second stability, focus, visible-frame and transport gates do.
public struct FocusCandidateSelector<Payload> {
    public struct Scope: Equatable, Sendable {
        public let session: UUID
        public let focusRevision: UInt64
        public let geometryRevision: UUID
        public init(session: UUID, focusRevision: UInt64, geometryRevision: UUID) {
            self.session = session; self.focusRevision = focusRevision; self.geometryRevision = geometryRevision
        }
    }
    private struct Candidate {
        let payload: Payload; let capturedAt: TimeInterval; let quality: CentralFocusQuality
    }
    public let hintDelay: TimeInterval
    public let candidateAge: TimeInterval
    private var beganAt: TimeInterval?
    private var scope: Scope?
    private var candidates: [Candidate] = []
    public private(set) var observedBlurredFrames = 0
    public init(hintDelay: TimeInterval = 3, candidateAge: TimeInterval = 0.5) {
        self.hintDelay = max(1, hintDelay.isFinite ? hintDelay : 3)
        self.candidateAge = min(0.5, max(0, candidateAge.isFinite ? candidateAge : 0.5))
    }
    public mutating func begin(at time: TimeInterval) {
        beganAt = time.isFinite ? time : nil; resetCandidates()
    }
    /// Epoch/scene changes clear only rolling samples, never delay the waiting hint.
    public mutating func resetCandidates() { scope = nil; candidates.removeAll(); observedBlurredFrames = 0 }
    public func needsWaitingHint(at now: TimeInterval) -> Bool {
        guard let beganAt, now.isFinite else { return false }
        return now - beganAt >= hintDelay
    }
    public mutating func observe(payload: Payload, capturedAt: TimeInterval, scope newScope: Scope,
                                 quality: CentralFocusQuality, sceneChanged: Bool = false, now: TimeInterval) {
        guard let beganAt, now.isFinite, capturedAt.isFinite, capturedAt > beganAt,
              capturedAt <= now, now - capturedAt <= candidateAge else { return }
        if scope != newScope || sceneChanged { resetCandidates(); scope = newScope }
        if let last = candidates.last, capturedAt <= last.capturedAt { return }
        if let last = candidates.last, capturedAt - last.capturedAt > candidateAge { observedBlurredFrames = 0 }
        let ageLimit = candidateAge
        candidates.removeAll { now - $0.capturedAt > ageLimit }
        candidates.append(Candidate(payload: payload, capturedAt: capturedAt, quality: quality))
        if candidates.count > 3 { candidates.removeFirst(candidates.count - 3) }
        if quality.state == .blurred { observedBlurredFrames += 1 }
        else { observedBlurredFrames = 0 }
    }
    public func selected(at now: TimeInterval, scope expectedScope: Scope) -> Payload? {
        guard scope == expectedScope, now.isFinite else { return nil }
        let fresh = candidates.filter { now >= $0.capturedAt && now - $0.capturedAt <= candidateAge }
        // Unknown is an honest fallback for low texture/low light, never a claim
        // of sharpness. A recently observed soft-edge sample is never selected.
        let detail = fresh.filter { $0.quality.state == .detail }
        if let maximum = detail.map({ $0.quality.score }).max(),
           let best = detail.last(where: { $0.quality.score >= maximum * 0.95 }) { return best.payload }
        return fresh.last(where: { $0.quality.state == .unknown })?.payload
    }
}

/// Text-only diagnosis for one acquisition intent. Rolling frame resets must not
/// erase it; scene/geometry/intent changes must. This never grants capture access.
public struct CaptureAcquisitionFeedback: Equatable, Sendable {
    public enum Reason: Sendable { case unknown, autofocus, blurred, motion }
    public private(set) var reason: Reason = .unknown
    public init() {}
    public mutating func reset() { reason = .unknown }
    public mutating func autofocusChanged() { reason = .autofocus }
    public mutating func sceneMoved() { reason = .motion }
    public mutating func observe(_ quality: CentralFocusQuality, repeatedBlurredFrames: Int) {
        if quality.state == .blurred {
            if repeatedBlurredFrames >= 3 { reason = .blurred }
        } else if reason == .autofocus || reason == .blurred {
            // A current usable/unknown sample supersedes the old focus diagnosis.
            reason = .unknown
        }
    }
    public var waitingMessage: String {
        switch reason {
        case .autofocus, .blurred:
            "正在等待對焦，請將手機稍微拉遠，停穩 1 秒後會自動辨識一張。"
        case .motion:
            "畫面仍在變動，請保持手機與目標穩定，停穩 1 秒後會自動辨識一張。"
        case .unknown:
            "正在等待穩定圖片，請調整光線或位置，停穩 1 秒後會自動辨識一張。"
        }
    }
}

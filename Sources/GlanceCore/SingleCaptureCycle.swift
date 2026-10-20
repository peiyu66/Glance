import Foundation

/// A user gesture grants one reservation. Preview lifetime is independent of transport.
public struct SingleCaptureCycle {
    public enum Preview: Equatable { case closed, open, expired }
    public enum Phase: Equatable { case idle, acquiring, preparing(UUID), waiting(UUID) }
    public private(set) var preview: Preview = .closed
    public private(set) var phase: Phase = .idle
    public private(set) var deadline: TimeInterval?
    private var stability = FirstCaptureGate()
    public var stableElapsed: TimeInterval { stability.stableElapsed }
    public var stabilityInvalidationCount: Int { stability.invalidationCount }
    public var lastStabilityInvalidationReason: String? { stability.lastInvalidationReason }
    public var activeID: UUID? {
        switch phase { case .preparing(let id), .waiting(let id): id; default: nil }
    }
    public var canContinue: Bool { preview == .open && phase == .idle }
    public var analyzesFrames: Bool { preview == .open && phase == .acquiring }
    public init() {}
    public mutating func openPreview(at now: TimeInterval) {
        guard now.isFinite, preview != .open else { return }
        preview = .open; deadline = now + CaptureTimeLimit.seconds
    }
    @discardableResult public mutating func arm() -> Bool {
        guard canContinue else { return false }
        stability = FirstCaptureGate(stableDuration: 1, maximumAge: 0.75, limit: 1)
        phase = .acquiring; return true
    }
    /// A saved-image gesture spends the same exclusive slot without opening a camera.
    @discardableResult public mutating func reserveArchived(id: UUID) -> Bool {
        guard phase == .idle else { return false }
        phase = .preparing(id); return true
    }
    public mutating func interruptStability() { stability.invalidate("focus-or-scene-changed") }
    public mutating func cancelAcquisition() {
        guard phase == .acquiring else { return }
        phase = .idle; stability.invalidate("user-cancelled")
    }
    public mutating func reserve(_ fingerprint: SceneFingerprint?, capturedAt: TimeInterval,
                                 now: TimeInterval, sceneChanged: Bool = false) -> UUID? {
        guard analyzesFrames else { return nil }
        if sceneChanged { interruptStability() }
        guard let ticket = stability.observe(fingerprint, capturedAt: capturedAt, now: now),
              stability.markSent(ticket, at: now) else { return nil }
        phase = .preparing(ticket.id); return ticket.id
    }
    @discardableResult public mutating func waiting(id: UUID) -> Bool {
        guard phase == .preparing(id) else { return false }
        phase = .waiting(id); return true
    }
    @discardableResult public mutating func finish(id: UUID) -> Bool {
        guard activeID == id else { return false }
        phase = .idle; return true
    }
    public mutating func closePreview(expired: Bool = false) {
        preview = expired ? .expired : .closed; deadline = nil
        if phase == .acquiring { phase = .idle }
        stability.invalidate("preview-closed")
        // A reserved/sent request owns its slot until its original completion.
    }
    @discardableResult public mutating func expire(at now: TimeInterval) -> Bool {
        guard preview == .open, let deadline, now >= deadline else { return false }
        closePreview(expired: true); return true
    }
}

/// A user scroll grants one preview reopen when it reaches the top. Its
/// deceleration is still that interaction; programmatic/data changes are not.
public struct HistoryPreviewPull {
    public static let topTolerance: Double = 1
    public private(set) var active = false
    private var eligible = false
    private var consumed = false
    private var awaitingNewGesture = false
    public init() {}
    /// Only a new recognizer .began releases the return-to-latest barrier.
    public mutating func newGestureBegan() { self = Self() }
    public mutating func returnToLatest() {
        awaitingNewGesture = true; eligible = false
    }
    public mutating func begin(canReopen: Bool) {
        guard !active, !awaitingNewGesture else { return }
        active = true; eligible = canReopen; consumed = false
    }
    public mutating func update(distanceFromTop: Double, movingTowardTop: Bool, isManualScroll: Bool) -> Bool {
        guard active, eligible, !consumed, !awaitingNewGesture, isManualScroll, movingTowardTop,
              distanceFromTop.isFinite, distanceFromTop <= Self.topTolerance else { return false }
        consumed = true; return true
    }
    public mutating func invalidateForProgrammaticChange() { eligible = false }
    public mutating func end() {
        active = false; eligible = false; consumed = false
        // Cancellation, detachment and a prior gesture's tail cannot release
        // the button's barrier. Only a subsequent physical gesture can.
    }
}

/// The first card may be tall or partially visible. Show the shortcut only
/// after its bottom has passed the viewport top, with an 8-point hysteresis.
public struct HistoryLatestVisibility {
    public private(set) var visible = false
    public init() {}
    public mutating func update(firstRowBottom: Double?, laterRowAtTop: Bool, scrollable: Bool, atTop: Bool) {
        guard scrollable, !atTop else { visible = false; return }
        if let bottom = firstRowBottom, bottom.isFinite {
            if bottom < -8 { visible = true }
            else if bottom > 8 { visible = false }
        } else {
            // Lazy stacks may remove the first row. Require a later rendered
            // row at the top instead of inferring visibility from record count.
            visible = laterRowAtTop
        }
    }
}

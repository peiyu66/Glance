import Foundation

/// One explicitly started viewing session, including temporary background/settings time.
public struct CaptureTimeLimit: Sendable {
    public static let seconds: TimeInterval = 300
    public private(set) var deadline: TimeInterval?
    public private(set) var expired = false
    public init() {}
    /// Repeated starts cannot extend an existing session.
    @discardableResult public mutating func begin(at now: TimeInterval) -> Bool {
        guard deadline == nil, now.isFinite else { return false }
        deadline = now + Self.seconds; expired = false; return true
    }
    public mutating func manualPause() { deadline = nil; expired = false }
    @discardableResult public mutating func expireIfNeeded(at now: TimeInterval) -> Bool {
        guard let deadline, now >= deadline else { return false }
        self.deadline = nil; expired = true; return true
    }
}

/// ContinuousClock is monotonic and includes time while the device sleeps.
public enum CaptureContinuousTime {
    private static let origin = ContinuousClock.now
    public static func now() -> TimeInterval {
        let parts = origin.duration(to: ContinuousClock.now).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

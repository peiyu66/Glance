import Foundation

/// KVO updates this gate synchronously; actor delivery must not decide eligibility.
/// This records focus activity, not optical sharpness or exact sensor exposure time.
public final class CameraFocusGate: @unchecked Sendable {
    public enum Rejection: Error { case changedBeforeSend }
    public struct Snapshot: Equatable, Sendable {
        public let session: UUID
        public let revision: UInt64
        public let active: Bool
        public let autofocusSupported: Bool
        public let adjusting: Bool
        public let changedAt: TimeInterval
    }
    public struct Stamp: Equatable, Sendable {
        public let session: UUID
        public let revision: UInt64
        public let capturedAt: TimeInterval
    }
    private let lock = NSLock()
    private var state = Snapshot(session: UUID(), revision: 0, active: false,
                                 autofocusSupported: false, adjusting: false, changedAt: 0)
    public init() {}
    public var snapshot: Snapshot { lock.withLock { state } }
    @discardableResult public func begin(session: UUID, autofocusSupported: Bool, adjusting: Bool, at time: TimeInterval) -> Snapshot {
        lock.withLock {
            state = Snapshot(session: session, revision: state.revision &+ 1, active: time.isFinite,
                autofocusSupported: autofocusSupported, adjusting: autofocusSupported && adjusting, changedAt: time)
            return state
        }
    }
    @discardableResult public func update(adjusting: Bool, session: UUID, at time: TimeInterval) -> Snapshot {
        lock.withLock {
            guard state.active, state.session == session, time.isFinite, time >= state.changedAt else { return state }
            let next = state.autofocusSupported && adjusting
            guard state.adjusting != next else { return state }
            state = Snapshot(session: session, revision: state.revision &+ 1, active: true,
                autofocusSupported: state.autofocusSupported, adjusting: next, changedAt: time)
            return state
        }
    }
    public func stop() {
        lock.withLock {
            state = Snapshot(session: state.session, revision: state.revision &+ 1, active: false,
                autofocusSupported: state.autofocusSupported, adjusting: state.adjusting, changedAt: state.changedAt)
        }
    }
    /// PTS must be converted from AVCaptureSession.synchronizationClock to host time.
    /// Strictly newer PTS drops buffered samples from before the latest KVO event.
    public func stamp(capturedAt: TimeInterval) -> Stamp? {
        lock.withLock {
            guard state.active, !state.adjusting, capturedAt.isFinite, capturedAt > state.changedAt else { return nil }
            return Stamp(session: state.session, revision: state.revision, capturedAt: capturedAt)
        }
    }
    public func allows(_ stamp: Stamp) -> Bool {
        lock.withLock {
            state.active && !state.adjusting && stamp.session == state.session && stamp.revision == state.revision &&
                stamp.capturedAt.isFinite && stamp.capturedAt > state.changedAt
        }
    }
    public func requireCurrent(_ stamp: Stamp) throws {
        guard allows(stamp) else { throw Rejection.changedBeforeSend }
    }
}

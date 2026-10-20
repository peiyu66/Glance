import Foundation

/// Independent of preview and focus. Disable synchronously before another frame can publish.
public final class FrameAnalysisGate: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UUID?
    private var beganAt: TimeInterval = 0
    public init() {}
    public var enabled: Bool { lock.withLock { current != nil } }
    @discardableResult public func enable(at time: TimeInterval) -> UUID {
        lock.withLock { let id = UUID(); current = id; beganAt = time; return id }
    }
    public func disable() { lock.withLock { current = nil } }
    public func permit(capturedAt: TimeInterval) -> UUID? {
        lock.withLock { capturedAt.isFinite && capturedAt > beganAt ? current : nil }
    }
    public func accepts(_ id: UUID, capturedAt: TimeInterval) -> Bool {
        lock.withLock { current == id && capturedAt.isFinite && capturedAt > beganAt }
    }
}

/// The ordinary preview displays this exact data-output crop. There is no second
/// AVCaptureVideoPreviewLayer with an independently stabilized field of view.
public final class VisibleCaptureGate: @unchecked Sendable {
    public struct Stamp: Equatable, Sendable {
        public let revision: UUID
        public let viewport: CGSize
        public let capturedAt: TimeInterval
    }
    public enum Rejection: Error { case geometryChanged, staleFrame }
    /// Evidence that the frozen image was current when selected. It is not
    /// permission to send: callers still validate lifecycle, focus and account.
    public struct AcceptedImage: Sendable {
        fileprivate let stamp: Stamp
        fileprivate init(stamp: Stamp) { self.stamp = stamp }
    }
    private let lock = NSLock()
    private var revision = UUID()
    private var viewport: CGSize = .zero
    private var displayed: UUID?
    public init() {}
    @discardableResult public func resize(_ size: CGSize) -> UUID {
        lock.withLock {
            if viewport != size { viewport = size; revision = UUID(); displayed = nil }
            return revision
        }
    }
    public func invalidate() { lock.withLock { revision = UUID(); displayed = nil } }
    public func stamp(at time: TimeInterval) -> Stamp? {
        lock.withLock {
            guard viewport.width > 0, viewport.height > 0, time.isFinite else { return nil }
            return Stamp(revision: revision, viewport: viewport, capturedAt: time)
        }
    }
    public func markDisplayed(_ stamp: Stamp) -> Bool {
        lock.withLock { guard stamp.revision == revision else { return false }; displayed = revision; return true }
    }
    public func requireCurrent(_ stamp: Stamp, now: TimeInterval) throws {
        try lock.withLock {
            guard stamp.revision == revision, displayed == revision else { throw Rejection.geometryChanged }
            guard now.isFinite, now >= stamp.capturedAt, now - stamp.capturedAt <= 0.75 else { throw Rejection.staleFrame }
        }
    }
    public func acceptImage(_ stamp: Stamp, now: TimeInterval) throws -> AcceptedImage {
        try requireCurrent(stamp, now: now)
        return AcceptedImage(stamp: stamp)
    }
    public func requireUnchanged(_ image: AcceptedImage) throws {
        try lock.withLock {
            guard image.stamp.revision == revision, displayed == revision else { throw Rejection.geometryChanged }
        }
    }
    public static func crop(source: CGRect, viewport: CGSize) -> CGRect? {
        guard !source.isInfinite, !source.isNull, source.width > 0, source.height > 0,
              viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0, viewport.height > 0 else { return nil }
        let ratio = viewport.width / viewport.height
        let width = min(source.width, source.height * ratio)
        let height = width / ratio
        return CGRect(x: source.midX - width / 2, y: source.midY - height / 2, width: width, height: height)
    }
}

/// Conservative near-black classification on 256 luminance samples (0...255).
/// This is an obscured/empty-frame safeguard, not a low-light quality threshold.
public struct CameraDarknessMetrics: Sendable {
    public let mean: Double
    public let deviation: Double
    public let edge: Double
    public let span: Double
    public let maximum: Double
    public init?(luminance: [UInt8], side: Int = 16) {
        guard side >= 2, luminance.count == side * side else { return nil }
        let values = luminance.map(Double.init)
        mean = values.reduce(0, +) / Double(values.count)
        let average = mean
        deviation = sqrt(values.reduce(0) { $0 + ($1 - average) * ($1 - average) } / Double(values.count))
        maximum = values.max()!; span = maximum - values.min()!
        var edges = 0.0; var count = 0
        for y in 0..<side { for x in 0..<side {
            let i = y * side + x
            if x > 0 { edges += abs(values[i] - values[i - 1]); count += 1 }
            if y > 0 { edges += abs(values[i] - values[i - side]); count += 1 }
        } }
        edge = edges / Double(count)
    }
    public var nearBlack: Bool { mean <= 8 && deviation <= 2.5 && edge <= 2 && span <= 12 && maximum <= 16 }
}

/// Capture-queue observation and synchronous pre-send validation share one gate.
public final class CameraDarknessGate: @unchecked Sendable {
    public enum Decision: Equatable, Sendable { case inactive, clear, temporaryDark, closeCamera }
    public struct Stamp: Sendable { fileprivate let session: UUID; fileprivate let revision: UUID }
    public enum Rejection: Error { case changedBeforeSend }
    private let lock = NSLock()
    private var session: UUID?
    private var revision = UUID()
    private var firstSample: Double?
    private var lastSample: Double?
    private var darkSince: Double?
    private var blocked = false
    private var closed = false
    public init() {}
    public func begin(session: UUID) {
        lock.withLock {
            self.session = session; revision = UUID(); firstSample = nil; lastSample = nil
            darkSince = nil; blocked = false; closed = false
        }
    }
    public func stop() { lock.withLock { session = nil; revision = UUID(); blocked = false; closed = false } }
    public var isBlocked: Bool { lock.withLock { blocked || closed } }
    public func stamp(session: UUID) -> Stamp? {
        lock.withLock { self.session == session && !blocked && !closed ? Stamp(session: session, revision: revision) : nil }
    }
    public func requireCurrent(_ stamp: Stamp) throws {
        try lock.withLock {
            guard session == stamp.session, revision == stamp.revision, !blocked, !closed else { throw Rejection.changedBeforeSend }
        }
    }
    @discardableResult public func observe(_ metrics: CameraDarknessMetrics?, at now: Double, session expected: UUID) -> Decision {
        lock.withLock {
            guard session == expected, now.isFinite else { return .inactive }
            if closed { return .temporaryDark }
            if let lastSample, now <= lastSample { return blocked ? .temporaryDark : .clear }
            if firstSample == nil { firstSample = now }
            if let lastSample, now - lastSample > 0.6 { darkSince = nil }
            lastSample = now
            guard let metrics else { darkSince = nil; return blocked ? .temporaryDark : .clear }
            guard metrics.nearBlack else { blocked = false; darkSince = nil; return .clear }
            if !blocked { revision = UUID() }; blocked = true
            // Initial exposure/black startup frames cannot close a freshly opened session.
            guard now - firstSample! >= 0.75 else { darkSince = nil; return .temporaryDark }
            if darkSince == nil { darkSince = now }
            guard now - darkSince! >= 1 else { return .temporaryDark }
            closed = true; return .closeCamera
        }
    }
}

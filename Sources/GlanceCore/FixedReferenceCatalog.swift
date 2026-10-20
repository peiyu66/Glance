import Foundation

/// Metadata only. The capture worker owns immutable in-memory feature payloads.
/// Snapshot time, never completion or hit time, defines the bounded lifetime.
public struct FixedReferenceCatalog {
    public struct Entry: Equatable, Sendable {
        public enum Status: Sendable { case pending, answered }
        public let id: UUID
        public let generation: UUID
        public let capturedAt: TimeInterval
        public fileprivate(set) var status: Status
    }
    public private(set) var entries: [Entry] = []
    public let capacity: Int
    public let lifetime: TimeInterval
    public init(capacity: Int = 8, lifetime: TimeInterval = 90) {
        self.capacity = max(1, capacity)
        self.lifetime = lifetime.isFinite ? max(1, lifetime) : 90
    }
    public mutating func expire(at now: TimeInterval) {
        entries.removeAll { !now.isFinite || now < $0.capturedAt || now - $0.capturedAt >= lifetime }
    }
    @discardableResult public mutating func begin(id: UUID, generation: UUID, capturedAt: TimeInterval, now: TimeInterval) -> Bool {
        expire(at: now)
        guard capturedAt.isFinite, now.isFinite, now >= capturedAt, now - capturedAt < lifetime,
              !entries.contains(where: { $0.id == id || $0.status == .pending }) else { return false }
        if entries.count == capacity { entries.removeFirst() }
        entries.append(Entry(id: id, generation: generation, capturedAt: capturedAt, status: .pending))
        return true
    }
    public mutating func complete(id: UUID, generation: UUID, accepted: Bool, now: TimeInterval) {
        expire(at: now)
        guard let index = entries.firstIndex(where: { $0.id == id && $0.generation == generation && $0.status == .pending }) else { return }
        if accepted { entries[index].status = .answered } else { entries.remove(at: index) }
    }
    public func uniqueMatch(_ ids: [UUID], generation: UUID) -> Entry? {
        // A stale/ambiguous worker result cannot be reduced to a convenient winner.
        guard ids.count == 1 else { return nil }
        return entries.first { $0.id == ids[0] && $0.generation == generation }
    }
    public mutating func clear() { entries.removeAll() }
}

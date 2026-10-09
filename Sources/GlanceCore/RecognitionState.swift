import Foundation

public struct RecognitionResult: Equatable, Sendable {
    public let names: [String]
    public let text: [String]
    public let barcodes: [String]
    public init(names: [String] = [], text: [String] = [], barcodes: [String] = []) {
        self.names = names; self.text = text; self.barcodes = barcodes
    }
    public var lines: [String] { (names + text + barcodes).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
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
    private var current: String?
    private var since: TimeInterval = 0
    private var cache: [String: RecognitionResult] = [:]
    private var attempted: Set<String> = []
    private var order: [String] = []
    private var created: [String: TimeInterval] = [:]
    private var pending: [String: Request] = [:]

    public init(stableDuration: TimeInterval = 1, capacity: Int = 8) {
        self.stableDuration = max(0, stableDuration); self.capacity = max(1, capacity)
    }
    /// Caller supplies monotonic time and nil immediately when the center loses its target.
    public mutating func observe(_ target: String?, at time: TimeInterval, allowRequest: Bool = true) -> Request? {
        for (id, stamp) in created where time - stamp >= 90 {
            cache.removeValue(forKey: id); attempted.remove(id); pending.removeValue(forKey: id); created.removeValue(forKey: id); order.removeAll { $0 == id }
        }
        if target != current {
            current = target; since = time; visible = nil
        }
        guard let target else { return nil }
        visible = nil
        guard time - since >= stableDuration else { return nil }
        if let result = cache[target] { visible = result; return nil }
        guard allowRequest else { return nil }
        guard !attempted.contains(target) else { return nil }
        attempted.insert(target); order.append(target); created[target] = time
        while order.count > capacity {
            let old = order.removeFirst()
            cache.removeValue(forKey: old); attempted.remove(old); pending.removeValue(forKey: old); created.removeValue(forKey: old)
        }
        let request = Request(id: UUID(), target: target)
        pending[target] = request
        return request
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
        current = nil; visible = nil; cache.removeAll(); attempted.removeAll()
        pending.removeAll(); order.removeAll(); created.removeAll()
    }
}

import Foundation

/// Only synthetic callback validation. This is not an OAuth implementation.
public struct ProbeCallback: Sendable {
    private let state: String
    private var consumed = false
    public init(state: String) { self.state = state }
    public mutating func accept(target: String) -> Bool {
        guard !consumed, let url = URLComponents(string: target),
              url.scheme == nil, url.host == nil, url.fragment == nil,
              url.percentEncodedPath == "/auth/callback" else { return false }
        let items = url.queryItems ?? []
        guard items.count == 2,
              items.filter({ $0.name == "state" }).count == 1,
              items.filter({ $0.name == "code" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state,
              items.first(where: { $0.name == "code" })?.value == "probe-only" else { return false }
        consumed = true
        return true
    }
}

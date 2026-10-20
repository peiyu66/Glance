import Foundation

/// Local opt-in, independent of an OAuth credential or subscription name.
public struct DataConsent: Codable, Equatable, Sendable {
    public static let currentVersion = "2026-10-19.1"
    public private(set) var acceptedVersion: String?
    public private(set) var acceptedAt: Date?
    public private(set) var setupCompleted: Bool
    public init() { acceptedVersion = nil; acceptedAt = nil; setupCompleted = false }
    public var allowsTransfer: Bool { acceptedVersion == Self.currentVersion && acceptedAt != nil }
    public mutating func accept(at date: Date = Date(), accountReady: Bool) {
        acceptedVersion = Self.currentVersion; acceptedAt = date; setupCompleted = accountReady
    }
    public mutating func accountChanged(ready: Bool) { setupCompleted = allowsTransfer && ready }
    public mutating func withdraw() { self = Self() }
}

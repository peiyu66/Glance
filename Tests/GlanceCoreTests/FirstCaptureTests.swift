import Foundation
import Testing
@testable import GlanceCore

private func captureFingerprint(_ changed: Bool = false) -> SceneFingerprint {
    SceneFingerprint(rgb: (0..<(8*8*3)).map { i in ((i/3)%8 < 4) != changed ? 0.15 : 0.85 }, side: 8)
}
private func stableTicket(_ gate: inout FirstCaptureGate, start: Double = 0) throws -> FirstCaptureGate.Request {
    var ticket: FirstCaptureGate.Request?
    for i in 0...4 { ticket = gate.observe(captureFingerprint(), capturedAt: start+Double(i)*0.25, now: start+Double(i)*0.25) }
    return try #require(ticket)
}
@Test func firstCaptureNeedsOneSecondWithoutOCROrCacheIdentity() throws {
    var gate = FirstCaptureGate()
    for i in 0..<4 { #expect({ gate.observe(captureFingerprint(), capturedAt: Double(i)*0.25, now: Double(i)*0.25) == nil }()) }
    let candidate = gate.observe(captureFingerprint(), capturedAt: 1, now: 1)
    let ticket = try #require(candidate)
    #expect(gate.stableElapsed == 1 && gate.sentCount == 0)
    #expect({ gate.markSent(ticket, at: 1.01) }())
    for i in 5...36 { #expect({ gate.observe(captureFingerprint(), capturedAt: Double(i)*0.25, now: Double(i)*0.25) == nil }()) }
    #expect({ gate.complete(ticket) }()); #expect({ !gate.complete(ticket) }())
    #expect(gate.sentCount == 1 && gate.completedCount == 1)
}
@Test func firstCaptureRejectsStaleGapReorderedAndChangedFrames() {
    for mode in ["stale", "gap", "reordered", "changed", "invalid"] {
        var gate = FirstCaptureGate()
        _ = gate.observe(captureFingerprint(), capturedAt: 0, now: 0)
        _ = gate.observe(captureFingerprint(), capturedAt: 0.5, now: 0.5)
        switch mode {
        case "stale": _ = gate.observe(captureFingerprint(), capturedAt: 0.6, now: 1.36)
        case "gap": _ = gate.observe(captureFingerprint(), capturedAt: 1.5, now: 1.5)
        case "reordered": _ = gate.observe(captureFingerprint(), capturedAt: 0.4, now: 0.6)
        case "changed": _ = gate.observe(captureFingerprint(true), capturedAt: 0.75, now: 0.75)
        default: _ = gate.observe(nil, capturedAt: 0.75, now: 0.75)
        }
        #expect(gate.stableElapsed == 0)
        #expect(gate.sentCount == 0)
    }
}
@Test func firstCaptureBudgetSurvivesStopAndLateCompletion() throws {
    var gate = FirstCaptureGate()
    let ticket = try stableTicket(&gate); #expect({ gate.markSent(ticket, at: 1) }())
    gate.stop()
    for i in 8...16 { #expect({ gate.observe(captureFingerprint(), capturedAt: Double(i)*0.25, now: Double(i)*0.25) == nil }()) }
    #expect({ !gate.complete(ticket) }()); #expect(gate.discardedCount == 1)
    #expect({ gate.observe(captureFingerprint(), capturedAt: 4.25, now: 4.25) == nil }())
    #expect(gate.sentCount == 1 && gate.gate == "lifetime-request-limit")
}
@Test func firstCaptureEncodingFailureAndExpiredSnapshotSpendNoBudget() throws {
    var gate = FirstCaptureGate()
    let first = try stableTicket(&gate)
    gate.releaseUnsent(first)
    let candidate = gate.observe(captureFingerprint(), capturedAt: 1.25, now: 1.25)
    let second = try #require(candidate)
    gate.releaseUnsent(first)
    #expect({ !gate.markSent(second, at: 2.01) }())
    #expect(gate.sentCount == 0)
    gate.stop()
    let next = try stableTicket(&gate, start: 3)
    #expect({ gate.markSent(next, at: 4) }())
}

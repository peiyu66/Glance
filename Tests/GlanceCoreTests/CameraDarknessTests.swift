import Foundation
import Testing
@testable import GlanceCore

private func darkMetric(_ values: [UInt8]) -> CameraDarknessMetrics { CameraDarknessMetrics(luminance: values)! }
private let solidBlack = darkMetric(Array(repeating: 0, count: 256))
private let normalScene = darkMetric(Array(repeating: 80, count: 256))
@Test func darknessRequiresLowBrightnessAndNoDetailsTogether() {
    #expect(solidBlack.nearBlack)
    #expect(darkMetric((0..<256).map { UInt8($0 % 4) }).nearBlack)
    #expect(!normalScene.nearBlack)
    #expect(!darkMetric((0..<256).map { $0 % 2 == 0 ? 0 : 15 }).nearBlack)
    #expect(!darkMetric((0..<256).map { $0 == 128 ? 100 : 2 }).nearBlack)
    #expect(!darkMetric((0..<256).map { UInt8($0 % 30) }).nearBlack)
    #expect(CameraDarknessMetrics(luminance: []) == nil)
}
@Test func darknessStartupGraceThenOneSecondClosesOnlyOnce() {
    let gate = CameraDarknessGate(), id = UUID(); gate.begin(session: id)
    for t in stride(from: 0.0, through: 1.5, by: 0.25) { #expect(gate.observe(solidBlack, at: t, session: id) == .temporaryDark) }
    #expect(gate.observe(solidBlack, at: 1.75, session: id) == .closeCamera)
    #expect(gate.observe(normalScene, at: 2, session: id) == .temporaryDark)
    #expect(gate.isBlocked && gate.stamp(session: id) == nil)
}
@Test func darknessShortOcclusionAndExposureChangesResetContinuity() {
    let gate = CameraDarknessGate(), id = UUID(); gate.begin(session: id)
    #expect(gate.observe(solidBlack, at: 0, session: id) == .temporaryDark)
    #expect(gate.observe(normalScene, at: 0.25, session: id) == .clear)
    for t in [1.0, 1.25, 1.5] { #expect(gate.observe(solidBlack, at: t, session: id) == .temporaryDark) }
    #expect(gate.observe(normalScene, at: 1.75, session: id) == .clear)
    for t in [2.0, 2.25, 2.5, 2.75] { #expect(gate.observe(solidBlack, at: t, session: id) == .temporaryDark) }
    #expect(gate.observe(normalScene, at: 3, session: id) == .clear)
}
@Test func darknessStaleGapInvalidatesOldCaptureEvenAfterLightReturns() throws {
    let gate = CameraDarknessGate(), id = UUID(); gate.begin(session: id)
    _ = gate.observe(normalScene, at: 0, session: id)
    let stamp = try #require(gate.stamp(session: id)); try gate.requireCurrent(stamp)
    _ = gate.observe(solidBlack, at: 1, session: id)
    #expect(throws: CameraDarknessGate.Rejection.self) { try gate.requireCurrent(stamp) }
    _ = gate.observe(normalScene, at: 1.25, session: id)
    #expect(throws: CameraDarknessGate.Rejection.self) { try gate.requireCurrent(stamp) }
    _ = gate.observe(solidBlack, at: 2, session: id)
    #expect(gate.observe(solidBlack, at: 4, session: id) == .temporaryDark)
    #expect(gate.observe(nil, at: 4.25, session: id) == .temporaryDark)
    #expect(gate.observe(solidBlack, at: 4.5, session: id) == .temporaryDark)
    gate.stop(); #expect(gate.observe(solidBlack, at: 5, session: id) == .inactive)
    let next = UUID(); gate.begin(session: next)
    #expect(gate.observe(solidBlack, at: 6, session: id) == .inactive)
    #expect(gate.observe(normalScene, at: 6, session: next) == .clear)
}

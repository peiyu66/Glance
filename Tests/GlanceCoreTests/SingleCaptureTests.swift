import Foundation
import Testing
@testable import GlanceCore

private func stableC2Fingerprint() -> SceneFingerprint {
    SceneFingerprint(rgb: (0..<192).map { $0 % 2 == 0 ? 0.2 : 0.8 }, side: 8)
}
private func reserveC2(_ cycle: inout SingleCaptureCycle, start: Double = 0) -> UUID? {
    var id: UUID?
    for t in stride(from: start, through: start + 1, by: 0.25) {
        id = cycle.reserve(stableC2Fingerprint(), capturedAt: t, now: t) ?? id
    }
    return id
}
@Test func c2PreviewNeverGrantsAnalysis() {
    var c = SingleCaptureCycle(); c.openPreview(at: 0)
    #expect({ !c.analyzesFrames }()); #expect({ reserveC2(&c) == nil }())
    #expect({ c.preview == .open }()); #expect({ c.deadline == 300 }())
}
@Test func c2RequiresOneSecondAndOneGesturePerReservation() throws {
    var c = SingleCaptureCycle(); c.openPreview(at: 0); #expect({ c.arm() }())
    for t in [0.0, 0.25, 0.5, 0.75] { #expect({ c.reserve(stableC2Fingerprint(), capturedAt: t, now: t) == nil }()) }
    let id = try #require({ c.reserve(stableC2Fingerprint(), capturedAt: 1, now: 1) }())
    #expect({ !c.analyzesFrames }()); #expect({ !c.arm() }()); #expect({ c.preview == .open }())
    #expect({ reserveC2(&c, start: 2) == nil }()); #expect({ c.waiting(id: id) }()); #expect({ !c.arm() }())
    #expect({ c.finish(id: id) }()); #expect({ c.canContinue }()); #expect({ reserveC2(&c, start: 4) == nil }())
}
@Test func c2ExplicitContinuationsBeyondThreeKeepWorking() throws {
    var c = SingleCaptureCycle(); c.openPreview(at: 0)
    var ids = Set<UUID>()
    for i in 0..<8 {
        #expect({ c.arm() }()); let id = try #require({ reserveC2(&c, start: Double(i * 3)) }())
        #expect({ ids.insert(id).inserted }()); #expect({ c.waiting(id: id) }()); #expect({ c.finish(id: id) }())
    }
    #expect({ ids.count == 8 }()); #expect({ c.deadline == 300 }())
}
@Test func c2BackgroundStopsPreviewButRetainsActiveSlot() throws {
    var c = SingleCaptureCycle(); c.openPreview(at: 0); c.arm()
    let id = try #require({ reserveC2(&c) }()); c.waiting(id: id); c.closePreview()
    #expect({ c.preview == .closed }()); #expect({ c.activeID == id }()); #expect({ !c.arm() }())
    c.openPreview(at: 20); #expect({ !c.arm() }()); #expect({ c.finish(id: id) }()); #expect({ c.arm() }())
}
@Test func c2CameraExpiresWhileWaitingAndResultCanStillComplete() throws {
    var c = SingleCaptureCycle(); c.openPreview(at: 0); c.arm()
    let id = try #require({ reserveC2(&c) }()); c.waiting(id: id)
    #expect({ !c.expire(at: 299.99) }()); #expect({ c.expire(at: 300) }()); #expect({ c.preview == .expired }())
    #expect({ !c.arm() }()); #expect({ c.finish(id: id) }()); #expect({ !c.canContinue }())
    c.openPreview(at: 500); #expect({ c.deadline == 800 }()); #expect({ c.canContinue }())
}
@Test func c2CancelAndRepeatedStartCannotExtendCameraBudget() {
    var c = SingleCaptureCycle(); c.openPreview(at: 10); c.arm(); c.cancelAcquisition()
    c.openPreview(at: 200); #expect({ c.deadline == 310 }()); #expect({ c.arm() }())
    c.closePreview(); #expect({ c.phase == .idle }()); #expect({ !c.analyzesFrames }())
}
@Test func c2LateWrongOrDuplicateCompletionsCannotReleaseNewRequest() throws {
    var c = SingleCaptureCycle(); c.openPreview(at: 0); c.arm()
    let a = try #require({ reserveC2(&c) }()); c.waiting(id: a); c.finish(id: a); c.arm()
    let b = try #require({ reserveC2(&c, start: 3) }()); c.waiting(id: b)
    #expect({ !c.finish(id: a) }()); #expect({ !c.finish(id: UUID()) }()); #expect({ c.activeID == b }())
}
@Test func c2FocusOrSceneChangeRestartsFullStableInterval() {
    var c = SingleCaptureCycle(); c.openPreview(at: 0); c.arm()
    for t in [0.0,0.25,0.5,0.75] { _ = c.reserve(stableC2Fingerprint(), capturedAt: t, now: t) }
    c.interruptStability()
    for t in [1.0,1.25,1.5,1.75] { #expect({ c.reserve(stableC2Fingerprint(), capturedAt: t, now: t) == nil }()) }
    #expect({ c.reserve(stableC2Fingerprint(), capturedAt: 2, now: 2) != nil }())
}
@Test func c2StaleFramesCannotSpendIntent() {
    var c = SingleCaptureCycle(); c.openPreview(at: 0); c.arm()
    for t in [0.0,0.25,0.5,0.75,1] { #expect({ c.reserve(stableC2Fingerprint(), capturedAt: t, now: t + 1) == nil }()) }
    #expect({ c.analyzesFrames }())
}
@Test func c2AnalysisGateRejectsBufferedAndPreviousIntentFrames() throws {
    let gate = FrameAnalysisGate(); #expect({ !gate.enabled }())
    let a = gate.enable(at: 10); #expect({ gate.permit(capturedAt: 10) == nil }())
    #expect({ gate.permit(capturedAt: 10.1) == a }()); gate.disable()
    #expect({ !gate.accepts(a, capturedAt: 10.1) }()); let b = gate.enable(at: 20)
    #expect({ !gate.accepts(a, capturedAt: 21) }()); #expect({ gate.permit(capturedAt: 19) == nil }())
    #expect({ gate.accepts(b, capturedAt: 21) }()); #expect({ gate.permit(capturedAt: .nan) == nil }())
}

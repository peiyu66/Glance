import Foundation
import Testing

@Test func acceptedVisibleImageSurvivesProcessingButNotChangedGeometry() throws {
    let gate = VisibleCaptureGate(); gate.resize(CGSize(width: 360, height: 360))
    let stamp = try #require(gate.stamp(at: 10)); _ = gate.markDisplayed(stamp)
    #expect(throws: VisibleCaptureGate.Rejection.self) { try gate.acceptImage(stamp, now: 10.751) }
    #expect(throws: VisibleCaptureGate.Rejection.self) { try gate.acceptImage(stamp, now: 9.9) }
    let accepted = try gate.acceptImage(stamp, now: 10.2)
    #expect(throws: VisibleCaptureGate.Rejection.self) { try gate.requireCurrent(stamp, now: 11) }
    try gate.requireUnchanged(accepted)
    gate.resize(CGSize(width: 390, height: 390))
    #expect(throws: VisibleCaptureGate.Rejection.self) { try gate.requireUnchanged(accepted) }
    let next = try #require(gate.stamp(at: 12)); _ = gate.markDisplayed(next)
    let second = try gate.acceptImage(next, now: 12)
    gate.invalidate()
    #expect(throws: VisibleCaptureGate.Rejection.self) { try gate.requireUnchanged(second) }
}
@testable import GlanceCore

@Test func fullVisibleCropRetainsEdgesAndExcludesOutsidePreview() {
    let portrait = VisibleCaptureGate.crop(source: CGRect(x: 0, y: 0, width: 1080, height: 1920), viewport: CGSize(width: 360, height: 360))!
    #expect(portrait == CGRect(x: 0, y: 420, width: 1080, height: 1080))
    #expect(portrait.contains(CGPoint(x: 30, y: 960))) // Visible edge, outside old 78% crop.
    #expect(!portrait.contains(CGPoint(x: 540, y: 200))) // Sensor content never visible.
    let landscape = VisibleCaptureGate.crop(source: CGRect(x: 0, y: 0, width: 1920, height: 1080), viewport: CGSize(width: 360, height: 360))!
    #expect(landscape == CGRect(x: 420, y: 0, width: 1080, height: 1080))
    let wide = VisibleCaptureGate.crop(source: CGRect(x: 0, y: 0, width: 1080, height: 1920), viewport: CGSize(width: 400, height: 200))!
    #expect(wide == CGRect(x: 0, y: 690, width: 1080, height: 540))
}
@Test func invalidViewportCannotProduceHiddenFallbackCrop() {
    #expect(VisibleCaptureGate.crop(source: .zero, viewport: CGSize(width: 360, height: 360)) == nil)
    #expect(VisibleCaptureGate.crop(source: CGRect(x: 0, y: 0, width: 1080, height: 1920), viewport: .zero) == nil)
}
@Test func geometryMustBeDisplayedAndRemainCurrentUntilSend() throws {
    let gate = VisibleCaptureGate(); gate.resize(CGSize(width: 360, height: 360))
    let first = gate.stamp(at: 10)!
    #expect(throws: VisibleCaptureGate.Rejection.self) { try gate.requireCurrent(first, now: 10.1) }
    #expect(gate.markDisplayed(first)); try gate.requireCurrent(first, now: 10.75)
    #expect(throws: VisibleCaptureGate.Rejection.self) { try gate.requireCurrent(first, now: 10.751) }
    #expect(throws: VisibleCaptureGate.Rejection.self) { try gate.requireCurrent(first, now: 9.9) }
    gate.resize(CGSize(width: 300, height: 300))
    #expect(!gate.markDisplayed(first))
    #expect(throws: VisibleCaptureGate.Rejection.self) { try gate.requireCurrent(first, now: 10.2) }
    let next = gate.stamp(at: 10.3)!; #expect(gate.markDisplayed(next)); gate.invalidate()
    #expect(throws: VisibleCaptureGate.Rejection.self) { try gate.requireCurrent(next, now: 10.4) }
}

import Foundation
import Testing
@testable import GlanceCore

private let focusDetail = CentralFocusQuality(mean: 0.5, variance: 0.08, tenengrad: 0.2, laplacianVariance: 0.02)
private let focusBlur = CentralFocusQuality(mean: 0.5, variance: 0.08, tenengrad: 0.02, laplacianVariance: 0.00001)
private func focusScope() -> FocusCandidateSelector<String>.Scope {
    .init(session: UUID(), focusRevision: 2, geometryRevision: UUID())
}

@Test func focusQualityDoesNotMistakeUnknownForMeasuredBlur() {
    let flat = CentralFocusQuality(mean: 0.5, variance: 0, tenengrad: 0, laplacianVariance: 0)
    let dark = CentralFocusQuality(mean: 0.02, variance: 0.01, tenengrad: 0.1, laplacianVariance: 0.001)
    let bright = CentralFocusQuality(mean: 0.98, variance: 0.01, tenengrad: 0.1, laplacianVariance: 0.001)
    #expect(flat.state == .unknown && flat.reason == .lowTexture)
    #expect(dark.state == .unknown && dark.reason == .dark)
    #expect(bright.state == .unknown && bright.reason == .bright)
    #expect(CentralFocusQuality.unavailable.state == .unknown)
    #expect(CentralFocusQuality(mean: 0.5, variance: 0.1, tenengrad: 0.0005, laplacianVariance: 0.00000001).reason == .lowTexture)
    #expect(focusBlur.state == .blurred && focusDetail.state == .detail)
}

@Test func focusSelectionKeepsScoresAndOriginalFrameTogether() {
    var selector = FocusCandidateSelector<String>(); let scope = focusScope()
    selector.begin(at: 0)
    selector.observe(payload: "sharp-image", capturedAt: 0.75, scope: scope, quality: focusDetail, now: 0.75)
    selector.observe(payload: "blurred-image", capturedAt: 1, scope: scope, quality: focusBlur, now: 1)
    #expect(selector.selected(at: 1, scope: scope) == "sharp-image")
    // The best historical image must not outlive its short candidate lease.
    #expect(selector.selected(at: 1.26, scope: scope) == nil)
}

@Test func focusSelectionTreatsUnknownAsFallbackAndFreshTiesPreferLatest() {
    var selector = FocusCandidateSelector<String>(); let scope = focusScope()
    selector.begin(at: 0)
    selector.observe(payload: "unknown", capturedAt: 0.25, scope: scope, quality: .unavailable, now: 0.25)
    #expect(selector.selected(at: 0.25, scope: scope) == "unknown")
    selector.observe(payload: "detail-a", capturedAt: 0.5, scope: scope, quality: focusDetail, now: 0.5)
    selector.observe(payload: "detail-b", capturedAt: 0.75, scope: scope, quality: focusDetail, now: 0.75)
    #expect(selector.selected(at: 0.75, scope: scope) == "detail-b")
}

@Test func focusSelectionCannotCrossIntentFocusGeometryOrScene() {
    var selector = FocusCandidateSelector<String>(); let scope = focusScope(), changed = focusScope()
    selector.begin(at: 0)
    selector.observe(payload: "old", capturedAt: 0.25, scope: scope, quality: focusDetail, now: 0.25)
    #expect(selector.selected(at: 0.25, scope: changed) == nil)
    selector.observe(payload: "new-epoch", capturedAt: 0.5, scope: changed, quality: focusBlur, now: 0.5)
    #expect(selector.selected(at: 0.5, scope: changed) == nil)
    selector.observe(payload: "new-scene", capturedAt: 0.75, scope: changed, quality: .unavailable, sceneChanged: true, now: 0.75)
    #expect(selector.selected(at: 0.75, scope: changed) == "new-scene")
    selector.begin(at: 1)
    #expect(selector.selected(at: 1, scope: changed) == nil)
    selector.observe(payload: "previous-intent", capturedAt: 0.9, scope: changed, quality: focusDetail, now: 1)
    #expect(selector.selected(at: 1, scope: changed) == nil)
}

@Test func focusSelectionShowsHintWithoutRejectingFreshFramesAfterThreeSeconds() {
    var selector = FocusCandidateSelector<String>(); let scope = focusScope()
    selector.begin(at: 10)
    selector.observe(payload: "a", capturedAt: 10.25, scope: scope, quality: focusDetail, now: 10.25)
    selector.resetCandidates()
    #expect(!selector.needsWaitingHint(at: 12.99))
    #expect(selector.needsWaitingHint(at: 13))
    selector.observe(payload: "recovered", capturedAt: 13, scope: scope, quality: focusDetail, now: 13)
    #expect(selector.selected(at: 13, scope: scope) == "recovered")
    selector.resetCandidates()
    #expect(selector.needsWaitingHint(at: 120))
    selector.observe(payload: "old", capturedAt: 13, scope: scope, quality: focusDetail, now: 120)
    #expect(selector.selected(at: 120, scope: scope) == nil)
    selector.observe(payload: "fresh-after-long-wait", capturedAt: 120, scope: scope, quality: focusDetail, now: 120)
    #expect(selector.selected(at: 120, scope: scope) == "fresh-after-long-wait")
}

@Test func focusSelectionSuggestsDistanceOnlyAfterRepeatedBlurEvidence() {
    var selector = FocusCandidateSelector<String>(); let scope = focusScope()
    selector.begin(at: 0)
    for time in [0.25, 0.5, 0.75] { selector.observe(payload: "soft", capturedAt: time, scope: scope, quality: focusBlur, now: time) }
    #expect(selector.observedBlurredFrames == 3)
    #expect(selector.selected(at: 0.75, scope: scope) == nil)
    selector.observe(payload: "dark", capturedAt: 1, scope: scope, quality: .unavailable, now: 1)
    #expect(selector.observedBlurredFrames == 0)
}

@Test func acquisitionFeedbackPreservesCauseSeparatelyFromCandidatesAndResets() {
    var feedback = CaptureAcquisitionFeedback()
    feedback.autofocusChanged()
    #expect(feedback.waitingMessage.contains("稍微拉遠") && !feedback.waitingMessage.contains("再按"))
    feedback.observe(focusBlur, repeatedBlurredFrames: 3)
    #expect(feedback.reason == .blurred)
    var selector = FocusCandidateSelector<String>(); selector.resetCandidates()
    #expect(feedback.reason == .blurred)
    feedback.reset(); feedback.sceneMoved()
    #expect(feedback.waitingMessage.contains("保持手機與目標穩定") && !feedback.waitingMessage.contains("拉遠"))
    feedback.reset()
    #expect(feedback.reason == .unknown && !feedback.waitingMessage.contains("拉遠"))
}

@Test func acquisitionFeedbackDoesNotCallUnknownOrRecoveredDetailBlurred() {
    var feedback = CaptureAcquisitionFeedback()
    feedback.observe(focusBlur, repeatedBlurredFrames: 2)
    #expect(feedback.reason == .unknown)
    feedback.observe(focusBlur, repeatedBlurredFrames: 3)
    feedback.observe(.unavailable, repeatedBlurredFrames: 0)
    #expect(feedback.reason == .unknown)
    feedback.autofocusChanged(); feedback.observe(focusDetail, repeatedBlurredFrames: 0)
    #expect(feedback.reason == .unknown)
}

@Test func focusSelectionRejectsFutureStaleAndOutOfOrderSamples() {
    var selector = FocusCandidateSelector<String>(); let scope = focusScope()
    selector.begin(at: 0)
    selector.observe(payload: "future", capturedAt: 1, scope: scope, quality: focusDetail, now: 0.5)
    selector.observe(payload: "stale", capturedAt: 0.1, scope: scope, quality: focusDetail, now: 1)
    #expect(selector.selected(at: 1, scope: scope) == nil)
    selector.observe(payload: "current", capturedAt: 1, scope: scope, quality: focusDetail, now: 1)
    selector.observe(payload: "old", capturedAt: 0.9, scope: scope, quality: focusDetail, now: 1)
    #expect(selector.selected(at: 1, scope: scope) == "current")
}

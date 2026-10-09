import Testing
@testable import GlanceCore

private func fingerprint(_ variant: Int = 0) -> SceneFingerprint {
    var rgb: [Float] = []
    for y in 0..<8 { for x in 0..<8 {
        let value: Float = ((x + 2 * y) % 3 == 0) ? 0.8 : 0.1
        rgb += [value, Float(x) / 10, Float(y) / 10]
    } }
    if variant > 0 { for i in 0..<24 { rgb[i] = 1 - rgb[i] } }
    return SceneFingerprint(rgb: rgb, side: 8)
}
@Test func targetMemoryDistinguishesSimilarLabelsAndSupportsRotation() {
    let a = fingerprint(); let b = fingerprint(1)
    #expect(a.distance(to: b) > 0.035)
    #expect(a.distance(to: a.rotated()) < 0.001)
    var m = TargetMemory()
    let first = m.resolve(a, at: 0)
    let second = m.resolve(b, at: 1)
    #expect(first != second)
    #expect(m.resolve(a.rotated(), at: 2) == first)
    // Additional feature-print disagreement fails closed even if pixels look similar.
    #expect(m.resolve(a, at: 3, additionalMatch: { _ in false }) == nil)
    #expect(m.resolve(a, at: 4) == first) // uncertainty does not poison the identity cache
}
@Test func targetMemoryIsBoundedAndExpires() {
    var m = TargetMemory(capacity: 1, ttl: 5)
    let original = m.resolve(fingerprint(), at: 0)
    _ = m.resolve(fingerprint(1), at: 1)
    #expect(m.entries.count == 1)
    let returned = m.resolve(fingerprint(), at: 2)
    #expect(original != returned)
    #expect(m.resolve(fingerprint(), at: 8) != returned)
    m.clear(); #expect(m.entries.isEmpty)
}
@Test func movingObjectResetsStabilityEvenWithStationaryCamera() {
    var s = RecognitionState()
    _ = s.observe("A", at: 0)
    _ = s.observe("B", at: 0.75) // ROI changed; no gyroscope input is used
    #expect(s.observe("B", at: 1) == nil)
    #expect(s.observe("B", at: 1.76) != nil)
    _ = s.observe(nil, at: 2) // blur/empty/saliency miss
    #expect(s.visible == nil)
}
@Test func inflightGateDoesNotConsumeNextTargetAndLateCacheCannotAttach() {
    var s = RecognitionState()
    _ = s.observe("A", at: 0); let a = s.observe("A", at: 1)!
    _ = s.observe("B", at: 1.1, allowRequest: false)
    #expect(s.observe("B", at: 2.2, allowRequest: false) == nil)
    s.complete(a, result: RecognitionResult(names: ["A"]))
    #expect(s.visible == nil)
    let b = s.observe("B", at: 2.3)!
    _ = s.observe("A", at: 2.4, allowRequest: false)
    #expect(s.visible == nil)
    _ = s.observe("A", at: 3.5, allowRequest: false)
    #expect(s.visible?.names == ["A"])
    s.complete(b, result: RecognitionResult(names: ["B"]))
    #expect(s.visible?.names == ["A"])
    s.leaveForeground(); s.complete(b, result: RecognitionResult(names: ["late"]))
    #expect(s.visible == nil)
}
@Test func quotaStopAndEmptyResultAreSilentAndDeduplicated() {
    var s = RecognitionState(stableDuration: 0)
    let a = s.observe("A", at: 0)!
    s.complete(a, result: nil)
    #expect(s.observe("A", at: 1) == nil)
    #expect(s.observe("B", at: 2, allowRequest: false) == nil)
    #expect(s.visible == nil)
    #expect(s.observe("B", at: 3, allowRequest: true) != nil)
}
@Test func resultCacheExpiresAndBackgroundRequiresNewStability() {
    var s = RecognitionState()
    _ = s.observe("A", at: 0); let first = s.observe("A", at: 1)!
    s.complete(first, result: RecognitionResult(text: ["A"]))
    _ = s.observe("A", at: 2); #expect(s.visible != nil)
    let expired = s.observe("A", at: 92)
    #expect(expired != nil)
    s.leaveForeground(); _ = s.observe("A", at: 93)
    #expect(s.observe("A", at: 93.5) == nil)
    #expect(s.observe("A", at: 94) != nil)
}
@Test func cameraJSONCombinesReadableFieldsAndRejectsMalformedAnswers() throws {
    let result = try CameraAnswer.parse(#"{"names":["茶罐","茶罐"],"text":["茶葉"," "],"barcodes":["4710000000000"]}"#)
    #expect(result.lines == ["茶罐", "茶葉", "4710000000000"])
    #expect(try CameraAnswer.parse(#"{"names":[],"text":[],"barcodes":[]}"#).lines.isEmpty)
    #expect(throws: (any Error).self) { try CameraAnswer.parse("Here is some text") }
    #expect(throws: (any Error).self) { try CameraAnswer.parse(#"{"names": [1]}"#) }
}

@Test func smallReframingMatchesButMotionMeasurementStillChanges() {
    let original = fingerprint()
    var shifted = original.rgb
    for y in 0..<8 { for x in 1..<8 { for c in 0..<3 { shifted[(y*8+x)*3+c] = original.rgb[(y*8+x-1)*3+c] } } }
    let sample = SceneFingerprint(rgb: shifted, side: 8)
    #expect(original.distance(to: sample) < 0.035)
    #expect(original.distance(to: sample, allowRotation: false, allowTranslation: false) > 0.035)
    #expect(original.distance(to: fingerprint(1)) > 0.035)
}

@Test func uncertainFramesDoNotFragmentOrEvictPendingIdentity() {
    var m = TargetMemory(capacity: 2)
    let a = fingerprint(); let id = m.resolve(a, at: 0)!
    for tick in 1...20 {
        #expect(m.resolve(a, at: Double(tick), protectedID: id, additionalMatch: { _ in false }) == nil)
    }
    #expect(m.entries.count == 1)
    #expect(m.resolve(a, at: 21) == id)
    var state = RecognitionState()
    _ = state.observe(id, at: 0); let request = state.observe(id, at: 1)!
    _ = state.observe(nil, at: 2) // blur/focus interval hides but keeps identity memory
    state.complete(request, result: RecognitionResult(text: ["fixture"]))
    _ = state.observe(id, at: 3); #expect(state.visible == nil)
    _ = state.observe(id, at: 4); #expect(state.visible?.text == ["fixture"])
}
@Test func smallExposureAndReframingRetainIdentityWithoutMergingLabels() {
    let original = fingerprint()
    let exposed = SceneFingerprint(rgb: original.rgb.map { $0 + 0.05 }, side: 8)
    #expect(original.distance(to: exposed) < 0.035)
    #expect(original.distance(to: fingerprint(1)) > 0.035)
    var m = TargetMemory(); let id = m.resolve(original, at: 0)
    #expect(m.resolve(exposed, at: 1) == id)
}

@Test func qualityKeepsSparseSharpLabelsButRejectsFlatOrBlurredGradient() {
    let side = 128
    let flat = SceneFingerprint(rgb: [Float](repeating: 0.7, count: side*side*3), side: side)
    #expect(!SceneQuality(flat).usable)
    var gradient: [Float] = []; var label = flat.rgb
    for y in 0..<side { for x in 0..<side {
        let value = Float(x+y) / 256; gradient += [value,value,value]
        if y > 40 && y < 75 && (x % 8 < 2) && x > 20 && x < 108 {
            for c in 0..<3 { label[(y*side+x)*3+c] = 0.05 }
        }
    } }
    #expect(!SceneQuality(SceneFingerprint(rgb: gradient, side: side)).usable)
    #expect(SceneQuality(SceneFingerprint(rgb: label, side: side)).usable)
}

@Test func tinyCentralLabelChangeDoesNotMergeNearIdenticalObjects() {
    let side = 32
    var values = [Float](repeating: 0.7, count: side*side*3)
    for y in 0..<side { for x in 0..<side { values[(y*side+x)*3] = Float((x*7+y*3)%17)/20 } }
    let original = SceneFingerprint(rgb: values, side: side)
    for y in 12..<14 { for x in 12..<14 { for c in 0..<3 { values[(y*side+x)*3+c] = 0.02 } } }
    let changed = SceneFingerprint(rgb: values, side: side)
    #expect(original.distance(to: changed) > 0.035)
    var m = TargetMemory(); let first = m.resolve(original, at: 0)
    #expect(m.resolve(changed, at: 1) != first)
}
@Test func admissionReturnsToNormalWithoutDiagnosticFlag() {
    let trial = RequestAdmission(trialLimit: 1); let normal = RequestAdmission()
    #expect(trial.allows(sent: 0, inflight: false, blocked: false, now: 10, nextAllowed: 0))
    #expect(!trial.allows(sent: 1, inflight: false, blocked: false, now: 10, nextAllowed: 0))
    #expect(normal.allows(sent: 4, inflight: false, blocked: false, now: 10, nextAllowed: 9))
    #expect(!normal.allows(sent: 0, inflight: true, blocked: false, now: 10, nextAllowed: 0))
    #expect(!normal.allows(sent: 0, inflight: false, blocked: true, now: 10, nextAllowed: 0))
    #expect(!normal.allows(sent: 0, inflight: false, blocked: false, now: 10, nextAllowed: 11))
}
@Test func pinnedPendingAnchorSurvivesCapacityPressure() {
    var memory = TargetMemory(capacity: 2, ttl: 2)
    let first = memory.resolve(fingerprint(), at: 0)!
    for i in 1...5 {
        let fp = SceneFingerprint(rgb: [Float](repeating: Float(i)/6, count: 8*8*3), side: 8)
        _ = memory.resolve(fp, at: Double(i), protectedID: first)
        #expect(memory.entries.contains { $0.id == first })
        #expect(memory.entries.count <= 2)
    }
}

@Test func readableLabelDifferenceCreatesDistinctTargetButUnreadableLabelDoesNot() {
    var memory = TargetMemory()
    let fp = fingerprint()
    let a = memory.resolve(fp, at: 0, labelSignature: "digest-123")!
    #expect(memory.resolve(fp, at: 1, labelSignature: "digest-123") == a)
    #expect(memory.resolve(fp, at: 2, labelSignature: "") == nil)
    #expect(memory.entries.count == 1)
    let b = memory.resolve(fp, at: 3, labelSignature: "digest-128")!
    #expect(b != a)
    #expect(memory.resolve(fp, at: 4, labelSignature: "digest-123") == a)
    #expect(memory.resolve(fp, at: 5, labelSignature: "digest-128") == b)
}

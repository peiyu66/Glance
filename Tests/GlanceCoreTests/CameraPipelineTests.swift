import Foundation
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

@Test func labelEvidencePreservesDifferentDigitsAndRejectsLowConfidence() {
    #expect(LabelEvidence.normalizedLines([(" GLANCE 123 ", 0.5), ("glance123",1), ("wrong",0.49), ("",1)]) == ["glance123"])
    #expect(LabelEvidence.normalizedLines([("GLANCE 128", 0.5)]) != LabelEvidence.normalizedLines([("GLANCE 123",0.5)]))
    #expect(LabelEvidence.normalizedLines([("invalid",.nan)]).isEmpty)
}
@Test func translatedFeatureNeedsBothSpatialAndExactLabelEvidence() {
    var memory = TargetMemory()
    let fp = fingerprint()
    let a = memory.resolve(fp, at: 0, labelSignature: "123")!
    let translatedDistance: Float = 0.3226 // measured real-device same-card translation
    #expect(!FeatureEvidence.accepts(translatedDistance, identicalReadableLabel: false))
    #expect(memory.resolve(fp, at: 1, labelSignature: "123", additionalMatch: { _ in FeatureEvidence.accepts(translatedDistance, identicalReadableLabel: true) }) == a)
    // A different digit is independent contradictory evidence, even if Vision is close.
    let b = memory.resolve(fp, at: 2, labelSignature: "128", additionalMatch: { _ in FeatureEvidence.accepts(0.09348, identicalReadableLabel: true) })
    #expect(b != nil && b != a)
    #expect(memory.resolve(fp, at: 3, labelSignature: "") == nil)
    #expect(memory.resolve(fingerprint(1), at: 4, labelSignature: "123", additionalMatch: { _ in true }) != a)
    #expect(!FeatureEvidence.accepts(0.36, identicalReadableLabel: true))
    #expect(!FeatureEvidence.accepts(.nan, identicalReadableLabel: true))
}

@Test func initiallyUnreadableAnchorDoesNotAttachResultToNewlyReadableLabel() {
    var memory = TargetMemory()
    let fp = fingerprint()
    let original = memory.resolve(fp, at: 0, labelSignature: "")!
    var state = RecognitionState()
    _ = state.observe(original, at: 0)
    let request = state.observe(original, at: 1)!
    let newlyReadable = memory.resolve(fp, at: 1.5, protectedID: original, labelSignature: "generated-digest")
    #expect(newlyReadable == nil)
    #expect(memory.entries.count == 1)
    _ = state.observe(newlyReadable, at: 1.5)
    state.complete(request, result: RecognitionResult(names: ["generated-result"]))
    _ = state.observe(newlyReadable, at: 3.75)
    #expect(state.visible == nil)
    let returnToOriginal = memory.resolve(fp, at: 4, labelSignature: "")
    #expect(returnToOriginal == original)
    _ = state.observe(returnToOriginal, at: 4)
    _ = state.observe(returnToOriginal, at: 5)
    #expect(state.visible?.names == ["generated-result"])
}

@Test func identityEvidenceMatrixWithAvailableVision() {
    struct Scenario {
        let name: String
        let anchorLabel: String
        let currentLabel: String
        let distance: Float
        let expected: String
        let expectedVisualChecks: Int
    }
    let scenarios = [
        Scenario(name: "both-missing-strong-vision", anchorLabel: "", currentLabel: "", distance: 0.02, expected: "same", expectedVisualChecks: 1),
        Scenario(name: "both-missing-weak-vision", anchorLabel: "", currentLabel: "", distance: 0.13, expected: "uncertain", expectedVisualChecks: 1),
        Scenario(name: "missing-to-readable-strong-vision", anchorLabel: "", currentLabel: "123", distance: 0.02, expected: "uncertain", expectedVisualChecks: 0),
        Scenario(name: "readable-to-missing-strong-vision", anchorLabel: "123", currentLabel: "", distance: 0.02, expected: "uncertain", expectedVisualChecks: 0),
        Scenario(name: "matching-label-translated-vision", anchorLabel: "123", currentLabel: "123", distance: 0.3226, expected: "same", expectedVisualChecks: 1),
        Scenario(name: "matching-label-weak-vision", anchorLabel: "123", currentLabel: "123", distance: 0.36, expected: "uncertain", expectedVisualChecks: 1),
        Scenario(name: "contradictory-digit-very-close-vision", anchorLabel: "123", currentLabel: "128", distance: 0.02, expected: "new", expectedVisualChecks: 0),
        Scenario(name: "contradictory-digit-measured-close-vision", anchorLabel: "123", currentLabel: "128", distance: 0.09348, expected: "new", expectedVisualChecks: 0)
    ]
    for scenario in scenarios {
        var memory = TargetMemory()
        let fp = fingerprint()
        let original = memory.resolve(fp, at: 0, labelSignature: scenario.anchorLabel)!
        var visualChecks = 0
        let resolved = memory.resolve(fp, at: 1, protectedID: original, labelSignature: scenario.currentLabel) { _ in
            visualChecks += 1
            return FeatureEvidence.accepts(scenario.distance, identicalReadableLabel: !scenario.currentLabel.isEmpty)
        }
        let disposition = resolved == nil ? "uncertain" : resolved == original ? "same" : "new"
        #expect(disposition == scenario.expected)
        #expect(visualChecks == scenario.expectedVisualChecks)
        #expect(memory.entries.count == (scenario.expected == "new" ? 2 : 1))
        print("IDENTITY_MATRIX \(scenario.name): \(disposition); visualChecks=\(visualChecks); entries=\(memory.entries.count)")
    }
    // The historical one-digit negative had a visually close distance. Visual
    // availability alone cannot justify adopting a new label onto an empty anchor.
    #expect(FeatureEvidence.accepts(0.09348, identicalReadableLabel: false))
}

@Test func missingLabelBlocksButReturningVerifiedLabelRestoresCachedResult() {
    var memory = TargetMemory()
    let fp = fingerprint()
    let original = memory.resolve(fp, at: 0, labelSignature: "123")!
    var state = RecognitionState()
    _ = state.observe(original, at: 0)
    let request = state.observe(original, at: 1)!
    let missing = memory.resolve(fp, at: 1.25, protectedID: original, labelSignature: "") { _ in
        FeatureEvidence.accepts(0.02, identicalReadableLabel: false)
    }
    #expect(missing == nil)
    _ = state.observe(missing, at: 1.25)
    state.complete(request, result: RecognitionResult(names: ["generated-A"]))
    #expect(state.visible == nil)
    let restored = memory.resolve(fp, at: 2, labelSignature: "123") { _ in
        FeatureEvidence.accepts(0.3226, identicalReadableLabel: true)
    }
    #expect(restored == original)
    #expect(state.observe(restored, at: 2) == nil && state.visible == nil)
    #expect(state.observe(restored, at: 3) == nil && state.visible?.names == ["generated-A"])
    #expect(memory.entries.count == 1)
}

@Test func emptyAnchorCanRemainUncertainWithoutFragmentingOrShowingWrongDigit() {
    var memory = TargetMemory()
    let fp = fingerprint()
    let original = memory.resolve(fp, at: 0, labelSignature: "")!
    var state = RecognitionState()
    _ = state.observe(original, at: 0)
    let request = state.observe(original, at: 1)!
    state.complete(request, result: RecognitionResult(names: ["generated-A"]))
    // This is a liveness limitation, not a positive first-display acceptance.
    // Two possible newly readable digits must both remain unverified against
    // an anchor whose text was never available, even with close visual evidence.
    for (index, label) in ["123", "128", "123", "128"].enumerated() {
        let time = 2 + Double(index)
        let resolved = memory.resolve(fp, at: time, protectedID: original, labelSignature: label) { _ in
            FeatureEvidence.accepts(0.09348, identicalReadableLabel: true)
        }
        #expect(resolved == nil)
        #expect(state.observe(resolved, at: time) == nil)
        #expect(state.visible == nil)
        #expect(memory.entries.count == 1 && memory.entries.first?.id == original)
    }
}

@Test func contradictoryDigitCannotDisplayEarlierResultWithCloseVision() {
    var memory = TargetMemory()
    let fp = fingerprint()
    let a = memory.resolve(fp, at: 0, labelSignature: "123")!
    var state = RecognitionState()
    _ = state.observe(a, at: 0)
    let requestA = state.observe(a, at: 1)!
    let b = memory.resolve(fp, at: 1.5, protectedID: a, labelSignature: "128") { _ in
        FeatureEvidence.accepts(0.09348, identicalReadableLabel: true)
    }
    #expect(b != nil && b != a)
    _ = state.observe(b, at: 1.5, allowRequest: false)
    state.complete(requestA, result: RecognitionResult(names: ["generated-A"]))
    _ = state.observe(b, at: 3, allowRequest: false)
    #expect(state.visible == nil)
    let back = memory.resolve(fp, at: 4, labelSignature: "123") { _ in
        FeatureEvidence.accepts(0.02, identicalReadableLabel: true)
    }
    #expect(back == a)
    _ = state.observe(back, at: 4, allowRequest: false)
    _ = state.observe(back, at: 5, allowRequest: false)
    #expect(state.visible?.names == ["generated-A"])
}


@Test func cameraRequestUsesTaiwanChineseWithoutTranslatingSourceText() throws {
    let model = SIWCModel(slug: "gpt-6-luna", display_name: "Fixture", visibility: "list")
    let bytes = try CameraAnswer.request(model: model.slug, catalog: [model], jpeg: Data([1, 2, 3]))
    let body = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    let input = try #require(body["input"] as? [[String: Any]])
    let content = try #require(input.first?["content"] as? [[String: Any]])
    let prompt = try #require(content.first?["text"] as? String)
    #expect(prompt.contains("Traditional Chinese as used in Taiwan (zh-Hant-TW)"))
    #expect(prompt.contains("natural Taiwanese vocabulary"))
    #expect(prompt.contains("verbatim in its original language and script"))
    #expect(prompt.contains("do not translate or normalize it"))
    #expect(prompt.contains("preserving all digits and leading zeros"))
    #expect(prompt.contains("four keys: names (array of strings), summary (string), text (array of strings), barcodes (array of strings)"))
    #expect(prompt.contains("No web lookup, outside facts"))
    #expect(body["model"] as? String == "gpt-6-luna")
    #expect(body["store"] as? Bool == false)
    #expect(body["stream"] as? Bool == true)
    #expect((body["reasoning"] as? [String: String])?["effort"] == "none")
    #expect(content.count == 2)
    #expect(content.last?["image_url"] as? String == "data:image/jpeg;base64,AQID")
    #expect(Set(body.keys) == Set(["model", "reasoning", "store", "stream", "input"]))
}

@Test func cameraAnswerPreservesSourceScriptBrandsModelsAndLeadingZeros() throws {
    let result = try CameraAnswer.parse(#"{"names":["隨身碟"],"text":["包装文字","Acme USB-C","AB-001","臺灣製造"],"barcodes":["0012345678905"]}"#)
    #expect(result.names == ["隨身碟"])
    #expect(result.text == ["包装文字", "Acme USB-C", "AB-001", "臺灣製造"])
    #expect(result.barcodes == ["0012345678905"])
}

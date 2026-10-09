import Testing
@testable import GlanceCore

let result = RecognitionResult(names: ["杯子"], text: ["茶"], barcodes: ["123"])

@Test func stableAndDeduplicated() {
    var s = RecognitionState()
    #expect(s.observe("A", at: 0) == nil)
    #expect(s.observe("A", at: 0.99) == nil)
    let a = s.observe("A", at: 1)!
    #expect(s.observe("A", at: 2) == nil)
    s.complete(a, result: result)
    _ = s.observe("A", at: 3)
    #expect(s.visible?.lines == ["杯子", "茶", "123"])
    #expect(s.observe("A", at: 4) == nil)
}
@Test func lateResultNeverAttachesToOtherTargetAndReturnWaits() {
    var s = RecognitionState()
    _ = s.observe("A", at: 0); let a = s.observe("A", at: 1)!
    _ = s.observe("B", at: 2)
    s.complete(a, result: result)
    #expect(s.visible == nil)
    _ = s.observe("B", at: 3)
    #expect(s.visible == nil)
    #expect(s.observe("A", at: 4) == nil)
    #expect(s.visible == nil)
    #expect(s.observe("A", at: 5) == nil)
    #expect(s.visible == result)
    _ = s.observe(nil, at: 6)
    #expect(s.visible == nil)
}
@Test func backIsIndependentAndFailuresAreSilent() {
    var s = RecognitionState()
    _ = s.observe("front", at: 0); let a = s.observe("front", at: 1)!
    s.complete(a, result: result); _ = s.observe("front", at: 2)
    _ = s.observe("back", at: 3)
    #expect(s.visible == nil)
    let b = s.observe("back", at: 4)!
    #expect(a.target != b.target)
    s.complete(b, result: RecognitionResult(text: ["  "]))
    #expect(s.observe("back", at: 5) == nil)
    #expect(s.visible == nil)
}
@Test func foregroundResetRejectsOldCompletion() {
    var s = RecognitionState()
    _ = s.observe("A", at: 0); let old = s.observe("A", at: 1)!
    s.leaveForeground()
    _ = s.observe("A", at: 2); let fresh = s.observe("A", at: 3)!
    s.complete(old, result: result); _ = s.observe("A", at: 4)
    #expect(s.visible == nil)
    s.complete(fresh, result: result); _ = s.observe("A", at: 5)
    #expect(s.visible == result)
    s.leaveForeground(); #expect(s.visible == nil)
}
@Test func boundedCacheEvictsAndRejectsOldRequest() {
    var s = RecognitionState(stableDuration: 0, capacity: 1)
    let old = s.observe("A", at: 0)!
    _ = s.observe("B", at: 1)
    let fresh = s.observe("A", at: 2)!
    #expect(old.id != fresh.id)
    s.complete(old, result: result); _ = s.observe("A", at: 3)
    #expect(s.visible == nil)
}
@Test func interruptedStabilityRestarts() {
    var s = RecognitionState()
    _ = s.observe("A", at: 0); _ = s.observe(nil, at: 0.8)
    _ = s.observe("A", at: 1)
    #expect(s.observe("A", at: 1.9) == nil)
    #expect(s.observe("A", at: 2) != nil)
}

import Testing
@testable import GlanceCore

@Test func unsentEncodingFailureCanRetryWithoutReleasingNewerOrCompletedRequest() throws {
    var state = RecognitionState()
    _ = state.observe("a", at: 0)
    let firstValue = state.observe("a", at: 1)
    let first = try #require(firstValue)
    // This is the prior failure: observe marks attempted before JPEG is encoded.
    #expect(state.observe("a", at: 2) == nil)
    #expect(state.lastGate == "already-attempted")
    state.releaseUnsent(first)
    let secondValue = state.observe("a", at: 2.25)
    let second = try #require(secondValue)
    #expect(first != second)
    state.releaseUnsent(first)
    #expect(state.observe("a", at: 2.5) == nil)
    let result = RecognitionResult(names: ["synthetic"])
    state.complete(second, result: result)
    state.releaseUnsent(second)
    #expect(state.observe("a", at: 3) == nil)
    #expect(state.visible == result)
}

@Test func stableGateSeparatesUncertaintyAdmissionDedupAndVisibleCache() throws {
    var state = RecognitionState()
    #expect(state.observe(nil, at: 0) == nil)
    #expect(state.lastGate == "no-target")
    _ = state.observe("a", at: 0.25)
    _ = state.observe("a", at: 1)
    #expect(state.lastGate == "stabilizing" && state.stableElapsed == 0.75)
    _ = state.observe("a", at: 1.25, allowRequest: false)
    #expect(state.lastGate == "admission-blocked")
    let requestValue = state.observe("a", at: 1.5)
    let request = try #require(requestValue)
    #expect(state.lastGate == "request-ready")
    state.complete(request, result: RecognitionResult(names: ["synthetic"]))
    _ = state.observe(nil, at: 1.75)
    #expect(state.visible == nil)
    _ = state.observe("a", at: 2)
    #expect(state.stableElapsed == 0 && state.visible == nil)
    _ = state.observe("a", at: 3)
    #expect(state.lastGate == "cached-visible")
}

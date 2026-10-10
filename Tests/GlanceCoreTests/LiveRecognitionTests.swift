import Foundation
import Testing
@testable import GlanceCore

@Test func ordinaryLaunchSelectsAcceptedLivePipelineWithoutStartingOrSpending() {
    #expect(CameraPipelineMode.resolve(arguments: ["Glance"]) == .liveCurrent)
    #expect(CameraPipelineMode.resolve(arguments: ["Glance", "-AppleLanguages", "(zh-Hant)"]) == .liveCurrent)
    let state = LiveRecognitionSession()
    #expect(state.limit == 3 && state.sentCount == 0)
    #expect(state.queuedIntent == nil && state.inflightRequest == nil && state.visible == nil)
}

@Test func explicitEngineeringRoutesRemainIsolatedFromDefaultLivePipeline() {
    for flag in ["--camera-first-capture", "--camera-first-capture-fixture", "--camera-first-capture-generated-real", "--camera-first-capture-generated-check"] {
        #expect(CameraPipelineMode.resolve(arguments: ["Glance", flag]) == .firstCapture)
    }
    for flag in ["--camera-legacy", "--camera-trial-once", "--camera-fixture", "--camera-local-fixture",
                 "--camera-continuous-fixture", "--camera-delayed-fixture", "--camera-vision-baseline", "--camera-geometry-profile",
                 "--camera-current-image-fixture", "--camera-roi-trace", "--camera-regional-fixture"] {
        #expect(CameraPipelineMode.resolve(arguments: ["Glance", flag]) == .legacy)
    }
    for flag in ["--camera-live-current", "--camera-live-fixture"] {
        #expect(CameraPipelineMode.resolve(arguments: ["Glance", flag]) == .liveCurrent)
    }
}

private func liveFingerprint(_ changed: Bool = false) -> SceneFingerprint {
    SceneFingerprint(rgb: (0..<(8*8*3)).map { i in ((i/3)%8 < 4) != changed ? 0.15 : 0.85 }, side: 8)
}
private func liveFeed(_ state: inout LiveRecognitionSession, _ changed: Bool = false, from: Double, through: Double) {
    for t in stride(from: from, through: through, by: 0.25) { state.observe(liveFingerprint(changed), capturedAt: t, now: t) }
}
@Test func liveAdoptsOnceHistoryIsImmediateAndCurrentNeedsPostResponseFrame() throws {
    var state = LiveRecognitionSession()
    liveFeed(&state, from: 0, through: 1)
    let request = try #require({ state.startRequest(snapshotCapturedAt: 1, at: 1.01) }())
    liveFeed(&state, from: 1.25, through: 2)
    #expect(state.adoptedCount == 1 && state.sentCount == 1)
    #expect({ state.complete(request, result: .init(names: ["A"]), at: 2.01) }())
    #expect(state.visible?.names == ["A"] && state.visibleIsPrevious && state.history.entries.count == 1)
    liveFeed(&state, from: 2.25, through: 3)
    #expect(state.visible?.names == ["A"])
    #expect(state.adoptedCount == 1 && state.queuedIntent == nil)
}
@Test(arguments: [4.0, 8.0]) func liveAdoptsBWhileAIsDelayed(delay: Double) throws {
    var state = LiveRecognitionSession()
    liveFeed(&state, from: 0, through: 1)
    let a = try #require({ state.startRequest(snapshotCapturedAt: 1, at: 1) }())
    liveFeed(&state, true, from: 1.25, through: 1+delay)
    let bIntent = try #require(state.queuedIntent)
    #expect(bIntent.adoptedAt == 2.25 && state.adoptedCount == 2)
    #expect({ state.startRequest(snapshotCapturedAt: 1+delay, at: 1+delay) == nil }())
    #expect({ state.complete(a, result: .init(names: ["A"]), at: 1+delay) }())
    #expect(state.visible?.names == ["A"] && state.visibleIsPrevious && state.discardedCount == 0)
    liveFeed(&state, true, from: 1.25+delay, through: 1.25+delay)
    let b = try #require({ state.startRequest(snapshotCapturedAt: 1.25+delay, at: 1.25+delay) }())
    #expect(b.intent == bIntent && b.startedAt > b.intent.adoptedAt)
    #expect({ state.complete(b, result: .init(text: ["B"]), at: b.startedAt) }())
    liveFeed(&state, true, from: 1.5+delay, through: 1.5+delay)
    #expect(state.visible?.text == ["B"])
}
@Test func liveOnlyKeepsLatestQueuedEpisodeAndReturnCanQueryAgain() throws {
    var state = LiveRecognitionSession()
    liveFeed(&state, from: 0, through: 1)
    let a = try #require({ state.startRequest(snapshotCapturedAt: 1, at: 1) }())
    liveFeed(&state, true, from: 1.25, through: 2.25)
    let b = try #require(state.queuedIntent)
    liveFeed(&state, from: 2.5, through: 3.5)
    let returnedA = try #require(state.queuedIntent)
    #expect(returnedA != b && returnedA.episode != a.intent.episode)
    #expect({ state.complete(a, result: .init(names: ["OLD A"]), at: 3.5) }())
    let next = try #require({ state.startRequest(snapshotCapturedAt: 3.5, at: 3.5) }())
    #expect(next.intent == returnedA && state.sentCount == 2 && state.visible?.names == ["OLD A"] && state.visibleIsPrevious)
}
@Test func liveStopRetainsTransportAndBudgetRejectsLateResult() throws {
    var state = LiveRecognitionSession(limit: 1)
    liveFeed(&state, from: 0, through: 1)
    let a = try #require({ state.startRequest(snapshotCapturedAt: 1, at: 1) }())
    state.stop()
    #expect(state.inflightRequest == a && state.sentCount == 1)
    liveFeed(&state, true, from: 2, through: 3)
    #expect(state.queuedIntent == nil)
    #expect({ !state.complete(a, result: .init(names: ["A"]), at: 3) }())
    #expect(state.visible == nil && state.inflightRequest == nil && state.sentCount == 1)
}
@Test func liveEmptyFailureAndEncodingFailureDoNotRetryEpisode() throws {
    for result: RecognitionResult? in [nil, RecognitionResult()] {
        var state = LiveRecognitionSession()
        liveFeed(&state, from: 0, through: 1)
        let a = try #require({ state.startRequest(snapshotCapturedAt: 1, at: 1) }())
        #expect({ !state.complete(a, result: result, at: 1) }())
        liveFeed(&state, from: 1.25, through: 3)
        #expect(state.queuedIntent == nil && state.sentCount == 1 && state.visible == nil)
    }
    var state = LiveRecognitionSession()
    liveFeed(&state, from: 0, through: 1); state.discardQueuedIntent()
    liveFeed(&state, from: 1.25, through: 2)
    #expect(state.queuedIntent == nil && state.sentCount == 0 && state.adoptedCount == 1)
}
@Test func liveSceneChangeUnknownAndTimeoutRetainPreviousCard() throws {
    for mode in ["changed", "unknown", "timeout"] {
        var state = LiveRecognitionSession()
        liveFeed(&state, from: 0, through: 1)
        let a = try #require({ state.startRequest(snapshotCapturedAt: 1, at: 1) }())
        #expect({ state.complete(a, result: .init(barcodes: ["A"]), at: 1) }())
        liveFeed(&state, from: 1.25, through: 1.25)
        #expect(state.visible != nil)
        if mode == "timeout" { state.expire(at: 2.01) }
        else { state.observe(mode == "unknown" ? nil : liveFingerprint(true), capturedAt: 1.5, now: 1.5) }
        #expect(state.visible?.barcodes == ["A"] && state.visibleIsPrevious)
        #expect({ !state.complete(a, result: .init(names: ["late"]), at: 2.01) }())
        #expect(state.visible?.barcodes == ["A"])
    }
}
@Test func liveBudgetThreeAndExpiredSnapshotCannotSend() throws {
    var state = LiveRecognitionSession()
    for index in 0..<4 {
        state.stop()
        let start = Double(index)*3
        liveFeed(&state, from: start, through: start+1)
        if index < 3 {
            #expect({ state.startRequest(snapshotCapturedAt: start+1, at: start+1.76) == nil }())
            let request = try #require({ state.startRequest(snapshotCapturedAt: start+1, at: start+1.01) }())
            _ = state.complete(request, result: nil, at: start+1.02)
        } else { #expect(state.queuedIntent == nil) }
    }
    #expect(state.sentCount == 3)
}

@Test func liveCompletionReasonsSurviveEpisodeChurn() throws {
    var state = LiveRecognitionSession()
    liveFeed(&state, from: 0, through: 1)
    let ticket = try #require({ state.startRequest(snapshotCapturedAt: 1, at: 1) }())
    for i in 5...100 {
        let t=Double(i)/4
        state.observe(liveFingerprint(i.isMultiple(of:2)),capturedAt:t,now:t)
    }
    #expect(state.lastEpisodeReason == "scene-changed")
    #expect((state.lastEpisodeDistance ?? 0) > 0.035)
    #expect({ state.complete(ticket,result:.init(names:["A"]),at:25.01) }())
    #expect(state.lastCompletionReason == "accepted-history-ended-episode")
    #expect(state.discardedCount == 0 && state.visible?.names == ["A"] && state.visibleIsPrevious)
    #expect((state.lastCompletionFrameAge ?? 1) < 0.02)
}
@Test func liveStoppedAndEmptyCompletionHaveDistinctReasons() throws {
    for stopped in [false,true] {
        var state = LiveRecognitionSession()
        liveFeed(&state,from:0,through:1)
        let ticket=try #require({state.startRequest(snapshotCapturedAt:1,at:1)}())
        if stopped { state.stop() }
        #expect({!state.complete(ticket,result:nil,at:1.01)}())
        #expect(state.lastCompletionReason == (stopped ? "generation-stopped" : "empty-or-failed"))
        #expect(state.visible == nil)
    }
}

private func shownA(_ state: inout LiveRecognitionSession) throws -> LiveRecognitionSession.Request {
    liveFeed(&state,from:0,through:1)
    let a=try #require({state.startRequest(snapshotCapturedAt:1,at:1)}())
    #expect({state.complete(a,result:.init(names:["A"]),at:1.01)}())
    liveFeed(&state,from:1.25,through:1.25)
    #expect(state.visible?.names == ["A"] && !state.visibleIsPrevious)
    return a
}
@Test func retainedAIsAtomicallyReplacedByBAndOldReplyCannotOverwrite() throws {
    var state=LiveRecognitionSession();let a=try shownA(&state)
    liveFeed(&state,true,from:1.5,through:2.5)
    #expect(state.visible?.names == ["A"] && state.visibleIsPrevious)
    let b=try #require({state.startRequest(snapshotCapturedAt:2.5,at:2.5)}())
    #expect({state.complete(b,result:.init(names:["B"]),at:2.51)}())
    #expect(state.visible?.names == ["B"] && state.visibleIsPrevious && state.history.entries.count == 2)
    liveFeed(&state,true,from:2.75,through:2.75)
    #expect(state.visible?.names == ["B"] && !state.visibleIsPrevious)
    #expect({!state.complete(a,result:.init(names:["LATE A"]),at:2.76)}())
    #expect(state.visible?.names == ["B"] && state.visibleRequestID == b.intent.id)
}
@Test(arguments:[false,true]) func retainedASurvivesBEmptyOrFailure(empty:Bool) throws {
    var state=LiveRecognitionSession();_=try shownA(&state)
    liveFeed(&state,true,from:1.5,through:2.5)
    let b=try #require({state.startRequest(snapshotCapturedAt:2.5,at:2.5)}())
    #expect({!state.complete(b,result:empty ? RecognitionResult() : nil,at:2.51)}())
    liveFeed(&state,true,from:2.75,through:5)
    #expect(state.visible?.names == ["A"] && state.visibleIsPrevious)
    #expect(state.sentCount == 2 && state.queuedIntent == nil)
}
@Test func retainedCardSurvivesThreeRequestLimitAndContinuousMovement() throws {
    var state=LiveRecognitionSession()
    for n in 0..<3 {
        let start=Double(n)*2
        liveFeed(&state,n.isMultiple(of:2),from:start,through:start+1)
        let request=try #require({state.startRequest(snapshotCapturedAt:start+1,at:start+1)}())
        #expect({state.complete(request,result:.init(names:[String(n)]),at:start+1.01)}())
        liveFeed(&state,n.isMultiple(of:2),from:start+1.25,through:start+1.75)
    }
    for i in 25...60 {
        let t=Double(i)/4
        state.observe(liveFingerprint(i.isMultiple(of:2)),capturedAt:t,now:t)
        #expect(state.visible?.names == ["2"] && state.visibleIsPrevious)
    }
    #expect(state.sentCount == 3 && state.queuedIntent == nil)
}
@Test func retainedCardClearsOnStopAndPendingCannotRevive() throws {
    var state=LiveRecognitionSession();_=try shownA(&state)
    liveFeed(&state,true,from:1.5,through:2.5)
    let b=try #require({state.startRequest(snapshotCapturedAt:2.5,at:2.5)}())
    state.stop()
    #expect(state.visible == nil && !state.visibleIsPrevious && state.visibleRequestID == nil)
    #expect({!state.complete(b,result:.init(names:["LATE B"]),at:3)}())
    #expect(state.visible == nil && state.sentCount == 2)
}
@Test func successfulResponseRemainsReadableAfterLeaving() throws {
    var state=LiveRecognitionSession()
    liveFeed(&state,from:0,through:1)
    let a=try #require({state.startRequest(snapshotCapturedAt:1,at:1)}())
    #expect({state.complete(a,result:.init(names:["A"]),at:1.01)}())
    liveFeed(&state,true,from:1.25,through:2.25)
    #expect(state.visible?.names == ["A"] && state.visibleIsPrevious && state.history.entries.count == 1)
    let b=try #require({state.startRequest(snapshotCapturedAt:2.25,at:2.25)}())
    #expect({state.complete(b,result:.init(names:["B"]),at:2.26)}())
    liveFeed(&state,true,from:2.5,through:2.5)
    #expect(state.visible?.names == ["B"])
}


@Test func summaryAndOriginalReplaceTogetherAndLateOldSummaryCannotOverwrite() throws {
    var state=LiveRecognitionSession()
    liveFeed(&state,from:0,through:1)
    let a=try #require({state.startRequest(snapshotCapturedAt:1,at:1)}())
    #expect({state.complete(a,result:.init(names:["A"],summary:"第一件物品的簡介。",text:["原文A"]),at:1.01)}())
    liveFeed(&state,from:1.25,through:1.25)
    liveFeed(&state,true,from:1.5,through:2.5)
    #expect(state.visible?.summary == "第一件物品的簡介。" && state.visibleIsPrevious)
    let b=try #require({state.startRequest(snapshotCapturedAt:2.5,at:2.5)}())
    #expect({state.complete(b,result:.init(names:["B"],summary:"第二件物品的簡介。",text:["原文B"]),at:2.51)}())
    #expect(state.visible?.summary == "第二件物品的簡介。" && state.visibleIsPrevious)
    liveFeed(&state,true,from:2.75,through:2.75)
    #expect(state.visible?.summary == "第二件物品的簡介。" && state.visible?.text == ["原文B"])
    #expect({!state.complete(a,result:.init(summary:"過期的錯誤簡介"),at:2.76)}())
    #expect(state.visible?.summary == "第二件物品的簡介。")
    state.stop(); #expect(state.visible == nil)
}

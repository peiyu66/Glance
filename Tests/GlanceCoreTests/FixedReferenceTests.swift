import Foundation
import Testing
@testable import GlanceCore

private let fixedFP = SceneFingerprint(rgb: (0..<192).map { ($0 / 3) % 8 < 4 ? 0.15 : 0.85 }, side: 8)
private func fixedRequest(_ state: inout LiveRecognitionSession, _ start: Double, reference: Bool = true) throws -> LiveRecognitionSession.Request {
    for t in stride(from: start, through: start + 1, by: 0.25) { state.observe(fixedFP, capturedAt: t, now: t) }
    return try #require({ state.startRequest(snapshotCapturedAt: start + 1, at: start + 1, referenceAvailable: reference) }())
}
private func fixedSuccess(_ state: inout LiveRecognitionSession, _ start: Double, _ name: String) throws -> LiveRecognitionSession.Request {
    let request = try fixedRequest(&state, start)
    #expect({ state.complete(request, result: .init(names: [name]), at: start + 1.1) }())
    return request
}

@Test func fixedABAReusesOriginalAnswerWithoutAddingRequestOrHistory() throws {
    var state = LiveRecognitionSession()
    let a = try fixedSuccess(&state, 0, "A")
    _ = try fixedSuccess(&state, 3, "B")
    state.observe(fixedFP, capturedAt: 6, now: 6, matchingReferenceIDs: [a.intent.id])
    #expect(state.visible?.names == ["A"] && !state.visibleIsPrevious)
    #expect(state.sentCount == 2 && state.history.entries.map(\.sequence) == [1, 2])
    #expect(state.queuedIntent == nil && state.gate == "fixed-reference-reused")
    state.observe(nil, capturedAt: 6.25, now: 6.25)
    #expect(state.visible?.names == ["A"] && state.visibleIsPrevious)
}
@Test func fixedAAAHitsAcrossEpisodeChangesKeepOneOriginalSnapshot() throws {
    var state = LiveRecognitionSession()
    let a = try fixedSuccess(&state, 0, "A")
    for t in [2.0, 4.0, 6.0] {
        state.observe(fixedFP, capturedAt: t, now: t, sceneChangeReason: "registered-content-changed", matchingReferenceIDs: [a.intent.id])
        #expect(state.visible?.names == ["A"] && !state.visibleIsPrevious && state.queuedIntent == nil)
    }
    #expect(state.sentCount == 1 && state.references.entries.count == 1)
    #expect(state.references.entries.first?.capturedAt == a.snapshotCapturedAt)
}
@Test func fixedPendingMatchSuppressesQueuedSameObjectWithoutInventingAnswer() throws {
    var state = LiveRecognitionSession()
    let a = try fixedRequest(&state, 0)
    for t in stride(from: 3.0, through: 4.0, by: 0.25) { state.observe(fixedFP, capturedAt: t, now: t) }
    #expect(state.queuedIntent != nil)
    state.observe(fixedFP, capturedAt: 4.25, now: 4.25, matchingReferenceIDs: [a.intent.id])
    #expect(state.queuedIntent == nil && state.visible == nil && state.gate == "same-reference-pending")
    #expect(state.references.entries.first?.status == .pending && state.sentCount == 1)
    #expect({ !state.complete(a, result: nil, at: 4.3) }())
    state.observe(fixedFP, capturedAt: 4.5, now: 4.5)
    #expect(state.references.entries.isEmpty && state.queuedIntent != nil)
}
@Test func fixedLateReplyPromotesRequestSnapshotInsteadOfLaterView() throws {
    var state = LiveRecognitionSession()
    let a = try fixedRequest(&state, 0)
    for t in stride(from: 3.0, through: 4.0, by: 0.25) { state.observe(fixedFP, capturedAt: t, now: t) }
    #expect({ state.complete(a, result: .init(names: ["A"]), at: 4.1) }())
    #expect(state.references.entries.first?.id == a.intent.id)
    #expect(state.references.entries.first?.capturedAt == 1 && state.references.entries.first?.status == .answered)
    #expect(state.visibleIsPrevious)
    let b = try #require({ state.startRequest(snapshotCapturedAt: 4, at: 4.2, referenceAvailable: true) }())
    #expect(b.intent.id != a.intent.id && state.references.entries.last?.capturedAt == 4)
}
@Test func fixedLateAReplyDoesNotReplaceFreshlyMatchedB() throws {
    var state = LiveRecognitionSession()
    let b = try fixedSuccess(&state, 0, "B")
    let a = try fixedRequest(&state, 3)
    state.observe(fixedFP, capturedAt: 4.25, now: 4.25, matchingReferenceIDs: [b.intent.id])
    #expect({ state.complete(a, result: .init(names: ["A"]), at: 4.3) }())
    #expect(state.visible?.names == ["B"] && !state.visibleIsPrevious)
    #expect(state.history.latest?.result.names == ["A"] && state.references.entries.count == 2)
}
@Test func fixedMissBackFaceAndAmbiguousCandidatesUseOrdinaryRequestGate() throws {
    var state = LiveRecognitionSession()
    let a = try fixedSuccess(&state, 0, "A front")
    let b = try fixedSuccess(&state, 3, "B")
    for t in stride(from: 6.0, through: 7.0, by: 0.25) {
        state.observe(fixedFP, capturedAt: t, now: t, matchingReferenceIDs: [a.intent.id, b.intent.id])
    }
    #expect(state.queuedIntent != nil && state.visible?.names == ["B"] && state.visibleIsPrevious)
    let back = try #require({ state.startRequest(snapshotCapturedAt: 7, at: 7, referenceAvailable: true) }())
    #expect(back.intent.id != a.intent.id && state.sentCount == 3)
}
@Test func fixedReuseStillWorksAtThreeRequestBudget() throws {
    var state = LiveRecognitionSession()
    let a = try fixedSuccess(&state, 0, "A")
    _ = try fixedSuccess(&state, 3, "B"); _ = try fixedSuccess(&state, 6, "C")
    state.observe(fixedFP, capturedAt: 9, now: 9, matchingReferenceIDs: [a.intent.id])
    #expect(state.visible?.names == ["A"] && !state.visibleIsPrevious && state.sentCount == 3)
}
@Test func fixedPauseClearsReferencesPreservesTextAndRejectsOldLateReply() throws {
    var state = LiveRecognitionSession()
    let a = try fixedSuccess(&state, 0, "A")
    let b = try fixedRequest(&state, 3)
    state.stop(preservingHistory: true, resetBudget: true)
    #expect(state.references.entries.isEmpty && state.visible?.names == ["A"] && state.visibleIsPrevious)
    #expect(state.sentCount == 0 && state.lifetimeSentCount == 2 && state.inflightRequest == b)
    #expect({ !state.complete(b, result: .init(names: ["OLD B"]), at: 5) }())
    state.observe(fixedFP, capturedAt: 6, now: 6, matchingReferenceIDs: [a.intent.id])
    #expect(state.references.entries.isEmpty && state.visibleIsPrevious)
    state.stop()
    #expect(state.visible == nil && state.references.entries.isEmpty)
    let restarted = LiveRecognitionSession()
    #expect(restarted.history.entries.isEmpty && restarted.references.entries.isEmpty)
}
@Test func fixedExpirationNeverExtendsOnHitAndPreservesReadableAnswer() throws {
    var state = LiveRecognitionSession()
    let a = try fixedSuccess(&state, 0, "A")
    state.observe(fixedFP, capturedAt: 90.5, now: 90.5, matchingReferenceIDs: [a.intent.id])
    #expect(!state.visibleIsPrevious)
    state.expire(at: 91)
    #expect(state.references.entries.isEmpty && state.visibleIsPrevious && state.visible?.names == ["A"])
    state.observe(fixedFP, capturedAt: 91.1, now: 91.1, matchingReferenceIDs: [a.intent.id])
    #expect(state.visibleIsPrevious)
}
@Test func fixedStaleOrInvalidFrameCannotConfirmIdentity() throws {
    var state = LiveRecognitionSession()
    let a = try fixedSuccess(&state, 0, "A")
    state.observe(fixedFP, capturedAt: 2, now: 3, matchingReferenceIDs: [a.intent.id])
    #expect(state.visibleIsPrevious && state.queuedIntent == nil)
    state.observe(nil, capturedAt: 4, now: 4, matchingReferenceIDs: [a.intent.id])
    #expect(state.visibleIsPrevious && state.queuedIntent == nil)
}
@Test func fixedAbsentDescriptorOrExpiredReplyCannotCreateReference() throws {
    var state = LiveRecognitionSession()
    let a = try fixedRequest(&state, 0, reference: false)
    #expect({ state.complete(a, result: .init(names: ["A"]), at: 1.1) }())
    #expect(state.references.entries.isEmpty && state.visible?.names == ["A"])
    let b = try fixedRequest(&state, 3)
    #expect({ state.complete(b, result: .init(names: ["B"]), at: 100) }())
    #expect(state.references.entries.isEmpty && state.history.entries.count == 2)
}
@Test func fixedCatalogCapacityEvictsOldestAndDoesNotRecreateCompletedIdentity() {
    var refs = FixedReferenceCatalog(capacity: 2)
    let gen = UUID(), ids = [UUID(), UUID(), UUID()]
    for (i, id) in ids.enumerated() {
        #expect({ refs.begin(id: id, generation: gen, capturedAt: Double(i), now: Double(i)) }())
        refs.complete(id: id, generation: gen, accepted: true, now: Double(i) + 0.1)
    }
    #expect(refs.entries.map(\.id) == Array(ids.suffix(2)))
    refs.clear(); refs.complete(id: ids[2], generation: gen, accepted: true, now: 4)
    #expect(refs.entries.isEmpty)
}

@Test func fixedWorkerMustEvaluateEntireCurrentCatalogBeforeReuseOrNewRequest() throws {
    var state = LiveRecognitionSession()
    let a = try fixedSuccess(&state, 0, "A")
    let b = try fixedSuccess(&state, 3, "B")
    for t in stride(from: 6.0, through: 7.0, by: 0.25) {
        state.observe(fixedFP, capturedAt: t, now: t, matchingReferenceIDs: [a.intent.id], evaluatedReferenceIDs: [a.intent.id])
    }
    #expect(state.queuedIntent == nil && state.visible?.names == ["B"] && state.visibleIsPrevious)
    #expect(state.gate == "awaiting-reference-evaluation")
    state.observe(fixedFP, capturedAt: 7.25, now: 7.25, matchingReferenceIDs: [a.intent.id], evaluatedReferenceIDs: [a.intent.id, b.intent.id])
    #expect(state.visible?.names == ["A"] && !state.visibleIsPrevious && state.sentCount == 2)
}

@Test func fixedMemoryPressureKeepsPaidHistoryBudgetAndPendingTransport() throws {
    var state = LiveRecognitionSession()
    let a = try fixedSuccess(&state, 0, "A")
    let b = try fixedRequest(&state, 3)
    state.observe(fixedFP, capturedAt: 4.25, now: 4.25, matchingReferenceIDs: [a.intent.id])
    state.purgeReferences()
    #expect(state.visible?.names == ["A"] && state.visibleIsPrevious && state.history.entries.count == 1)
    #expect(state.references.entries.isEmpty && state.inflightRequest == b && state.sentCount == 2)
    #expect({ state.complete(b, result: .init(names: ["B"]), at: 4.5) }())
    #expect(state.references.entries.isEmpty && state.history.entries.count == 2 && state.sentCount == 2)
}

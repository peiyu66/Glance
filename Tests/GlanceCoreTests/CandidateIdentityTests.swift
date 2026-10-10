import Testing
@testable import GlanceCore

private func solid(_ channels: [Float]) -> SceneFingerprint {
    SceneFingerprint(rgb: Array(repeating: channels, count: 32*32).flatMap { $0 }, side: 32)
}

@Test func unstableCandidatesDoNotAccumulateButConfirmedAndPendingAreRetained() throws {
    var memory = TargetMemory(requiresConfirmation: true)
    let a = solid([0.1,0.3,0.5]), b = solid([0.6,0.1,0.2]), c = solid([0.2,0.7,0.1])
    let firstValue = memory.resolve(a, at: 0, labelSignature: "same")
    let first = try #require(firstValue)
    let secondValue = memory.resolve(b, at: 0.25, labelSignature: "same")
    let second = try #require(secondValue)
    #expect(first != second && memory.entries.count == 1 && memory.discardedCandidates == 1)
    memory.confirm(second)
    let thirdValue = memory.resolve(c, at: 0.5, labelSignature: "same")
    let third = try #require(thirdValue)
    #expect(memory.entries.count == 2 && memory.entries.contains { $0.id == second && $0.confirmed })
    _ = memory.resolve(a, at: 0.75, protectedID: third, labelSignature: "different")
    #expect(memory.entries.contains { $0.id == third })
    #expect(memory.entries.contains { $0.id == second })
    _ = memory.resolve(a, at: 1, protectedID: third, labelSignature: "another")
    #expect(memory.entries.count == 3)
}

@Test func layoutStillRequiresVisualEvidenceAndUnknownTextNeverUsesReadablePath() throws {
    var memory = TargetMemory(requiresConfirmation: true)
    let fp = solid([0.1,0.4,0.8])
    let idValue = memory.resolve(fp, at: 0, labelSignature: "123")
    let id = try #require(idValue); memory.confirm(id)
    #expect(memory.resolve(fp, at: 1, labelSignature: "123", additionalMatch: { _ in false }) == nil)
    #expect(memory.lastDecision == "visual-rejected" && memory.entries.count == 1)
    #expect(memory.resolve(fp, at: 2, labelSignature: "") == nil)
    #expect(memory.lastDecision == "label-missing-mismatch" && memory.directComparisons == 0)
    let changed = memory.resolve(fp, at: 3, labelSignature: "128", additionalMatch: { _ in true })
    #expect(changed != nil && changed != id)
    #expect(memory.directComparisons == 0 && memory.alignmentComparisons == 0)
}

@Test func multipleConfirmedCandidatesNeverUseCheapScoreToChooseAmbiguousIdentity() throws {
    var memory = TargetMemory(threshold: 0.1, requiresConfirmation: true)
    let aValue = memory.resolve(solid([0.1,0.3,0.5]), at: 0, labelSignature: "same")
    let a = try #require(aValue); memory.confirm(a)
    let bValue = memory.resolve(solid([0.3,0.1,0.5]), at: 1, labelSignature: "same")
    let b = try #require(bValue); memory.confirm(b)
    #expect(a != b)
    let ambiguous = memory.resolve(solid([0.2,0.2,0.5]), at: 2, labelSignature: "same")
    #expect(ambiguous == nil && memory.lastDecision == "ambiguous-candidates")
    #expect(memory.directComparisons == 0 && memory.alignmentComparisons == 2)
}

@Test func confirmedIdentityAndLateResultsRespectSingleRequestBudget() throws {
    var memory = TargetMemory(requiresConfirmation: true), state = RecognitionState()
    let fp = solid([0.1,0.4,0.8]); let policy = RequestAdmission(trialLimit: 1)
    let aValue = memory.resolve(fp, at: 0, labelSignature: "123")
    let a = try #require(aValue)
    _ = state.observe(a, at: 0)
    let firstValue = state.observe(a, at: 1)
    let first = try #require(firstValue); memory.confirm(a)
    let b = memory.resolve(fp, at: 1.25, protectedID: a, labelSignature: "128")
    _ = state.observe(b, at: 1.25, allowRequest: false)
    state.complete(first, result: RecognitionResult(names: ["A"]))
    let allowed = policy.allows(sent: 1, inflight: false, blocked: false, now: 10, nextAllowed: 0)
    #expect(!allowed)
    #expect(state.observe(b, at: 10, allowRequest: allowed) == nil && state.visible == nil)
    let returned = memory.resolve(fp, at: 10.25, labelSignature: "123")
    #expect(returned == a)
    _ = state.observe(returned, at: 10.25, allowRequest: false)
    #expect(state.visible == nil)
    _ = state.observe(returned, at: 11.25, allowRequest: false)
    #expect(state.visible?.names == ["A"])
}

@Test func movingUnverifiedFramesCannotCreateOrReplacePendingIdentity() throws {
    var memory = TargetMemory(capacity: 2, requiresConfirmation: true)
    let fp = solid([0.1,0.4,0.8])
    #expect(memory.resolve(fp, at: 0, labelSignature: "123", allowCreation: false) == nil)
    #expect(memory.entries.isEmpty)
    let firstValue = memory.resolve(fp, at: 1, labelSignature: "123")
    let first = try #require(firstValue); memory.confirm(first)
    let pendingValue = memory.resolve(solid([0.8,0.1,0.3]), at: 2, labelSignature: "pending")
    let pending = try #require(pendingValue)
    let before = memory.entries.map(\.id)
    for (index, label) in ["128", "", "new"].enumerated() {
        #expect(memory.resolve(fp, at: Double(index+3), protectedID: pending, labelSignature: label, allowCreation: false) == nil)
        #expect(memory.entries.map(\.id) == before)
    }
    #expect(memory.resolve(fp, at: 6, protectedID: pending, labelSignature: "123", allowCreation: false, additionalMatch: { _ in false }) == nil)
    #expect(memory.lastDecision == "visual-rejected")
    #expect(memory.resolve(fp, at: 7, protectedID: pending, labelSignature: "123", allowCreation: false, additionalMatch: { _ in true }) == first)
    #expect(memory.entries.map(\.id) == before)
}

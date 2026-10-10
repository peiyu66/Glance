import Testing
@testable import GlanceCore

private func line(_ text: String, y: Double = 0.3, confidence: Float = 0.99, x: Double = 0.2) -> RegionalText.Line {
    .init(text: text, confidence: confidence, box: .init(x:x,y:y,width:0.5,height:0.08))
}
@Test func objectRegionExcludesEnteringBackgroundWordsWithoutIgnoringObjectDigits() {
    let object=RegionalText.Box(x:0.1,y:0.2,width:0.8,height:0.6)
    let base=RegionalText(lines:[line("Brand"),line("123",y:0.5)],object:object)
    let background=RegionalText(lines:[line("Brand"),line("123",y:0.5),line("SALE",y:0.02)],object:object)
    #expect(background.compare(to:base).resultCompatible)
    let changed=RegionalText(lines:[line("Brand"),line("128",y:0.5),line("SALE",y:0.02)],object:object)
    #expect(changed.compare(to:base).conflicts == 1)
    #expect(!changed.compare(to:base).acquisitionCompatible)
}
@Test func partialWordsAndOcclusionPermitOnlyProvisionalContinuityNeverResultReuse() {
    let full=RegionalText(lines:[line("Brand"),line("CODE123",y:0.5)])
    for partial in [RegionalText(lines:[line("Brand")]),RegionalText(lines:[line("Brand"),line("CODE12",y:0.5)]),RegionalText(lines:[line("Brand"),line("CODE1234",y:0.5)]),RegionalText(lines:[line("Brand"),line("CODE128",y:0.5,confidence:0.6)])] {
        let comparison=partial.compare(to:full)
        #expect(comparison.acquisitionCompatible)
        #expect(!comparison.resultCompatible)
    }
    #expect(!RegionalText(lines:[]).compare(to:full).acquisitionCompatible)
    #expect(!RegionalText(lines:[]).compare(to:RegionalText(lines:[])).resultCompatible)
}
@Test func lowConfidenceFlickerAndUnmatchedRegionsDoNotBecomeIdentityEvidence() {
    let brand=RegionalText(lines:[line("Brand")])
    let noise=RegionalText(lines:[line("Brand"),line("128",y:0.5,confidence:0.3)])
    #expect(noise.compare(to:brand).acquisitionCompatible)
    #expect(!noise.compare(to:brand).resultCompatible)
    let moved=RegionalText(lines:[line("Brand",y:0.7)])
    #expect(!moved.compare(to:brand).acquisitionCompatible)
    let digitOnly=RegionalText(lines:[line("128",confidence:0.99)])
    #expect(!digitOnly.compare(to:RegionalText(lines:[line("123")])).acquisitionCompatible)
}

@Test func changingRegionalTextCanTriggerOnceButCannotRevealCacheUntilCompleteEvidenceIsStable() throws {
    let full=RegionalText(lines:[line("Brand"),line("CODE123",y:0.5)])
    let subset=RegionalText(lines:[line("Brand")])
    let low=RegionalText(lines:[line("Brand"),line("CODE128",y:0.5,confidence:0.6)])
    let wrong=RegionalText(lines:[line("Brand"),line("CODE128",y:0.5)])
    let fp=SceneFingerprint(rgb:Array(repeating:Float(0.4),count:32*32*3),side:32)
    var memory=TargetMemory(requiresConfirmation:true), state=RecognitionState()
    var current: String?, previous: RegionalText?, pending: RecognitionState.Request?
    for (i,evidence) in [full,subset,low,full,full].enumerated() {
        let target=memory.resolve(fp,at:Double(i)*0.25,labelSignature:"variable-\(i)",regional:evidence,continuityID:current,previousRegional:previous)
        #expect(target != nil)
        pending=state.observe(target,at:Double(i)*0.25,allowDisplay:memory.permitsResult(target,regional:evidence)) ?? pending
        current=target; previous=evidence
    }
    let request=try #require(pending); memory.confirm(request.target);memory.bindResultEvidence(request.target,regional:full)
    state.complete(request,result:RecognitionResult(names:["original"]))
    #expect(memory.resolve(fp,at:1.25,regional:subset,continuityID:current,previousRegional:full)==current)
    _=state.observe(current,at:1.25,allowRequest:false,allowDisplay:memory.permitsResult(current,regional:subset))
    #expect(state.visible==nil && state.lastGate=="cached-evidence-incomplete")
    let other=memory.resolve(fp,at:1.5,regional:wrong,continuityID:current,previousRegional:subset)
    #expect(other != nil && other != current)
    _=state.observe(other,at:1.5,allowRequest:false,allowDisplay:memory.permitsResult(other,regional:wrong))
    #expect(state.visible==nil)
    let recovered=memory.resolve(fp,at:2,regional:full,continuityID:other,previousRegional:wrong)
    #expect(recovered==request.target)
    _=state.observe(recovered,at:2,allowRequest:false,allowDisplay:memory.permitsResult(recovered,regional:full))
    _=state.observe(recovered,at:2.75,allowRequest:false,allowDisplay:true)
    #expect(state.visible==nil)
    _=state.observe(recovered,at:3,allowRequest:false,allowDisplay:true)
    #expect(state.visible?.names==["original"])
    #expect(!memory.permitsResult(recovered,regional:RegionalText(lines:[])))
    #expect(memory.resolve(fp,at:3.25,regional:full,additionalMatch:{ _ in false })==nil)
}

@Test func partialEvidenceCannotReacquireCachedIdentityAcrossAnUnknownGap() throws {
    let full=RegionalText(lines:[line("Brand"),line("123",y:0.5)])
    let subset=RegionalText(lines:[line("Brand")])
    let fp=SceneFingerprint(rgb:Array(repeating:Float(0.4),count:32*32*3),side:32)
    var memory=TargetMemory(requiresConfirmation:true)
    let value=memory.resolve(fp,at:0,regional:full)
    let id=try #require(value);memory.confirm(id);memory.bindResultEvidence(id,regional:full)
    #expect(memory.resolve(fp,at:1,regional:RegionalText(lines:[]))==nil)
    #expect(memory.resolve(fp,at:2,regional:subset)==nil)
    #expect(memory.lastDecision=="regional-incomplete-without-continuity")
    #expect(memory.resolve(fp,at:3,regional:full)==id)
}

@Test func overlappingOCRAlternativesCannotRevealCachedAnswer() {
    let original=RegionalText(lines:[line("Brand"),line("123",y:0.5)])
    let duplicated=RegionalText(lines:[line("Brand"),line("123",y:0.5),line("128",y:0.5)])
    #expect(!duplicated.compare(to:original).resultCompatible)
    #expect(!duplicated.compare(to:original).acquisitionCompatible)
}

@Test func unlabeledObjectCanTriggerThroughContinuousVisualEvidenceButCannotBorrowCacheAcrossGap() throws {
    let blank=RegionalText(lines:[])
    let fp=SceneFingerprint(rgb:Array(repeating:Float(0.4),count:32*32*3),side:32)
    var memory=TargetMemory(requiresConfirmation:true), state=RecognitionState()
    let initial=memory.resolve(fp,at:0,regional:blank)
    let id=try #require(initial)
    _=state.observe(id,at:0,allowDisplay:false)
    let tracked=memory.resolve(fp,at:1,regional:blank,continuityID:id,previousRegional:blank,additionalMatch:{ _ in true })
    #expect(tracked==id && memory.lastTextDecision=="continuous-unlabeled-visual")
    let pending=state.observe(tracked,at:1,allowDisplay:false)
    let request=try #require(pending);memory.confirm(id);memory.bindResultEvidence(id,regional:blank)
    state.complete(request,result:RecognitionResult(names:["object"]))
    _=state.observe(id,at:2,allowRequest:false,allowDisplay:memory.permitsResult(id,regional:blank))
    _=state.observe(id,at:3,allowRequest:false,allowDisplay:memory.permitsResult(id,regional:blank))
    #expect(state.visible?.names==["object"])
    #expect(memory.resolve(fp,at:3.25,regional:blank,continuityID:id,previousRegional:blank,additionalMatch:{ _ in false })==nil)
    #expect(!memory.permitsResult(id,regional:blank))
    _=state.observe(nil,at:3.25,allowRequest:false,allowDisplay:false)
    let afterGap=memory.resolve(fp,at:4,regional:blank)
    #expect(afterGap != nil && afterGap != id)
    #expect(!memory.permitsResult(afterGap,regional:blank))
    let uncertain=RegionalText(lines:[line("maybe",confidence:0.3)])
    #expect(memory.resolve(fp,at:5,regional:uncertain,continuityID:afterGap,previousRegional:blank)==nil)
}

@Test func cachedLabeledObjectDoesNotBlockADifferentBareObject() throws {
    let a=SceneFingerprint(rgb:Array(repeating:Float(0.2),count:32*32*3),side:32)
    let b=SceneFingerprint(rgb:Array(repeating:Float(0.8),count:32*32*3),side:32)
    let labeled=RegionalText(lines:[line("123")]), bare=RegionalText(lines:[])
    var memory=TargetMemory(requiresConfirmation:true)
    let first=memory.resolve(a,at:0,regional:labeled)
    let id=try #require(first);memory.confirm(id);memory.bindResultEvidence(id,regional:labeled)
    #expect(memory.resolve(a,at:1,regional:bare)==nil)
    let other=memory.resolve(b,at:2,regional:bare)
    #expect(other != nil && other != id)
    #expect(!memory.permitsResult(other,regional:bare))
}

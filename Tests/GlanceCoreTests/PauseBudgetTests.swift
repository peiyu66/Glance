import Foundation
import Testing
@testable import GlanceCore

private func batchFeed(_ state:inout LiveRecognitionSession,_ start:Double,_ opposite:Bool=false) {
    let fp=SceneFingerprint(rgb:(0..<192).map { (((($0/3)%8)<4) != opposite) ? 0.15 : 0.85 },side:8)
    for t in stride(from:start,through:start+1,by:0.25) { state.observe(fp,capturedAt:t,now:t) }
}
private func batchSuccess(_ state:inout LiveRecognitionSession,_ start:Double,_ label:String) throws -> LiveRecognitionSession.Request {
    batchFeed(&state,start,Int(start)%4==2)
    let request=try #require({state.startRequest(snapshotCapturedAt:start+1,at:start+1)}())
    #expect({state.complete(request,result:.init(names:[label]),at:start+1.1)}())
    return request
}
@Test func threeAttemptsThenManualPauseAllowsBWithoutLosingHistory() throws {
    var state=LiveRecognitionSession()
    for i in 0..<3 { _=try batchSuccess(&state,Double(i)*2,"A\(i+1)") }
    batchFeed(&state,6,true)
    #expect(state.sentCount==3 && state.lifetimeSentCount==3 && state.queuedIntent==nil)
    #expect(state.gate=="batch-request-limit")
    let previous=state.history.entries
    state.stop(preservingHistory:true,resetBudget:true)
    #expect(state.sentCount==0 && state.lifetimeSentCount==3 && state.history.entries==previous)
    #expect(state.visible?.names==["A3"] && state.visibleIsPrevious)
    let b=try batchSuccess(&state,8,"B")
    #expect(b.sequence==4 && b.batchSequence==1 && state.sentCount==1)
    #expect(state.history.entries.map(\.sequence)==[1,2,3,4] && state.visible?.names==["B"])
}
@Test func repeatedManualPauseDoesNotResetSequenceOrEraseCompletedAnswers() throws {
    var state=LiveRecognitionSession()
    _=try batchSuccess(&state,0,"A")
    let previous=state.history.entries
    for _ in 0..<5 { state.stop(preservingHistory:true,resetBudget:true) }
    #expect(state.sentCount==0 && state.lifetimeSentCount==1 && state.history.entries==previous)
    let next=try batchSuccess(&state,2,"B")
    #expect(next.sequence==2 && next.batchSequence==1 && state.history.entries.count==2)
}
@Test func pendingOldBatchCannotWriteOrReleaseNewTransportAfterPause() throws {
    var state=LiveRecognitionSession()
    _=try batchSuccess(&state,0,"A");_=try batchSuccess(&state,2,"B")
    batchFeed(&state,4)
    let old=try #require({state.startRequest(snapshotCapturedAt:5,at:5)}())
    state.stop(preservingHistory:true,resetBudget:true)
    batchFeed(&state,6,true)
    #expect(state.sentCount==0 && state.lifetimeSentCount==3 && state.inflightRequest==old)
    #expect({state.startRequest(snapshotCapturedAt:7,at:7)==nil}())
    #expect({!state.complete(old,result:.init(names:["OLD C"]),at:7.1)}())
    let current=try #require({state.startRequest(snapshotCapturedAt:7,at:7.2)}())
    #expect(current.sequence==4 && current.batchSequence==1 && current.intent.id != old.intent.id)
    #expect({!state.complete(old,result:.init(names:["DUPLICATE OLD C"]),at:7.25)}())
    #expect(state.inflightRequest==current && state.sentCount==1)
    #expect({state.complete(current,result:.init(names:["NEW D"]),at:7.3)}())
    #expect(state.history.entries.map(\.sequence)==[1,2,4] && state.visible?.names==["NEW D"])
}
@Test func backgroundStillClearsHistoryAndKeepsCurrentBatchSpent() throws {
    var state=LiveRecognitionSession()
    for i in 0..<3 { _=try batchSuccess(&state,Double(i)*2,"A") }
    state.stop()
    #expect(state.sentCount==3 && state.history.entries.isEmpty && state.lifetimeSentCount==3)
    batchFeed(&state,6)
    #expect(state.queuedIntent==nil)
    state.stop(preservingHistory:true,resetBudget:true)
    let next=try batchSuccess(&state,8,"B")
    #expect(next.sequence==4 && next.batchSequence==1 && state.history.entries.count==1)
}
@Test func twoCompleteBatchesRetainAllSixUniqueOrderedAnswers() throws {
    var state=LiveRecognitionSession()
    var ids=Set<UUID>()
    for i in 0..<6 {
        if i==3 { state.stop(preservingHistory:true,resetBudget:true) }
        let r=try batchSuccess(&state,Double(i)*2,"答案\(i+1)")
        ids.insert(r.intent.id)
        #expect(r.sequence==i+1 && r.batchSequence==i%3+1)
    }
    #expect(state.sentCount==3 && state.lifetimeSentCount==6 && ids.count==6)
    #expect(state.history.entries.map(\.sequence)==[1,2,3,4,5,6])
    #expect(state.visible?.names==["答案6"])
}
@Test func failedAttemptsDoNotRefundWithoutExplicitManualPause() throws {
    var state=LiveRecognitionSession()
    for i in 0..<3 {
        let start=Double(i)*2;batchFeed(&state,start,i%2==1)
        let r=try #require({state.startRequest(snapshotCapturedAt:start+1,at:start+1)}())
        #expect({!state.complete(r,result:nil,at:start+1.1)}())
    }
    #expect(state.sentCount==3 && state.lifetimeSentCount==3 && state.history.entries.isEmpty)
    state.stop(preservingHistory:true,resetBudget:true)
    let next=try batchSuccess(&state,6,"第一筆成功")
    #expect(next.sequence==4 && next.batchSequence==1 && state.sentCount==1)
}

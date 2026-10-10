import Foundation
import Testing
@testable import GlanceCore

private func historyFingerprint(_ opposite:Bool=false)->SceneFingerprint {
    .init(rgb:(0..<(8*8*3)).map { (((($0/3)%8)<4) != opposite) ? 0.15 : 0.85 },side:8)
}
private func historyFeed(_ state:inout LiveRecognitionSession,from:Double,opposite:Bool=false) {
    for t in stride(from:from,through:from+1,by:0.25) { state.observe(historyFingerprint(opposite),capturedAt:t,now:t) }
}
@Test func allThreeSuccessfulAnswersSurviveRecordedEpisodeLossTimes() throws {
    var state=LiveRecognitionSession()
    for (index,delay) in [7.829,4.634,4.373].enumerated() {
        let begin=Double(index)*10
        historyFeed(&state,from:begin)
        let request=try #require({state.startRequest(snapshotCapturedAt:begin+1,at:begin+1)}())
        #expect(request.sequence == index+1)
        let loss=begin+1+(index==2 ? 1.324 : 0.792)
        state.observe(nil,capturedAt:loss,now:loss)
        #expect({state.complete(request,result:.init(names:[index==1 ? "B" : "A"],summary:"合成成功答案 \(index+1)"),at:begin+1+delay)}())
        #expect(state.history.entries.count == index+1 && state.visibleIsPrevious)
        #expect(state.history.latest?.sequence == index+1)
    }
    #expect(state.sentCount==3 && state.history.entries.map(\.sequence)==[1,2,3])
    historyFeed(&state,from:40)
    #expect(state.queuedIntent==nil && state.visible != nil && state.visibleIsPrevious)
}
@Test func outOfOrderSuccessIsSavedButCannotReplaceNewerSuccess() {
    var history=RecognitionHistory()
    let entries=[1,2,3].map { i in RecognitionHistory.Entry(id:UUID(),sequence:i,capturedAt:Double(i),completedAt:10,result:.init(names:["答案\(i)"])) }
    #expect({history.insert(entries[2])}())
    #expect({history.insert(entries[0])}())
    #expect({history.insert(entries[1])}())
    #expect(history.entries.map(\.sequence)==[1,2,3] && history.latest?.result.names==["答案3"])
    #expect({!history.insert(entries[0]) && history.entries.count==3}())
}
@Test func emptyAndInvalidHistoryCannotReplaceSuccessfulAnswers() {
    var history=RecognitionHistory()
    let good=RecognitionHistory.Entry(id:UUID(),sequence:1,capturedAt:1,completedAt:2,result:.init(summary:"保留這個成功答案"))
    #expect({history.insert(good)}())
    #expect({!history.insert(.init(id:UUID(),sequence:2,capturedAt:2,completedAt:3,result:.init()))}())
    #expect({!history.insert(.init(id:UUID(),sequence:3,capturedAt:4,completedAt:3,result:.init(names:["無效時序"])))}())
    #expect(history.latest==good && history.entries.count==1)
}
@Test func manualPausePreservesReadingButRevokesPendingReplyPermission() throws {
    var state=LiveRecognitionSession()
    historyFeed(&state,from:0)
    let first=try #require({state.startRequest(snapshotCapturedAt:1,at:1)}())
    #expect({state.complete(first,result:.init(names:["A"]),at:1.1)}())
    historyFeed(&state,from:2,opposite:true)
    let second=try #require({state.startRequest(snapshotCapturedAt:3,at:3)}())
    state.stop(preservingHistory:true)
    #expect(state.visible?.names==["A"] && state.visibleIsPrevious && state.history.entries.count==1)
    #expect(state.inflightRequest==second && state.sentCount==2)
    #expect({!state.complete(second,result:.init(names:["舊世代B"]),at:3.5)}())
    #expect(state.history.entries.count==1)
    historyFeed(&state,from:4)
    let third=try #require({state.startRequest(snapshotCapturedAt:5,at:5)}())
    #expect({state.complete(third,result:.init(names:["新世代C"]),at:5.1)}())
    #expect(state.history.entries.map(\.sequence)==[1,3] && state.visible?.names==["新世代C"])
    state.stop()
    #expect(state.history.entries.isEmpty && state.visible==nil && state.sentCount==3)
}
@Test func backgroundClearsHistoryAndThirdReplyCannotRepopulateIt() throws {
    var state=LiveRecognitionSession()
    for i in 0..<3 {
        let begin=Double(i)*3
        historyFeed(&state,from:begin,opposite:i%2==1)
        let request=try #require({state.startRequest(snapshotCapturedAt:begin+1,at:begin+1)}())
        if i==2 {
            state.stop()
            #expect({!state.complete(request,result:.init(names:["晚第三筆"]),at:begin+1.1)}())
        } else { #expect({state.complete(request,result:.init(names:["先前成功"]),at:begin+1.1)}()) }
    }
    #expect(state.history.entries.isEmpty && state.visible==nil && state.sentCount==3)
}

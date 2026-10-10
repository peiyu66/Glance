import Foundation
import Testing
@testable import GlanceCore

private func displayTicket() throws -> FirstCaptureGate.Request {
    var capture = FirstCaptureGate()
    let fp = SceneFingerprint(rgb:[Float](repeating:0.5,count:4*4*3),side:4)
    var ticket:FirstCaptureGate.Request?
    for i in 0...4 { ticket=capture.observe(fp,capturedAt:Double(i)*0.25,now:Double(i)*0.25) }
    return try #require(ticket)
}
@Test func currentDisplayRequiresAFrameCapturedAfterDelayedResponse() throws {
    for delay in [0.0,4.0,8.0] {
        let ticket=try displayTicket();var gate=CurrentDisplayGate();gate.bind(ticket)
        let end=1+delay
        if delay>0 { for i in 1...Int(delay*4) { let t=1+Double(i)*0.25;gate.observe(matchesSnapshot:true,capturedAt:t,now:t,generation:ticket.generation) } }
        gate.complete(ticket,result:RecognitionResult(names:["generated"]),at:end)
        #expect(gate.visible == nil)
        gate.observe(matchesSnapshot:true,capturedAt:end+0.25,now:end+0.3,generation:ticket.generation)
        #expect(gate.visible?.names == ["generated"])
    }
}
@Test func currentDisplayRevokesMismatchUnknownAndGapWithoutReacquiring() throws {
    for kind in ["mismatch","unknown","gap","stale","generation"] {
        let ticket=try displayTicket();var gate=CurrentDisplayGate();gate.bind(ticket)
        gate.complete(ticket,result:RecognitionResult(names:["generated"]),at:1.1)
        gate.observe(matchesSnapshot:true,capturedAt:1.25,now:1.3,generation:ticket.generation)
        #expect(gate.visible != nil)
        switch kind {
        case "mismatch":gate.observe(matchesSnapshot:false,capturedAt:1.5,now:1.5,generation:ticket.generation)
        case "unknown":gate.observe(matchesSnapshot:nil,capturedAt:1.5,now:1.5,generation:ticket.generation)
        case "gap":gate.observe(matchesSnapshot:true,capturedAt:2.1,now:2.1,generation:ticket.generation)
        case "stale":gate.observe(matchesSnapshot:true,capturedAt:1.5,now:2.3,generation:ticket.generation)
        default:gate.observe(matchesSnapshot:true,capturedAt:1.5,now:1.5,generation:UUID())
        }
        #expect(gate.visible == nil && gate.revoked)
        gate.observe(matchesSnapshot:true,capturedAt:2.5,now:2.5,generation:ticket.generation)
        gate.complete(ticket,result:RecognitionResult(names:["late"]),at:2.5)
        #expect(gate.visible == nil)
    }
}
@Test func currentDisplayRejectsLateReplyAfterSwitchStopEmptyAndTimeout() throws {
    for kind in ["switch","stop","empty","timeout"] {
        let ticket=try displayTicket();var gate=CurrentDisplayGate();gate.bind(ticket)
        switch kind {
        case "switch":gate.observe(matchesSnapshot:false,capturedAt:1.25,now:1.25,generation:ticket.generation)
        case "stop":gate.stop()
        case "empty":gate.complete(ticket,result:RecognitionResult(),at:1.2)
        default:gate.expire(at:1.76)
        }
        gate.complete(ticket,result:RecognitionResult(names:["late"]),at:4)
        gate.observe(matchesSnapshot:true,capturedAt:4.25,now:4.25,generation:ticket.generation)
        #expect(gate.visible == nil)
    }
}
@Test func currentDisplayCannotBorrowAnotherRequestsCompletion() throws {
    let first=try displayTicket(),second=try displayTicket()
    var gate=CurrentDisplayGate();gate.bind(second)
    gate.complete(first,result:RecognitionResult(names:["wrong"]),at:1.1)
    gate.observe(matchesSnapshot:true,capturedAt:1.25,now:1.25,generation:second.generation)
    #expect(gate.visible == nil && !gate.revoked)
}

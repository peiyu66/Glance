import Foundation
import Testing
@testable import GlanceCore

private func focusFingerprint(_ reversed: Bool = false) -> SceneFingerprint {
    SceneFingerprint(rgb:(0..<192).map { ((($0/3)%8 < 4) != reversed) ? 0.15 : 0.85 },side:8)
}
private func focusStable(_ session: inout LiveRecognitionSession, from start: Double, reversed: Bool = false) {
    for t in stride(from:start,through:start+1,by:0.25) {
        session.observe(focusFingerprint(reversed),capturedAt:t,now:t)
    }
}
@Test func focusNoEventAndFixedFocusDoNotWaitForAnEdge() throws {
    let gate=CameraFocusGate(), epoch=UUID()
    gate.begin(session:epoch,autofocusSupported:true,adjusting:false,at:0)
    #expect(gate.allows(try #require(gate.stamp(capturedAt:0.25))))
    gate.begin(session:epoch,autofocusSupported:false,adjusting:true,at:1)
    gate.update(adjusting:true,session:epoch,at:1.1)
    #expect(!gate.snapshot.adjusting)
    #expect(gate.allows(try #require(gate.stamp(capturedAt:1.25))))
}
@Test func focusRejectsBufferedAndAnalyzedFramesAcrossBothEdges() throws {
    let gate=CameraFocusGate(), epoch=UUID()
    gate.begin(session:epoch,autofocusSupported:true,adjusting:false,at:0)
    let old=try #require(gate.stamp(capturedAt:0.5))
    gate.update(adjusting:true,session:epoch,at:0.6)
    #expect(!gate.allows(old));#expect(gate.stamp(capturedAt:0.75)==nil)
    gate.update(adjusting:false,session:epoch,at:1)
    #expect(gate.stamp(capturedAt:1)==nil);#expect(!gate.allows(old))
    #expect(gate.allows(try #require(gate.stamp(capturedAt:1.25))))
}
@Test func focusCrossThreadChangeInvalidatesBeforeActorNotification() async throws {
    let gate=CameraFocusGate(), epoch=UUID()
    gate.begin(session:epoch,autofocusSupported:true,adjusting:false,at:0)
    let stamp=try #require(gate.stamp(capturedAt:0.5))
    _ = await Task.detached { gate.update(adjusting:true,session:epoch,at:0.6) }.value
    #expect(throws:CameraFocusGate.Rejection.self) { try gate.requireCurrent(stamp) }
    gate.stop();gate.begin(session:UUID(),autofocusSupported:true,adjusting:false,at:2)
    let next=gate.snapshot
    gate.update(adjusting:true,session:epoch,at:3)
    #expect(gate.snapshot==next);#expect(!gate.allows(stamp))
}
@Test func focusGapKeepsPaidReferenceAndInflightAnswerButRequiresFreshStabilityForB() throws {
    var session=LiveRecognitionSession()
    focusStable(&session,from:0)
    let a=try #require({ session.startRequest(snapshotCapturedAt:1,at:1,referenceAvailable:true) }())
    let generation=session.generation
    session.interruptAcquisitionForFocus()
    #expect(session.inflightRequest==a && session.generation==generation && session.references.entries.count==1)
    #expect({ session.complete(a,result:.init(names:["A"]),at:1.2) }())
    #expect(session.history.entries.count==1 && session.visible?.names==["A"])
    session.observe(focusFingerprint(),capturedAt:2,now:2,matchingReferenceIDs:[a.intent.id],evaluatedReferenceIDs:[a.intent.id])
    #expect(session.queuedIntent==nil && session.sentCount==1 && session.references.entries.count==1)
    session.interruptAcquisitionForFocus()
    for t in stride(from:3.0,through:3.75,by:0.25) { session.observe(focusFingerprint(true),capturedAt:t,now:t) }
    #expect(session.queuedIntent==nil && session.stableElapsed==0.75)
    session.observe(focusFingerprint(true),capturedAt:4,now:4)
    #expect({ session.startRequest(snapshotCapturedAt:4,at:4,referenceAvailable:true) }() != nil)
    #expect(session.references.entries.count==2 && session.history.entries.count==1)
}
@Test func focusUnsentRejectionReleasesOnlyReservation() throws {
    var session=LiveRecognitionSession();focusStable(&session,from:0)
    let a=try #require({ session.startRequest(snapshotCapturedAt:1,at:1,referenceAvailable:true) }())
    #expect({ session.complete(a,result:.init(names:["A"]),at:1.1) }())
    focusStable(&session,from:3,reversed:true)
    let b=try #require({ session.startRequest(snapshotCapturedAt:4,at:4,referenceAvailable:true) }())
    session.releaseBeforeImageSend(b,at:4.1)
    #expect(session.sentCount==1 && session.lifetimeSentCount==2 && session.inflightRequest==nil)
    #expect(session.references.entries.map(\.id)==[a.intent.id] && session.visible?.names==["A"])
    session.releaseBeforeImageSend(b,at:4.2)
    #expect(session.sentCount==1)
}
@Test func focusSingleCaptureUnsentReservationCanRecover() throws {
    var gate=FirstCaptureGate();var request:FirstCaptureGate.Request?
    for t in stride(from:0.0,through:1,by:0.25) { request=gate.observe(focusFingerprint(),capturedAt:t,now:t) ?? request }
    let ticket=try #require(request);#expect({ gate.markSent(ticket,at:1) }())
    gate.releaseBeforeImageSend(ticket)
    #expect(gate.sentCount==0 && gate.stableElapsed==0)
    var next:FirstCaptureGate.Request?
    for t in stride(from:2.0,through:3,by:0.25) { next=gate.observe(focusFingerprint(),capturedAt:t,now:t) ?? next }
    #expect(next != nil)
}

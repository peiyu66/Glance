import Foundation
import CoreGraphics
import Testing
@testable import GlanceCore

private func nativeCanvas() -> CGContext {
    CGContext(data:nil,width:768,height:768,bitsPerComponent:8,bytesPerRow:768*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
}
private func nativeSource(textured: Bool, changed: Bool = false) -> CGImage {
    let c=nativeCanvas();c.setFillColor(gray:0.92,alpha:1);c.fill(CGRect(x:0,y:0,width:768,height:768))
    if textured {
        for y in 0..<12 { for x in 0..<12 {
            c.setFillColor(gray:(x+y).isMultiple(of:2) ? 0.72 : 0.88,alpha:1)
            c.fill(CGRect(x:x*64,y:y*64,width:64,height:64))
        } }
    }
    c.setFillColor(red:changed ? 0.85 : 0.1,green:0.3,blue:changed ? 0.1 : 0.8,alpha:1);c.fill(CGRect(x:160,y:115,width:448,height:540))
    c.setFillColor(gray:1,alpha:1);c.fill(CGRect(x:182,y:190,width:406,height:410))
    c.setFillColor(gray:0.05,alpha:1)
    for line in 0..<8 {
        for letter in 0..<(line%2 == 0 ? 8 : 6) {
            c.fill(CGRect(x:220+letter*30,y:230+line*40,width:12+line%3,height:14))
        }
    }
    return c.makeImage()!
}

private func nativeTransformed(_ image:CGImage,t:Double,dx:Double,scale:Double,angle:Double)->CGImage {
    let phase=max(0,t-1.5),v=sin(phase*2.2),c=nativeCanvas()
    c.setFillColor(gray:0.92,alpha:1);c.fill(CGRect(x:0,y:0,width:768,height:768))
    c.translateBy(x:384+dx*v,y:384);c.rotate(by:angle*v * .pi/180)
    let factor=1+scale*sin(phase*1.3);c.scaleBy(x:factor,y:factor);c.translateBy(x:-384,y:-384)
    c.draw(image,in:CGRect(x:0,y:0,width:768,height:768));return c.makeImage()!
}
@Test(arguments:[0,1,2,3]) func nativeGeometryPreservesSameSceneAcrossEightSecondResponse(index:Int) throws {
    let cases=[(false,4.0,0.0,0.0),(false,8.0,0.02,2.0),(true,8.0,0.02,2.0),(true,12.0,0.04,3.0)]
    let (textured,dx,scale,angle)=cases[index],source=nativeSource(textured:textured),normalizer=NativeSceneRegistration()
    var state=LiveRecognitionSession(),request:LiveRecognitionSession.Request?
    for i in 0...44 {
        let t=Double(i)/4,image=nativeTransformed(source,t:t,dx:dx,scale:scale,angle:angle)
        let evidence=try #require(normalizer.observe(image))
        state.observe(evidence.fingerprint,capturedAt:t,now:t,sceneChangeReason:evidence.sceneChanged ? evidence.reason : nil)
        if request == nil { request=state.startRequest(snapshotCapturedAt:t,at:t) }
        if t==9 { let ticket=try #require(request);#expect({state.complete(ticket,result:.init(names:["A"]),at:t)}()) }
    }
    #expect(state.visible?.names == ["A"])
    #expect(state.adoptedCount == 1 && state.sentCount == 1 && state.discardedCount == 0)
}
@Test(arguments:[false,true]) func nativeContentChangePreservesSuccessfulHistoryWithoutClaimingCurrent(pending:Bool) throws {
    let normalizer=NativeSceneRegistration(),a=nativeSource(textured:true),b=nativeSource(textured:true,changed:true)
    var state=LiveRecognitionSession()
    func feed(_ image:CGImage,_ t:Double) throws {
        let e=try #require(normalizer.observe(image))
        state.observe(e.fingerprint,capturedAt:t,now:t,sceneChangeReason:e.sceneChanged ? e.reason : nil)
    }
    for i in 0...4 { try feed(a,Double(i)/4) }
    let request=try #require({state.startRequest(snapshotCapturedAt:1,at:1)}())
    if !pending { #expect({state.complete(request,result:.init(names:["A"]),at:1)}()) }
    try feed(a,1.25)
    if !pending { #expect(state.visible?.names == ["A"]) }
    for i in 6...12 {
        try feed(b,Double(i)/4)
        if pending { #expect(state.visible == nil) }
        else { #expect(state.visible?.names == ["A"] && state.visibleIsPrevious) }
    }
    #expect(state.adoptedCount == 2)
    if pending { #expect({state.complete(request,result:.init(names:["A"]),at:3)}()) }
    try feed(b,3.25)
    let next=try #require({state.startRequest(snapshotCapturedAt:3.25,at:3.25)}())
    #expect({state.complete(next,result:.init(names:["B"]),at:3.26)}())
    try feed(b,3.5);#expect(state.visible?.names == ["B"] && !state.visibleIsPrevious)
}

// Appended to production CameraController solely in the synthetic fixture host.
@MainActor extension CameraController {
    static func runFocusControllerChecks() async -> [String:Bool] {
        var checks:[String:Bool]=[:]
        let bitmap=UIGraphicsImageRenderer(size:CGSize(width:16,height:16)).image { c in
            UIColor.white.setFill();c.fill(CGRect(x:0,y:0,width:16,height:16))
        }.cgImage!
        let features=ForegroundORBFeatures(native:GLOpenCVFeatures())
        func makeFrame(_ model:CameraController,_ t:Double,_ reversed:Bool=false,_ matches:[UUID]=[]) -> CameraFrame? {
            guard let stamp=model.capture.focusGate.stamp(capturedAt:t) else { return nil }
            let fp=SceneFingerprint(rgb:(0..<192).map { ((($0/3)%8 < 4) != reversed) ? 0.15 : 0.85 },side:8)
            let identity=FixedForegroundMatcher.Observation(features:features,matches:matches,
                evaluated:Set(model.liveSession.references.entries.map(\.id)),milliseconds:0)
            return CameraFrame(image:bitmap,fingerprint:fp,feature:nil,time:t,identity:identity,focusStamp:stamp)
        }
        func feed(_ model:CameraController,_ t:Double,_ reversed:Bool=false,_ matches:[UUID]=[]) {
            model.fixtureTime=t;model.frame(makeFrame(model,t,reversed,matches),generation:model.generation,stats:CaptureStatistics())
        }
        func stable(_ model:CameraController,_ start:Double,_ reversed:Bool=false,_ matches:[UUID]=[]) {
            for t in stride(from:start,through:start+1,by:0.25) { feed(model,t,reversed,matches) }
        }
        func prepare(_ model:CameraController,auto:Bool=true) async {
            model.fixtureTime=0;await model.start()
            model.capture.focusGate.begin(session:model.generation,autofocusSupported:auto,adjusting:!auto,at:-1)
        }
        let clock=CaptureFixtureClock(),model=captureLimitFixtureModel(CaptureFixtureClock())
        await prepare(model)
        var calls=0
        model.fixtureProvider={ _ in calls += 1;return .init(names:["A"]) }
        stable(model,0);await model.work?.value
        let a=model.liveSession.history.entries.first?.id
        checks["F1_initial_stable_without_focus_event_sends_after_one_second"] = calls==1 && a != nil && model.liveSession.references.entries.count==1
        let old=makeFrame(model,1.1)!
        let epoch=model.generation,gate=model.capture.focusGate
        await Task.detached { gate.update(adjusting:true,session:epoch,at:1.2) }.value
        model.focusChanged(generation:epoch)
        checks["F1_focus_edge_resets_only_acquisition"] = model.liveSession.stableElapsed==0 && model.liveSession.references.entries.map(\.id)==[a!] && model.visible?.names==["A"] && model.sessionRecords.count==1
        for t in stride(from:1.5,through:2.5,by:0.25) { feed(model,t) }
        checks["F1_hunting_never_dispatches_or_clears_paid_card"] = calls==1 && model.liveSession.queuedIntent==nil && model.visible?.names==["A"]
        gate.update(adjusting:false,session:epoch,at:2.75)
        model.fixtureTime=3;model.frame(old,generation:epoch,stats:CaptureStatistics())
        checks["F1_actor_queued_old_frame_rejected_after_settled"] = calls==1 && model.liveSession.stableElapsed==0 && model.pipelineStage=="focus-stale-frame"
        do { _ = try model.capture.prepareLiveFrame(bitmap,time:3,focusStamp:old.focusStamp);checks["F1_stale_frame_rejected_before_alignment_ORB"]=false }
        catch is CameraFocusGate.Rejection { checks["F1_stale_frame_rejected_before_alignment_ORB"] = CaptureFixtureOpticalCalls.count==0 }
        catch { checks["F1_stale_frame_rejected_before_alignment_ORB"]=false }
        stable(model,3,false,[a!]);await model.work?.value
        checks["F1_same_A_after_focus_gap_reuses_original_reference"] = calls==1 && model.liveSession.references.entries.map(\.id)==[a!] && model.visible?.sourceImageID==a
        model.fixtureProvider={ [weak model] _ in calls += 1;return try await withCheckedThrowingContinuation { model?.fixtureWaiter=$0 } }
        for t in stride(from:5.0,through:5.75,by:0.25) { feed(model,t,true) }
        checks["F1_different_B_cannot_send_before_new_one_second"] = calls==1 && model.liveSession.queuedIntent==nil
        feed(model,6,true)
        for _ in 0..<60 where model.fixtureWaiter==nil { await Task.yield() }
        checks["F1_different_B_sends_after_new_one_second"] = calls==2 && model.inflight && model.liveSession.references.entries.count==2
        gate.update(adjusting:true,session:epoch,at:6.1);model.focusChanged(generation:epoch)
        model.fixtureTime=6.2;model.fixtureWaiter?.resume(returning:.init(names:["B"]));model.fixtureWaiter=nil;await model.work?.value
        checks["F1_focus_does_not_cancel_inflight_B_or_erase_A"] = !model.inflight && model.liveSession.history.entries.map{$0.result.names}==[["A"],["B"]] && model.liveSession.references.entries.count==2 && !model.blocked
        model.stop(userInitiated:true)

        for scenario in ["encoding","task-queue","pre-send-await"] {
            let m=captureLimitFixtureModel(CaptureFixtureClock());await prepare(m);var count=0
            m.fixtureProvider={ _ in count += 1;return .init(names:["unexpected"]) }
            var ready=false;var waiter:CheckedContinuation<Void,Never>?
            if scenario=="encoding" { m.fixtureJPEGEncoder={ _ in m.capture.focusGate.update(adjusting:true,session:m.generation,at:1.01);return Data([1,2,3]) } }
            if scenario=="pre-send-await" { m.fixtureBeforeImageSend={ ready=true;await withCheckedContinuation { waiter=$0 } } }
            stable(m,0)
            if scenario=="task-queue" { m.capture.focusGate.update(adjusting:true,session:m.generation,at:1.01) }
            if scenario=="pre-send-await" {
                for _ in 0..<60 where !ready { await Task.yield() }
                m.capture.focusGate.update(adjusting:true,session:m.generation,at:1.01);waiter?.resume()
            }
            await m.work?.value
            checks["F1_\(scenario)_focus_change_never_sends_old_JPEG"] = count==0 && m.requestCount==0 && !m.inflight && !m.blocked && m.liveSession.sentCount==0 && m.liveSession.references.entries.isEmpty
            checks["T2_\(scenario)_focus_rejection_clears_waiting"] = m.pendingRecognition == nil
            m.stop(userInitiated:true)
        }
        let fixed=captureLimitFixtureModel(CaptureFixtureClock());await prepare(fixed,auto:false);var fixedCalls=0
        fixed.fixtureProvider={_ in fixedCalls += 1;return .init(names:["fixed"])}
        stable(fixed,0);await fixed.work?.value
        checks["F1_fixed_focus_camera_is_not_permanently_blocked"] = fixedCalls==1
        fixed.stop(userInitiated:true)

        let timed=captureLimitFixtureModel(clock);await prepare(timed);timed.seedCaptureLimitFixtureAnswer()
        timed.capture.focusGate.update(adjusting:true,session:timed.generation,at:1)
        clock.now=300;feed(timed,2)
        checks["F1_T1_expires_while_focus_hunts_and_retains_answer"] = !timed.running && timed.captureTimeLimit.expired && timed.visible != nil && !timed.capture.focusGate.snapshot.active
        for background in [false,true] {
            let m=captureLimitFixtureModel(CaptureFixtureClock());await prepare(m)
            m.fixtureProvider={ [weak m] _ in try await withCheckedThrowingContinuation { m?.fixtureWaiter=$0 } }
            stable(m,0);for _ in 0..<60 where m.fixtureWaiter==nil { await Task.yield() }
            let task=m.work
            m.capture.focusGate.update(adjusting:true,session:m.generation,at:1.1)
            if background { m.foreground(.background) } else { m.stop(userInitiated:true) }
            m.fixtureWaiter?.resume(returning:.init(names:["late"]));m.fixtureWaiter=nil;await task?.value
            checks["F1_\(background ? "background" : "pause")_cancels_generation_and_rejects_late_result"] = !m.running && !m.inflight && m.sessionRecords.isEmpty && !m.capture.focusGate.snapshot.active
        }
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[FocusFixtureURLProtocol.self]
        let http=SIWCHTTP(configuration:config)
        do {
            _ = try await http.stream(body:Data("{}".utf8),bearer:"synthetic",validateBeforeImageSend:{throw CameraFocusGate.Rejection.changedBeforeSend})
            checks["F1_real_stream_boundary_rejects_before_URLSession"]=false
        } catch is CameraFocusGate.Rejection { checks["F1_real_stream_boundary_rejects_before_URLSession"] = FocusFixtureURLProtocol.calls==0 }
          catch { checks["F1_real_stream_boundary_rejects_before_URLSession"]=false }
        checks["F1_no_real_camera_network_or_optics"] = !model.capture.session.isRunning && CaptureFixtureOpticalCalls.count==0 && FocusFixtureURLProtocol.calls==0
        return checks
    }
}
final class FocusFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock=NSLock()
    nonisolated(unsafe) private static var count=0
    static var calls:Int { lock.withLock { count } }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.count += 1 };client?.urlProtocol(self,didFailWithError:URLError(.cancelled)) }
    override func stopLoading() {}
}

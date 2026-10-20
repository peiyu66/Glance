// Appended to the unchanged production CameraView.swift for private-path testing.
@MainActor final class CaptureFixtureClock { var now = 0.0; var starts = 0; var stops = 0 }
@MainActor extension CameraController {
    static func captureLimitFixtureModel(_ clock: CaptureFixtureClock,
        signedIn: Bool = true, planPermission: Bool = true, permission: @escaping () async -> Bool = { true }) -> CameraController {
        let tokens = SIWCTokens(access:"synthetic",refresh:nil,idToken:"synthetic",scope:planPermission ? SIWCProtocol.scopes : "openid profile email",expiresAt:Date().addingTimeInterval(3600))
        let account = SIWCAccount(clientID:"synthetic",subject:"synthetic",email:nil,tokens:signedIn ? tokens : nil,planOnlyConfirmed:false)
        let storage = SIWCSaved(hostID:"synthetic",accounts:[account],selected:account.id)
        let auth = SIWCController(authSaveSession:{_ in},authLoadSession:{ storage })
        return CameraController(account:auth,captureClock:{ clock.now },requestCameraAccess:permission,
            beginCapture:{_,_,_ in clock.starts += 1},endCapture:{ clock.stops += 1 })
    }
    func seedCaptureLimitFixtureAnswer() {
        let fp = SceneFingerprint(rgb:(0..<192).map { ($0/3)%8 < 4 ? 0.15 : 0.85 },side:8)
        for t in stride(from:0.0,through:1,by:0.25) { liveSession.observe(fp,capturedAt:t,now:t) }
        if let request = liveSession.startRequest(snapshotCapturedAt:1,at:1) {
            _ = liveSession.complete(request,result:RecognitionResult(names:["已完成答案 A"],summary:"這筆已完成的解說應在自動暫停後保留。"),at:1.1)
        }
        syncLiveVisible(at:1.1)
    }
    static func runCaptureLimitControllerChecks() async -> [String:Bool] {
        var checks:[String:Bool]=[:]
        let clock=CaptureFixtureClock();let model=captureLimitFixtureModel(clock)
        checks["cold_idle_has_no_timer_or_capture"] = !model.running && model.watchdog == nil && model.captureTimeLimit.deadline == nil && clock.starts == 0
        checks["W1_existing_session_false_legacy_confirmation_is_ready"] = model.account.planAccessReady && model.account.account?.planOnlyConfirmed == false && model.canStartCapture
        await model.start()
        checks["explicit_start_arms_300_seconds"] = model.running && clock.starts == 1 && model.captureTimeLimit.deadline == 300 && model.watchdog != nil
        clock.now=100;await model.start()
        checks["reentrant_start_does_not_extend"] = clock.starts == 1 && model.captureTimeLimit.deadline == 300
        clock.now=299.999
        checks["under_boundary_keeps_running"] = !model.pauseIfCaptureTimeExpired() && model.running
        model.seedCaptureLimitFixtureAnswer();clock.now=300
        model.frame(nil,generation:model.generation,stats:CaptureStatistics())
        checks["frame_boundary_uses_safe_pause"] = !model.running && !model.wantsRunning && model.watchdog == nil && clock.stops == 1 && model.captureTimeLimit.expired
        checks["automatic_pause_preserves_paid_card_and_history"] = model.visible?.names == ["已完成答案 A"] && model.liveSession.history.entries.count == 1 && model.liveSession.sentCount == 0 && model.fixedReferenceFeatures.isEmpty
        model.foreground(.active)
        checks["expired_foreground_does_not_restart"] = clock.starts == 1 && !model.running && model.captureTimeLimitStatus == "已取景5分鐘，自動暫停"
        clock.now=305;await model.start()
        checks["explicit_restart_is_new_five_minutes"] = model.running && clock.starts == 2 && model.captureTimeLimit.deadline == 605 && model.captureTimeLimitStatus == nil
        model.stop(userInitiated:true);clock.now=400;await model.start()
        checks["manual_pause_then_start_resets_deadline"] = model.captureTimeLimit.deadline == 700
        clock.now=420;model.foreground(.inactive);model.foreground(.background)
        checks["background_stops_watchdog_preserves_deadline"] = !model.running && model.watchdog == nil && model.wantsRunning && model.captureTimeLimit.deadline == 700
        clock.now=500;model.foreground(.active)
        checks["foreground_before_deadline_resumes_same_session"] = model.running && model.captureTimeLimit.deadline == 700
        model.showingSettings=true;model.settingsChanged(true);clock.now=600
        model.showingSettings=false;model.settingsChanged(false)
        checks["settings_does_not_extend_deadline"] = model.running && model.captureTimeLimit.deadline == 700
        model.foreground(.background);let previousStarts=clock.starts;clock.now=900;model.foreground(.active)
        checks["background_expiry_does_not_restart"] = !model.running && !model.wantsRunning && clock.starts == previousStarts && model.watchdog == nil
        await model.start();model.showingSettings=true;model.settingsChanged(true);let settingsStarts=clock.starts
        clock.now=1200;model.showingSettings=false;model.settingsChanged(false)
        checks["settings_expiry_does_not_restart"] = !model.running && clock.starts == settingsStarts && model.captureTimeLimit.expired
        model.stop(userInitiated:true)

        for (name,signedIn,planPermission) in [("signed_out",false,true),("no_plan_permission",true,false)] {
            let lockedClock=CaptureFixtureClock();var permissionCalls=0
            let locked=captureLimitFixtureModel(lockedClock,signedIn:signedIn,planPermission:planPermission,permission:{permissionCalls += 1;return true})
            await locked.start()
            checks["W1_\(name)_cannot_start"] = !locked.running && !locked.canStartCapture && locked.showingSettings && lockedClock.starts == 0 && permissionCalls == 0 && locked.captureTimeLimit.deadline == nil
            do { _ = try await locked.account.recognize(jpeg:Data([1]));checks["W1_\(name)_cannot_recognize"]=false }
            catch { checks["W1_\(name)_cannot_recognize"] = error as? SIWCError == .planDisabled && !locked.account.busy }
        }
        let unavailableClock=CaptureFixtureClock()
        let unavailableAuth=SIWCController(authSaveSession:{_ in},authLoadSession:{throw SIWCError.invalidResponse})
        let unavailable=CameraController(account:unavailableAuth,captureClock:{unavailableClock.now},requestCameraAccess:{true},beginCapture:{_,_,_ in unavailableClock.starts += 1},endCapture:{})
        await unavailable.start()
        checks["W1_unreadable_session_cannot_start"] = !unavailable.running && !unavailable.canStartCapture && unavailableClock.starts == 0
        let deniedClock=CaptureFixtureClock();let denied=captureLimitFixtureModel(deniedClock,permission:{false});await denied.start()
        checks["permission_denied_does_not_arm"] = denied.permissionDenied && denied.captureTimeLimit.deadline == nil && deniedClock.starts == 0
        let permissionClock=CaptureFixtureClock();var permissionWaiter:CheckedContinuation<Bool,Never>?
        let permissionModel=captureLimitFixtureModel(permissionClock,permission:{ await withCheckedContinuation { permissionWaiter=$0 } })
        let pendingStart=Task { await permissionModel.start() }
        for _ in 0..<30 where permissionWaiter == nil { await Task.yield() }
        await permissionModel.start();permissionModel.foreground(.background)
        permissionWaiter?.resume(returning:true);await pendingStart.value
        checks["permission_return_after_background_never_starts"] = permissionClock.starts == 0 && !permissionModel.running && permissionModel.captureTimeLimit.deadline == nil

        let watchClock=CaptureFixtureClock();let watched=captureLimitFixtureModel(watchClock);await watched.start();watchClock.now=300
        try? await Task.sleep(for:.milliseconds(350))
        checks["real_watchdog_auto_pauses_without_frames"] = !watched.running && watched.watchdog == nil && watchClock.stops == 1 && watched.captureTimeLimit.expired

        let lateClock=CaptureFixtureClock();let late=captureLimitFixtureModel(lateClock);await late.start()
        late.fixtureTime=0
        var sentJPEG:Data?
        late.fixtureProvider={ [weak late] jpeg in sentJPEG=jpeg;return try await withCheckedThrowingContinuation { late?.fixtureWaiter=$0 } }
        let bitmap=UIGraphicsImageRenderer(size:CGSize(width:16,height:16)).image{ctx in UIColor.white.setFill();ctx.fill(CGRect(x:0,y:0,width:16,height:16))}.cgImage!
        func feed(_ start:Double,_ reversed:Bool) {
            let fp=SceneFingerprint(rgb:(0..<192).map { ((($0/3)%8 < 4) != reversed) ? 0.15 : 0.85 },side:8)
            for t in stride(from:start,through:start+1,by:0.25) { late.fixtureTime=t;late.frame(CameraFrame(image:bitmap,fingerprint:fp,feature:nil,time:t),generation:late.generation,stats:CaptureStatistics()) }
        }
        func settleProvider() async { for _ in 0..<60 where late.fixtureWaiter == nil { await Task.yield() } }
        feed(0,false);await settleProvider();late.fixtureTime=1.1
        checks["T2_pending_A_holds_exact_provider_JPEG"] = late.pendingRecognition?.id == late.liveSession.inflightRequest?.intent.id && late.pendingRecognition?.jpeg == sentJPEG
        late.fixtureWaiter?.resume(returning:RecognitionResult(names:["A"]));late.fixtureWaiter=nil;await late.work?.value
        let firstSource=late.visible?.sourceImageID;let firstBytes=sentJPEG
        checks["T2_A_completion_removes_waiting"] = late.pendingRecognition == nil
        checks["share_A_exact_sent_JPEG_bound_to_result"] = firstSource != nil && late.sourceImages.images.image(for:firstSource) == firstBytes
        feed(3,true);await settleProvider();let old=late.work;let beforeLateCount=late.requestCount
        checks["T2_pending_B_distinct_from_completed_A"] = late.pendingRecognition?.id != firstSource && late.pendingRecognition?.jpeg == sentJPEG && late.visible?.sourceImageID == firstSource
        lateClock.now=300;_ = late.pauseIfCaptureTimeExpired()
        checks["T2_pause_clears_waiting_keeps_A"] = late.pendingRecognition == nil && late.visible?.sourceImageID == firstSource
        checks["expiry_cancels_pending_keeps_paid_A_and_slot"] = old?.isCancelled == true && late.inflight && late.visible?.names == ["A"] && late.liveSession.history.entries.count == 1 && late.liveSession.sentCount == 0 && late.watchdog == nil
        lateClock.now=301;await late.start();feed(6,false)
        checks["restart_waits_for_old_transport_cleanup"] = late.inflight && late.requestCount == beforeLateCount
        late.fixtureTime=7.1;late.fixtureWaiter?.resume(returning:RecognitionResult(names:["LATE B"]));late.fixtureWaiter=nil;await old?.value
        checks["T2_late_cancelled_B_does_not_revive_waiting"] = late.pendingRecognition == nil
        checks["share_cancelled_B_does_not_store_or_overwrite_A"] = late.sourceImages.images.count == 1 && late.sourceImages.images.image(for:firstSource) == firstBytes
        checks["cancelled_late_reply_does_not_replace_paid_A"] = !late.inflight && late.visible?.names == ["A"] && late.liveSession.history.entries.map(\.sequence) == [1]
        let fp=SceneFingerprint(rgb:(0..<192).map { ($0/3)%8 < 4 ? 0.15 : 0.85 },side:8)
        late.fixtureTime=7.25;late.frame(CameraFrame(image:bitmap,fingerprint:fp,feature:nil,time:7.25),generation:late.generation,stats:CaptureStatistics())
        await settleProvider();late.fixtureTime=7.4
        late.fixtureWaiter?.resume(returning:RecognitionResult(names:["C"]));late.fixtureWaiter=nil;await late.work?.value
        checks["new_batch_keeps_unique_history_sequences"] = late.liveSession.history.entries.map(\.sequence) == [1,3] && late.liveSession.sentCount == 1 && late.visible?.names == ["C"]
        let secondSource=late.visible?.sourceImageID
        checks["share_C_and_history_A_have_distinct_sources"] = secondSource != nil && secondSource != firstSource && late.liveSession.history.entries.first?.result.sourceImageID == firstSource && late.sourceImages.images.image(for:secondSource) == sentJPEG
        late.stop(userInitiated:true)
        checks["share_manual_pause_keeps_sources"] = late.sourceImages.images.count == 2
        late.memoryWarning()
        checks["share_memory_warning_removes_images_keeps_text"] = late.sourceImages.images.count == 0 && late.sessionRecords.count == 2
        late.sourceImages.insert(Data([1]),for:UUID());late.foreground(.background)
        checks["share_background_clears_sources_and_history"] = late.sourceImages.images.count == 0 && late.sessionRecords.isEmpty
        late.sourceImages.insert(Data([2]),for:UUID());late.settingsChanged(true)
        checks["share_settings_clears_sources"] = late.sourceImages.images.count == 0
        checks["real_camera_and_optics_never_started"] = !model.capture.session.isRunning && !late.capture.session.isRunning && CaptureFixtureOpticalCalls.count == 0
        checks.merge(await runThumbnailControllerChecks(),uniquingKeysWith:{ _,new in new })
        return checks
    }
    static func runThumbnailControllerChecks() async -> [String:Bool] {
        var checks:[String:Bool]=[:]
        let model=captureLimitFixtureModel(CaptureFixtureClock());await model.start();model.fixtureTime=0
        let a=UIGraphicsImageRenderer(size:CGSize(width:32,height:32)).image { c in UIColor.blue.setFill();c.fill(CGRect(x:0,y:0,width:32,height:32)) }.cgImage!
        let b=UIGraphicsImageRenderer(size:CGSize(width:32,height:32)).image { c in UIColor.red.setFill();c.fill(CGRect(x:0,y:0,width:32,height:32)) }.cgImage!
        var sent:[Data]=[]
        model.fixtureProvider={ [weak model] jpeg in
            sent.append(jpeg)
            return try await withCheckedThrowingContinuation { model?.fixtureWaiter=$0 }
        }
        func feed(_ time:Double,_ isB:Bool) {
            let fp=SceneFingerprint(rgb:(0..<192).map { ((($0/3)%8 < 4) != isB) ? 0.15 : 0.85 },side:8)
            model.fixtureTime=time
            model.frame(CameraFrame(image:isB ? b : a,fingerprint:fp,feature:nil,time:time),generation:model.generation,stats:CaptureStatistics())
        }
        func stable(_ time:Double,_ isB:Bool) { for t in stride(from:time,through:time+1,by:0.25) { feed(t,isB) } }
        func settle() async { for _ in 0..<80 where model.fixtureWaiter==nil { await Task.yield() } }
        stable(0,false);await settle()
        let aID=model.pendingRecognition?.id, aJPEG=sent.first
        checks["T2_real_frame_A_pending_binds_provider_bytes"] = aID != nil && model.pendingRecognition?.jpeg == aJPEG && model.sessionRecords.isEmpty
        stable(2,true)
        checks["T2_camera_B_while_A_pending_keeps_A_thumbnail"] = sent.count==1 && model.pendingRecognition?.id==aID && model.pendingRecognition?.jpeg==aJPEG
        model.fixtureTime=3.1;model.fixtureWaiter?.resume(returning:.init(names:["A"]));model.fixtureWaiter=nil;await model.work?.value
        checks["T2_A_late_after_camera_B_saved_as_A_history"] = model.sessionRecords.count==1 && model.sessionRecords.first?.result.sourceImageID==aID && model.sourceImages.images.image(for:aID)==aJPEG
        feed(3.25,true);await settle()
        let bID=model.pendingRecognition?.id,bJPEG=sent.last
        checks["T2_B_pending_uses_new_JPEG_keeps_A_result"] = sent.count==2 && bID != nil && bID != aID && bJPEG != aJPEG && model.pendingRecognition?.jpeg==bJPEG && model.visible?.sourceImageID==aID
        if let aID { model.finishRecognitionPreview(id:aID) }
        checks["T2_old_completion_cannot_clear_new_B_waiting"] = model.pendingRecognition?.id==bID
        model.memoryWarning()
        checks["T2_memory_releases_pending_pixels_without_wrong_fallback"] = model.pendingRecognition?.id==bID && model.pendingRecognition?.jpeg==nil && model.sourceImages.images.count==0 && model.sessionRecords.count==1
        model.fixtureTime=3.5;model.fixtureWaiter?.resume(returning:.init(names:["B"]));model.fixtureWaiter=nil;await model.work?.value
        checks["T2_B_completion_uses_original_sent_JPEG_after_memory_warning"] = model.pendingRecognition==nil && model.visible?.sourceImageID==bID && model.sourceImages.images.image(for:bID)==bJPEG
        checks["T2_evicted_A_source_cannot_resolve_to_B"] = model.sessionRecords.first?.result.sourceImageID==aID && model.sourceImages.images.image(for:aID)==nil && model.sessionRecords.last?.result.sourceImageID==bID
        model.stop(userInitiated:true)
        checks["T2_no_camera_or_optical_processing"] = !model.capture.session.isRunning && CaptureFixtureOpticalCalls.count==0
        return checks
    }
}

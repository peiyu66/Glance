// Appended only to the simulator harness's production CameraView source.
@MainActor extension CameraController {
    static func runShareControllerChecks() async -> [String:Bool] {
        var checks:[String:Bool]=[:]
        let model=CameraController()
        model.running=true;model.fixtureTime=0
        var sentJPEG:Data?
        model.fixtureProvider={ [weak model] jpeg in
            sentJPEG=jpeg
            return try await withCheckedThrowingContinuation { model?.fixtureWaiter=$0 }
        }
        let bitmap=UIGraphicsImageRenderer(size:CGSize(width:24,height:24)).image { ctx in
            UIColor.blue.setFill();ctx.fill(CGRect(x:0,y:0,width:24,height:24))
        }.cgImage!
        func feed(_ start:Double,_ reversed:Bool) {
            let fp=SceneFingerprint(rgb:(0..<192).map { ((($0/3)%8 < 4) != reversed) ? 0.15 : 0.85 },side:8)
            for t in stride(from:start,through:start+1,by:0.25) {
                model.fixtureTime=t
                model.liveFrame(CameraFrame(image:bitmap,fingerprint:fp,feature:nil,time:t),now:t)
            }
        }
        func settle() async { for _ in 0..<80 where model.fixtureWaiter == nil { await Task.yield() } }
        feed(0,false);await settle()
        checks["A_provider_received_encoded_JPEG"] = sentJPEG.flatMap { UIImage(data:$0) } != nil && model.fixtureWaiter != nil
        model.fixtureTime=1.1;model.fixtureWaiter?.resume(returning:.init(names:["A"],text:["Original A"]));model.fixtureWaiter=nil
        await model.work?.value
        let a=model.visible?.sourceImageID;let aJPEG=sentJPEG
        checks["A_exact_provider_bytes_bound_to_result_and_history"] = a != nil && model.sourceImages.images.image(for:a)==aJPEG && model.sessionRecords.first?.result.sourceImageID==a
        feed(3,true);await settle();let pending=model.work
        model.stop(userInitiated:true)
        checks["manual_pause_keeps_A_image_and_history"] = model.sourceImages.images.image(for:a)==aJPEG && model.sessionRecords.count==1
        model.fixtureTime=4.1;model.fixtureWaiter?.resume(returning:.init(names:["cancelled B"]));model.fixtureWaiter=nil
        await pending?.value
        checks["cancelled_B_never_stores_or_overwrites_A"] = model.sourceImages.images.count==1 && model.sessionRecords.count==1 && model.visible?.sourceImageID==a
        model.running=true;feed(6,false);await settle();model.fixtureTime=7.1
        model.fixtureWaiter?.resume(returning:.init(names:["C"]));model.fixtureWaiter=nil;await model.work?.value
        let c=model.visible?.sourceImageID
        checks["C_uses_distinct_source_without_replacing_history_A"] = c != nil && c != a && model.sourceImages.images.image(for:c)==sentJPEG && model.sessionRecords.first?.result.sourceImageID==a
        checks["public_three_attempt_budget_unchanged"] = model.liveSession.sentCount==3 && model.requestCount==3
        model.sourceImages.removeAll()
        checks["memory_eviction_keeps_text_and_degrades_to_text_only"] = model.sourceImages.images.count==0 && model.sessionRecords.count==2 && model.visible?.shareText=="C"
        model.sourceImages.insert(aJPEG ?? Data(),for:a ?? UUID())
        model.stop(reason:.sceneBackground)
        checks["background_clears_images_and_history"] = model.sourceImages.images.count==0 && model.sessionRecords.isEmpty
        checks["camera_never_started"] = !model.capture.session.isRunning
        checks["no_network_attempts"] = ShareFixtureBlockedNetwork.attemptedRequests==0
        return checks
    }
}

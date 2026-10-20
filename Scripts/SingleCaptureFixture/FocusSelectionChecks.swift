import SwiftUI
import CoreVideo

/// Controller integration uses synthetic metrics; OpenCV numerical evidence is separate.
@MainActor enum FocusSelectionChecks {
    static let detail = CentralFocusQuality(mean: 0.5, variance: 0.08, tenengrad: 0.2, laplacianVariance: 0.02)
    static let softer = CentralFocusQuality(mean: 0.5, variance: 0.08, tenengrad: 0.2, laplacianVariance: 0.005)
    static let blur = CentralFocusQuality(mean: 0.5, variance: 0.08, tenengrad: 0.02, laplacianVariance: 0.00001)
    static func feed(_ host: C2FixtureHost, at time: Double, color: UIColor, quality: CentralFocusQuality) {
        host.clock.now = time
        let image = UIImage(data: C2FixtureHost.jpeg(color))!.cgImage!
        let fingerprint = SceneFingerprint(rgb: (0..<192).map { $0 % 2 == 0 ? 0.2 : 0.8 }, side: 8)
        host.model.receive(CameraFrame(image: image, fingerprint: fingerprint, feature: nil, time: time, focusStamp: host.model.capture.focusGate.stamp(capturedAt: time), focusQuality: quality, darknessStamp: host.model.capture.darknessGate.stamp(session: host.model.previewGeneration)), generation: host.model.previewGeneration)
    }
    static func host(_ name: String) async -> C2FixtureHost {
        let host = C2FixtureHost(name: "focus-selection-" + name)
        try? FileManager.default.removeItem(at: host.root); await host.model.bootstrap()
        _ = host.model.beginAcquisition(); return host
    }
    static func run() async -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let best = await host("same-jpeg")
        for time in [0.25, 0.5, 0.75] { feed(best, at: time, color: .red, quality: softer) }
        feed(best, at: 1, color: .blue, quality: detail)
        feed(best, at: 1.25, color: .red, quality: blur)
        await best.settle { best.waiter != nil }
        let selectedImage = UIImage(data: C2FixtureHost.jpeg(.blue))!.cgImage!
        let expected = UIImage(cgImage: selectedImage).jpegData(compressionQuality: 0.82)!
        checks["best_recent_frame_keeps_its_own_pixels"] = best.calls == 1 && best.lastJPEG == expected
        if let record = best.model.records.first {
            let saved = await best.model.image(for: record)
            let scanned = await best.barcodeProbe.lastJPEG
            checks["selected_JPEG_shared_by_archive_decoder_provider_preview"] = saved == expected && scanned == expected && best.model.submittedPreview?.jpeg == expected
        } else { checks["selected_JPEG_shared_by_archive_decoder_provider_preview"] = false }
        await best.complete(); best.model.closePreview()
        let unknown = await host("unknown")
        for time in [0.25, 0.5, 0.75, 1, 1.25] { feed(unknown, at: time, color: .gray, quality: .unavailable) }
        await unknown.settle { unknown.waiter != nil }
        checks["low_texture_unknown_is_not_a_permanent_focus_block"] = unknown.calls == 1
        await unknown.complete(); unknown.model.closePreview()
        let blurred = await host("blurred")
        for time in stride(from: 0.25, through: 3, by: 0.25) { feed(blurred, at: time, color: .gray, quality: blur) }
        checks["sustained_blur_remains_armed_without_a_request_or_archive"] = blurred.calls == 0 && blurred.model.acquiring && !blurred.model.canContinue && blurred.model.records.isEmpty
        checks["distance_hint_needs_repeated_blur_evidence"] = blurred.model.status.contains("稍微拉遠")
        blurred.model.closePreview()
        let hunting = await host("adjusting")
        hunting.clock.now = 3; hunting.model.updateAcquisitionWaitingHint()
        checks["no_frames_waits_with_guidance_without_guessing_focus"] = hunting.model.acquiring && hunting.calls == 0 && !hunting.model.status.contains("拉遠")
        hunting.clock.now = 120; hunting.model.updateAcquisitionWaitingHint()
        checks["long_wait_keeps_original_preview_deadline"] = hunting.model.acquiring && hunting.model.cycle.deadline == 300 && hunting.calls == 0
        hunting.model.closePreview()
        let af = await host("autofocus")
        af.model.capture.focusGate.begin(session: af.model.previewGeneration, autofocusSupported: true, adjusting: true, at: 0)
        af.clock.now = 0.5; af.model.receive(nil, generation: af.model.previewGeneration)
        af.clock.now = 3; af.model.updateAcquisitionWaitingHint()
        checks["AF_wait_has_distance_advice_and_remains_armed"] = af.model.focusMessage?.contains("稍微拉遠") == true && af.model.acquiring && af.calls == 0
        af.clock.now = 10; af.model.updateAcquisitionWaitingHint()
        af.model.capture.focusGate.update(adjusting: false, session: af.model.previewGeneration, at: 10)
        for time in [10.25, 10.5, 10.75, 11, 11.25] { feed(af, at: time, color: .blue, quality: detail) }
        await af.settle { af.waiter != nil }
        checks["AF_recovers_after_ten_seconds_and_sends_once_without_restart"] = af.calls == 1 && af.model.records.count == 1 && af.model.focusMessage == nil
        await af.complete()
        af.model.capture.focusGate.stop()
        _ = af.model.beginAcquisition(); af.clock.now = 15; af.model.updateAcquisitionWaitingHint()
        checks["next_intent_cannot_borrow_previous_focus_cause"] = af.model.focusMessage?.contains("拉遠") == false && af.calls == 1
        af.model.closePreview()
        let gap = await host("blur-gap")
        for time in [0.25, 0.5, 0.75] { feed(gap, at: time, color: .gray, quality: blur) }
        gap.clock.now = 1; gap.model.receive(nil, generation: gap.model.previewGeneration)
        gap.clock.now = 3; gap.model.updateAcquisitionWaitingHint()
        checks["missing_frame_keeps_this_intents_blur_diagnosis"] = gap.model.focusMessage?.contains("稍微拉遠") == true && gap.calls == 0
        gap.model.closePreview()
        let changedScene = await host("new-scene")
        for time in [0.25, 0.5, 0.75] { feed(changedScene, at: time, color: .gray, quality: blur) }
        changedScene.clock.now = 1
        let sceneImage = UIImage(data: C2FixtureHost.jpeg(.blue))!.cgImage!
        let sceneFingerprint = SceneFingerprint(rgb: (0..<192).map { $0 % 2 == 0 ? 0.2 : 0.8 }, side: 8)
        let registration = NativeSceneRegistration.Observation(fingerprint: sceneFingerprint, sceneChanged: true, reason: "fixture", distance: 1, maximumCornerMotion: 1, milliseconds: 0)
        changedScene.model.receive(CameraFrame(image: sceneImage, fingerprint: sceneFingerprint, feature: nil, time: 1, registration: registration, focusQuality: blur), generation: changedScene.model.previewGeneration)
        changedScene.clock.now = 3; changedScene.model.updateAcquisitionWaitingHint()
        checks["new_scene_does_not_inherit_old_blur_diagnosis"] = changedScene.model.focusMessage?.contains("拉遠") == false && changedScene.model.focusMessage?.contains("保持") == true && changedScene.calls == 0
        changedScene.model.closePreview()
        let motion = await host("motion")
        for (index, time) in stride(from: 0.25, through: 10.0, by: 0.25).enumerated() {
            motion.clock.now = time
            let image = UIImage(data: C2FixtureHost.jpeg(.blue))!.cgImage!
            let fingerprint = SceneFingerprint(rgb: Array(repeating: index % 2 == 0 ? 0.1 : 0.9, count: 192), side: 8)
            motion.model.receive(CameraFrame(image: image, fingerprint: fingerprint, feature: nil, time: time, focusQuality: detail), generation: motion.model.previewGeneration)
        }
        motion.clock.now = 10; motion.model.updateAcquisitionWaitingHint()
        checks["long_motion_waits_for_stability_without_distance_claim"] = motion.model.focusMessage?.contains("保持手機與目標穩定") == true && motion.model.focusMessage?.contains("拉遠") == false && motion.calls == 0 && motion.model.acquiring
        for time in [10.25, 10.5, 10.75, 11, 11.25] { feed(motion, at: time, color: .blue, quality: detail) }
        await motion.settle { motion.waiter != nil }
        checks["long_motion_then_stable_sends_once_without_restart"] = motion.calls == 1 && motion.model.records.count == 1 && motion.model.requestCount == 1
        await motion.complete()
        for time in [12.25, 12.5, 12.75, 13, 13.25] { feed(motion, at: time, color: .blue, quality: detail) }
        checks["completed_wait_does_not_rearm_or_resend"] = motion.calls == 1 && !motion.model.acquiring && motion.model.focusMessage == nil
        motion.model.closePreview()
        let late = await host("delayed-preflight")
        late.delayValidation = true
        _ = late.model.capture.visibleGate.resize(CGSize(width: 390, height: 390))
        for time in [0.25, 0.5, 0.75, 1, 1.25] {
            late.clock.now = time
            let stamp = late.model.capture.visibleGate.stamp(at: CameraCapture.hostTime())!
            _ = late.model.capture.visibleGate.markDisplayed(stamp)
            late.model.receive(CameraFrame(image: sceneImage, fingerprint: sceneFingerprint, feature: nil, time: time, visibleStamp: stamp, focusQuality: detail), generation: late.model.previewGeneration)
        }
        await late.settle { late.holdBeforeSend != nil }
        late.clock.now = 3.1; late.model.updateAcquisitionWaitingHint()
        try? await Task.sleep(for: .milliseconds(900))
        late.holdBeforeSend?.resume(); late.holdBeforeSend = nil
        await late.settle { late.waiter != nil || !late.model.busy }
        checks["delayed_preflight_does_not_expire_accepted_snapshot"] = late.calls == 1 && late.model.records.count == 1
        await late.complete(); late.model.closePreview()
        let recovered = await host("blur-then-stable")
        for time in stride(from: 0.25, through: 7, by: 0.25) { feed(recovered, at: time, color: .gray, quality: blur) }
        for time in [7.25, 7.5, 7.75, 8, 8.25] { feed(recovered, at: time, color: .blue, quality: detail) }
        await recovered.settle { recovered.waiter != nil }
        feed(recovered, at: 8.5, color: .blue, quality: detail)
        checks["first_qualified_frame_after_blur_sends_once_without_another_tap"] = recovered.calls == 1 && recovered.model.records.count == 1 && recovered.model.requestCount == 1
        await recovered.complete(); recovered.model.closePreview()
        let beforeDeadline = await host("before-deadline")
        for time in [1.99, 2.25, 2.5, 2.75, 2.99] { feed(beforeDeadline, at: time, color: .blue, quality: detail) }
        beforeDeadline.clock.now = 3.01; beforeDeadline.model.updateAcquisitionWaitingHint()
        await beforeDeadline.settle { beforeDeadline.waiter != nil }
        checks["qualified_frame_before_hint_completes_after_hint_once"] = beforeDeadline.calls == 1 && beforeDeadline.model.records.count == 1
        await beforeDeadline.complete(); beforeDeadline.model.closePreview()
        let atDeadline = await host("at-deadline")
        for time in [2, 2.25, 2.5, 2.75, 3] { feed(atDeadline, at: time, color: .blue, quality: detail) }
        await atDeadline.settle { atDeadline.waiter != nil }
        checks["qualification_at_three_seconds_keeps_same_intent_and_sends"] = atDeadline.calls == 1 && atDeadline.model.records.count == 1 && atDeadline.model.focusMessage == nil
        for time in [3.25, 3.5, 3.75, 4, 4.25] { feed(atDeadline, at: time, color: .blue, quality: detail) }
        checks["no_duplicate_after_three_second_boundary"] = atDeadline.calls == 1 && atDeadline.model.records.count == 1
        await atDeadline.complete(); atDeadline.model.closePreview()
        let stale = await host("stale-admission")
        _ = stale.model.capture.visibleGate.resize(CGSize(width: 390, height: 390))
        for time in [0.25, 0.5, 0.75, 1, 1.25] {
            stale.clock.now = time
            let stamp = stale.model.capture.visibleGate.stamp(at: CameraCapture.hostTime() - 1)!
            _ = stale.model.capture.visibleGate.markDisplayed(stamp)
            stale.model.receive(CameraFrame(image: sceneImage, fingerprint: sceneFingerprint, feature: nil, time: time, visibleStamp: stamp, focusQuality: detail), generation: stale.model.previewGeneration)
        }
        stale.clock.now = 3; stale.model.updateAcquisitionWaitingHint()
        checks["already_stale_image_never_gets_accepted_or_frozen"] = stale.calls == 0 && stale.model.records.isEmpty && stale.model.submittedPreview == nil
        stale.model.closePreview()
        let cancel = await host("cancel")
        cancel.clock.now = 10; cancel.model.updateAcquisitionWaitingHint(); cancel.model.cancelAcquisition()
        for time in [10.25, 10.5, 10.75, 11, 11.25] { feed(cancel, at: time, color: .blue, quality: detail) }
        checks["cancel_drops_selection_intent"] = cancel.calls == 0 && cancel.model.records.isEmpty && !cancel.model.acquiring && cancel.model.focusMessage == nil && cancel.model.previewOpen && cancel.model.cycle.deadline == 300
        cancel.model.closePreview()
        let background = await host("background-wait")
        background.clock.now = 10; background.model.updateAcquisitionWaitingHint()
        background.model.foreground(.background)
        for time in [10.25, 10.5, 10.75, 11, 11.25] { feed(background, at: time, color: .blue, quality: detail) }
        checks["background_ends_wait_without_request"] = !background.model.previewOpen && !background.model.acquiring && background.calls == 0 && background.model.focusMessage == nil
        background.model.foreground(.active)
        await background.settle { background.model.previewOpen }
        checks["foreground_does_not_resume_cancelled_intent"] = background.model.previewOpen && !background.model.acquiring && !background.model.capture.analysisGate.enabled && background.calls == 0
        background.model.closePreview()
        let expired = await host("five-minute-wait")
        expired.clock.now = 299.75; expired.model.updateAcquisitionWaitingHint()
        checks["still_waiting_before_original_five_minute_deadline"] = expired.model.acquiring && expired.model.cycle.deadline == 300 && expired.calls == 0
        feed(expired, at: 300, color: .blue, quality: detail)
        checks["five_minutes_closes_wait_before_any_send"] = expired.model.expired && !expired.model.acquiring && !expired.model.previewOpen && expired.calls == 0 && expired.model.records.isEmpty && expired.model.focusMessage == nil
        let failed = await host("camera-failure-wait")
        failed.clock.now = 10; failed.model.updateAcquisitionWaitingHint()
        failed.model.capture.onFailure?("synthetic-interruption")
        await failed.settle { !failed.model.previewOpen }
        checks["camera_failure_still_ends_wait"] = !failed.model.previewOpen && !failed.model.acquiring && failed.calls == 0 && failed.model.focusMessage == nil
        let denied = C2FixtureHost(name: "focus-denied")
        denied.model = denied.makeModel(permission: { false }); await denied.model.bootstrap()
        checks["permission_denied_never_arms_or_requests"] = !denied.model.beginAcquisition() && denied.model.permissionDenied && denied.calls == 0 && denied.starts == 0
        checks["no_camera_or_real_network"] = !best.model.capture.session.isRunning && C8NetworkProbe.shared.count == 0
        checks.merge(await CameraDarknessChecks.run(), uniquingKeysWith: { first, _ in first })
        return checks
    }
}
struct FocusSelectionChecksView: View {
    @State private var status = "running"
    var body: some View {
        Text(status).accessibilityIdentifier("focusSelectionResult").task {
            let checks = await FocusSelectionChecks.run()
            let passed = checks.values.allSatisfy { $0 }
            let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let data = try? JSONSerialization.data(withJSONObject: ["passed": passed, "checks": checks], options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: root.appendingPathComponent("focus-selection-fixture.json"))
            status = passed ? "focus-selection-passed-\(checks.count)" : "focus-selection-failed-" + checks.filter { !$0.value }.map(\.key).sorted().joined(separator: ",")
        }
    }
}

@MainActor enum CameraDarknessChecks {
    static func sample(_ host: C2FixtureHost, value: UInt8, at time: Double) {
        host.clock.now = time
        let decision = host.model.capture.darknessGate.observe(CameraDarknessMetrics(luminance: Array(repeating: value, count: 256)), at: time, session: host.model.previewGeneration)
        host.model.cameraDarknessChanged(decision, generation: host.model.previewGeneration)
    }
    static func blackout(_ host: C2FixtureHost) {
        let start = host.clock.now
        for offset in stride(from: 0.0, through: 2.0, by: 0.25) { sample(host, value: 0, at: start + offset) }
    }
    static func run() async -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let armed = await FocusSelectionChecks.host("black-armed")
        armed.clock.now = 10; armed.model.updateAcquisitionWaitingHint()
        blackout(armed); armed.feed(.black)
        checks["black_armed_never_sends_or_creates_card"] = armed.calls == 0 && armed.model.records.isEmpty && !armed.model.acquiring
        checks["black_closes_session_preserves_area_and_start_button"] = armed.model.darknessClosed && !armed.model.previewOpen && !armed.model.previewCollapsed && armed.model.canStartRecognition && armed.model.status == "畫面持續全黑，相機已關閉" && !armed.model.capture.analysisGate.enabled
        let starts = armed.starts
        armed.model.foreground(.background); armed.model.foreground(.active)
        armed.model.settingsChanged(true); armed.model.settingsChanged(false)
        for _ in 0..<8 { await Task.yield() }
        checks["black_does_not_reopen_after_foreground_or_settings"] = armed.starts == starts && !armed.model.previewOpen
        checks["black_explicit_start_reopens_and_arms"] = await armed.model.startRecognition()
        checks["black_reopen_clears_message_and_gets_new_deadline"] = !armed.model.darknessClosed && armed.model.cycle.deadline == armed.clock.now + 300
        armed.model.cancelAcquisition(); armed.model.closePreview()
        let short = await FocusSelectionChecks.host("black-short")
        for t in [0.25, 0.5] { sample(short, value: 80, at: t); FocusSelectionChecks.feed(short, at: t, color: .gray, quality: .unavailable) }
        sample(short, value: 0, at: 0.75)
        FocusSelectionChecks.feed(short, at: 0.75, color: .black, quality: .unavailable)
        checks["short_black_no_error_no_capture"] = short.model.previewOpen && short.model.acquiring && short.model.focusMessage == nil && short.calls == 0
        for t in [1.0, 1.25, 1.5, 1.75] { sample(short, value: 80, at: t); FocusSelectionChecks.feed(short, at: t, color: .gray, quality: .unavailable) }
        checks["short_black_restarts_stability_without_reusing_old_time"] = short.calls == 0 && !short.model.busy
        sample(short, value: 80, at: 2); FocusSelectionChecks.feed(short, at: 2, color: .gray, quality: .unavailable)
        await short.settle { short.waiter != nil }
        checks["normal_after_short_black_uses_original_one_second_wait"] = short.calls == 1
        await short.complete(); short.model.closePreview()
        let preflight = await FocusSelectionChecks.host("black-preflight"); preflight.delayValidation = true
        for t in [0.25, 0.5, 0.75, 1, 1.25] { sample(preflight, value: 80, at: t); FocusSelectionChecks.feed(preflight, at: t, color: .gray, quality: .unavailable) }
        await preflight.settle { preflight.holdBeforeSend != nil }
        sample(preflight, value: 0, at: 1.5); sample(preflight, value: 80, at: 1.75)
        preflight.holdBeforeSend?.resume(); preflight.holdBeforeSend = nil
        await preflight.model.waitForCurrentWork()
        checks["short_black_invalidates_preflight_image_even_after_clear"] = preflight.calls == 0 && preflight.model.records.first?.status == .failed && preflight.model.previewOpen
        preflight.model.closePreview()
        let idle = C2FixtureHost(name: "black-idle"); await idle.model.bootstrap()
        blackout(idle)
        checks["idle_preview_black_closes_without_AI"] = idle.model.darknessClosed && idle.calls == 0 && idle.starts == 1
        idle.model.historyDragBegan()
        checks["black_explicit_pull_reopens_without_arm"] = await idle.model.reopenPreviewFromHistoryPull()
        checks["black_pull_clears_warning_but_does_not_analyze"] = !idle.model.darknessClosed && !idle.model.acquiring && !idle.model.capture.analysisGate.enabled
        idle.model.closePreview()
        let sent = await FocusSelectionChecks.host("black-sent")
        sent.feed(); await sent.settle { sent.waiter != nil }
        let id = sent.model.records.first?.id
        blackout(sent)
        checks["sent_black_does_not_cancel_transport"] = sent.model.darknessClosed && sent.model.busy && sent.waiter != nil && sent.calls == 1
        await sent.complete()
        checks["sent_black_result_saved_same_card_without_reopening"] = sent.model.records.first?.id == id && sent.model.records.first?.status == .succeeded && sent.model.darknessClosed && !sent.model.previewOpen
        let photo = C2FixtureHost(name: "black-photo"); await photo.model.bootstrap()
        let selection = photo.model.beginPhotoSelection()!; _ = photo.model.photoTransferStarted(id: selection)
        photo.model.photoPickerDismissed(id: selection)
        _ = await photo.model.prepareSelectedPhoto(C2FixtureHost.jpeg(.black), selectionID: selection)
        await photo.settle { photo.waiter != nil }
        checks["black_photo_is_not_camera_obscuration"] = photo.calls == 1 && !photo.model.darknessClosed && photo.model.records.first?.source == .photoLibrary
        await photo.complete()
        // Use the production CVPixelBuffer adapter, including BGRA order and crop.
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, nil, &buffer)
        if status == kCVReturnSuccess, let buffer {
            CVPixelBufferLockBaseAddress(buffer, [])
            let raw = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<32 { for x in 0..<32 { let i = y * row + x * 4; raw[i] = 0; raw[i+1] = 0; raw[i+2] = 0; raw[i+3] = 255 } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            checks["production_BGRA_black_adapter"] = CameraCapture.darknessMetrics(buffer, viewport: CGSize(width: 1, height: 1))?.nearBlack == true
            CVPixelBufferLockBaseAddress(buffer, [])
            for y in 0..<32 { for x in 0..<32 where x % 4 < 2 { let i = y * row + x * 4; raw[i] = 30; raw[i+1] = 30; raw[i+2] = 30 } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            checks["production_BGRA_dark_object_detail_not_black"] = CameraCapture.darknessMetrics(buffer, viewport: CGSize(width: 1, height: 1))?.nearBlack == false
        } else { checks["production_BGRA_black_adapter"] = false }
        return checks
    }
}

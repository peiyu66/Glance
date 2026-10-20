import SwiftUI

extension C2FixtureHost {
    func inspectDeletionFiles() async {
        do {
            let disk = try await model.archive.load(recoverPending: false)
            let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            let ids = Set(model.records.map(\.id))
            let images = folders.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("source.jpg").path) }
            let passed = Set(disk.records.map(\.id)) == ids && folders.count == ids.count && images.count == ids.count && disk.deletionIssues.isEmpty
            deletionFileStatus = passed ? "passed-\(ids.count)" : "failed"
            let report: [String: Any] = ["passed": passed, "recordCount": ids.count, "imageCount": images.count,
                "folderCount": folders.count, "physicalDeviceOperations": 0, "realNetworkRequests": 0]
            let file = root.deletingLastPathComponent().appendingPathComponent("history-deletion-files.json")
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: file)
        } catch { deletionFileStatus = "failed-read" }
    }
}

@MainActor enum HistoryDeletionChecks {
    static func run() async -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let host = C2FixtureHost(name: "build34-deletion-controller-" + UUID().uuidString)
        await host.model.bootstrap()
        checks["empty_clear_disabled"] = !host.model.canClearHistory
        func recognize() async -> UUID? {
            _ = host.model.beginAcquisition(); host.feed(); await host.settle { host.waiter != nil }
            await host.complete(); return host.model.records.first?.id
        }
        guard let old = await recognize() else { return ["setup": false] }
        _ = host.model.beginAcquisition(); host.feed(); await host.settle { host.waiter != nil }
        guard let pending = host.model.cycle.activeID else { return ["pending_setup": false] }
        checks["pending_has_no_single_delete"] = !host.model.canDeleteRecord(pending)
        checks["pending_delete_rejected_in_controller"] = !(await host.model.deleteRecord(id: pending))
        checks["busy_clear_disabled_with_reason"] = !host.model.canClearHistory && host.model.clearHistoryBlockedReason?.contains("辨識進行中") == true
        checks["busy_clear_rejected_in_controller"] = !(await host.model.clearHistory(confirmedIDs: Set(host.model.records.map(\.id))))
        checks["older_record_deletable_while_current_pending"] = await host.model.deleteRecord(id: old)
        checks["deletion_preserves_pending_work_and_preview"] = host.model.busy && host.model.previewOpen && host.calls == 2 && host.model.records.map(\.id) == [pending]
        await host.complete()
        let reopened = host.makeModel(); await reopened.bootstrap()
        checks["controller_reopen_keeps_deletion"] = reopened.records.map(\.id) == [pending]
        reopened.closePreview()
        let confirmed = Set(host.model.records.map(\.id))
        _ = await recognize()
        checks["changed_confirmation_rejected"] = !(await host.model.clearHistory(confirmedIDs: confirmed)) && host.model.records.count == 2
        host.writeFault.set(true)
        checks["delete_failure_keeps_card_and_reports"] = !(await host.model.deleteRecord(id: pending)) && host.model.records.count == 2 && host.model.deletionError != nil
        host.writeFault.set(false)
        host.model.historyDragBegan()
        let starts = host.starts
        checks["confirmed_clear_removes_all"] = await host.model.clearHistory(confirmedIDs: Set(host.model.records.map(\.id)))
        checks["empty_after_clear_keeps_camera_collapsed"] = host.model.records.isEmpty && !host.model.canClearHistory && host.model.previewCollapsed && host.starts == starts
        checks["clear_removes_all_image_and_record_directories"] = (try? FileManager.default.contentsOfDirectory(atPath: host.root.path).isEmpty) == true
        let afterClear = host.makeModel(); await afterClear.bootstrap()
        checks["reopen_after_all_remains_empty"] = afterClear.records.isEmpty
        afterClear.closePreview(); host.model.closePreview()

        let wiki = C5WikipediaProbe()
        let enrichment = C2FixtureHost(name: "build34-deletion-wiki-" + UUID().uuidString, wikipediaLookup: { await wiki.lookup($0) })
        await enrichment.model.bootstrap(); _ = enrichment.model.beginAcquisition(); enrichment.feed()
        await enrichment.settle { enrichment.waiter != nil }
        enrichment.waiter?.resume(returning: C5WikipediaProbe.result()); enrichment.waiter = nil
        await enrichment.model.waitForCurrentWork(); await enrichment.settle { wiki.calls == 1 }
        guard let id = enrichment.model.records.first?.id else { return checks.merging(["wiki_setup": false], uniquingKeysWith: { _, b in b }) }
        checks["completed_record_deletes_during_optional_lookup"] = await enrichment.model.deleteRecord(id: id)
        wiki.finish()
        for _ in 0..<20 { await Task.yield() }
        let wikiDiskEmpty = (try? await enrichment.model.archive.load().records.isEmpty) == true
        checks["late_wiki_cannot_resurrect_memory_or_disk"] = enrichment.model.records.isEmpty && wikiDiskEmpty
        do {
            _ = try await enrichment.model.archive.attachWikipedia(id: id, reference: C5WikipediaProbe.reference()!)
            checks["late_archive_enrichment_rejected"] = false
        } catch { checks["late_archive_enrichment_rejected"] = true }
        enrichment.model.closePreview()

        let late = C2FixtureHost(name: "build34-deletion-timeout-" + UUID().uuidString)
        late.model = late.makeModel(requestTimeout: .milliseconds(80))
        await late.model.bootstrap(); _ = late.model.beginAcquisition(); late.feed()
        await late.settle { late.waiter != nil }; await late.settle { !late.model.busy }
        guard let timedOut = late.model.records.first?.id else { return checks.merging(["timeout_setup": false], uniquingKeysWith: { _, b in b }) }
        checks["timed_out_record_can_be_deleted"] = await late.model.deleteRecord(id: timedOut)
        late.waiter?.resume(returning: .init(names: ["late answer"])); late.waiter = nil
        for _ in 0..<20 { await Task.yield() }
        let lateDiskEmpty = (try? await late.model.archive.load().records.isEmpty) == true
        checks["late_ai_cannot_resurrect_deleted_timeout"] = late.model.records.isEmpty && late.model.storageError == nil && lateDiskEmpty
        late.model.closePreview()
        let unsaved = C2FixtureHost(name: "build34-deletion-unsaved-" + UUID().uuidString)
        await unsaved.model.bootstrap(); _ = unsaved.model.beginAcquisition(); unsaved.feed()
        await unsaved.settle { unsaved.waiter != nil }; unsaved.writeFault.set(true)
        await unsaved.complete()
        if let id = unsaved.model.records.first?.id {
            checks["unsaved_reply_blocks_single_and_clear"] = !unsaved.model.canDeleteRecord(id) && !unsaved.model.canClearHistory && unsaved.model.storageError != nil
            checks["unsaved_delete_rejected"] = !(await unsaved.model.deleteRecord(id: id))
            unsaved.writeFault.set(false); await unsaved.model.retrySaving()
            checks["saved_reply_becomes_deletable"] = await unsaved.model.deleteRecord(id: id)
        } else { checks["unsaved_setup"] = false }
        unsaved.model.closePreview()
        return checks
    }
}

struct HistoryDeletionChecksView: View {
    @State private var result = "running"
    var body: some View {
        Text(result).accessibilityIdentifier("historyDeletionChecksResult").task {
            let checks = await HistoryDeletionChecks.run()
            let passed = checks.values.allSatisfy { $0 }
            let report: [String: Any] = ["passed": passed, "checks": checks, "count": checks.count, "realNetworkRequests": 0, "physicalDeviceOperations": 0]
            let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("history-deletion-controller.json")
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: file)
            result = passed ? "passed \(checks.count)" : "FAILED " + checks.filter { !$0.value }.map(\.key).sorted().joined(separator: ",")
        }
    }
}

@MainActor enum ScrollCollapseChecks {
    static func run() async -> [String: Bool] {
        var checks: [String: Bool] = [:]
        func host(_ suffix: String) async -> C2FixtureHost {
            let host = C2FixtureHost(name: "scroll-collapse-" + suffix)
            try? FileManager.default.removeItem(at: host.root)
            await host.model.bootstrap(); return host
        }
        let idle = await host("idle")
        let generation = idle.model.previewGeneration
        idle.model.historyDragBegan()
        checks["manual_drag_stops_session_analysis_and_focus"] = idle.model.previewCollapsed && !idle.model.previewOpen && !idle.model.capture.analysisGate.enabled && !idle.model.capture.focusGate.snapshot.active && idle.stops == 1
        idle.model.historyDragBegan()
        checks["continued_drag_does_not_repeat_stop_or_send"] = idle.stops == 1 && idle.calls == 0
        idle.model.foreground(.background); idle.model.foreground(.active)
        idle.model.settingsChanged(true); idle.model.settingsChanged(false)
        for _ in 0..<8 { await Task.yield() }
        checks["foreground_and_settings_do_not_reopen_reading_camera"] = idle.starts == 1 && idle.model.previewCollapsed && !idle.model.previewOpen
        checks["one_press_reopens_and_arms"] = await idle.model.startRecognition()
        checks["fresh_generation_and_analysis_after_explicit_start"] = idle.starts == 2 && idle.model.previewGeneration != generation && !idle.model.previewCollapsed && idle.model.acquiring && idle.model.capture.analysisGate.enabled
        checks["rapid_second_press_does_not_queue"] = !(await idle.model.startRecognition())
        idle.feed(); await idle.settle { idle.waiter != nil }
        checks["one_pending_card_and_presentation_per_capture"] = idle.calls == 1 && idle.model.records.count == 1 && idle.model.pendingPresentation?.recordID == idle.model.records.first?.id
        idle.feed(); checks["extra_frames_cannot_send_second_image"] = idle.calls == 1
        await idle.complete()
        checks["completion_keeps_card_uuid"] = idle.model.records.count == 1 && idle.model.records.first?.id == idle.model.pendingPresentation?.recordID
        idle.model.closePreview()

        let acquiring = await host("acquiring")
        _ = acquiring.model.beginAcquisition(); acquiring.model.historyDragBegan(); acquiring.feed()
        checks["collapse_cancels_capture_intent_before_reservation"] = !acquiring.model.acquiring && !acquiring.model.busy && acquiring.calls == 0 && acquiring.model.records.isEmpty

        let preflight = await host("preflight"); preflight.delayValidation = true
        _ = preflight.model.beginAcquisition(); preflight.feed()
        await preflight.settle { preflight.holdBeforeSend != nil }
        preflight.model.historyDragBegan()
        preflight.holdBeforeSend?.resume(); preflight.holdBeforeSend = nil
        await preflight.model.waitForCurrentWork()
        checks["collapse_before_transport_sends_nothing_and_keeps_saved_image"] = preflight.calls == 0 && preflight.model.records.count == 1 && preflight.model.records.first?.status == .failed && preflight.model.previewCollapsed

        let sent = await host("sent")
        _ = sent.model.beginAcquisition(); sent.feed(); await sent.settle { sent.waiter != nil }
        let id = sent.model.records.first!.id; let bytes = sent.lastJPEG
        sent.model.historyDragBegan()
        checks["collapse_after_send_retains_pending_request"] = sent.model.busy && sent.waiter != nil && sent.calls == 1
        await sent.complete(fail: true)
        checks["failed_reply_does_not_reopen_or_discard_original"] = sent.model.previewCollapsed && sent.model.records.first?.id == id && sent.model.records.first?.status == .failed && sent.starts == 1
        checks["explicit_retry_uses_same_card_while_camera_collapsed"] = sent.model.retryImage(id: id)
        await sent.settle { sent.waiter != nil }
        checks["retry_presentation_has_same_id_new_attempt_and_exact_bytes"] = sent.model.pendingPresentation?.recordID == id && sent.model.pendingPresentation?.attemptID != id && sent.lastJPEG == bytes && sent.starts == 1 && sent.model.records.count == 1
        sent.model.historyDragBegan(); await sent.complete()
        checks["retry_completion_keeps_reading_state"] = sent.model.readingHistory && sent.model.previewCollapsed && sent.model.records.first?.status == .succeeded && sent.model.records.first?.attemptNumber == 2

        let photo = await host("photo"); photo.model.historyDragBegan()
        let selection = photo.model.beginPhotoSelection()!
        _ = photo.model.photoTransferStarted(id: selection)
        _ = await photo.model.prepareSelectedPhoto(C2FixtureHost.jpeg(.green), selectionID: selection)
        checks["photo_selection_still_previews_without_opening_camera"] = photo.model.selectedPhoto != nil && photo.starts == 1 && photo.calls == 0
        photo.model.photoPickerDismissed(id: selection)
        photo.model.photoPickerDismissed(id: selection)
        checks["photo_dismissal_reserves_once"] = photo.model.busy && photo.model.selectedPhoto == nil
        await photo.settle { photo.waiter != nil }
        let photoID = photo.model.records.first?.id
        checks["photo_pending_presentation_is_own_card"] = photo.model.pendingPresentation?.recordID == photoID && photo.model.records.first?.source == .photoLibrary
        photo.model.historyDragBegan(); await photo.complete()
        checks["photo_reply_preserved_while_reading_collapsed_list"] = photo.model.records.first?.id == photoID && photo.model.records.first?.status == .succeeded && photo.model.previewCollapsed && photo.calls == 1

        let wiki = C5WikipediaProbe()
        let enriched = C2FixtureHost(name: "scroll-collapse-wiki", wikipediaLookup: { await wiki.lookup($0) })
        try? FileManager.default.removeItem(at: enriched.root); await enriched.model.bootstrap()
        _ = enriched.model.beginAcquisition(); enriched.feed(); await enriched.settle { enriched.waiter != nil }
        enriched.model.historyDragBegan()
        enriched.waiter?.resume(returning: C5WikipediaProbe.result()); enriched.waiter = nil
        await enriched.model.waitForCurrentWork(); await enriched.settle { wiki.calls == 1 }
        checks["sent_reply_can_enrich_while_camera_collapsed"] = wiki.calls == 1 && enriched.model.records.first?.status == .succeeded
        wiki.finish(); await enriched.model.waitForWikipediaWork()
        checks["wiki_saved_to_original_card_without_reopening"] = enriched.model.records.first?.wikipedia != nil && enriched.starts == 1 && enriched.model.previewCollapsed
        let reopened = try? await RecognitionArchive(root: enriched.root).load().records
        checks["collapsed_completion_and_wiki_survive_restart"] = reopened == enriched.model.records
        let pull = await host("pull")
        pull.model.historyDragBegan()
        checks["pull_opens_preview_without_arm"] = await pull.model.reopenPreviewFromHistoryPull()
        checks["pull_does_not_analyze_or_send_and_keeps_reading"] = pull.model.previewOpen && !pull.model.acquiring && !pull.model.capture.analysisGate.enabled && pull.calls == 0 && pull.model.readingHistory
        checks["duplicate_pull_cannot_restart_open_preview"] = !(await pull.model.reopenPreviewFromHistoryPull()) && pull.starts == 2
        pull.feed()
        checks["frames_after_pull_cannot_create_card"] = pull.calls == 0 && pull.model.records.isEmpty
        pull.clock.now += 301; pull.model.checkPreviewDeadline(); pull.model.historyDragBegan()
        checks["explicit_pull_renews_expired_preview_only"] = await pull.model.reopenPreviewFromHistoryPull()
        checks["renewed_preview_has_fresh_five_minute_deadline"] = !pull.model.expired && pull.model.cycle.deadline == pull.clock.now + 300 && !pull.model.acquiring
        pull.model.historyDragBegan(); pull.model.foreground(.background)
        checks["background_pull_cannot_open"] = !(await pull.model.reopenPreviewFromHistoryPull()) && !pull.model.previewOpen
        pull.model.foreground(.active)
        pull.model.settingsChanged(true)
        checks["settings_pull_cannot_open"] = !(await pull.model.reopenPreviewFromHistoryPull())
        pull.model.settingsChanged(false)
        let selectionID = pull.model.beginPhotoSelection()!
        checks["picker_pull_does_not_discard_selection"] = !(await pull.model.reopenPreviewFromHistoryPull()) && pull.model.photoSelectionActive
        _ = pull.model.photoTransferStarted(id: selectionID)
        checks["loading_pull_does_not_cancel_photo"] = !(await pull.model.reopenPreviewFromHistoryPull()) && pull.model.photoLoading
        _ = await pull.model.prepareSelectedPhoto(C2FixtureHost.jpeg(.blue), selectionID: selectionID)
        pull.model.photoPickerDismissed(id: selectionID)
        await pull.settle { pull.waiter != nil }
        let pendingID = pull.model.pendingPresentation
        checks["inflight_pull_preserves_single_request_and_card"] = !(await pull.model.reopenPreviewFromHistoryPull()) && pull.calls == 1 && pull.model.busy && pull.model.pendingPresentation == pendingID
        await pull.complete()
        checks["completed_photo_can_reopen_preview_only"] = await pull.model.reopenPreviewFromHistoryPull()
        checks["photo_reopen_removes_old_frozen_image"] = pull.model.submittedPreview == nil && !pull.model.acquiring && pull.calls == 1
        pull.model.closePreview()

        let denied = C2FixtureHost(name: "scroll-pull-denied")
        denied.model = denied.makeModel(permission: { false })
        await denied.model.bootstrap(); denied.model.historyDragBegan()
        checks["denied_permission_stays_closed_without_send"] = !(await denied.model.reopenPreviewFromHistoryPull()) && denied.model.permissionDenied && denied.starts == 0 && denied.calls == 0
        let race = await host("permission-race")
        var permissionWait: CheckedContinuation<Bool, Never>?
        race.model.closePreview()
        race.model = race.makeModel(permission: { await withCheckedContinuation { permissionWait = $0 } })
        await race.model.reloadHistory(); race.model.historyDragBegan()
        let opening = Task { await race.model.reopenPreviewFromHistoryPull() }
        await race.settle { permissionWait != nil }
        race.model.foreground(.background)
        permissionWait?.resume(returning: true)
        checks["late_permission_after_background_does_not_open"] = !(await opening.value) && race.starts == 1 && !race.model.previewOpen && race.calls == 0
        return checks
    }
}

struct ScrollCollapseChecksView: View {
    @State private var status = "running"
    var body: some View {
        Text(status).accessibilityIdentifier("scrollCollapseResult").task {
            let checks = await ScrollCollapseChecks.run()
            let passed = checks.values.allSatisfy { $0 }
            let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let report: [String: Any] = ["passed": passed, "count": checks.count, "checks": checks,
                "realCameraRequests": 0, "realNetworkRequests": 0]
            try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                .write(to: root.appendingPathComponent("scroll-collapse-checks.json"))
            status = passed ? "passed \(checks.count)" : "FAILED " + checks.filter { !$0.value }.map(\.key).sorted().joined(separator: ",")
        }
    }
}

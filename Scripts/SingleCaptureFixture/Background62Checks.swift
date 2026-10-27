import SwiftUI

/// Deterministic finite UIKit allowance; it grants no actual OS background time.
@MainActor final class Background62Lease {
    var begins = 0
    var ends: [UIBackgroundTaskIdentifier] = []
    var handlers: [() -> Void] = []
    var unavailable = false
    func begin(_ handler: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        begins += 1; handlers.append(handler)
        return unavailable ? .invalid : UIBackgroundTaskIdentifier(rawValue: 6200 + begins)
    }
    func end(_ id: UIBackgroundTaskIdentifier) { ends.append(id) }
    func expire() { handlers.last?() }
}

extension C2FixtureHost {
    func finishFirst62(fail: Bool = false) async {
        let value = waiter; waiter = nil
        if fail { value?.resume(throwing: URLError(.notConnectedToInternet)) }
        else { value?.resume(returning: Semantic45Probe.result) }
        await model.waitForCurrentWork()
    }
    func runBackground62Checks() async -> [String: Bool] {
        var c: [String: Bool] = [:]
        func make(_ name: String) async -> (C2FixtureHost, Semantic45Probe, Background62Lease) {
            let h = C2FixtureHost(name: "background62-" + name), p = Semantic45Probe(), b = Background62Lease()
            try? FileManager.default.removeItem(at: h.root)
            h.model = h.makeModel(semantic: p, background: b); await h.model.bootstrap()
            return (h, p, b)
        }
        // Foreground authorization carries one captured image through both stages,
        // even if stage two has not been submitted when active changes.
        do {
            let (h,p,b) = await make("whole-pipeline")
            p.holdSources = true
            _ = h.model.beginAcquisition(); h.feed(); await h.settle { h.waiter != nil }
            c["first_image_pending_has_processing_presentation"] = h.model.isRecognizingImage && h.model.busy
            let id = h.model.records.first!.id, starts = h.starts
            h.model.foreground(.inactive); h.model.foreground(.background)
            c["one_allowance_for_inactive_then_background"] = b.begins == 1 && !h.model.previewOpen
            await h.finishFirst62(); await h.settle { p.sourceWait != nil }
            c["stage_one_completes_and_collects_in_background"] = h.model.records.first?.status == .succeeded && p.sourceCalls == 1 && b.ends.isEmpty
            c["first_image_completion_ends_processing_before_sources"] = !h.model.isRecognizingImage && !h.model.busy
            p.finishSources(); await h.settle { p.waits[id] != nil }
            c["stage_two_starts_in_background_under_same_allowance"] = p.calls == 1 && b.begins == 1 && b.ends.isEmpty
            p.finish(id); await h.model.waitForWikipediaWork()
            c["whole_pipeline_releases_allowance_after_save"] = h.model.records.first?.semanticReview?.state == .succeeded && b.ends.count == 1
            h.model.foreground(.active); await h.model.reloadHistory()
            c["return_has_no_camera_or_request_restart"] = h.starts == starts && !h.model.previewOpen && h.calls == 1 && p.calls == 1
            c["completed_record_survives_load"] = (try? await h.model.archive.load().records.first) == h.model.records.first
            h.model.closePreview()
        }
        for phase in ["first", "sources", "second", "unavailable"] {
            let (h,p,b) = await make("expire-" + phase)
            p.holdSources = phase == "sources"
            _ = h.model.beginAcquisition(); h.feed(); await h.settle { h.waiter != nil }
            let id = h.model.records.first!.id
            if phase == "sources" || phase == "second" {
                await h.finishFirst62()
                await h.settle { phase == "sources" ? p.sourceWait != nil : p.waits[id] != nil }
            }
            b.unavailable = phase == "unavailable"
            h.model.foreground(.background)
            if !b.unavailable { b.expire(); b.expire() }
            await h.settle { !h.model.busy && h.model.records.first?.semanticReview?.isPending != true }
            if phase == "first" || phase == "unavailable" {
                c[phase + "_first_interrupted_with_exact_reason"] = h.model.records.first?.status == .interrupted && h.model.records.first?.attempts?.last?.stopReason == (b.unavailable ? .backgroundTimeUnavailable : .backgroundTimeExpired)
                await h.finishFirst62()
                c[phase + "_late_first_cannot_start_second"] = p.calls == 0 && p.sourceCalls == 0
            } else {
                let before = h.model.records.first
                c[phase + "_preserves_usable_first_card"] = before?.status == .succeeded && before?.semanticReview?.stopReason == .backgroundTimeExpired && before?.semanticReview?.state == .cancelled
                p.finishSources(); await h.settle { p.sourceWait == nil }
                p.finish(id); await Task.yield()
                c[phase + "_late_result_cannot_add_reference"] = h.model.records.first?.currentSemanticReview?.source == nil
            }
            h.model.foreground(.active); await h.model.reloadHistory()
            c[phase + "_no_resume_resend_or_double_end"] = h.calls == 1 && p.calls <= 1 && b.ends.count == (b.unavailable ? 0 : 1) && !h.model.previewOpen
            h.model.closePreview()
        }
        do {
            let (h,p,b) = await make("brief-inactive")
            h.delayValidation = true
            _ = h.model.beginAcquisition(); h.feed(); await h.settle { h.holdBeforeSend != nil }
            h.model.foreground(.inactive); h.model.foreground(.active)
            h.holdBeforeSend?.resume(); h.holdBeforeSend = nil
            await h.settle { h.waiter != nil }; await h.finishFirst62()
            let id = h.model.records.first!.id
            await h.settle { p.waits[id] != nil }; await h.model.reloadHistory()
            c["brief_inactive_preserves_preflight_and_live_second"] = h.calls == 1 && h.model.records.first?.semanticReview?.state == .reviewing && b.ends.count == 1
            h.model.foreground(.background)
            b.handlers.first?(); await Task.yield(); await Task.yield()
            c["expired_old_callback_cannot_revoke_new_allowance"] = b.begins == 2 && b.ends.count == 1 && h.model.records.first?.semanticReview?.isPending == true
            p.finish(id); await h.model.waitForWikipediaWork()
            c["brief_return_completes_without_automatic_retry"] = h.model.records.first?.semanticReview?.state == .succeeded && h.calls == 1 && p.calls == 1 && b.ends.count == 2
            h.model.closePreview()
        }
        for outcome in ["success", "failure", "expiry", "account", "withdraw"] {
            let (h,p,b) = await make("refresh-" + outcome)
            guard let id = await h.recognize45(p) else { c[outcome + "_seed"] = false; continue }
            p.finish(id); await h.model.waitForWikipediaWork()
            let old = h.model.records.first!, image = try? await h.model.archive.image(for: old), starts = h.starts
            c[outcome + "_refresh_reserves_once"] = h.model.retryImage(id: id) && !h.model.retryImage(id: id) && !h.model.canStartRecognition && !h.model.canChoosePhoto
            c[outcome + "_refresh_image_has_processing_presentation"] = h.model.isRecognizingImage
            await h.settle { h.waiter != nil }
            let pending = h.model.records.first!
            c[outcome + "_pending_retains_same_image_card_and_share"] = pending.id == id && pending.sequence == old.sequence && pending.capturedAt == old.capturedAt && pending.shareDocument() == old.shareDocument() && h.lastJPEG == image && h.starts == starts
            if outcome == "expiry" {
                h.model.foreground(.background); b.expire()
                await h.settle { !h.model.busy }
            } else if outcome == "account" {
                h.model.account.selectedID = "synthetic-account-changed"; h.model.accountStateChanged()
                await h.settle { !h.model.busy }
            } else if outcome == "withdraw" {
                h.model.withdrawDataUse(); await h.settle { !h.model.busy }
            }
            await h.finishFirst62(fail: outcome == "failure")
            if outcome == "success" {
                await h.settle { p.waits[id] != nil }
                c["refresh_busy_spans_second_stage"] = h.model.busy && !h.model.canStartRecognition && !h.model.canChoosePhoto && !h.model.retryImage(id: id)
                c["refresh_second_keeps_lock_without_processing_presentation"] = !h.model.isRecognizingImage && h.model.records.first?.status == .succeeded
                c["new_first_discards_old_wiki_and_raw_association"] = h.model.records.first?.retainedSuccess == nil && h.model.records.first?.currentSemanticReview?.source == nil && h.model.records.first?.currentAttemptID != old.currentAttemptID
                h.model.foreground(.background)
                p.finish(id); await h.model.waitForWikipediaWork()
                c["refresh_success_releases_all_gates"] = !h.model.busy && h.model.records.count == 1 && h.model.records.first?.semanticReview?.state == .succeeded && b.ends.count == 1
                h.model.foreground(.active)
            } else {
                c[outcome + "_refresh_failure_retains_success_without_lock"] = !h.model.busy && h.model.records.first?.shareDocument() == old.shareDocument() && h.model.records.first?.retainedSuccess != nil
                c[outcome + "_refresh_failure_starts_no_second"] = p.calls == 1
                h.model.foreground(.active)
            }
            // Exercise an actual inactive→active transition in every case.
            // Failure while staying active may legitimately retain its open preview.
            h.model.foreground(.inactive); h.model.foreground(.active)
            await h.model.reloadHistory()
            c[outcome + "_refresh_reopen_never_resends"] = h.calls == 2 && p.calls == (outcome == "success" ? 2 : 1) && !h.model.previewOpen && h.starts == starts
            h.model.closePreview()
        }
        do {
            let (h,p,b) = await make("preflight-expiry")
            h.delayValidation = true
            _ = h.model.beginAcquisition(); h.feed(); await h.settle { h.holdBeforeSend != nil }
            h.model.foreground(.background); b.expire()
            await h.settle { !h.model.busy }
            c["expiry_before_transport_releases_slot_and_marks_interrupted"] = !h.model.busy && h.model.records.first?.status == .interrupted && h.calls == 0
            h.holdBeforeSend?.resume(); h.holdBeforeSend = nil
            await Task.yield(); await Task.yield()
            c["expired_preflight_never_sends_on_late_release"] = h.calls == 0 && p.calls == 0 && b.ends.count == 1
            h.model.closePreview()
        }
        for round in 0..<4 {
            let (h,p,_) = await make("reload-race-\(round)")
            let id = await h.recognize45(p)!
            let reload = Task { await h.model.reloadHistory() }
            if round % 2 == 0 { await Task.yield() }
            p.finish(id)
            await h.model.waitForWikipediaWork(); await reload.value
            c["reload_does_not_restore_pending_over_terminal_\(round)"] = h.model.records.first?.semanticReview?.state == .succeeded && h.model.records.first?.currentAttemptID == id && p.calls == 1
            h.model.closePreview()
        }
        do {
            let (h,p,_) = await make("replace-live-second")
            let id = await h.recognize45(p)!
            let oldRun = h.model.records.first?.semanticReview?.runID
            let oldReply = p.waits.removeValue(forKey: id)
            c["refresh_can_replace_own_pending_optional_stage"] = h.model.retryImage(id: id)
            await h.settle { h.waiter != nil }; await h.finishFirst62()
            await h.settle { p.waits[id] != nil }
            let newRun = h.model.records.first?.semanticReview?.runID
            oldReply?.resume(returning: String(decoding: try! JSONEncoder().encode(Semantic45Probe.answer), as: UTF8.self))
            await Task.yield(); await Task.yield()
            c["old_second_callback_cannot_complete_or_unlock_refresh"] = oldRun != newRun && h.model.records.first?.semanticReview?.runID == newRun && h.model.records.first?.semanticReview?.isPending == true && h.model.busy
            p.finish(id); await h.model.waitForWikipediaWork()
            c["replacement_finishes_only_current_attempt"] = h.model.records.first?.semanticReview?.runID == newRun && h.model.records.first?.semanticReview?.state == .succeeded && !h.model.busy && h.calls == 2 && p.calls == 2
            h.model.closePreview()
        }
        do {
            let (h,p,b) = await make("save-failure")
            _ = h.model.beginAcquisition(); h.feed(); await h.settle { h.waiter != nil }
            h.model.foreground(.background); h.writeFault.set(true)
            await h.finishFirst62()
            c["save_failure_keeps_first_result_and_ends_allowance"] = h.model.records.first?.status == .succeeded && h.model.storageError != nil && b.ends.count == 1 && p.calls == 0
            h.writeFault.set(false)
            h.model.foreground(.active); await h.model.retrySaving()
            let saved = try? await h.model.archive.load().records.first
            c["foreground_retries_storage_without_network_resubmit"] = saved?.status == .succeeded && h.model.storageError == nil && h.calls == 1 && p.calls == 0 && !h.model.previewOpen
            h.model.closePreview()
        }
        do {
            let (h,p,_) = await make("missing")
            let id = await h.recognize45(p)!
            p.finish(id); await h.model.waitForWikipediaWork()
            let old = h.model.records.first!
            try? FileManager.default.removeItem(at: h.root.appendingPathComponent(id.uuidString).appendingPathComponent("source.jpg"))
            await h.model.reloadHistory()
            c["missing_image_disables_refresh_without_losing_card"] = !h.model.retryImage(id: id) && h.model.missingImageReason(old) != nil && h.model.records.first == old && h.calls == 1
            h.model.closePreview()
        }
        c["no_real_network_or_model"] = C8NetworkProbe.shared.count == 0
        return c
    }
}

struct Background62View: View {
    @State private var host = C2FixtureHost(name: "refresh62-ui")
    @State private var probe = Semantic45Probe()
    @State private var lease = Background62Lease()
    @State private var checks = "running"
    @State private var ready = false
    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--background62-checks") {
            Text(checks).accessibilityIdentifier("background62-checks").task {
                let result = await host.runBackground62Checks()
                let passed = result.values.allSatisfy { $0 }
                checks = passed ? "passed \(result.count)" : "FAILED " + result.filter { !$0.value }.map(\.key).sorted().joined(separator: ",")
                let receipt: [String: Any] = ["passed": passed, "checks": result, "realModelRequests": 0, "realNetworkRequests": C8NetworkProbe.shared.count]
                try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted,.sortedKeys]).write(to: host.root.deletingLastPathComponent().appendingPathComponent("background62-checks.json"))
            }
        } else {
            VStack {
                HStack {
                    Button("第一階段完成") { Task { await host.finishFirst62() } }.accessibilityIdentifier("refresh62-first")
                    Button("第二階段完成") { if let id = host.model.records.first?.id { probe.finish(id) } }.accessibilityIdentifier("refresh62-second")
                    Button("第一階段失敗") { Task { await host.finishFirst62(fail: true) } }.accessibilityIdentifier("refresh62-fail")
                }.font(.caption)
                Text(host.model.busy ? "busy" : "idle").accessibilityIdentifier("refresh62-busy")
                Text("\(host.calls):\(probe.calls)").accessibilityIdentifier("refresh62-count")
                if ready { SingleCaptureView(model: host.model, shareProbe: host.shareProbe) }
            }.task {
                let preserve = ProcessInfo.processInfo.arguments.contains("--refresh63-preserve")
                if !preserve { try? FileManager.default.removeItem(at: host.root) }
                host.model = host.makeModel(semantic: probe, background: lease); await host.model.bootstrap()
                if !preserve && ProcessInfo.processInfo.arguments.contains("--first63-ui") {
                    _ = await host.model.startRecognition(); host.feed()
                    await host.settle { host.waiter != nil }
                } else if !preserve {
                    let id = await host.recognize45(probe)!
                    probe.finish(id); await host.model.waitForWikipediaWork()
                    if ProcessInfo.processInfo.arguments.contains("--refresh62-missing") {
                        try? FileManager.default.removeItem(at: host.root.appendingPathComponent(id.uuidString).appendingPathComponent("source.jpg"))
                        await host.model.reloadHistory()
                    }
                    if ProcessInfo.processInfo.arguments.contains("--attempt63-legacy") {
                        let attemptID = UUID()
                        _ = try? await host.model.archive.beginRetry(id: id, attemptID: attemptID)
                        _ = try? await host.model.archive.complete(id: id, result: nil, message: "合成舊紀錄", attemptID: attemptID)
                        let file = host.root.appendingPathComponent(id.uuidString).appendingPathComponent("record.json")
                        if let data = try? Data(contentsOf: file),
                           var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           var attempts = json["attempts"] as? [[String: Any]], !attempts.isEmpty {
                            attempts[attempts.count - 1].removeValue(forKey: "startedAt")
                            json["attempts"] = attempts
                            try? JSONSerialization.data(withJSONObject: json).write(to: file)
                        }
                        await host.model.reloadHistory()
                    }
                }
                UserDefaults.standard.set(true, forKey: "glance.showModelJSON")
                ready = true
            }.dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("--refresh62-large") ? .accessibility3 : .large)
        }
    }
}

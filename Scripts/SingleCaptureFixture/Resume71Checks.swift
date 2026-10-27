import SwiftUI

@MainActor
func runResume71Checks() async -> [String: Bool] {
    var checks: [String: Bool] = [:]
    func host(_ suffix: String, _ probe: Semantic45Probe) async -> C2FixtureHost {
        let h = C2FixtureHost(name: "resume71-" + suffix)
        try? FileManager.default.removeItem(at: h.root)
        h.model = h.makeModel(semantic: probe); await h.model.bootstrap(); return h
    }
    // Source collection cancelled by Settings. A manual continuation retains stage one.
    do {
        let p = Semantic45Probe(); p.holdSources = true
        let h = await host("sources", p)
        if let id = await h.recognize45(p), let base = h.model.records.first {
            await h.settle { p.sourceWait != nil }
            checks["collecting_spinner"] = h.model.cardRecognitionAction(for: base) == .working
            h.model.settingsChanged(true); p.finishSources()
            await h.settle { h.model.records.first?.semanticReview?.state == .cancelled }
            checks["settings_before_model_sends_zero"] = p.calls == 0
            h.model.settingsChanged(false)
            await h.settle { h.model.canContinueSecondStage(h.model.records.first!) }
            checks["return_does_not_auto_send"] = p.sourceCalls == 1 && p.calls == 0
            checks["cancelled_indicated"] = h.model.cardRecognitionAction(for: h.model.records.first!) == .continueSecondStage
            p.holdSources = false
            checks["manual_continue_accepted"] = h.model.continueSecondStage(id: id)
            checks["double_tap_rejected"] = !h.model.continueSecondStage(id: id) && !h.model.retryImage(id: id)
            await h.settle { p.waits[id] != nil }
            checks["only_stage_two_runs"] = h.calls == 1 && p.sourceCalls == 2 && p.calls == 1
            p.finish(id, networkFailure: true)
            await h.settle { h.model.records.first?.semanticReview?.state == .failed && !h.model.busy }
            checks["failure_restores_continue"] = h.model.cardRecognitionAction(for: h.model.records.first!) == .continueSecondStage
            checks["failure_can_continue_again"] = h.model.continueSecondStage(id: id)
            await h.settle { p.waits[id] != nil }; p.finish(id)
            await h.settle { h.model.records.first?.semanticReview?.state == .succeeded && !h.model.busy }
            let done = h.model.records.first!
            checks["success_returns_full_image"] = h.model.cardRecognitionAction(for: done) == .fullImage
            checks["stage_one_unchanged"] = done.result == base.result && done.attempts == base.attempts && done.modelResponses == base.modelResponses && done.imageSHA256 == base.imageSHA256
            checks["success_generation_three"] = done.semanticReview?.generation == 3 && h.calls == 1
            h.model.closePreview()
        } else { checks["sources_created"] = false }
    }
    // First stage finishes while Settings is open: no stage2 admission or automatic replay.
    do {
        let p = Semantic45Probe(), h = await host("first-in-settings", Semantic45Probe())
        h.model = h.makeModel(semantic: p); await h.model.bootstrap()
        _ = await h.model.startRecognition(); h.feed(); await h.settle { h.waiter != nil }
        let id = h.model.cycle.activeID
        h.model.settingsChanged(true)
        h.waiter?.resume(returning: Semantic45Probe.result); h.waiter = nil
        await h.model.waitForCurrentWork()
        if let id, let record = h.model.records.first {
            checks["first_stage_saved_in_settings"] = record.status == .succeeded && record.canContinueSemanticReview && record.semanticReview == nil
            checks["settings_no_stage_two"] = p.calls == 0 && p.sourceCalls == 0
            h.model.settingsChanged(false)
            await h.settle { h.model.canContinueSecondStage(record) }
            h.model.closePreview()
            h.model = h.makeModel(semantic: p); await h.model.bootstrap()
            checks["restart_still_incomplete_without_send"] = h.model.records.first?.canContinueSemanticReview == true && p.sourceCalls == 0
            // A disk failure before claiming must not create an unsaved phantom run.
            h.writeFault.set(true)
            checks["claim_failure_admitted_locally"] = h.model.continueSecondStage(id: id)
            await h.settle { !h.model.busy }
            checks["claim_failure_no_phantom_run"] = h.model.records.first?.semanticReview == nil && p.calls == 0
            h.writeFault.set(false)
            checks["immediate_continue_accepted"] = h.model.continueSecondStage(id: id)
            h.model.stopSemanticReview(id: id)
            await h.settle { h.model.canContinueSecondStage(h.model.records.first!) }
            checks["immediate_stop_can_retry"] = h.model.canContinueSecondStage(h.model.records.first!) && p.calls == 0
            checks["restart_continue_accepted"] = h.model.continueSecondStage(id: id)
            await h.settle { p.waits[id] != nil }; p.finish(id, noMatch: true)
            await h.settle { h.model.records.first?.semanticReview?.state == .insufficientEvidence && !h.model.busy }
            checks["completed_insufficient_not_retry"] = h.model.cardRecognitionAction(for: h.model.records.first!) == .fullImage && h.calls == 1
        } else { checks["first_in_settings_created"] = false }
        h.model.closePreview()
    }
    // A remote reply that ignores local cancellation arrives during a newer continuation.
    do {
        let p = Semantic45Probe(), h = await host("late", Semantic45Probe())
        h.model = h.makeModel(semantic: p); await h.model.bootstrap()
        if let id = await h.recognize45(p) {
            await h.settle { p.waits[id] != nil }
            let late = p.waits.removeValue(forKey: id)
            h.model.settingsChanged(true)
            await h.settle { h.model.records.first?.semanticReview?.state == .cancelled }
            h.model.settingsChanged(false)
            await h.settle { h.model.canContinueSecondStage(h.model.records.first!) }
            checks["sent_then_cancelled_can_continue"] = h.model.continueSecondStage(id: id)
            await h.settle { p.waits[id] != nil }
            let run = h.model.records.first?.semanticReview?.runID
            late?.resume(returning: String(decoding: try! JSONEncoder().encode(Semantic45Probe.answer), as: UTF8.self))
            await Task.yield()
            checks["late_reply_keeps_new_job_locked"] = h.model.busy && !h.model.continueSecondStage(id: id) && h.model.records.first?.semanticReview?.runID == run
            p.finish(id); await h.settle { h.model.records.first?.semanticReview?.state == .succeeded && !h.model.busy }
            checks["new_run_completes"] = h.model.records.first?.semanticReview?.runID == run && h.calls == 1
            // Explicit full-image action remains a genuinely new stage-one attempt.
            checks["whole_image_retry_accepted"] = h.model.retryImage(id: id)
            await h.settle { h.waiter != nil }
            checks["whole_image_new_attempt"] = h.calls == 2 && h.model.records.first?.attemptNumber == 2
            await h.complete(); await h.settle { !h.model.busy }
        } else { checks["late_created"] = false }
        h.model.closePreview()
    }
    // Revocation prevents manual continuation and late results; no account credential access.
    do {
        let p = Semantic45Probe(), h = await host("consent", Semantic45Probe())
        h.model = h.makeModel(semantic: p); await h.model.bootstrap()
        if let id = await h.recognize45(p) {
            await h.settle { p.waits[id] != nil }; h.model.withdrawDataUse(); p.finish(id)
            await h.settle { h.model.records.first?.semanticReview?.state == .cancelled }
            checks["withdrawal_blocks_continue"] = !h.model.continueSecondStage(id: id)
            checks["withdrawal_rejects_late_answer"] = h.model.records.first?.semanticReview?.source == nil
        } else { checks["consent_created"] = false }
    }
    // Account changes cancel an in-flight continuation; deleting it cannot revive it.
    do {
        let p = Semantic45Probe(), h = await host("account-delete", Semantic45Probe())
        h.model = h.makeModel(semantic: p); await h.model.bootstrap()
        if let id = await h.recognize45(p) {
            await h.settle { p.waits[id] != nil }; h.model.stopSemanticReview(id: id); p.finish(id)
            await h.settle { h.model.canContinueSecondStage(h.model.records.first!) }
            checks["account_case_continue"] = h.model.continueSecondStage(id: id)
            await h.settle { p.waits[id] != nil }
            h.model.account.selectedID = "generated-another-account"; h.model.accountStateChanged()
            p.finish(id); await h.settle { !h.model.busy && h.model.records.first?.semanticReview?.state == .cancelled }
            checks["account_change_stops_run"] = h.model.records.first?.semanticReview?.stopReason == .accountChanged && h.model.records.first?.semanticReview?.source == nil
            await h.settle { h.model.canContinueSecondStage(h.model.records.first!) }
            checks["delete_case_continue"] = h.model.continueSecondStage(id: id)
            await h.settle { p.waits[id] != nil }
            checks["clear_blocked_during_manual_continuation"] = !h.model.canClearHistory
            checks["single_delete_cancels_continuation"] = await h.model.deleteRecord(id: id)
            p.finish(id); await h.settle { !h.model.busy }
            checks["deleted_card_not_revived"] = h.model.records.isEmpty && !h.model.continueSecondStage(id: id)
            let archive = RecognitionArchive(root: h.root)
            checks["deleted_record_not_on_disk"] = (try? await archive.load().records.isEmpty) == true
        } else { checks["account_delete_created"] = false }
        h.model.closePreview()
    }
    // After stopping a manual continuation, clear/reset remains atomic against its late reply.
    do {
        let p = Semantic45Probe(), h = await host("clear-late", Semantic45Probe())
        h.model = h.makeModel(semantic: p); await h.model.bootstrap()
        if let id = await h.recognize45(p) {
            await h.settle { p.waits[id] != nil }; h.model.stopSemanticReview(id: id); p.finish(id)
            await h.settle { h.model.canContinueSecondStage(h.model.records.first!) }
            _ = h.model.continueSecondStage(id: id); await h.settle { p.waits[id] != nil }
            h.model.stopSemanticReview(id: id); await h.settle { h.model.canClearHistory }
            checks["clear_after_stop_succeeds"] = await h.model.clearHistory(confirmedIDs: [id])
            p.finish(id); await Task.yield()
            checks["clear_late_reply_does_not_revive"] = h.model.records.isEmpty
            let archive = RecognitionArchive(root: h.root)
            let fresh = try? await archive.create(id: UUID(), jpeg: Data([71]), capturedAt: Date())
            checks["clear_continuation_next_sequence_one"] = fresh?.sequence == 1 && fresh?.id != id
        } else { checks["clear_late_created"] = false }
        h.model.closePreview()
    }
    // No matching evidence is a completed decision, distinct from interruption.
    do {
        let p = Semantic45Probe(), h = await host("no-match", Semantic45Probe())
        h.model = h.makeModel(semantic: p); await h.model.bootstrap()
        if let id = await h.recognize45(p) {
            await h.settle { p.waits[id] != nil }
            let wait = p.waits.removeValue(forKey: id)
            wait?.resume(returning: String(decoding: try! JSONEncoder().encode(WikipediaReviewAnswer(decision: .no_match)), as: UTF8.self))
            await h.settle { h.model.records.first?.semanticReview?.state == .noMatch }
            checks["completed_no_match_not_retry"] = h.model.cardRecognitionAction(for: h.model.records.first!) == .fullImage && !h.model.continueSecondStage(id: id)
        } else { checks["no_match_created"] = false }
        h.model.closePreview()
    }
    return checks
}

struct Resume71ChecksView: View {
    @State private var status = "running"
    var body: some View {
        Text(status).accessibilityIdentifier("resume71-checks").task {
            let checks = await runResume71Checks()
            let passed = checks.values.allSatisfy { $0 }
            status = passed ? "passed \(checks.count)" : "FAILED " + checks.filter { !$0.value }.keys.sorted().joined(separator: ",")
            let receipt: [String: Any] = ["passed": passed, "checks": checks, "realModelRequests": 0, "networkAttempts": C8NetworkProbe.shared.count]
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("resume71-checks.json")
            try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        }
    }
}

struct Resume71UIView: View {
    @State private var host = C2FixtureHost(name: "resume71-ui")
    @State private var probe = Semantic45Probe()
    @State private var ready = false
    var body: some View {
        VStack(spacing: 4) {
            Text("模擬器示意資料・沒有真實 AI 請求").font(.caption).dynamicTypeSize(.large)
            Text("stage1=\(host.calls) stage2=\(probe.calls)").font(.caption).dynamicTypeSize(.large)
                .accessibilityIdentifier("resume71-counts")
            HStack {
                Button("合成完成") {
                    if let waiter = host.waiter {
                        host.waiter = nil; waiter.resume(returning: Semantic45Probe.result)
                    } else if let id = host.model.records.first?.id { probe.finish(id) }
                }.accessibilityIdentifier("resume71-finish")
                Button("合成失敗") { if let id = host.model.records.first?.id { probe.finish(id, networkFailure: true) } }
                    .accessibilityIdentifier("resume71-fail")
                Button("合成中斷") {
                    host.model.settingsChanged(true)
                    if let id = host.model.records.first?.id { probe.finish(id) }
                    host.model.settingsChanged(false)
                }.accessibilityIdentifier("resume71-stop")
            }.font(.caption).dynamicTypeSize(.large)
            if ready { SingleCaptureView(model: host.model, shareProbe: host.shareProbe) }
            else { ProgressView() }
        }.task {
            UserDefaults.standard.set(true, forKey: "glance.showModelJSON")
            try? FileManager.default.removeItem(at: host.root)
            host.model = host.makeModel(semantic: probe); await host.model.bootstrap()
            _ = await host.model.startRecognition(); host.feed(); await host.settle { host.waiter != nil }
            host.model.settingsChanged(true)
            host.waiter?.resume(returning: Semantic45Probe.result); host.waiter = nil
            await host.model.waitForCurrentWork()
            host.model.settingsChanged(false)
            await host.settle { host.model.records.first.map { host.model.canContinueSecondStage($0) } == true }
            if ProcessInfo.processInfo.arguments.contains("--maximum-type") { host.model.closePreview() }
            ready = true
        }
    }
}

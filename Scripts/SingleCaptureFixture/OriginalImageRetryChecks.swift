import SwiftUI
import UIKit

/// An intentionally non-cooperative transport: cancelling its Task does not settle
/// its continuation. This makes a late paid response race reproducible, offline.
@MainActor private final class OriginalImageRetryProbe {
    struct Sent { let id: UUID; let jpeg: Data }
    let root: URL
    let archive: RecognitionArchive
    var model: SingleCaptureController!
    var sent: [Sent] = []
    var returned: Set<UUID> = []
    var waiters: [UUID: CheckedContinuation<RecognitionResult, Error>] = [:]
    var cameraStarts = 0
    var permissionRequests = 0

    init(root: URL? = nil, timeout: Duration = .seconds(120)) {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("retry-fixture-" + UUID().uuidString)
        archive = RecognitionArchive(root: self.root)
        model = SingleCaptureController(consent: .fixtureAccepted(), archive: archive,
            permission: { self.permissionRequests += 1; return true },
            previewStart: { _ in self.cameraStarts += 1 }, previewStop: {}, access: { true },
            decodeBarcodes: { _ in [] }, wikipediaLookup: { _ in nil },
            provider: { jpeg, attemptID, validate in
                try validate()
                self.sent.append(.init(id: attemptID, jpeg: jpeg))
                do {
                    let result = try await withCheckedThrowingContinuation { self.waiters[attemptID] = $0 }
                    self.returned.insert(attemptID)
                    return result
                } catch {
                    self.returned.insert(attemptID); throw error
                }
            }, loadAccount: false, requestTimeout: timeout)
    }

    func seed(pending: Bool = false) async throws -> ArchivedRecognition {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 32), format: format).image { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
            UIColor.blue.setFill(); context.fill(CGRect(x: 12, y: 8, width: 13, height: 11))
        }.jpegData(compressionQuality: 0.82)!
        let id = UUID()
        let initial = try await archive.create(id: id, jpeg: image,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000), decodedBarcodes: ["verified-original-code"])
        if pending { return initial }
        return try await archive.complete(id: id, result: nil, message: "generated original failure")
    }

    func settle(_ predicate: () -> Bool) async {
        for _ in 0..<400 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func reply(_ attemptID: UUID, name: String? = nil) async {
        guard let continuation = waiters.removeValue(forKey: attemptID) else { return }
        if let name { continuation.resume(returning: .init(names: [name], barcodes: ["untrusted-guess"])) }
        else { continuation.resume(throwing: URLError(.notConnectedToInternet)) }
        await settle { self.returned.contains(attemptID) }
        for _ in 0..<8 { await Task.yield() }
    }

    var neverOpenedCamera: Bool { cameraStarts == 0 && permissionRequests == 0 && !model.previewOpen }
}

@MainActor enum OriginalImageRetryChecks {
    static func run() async -> [String: Bool] {
        var checks: [String: Bool] = [:]
        do {
            let probe = OriginalImageRetryProbe()
            let original = try await probe.seed(), image = try await probe.archive.image(for: original)
            await probe.model.reloadHistory()
            checks["history_load_does_not_retry_or_open_camera"] = probe.sent.isEmpty && probe.neverOpenedCamera
            let accepted = probe.model.retryImage(id: original.id)
            let duplicate = probe.model.retryImage(id: original.id)
            await probe.settle { probe.sent.count == 1 }
            guard let sent = probe.sent.first else { checks["first_retry_reaches_injected_transport"] = false; return checks }
            checks["double_tap_spends_only_one_request"] = accepted && !duplicate && probe.sent.count == 1 && probe.model.requestCount == 1
            checks["retry_uses_exact_archived_JPEG_and_new_attempt_ID"] = sent.jpeg == image && sent.id != original.id && probe.model.records.first?.currentAttemptID == sent.id
            checks["retry_frozen_preview_stays_with_original_record"] = probe.model.submittedPreview?.id == original.id && probe.model.submittedPreview?.jpeg == image
            checks["retry_pending_has_one_original_card"] = probe.model.records.count == 1 && probe.model.records.first?.id == original.id && probe.model.records.first?.status == .pending
            checks["retry_does_not_open_camera_or_request_permission"] = probe.neverOpenedCamera
            await probe.reply(sent.id, name: "retry success")
            await probe.settle { !probe.model.busy }
            let success = probe.model.records.first
            checks["failed_to_success_retains_original_identity_date_and_sequence"] = success?.status == .succeeded && success?.id == original.id && success?.capturedAt == original.capturedAt && success?.sequence == original.sequence
            checks["retry_success_keeps_verified_barcodes_and_source_identity"] = success?.result?.barcodes == ["verified-original-code"] && success?.result?.sourceImageID == original.id
            checks["retry_success_releases_slot_and_clears_frozen_preview"] = !probe.model.busy && probe.model.submittedPreview == nil && probe.model.completionID == original.id
            checks["successful_card_cannot_retry_or_send_again"] = !probe.model.retryImage(id: original.id) && probe.sent.count == 1
            let after = try await probe.archive.image(for: original)
            checks["retry_never_reencodes_or_overwrites_source_JPEG"] = after == image

            let failure = try await probe.seed()
            await probe.model.reloadHistory()
            _ = probe.model.retryImage(id: failure.id)
            await probe.settle { probe.sent.count == 2 }
            guard probe.sent.count == 2 else { checks["second_card_reaches_transport"] = false; return checks }
            await probe.reply(probe.sent[1].id)
            await probe.settle { !probe.model.busy }
            let repeated = probe.model.records.first(where: { $0.id == failure.id })
            checks["retry_failure_remains_retryable_without_automatic_resend"] = repeated?.status == .failed && repeated?.canRetryImage == true && repeated?.attempts?.map(\.outcome) == [.failed, .failed] && probe.sent.count == 2
            checks["retry_failure_preserves_other_completed_cards"] = probe.model.records.first(where: { $0.id == original.id }) == success

            if let selection = probe.model.beginPhotoSelection() {
                _ = probe.model.photoTransferStarted(id: selection)
                probe.model.photoPickerDismissed(id: selection)
                let beforeRetry = probe.sent.count
                checks["photo_loading_blocks_other_card_retry_without_sending"] = !probe.model.retryImage(id: failure.id) && probe.sent.count == beforeRetry && probe.model.photoLoading && probe.neverOpenedCamera
                probe.model.photoSelectionFailed(id: selection)
            } else { checks["photo_loading_blocks_other_card_retry_without_sending"] = false }

            // Short injection exercises the same production 120-second watchdog.
            // The first provider ignores cancellation and replies during attempt B.
            let timed = OriginalImageRetryProbe(timeout: .milliseconds(350))
            let timedOriginal = try await timed.seed()
            await timed.model.reloadHistory()
            _ = timed.model.retryImage(id: timedOriginal.id)
            await timed.settle { timed.sent.count == 1 }
            guard let late = timed.sent.first else { checks["timeout_request_reaches_transport"] = false; return checks }
            await timed.settle { !timed.model.busy }
            checks["watchdog_releases_cancel_ignoring_transport"] = timed.model.records.first?.status == .failed && timed.model.records.first?.attempts?.last?.outcome == .timedOut && timed.waiters[late.id] != nil
            let nextAccepted = timed.model.retryImage(id: timedOriginal.id)
            await timed.settle { timed.sent.count == 2 }
            guard timed.sent.count == 2 else { checks["timeout_allows_explicit_new_attempt"] = false; await timed.reply(late.id); return checks }
            let next = timed.sent[1]
            await timed.reply(late.id, name: "wrong late result")
            checks["late_response_cannot_finish_or_replace_new_attempt"] = nextAccepted && timed.model.busy && timed.model.records.first?.status == .pending && timed.model.records.first?.currentAttemptID == next.id && timed.model.records.first?.result == nil
            checks["late_response_cannot_clear_new_frozen_preview"] = timed.model.submittedPreview?.id == timedOriginal.id && timed.model.submittedPreview?.jpeg == next.jpeg
            await timed.reply(next.id, name: "new winner")
            await timed.settle { !timed.model.busy }
            checks["new_attempt_result_survives_old_late_response"] = timed.model.records.first?.result?.names == ["new winner"] && timed.model.records.first?.attempts?.map(\.outcome) == [.failed, .timedOut, .succeeded] && timed.model.records.count == 1
            checks["timeout_and_late_reply_never_open_camera"] = timed.neverOpenedCamera

            let oldProcess = OriginalImageRetryProbe()
            let interrupted = try await oldProcess.seed(pending: true)
            let rebooted = OriginalImageRetryProbe(root: oldProcess.root)
            await rebooted.model.reloadHistory()
            checks["restart_recovers_pending_without_camera_or_auto_replay"] = rebooted.neverOpenedCamera && rebooted.sent.isEmpty && rebooted.model.records.first?.status == .interrupted
            let rebootAccepted = rebooted.model.retryImage(id: interrupted.id)
            await rebooted.settle { rebooted.sent.count == 1 }
            guard let rebootSent = rebooted.sent.first else { checks["restart_retry_reaches_transport"] = false; return checks }
            let savedJPEG = try await oldProcess.archive.image(for: interrupted)
            checks["restart_retry_keeps_record_and_original_JPEG_without_camera"] = rebootAccepted && rebootSent.jpeg == savedJPEG && rebooted.model.records.first?.id == interrupted.id && rebooted.neverOpenedCamera
            await rebooted.reply(rebootSent.id, name: "restart success")
            await rebooted.settle { !rebooted.model.busy }
            let persisted = try await RecognitionArchive(root: oldProcess.root).load()
            checks["restart_retry_result_is_durable_on_same_card"] = persisted.records == rebooted.model.records && persisted.records.first?.status == .succeeded && persisted.records.first?.attempts?.map(\.outcome) == [.interrupted, .succeeded]
            checks["no_real_network"] = C8NetworkProbe.shared.count == 0
        } catch { checks["fixture_setup_and_storage"] = false }
        return checks
    }
}

struct OriginalImageRetryChecksView: View {
    @State private var status = "running"
    var body: some View {
        Text(status).accessibilityIdentifier("originalImageRetryResult").task {
            let checks = await OriginalImageRetryChecks.run(), passed = checks.values.allSatisfy { $0 }
            let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let report: [String: Any] = ["passed": passed, "checks": checks, "count": checks.count,
                "realNetworkRequests": C8NetworkProbe.shared.count, "cameraStarted": false,
                "timeoutInjectionMilliseconds": 350, "productionTimeoutSeconds": 120]
            try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                .write(to: root.appendingPathComponent("original-image-retry-checks.json"))
            status = passed ? "passed \(checks.count)" : "FAILED " + checks.filter { !$0.value }.map(\.key).sorted().joined(separator: ",")
        }
    }
}

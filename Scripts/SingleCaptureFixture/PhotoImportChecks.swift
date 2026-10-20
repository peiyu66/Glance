import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

private actor PhotoImportBarcodeProbe {
    private(set) var inputs: [Data] = []
    let paused: Bool
    private var continuation: CheckedContinuation<[String], Never>?
    init(paused: Bool = false) { self.paused = paused }
    func decode(_ data: Data) async -> [String] {
        inputs.append(data)
        if paused { return await withCheckedContinuation { continuation = $0 } }
        return ["verified-photo-code"]
    }
    func resume() { continuation?.resume(returning: ["verified-photo-code"]); continuation = nil }
    var waiting: Bool { continuation != nil }
}

@MainActor private final class PhotoImportProbe {
    struct Sent { let id: UUID; let jpeg: Data; let durableBeforeSend: Bool }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("photo-import-fixture-" + UUID().uuidString)
    let archive: RecognitionArchive
    let barcode: PhotoImportBarcodeProbe
    var model: SingleCaptureController!
    var sent: [Sent] = []
    var waiters: [UUID: CheckedContinuation<RecognitionResult, Error>] = [:]
    var permissionRequests = 0
    var cameraStarts = 0
    var access = true
    var now: Double = 0

    init(cameraAllowed: Bool = true, pauseBarcode: Bool = false, failStorage: Bool = false) {
        archive = RecognitionArchive(root: root, beforeWrite: { _ in
            if failStorage { throw URLError(.cannotWriteToFile) }
        })
        barcode = PhotoImportBarcodeProbe(paused: pauseBarcode)
        let barcode = barcode
        model = SingleCaptureController(consent: .fixtureAccepted(), archive: archive, clock: { self.now },
            permission: { self.permissionRequests += 1; return cameraAllowed },
            previewStart: { _ in self.cameraStarts += 1 }, previewStop: {}, access: { self.access },
            decodeBarcodes: { await barcode.decode($0) }, wikipediaLookup: { _ in nil },
            provider: { jpeg, id, validate, submitted in
                try validate()
                let row = try await self.archive.load(recoverPending: false).records.first(where: { $0.id == id })
                let saved: Data?
                if let row { saved = try await self.archive.image(for: row) } else { saved = nil }
                try validate(); try submitted()
                self.sent.append(.init(id: id, jpeg: jpeg,
                    durableBeforeSend: row?.status == .pending && row?.source == .photoLibrary && saved == jpeg))
                return try await withCheckedThrowingContinuation { self.waiters[id] = $0 }
            }, loadAccount: false)
    }
    func settle(_ predicate: () -> Bool) async {
        for _ in 0..<400 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    func select(_ data: Data) async -> Bool {
        guard let id = model.beginPhotoSelection() else { return false }
        guard model.photoTransferStarted(id: id) else { return false }
        model.photoPickerDismissed(id: id)
        return await model.prepareSelectedPhoto(data, selectionID: id)
    }
    func reply() async {
        let pending = waiters; waiters.removeAll()
        for continuation in pending.values {
            continuation.resume(returning: .init(names: ["合成相簿圖片"], barcodes: ["untrusted-model-guess"]))
        }
        await settle { !self.model.busy }
    }
    var noCamera: Bool { cameraStarts == 0 && !model.previewOpen }
}

/// Generated colored quadrants include private-looking fixture metadata, never user photos.
@MainActor private enum PhotoImportImage {
    static func source() throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1_600, height: 800), format: format).image { context in
            for (rect, color) in [(CGRect(x: 0, y: 0, width: 800, height: 400), UIColor.red),
                                  (CGRect(x: 800, y: 0, width: 800, height: 400), .green),
                                  (CGRect(x: 0, y: 400, width: 800, height: 400), .blue),
                                  (CGRect(x: 800, y: 400, width: 800, height: 400), .yellow)] {
                color.setFill(); context.fill(rect)
            }
        }
        let data = NSMutableData()
        guard let cg = image.cgImage,
              let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw SelectedPhoto.Failure.unsupportedOrTooLarge
        }
        CGImageDestinationAddImage(destination, cg, [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 25.0,
                kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 121.0,
                kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "SYNTHETIC-PRIVATE-PHOTO-METADATA",
                kCGImagePropertyExifDateTimeOriginal: "2020:01:02 03:04:05", kCGImagePropertyExifDateTimeDigitized: "2020:01:02 03:04:05"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "SYNTHETIC-PHOTO-AUTHOR",
                kCGImagePropertyTIFFMake: "SYNTHETIC-CAMERA-MAKER", kCGImagePropertyTIFFModel: "SYNTHETIC-CAMERA-MODEL",
                kCGImagePropertyTIFFDateTime: "2020:01:02 03:04:05"]
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw SelectedPhoto.Failure.unsupportedOrTooLarge }
        return data as Data
    }
    static func properties(_ data: Data) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    }
    static func cornerColors(_ data: Data) -> [String] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { pointer -> Bool in
            guard let context = CGContext(data: pointer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
        }
        guard drawn else { return [] }
        return [(width / 4, height / 4), (3 * width / 4, height / 4),
                (width / 4, 3 * height / 4), (3 * width / 4, 3 * height / 4)].map { x, y in
            let offset = (y * width + x) * 4
            let r = bytes[offset], g = bytes[offset + 1], b = bytes[offset + 2]
            if r > 170 && g < 80 && b < 80 { return "red" }
            if r < 80 && g > 170 && b < 80 { return "green" }
            if r < 80 && g < 80 && b > 170 { return "blue" }
            if r > 170 && g > 170 && b < 80 { return "yellow" }
            return "unexpected"
        }
    }
}

@MainActor enum PhotoImportChecks {
    static func run() async -> [String: Bool] {
        var checks: [String: Bool] = [:]
        var probes: [PhotoImportProbe] = []
        defer { for probe in probes { probe.model.closePreview(); try? FileManager.default.removeItem(at: probe.root) } }
        do {
            let input = try PhotoImportImage.source()
            let jpeg = try SelectedPhoto.jpeg(from: input)
            let properties = PhotoImportImage.properties(jpeg) ?? [:]
            checks["fixture_input_really_contains_orientation_and_GPS"] = PhotoImportImage.properties(input)?[kCGImagePropertyOrientation] as? Int == 6 && PhotoImportImage.properties(input)?[kCGImagePropertyGPSDictionary] != nil
            checks["portrait_orientation_is_applied_with_entire_2_to_1_aspect"] = properties[kCGImagePropertyPixelWidth] as? Int == 384 && properties[kCGImagePropertyPixelHeight] as? Int == 768 && (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1
            checks["orientation_rotates_all_four_quadrants_without_crop"] = PhotoImportImage.cornerColors(jpeg) == ["blue", "red", "yellow", "green"]
            checks["GPS_author_and_comment_metadata_are_removed"] = properties[kCGImagePropertyGPSDictionary] == nil && !String(describing: properties).contains("SYNTHETIC-") && jpeg.range(of: Data("SYNTHETIC-".utf8)) == nil
            let inputProperties = PhotoImportImage.properties(input) ?? [:]
            let inputExif = inputProperties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let inputTIFF = inputProperties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            let outputExif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let outputTIFF = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            checks["fixture_really_contains_capture_dates_and_camera_information"] = inputExif[kCGImagePropertyExifDateTimeOriginal] as? String == "2020:01:02 03:04:05" && inputTIFF[kCGImagePropertyTIFFModel] as? String == "SYNTHETIC-CAMERA-MODEL"
            checks["capture_dates_are_not_copied_to_prepared_JPEG"] = outputExif[kCGImagePropertyExifDateTimeOriginal] == nil && outputExif[kCGImagePropertyExifDateTimeDigitized] == nil && outputTIFF[kCGImagePropertyTIFFDateTime] == nil && jpeg.range(of: Data("2020:01:02 03:04:05".utf8)) == nil
            checks["camera_make_model_and_author_are_not_copied"] = outputTIFF[kCGImagePropertyTIFFMake] == nil && outputTIFF[kCGImagePropertyTIFFModel] == nil && outputTIFF[kCGImagePropertyTIFFArtist] == nil
            checks["empty_and_invalid_inputs_are_rejected"] = (try? SelectedPhoto.jpeg(from: Data())) == nil && (try? SelectedPhoto.jpeg(from: Data("not-an-image".utf8))) == nil
            checks["over_40_MiB_is_rejected"] = (try? SelectedPhoto.jpeg(from: Data(repeating: 0, count: 40 * 1_024 * 1_024 + 1))) == nil

            let probe = PhotoImportProbe(); probes.append(probe)
            await probe.model.reloadHistory()
            let cancelled = probe.model.beginPhotoSelection()!
            probe.model.photoPickerDismissed(id: cancelled)
            checks["cancel_closed_picker_does_not_create_send_or_open_camera"] = probe.model.records.isEmpty && probe.sent.isEmpty && probe.noCamera
            let selection = probe.model.beginPhotoSelection()!
            checks["opening_picker_alone_does_not_send"] = probe.model.photoSelectionActive && !probe.model.busy && probe.sent.isEmpty
            checks["picker_cannot_be_started_twice"] = probe.model.beginPhotoSelection() == nil
            checks["explicit_selection_starts_loading"] = probe.model.photoTransferStarted(id: selection)
            checks["duplicate_transfer_is_rejected"] = !probe.model.photoTransferStarted(id: selection)
            checks["iCloud_wait_has_no_card_or_request_and_blocks_actions"] = probe.model.photoLoading && probe.model.records.isEmpty && !probe.model.canChoosePhoto && !probe.model.canStartRecognition
            let prepared = await probe.model.prepareSelectedPhoto(input, selectionID: selection)
            let preview = probe.model.selectedPhoto
            checks["decoded_photo_waits_only_for_picker_dismissal"] = prepared && preview != nil && probe.sent.isEmpty && probe.model.records.isEmpty && !probe.model.busy
            probe.model.photoPickerDismissed(id: selection)
            checks["dismissal_automatically_consumes_selection"] = probe.model.busy && probe.model.selectedPhoto == nil && !probe.model.photoLoading
            probe.model.photoPickerDismissed(id: selection)
            let duplicate = await probe.model.prepareSelectedPhoto(input, selectionID: selection)
            await probe.settle { probe.sent.count == 1 }
            guard let sent = probe.sent.first, let preview else { checks["auto_send_reaches_transport"] = false; return checks }
            checks["duplicate_callbacks_create_one_request_and_card"] = !duplicate && probe.sent.count == 1 && probe.model.requestCount == 1 && probe.model.records.count == 1
            checks["archive_is_durable_before_first_send"] = sent.durableBeforeSend
            let decodedInputs = await probe.barcode.inputs
            checks["preview_barcode_archive_and_provider_share_exact_JPEG"] = preview.jpeg == sent.jpeg && decodedInputs == [sent.jpeg] && probe.model.submittedPreview?.jpeg == sent.jpeg
            checks["photo_card_uses_same_source_ID"] = probe.model.records.first?.source == .photoLibrary && probe.model.records.first?.id == preview.id && sent.id == preview.id
            checks["busy_photo_rejects_new_picker_and_camera"] = probe.model.beginPhotoSelection() == nil && !probe.model.beginAcquisition()
            probe.model.foreground(.background); probe.model.foreground(.active)
            for _ in 0..<8 { await Task.yield() }
            checks["already_sent_work_survives_background_without_reopening"] = probe.model.busy && probe.noCamera && probe.sent.count == 1
            await probe.reply()
            checks["completion_uses_verified_barcodes_and_same_source"] = probe.model.records.first?.result?.barcodes == ["verified-photo-code"] && probe.model.records.first?.result?.sourceImageID == preview.id
            checks["completion_clears_frozen_preview_without_resend"] = !probe.model.busy && probe.model.submittedPreview == nil && probe.model.selectedPhoto == nil && probe.sent.count == 1
            probe.model.foreground(.background); probe.model.foreground(.active)
            for _ in 0..<8 { await Task.yield() }
            checks["foreground_after_completion_does_not_open_camera"] = probe.noCamera && probe.permissionRequests == 0
            checks["photo_source_and_result_survive_reload"] = try await RecognitionArchive(root: probe.root).load().records == probe.model.records
            checks["next_start_opens_camera_and_arms_fresh_capture"] = await probe.model.startRecognition()
            checks["next_camera_intent_does_not_resend_photo"] = probe.model.acquiring && probe.cameraStarts == 1 && probe.sent.count == 1
            probe.model.cancelAcquisition(); probe.model.closePreview()

            let open = PhotoImportProbe(); probes.append(open); await open.model.bootstrap()
            let cancelOpen = open.model.beginPhotoSelection()!
            checks["picker_stops_previous_live_camera_and_analysis"] = !open.model.previewOpen && !open.model.capture.analysisGate.enabled
            open.model.photoPickerDismissed(id: cancelOpen)
            await open.settle { open.cameraStarts == 2 }
            checks["cancel_restores_expanded_preview_without_arming"] = open.model.previewOpen && !open.model.previewCollapsed && !open.model.acquiring && open.sent.isEmpty
            open.model.historyDragBegan()
            let cancelCollapsed = open.model.beginPhotoSelection()!; open.model.photoPickerDismissed(id: cancelCollapsed)
            for _ in 0..<8 { await Task.yield() }
            checks["cancel_preserves_collapsed_camera_and_reading_intent"] = open.model.previewCollapsed && !open.model.previewOpen && open.model.readingHistory && open.cameraStarts == 2
            _ = await open.select(input); await open.settle { open.sent.count == 1 }
            checks["selected_photo_auto_sends_while_preserving_collapse"] = open.model.previewCollapsed && !open.model.previewOpen && open.sent.count == 1
            await open.reply()
            checks["collapsed_photo_completion_stays_collapsed"] = open.model.previewCollapsed && !open.model.previewOpen
            _ = await open.model.startRecognition(); open.model.cancelAcquisition(); open.now = 301; open.model.checkPreviewDeadline()
            let expiredPicker = open.model.beginPhotoSelection()!; open.model.photoPickerDismissed(id: expiredPicker)
            for _ in 0..<8 { await Task.yield() }
            checks["cancel_does_not_reopen_expired_camera"] = open.model.expired && !open.model.previewOpen && !open.model.acquiring

            let denied = PhotoImportProbe(cameraAllowed: false); probes.append(denied); await denied.model.bootstrap()
            _ = await denied.select(input); await denied.settle { denied.sent.count == 1 }; await denied.reply()
            checks["camera_denial_does_not_block_photo_or_request_more_permission"] = denied.model.permissionDenied && denied.sent.count == 1 && denied.permissionRequests == 1 && denied.noCamera

            let raced = PhotoImportProbe(); probes.append(raced); await raced.model.reloadHistory()
            let oldID = raced.model.beginPhotoSelection()!; raced.model.photoPickerDismissed(id: oldID)
            let newID = raced.model.beginPhotoSelection()!; _ = raced.model.photoTransferStarted(id: newID)
            raced.model.photoPickerDismissed(id: oldID)
            let stale = await raced.model.prepareSelectedPhoto(input, selectionID: oldID)
            checks["stale_dismissal_and_data_cannot_consume_new_selection"] = !stale && raced.model.photoSelectionActive && raced.model.photoLoading && raced.sent.isEmpty
            raced.model.photoPickerDismissed(id: newID)
            raced.model.foreground(.background); raced.model.foreground(.active)
            let late = await raced.model.prepareSelectedPhoto(input, selectionID: newID)
            checks["background_invalidates_load_even_after_foreground_returns"] = !late && !raced.model.photoLoading && raced.model.selectedPhoto == nil && raced.sent.isEmpty
            checks["background_load_leaves_reselection_message"] = raced.model.photoMessage == "相片載入已中止，請重新選擇。"
            let settingsID = raced.model.beginPhotoSelection()!; _ = raced.model.photoTransferStarted(id: settingsID)
            raced.model.photoPickerDismissed(id: settingsID); raced.model.settingsChanged(true); raced.model.settingsChanged(false)
            let settingsLate = await raced.model.prepareSelectedPhoto(input, selectionID: settingsID)
            checks["settings_invalidates_load_without_late_send"] = !settingsLate && raced.sent.isEmpty && raced.noCamera

            let pending = PhotoImportProbe(pauseBarcode: true); probes.append(pending); await pending.model.reloadHistory()
            _ = await pending.select(input)
            for _ in 0..<400 { if await pending.barcode.waiting { break }; try? await Task.sleep(for: .milliseconds(5)) }
            checks["preflight_race_reaches_barcode_before_transport"] = await pending.barcode.waiting
            pending.model.foreground(.background); pending.model.foreground(.active); await pending.barcode.resume()
            await pending.settle { !pending.waiters.isEmpty }; await pending.reply()
            checks["background_round_trip_preserves_reserved_photo_pipeline"] = pending.sent.count == 1 && pending.model.requestCount == 1 && pending.model.records.first?.status == .succeeded && pending.model.records.first?.source == .photoLibrary

            let invalid = PhotoImportProbe(); probes.append(invalid); await invalid.model.reloadHistory()
            let invalidAccepted = await invalid.select(Data("generated invalid image".utf8))
            checks["invalid_data_leaves_no_pending_photo_or_card"] = !invalidAccepted && invalid.model.selectedPhoto == nil && !invalid.model.photoLoading && invalid.sent.isEmpty && invalid.model.records.isEmpty
            let failedID = invalid.model.beginPhotoSelection()!; _ = invalid.model.photoTransferStarted(id: failedID)
            invalid.model.photoPickerDismissed(id: failedID); invalid.model.photoSelectionFailed(id: failedID)
            checks["download_failure_shows_reselection_without_send"] = invalid.model.photoMessage == "無法讀取這張相片，請重新選擇。" && invalid.sent.isEmpty && invalid.noCamera
            let lateAfterFailure = await invalid.model.prepareSelectedPhoto(input, selectionID: failedID)
            checks["late_success_after_download_failure_is_rejected"] = !lateAfterFailure && invalid.sent.isEmpty
            _ = await invalid.select(input); await invalid.settle { invalid.sent.count == 1 }; await invalid.reply()
            checks["fresh_selection_after_failure_sends_once"] = invalid.sent.count == 1 && invalid.model.records.count == 1

            let fullDisk = PhotoImportProbe(failStorage: true); probes.append(fullDisk); await fullDisk.model.reloadHistory()
            _ = await fullDisk.select(input); await fullDisk.settle { !fullDisk.model.busy }
            checks["archive_failure_blocks_send_and_discards_auto_intent"] = fullDisk.sent.isEmpty && fullDisk.model.requestCount == 0 && fullDisk.model.storageError != nil && fullDisk.model.selectedPhoto == nil && fullDisk.model.submittedPreview == nil && fullDisk.model.records.isEmpty
            await fullDisk.model.retrySaving()
            checks["storage_retry_does_not_replay_unsaved_photo"] = fullDisk.sent.isEmpty && !fullDisk.model.busy

            let noAccess = PhotoImportProbe(); probes.append(noAccess); await noAccess.model.reloadHistory(); noAccess.access = false
            _ = await noAccess.select(input)
            checks["missing_access_blocks_picker_without_partial_card"] = noAccess.sent.isEmpty && noAccess.model.records.isEmpty && !noAccess.model.photoLoading && noAccess.model.selectedPhoto == nil && !noAccess.model.canChoosePhoto
            noAccess.access = true
            for _ in 0..<8 { await Task.yield() }
            checks["later_login_does_not_resend_old_selection"] = noAccess.sent.isEmpty && noAccess.model.records.isEmpty
            _ = await noAccess.select(input); await noAccess.settle { noAccess.sent.count == 1 }; await noAccess.reply()
            checks["new_selection_after_access_restored_sends_once"] = noAccess.sent.count == 1

            let lostAccess = PhotoImportProbe(pauseBarcode: true); probes.append(lostAccess); await lostAccess.model.reloadHistory()
            _ = await lostAccess.select(input)
            for _ in 0..<400 { if await lostAccess.barcode.waiting { break }; try? await Task.sleep(for: .milliseconds(5)) }
            lostAccess.access = false; await lostAccess.barcode.resume(); await lostAccess.settle { !lostAccess.model.busy }
            checks["access_lost_before_transport_blocks_send_and_preserves_retryable_card"] = lostAccess.sent.isEmpty && lostAccess.model.records.first?.status == .failed && lostAccess.model.records.first?.canRetryImage == true
            checks["no_real_network"] = C8NetworkProbe.shared.count == 0
        } catch { checks["fixture_generation_or_storage"] = false }
        return checks
    }
}

struct PhotoImportChecksView: View {
    @State private var status = "running"
    var body: some View {
        Text(status).accessibilityIdentifier("photoImportResult").task {
            let checks = await PhotoImportChecks.run(), passed = checks.values.allSatisfy { $0 }
            let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let report: [String: Any] = ["passed": passed, "checks": checks, "count": checks.count,
                "realNetworkRequests": C8NetworkProbe.shared.count, "syntheticImagesOnly": true,
                "physicalCameraStarted": false, "systemPhotoLibraryOpened": false]
            try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                .write(to: root.appendingPathComponent("photo-import-checks.json"))
            status = passed ? "passed \(checks.count)" : "FAILED " + checks.filter { !$0.value }.map(\.key).sorted().joined(separator: ",")
        }
    }
}

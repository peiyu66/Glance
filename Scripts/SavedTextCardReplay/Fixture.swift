import SwiftUI
import UIKit
import UniformTypeIdentifiers

// ReplaySamples is generated locally from the approved saved input and response files.
// No sample image, account, or network access is involved.
struct SavedCardSample: @unchecked Sendable {
    let sequence: Int
    let rawFirst: String
    let rawSecond: String
    let result: RecognitionResult
    let sources: [WikipediaReviewSource]
    let answer: WikipediaReviewAnswer
    init(_ sequence: Int) throws {
        self.sequence = sequence
        let value = ReplaySamples.values[sequence]!
        let payload = try JSONSerialization.jsonObject(with: Data(base64Encoded: value[0])!) as! [String: Any]
        rawFirst = payload["raw_stage_one_json"] as! String
        rawSecond = String(decoding: Data(base64Encoded: value[1])!, as: UTF8.self)
        var stage = payload["stage_one"] as! [String: Any]
        // Explicit adapter: historical P18 content in the current v17 presentation contract.
        // The original v16 JSON remains byte-for-byte intact in the first-stage viewer.
        stage["schema_version"] = 17
        result = try CameraAnswer.parse(String(decoding: JSONSerialization.data(withJSONObject: stage), as: UTF8.self), expectingStructured: true)
        sources = try (payload["sources"] as! [[String: Any]]).map { s in
            let snippets = s["excerpts"] as! [[String: String]]
            return WikipediaReviewSource(pageID: Int((s["source_id"] as! String).split(separator: ":").last!)!, title: s["title"] as! String,
                url: URL(string: s["url"] as! String)!, fetchedAt: Date(), excerpts: snippets.map { .init(id: $0["excerpt_id"]!, text: $0["text"]!) })
        }
        answer = try WikipediaSemanticReview.parse(rawSecond, sources: sources)
    }
}

@MainActor @Observable final class SavedCardReplayHost {
    let sample: SavedCardSample
    let root: URL
    let jpeg = C2FixtureHost.jpeg(.systemTeal)
    let probe = SummaryCardProbe()
    var model: SingleCaptureController!
    var continuation: CheckedContinuation<String, Error>?
    var initial: ArchivedRecognition?
    var status = "loading"
    var shareStatus = "idle"
    var openedURL = "none"
    var checks: [String: Bool] = [:]
    var semanticCalls = 0
    var sourceCalls = 0
    var shareCount = 0
    var jsonShareCount = 0
    var copyCount = 0
    private var expectedCopy: String?
    private var currentShareName = ""

    init() {
        let flag = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--saved-card=") }!
        sample = try! SavedCardSample(Int(flag.split(separator: "=").last!)!)
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("saved-card-\(sample.sequence)")
        let sources = sample.sources
        model = SingleCaptureController(consent: .fixtureAccepted(), archive: RecognitionArchive(root: root),
            permission: { true }, previewStart: { _ in }, previewStop: {}, access: { true },
            scanBarcodes: { _ in .init(values: []) }, wikipediaLookup: { _ in preconditionFailure("Legacy network forbidden") },
            wikipediaReferencesLookup: { _ in preconditionFailure("Legacy enrichment forbidden") },
            semanticReviewEnabled: true,
            semanticSources: { [weak self] _ in await MainActor.run { self?.sourceCalls += 1 }; return sources },
            semanticProvider: { [weak self] result, raw, received, validate in
                guard let self else { throw CancellationError() }; try validate()
                self.semanticCalls += 1
                self.checks["source_provider_received_exact_raw_first"] = raw == self.sample.rawFirst
                self.checks["source_provider_received_same_names_OCR_entities"] = result.names == self.sample.result.names && result.text == self.sample.result.text && result.searchEntities == self.sample.result.searchEntities
                self.checks["source_provider_received_exact_candidates"] = received == self.sample.sources
                return try await withCheckedThrowingContinuation { self.continuation = $0 }
            }, loadAccount: false)
        configureShare()
    }
    func saveEvidence() {
        let record = model.records.first
        let value: [String: Any] = ["sequence": sample.sequence, "checks": checks, "passed": !checks.isEmpty && checks.values.allSatisfy { $0 },
            "status": status, "shareCount": shareCount, "jsonShareCount": jsonShareCount, "copyCount": copyCount,
            "semanticProviderCalls": semanticCalls, "sourceProviderCalls": sourceCalls, "recordID": record?.id.uuidString ?? "",
            "attemptID": record?.currentAttemptID.uuidString ?? "", "originalRecordID": initial?.id.uuidString ?? "",
            "originalImageSHA256": initial?.imageSHA256 ?? "", "currentImageSHA256": record?.imageSHA256 ?? "",
            "realNetworkRequests": C8NetworkProbe.shared.count, "realModelRequests": 0, "realCameraStarts": 0,
            "firstStageAdapter": "historical P18 fields in v17 presentation contract; exact v16 raw retained", "sourceImage": "generated teal placeholder; no sample image read"]
        let path = root.deletingLastPathComponent().appendingPathComponent("saved-card-\(sample.sequence)-checks.json")
        try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: path)
    }
    func prepare() async {
        UserDefaults.standard.set(false, forKey: "glance.showModelJSON")
        try? FileManager.default.removeItem(at: root)
        await model.bootstrap(); status = "ready"
    }
    func begin() async {
        do {
            try await model.seedSavedStageOneForReplay(result: sample.result, raw: sample.rawFirst, jpeg: jpeg)
            for _ in 0..<300 where continuation == nil { try? await Task.sleep(for: .milliseconds(10)) }
            guard let record = model.records.first else { throw CocoaError(.fileReadCorruptFile) }
            initial = record
            checks["first_stage_visible_before_second"] = record.status == .succeeded && record.presentationResult?.summary == sample.result.summary && record.currentSemanticReview?.source == nil && continuation != nil
            checks["first_stage_exact_raw_saved"] = record.modelJSONDocument.rawText == sample.rawFirst
            checks["first_stage_share_has_no_Wiki"] = record.shareDocument().links.allSatisfy { $0.url.host != "zh.wikipedia.org" }
            status = "first-ready"; saveEvidence()
        } catch { status = "FAILED-first-\(error)"; saveEvidence() }
    }
    func finish() async {
        guard let wait = continuation else { status = "FAILED-no-wait"; return }; continuation = nil
        wait.resume(returning: sample.rawSecond)
        await model.waitForWikipediaWork()
        guard let before = initial, let record = model.records.first else { status = "FAILED-no-record"; return }
        checks["same_record_attempt_image_date_and_single_card"] = model.records.count == 1 && record.id == before.id && record.currentAttemptID == before.currentAttemptID && record.imageSHA256 == before.imageSHA256 && record.capturedAt == before.capturedAt
        checks["original_result_unchanged"] = record.result == before.result
        checks["updated_summary_exact"] = record.presentationResult?.summary == sample.answer.summary
        checks["names_OCR_aliases_unchanged"] = record.presentationResult?.names == before.result?.names && record.presentationResult?.text == before.result?.text && record.presentationResult?.searchEntities == before.result?.searchEntities
        checks["second_raw_exact_and_bound"] = record.semanticJSONDocument?.rawText == sample.rawSecond && record.currentSemanticReview?.modelResponse?.sourceImageID == before.id && record.currentSemanticReview?.modelResponse?.attemptID == before.currentAttemptID
        checks["first_raw_exact_after_enrichment"] = record.modelJSONDocument.rawText == sample.rawFirst
        checks["selected_source_url_pageID_and_title"] = record.currentSemanticReview?.source?.id == sample.answer.sourceID && record.currentSemanticReview?.source == sample.sources.first { $0.id == sample.answer.sourceID }
        checks["Google_refined_query"] = record.googleSearch?.query == sample.answer.searchName
        checks["share_has_updated_summary_and_all_OCR"] = record.shareText().contains(sample.answer.summary) && sample.result.text.allSatisfy { record.shareText().contains($0) }
        checks["share_source_link_same_as_card"] = record.shareDocument().links.last?.url == record.currentSemanticReview?.source?.url && record.shareDocument().links.count == 2
        checks["legacy_veto_path_unused"] = record.wikipedia == nil && model.wikipediaDiagnostics.isEmpty
        let reopened = try? await RecognitionArchive(root: root).load().records.first
        checks["disk_readback_preserves_both_JSON_and_source"] = reopened == record
        await model.reloadHistory(); model.foreground(.active); await Task.yield()
        checks["reload_does_not_replay_or_duplicate"] = model.records.count == 1 && semanticCalls == 1 && sourceCalls == 1 && model.records.first?.id == before.id
        checks["zero_real_network_and_camera"] = C8NetworkProbe.shared.count == 0 && !model.capture.session.isRunning
        status = checks.values.allSatisfy { $0 } ? "second-ready" : "FAILED-" + checks.filter { !$0.value }.map(\.key).joined(separator: ",")
        saveEvidence()
    }
    func open(_ url: URL) -> OpenURLAction.Result {
        openedURL = url.absoluteString
        let record = model.records.first!
        checks["tapped_" + (url.host == "zh.wikipedia.org" ? "Wiki" : "Google") + "_URL_matches"] = record.shareDocument().links.contains { $0.url == url }
        saveEvidence(); return .handled
    }
    private func configureShare() {
        probe.itemsPresented = { [weak self] items, copyItems in
            guard let self, let record = self.model.records.first else { return }
            let stage = record.currentSemanticReview?.source == nil ? "first" : "second"
            var valid = false
            if items.count == 1, let raw = items.first as? String {
                let isFirst = raw == self.sample.rawFirst
                self.currentShareName = isFirst ? "json-first" : "json-second"
                self.expectedCopy = raw
                valid = (isFirst || raw == self.sample.rawSecond) && copyItems.count == 1 && Set(copyItems[0].keys) == [UTType.utf8PlainText.identifier] && copyItems[0][UTType.utf8PlainText.identifier] as? String == raw
                self.jsonShareCount += 1
            } else {
                self.currentShareName = "card-" + stage
                self.expectedCopy = nil
                let doc = record.shareDocument()
                valid = items.count == 2 && (items.first as? UIImage)?.pngData() == UIImage(data: self.jpeg)?.pngData() && items.last as? String == doc.plainText && copyItems.count == 2 && copyItems.first?[UTType.jpeg.identifier] as? Data == self.jpeg && copyItems.last?[UTType.utf8PlainText.identifier] as? String == doc.plainText
                if let rtf = copyItems.last?[UTType.rtf.identifier] as? Data,
                   let attributed = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
                    var urls: [URL] = []
                    attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
                        if let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)) { urls.append(url) }
                    }
                    valid = valid && urls == doc.links.map(\.url)
                } else { valid = false }
                self.shareCount += 1
            }
            self.checks[self.currentShareName + "_actual_share_items_exact"] = valid
            self.shareStatus = valid ? "items-" + self.currentShareName : "FAILED-share"
            self.saveEvidence()
        }
        probe.activityCompleted = { [weak self] type, completed in
            guard let self, completed, type == UIActivity.ActivityType.copyToPasteboard.rawValue else { return }
            // Only read the fixture's own just-completed Copy, never preexisting clipboard contents.
            let items = UIPasteboard.general.items
            func text(_ value: Any?) -> String? { (value as? String) ?? (value as? Data).flatMap { String(data: $0, encoding: .utf8) } }
            let valid: Bool
            if let expected = self.expectedCopy { valid = items.count == 1 && text(items.first?[UTType.utf8PlainText.identifier]) == expected }
            else { valid = items.count == 2 && text(items.last?[UTType.utf8PlainText.identifier]) == self.model.records.first?.shareText() }
            self.checks[self.currentShareName + "_system_copy_exact"] = valid
            self.copyCount += 1; self.shareStatus = valid ? "copied-" + self.currentShareName : "FAILED-copy"; self.saveEvidence()
        }
    }
}

struct SavedCardReplayView: View {
    @State private var host = SavedCardReplayHost()
    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Button("回放第一階段") { Task { await host.begin() } }.accessibilityIdentifier("replay-start")
                Button("補上第二階段") { Task { await host.finish() } }.accessibilityIdentifier("replay-finish")
            }.font(.caption)
            Text(host.status).font(.caption2).accessibilityIdentifier("replay-status")
            Text(host.shareStatus).font(.caption2).accessibilityIdentifier("replay-share")
            Text(host.openedURL).lineLimit(1).font(.caption2).accessibilityIdentifier("replay-url")
            SingleCaptureView(model: host.model, shareProbe: host.probe, motionAllowed: false)
                .environment(\.openURL, OpenURLAction { host.open($0) })
        }.task { await host.prepare() }
    }
}

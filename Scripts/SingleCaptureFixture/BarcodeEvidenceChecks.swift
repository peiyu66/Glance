import SwiftUI
import CoreImage

private final class BarcodeEvidenceWire: @unchecked Sendable {
    static let shared = BarcodeEvidenceWire()
    private let lock = NSLock()
    private var bodies: [Data] = []
    private var fail = true
    private var answerOverride: String?
    func overrideAnswer(_ answer: String) { lock.lock(); answerOverride = answer; fail = false; lock.unlock() }
    func answer(or fallback: String) -> String { lock.lock(); defer { lock.unlock() }; return answerOverride ?? fallback }
    func receive(_ body: Data) -> Bool { lock.lock(); defer { lock.unlock() }; bodies.append(body); return fail }
    func succeed() { lock.lock(); fail = false; lock.unlock() }
    func snapshot() -> [Data] { lock.lock(); defer { lock.unlock() }; return bodies }
}

/// Selected only in this generated fixture. Every URL is intercepted; no network fallback.
final class BarcodeEvidenceProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.path == "/v1/responses" else {
            C8NetworkProbe.shared.record(); client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }; body.append(contentsOf: bytes.prefix(count))
            }
        }
        let fail = BarcodeEvidenceWire.shared.receive(body)
        let defaultAnswer = #"{"schema_version":10,"names":["胃藥錠劑"],"summary":"合成回應，僅驗證資料流。","text":["PHAZIN-P Enteric S.C.TABLETS"],"barcodes":["MODEL-GUESS-MUST-NOT-REPLACE-LOCAL"],"search_identity":null,"search_block_reason":null}"#
        let answer = BarcodeEvidenceWire.shared.answer(or: defaultAnswer)
        let delta = try! JSONSerialization.data(withJSONObject: ["type": "response.output_text.delta", "delta": answer])
        let text = fail ? #"{"error":{"code":"rate_limit_exceeded"}}"# : "data: " + String(decoding: delta, as: UTF8.self) + "\n\ndata: {\"type\":\"response.completed\"}\n\n"
        let response = HTTPURLResponse(url: request.url!, statusCode: fail ? 429 : 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": fail ? "application/json" : "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor private enum BarcodeEvidenceChecks {
    static func run() async throws -> [String: Bool] {
        let payload = "品名：腹釋寧消化\n品牌：合成廠牌\n型號：AB-01\n諮詢電話：0800-388-100"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("barcode-evidence-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let tokens = SIWCTokens(access: "generated-access", refresh: nil, idToken: "generated-id", scope: SIWCProtocol.scopes, expiresAt: Date().addingTimeInterval(3600))
        let account = SIWCAccount(clientID: "generated-client", subject: "generated-subject", tokens: tokens)
        let saved = SIWCSaved(hostID: "generated-host", accounts: [account], selected: account.id)
        let controller = SIWCController(allowsDataTransfer: { true }, authSaveSession: { _ in preconditionFailure("No account writes") }, authLoadSession: { saved })
        controller.load()
        controller.catalog = [.init(slug: "gpt-6-luna", display_name: "Generated", visibility: "list")]
        var cameraCalls = 0
        let model = SingleCaptureController(consent: .fixtureAccepted(), account: controller, archive: RecognitionArchive(root: root),
            permission: { cameraCalls += 1; return false }, previewStart: { _ in cameraCalls += 1 }, previewStop: {},
            wikipediaLookup: { _ in preconditionFailure("Wikipedia forbidden in this fixture") }, wikipediaReferencesLookup: { _ in .init() }, loadAccount: false)
        await model.reloadHistory()
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let qr = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let cg = CIContext().createCGImage(qr, from: qr.extent)!
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 768, height: 768), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 768, height: 768))
            context.cgContext.interpolationQuality = .none
            UIImage(cgImage: cg).draw(in: CGRect(x: 80, y: 80, width: 608, height: 608))
        }
        var checks: [String: Bool] = [:]
        let selection = model.beginPhotoSelection()!
        checks["photo_transfer_started"] = model.photoTransferStarted(id: selection)
        checks["photo_prepared"] = await model.prepareSelectedPhoto(image.jpegData(compressionQuality: 0.98)!, selectionID: selection)
        let expectedImage = model.selectedPhoto!.jpeg
        checks["no_request_before_picker_dismissal"] = BarcodeEvidenceWire.shared.snapshot().isEmpty
        model.photoPickerDismissed(id: selection)
        checks["photo_auto_request_started"] = model.busy
        func settle() async { for _ in 0..<500 { if !model.busy { return }; try? await Task.sleep(for: .milliseconds(20)) } }
        await settle()
        let first = model.records.first!
        checks["failed_attempt_preserves_locally_decoded_full_QR"] = first.status == .failed && first.decodedBarcodes == [payload]
        checks["QR_symbology_and_exclusion_saved_before_AI"] = first.barcodeDiagnostics?.observations.contains { $0.value == payload && $0.symbology == "qr" && $0.decision == .unsupportedSymbology } == true
        checks["same_image_targeted_EAN_pass_recorded"] = first.barcodeDiagnostics?.attempts.contains { $0.pass == .targetedEAN && $0.observationCount != nil } == true
        checks["AI_failure_already_has_safe_QR_manual_search"] = first.result == nil && first.googleSearch?.query == "腹釋寧消化" && first.shareDocument().links.first?.url == first.googleSearch?.googleURL
        checks["one_request_no_automatic_retry"] = BarcodeEvidenceWire.shared.snapshot().count == 1
        BarcodeEvidenceWire.shared.succeed()
        checks["explicit_retry_started"] = model.retryImage(id: first.id)
        await settle()
        let row = model.records.first!
        checks["retry_success_keeps_same_card_and_image"] = row.status == .succeeded && row.id == first.id && row.imageSHA256 == first.imageSHA256 && row.attemptNumber == 2
        checks["actual_SIWC_parser_and_local_barcode_replacement"] = row.result?.names == ["胃藥錠劑"] && row.result?.barcodes == [payload] && row.result?.text == ["PHAZIN-P Enteric S.C.TABLETS"]
        checks["search_null_uses_QR_without_rewriting_model_answer"] = row.result?.searchQuery == nil && row.result?.searchRestriction == nil && row.googleSearch?.query == "腹釋寧消化"
        let trace = row.modelResponses?.last
        checks["preparse_raw_response_saved_once_on_success"] = trace?.rawResponse?.contains("MODEL-GUESS-MUST-NOT-REPLACE-LOCAL") == true && row.modelResponses?.count == 1
        checks["raw_response_bound_to_actual_attempt_and_fixture_version"] = trace?.attemptID == row.currentAttemptID && trace?.sourceImageID == row.id && trace?.appBuild == "321" && trace?.promptRevision == CameraAnswer.promptRevision
        checks["raw_response_not_shared"] = !row.shareText().contains("MODEL-GUESS-MUST-NOT-REPLACE-LOCAL")
        let requests = BarcodeEvidenceWire.shared.snapshot()
        checks["exactly_two_intercepted_requests"] = requests.count == 2
        for (index, body) in requests.enumerated() {
            let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            let input = object["input"] as! [[String: Any]]
            let content = input[0]["content"] as! [[String: String]]
            let metadata = content.filter { $0["type"] == "input_text" }.dropFirst()
            let field = metadata.first?["text"] ?? ""
            let decoded = try JSONSerialization.jsonObject(with: Data(field.utf8)) as! [String: [String: String]]
            let format = (object["text"] as? [String: Any])?["format"] as? [String: Any]
            let properties = (format?["schema"] as? [String: Any])?["properties"] as? [String: [String: Any]]
            checks["request_\(index)_P19_entity_contract"] = content.first?["text"] == CameraAnswer.prompt && properties?["schema_version"]?["enum"] as? [Int] == [17] && properties?["search_entities"] != nil
            checks["request_\(index)_only_explicit_name_no_phone_or_full_QR"] = (object["text"] as? [String: Any])?["format"] != nil && metadata.count == 1 && decoded == ["untrusted_qr_fields": ["product": "腹釋寧消化", "brand": "合成廠牌", "model": "AB-01"]] && !field.contains("0800")
            checks["request_\(index)_same_saved_image_and_no_tools"] = content.filter { $0["type"] == "input_image" }.map { $0["image_url"] } == ["data:image/jpeg;base64," + expectedImage.base64EncodedString()] && object["tools"] == nil
        }
        let reopened = try await RecognitionArchive(root: root).load().records.first!
        checks["reopened_keeps_exact_raw_response"] = reopened.modelResponses == row.modelResponses
        checks["retry_and_reopen_preserve_diagnostics"] = reopened.barcodeDiagnostics == first.barcodeDiagnostics && row.barcodeDiagnostics == first.barcodeDiagnostics
        checks["reopened_share_uses_same_Google_URL_and_verbatim_QR"] = reopened.shareDocument().links.first?.url == reopened.googleSearch?.googleURL && reopened.googleSearch?.query == "腹釋寧消化" && reopened.shareText().contains(payload)
        // Exercise the actual SIWC parser failure and v15 recovery path with synthetic wire data.
        let malformed = "{invalid synthetic parser response}"
        BarcodeEvidenceWire.shared.overrideAnswer(malformed)
        let newSelection = model.beginPhotoSelection()!
        _ = model.photoTransferStarted(id: newSelection)
        _ = await model.prepareSelectedPhoto(expectedImage, selectionID: newSelection)
        model.photoPickerDismissed(id: newSelection); await settle()
        let failedParse = model.records.first!
        checks["actual_parser_failure_keeps_exact_preparse_response"] = failedParse.status == .failed && failedParse.modelResponses?.last?.rawResponse == malformed && failedParse.result == nil
        checks["parser_failure_response_has_current_attempt_binding"] = failedParse.modelResponses?.last?.attemptID == failedParse.currentAttemptID && failedParse.modelResponses?.last?.sourceImageID == failedParse.id
        checks["parser_failure_raw_value_never_shared"] = !failedParse.shareText().contains(malformed)
        let wire15 = #"{"schema_version":15,"names":["合成飲品"],"summary":"合成傳輸測試","text":["AURORA\nDRINK"],"search_entities":[{"id":0,"role":"central","kind":"product","name":"曙光飲品","aliases":["曙光飲品","Aurora Drink"],"status":"ready","basis":"text","source_role":"product_label","source_text":"AURORA DRINK","context_text":[],"relation":"none","related_to":-1}]}"#
        BarcodeEvidenceWire.shared.overrideAnswer(wire15)
        checks["parser_failure_manual_retry_starts"] = model.retryImage(id: failedParse.id)
        await settle()
        let recovered = model.records.first!
        checks["v15_wire_parser_accepts_cross_language_linebreaks_and_duplicate_alias"] = recovered.status == .succeeded && recovered.result?.searchContractVersion == 15 && recovered.result?.searchEntities?.first?.aliases == ["Aurora Drink"] && recovered.result?.text == ["AURORA\nDRINK"]
        checks["v15_wire_raw_and_prior_failure_kept_in_order"] = recovered.modelResponses?.map(\.rawResponse) == [malformed, wire15] && recovered.modelResponses?.map(\.attemptID) == [failedParse.currentAttemptID, recovered.currentAttemptID]
        let recoveredReadback = try await RecognitionArchive(root: root).load().records.first!
        checks["v15_wire_saved_query_matches_share_after_readback"] = recoveredReadback.googleSearch?.query == "曙光飲品 Aurora Drink" && recoveredReadback.shareDocument().links.first?.url == recoveredReadback.googleSearch?.googleURL && recoveredReadback.modelResponses == recovered.modelResponses
        checks["all_requests_intercepted_without_extra_automatic_retry"] = BarcodeEvidenceWire.shared.snapshot().count == 4
        checks["no_camera_or_unexpected_transport"] = cameraCalls == 0 && C8NetworkProbe.shared.count == 0
        return checks
    }
}

struct BarcodeEvidenceChecksView: View {
    @State private var status = "running"
    var body: some View {
        Text(status).accessibilityIdentifier("barcode-evidence-result").task {
            do {
                let checks = try await BarcodeEvidenceChecks.run()
                let passed = checks.values.allSatisfy { $0 }
                let report: [String: Any] = ["passed": passed, "checks": checks, "count": checks.count, "realNetworkRequests": 0, "realCameraRequests": 0, "keychainAccess": false, "modelQualityVerified": false]
                let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: root.appendingPathComponent("barcode-evidence-checks.json"))
                status = passed ? "passed \(checks.count)" : "FAILED " + checks.filter { !$0.value }.map(\.key).joined(separator: ",")
            } catch { status = "FAILED fixture execution" }
        }
    }
}

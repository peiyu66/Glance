import Foundation
import UIKit
import UniformTypeIdentifiers

/// Synthetic source only. Inspect the exact standard objects passed to the system sheet and its frozen Copy snapshot.
@MainActor enum C9RichShareChecks {
    static var copyMode: String {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--markdown-punctuation") { return "markdown-punctuation" }
        if args.contains("--legacy-rich-card") { return "markdown-legacy" }
        if args.contains("--fallback-links") { return "markdown-fallback" }
        return args.contains("--explicit-copy-prototype") ? "prototype" : args.contains("--legacy-copy-transport") ? "pre9" : "production-markdown"
    }
    /// Test-only candidate: preserve the two items and explicitly retain both
    /// named rich links and the existing complete plain-text fallback.
    static func explicitCopyPrototype(record: ArchivedRecognition, jpeg: Data) throws {
        let document = record.shareDocument()
        let rich = NSMutableAttributedString(string: document.body)
        for link in document.links {
            if rich.length > 0 { rich.append(NSAttributedString(string: "\n\n")) }
            rich.append(NSAttributedString(string: link.label, attributes: [.link: link.url]))
        }
        let rtf = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        UIPasteboard.general.items = [[UTType.jpeg.identifier: jpeg],
            [UTType.rtf.identifier: rtf, UTType.html.identifier: Data(document.html.utf8),
             UTType.utf8PlainText.identifier: document.plainText]]
    }
    /// Paste only this fixture's freshly copied synthetic content into native
    /// receivers, without an external app or private clipboard reads.
    static func observeReceivers(record: ArchivedRecognition, jpeg: Data, root: URL) async -> Bool {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) else { return false }
        let expected = record.shareDocument(), urls = expected.links.map { $0.url.absoluteString }
        let ownItems = UIPasteboard.general.items
        func bytes(_ value: Any?) -> Data? { (value as? Data) ?? (value as? String).map { Data($0.utf8) } }
        let first = ownItems.first ?? [:], last = ownItems.last ?? [:]
        // UIPasteboard may bridge text to Data and JPEG to UIImage on readback.
        // Validate types by their advertised UTI, then compare actual content.
        let imageValue = first[UTType.jpeg.identifier]
        let copiedImage = (imageValue as? UIImage) ?? bytes(imageValue).flatMap { UIImage(data: $0) }
        let copiedPixelsMatch = copiedImage?.pngData() == UIImage(data: jpeg)?.pngData() && copiedImage != nil
        let copyImageThenText = ownItems.count == 2 && bytes(last[UTType.rtf.identifier]) != nil && bytes(last[UTType.html.identifier]) != nil && bytes(last[UTType.utf8PlainText.identifier]).flatMap { String(data: $0, encoding: .utf8) } == expected.plainText && copiedPixelsMatch && last[UTType.jpeg.identifier] == nil && first[UTType.utf8PlainText.identifier] == nil
        let panel = UIView(frame: window.bounds); panel.backgroundColor = .white
        window.addSubview(panel)
        defer { panel.removeFromSuperview() }
        var rows: [[String: Any]] = []
        for rich in [true, false] {
            let view = UITextView(frame: panel.bounds.insetBy(dx: 16, dy: 70))
            view.isEditable = true; view.allowsEditingTextAttributes = rich; view.dataDetectorTypes = []
            view.font = .systemFont(ofSize: 15); panel.addSubview(view); view.becomeFirstResponder()
            view.paste(nil)
            for _ in 0..<50 where view.textStorage.length == 0 { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(400))
            var links: [String] = [], attachments = 0
            let attributed = view.textStorage
            attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
                if let url = (value as? URL)?.absoluteString ?? (value as? String) { links.append(urls.contains(url) ? url : "unexpected-link") }
            }
            attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
                if value is NSTextAttachment { attachments += 1 }
            }
            rows.append(["receiver": rich ? "UITextView-rich" : "UITextView-plain", "allowsEditingTextAttributes": rich,
                "linkDestinationsMatch": links == urls, "linkCount": links.count, "imageAttachments": attachments,
                "hasAllLabels": expected.links.allSatisfy { attributed.string.contains(rich ? $0.label : (copyMode == "pre9" ? $0.label : $0.markdown)) },
                "plainTextMatches": attributed.string.trimmingCharacters(in: .whitespacesAndNewlines) == expected.plainText.trimmingCharacters(in: .whitespacesAndNewlines),
                "hasAllMarkdownLinks": expected.links.allSatisfy { attributed.string.contains($0.markdown) },
                "hasAllURLsAsVisibleText": urls.allSatisfy { attributed.string.contains($0) },
                "pastedNonempty": attributed.length > 0])
            let mode = copyMode
            if let png = UIGraphicsImageRenderer(bounds: view.bounds).image(actions: { view.layer.render(in: $0.cgContext) }).pngData() {
                try? png.write(to: root.appendingPathComponent("paste-\(mode)-\(record.sequence)-\(rich ? "rich" : "plain").png"))
            }
            view.resignFirstResponder(); view.removeFromSuperview()
        }
        let mode = copyMode
        let rich = rows[0], plain = rows[1]
        let labels = rich["hasAllLabels"] as? Bool == true && plain["hasAllLabels"] as? Bool == true
        let imagePreserved = rich["imageAttachments"] as? Int == 1
        let passed: Bool
        if mode == "pre9" {
            passed = labels && imagePreserved && rich["hasAllURLsAsVisibleText"] as? Bool == true && plain["hasAllURLsAsVisibleText"] as? Bool == true
        } else {
            passed = (mode == "prototype" || copyImageThenText) && labels && imagePreserved && rich["linkDestinationsMatch"] as? Bool == true &&
                rich["hasAllURLsAsVisibleText"] as? Bool == false && plain["plainTextMatches"] as? Bool == true && plain["hasAllMarkdownLinks"] as? Bool == true
        }
        let report: [String: Any] = ["transport": mode, "sequence": record.sequence, "expectedURLs": urls,
            "actualCopyImageThenText": copyImageThenText, "copiedImagePixelsMatch": copiedPixelsMatch, "readbackTypes": ownItems.map { $0.mapValues { String(describing: type(of: $0)) } }, "receivers": rows, "externalAppTested": false, "ownSyntheticClipboardOnly": true,
            "meetsExpectedDiagnosticBehavior": passed,
            "googleQuery": record.googleSearch?.query ?? "",
            "googleURLQueryMatches": record.googleSearch?.googleURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value } == record.googleSearch?.query,
            "realNetworkRequests": C8NetworkProbe.shared.count]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("paste-\(mode)-\(record.sequence).json"))
        return passed
    }
    /// Only called after this fixture's own completed system Copy action changed
    /// the clipboard. It records types and exact-match booleans, never other text.
    static func observeOwnCopy(record: ArchivedRecognition, root: URL) {
        let expected = record.shareDocument(), urls = expected.links.map { $0.url.absoluteString }
        var rows: [[String: Any]] = []
        for (index, item) in UIPasteboard.general.items.enumerated() {
            for (type, value) in item {
                var row: [String: Any] = ["item": index, "type": type]
                let data = (value as? Data) ?? (value as? String).map { Data($0.utf8) }
                if type == UTType.jpeg.identifier, let data { row["sourceImageHashMatches"] = RecognitionArchive.hash(data) == record.imageSHA256 }
                if let data, [UTType.rtf.identifier, UTType.html.identifier, "com.apple.rtfd", "com.apple.flat-rtfd"].contains(type) {
                    let format: NSAttributedString.DocumentType = type == UTType.rtf.identifier ? .rtf : type == UTType.html.identifier ? .html : .rtfd
                    let decoded = try? NSAttributedString(data: data, options: [.documentType: format], documentAttributes: nil)
                    row["richDecodeSucceeded"] = decoded != nil
                    if let rich = decoded {
                        var links: [String] = []
                        rich.enumerateAttribute(.link, in: NSRange(location: 0, length: rich.length)) { v, _, _ in
                            if let url = (v as? URL)?.absoluteString ?? (v as? String) { links.append(urls.contains(url) ? url : "unexpected-link") }
                        }
                        row["exactExpectedLinks"] = links == urls; row["linkCount"] = links.count
                        row["displayTextMatches"] = rich.string == expected.displayText
                    }
                } else if let data, let text = String(data: data, encoding: .utf8), type.contains("text") || type.contains("string") {
                    row["plainTextMatches"] = text == expected.plainText
                    row["allMarkdownLinksPresent"] = expected.links.allSatisfy { text.contains($0.markdown) }
                    row["hasAllExpectedURLs"] = urls.allSatisfy { text.contains($0) }
                    row["hasGoogleLabel"] = expected.links.filter { $0.url.host == "www.google.com" }.allSatisfy { text.contains($0.label) }
                }
                rows.append(row)
            }
        }
        let report: [String: Any] = ["source": copyMode == "prototype" ? "test-only-explicit-representations-after-own-copy" : "own-synthetic-system-copy", "transport": copyMode, "sequence": record.sequence,
            "query": record.googleSearch?.query as Any? ?? NSNull(), "expectedURLs": urls, "representations": rows,
            "noPhysicalDevice": true, "realNetworkRequests": C8NetworkProbe.shared.count]
        let file = root.appendingPathComponent("copy-\(copyMode)-\(record.sequence).json")
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: file)
    }
    static func result(_ sequence: Int) -> RecognitionResult {
        let special = ProcessInfo.processInfo.arguments.contains("--markdown-punctuation")
        let name = special ? "Lay’s 樂事 [限定](原味) C++ & 日本語" : sequence == 12 ? "Lay’s 樂事 樂連連原味" : "曼秀雷敦 AD 高效抗乾修復乳液"
        let longOriginal = ProcessInfo.processInfo.arguments.contains("--long-share") ? [String(repeating: "長文測試：中文 English 日本語 👩🏽‍🔬 [原文](保留) & 123。\n", count: 400)] : []
        return .init(names: [name], summary: "合成簡介，用於檢驗分享格式，並非模型評測。",
            text: ["日本語\n  Original <script> & \"quotes\" 👩🏽‍🔬  "] + (special ? ["樂事"] : []) + longOriginal, barcodes: ["00123"],
            searchQuery: PublicSearchQuery(query: name, category: "product"),
            wikipediaTopics: sequence == 12 ? .init(category: .product, automaticWikipediaAllowed: true,
                classTerms: ["洋芋片"], candidates: [.init(topic: "樂事", kind: .brand, evidence: special ? "樂事" : name)]) : nil)
    }
    static func reference(_ sequence: Int) -> WikipediaReference? {
        guard sequence == 12, let subject = WikipediaSubject.matching(result(sequence)) else { return nil }
        let page: [String: Any] = ["pageid": 123, "ns": 0, "title": "乐事",
            "canonicalurl": "https://zh.wikipedia.org/wiki/%E4%B9%90%E4%BA%8B",
            "extract": "乐事是生产洋芋片与其他零食的品牌。"]
        return subject.reference(from: try! JSONSerialization.data(withJSONObject: ["query": ["pages": [page]]]), at: Date())
    }
    static func data(_ provider: NSItemProvider, type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }
    static func stringObject(_ provider: NSItemProvider) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadObject(ofClass: NSString.self) { object, error in
                if let object = object as? String { continuation.resume(returning: object) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }
    static func consume(_ items: [Any], copyItems: [[String: Any]], record: ArchivedRecognition, jpeg: Data, root: URL) async -> Bool {
        let mode = ProcessInfo.processInfo.arguments.contains("--actein-sample") ? "actein" : ProcessInfo.processInfo.arguments.contains("--glass-sample") ? "glass" : ProcessInfo.processInfo.arguments.contains("--fallback-links") ? "fallback" : "named"
        let exportMode = ProcessInfo.processInfo.arguments.contains("--markdown-punctuation") || ProcessInfo.processInfo.arguments.contains("--legacy-rich-card") ? copyMode : mode
        let folder = root.appendingPathComponent("rich-share-export/\(exportMode)-sequence-\(record.sequence)")
        var checks: [String: Bool] = [:]
        var errorText: String?
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            checks["direct_share_has_exact_UIImage_then_String"] = items.count == 2 && items.first is UIImage && items.last is String
            checks["direct_share_contains_no_provider_or_file_URL"] = !items.contains { $0 is NSItemProvider || $0 is URL }
            checks["copy_has_JPEG_then_rich_and_plain_text"] = copyItems.count == 2 && copyItems.first?[UTType.jpeg.identifier] is Data && copyItems.last?[UTType.rtf.identifier] is Data && copyItems.last?[UTType.html.identifier] is Data && copyItems.last?[UTType.utf8PlainText.identifier] is String
            var writes = 0
            let guardItems = [[UTType.utf8PlainText.identifier: "synthetic-only"]]
            for (kind, completed, error) in [(UIActivity.ActivityType.copyToPasteboard as UIActivity.ActivityType?, false, nil as Error?),
                (nil, true, nil), (.mail, true, nil), (.copyToPasteboard, true, CocoaError(.fileReadUnknown))] {
                RecognitionShareProviders.finishCopy(kind: kind, completed: completed, error: error, items: guardItems) { _ in writes += 1 }
            }
            checks["cancel_error_other_activity_never_write"] = writes == 0
            RecognitionShareProviders.finishCopy(kind: .copyToPasteboard, completed: true, error: nil, items: guardItems) { rows in
                if rows.first?[UTType.utf8PlainText.identifier] as? String == "synthetic-only" { writes += 1 }
            }
            checks["successful_copy_writes_frozen_items_once"] = writes == 1
            guard items.count == 2, copyItems.count == 2 else { throw CocoaError(.fileReadCorruptFile) }
            let document = record.shareDocument()
            if ProcessInfo.processInfo.arguments.contains("--markdown-punctuation") {
                checks["punctuation_case_has_Google_and_Wiki"] = document.links.count == 2
            }
            if ProcessInfo.processInfo.arguments.contains("--legacy-rich-card") {
                checks["legacy_archive_reopened_without_optional_metadata"] = record.attempts == nil && record.imageSource == nil && record.barcodeDiagnostics == nil
            }
            let frozen = RecognitionShareProviders.textRepresentations(document)
            let newer = RecognitionShareDocument(body: "Different card", links: [])
            checks["fixed_snapshot_does_not_follow_new_card"] = frozen[UTType.utf8PlainText.identifier] as? String == document.plainText && newer.plainText != document.plainText
            checks["query_round_trips_original_language_and_punctuation"] = record.googleSearch?.googleURL.flatMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value
            } == record.googleSearch?.query
            guard let image = copyItems[0][UTType.jpeg.identifier] as? Data,
                  let rtf = copyItems[1][UTType.rtf.identifier] as? Data,
                  let html = copyItems[1][UTType.html.identifier] as? Data,
                  let plainString = copyItems[1][UTType.utf8PlainText.identifier] as? String,
                  let object = items[1] as? String else { throw CocoaError(.fileReadCorruptFile) }
            let plain = Data(plainString.utf8)
            checks["direct_image_pixels_match_exact_source_JPEG"] = (items[0] as? UIImage)?.pngData() == UIImage(data: jpeg)?.pngData()
            checks["direct_text_includes_all_Markdown_links"] = document.links.allSatisfy { object.contains($0.markdown) }
            if ProcessInfo.processInfo.arguments.contains("--long-share") {
                checks["long_text_not_truncated"] = object.count > 15_000 && object == document.plainText
            }
            try image.write(to: folder.appendingPathComponent("source.jpg"))
            try rtf.write(to: folder.appendingPathComponent("share.rtf"))
            try html.write(to: folder.appendingPathComponent("share.html"))
            try plain.write(to: folder.appendingPathComponent("share.txt"))
            checks["exact_source_jpeg"] = image == jpeg && RecognitionArchive.hash(image) == record.imageSHA256
            checks["uiimage_object_compatible"] = items[0] is UIImage
            checks["plain_and_nsstring_preserve_full_text_urls_original"] = String(data: plain, encoding: .utf8) == document.plainText && object == document.plainText
            let rich = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            let htmlRich = try NSAttributedString(data: html, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
            checks["rtf_visible_text_has_named_links_without_raw_urls"] = rich.string == document.displayText && !rich.string.contains("https://")
            checks["html_visible_text_keeps_original_and_hides_raw_urls"] = htmlRich.string.contains(record.result!.text[0]) && !htmlRich.string.contains("https://")
            for (name, content) in [("rtf", rich), ("html", htmlRich)] {
                var links: [RecognitionShareDocument.Link] = []
                content.enumerateAttribute(.link, in: NSRange(location: 0, length: content.length)) { value, range, _ in
                    let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
                    if let url { links.append(.init(label: (content.string as NSString).substring(with: range), url: url)) }
                }
                checks[name + "_links_same_labels_and_canonical_destinations_once"] = links == document.links
            }
            checks["barcode_heading_and_verbatim_values"] = (rich.string.contains("【條碼】") == !record.barcodes.isEmpty) && record.barcodes.allSatisfy { rich.string.contains($0) }
            checks["no_off_or_remote_html_resources"] = !document.html.contains("<img") && !document.html.contains("<script>") && !document.html.contains("openfoodfacts")
            checks["no_model_network"] = C8NetworkProbe.shared.count == 0
            let view = UITextView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
            view.backgroundColor = .white; view.isEditable = false; view.attributedText = rich
            view.textColor = .black; view.font = .systemFont(ofSize: 17)
            view.layoutIfNeeded()
            let rendered = UIGraphicsImageRenderer(size: view.bounds.size).image { view.layer.render(in: $0.cgContext) }
            try rendered.pngData()!.write(to: folder.appendingPathComponent("rtf-consumer.png"))
        } catch { errorText = String(describing: error) }
        let passed = errorText == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        let report: [String: Any] = ["passed": passed, "checks": checks, "error": errorText as Any? ?? NSNull(),
            "sequence": record.sequence, "activityItemTypes": items.map { String(describing: type(of: $0)) }, "copyTypes": copyItems.map { $0.keys.sorted() },
            "source": "synthetic-actual-standard-activity-items-and-copy-snapshot", "realChatGPTOrLINETested": false]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("report.json"))
        return passed
    }
}

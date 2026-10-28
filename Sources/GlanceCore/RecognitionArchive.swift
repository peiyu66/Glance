import Foundation
import CryptoKit

/// Local lifecycle evidence, separate from a model's answer or network receipt.
public enum RecognitionStopReason: String, Codable, Sendable {
    case backgroundTimeExpired, backgroundTimeUnavailable, deadline
    case manual, previewClosed, consentRevoked, accountChanged, deleted, replaced, processInterrupted
    public var isBackgroundInterruption: Bool {
        self == .backgroundTimeExpired || self == .backgroundTimeUnavailable || self == .processInterrupted
    }
}

/// Local diagnostic evidence. Never included in search or ordinary result sharing.
/// The explicitly enabled JSON viewer can display/share only the current attempt's raw response.
/// At most 32 KiB of exact pre-parser response per attempt; oversize input retains metadata only.
public struct RecognitionModelResponse: Codable, Equatable, Sendable {
    public let sourceImageID: UUID
    public let attemptID: UUID
    public let recordedAt: Date
    public let appVersion: String
    public let appBuild: String
    public let promptRevision: String
    public let model: String
    public let byteCount: Int
    public let sha256: String
    public let rawResponse: String?
    public let omission: String?
    public static func capture(_ answer: String, sourceImageID: UUID, attemptID: UUID,
                               appVersion: String, appBuild: String, at date: Date = Date(), promptRevision: String = CameraAnswer.promptRevision) -> Self {
        let data = Data(answer.utf8)
        return .init(sourceImageID: sourceImageID, attemptID: attemptID, recordedAt: date,
            appVersion: String(appVersion.prefix(32)), appBuild: String(appBuild.prefix(32)),
            promptRevision: promptRevision, model: "gpt-6-luna", byteCount: data.count,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            rawResponse: data.count <= 32768 ? answer : nil, omission: data.count <= 32768 ? nil : "responseTooLarge")
    }
    var valid: Bool {
        guard appVersion.count <= 32, appBuild.count <= 32, promptRevision.count <= 80,
              model.count <= 80, byteCount >= 0, sha256.count == 64 else { return false }
        if let rawResponse {
            return omission == nil && rawResponse.utf8.count <= 32768 && rawResponse.utf8.count == byteCount &&
                SHA256.hash(data: Data(rawResponse.utf8)).map { String(format: "%02x", $0) }.joined() == sha256
        }
        return omission == "responseTooLarge" && byteCount > 32768
    }
}

/// A dedicated export of model output, never an encoding of the archive, account,
/// parsed result, or app-generated search diagnostics. Sharing preserves exact bytes.
public struct RecognitionJSONDocument: Equatable, Sendable {
    public let rawText: String?
    public let formattedText: String?
    public let message: String
    public let version: String?
    public let promptRevision: String?

    static func unavailable(_ message: String) -> Self {
        .init(rawText: nil, formattedText: nil, message: message, version: nil, promptRevision: nil)
    }
    static func prettyPrinted(_ raw: String) -> String? {
        guard (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])) != nil else { return nil }
        // Retain every JSON token, including Unicode, number spelling, duplicate
        // keys and escape sequences. Re-encoding through NSNumber could change them.
        var output = "", quoted = false, escaped = false, depth = 0
        func indentation(_ count: Int) -> String { String(repeating: "  ", count: min(max(0, count), 16)) }
        for character in raw {
            if quoted {
                output.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
                continue
            }
            if character == "\"" { quoted = true; output.append(character) }
            else if character == "{" || character == "[" { depth += 1; output.append(character); output += "\n" + indentation(depth) }
            else if character == "}" || character == "]" { depth -= 1; output += "\n" + indentation(depth); output.append(character) }
            else if character == "," { output += ",\n" + indentation(depth) }
            else if character == ":" { output += ": " }
            else if !character.isWhitespace { output.append(character) }
        }
        return output
    }
}

/// Exact text input used by the second-stage body builder. Never HTTP headers,
/// credentials, a rebuilt archive, or an inferred request from old history.
public struct RecognitionModelRequest: Codable, Equatable, Sendable {
    public enum Delivery: String, Codable, Sendable { case prepared, dispatching, submitted }
    public let recordID: UUID
    public let attemptID: UUID
    public let runID: UUID
    public let preparedAt: Date
    public let appVersion: String
    public let appBuild: String
    public let promptRevision: String
    public let rawPayload: String
    public let byteCount: Int
    public let sha256: String
    public var delivery: Delivery
    public static func capture(_ input: Data, recordID: UUID, attemptID: UUID, runID: UUID,
                               appVersion: String, appBuild: String, at date: Date = Date()) throws -> Self {
        guard let raw = String(data: input, encoding: .utf8), input.count <= 128_000,
              let root = try JSONSerialization.jsonObject(with: input) as? [String: Any],
              Set(root.keys) == ["input_version", "stage_one", "raw_stage_one_json", "sources"] else { throw SIWCError.invalidResponse }
        return .init(recordID: recordID, attemptID: attemptID, runID: runID, preparedAt: date,
            appVersion: String(appVersion.prefix(32)), appBuild: String(appBuild.prefix(32)),
            promptRevision: WikipediaSemanticReview.promptRevision, rawPayload: raw, byteCount: input.count,
            sha256: SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined(), delivery: .prepared)
    }
    public var valid: Bool {
        guard appVersion.count <= 32, appBuild.count <= 32, [WikipediaSemanticReview.promptRevision, WikipediaSemanticReview.legacyPromptRevisionW4, WikipediaSemanticReview.legacyPromptRevisionW3, WikipediaSemanticReview.legacyPromptRevisionW2, WikipediaSemanticReview.legacyPromptRevisionW1].contains(promptRevision),
              byteCount <= 128_000, rawPayload.utf8.count == byteCount,
              let root = (try? JSONSerialization.jsonObject(with: Data(rawPayload.utf8))) as? [String: Any],
              Set(root.keys) == ["input_version", "stage_one", "raw_stage_one_json", "sources"] else { return false }
        return SHA256.hash(data: Data(rawPayload.utf8)).map { String(format: "%02x", $0) }.joined() == sha256
    }
    public var message: String {
        let state: String
        switch delivery {
        case .prepared: state = "請求已組成，尚未進入送出流程。"
        case .dispatching: state = "已進入送出流程，實際傳送狀態未確認。"
        case .submitted: state = "已交給網路傳輸；不代表服務端已收到或已回覆。"
        }
        return state + "以下是第一階段資料與候選來源的實際 JSON 內容；不含 HTTP 標頭或憑證。分享保留原始文字。"
    }
}

public struct ArchivedRecognition: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable { case pending, succeeded, failed, interrupted }
    public let schemaVersion: Int
    public let id: UUID
    public let sequence: Int
    public let capturedAt: Date
    public let imageSHA256: String
    public let imageByteCount: Int
    public var status: Status
    public var result: RecognitionResult?
    public var message: String?
    public var completedAt: Date?
    /// nil marks legacy records; [] means this source was checked with no decoded value.
    public var decodedBarcodes: [String]? = nil
    public var wikipedia: WikipediaReference? = nil
    public var textWikipedia: [TextWikipediaReference]? = nil
    public var wikipediaDiagnostics: [WikipediaDiagnostic]? = nil
    public var modelResponses: [RecognitionModelResponse]? = nil
    public var semanticReview: RecognitionSemanticReview? = nil
    public var semanticRunHistory: [RecognitionSemanticRunSummary]? = nil
    mutating func retainSemanticRun() {
        guard let review = semanticReview else { return }
        semanticRunHistory = Array(((semanticRunHistory ?? []).filter { $0.runID != review.runID } + [.init(review)]).suffix(12))
    }
    public var recognitionAttemptSummary: String {
        retryAttemptSummary()?.replacingOccurrences(of: "本圖第", with: "整圖辨識第").replacingOccurrences(of: "次辨識", with: "次嘗試") ?? "整圖辨識第 \(attemptNumber) 次嘗試"
    }
    public var semanticAttemptSummary: String? {
        guard let review = semanticReview else { return nil }
        return "第二階段第 \(review.generation) 次嘗試・" + review.deliveryEvidence.label
    }
    public var productBarcodes: [ProductBarcode]? = nil
    public var productFacts: ProductFacts? = nil
    /// Absent on legacy cards; never reconstructed from an untyped payload.
    public var barcodeDiagnostics: SourceBarcodeDiagnostics? = nil
    public struct Attempt: Codable, Equatable, Identifiable, Sendable {
        public enum Outcome: String, Codable, Sendable { case pending, succeeded, failed, timedOut, interrupted }
        public let id: UUID
        /// Missing on older attempts; never inferred from the image or response date.
        public let startedAt: Date?
        public var outcome: Outcome
        public var completedAt: Date?
        public var stopReason: RecognitionStopReason? = nil
    }
    /// Optional for v1 compatibility. The JPEG, record ID and capture date never change.
    public var attempts: [Attempt]? = nil
    public enum ImageSource: String, Codable, Sendable { case camera, photoLibrary }
    /// Missing on older records, which were all captured in the app.
    public var imageSource: ImageSource? = nil
    /// One prior successful attempt, retained only while a manual rerun has no
    /// successful first-stage replacement. No image copy or recursive archive.
    public struct RetainedSuccess: Codable, Equatable, Sendable {
        public let result: RecognitionResult
        public let attempts: [Attempt]?
        public let completedAt: Date?
        public let wikipedia: WikipediaReference?
        public let textWikipedia: [TextWikipediaReference]?
        public let wikipediaDiagnostics: [WikipediaDiagnostic]?
        public let semanticReview: RecognitionSemanticReview?
        public let modelResponses: [RecognitionModelResponse]?
    }
    public var retainedSuccess: RetainedSuccess? = nil
    public var displayRecord: ArchivedRecognition {
        guard status != .succeeded, let retainedSuccess else { return self }
        var display = self
        display.retainedSuccess = nil
        display.status = .succeeded; display.result = retainedSuccess.result; display.message = nil
        display.attempts = retainedSuccess.attempts; display.completedAt = retainedSuccess.completedAt
        display.wikipedia = retainedSuccess.wikipedia; display.textWikipedia = retainedSuccess.textWikipedia
        display.wikipediaDiagnostics = retainedSuccess.wikipediaDiagnostics
        display.semanticReview = retainedSuccess.semanticReview; display.modelResponses = retainedSuccess.modelResponses
        return display
    }
    public var retainedResultNotice: String? {
        guard status != .succeeded, retainedSuccess != nil else { return nil }
        return status == .pending ? "重新辨識中，暫時顯示上次辨識結果。" : "重新辨識未完成，保留上次成功結果；可再次手動重新辨識。"
    }
    public var source: ImageSource { imageSource ?? .camera }
    public var currentAttemptID: UUID { attempts?.last?.id ?? id }
    public var attemptNumber: Int { attempts?.count ?? 1 }
    public var canRetryImage: Bool { status != .pending }
    /// Based only on saved identity/terminal evidence. This never starts a request.
    public var canContinueSemanticReview: Bool {
        guard status == .succeeded, let result, result.searchContractVersion == 17,
              !WikipediaReviewCollector.queries(for: result).isEmpty else { return false }
        guard let review = currentSemanticReview else { return true }
        switch review.state {
        case .succeeded: return review.source == nil
        case .noMatch: return review.answer?.decision != .no_match || review.answer?.valid(sources: review.sources) != true
        case .insufficientEvidence: return false
        case .collecting, .reviewing, .failed, .cancelled, .interrupted: return true
        }
    }
    public var barcodes: [String] { decodedBarcodes ?? result?.barcodes ?? [] }
    public var googleSearch: GoogleSearchQuery? {
        if status != .succeeded, retainedSuccess != nil { return displayRecord.googleSearch }
        guard status != .pending else { return nil }
        if let review = currentSemanticReview, let answer = review.answer, answer.relationship != .contextual, review.source != nil,
           let query = GoogleSearchQuery.reviewedName(answer.searchName) { return query }
        return GoogleSearchQuery.resolve(result: result, decodedBarcodes: decodedBarcodes ?? [], productBarcodes: productBarcodes ?? [])
    }
    public var shareResult: RecognitionResult? {
        if let result = presentationResult { return result.withBarcodes(barcodes).withSourceImage(id) }
        return barcodes.isEmpty ? nil : RecognitionResult(barcodes: barcodes, sourceImageID: id)
    }
    public var currentSemanticReview: RecognitionSemanticReview? {
        guard status == .succeeded, let review = semanticReview, review.recordID == id, review.attemptID == currentAttemptID else { return nil }
        if review.answer?.relationship == .contextual {
            guard let result, WikipediaSemanticReview.hasPublicTextTopic(in: result) else { return nil }
        }
        return review
    }
    /// A display projection; the archived first-stage result and raw response never change.
    public var presentationResult: RecognitionResult? {
        if status != .succeeded, retainedSuccess != nil { return displayRecord.presentationResult }
        guard let result else { return nil }
        guard let review = currentSemanticReview, review.source != nil, let answer = review.answer else { return result }
        if answer.relationship == .contextual {
            return result.withSummary([result.summary, answer.summary].filter { !$0.isEmpty }.joined(separator: "\n\n"))
        }
        return result.withSummary(answer.summary)
    }
    public var semanticJSONDocument: RecognitionJSONDocument? {
        if status != .succeeded, retainedSuccess != nil { return displayRecord.semanticJSONDocument }
        guard let review = currentSemanticReview else { return nil }
        guard let response = review.modelResponse else {
            let failure = review.failure.map { "\n診斷：" + $0.stage.rawValue + " / " + $0.code.rawValue + ($0.status.map { "（\($0)）" } ?? "") } ?? ""
            return .unavailable(review.statusText + "\n第二階段尚無保存的原始 JSON。" + failure)
        }
        guard response.valid, response.sourceImageID == id, response.attemptID == currentAttemptID else { return .unavailable("第二階段回覆完整性檢查未通過。") }
        guard let raw = response.rawResponse else { return .unavailable("第二階段回覆超過保存上限，未保存 JSON 內容。") }
        return .init(rawText: raw, formattedText: RecognitionJSONDocument.prettyPrinted(raw) ?? raw,
            message: "第二階段原始回覆；不包含 App 擷取的百科來源。分享保留原始文字。",
            version: response.appVersion + "（" + response.appBuild + "）", promptRevision: response.promptRevision)
    }
    public var semanticRequestJSONDocument: RecognitionJSONDocument {
        if status != .succeeded, retainedSuccess != nil { return displayRecord.semanticRequestJSONDocument }
        guard let review = currentSemanticReview else {
            if status == .succeeded, let result, result.searchContractVersion == 17, WikipediaReviewCollector.queries(for: result).isEmpty {
                let proposed = result.searchEntities ?? []
                let reason = !proposed.isEmpty && proposed.allSatisfy({ $0.status == .uncertain })
                    ? "候選實體皆為 uncertain，沒有可查詢的公開實體。"
                    : "沒有通過公開查詢與原文證據檢查的實體。"
                return .unavailable("本次未保存第二階段請求。\n診斷：" + reason + "依目前規則會在查詢前跳過；這不是網路失敗證據。")
            }
            return .unavailable("本次未保存第二階段請求。")
        }
        guard let request = review.modelRequest else {
            guard review.requestCaptureVersion == 1 else { return .unavailable("這筆歷史未保存第二階段請求，無法還原實際送出的內容。") }
            if review.failure?.stage == .savingRequest { return .unavailable("第二階段請求已組成但未保存，未送出。") }
            let beforePreparation: Set<SemanticReviewFailure.Stage> = [.admission, .collecting, .sourceSearch, .sourceExtract, .savingSources]
            if review.sources.isEmpty || review.failure.map({ beforePreparation.contains($0.stage) }) == true {
                return .unavailable("第二階段請求尚未組成，也未送出。")
            }
            // Cancellation may fall between assembling the bytes and saving
            // them. Mandatory persistence still proves transport did not start.
            return .unavailable("第二階段尚無已保存的請求，未送出。")
        }
        guard request.valid, request.recordID == id, request.attemptID == currentAttemptID, request.runID == review.runID else {
            return .unavailable("第二階段請求完整性檢查未通過，無法顯示或分享。")
        }
        return .init(rawText: request.rawPayload, formattedText: RecognitionJSONDocument.prettyPrinted(request.rawPayload),
            message: request.message, version: request.appVersion + "（" + request.appBuild + "）", promptRevision: request.promptRevision)
    }
    public var combinedJSONShareText: String {
        if let notice = retainedResultNotice {
            return notice + "\n以下為上次成功嘗試 " + displayRecord.currentAttemptID.uuidString
                + "；本次嘗試 " + currentAttemptID.uuidString + " 尚未取代它。\n\n" + displayRecord.combinedJSONShareText
        }
        let reply = semanticJSONDocument ?? .unavailable("本次未保存第二階段回覆。")
        func section(_ title: String, _ document: RecognitionJSONDocument, includeState: Bool = false) -> String {
            if let raw = document.rawText { return title + "\n" + (includeState ? document.message + "\n\n" : "") + raw }
            return title + "\n" + document.message
        }
        return [section("第一階段回覆", modelJSONDocument),
                section("第二階段請求", semanticRequestJSONDocument, includeState: true),
                section("第二階段回覆", reply)].joined(separator: "\n\n")
    }
    public var canShare: Bool { (status != .pending || retainedSuccess != nil) && shareResult != nil }
    public var modelJSONDocument: RecognitionJSONDocument {
        if let notice = retainedResultNotice {
            let old = displayRecord.modelJSONDocument
            return .init(rawText: old.rawText, formattedText: old.formattedText,
                message: notice + "\n以下為上次成功嘗試 " + displayRecord.currentAttemptID.uuidString + " 的原始回覆。\n" + old.message,
                version: old.version, promptRevision: old.promptRevision)
        }
        guard status != .pending else { return .unavailable("辨識尚未完成，尚無本次原始 JSON。") }
        guard let response = modelResponses?.last(where: { $0.attemptID == currentAttemptID && $0.sourceImageID == id }) else {
            return .unavailable("本次嘗試未保存原始 JSON，無法從解析結果還原。")
        }
        guard response.valid else { return .unavailable("原始回覆完整性檢查未通過，無法顯示或分享。") }
        guard let raw = response.rawResponse else { return .unavailable("原始回覆超過保存上限，未保存 JSON 內容。") }
        let formatted = RecognitionJSONDocument.prettyPrinted(raw)
        return .init(rawText: raw, formattedText: formatted ?? raw,
                     message: formatted == nil ? "保存的原始回覆不是有效 JSON；以下保留原文。" : "畫面僅調整縮排；分享會保留完整原始文字。",
                     version: response.appVersion + "（" + response.appBuild + "）", promptRevision: response.promptRevision)
    }
    public func currentTextWikipedia(at date: Date = Date()) -> [TextWikipediaReference] {
        guard status == .succeeded, let result, !result.usesEntitySearch, let references = textWikipedia, references.count <= 3 else { return [] }
        var urls = Set<URL>()
        if let wikipedia, wikipedia.isCurrent(for: result, at: date) { urls.insert(wikipedia.canonicalURL) }
        return references.filter { $0.isCurrent(for: result, at: date) && urls.insert($0.canonicalURL).inserted }
    }
    /// Resolve current valid links once; callers freeze this document at the share tap.
    public func shareDocument(at date: Date = Date()) -> RecognitionShareDocument {
        if status != .succeeded, retainedSuccess != nil { return displayRecord.shareDocument(at: date) }
        guard canShare, let result = shareResult else { return .init(body: "") }
        var links: [RecognitionShareDocument.Link] = []
        if let query = googleSearch, let url = query.googleURL {
            links.append(.init(label: "Google 搜尋：\(query.query)", url: url))
        }
        if let review = currentSemanticReview, let source = review.source, let title = review.displayTitle {
            links.append(.init(label: "維基百科：\(title)", url: source.url))
        } else if let reference = wikipedia, reference.isCurrent(for: result, at: date) {
            links.append(.init(label: "維基百科：\(reference.displayTitle)", url: reference.canonicalURL))
        }
        links += currentTextWikipedia(at: date).map { .init(label: "原文參考：\($0.displayTitle)", url: $0.canonicalURL) }
        return .init(body: result.shareText, links: links)
    }
    public func shareText(at date: Date = Date()) -> String { shareDocument(at: date).plainText }
    public func captureTimestamp(timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter.string(from: capturedAt)
    }
    public func retryAttemptSummary(locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> String? {
        guard attemptNumber > 1 else { return nil }
        let label = "本圖第 \(attemptNumber) 次辨識"
        guard let startedAt = attempts?.last?.startedAt else { return label }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("yyyyMMddjmm")
        return label + "・" + formatter.string(from: startedAt)
    }
}

// Optional enrichment must not make an otherwise readable result disappear.
extension ArchivedRecognition {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, sequence, capturedAt, imageSHA256, imageByteCount
        case status, result, message, completedAt, decodedBarcodes, wikipedia, textWikipedia, wikipediaDiagnostics, modelResponses, semanticReview, semanticRunHistory, productBarcodes, productFacts, barcodeDiagnostics, attempts, imageSource, retainedSuccess
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        id = try c.decode(UUID.self, forKey: .id)
        sequence = try c.decode(Int.self, forKey: .sequence)
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        imageSHA256 = try c.decode(String.self, forKey: .imageSHA256)
        imageByteCount = try c.decode(Int.self, forKey: .imageByteCount)
        status = try c.decode(Status.self, forKey: .status)
        result = try c.decodeIfPresent(RecognitionResult.self, forKey: .result)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        decodedBarcodes = try c.decodeIfPresent([String].self, forKey: .decodedBarcodes)
        wikipedia = try? c.decodeIfPresent(WikipediaReference.self, forKey: .wikipedia)
        wikipediaDiagnostics = (try? c.decodeIfPresent([WikipediaDiagnostic].self, forKey: .wikipediaDiagnostics)).map { Array($0.prefix(64)) }
        modelResponses = (try? c.decodeIfPresent([RecognitionModelResponse].self, forKey: .modelResponses)).map { values in Array(values.filter { $0.valid && $0.sourceImageID == id }.suffix(3)) }
        semanticReview = try? c.decodeIfPresent(RecognitionSemanticReview.self, forKey: .semanticReview)
        semanticRunHistory = (try? c.decodeIfPresent([RecognitionSemanticRunSummary].self, forKey: .semanticRunHistory)).map { Array($0.suffix(12)) }
        textWikipedia = try? c.decodeIfPresent([TextWikipediaReference].self, forKey: .textWikipedia)
        productBarcodes = try? c.decodeIfPresent([ProductBarcode].self, forKey: .productBarcodes)
        productFacts = try? c.decodeIfPresent(ProductFacts.self, forKey: .productFacts)
        barcodeDiagnostics = try? c.decodeIfPresent(SourceBarcodeDiagnostics.self, forKey: .barcodeDiagnostics)
        attempts = try c.decodeIfPresent([Attempt].self, forKey: .attempts)
        imageSource = try c.decodeIfPresent(ImageSource.self, forKey: .imageSource)
        if let retained = try? c.decodeIfPresent(RetainedSuccess.self, forKey: .retainedSuccess),
           retained.result.sourceImageID == id,
           let prior = retained.attempts?.last, prior.outcome == .succeeded,
           attempts?.contains(where: { $0.id == prior.id && $0.outcome == .succeeded }) == true {
            retainedSuccess = retained
        }
    }
}

/// App-private durable records. No index, automatic eviction, network, or replay.
/// Publishing a directory commits the JPEG and initial record together.
public actor RecognitionArchive {
    public struct Loaded: Sendable {
        public let records: [ArchivedRecognition]
        public let issues: [String]
        public let deletionIssues: [String]
        public let missingImageIDs: Set<UUID>
    }
    public enum Failure: Error, Equatable { case invalidRecord, missingImage, duplicateID, invalidCompletion, recognitionInProgress }
    public struct Deletion: Sendable {
        public let deletedIDs: Set<UUID>
        public let issues: [String]
        public let cleanupPending: Bool
    }
    public let root: URL
    private let beforeWrite: @Sendable (URL) throws -> Void
    private let manager = FileManager.default
    private var nextSequence = 1
    private var loaded = false
    public init(root: URL, beforeWrite: @escaping @Sendable (URL) throws -> Void = { _ in }) {
        self.root = root; self.beforeWrite = beforeWrite
    }
    public static func defaultRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glance/RecognitionHistory-v1", isDirectory: true)
    }
    private func protect(_ url: URL) throws {
        var resource = URLResourceValues(); resource.isExcludedFromBackup = true
        var target = url; try target.setResourceValues(resource)
        #if os(iOS)
        try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
    private func ensureRoot() throws {
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try protect(root)
    }
    private func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func write(_ data: Data, to url: URL) throws {
        try beforeWrite(url)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try protect(url)
    }
    private func encode(_ value: ArchivedRecognition) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private func read(_ id: UUID) throws -> ArchivedRecognition {
        let properties = try directory(id).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard properties.isDirectory == true, properties.isSymbolicLink != true else { throw Failure.invalidRecord }
        let value = try JSONDecoder().decode(ArchivedRecognition.self, from: Data(contentsOf: directory(id).appendingPathComponent("record.json")))
        guard value.schemaVersion == 1, value.id == id, value.sequence > 0,
              value.result == nil || value.result?.sourceImageID == id,
              value.status != .succeeded || value.result != nil else { throw Failure.invalidRecord }
        return value
    }
    public func load(recoverPending: Bool = true, liveAttemptIDs: Set<UUID> = [], liveSemanticRunIDs: Set<UUID> = []) throws -> Loaded {
        try ensureRoot()
        let deletionIssues = cleanupDeleted()
        var records: [ArchivedRecognition] = [], issues: [String] = [], missingImageIDs = Set<UUID>()
        for folder in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            do {
                let properties = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard properties.isDirectory == true, properties.isSymbolicLink != true else { throw Failure.invalidRecord }
                var record = try read(id)
                // Reserve sequence even if an image is damaged; never renumber existing rows.
                nextSequence = max(nextSequence, record.sequence + 1)
                if recoverPending && record.status == .pending && !liveAttemptIDs.contains(record.currentAttemptID) {
                    record.status = .interrupted; record.message = "辨識中斷，尚未完成；原圖已保留，可手動重試，沒有自動重送。"; record.completedAt = Date()
                    if let index = record.attempts?.indices.last {
                        record.attempts?[index].outcome = .interrupted; record.attempts?[index].completedAt = record.completedAt
                        record.attempts?[index].stopReason = .processInterrupted
                    }
                    do { try write(encode(record), to: folder.appendingPathComponent("record.json")) }
                    catch { issues.append("有一筆中斷狀態尚未保存，原資料保留。") }
                }
                if recoverPending && record.semanticReview?.isPending == true && !liveSemanticRunIDs.contains(record.semanticReview!.runID) {
                    record.semanticReview?.state = .interrupted; record.semanticReview?.finishedAt = Date()
                    record.semanticReview?.stopReason = .processInterrupted
                    do { try write(encode(record), to: folder.appendingPathComponent("record.json")) }
                    catch { issues.append("有一筆百科補充中斷狀態尚未保存，原始辨識保留。") }
                }
                do { _ = try imageURL(for: record) }
                catch { missingImageIDs.insert(record.id); issues.append("有一筆來源圖片無法讀取，文字及原始檔案均保留。") }
                records.append(record)
            } catch { issues.append("有一筆歷史無法讀取，未覆蓋或刪除原始檔案。") }
        }
        loaded = true
        return Loaded(records: records.sorted { $0.sequence > $1.sequence }, issues: issues, deletionIssues: deletionIssues, missingImageIDs: missingImageIDs)
    }
    public func create(id: UUID, jpeg: Data, capturedAt: Date, decodedBarcodes: [String]? = nil, productBarcodes: [ProductBarcode]? = nil, barcodeDiagnostics: SourceBarcodeDiagnostics? = nil, imageSource: ArchivedRecognition.ImageSource = .camera) throws -> ArchivedRecognition {
        if !loaded { _ = try load() }
        guard !jpeg.isEmpty else { throw Failure.missingImage }
        let destination = directory(id)
        guard !manager.fileExists(atPath: destination.path) else { throw Failure.duplicateID }
        let record = ArchivedRecognition(schemaVersion: 1, id: id, sequence: nextSequence, capturedAt: capturedAt,
            imageSHA256: Self.hash(jpeg), imageByteCount: jpeg.count, status: .pending, result: nil, message: nil, completedAt: nil,
            decodedBarcodes: decodedBarcodes, productBarcodes: productBarcodes, barcodeDiagnostics: barcodeDiagnostics,
            attempts: [.init(id: id, startedAt: capturedAt, outcome: .pending)], imageSource: imageSource)
        let staging = root.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            try protect(staging)
            try write(jpeg, to: staging.appendingPathComponent("source.jpg"))
            try write(encode(record), to: staging.appendingPathComponent("record.json"))
            try beforeWrite(destination)
            try manager.moveItem(at: staging, to: destination)
        } catch {
            // Only this unpublished transaction; no request was sent, no saved result is removed.
            try? manager.removeItem(at: staging); throw error
        }
        nextSequence += 1; return record
    }
    /// Start one new attempt on verified existing bytes. Never rewrites source.jpg.
    public func beginRetry(id: UUID, attemptID: UUID, at date: Date = Date()) throws -> ArchivedRecognition {
        var record = try read(id)
        guard record.canRetryImage, attemptID != record.currentAttemptID,
              record.attempts?.contains(where: { $0.id == attemptID }) != true else { throw Failure.invalidCompletion }
        _ = try image(for: record)
        if record.attempts == nil {
            record.attempts = [.init(id: id, startedAt: nil,
                outcome: record.status == .succeeded ? .succeeded : record.status == .interrupted ? .interrupted : .failed, completedAt: record.completedAt)]
        }
        if record.status == .succeeded, let result = record.result {
            record.retainedSuccess = .init(result: result, attempts: record.attempts, completedAt: record.completedAt,
                wikipedia: record.wikipedia, textWikipedia: record.textWikipedia, wikipediaDiagnostics: record.wikipediaDiagnostics,
                semanticReview: record.semanticReview, modelResponses: record.modelResponses)
        }
        record.retainSemanticRun()
        record.attempts?.append(.init(id: attemptID, startedAt: date, outcome: .pending))
        record.status = .pending; record.result = nil; record.message = nil; record.completedAt = nil
        record.wikipedia = nil; record.textWikipedia = nil; record.wikipediaDiagnostics = nil; record.semanticReview = nil
        try write(encode(record), to: directory(id).appendingPathComponent("record.json"))
        return record
    }
    public func complete(id: UUID, result: RecognitionResult?, message: String?, at date: Date = Date(),
                         attemptID: UUID? = nil, timedOut: Bool = false, modelResponse: RecognitionModelResponse? = nil,
                         stopReason: RecognitionStopReason? = nil) throws -> ArchivedRecognition {
        var record = try read(id)
        guard record.status == .pending, record.currentAttemptID == (attemptID ?? id) else { return record }
        if let modelResponse {
            guard modelResponse.valid, modelResponse.sourceImageID == id, modelResponse.attemptID == record.currentAttemptID else { throw Failure.invalidCompletion }
            record.modelResponses = Array(((record.modelResponses ?? []).filter { $0.attemptID != modelResponse.attemptID } + [modelResponse]).suffix(3))
        }
        // Each attempt is terminal once. Late replies cannot finish a newer attempt.
        if let result {
            record.retainedSuccess = nil
            record.result = result.withBarcodes(record.decodedBarcodes ?? result.barcodes).withSourceImage(id)
            record.status = .succeeded; record.message = nil
        } else {
            record.status = stopReason?.isBackgroundInterruption == true ? .interrupted : .failed
            record.message = message ?? "辨識未完成；原圖已保留，可重試這張圖片。"
        }
        record.completedAt = date
        if let index = record.attempts?.indices.last {
            record.attempts?[index].outcome = result != nil ? .succeeded : stopReason?.isBackgroundInterruption == true ? .interrupted : timedOut ? .timedOut : .failed
            record.attempts?[index].completedAt = date
            record.attempts?[index].stopReason = result == nil ? stopReason : nil
        }
        try write(encode(record), to: directory(id).appendingPathComponent("record.json"))
        return record
    }
    /// Update only an existing completed card; a deleted card is never recreated.
    public func attachWikipedia(id: UUID, reference: WikipediaReference, at date: Date = Date()) throws -> ArchivedRecognition {
        try Task.checkCancellation()
        var record = try read(id)
        guard record.status == .succeeded, let result = record.result,
              result.sourceImageID == id, reference.isCurrent(for: result, at: date) else { throw Failure.invalidCompletion }
        record.wikipedia = reference
        try write(encode(record), to: directory(id).appendingPathComponent("record.json"))
        return record
    }
    public func attachWikipediaEnrichment(id: UUID, expectedResult: RecognitionResult,
                                          enrichment: WikipediaEnrichment, at date: Date = Date()) throws -> ArchivedRecognition {
        try Task.checkCancellation()
        var record = try read(id)
        guard record.status == .succeeded, let result = record.result, result == expectedResult,
              result.sourceImageID == id, enrichment.text.count <= 3,
              !result.usesEntitySearch || enrichment.text.isEmpty,
              Set(enrichment.text.map(\.candidateKey)).count == enrichment.text.count,
              enrichment.text.allSatisfy({ $0.isCurrent(for: result, at: date) }),
              enrichment.subject.map({ $0.isCurrent(for: result, at: date) }) ?? true else { throw Failure.invalidCompletion }
        if let subject = enrichment.subject { record.wikipedia = subject }
        record.textWikipedia = enrichment.text
        if result.usesEntitySearch {
            record.wikipedia = enrichment.subject
            record.wikipediaDiagnostics = Array(enrichment.diagnostics.prefix(63)) + [.init(.persistence, .saved, at: date)]
        }
        try write(encode(record), to: directory(id).appendingPathComponent("record.json"))
        return record
    }
    /// Claim once before any network request. Restart never replays it automatically.
    public func beginSemanticReview(id: UUID, attemptID: UUID, runID: UUID, expectedResult: RecognitionResult) throws -> ArchivedRecognition {
        try claimSemanticReview(id: id, attemptID: attemptID, runID: runID, expectedResult: expectedResult, resuming: false, previousRunID: nil)
    }
    /// One explicit manual continuation; compare-and-swap prevents two retries or stale UI actions.
    public func resumeSemanticReview(id: UUID, attemptID: UUID, runID: UUID, previousRunID: UUID?, expectedResult: RecognitionResult) throws -> ArchivedRecognition {
        try claimSemanticReview(id: id, attemptID: attemptID, runID: runID, expectedResult: expectedResult, resuming: true, previousRunID: previousRunID)
    }
    private func claimSemanticReview(id: UUID, attemptID: UUID, runID: UUID, expectedResult: RecognitionResult,
                                     resuming: Bool, previousRunID: UUID?) throws -> ArchivedRecognition {
        try Task.checkCancellation()
        var record = try read(id)
        guard record.status == .succeeded, record.currentAttemptID == attemptID, record.result == expectedResult else { throw Failure.invalidCompletion }
        if resuming {
            guard record.canContinueSemanticReview, record.semanticReview?.runID == previousRunID,
                  runID != previousRunID else { throw Failure.invalidCompletion }
        } else { guard record.semanticReview == nil else { throw Failure.invalidCompletion } }
        let previousGeneration = record.semanticReview?.generation ?? 0
        guard previousGeneration < Int.max else { throw Failure.invalidCompletion }
        record.retainSemanticRun()
        record.semanticReview = .init(recordID: id, attemptID: attemptID, runID: runID)
        record.semanticReview?.runNumber = previousGeneration + 1
        record.semanticReview?.requestCaptureVersion = 1
        try write(encode(record), to: directory(id).appendingPathComponent("record.json"))
        return record
    }
    public func saveSemanticRequest(id: UUID, attemptID: UUID, runID: UUID, request: RecognitionModelRequest) throws -> ArchivedRecognition {
        try Task.checkCancellation()
        var record = try read(id)
        guard record.status == .succeeded, record.currentAttemptID == attemptID, var review = record.semanticReview,
              review.recordID == id, review.attemptID == attemptID, review.runID == runID,
              request.valid, request.recordID == id, request.attemptID == attemptID, request.runID == runID else { throw Failure.invalidCompletion }
        if let previous = review.modelRequest {
            var same = request; same.delivery = previous.delivery
            guard same == previous else { throw Failure.invalidCompletion }
            let order: [RecognitionModelRequest.Delivery] = [.prepared, .dispatching, .submitted]
            let old = order.firstIndex(of: previous.delivery)!, new = order.firstIndex(of: request.delivery)!
            guard new == old || new == old + 1 else { throw Failure.invalidCompletion }
            // A late transport receipt may refine an already-cancelled run, but
            // cannot change its outcome, sources or response, or restart it.
            guard review.isPending || (previous.delivery == .dispatching && request.delivery == .submitted) else { throw Failure.invalidCompletion }
        } else {
            guard review.state == .reviewing, !review.sources.isEmpty, request.delivery == .prepared else { throw Failure.invalidCompletion }
        }
        if request.delivery == .dispatching && review.requestDispatchStartedAt == nil { review.requestDispatchStartedAt = Date() }
        review.modelRequest = request; record.semanticReview = review
        try write(encode(record), to: directory(id).appendingPathComponent("record.json"))
        return record
    }
    public func updateSemanticReview(id: UUID, attemptID: UUID, runID: UUID, state: RecognitionSemanticReview.State,
        sources: [WikipediaReviewSource]? = nil, answer: WikipediaReviewAnswer? = nil, response: RecognitionModelResponse? = nil, failure: SemanticReviewFailure? = nil,
        stopReason: RecognitionStopReason? = nil) throws -> ArchivedRecognition {
        try Task.checkCancellation()
        var record = try read(id)
        guard record.status == .succeeded, record.currentAttemptID == attemptID, var review = record.semanticReview,
              review.recordID == id, review.attemptID == attemptID, review.runID == runID, review.isPending,
              state != .collecting else { throw Failure.invalidCompletion }
        if let sources {
            guard sources.count <= WikipediaReviewBudget.sourceLimit, sources.allSatisfy(\.valid), Set(sources.map(\.id)).count == sources.count else { throw Failure.invalidCompletion }
            review.sources = sources
        }
        if let response {
            guard response.valid, response.sourceImageID == id, response.attemptID == attemptID,
                  response.promptRevision == WikipediaSemanticReview.promptRevision else { throw Failure.invalidCompletion }
            review.modelResponse = response
        }
        if let answer {
            guard answer.valid(sources: review.sources) else { throw Failure.invalidCompletion }
            if answer.relationship == .contextual {
                guard let result = record.result, WikipediaSemanticReview.hasPublicTextTopic(in: result) else { throw Failure.invalidCompletion }
            }
            review.answer = answer
        }
        if state == .succeeded { guard review.answer?.decision == .selected, review.answer?.valid(sources: review.sources) == true else { throw Failure.invalidCompletion } }
        if state == .noMatch { guard review.answer?.decision == .no_match else { throw Failure.invalidCompletion } }
        if state == .reviewing {
            guard review.state == .collecting, !review.sources.isEmpty else { throw Failure.invalidCompletion }
            review.sourcesFinishedAt = Date()
        }
        review.state = state
        review.stopReason = stopReason
        review.failure = state == .failed ? failure : nil
        if !review.isPending { review.finishedAt = Date() }
        record.semanticReview = review
        try Task.checkCancellation()
        try write(encode(record), to: directory(id).appendingPathComponent("record.json"))
        return record
    }
    /// Independent enrichment can finish before or after the AI, on this same saved source.
    public func attachProductFacts(id: UUID, facts: ProductFacts) throws -> ArchivedRecognition {
        try Task.checkCancellation()
        var record = try read(id)
        guard facts.isValid(for: record.productBarcodes ?? []) else { throw Failure.invalidCompletion }
        record.productFacts = facts
        try write(encode(record), to: directory(id).appendingPathComponent("record.json"))
        return record
    }
    /// First remove the whole record from the readable namespace. Completions and
    /// enrichment never create directories, so a late reply cannot resurrect it.
    /// The hidden directory is deletion work, not an undo copy; load retries cleanup.
    public func delete(ids: Set<UUID>, resetSequenceWhenEmpty: Bool = false) throws -> Deletion {
        try ensureRoot()
        // Validate the entire request before deleting anything, including pending work.
        for id in ids {
            guard try read(id).status != .pending else { throw Failure.recognitionInProgress }
            try beforeWrite(directory(id))
        }
        var deleted: Set<UUID> = [], issues: [String] = []
        for id in ids {
            let tombstone = root.appendingPathComponent(".deleted-" + UUID().uuidString, isDirectory: true)
            do {
                try manager.moveItem(at: directory(id), to: tombstone)
                deleted.insert(id)
            } catch {
                issues.append("有一筆紀錄無法刪除，請重試。")
            }
        }
        let cleanupIssues = cleanupDeleted()
        if resetSequenceWhenEmpty && !ids.isEmpty && deleted == ids && issues.isEmpty && cleanupIssues.isEmpty {
            // Only an explicit successful clear-all resets the display counter.
            // Verify disk, not a possibly stale UI list; never discard unknown records.
            do {
                if try manager.contentsOfDirectory(atPath: root.path).isEmpty {
                    nextSequence = 1
                } else {
                    issues.append("仍有未清除的紀錄或檔案，編號尚未重設；請重新讀取紀錄。")
                }
            } catch {
                issues.append("無法確認清空結果，編號尚未重設；請重新讀取紀錄。")
            }
        }
        return Deletion(deletedIDs: deleted, issues: issues + cleanupIssues, cleanupPending: !cleanupIssues.isEmpty)
    }
    /// Only generated deletion directories inside this archive are eligible.
    private func cleanupDeleted() -> [String] {
        var issues: [String] = []
        guard let folders = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return ["無法檢查已刪紀錄的檔案，請重試清理。"]
        }
        for folder in folders {
            let name = folder.lastPathComponent
            guard name.hasPrefix(".deleted-"), UUID(uuidString: String(name.dropFirst(9))) != nil else { continue }
            do {
                try beforeWrite(folder)
                try manager.removeItem(at: folder)
            } catch {
                issues.append("已刪紀錄的部分檔案尚未清除，請重試清理。")
            }
        }
        return issues
    }
    private func imageURL(for record: ArchivedRecognition) throws -> URL {
        let url = directory(record.id).appendingPathComponent("source.jpg")
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true,
              properties.fileSize == record.imageByteCount else { throw Failure.missingImage }
        return url
    }
    public func image(for record: ArchivedRecognition) throws -> Data {
        // Loading the history scans metadata only; validate full bytes lazily for visible rows.
        let data = try Data(contentsOf: imageURL(for: record))
        guard Self.hash(data) == record.imageSHA256 else { throw Failure.missingImage }
        return data
    }
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}


/// One text item with equivalent rich and plain representations. No Markdown guessing,
/// duplicate page title, remote resource, or mutation of the saved recognition answer.
public struct RecognitionShareDocument: Equatable, Sendable {
    public struct Link: Equatable, Sendable {
        public let label: String
        public let url: URL
        public init(label: String, url: URL) { self.label = label; self.url = url }
        /// Escape Markdown punctuation in the label without changing its Unicode text.
        /// Percent-encode destination parentheses; existing URL escapes stay intact.
        public var markdown: String {
            let escaped = label.unicodeScalars.map { scalar -> String in
                let punctuation = (33...47).contains(scalar.value) || (58...64).contains(scalar.value)
                    || (91...96).contains(scalar.value) || (123...126).contains(scalar.value)
                return (punctuation ? "\\" : "") + String(scalar)
            }.joined()
            let destination = url.absoluteString.replacingOccurrences(of: "(", with: "%28")
                .replacingOccurrences(of: ")", with: "%29")
            return "[\(escaped)](\(destination))"
        }
    }
    public let body: String
    public let links: [Link]
    public init(body: String, links: [Link] = []) { self.body = body; self.links = links }
    public var displayText: String { ([body].filter { !$0.isEmpty } + links.map(\.label)).joined(separator: "\n\n") }
    /// A receiver may display this Markdown literally; the complete URL remains usable.
    public var plainText: String {
        ([body].filter { !$0.isEmpty } + links.map(\.markdown)).joined(separator: "\n\n")
    }
    public var html: String {
        let paragraphs = links.map { "<p><a href=\"\(Self.escape($0.url.absoluteString))\">\(Self.escape($0.label))</a></p>" }.joined()
        return "<!doctype html><html lang=\"zh-Hant-TW\"><head><meta charset=\"utf-8\"></head><body><div style=\"white-space:pre-wrap\">\(Self.escape(body))</div>\(paragraphs)</body></html>"
    }
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }
}

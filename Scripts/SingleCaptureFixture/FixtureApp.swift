import SwiftUI
import UIKit
import CoreImage
import Vision
import Photos
import UniformTypeIdentifiers

actor C3BarcodeProbe {
    var values: [String] = []
    var lastJPEG: Data?
    func set(_ values: [String]) { self.values = values }
    func decode(_ jpeg: Data) -> [String] { lastJPEG = jpeg; return values }
}

final class C2WriteFault: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    func set(_ value: Bool) { lock.withLock { self.value = value } }
    func check(_: URL) throws { if lock.withLock({ value }) { throw CocoaError(.fileWriteOutOfSpace) } }
}
@MainActor final class C2Clock { var now: Double = 0 }
@MainActor @Observable final class C2FixtureHost {
    let clock = C2Clock()
    let barcodeProbe = C3BarcodeProbe()
    let realBarcodes: Bool
    let wikipediaReferencesLookup: @Sendable (RecognitionResult) async -> WikipediaEnrichment
    let wikipediaLookup: @Sendable (WikipediaSubject) async -> WikipediaReference?
    let productScan: (@Sendable (Data) async -> SourceBarcodeScan)?
    let root: URL
    var model: SingleCaptureController!
    var status = "loading"
    var openedURLs: [String] = []
    var openedURLsJSON: String { String(data: try! JSONEncoder().encode(openedURLs), encoding: .utf8)! }
    var deletionFileStatus = "unchecked"
    var selectionStatus = "selection-idle"
    var selectionClipboardBaseline = 0
    var selectionDragInitialLength = 0
    var starts = 0
    var stops = 0
    var calls = 0
    var loginCalls = 0
    var lastJPEG: Data?
    var waiter: CheckedContinuation<RecognitionResult, Error>?
    var holdBeforeSend: CheckedContinuation<Void, Never>?
    var delayValidation = false
    var prepared = false
    private var preparing = false
    let writeFault = C2WriteFault()
    let shareProbe = SummaryCardProbe()
    private var shareFile: URL?
    private var copiedFixtureRecord: ArchivedRecognition?
    private var clipboardChangeCount = 0
    private var imageShareChecks: [String: Bool] = [:]
    private var imageShareSequence = 0
    init(name: String = "ui-history", realBarcodes: Bool = false,
         wikipediaLookup: @escaping @Sendable (WikipediaSubject) async -> WikipediaReference? = { _ in nil },
         wikipediaReferencesLookup: @escaping @Sendable (RecognitionResult) async -> WikipediaEnrichment = { _ in .init() },
         productScan: (@Sendable (Data) async -> SourceBarcodeScan)? = nil) {
        self.wikipediaReferencesLookup = wikipediaReferencesLookup
        self.wikipediaLookup = wikipediaLookup
        self.productScan = productScan
        self.realBarcodes = realBarcodes
        if !ProcessInfo.processInfo.arguments.contains("--json45-preserve-setting") {
            UserDefaults.standard.removeObject(forKey: "glance.showModelJSON")
        }
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        model = makeModel()
        if ProcessInfo.processInfo.arguments.contains("--actions56") {
            delayValidation = true
            UserDefaults.standard.set(true, forKey: "glance.showModelJSON")
        }
        if ProcessInfo.processInfo.arguments.contains("--onboarding-ui") { configureOnboardingFixture() }
    }
    static let webHTTP = "http://60.251.161.196/RegDegree/RegisterDegree.aspx"
    static let webBarcodes = [webHTTP, "https://example.com/path?x=1&y=2#part", "0012345678905", "javascript:alert(1)", "https://", "file:///tmp/example"]
    static let webResult = RecognitionResult(names: ["https://name.example/a"], summary: "明確網址 https://summary.example/a；電話 0800-388-100、數字 0012345678905、example.com 保留文字。", text: ["原文 https://original.example/a"], barcodes: webBarcodes)
    func makeModel(consent: DataConsentController = .fixtureAccepted(), account: SIWCController = SIWCController(allowsDataTransfer: { true }), access: @escaping () -> Bool = { true }, permission: @escaping () async -> Bool = { true }, requestTimeout: Duration = .seconds(120), semantic: Semantic45Probe? = nil, background: Background62Lease? = nil) -> SingleCaptureController {
        let fault = writeFault
        let reviewProvider: (@MainActor (RecognitionResult, String?, [WikipediaReviewSource], @escaping () throws -> Void) async throws -> String)?
        if let semantic {
            reviewProvider = { result, _, sources, validate in
                try validate(); return try await semantic.review(result, sources: sources)
            }
        } else { reviewProvider = nil }
        return SingleCaptureController(consent: consent, account: account, archive: RecognitionArchive(root: root, beforeWrite: { try fault.check($0) }), clock: { self.clock.now }, frameClock: { self.clock.now },
            permission: permission, previewStart: { _ in self.starts += 1 }, previewStop: { self.stops += 1 }, access: access,
            scanBarcodes: { [probe = barcodeProbe, real = realBarcodes, scan = productScan] jpeg in
                if let scan { return await scan(jpeg) }
                let injected = await probe.decode(jpeg)
                return real ? await SourceBarcodeDecoder.shared.scan(jpeg) : .init(values: injected)
            },
            wikipediaLookup: wikipediaLookup, wikipediaReferencesLookup: wikipediaReferencesLookup,
            provider: { jpeg, _, validate, submitted in
                if self.delayValidation { await withCheckedContinuation { self.holdBeforeSend = $0 } }
                try validate(); try submitted(); self.calls += 1; self.lastJPEG = jpeg
                return try await withCheckedThrowingContinuation { self.waiter = $0 }
            }, semanticReviewEnabled: semantic != nil,
            semanticSources: { result in try await semantic?.sources(result) ?? [] },
            semanticProvider: reviewProvider,
            loadAccount: false, requestTimeout: requestTimeout,
            backgroundBegin: { handler in background?.begin(handler) ?? UIBackgroundTaskIdentifier(rawValue: 6200) },
            backgroundEnd: { id in background?.end(id) })
    }
    static func jpeg(_ color: UIColor) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            color.setFill(); context.fill(CGRect(x:0,y:0,width:64,height:64))
        }.jpegData(compressionQuality: 0.82)!
    }
    func feed(_ color: UIColor = .blue, focus: Bool = false, source: UIImage? = nil) {
        let image = source?.cgImage ?? UIImage(data: Self.jpeg(color))!.cgImage!
        let fp = SceneFingerprint(rgb:(0..<192).map { $0 % 2 == 0 ? 0.2 : 0.8 },side:8)
        for _ in 0..<6 {
            clock.now += 0.25
            let stamp = focus ? model.capture.focusGate.stamp(capturedAt: clock.now) : nil
            model.receive(CameraFrame(image:image,fingerprint:fp,feature:nil,time:clock.now,focusStamp:stamp),generation:model.previewGeneration)
        }
    }
    func settle(_ predicate: () -> Bool) async {
        for _ in 0..<300 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
    func complete(fail: Bool = false, cancelled: Bool = false) async {
        guard let continuation = waiter else { return }; waiter = nil
        if cancelled { continuation.resume(throwing: CancellationError()) }
        else if fail { continuation.resume(throwing: URLError(.timedOut)) }
        else { continuation.resume(returning: .init(names:["合成第 \(calls) 張"],summary:ProcessInfo.processInfo.arguments.contains("--preview-stability") ? String(repeating:"合成長回覆，用來測量卡片長度不應改變鏡頭尺寸。",count:30) : "完整繁體中文簡介",text:["日本語\nABC 👩🏽‍🔬"],barcodes:["00123"])) }
        await model.waitForCurrentWork()
    }
    func prepareUI() async {
        guard !prepared, !preparing else { return }; preparing = true
        if ProcessInfo.processInfo.arguments.contains("--failed-signin-settings") || ProcessInfo.processInfo.arguments.contains("--signed-in-settings") {
            let tokens = SIWCTokens(access: "generated", refresh: nil, idToken: "generated", scope: SIWCProtocol.scopes, expiresAt: Date().addingTimeInterval(3600))
            let previous = SIWCAccount(clientID: "generated", subject: "generated", email: "previous@example.invalid", tokens: tokens)
            model.account.saved = SIWCSaved(hostID: "generated", accounts: [previous], selected: previous.id)
            model.account.selectedID = previous.id
            if ProcessInfo.processInfo.arguments.contains("--failed-signin-settings") {
                let trace = UUID(); model.account.authDiagnostic.begin(traceID: trace)
                model.account.authDiagnostic.record(stage: .tokenExchange, outcome: .failed, category: .http, httpStatus: 400, errorCode: "invalid_grant", traceID: trace, errorDescription: .tokenResponse(Data(#"{"error":"invalid_grant","error_description":"generated token=never-store"}"#.utf8)))
                model.account.status = SIWCSignInMessage.failure(stage: .tokenExchange, category: .http, httpStatus: 400, errorCode: "invalid_grant") + "原帳戶已保留。"
            } else { model.account.status = "" }
        }
        let webLinks = ProcessInfo.processInfo.arguments.contains("--web-url-links")
        if webLinks { UserDefaults.standard.set(true, forKey: "glance.showModelJSON") }
        let resume = ProcessInfo.processInfo.arguments.contains("--resume-history")
        if !resume {
            try? FileManager.default.removeItem(at: root)
            let archive = RecognitionArchive(root: root)
            for index in (ProcessInfo.processInfo.arguments.contains("--empty-history") ? [] : Array(1...12)) {
                let actein = ProcessInfo.processInfo.arguments.contains("--actein-sample") && index >= 11
                let glass = ProcessInfo.processInfo.arguments.contains("--glass-sample") && index >= 11
                let glassCode = ProductBarcode(value: "4713213242926", symbology: .ean13)!
                let fallback = ProcessInfo.processInfo.arguments.contains("--fallback-links") && index >= 11
                let fallbackQR = "品名：腹釋寧消化\n諮詢電話：0800-388-100"
                let isProduct = (ProcessInfo.processInfo.arguments.contains("--product-links") || ProcessInfo.processInfo.arguments.contains("--barcode-only")) && index >= 11
                let productCode = index == 12 ? C7FactsProbe.firstCode : C7FactsProbe.secondCode
                let id = UUID(); _ = try? await archive.create(id:id,jpeg:Self.jpeg(UIColor(hue:CGFloat(index)/16,saturation:0.7,brightness:0.9,alpha:1)),capturedAt:Date(), decodedBarcodes: webLinks && index == 12 ? Self.webBarcodes : glass ? [glassCode.value] : fallback && index == 11 ? [fallbackQR] : isProduct ? [productCode.value] : nil, productBarcodes: glass ? (index == 12 ? [glassCode] : []) : isProduct ? [productCode] : nil, imageSource: ProcessInfo.processInfo.arguments.contains("--photo57-label") ? .photoLibrary : .camera)
                let selectionLinks = ProcessInfo.processInfo.arguments.contains("--selection-links") && index >= 11
                let search = (ProcessInfo.processInfo.arguments.contains("--search-links") || selectionLinks) && index >= 11 ? PublicSearchQuery(query: "Acme C++ & 測試 #\(index)", category: "product") : nil
                let isWiki = (ProcessInfo.processInfo.arguments.contains("--wiki-links") || ProcessInfo.processInfo.arguments.contains("--share-links") || isProduct) && index >= 11
                let rich = ProcessInfo.processInfo.arguments.contains("--rich-share") && index >= 11
                let entity39 = ProcessInfo.processInfo.arguments.contains("--entity39-links") && index >= 11
                let entity38 = ProcessInfo.processInfo.arguments.contains("--entity38-links") && index >= 11
                let modern = ProcessInfo.processInfo.arguments.contains("--candidate37-links") && index >= 11
                let textWiki = (ProcessInfo.processInfo.arguments.contains("--text-wiki-links") || modern) && index >= 11
                let fixtureResult: RecognitionResult = webLinks && index == 12 ? Self.webResult : entity39 ? C39EntityProbe.result(index) : entity38 ? C38EntityProbe.result(index) : modern ? C37CandidateProbe.result() : textWiki ? C36TextProbe.result() : actein ? .init(names: [index == 12 ? "Actein 顆粒" : "アクテイン顆粒"], summary: "這是標示為 Actein 的藥品顆粒包裝；顆粒劑是將藥物製成可分散或吞服的小顆粒的劑型。", text: ["synmosa", "3g", "Actein®", "Granules 66.7mg/gm"]) : glass ? .init(names: ["玻璃杯"], text: [glassCode.value], barcodes: [glassCode.value], searchQuery: PublicSearchQuery(query: "玻璃杯", category: "object")) : fallback ? .init(names: [index == 12 ? "腹釋寧消化腸溶糖衣錠" : "胃藥錠劑"], text: ["PHAZIN-P Enteric S.C.TABLETS"], barcodes: index == 11 ? [fallbackQR] : []) : rich ? C9RichShareChecks.result(index) : isWiki ? C5WikipediaProbe.result(index == 12 ? "雨傘" : "剪刀") : .init(names:["已保存第 \(index) 張"],summary:String(repeating:"這是合成說明，用來檢查閱讀位置與來源圖片。",count:5),text:["Original \(index)\n日本語" + (selectionLinks ? "\n" + (index == 12 ? "雨傘" : "剪刀") : "") + (ProcessInfo.processInfo.arguments.contains("--selection-long") ? String(repeating: "\n長文段落 中文 English 日本語 👩🏽‍🔬", count: 30) : "")],barcodes:["00\(index)"],searchQuery:search,wikipediaTopics:selectionLinks ? C5WikipediaProbe.result(index == 12 ? "雨傘" : "剪刀").wikipediaTopics : nil)
                let json45 = ProcessInfo.processInfo.arguments.contains("--json45")
                let raw45 = webLinks && index == 12 ? "{\"url\":\"https://json.example/a\",\"numeric\":\"0012345678905\"}" : json45 ? Self.json45Raw(index) : nil
                let evidence45 = raw45.map { RecognitionModelResponse.capture($0, sourceImageID: id, attemptID: id, appVersion: "0.1.0", appBuild: "45") }
                _ = try? await archive.complete(id:id,result:ProcessInfo.processInfo.arguments.contains("--barcode-only") || (json45 && index == 10) ? nil : fixtureResult,message:json45 && index == 10 ? "合成解析失敗" : nil,modelResponse:evidence45)
                if (textWiki || entity38 || entity39), let saved = try? await archive.load().records.first(where: { $0.id == id }), let result = saved.result {
                    _ = try? await archive.attachWikipediaEnrichment(id: id, expectedResult: result, enrichment: entity39 ? C39EntityProbe.enrichment(result) : entity38 ? C38EntityProbe.enrichment(result) : modern ? C37CandidateProbe.enrichment(result) : C36TextProbe.enrichment(result))
                }
                if rich, let reference = C9RichShareChecks.reference(index) { _ = try? await archive.attachWikipedia(id: id, reference: reference) }
                if isProduct { _ = try? await archive.attachProductFacts(id: id, facts: C7FactsProbe.facts(productCode)) }
                if (isWiki || selectionLinks) && !ProcessInfo.processInfo.arguments.contains("--barcode-only") && !(index == 12 && ProcessInfo.processInfo.arguments.contains("--delayed-wiki")), let reference = C5WikipediaProbe.reference(index == 12 ? "雨傘" : "剪刀") {
                    _ = try? await archive.attachWikipedia(id: id, reference: reference)
                }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--legacy-rich-card") {
            // Reopen a v1 archive without newly added optional metadata. No migration write.
            let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for folder in folders {
                let file = folder.appendingPathComponent("record.json")
                if let bytes = try? Data(contentsOf: file), var object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
                    for key in ["barcodeDiagnostics", "imageSource", "attempts"] { object.removeValue(forKey: key) }
                    if var result = object["result"] as? [String: Any] { result.removeValue(forKey: "searchRestriction"); object["result"] = result }
                    try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: file)
                }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--missing-preview-image") || ProcessInfo.processInfo.arguments.contains("--corrupt-preview-image") {
            if let record = try? await model.archive.load().records.first {
                let file = root.appendingPathComponent(record.id.uuidString).appendingPathComponent("source.jpg")
                if ProcessInfo.processInfo.arguments.contains("--corrupt-preview-image") { try? Data([0, 1, 2]).write(to: file) }
                else { try? FileManager.default.removeItem(at: file) }
            }
        }
        await barcodeProbe.set(["0012345678905"])
        await model.bootstrap()
        if ProcessInfo.processInfo.arguments.contains("--focus-hint-preview") {
            _ = model.beginAcquisition()
            for time in [0.25, 0.5, 0.75] { FocusSelectionChecks.feed(self, at: time, color: .gray, quality: FocusSelectionChecks.blur) }
            clock.now = 3; model.updateAcquisitionWaitingHint()
        }
        if ProcessInfo.processInfo.arguments.contains("--photo-preview"), let selectionID = model.beginPhotoSelection() {
            _ = model.photoTransferStarted(id: selectionID)
            model.photoPickerDismissed(id: selectionID)
            _ = await model.prepareSelectedPhoto(Self.jpeg(.systemBlue), selectionID: selectionID)
        }
        selectionClipboardBaseline = UIPasteboard.general.changeCount
        prepared = true; status = "ready-\(model.records.count)"
        shareProbe.combinedPresented = { [weak self] text, url, count in
            guard let self else { return }; self.shareFile = url
            let jpeg = url.flatMap { try? Data(contentsOf: $0) }
            // Two cards may legitimately have identical text. Match the frozen
            // image as well so the probe verifies the selected card's pair.
            let selected = self.model.records.first { $0.shareText() == text && $0.imageSHA256 == jpeg.map { RecognitionArchive.hash($0) } }
            if ProcessInfo.processInfo.arguments.contains("--observe-copy") {
                self.copiedFixtureRecord = selected; self.clipboardChangeCount = UIPasteboard.general.changeCount
            }
            let linkMode = ProcessInfo.processInfo.arguments.contains("--share-links") || ProcessInfo.processInfo.arguments.contains("--product-links")
            let expectedSequence = ProcessInfo.processInfo.arguments.contains("--expect-share-11") ? 11 : 12
            let linksCorrect = !linkMode || (selected?.sequence == expectedSequence &&
                text.contains("Google 搜尋：" + (expectedSequence == 12 ? "雨傘" : "剪刀")) &&
                selected?.googleSearch?.googleURL.map { text.contains($0.absoluteString) } == true &&
                selected?.wikipedia.map { text.contains($0.canonicalURL.absoluteString) } == true)
            let productCorrect = !text.contains("Open Food Facts") && !text.contains("openfoodfacts.org") && !text.contains("ODbL") && !text.contains("DbCL")
            let fallbackMode = ProcessInfo.processInfo.arguments.contains("--fallback-links")
            let fallbackCorrect = !fallbackMode || (selected?.result?.searchQuery == nil && selected?.googleSearch?.query == (selected?.sequence == 12 ? "腹釋寧消化腸溶糖衣錠" : "腹釋寧消化") && selected?.googleSearch?.googleURL.map { text.contains($0.absoluteString) } == true && (selected?.sequence != 11 || text.contains("品名：腹釋寧消化\n諮詢電話：0800-388-100")))
            let modernCorrect = !ProcessInfo.processInfo.arguments.contains("--candidate37-links") || (selected?.sequence == expectedSequence && selected?.shareDocument().links.count == 5 && text.contains("原文參考：阿斯匹靈") && text.contains("維基百科：林範例"))
            let textCorrect = !ProcessInfo.processInfo.arguments.contains("--text-wiki-links") || (selected?.sequence == expectedSequence && selected?.shareDocument().links.count == 4 && text.contains("原文參考：摩訶止觀"))
            let entityCorrect = (!ProcessInfo.processInfo.arguments.contains("--entity38-links") && !ProcessInfo.processInfo.arguments.contains("--entity39-links")) || (selected?.sequence == expectedSequence && selected?.shareDocument().links.count == 2 && selected?.currentTextWikipedia().isEmpty == true && text.contains(expectedSequence == 12 ? "維基百科：曙光公司（製造商）" : "維基百科：曙光（品牌）"))
            let passed = entityCorrect && modernCorrect && textCorrect && productCorrect && fallbackCorrect && selected != nil && jpeg.map { RecognitionArchive.hash($0) } == selected?.imageSHA256 && count == 2 && linksCorrect
            self.status = passed ? "share-pair-correct" : "FAILED-share-pair"
            let report: [String:Any] = ["passed":passed,"selectedSequence":selected?.sequence ?? -1,"items":count,"sourceHashMatches":jpeg.map { RecognitionArchive.hash($0) } == selected?.imageSHA256,"fullTextMatches":selected != nil,"linksCorrect":linksCorrect,"fallbackCorrect":fallbackCorrect,"productCorrect":productCorrect,"sharedText":text]
            let file = self.root.deletingLastPathComponent().appendingPathComponent("c2-share.json")
            try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]).write(to:file)
        }
        if ProcessInfo.processInfo.arguments.contains("--entity39-links") || ProcessInfo.processInfo.arguments.contains("--entity38-links") || ProcessInfo.processInfo.arguments.contains("--candidate37-links") || ProcessInfo.processInfo.arguments.contains("--text-wiki-links") || ProcessInfo.processInfo.arguments.contains("--rich-share") || ProcessInfo.processInfo.arguments.contains("--glass-sample") || ProcessInfo.processInfo.arguments.contains("--fallback-rich-share") || ProcessInfo.processInfo.arguments.contains("--actein-sample") {
            shareProbe.itemsPresented = { [weak self] items, copyItems in
                guard let self, let file = self.shareFile,
                      let jpeg = try? Data(contentsOf: file),
                      let record = self.model.records.first(where: { $0.imageSHA256 == RecognitionArchive.hash(jpeg) }) else { return }
                Task { @MainActor in
                    let passed = await C9RichShareChecks.consume(items, copyItems: copyItems, record: record, jpeg: jpeg, root: self.root.deletingLastPathComponent())
                    self.status = passed && self.status == "share-pair-correct" ? "rich-share-passed" : "FAILED-rich-share"
                }
            }
        }
        shareProbe.shareFinished = { [weak self] in
            guard let self else { return }
            if self.status == "rich-share-passed" { self.status = self.shareFile.map { !FileManager.default.fileExists(atPath:$0.path) } == true ? "rich-share-clean" : "FAILED-rich-share-clean" }
            if self.status == "share-pair-correct" { self.status = self.shareFile.map { !FileManager.default.fileExists(atPath:$0.path) } == true ? "share-clean" : "FAILED-share-clean" }
        }
        if ProcessInfo.processInfo.arguments.contains("--observe-copy") {
            shareProbe.activityCompleted = { [weak self] kind, completed in
                guard let self, completed, kind == UIActivity.ActivityType.copyToPasteboard.rawValue,
                      let record = self.copiedFixtureRecord,
                      UIPasteboard.general.changeCount > self.clipboardChangeCount else { return }
                C9RichShareChecks.observeOwnCopy(record: record, root: self.root.deletingLastPathComponent())
                if ProcessInfo.processInfo.arguments.contains("--paste-receivers") {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(500))
                        if ProcessInfo.processInfo.arguments.contains("--explicit-copy-prototype"),
                           let jpeg = try? await self.model.archive.image(for: record) {
                            try? C9RichShareChecks.explicitCopyPrototype(record: record, jpeg: jpeg)
                            C9RichShareChecks.observeOwnCopy(record: record, root: self.root.deletingLastPathComponent())
                        }
                        guard let jpeg = try? await self.model.archive.image(for: record) else { self.status = "FAILED-copy-source"; return }
                        let passed = await C9RichShareChecks.observeReceivers(record: record, jpeg: jpeg, root: self.root.deletingLastPathComponent())
                        self.status = passed ? "copy-observed-\(record.sequence)" : "FAILED-copy-receivers-\(record.sequence)"
                    }
                } else { self.status = "copy-observed-\(record.sequence)" }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--image-share") { configureImageShareProbe() }
        if ProcessInfo.processInfo.arguments.contains("--json45") { configureJSON45Probe() }
    }
    static func json45Raw(_ index: Int) -> String? {
        if index == 10 { return "{broken 原始回覆 👩🏽‍🔬" }
        if index == 9 { return String(repeating: "a", count: 32769) }
        guard index == 12 else { return nil }
        let value: [String: Any] = ["schema_version": 16, "names": ["摩訶止觀"], "summary": "原始簡介，包含 Unicode 👩🏽‍🔬 日本語。", "text": (1...180).map { "第\($0)行 繁中日本語 👩🏽‍🔬 quote\" slash\\" }, "search_entities": []]
        return String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
    func configureJSON45Probe() {
        shareProbe.combinedPresented = nil
        shareProbe.itemsPresented = { [weak self] items, copyItems in
            guard let self else { return }
            let raw = self.model.records.first(where: { $0.sequence == 12 })!.combinedJSONShareText
            func jsonText(in view: UIView) -> UITextView? {
                if let text = view as? UITextView, text.accessibilityIdentifier == "modelJSONText" { return text }
                return view.subviews.lazy.compactMap { jsonText(in: $0) }.first
            }
            let views = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            let displayed = views.lazy.compactMap { jsonText(in: $0) }.first
            let scrollable = displayed.map { $0.contentSize.height > $0.bounds.height && $0.bounds.height > 100 } == true
            let scrolled = displayed.map { $0.contentOffset.y > 20 } == true
            let maximumType = ProcessInfo.processInfo.arguments.contains("--maximum-type")
            let expectedFont = UIFontMetrics(forTextStyle: .body).scaledValue(for: 15, compatibleWith: UITraitCollection(preferredContentSizeCategory: maximumType ? .accessibilityExtraExtraExtraLarge : .large))
            let actualFont = displayed?.font?.pointSize ?? 0
            let fontMatches = abs(actualFont - expectedFont) < 0.5
            let passed = fontMatches && items.count == 1 && items.first as? String == raw && copyItems.count == 1 &&
                Set(copyItems[0].keys) == [UTType.utf8PlainText.identifier] && copyItems[0][UTType.utf8PlainText.identifier] as? String == raw && scrollable && scrolled
            self.status = passed ? "json45-share-verified" : "FAILED-json45-share"
            let result: [String: Any] = ["passed": passed, "plainTextOnly": passed, "unicodeAndBytesPreserved": passed,
                "rawSHA256": RecognitionArchive.hash(Data(raw.utf8)), "rawByteCount": raw.utf8.count, "realNetworkRequests": C8NetworkProbe.shared.count,
                "longJSONScrollable": scrollable, "contentOffsetMoved": scrolled,
                "maximumType": maximumType, "actualFontPoints": actualFont, "expectedFontPoints": expectedFont, "fontMatchesRequestedType": fontMatches]
            try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]).write(to: self.root.deletingLastPathComponent().appendingPathComponent(maximumType ? "json45-maximum-share.json" : "json45-share.json"))
        }
        shareProbe.activityCompleted = { [weak self] kind, completed in
            guard let self, completed, kind == UIActivity.ActivityType.copyToPasteboard.rawValue else { return }
            // Read only this fixture's explicit, completed Copy result.
            let values = UIPasteboard.general.items
            let raw = self.model.records.first(where: { $0.sequence == 12 })!.combinedJSONShareText
            let value = values.first?[UTType.utf8PlainText.identifier]
            let text = (value as? String) ?? (value as? Data).flatMap { String(data: $0, encoding: .utf8) }
            let passed = self.status == "json45-share-verified" && values.count == 1 && values.first?.count == 1 && text == raw
            self.status = passed ? "json45-copy-verified" : "FAILED-json45-copy"
            let result: [String: Any] = ["passed": passed, "exactOriginalText": text == raw, "onlyUTF8PlainText": passed]
            try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: self.root.deletingLastPathComponent().appendingPathComponent(ProcessInfo.processInfo.arguments.contains("--maximum-type") ? "json45-maximum-copy.json" : "json45-copy.json"))
        }
    }
    func configureImageShareProbe() {
        let startAdd = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let startRead = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        shareProbe.combinedPresented = { [weak self] text, url, count in
            guard let self else { return }; self.shareFile = url
            let data = url.flatMap { try? Data(contentsOf: $0) }
            let record = self.model.records.first { $0.imageSHA256 == data.map(RecognitionArchive.hash) }
            self.imageShareSequence = record?.sequence ?? 0
            self.imageShareChecks = ["exact_source_JPEG": data.map(RecognitionArchive.hash) == record?.imageSHA256 && record != nil,
                "completed_record": record?.status == .succeeded, "image_only_no_text": count == 1 && text.isEmpty,
                "no_permission_requested_by_opening": startAdd == PHPhotoLibrary.authorizationStatus(for: .addOnly) && startRead == PHPhotoLibrary.authorizationStatus(for: .readWrite),
                "add_only_usage_present": Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") is String,
                "no_full_library_usage": Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") == nil]
        }
        shareProbe.itemsPresented = { [weak self] items, copyItems in
            guard let self, let file = self.shareFile, let data = try? Data(contentsOf: file) else { return }
            self.imageShareChecks["one_UIImage_exact_pixels"] = items.count == 1 && (items.first as? UIImage)?.pngData() == UIImage(data: data)?.pngData()
            self.imageShareChecks["one_JPEG_copy_item"] = copyItems.count == 1 && copyItems.first?[UTType.jpeg.identifier] as? Data == data
        }
        shareProbe.activityPresented = { [weak self] activity, button in
            guard let self else { return }
            self.imageShareChecks["save_activity_not_excluded"] = activity.excludedActivityTypes?.contains(.saveToCameraRoll) != true
            let popover = activity.popoverPresentationController
            self.imageShareChecks["popover_anchor_valid_or_phone_modal"] = UIDevice.current.userInterfaceIdiom != .pad || (popover?.sourceView === button && popover?.sourceRect == button.bounds && button.window != nil)
            self.recordImageShare("presented")
        }
        shareProbe.shareFinished = { [weak self] in
            guard let self else { return }
            self.imageShareChecks["temporary_JPEG_cleaned"] = self.shareFile.map { !FileManager.default.fileExists(atPath: $0.path) } == true
            self.recordImageShare("clean")
        }
        shareProbe.activityCompleted = { [weak self] kind, completed in
            guard let self, completed else { return }
            if kind == UIActivity.ActivityType.saveToCameraRoll.rawValue {
                self.imageShareChecks["system_save_completed"] = true
                self.imageShareChecks["read_access_not_granted"] = ![PHAuthorizationStatus.authorized, .limited].contains(PHPhotoLibrary.authorizationStatus(for: .readWrite))
                self.recordImageShare("saved")
            }
        }
    }
    func recordImageShare(_ stage: String) {
        let passed = imageShareChecks.values.allSatisfy { $0 }
        status = (passed ? "image-share-" : "FAILED-image-share-") + stage + "-\(imageShareSequence)"
        let report: [String: Any] = ["passed": passed, "checks": imageShareChecks, "sequence": imageShareSequence,
            "stage": stage, "physicalDevice": false, "realNetworkRequests": C8NetworkProbe.shared.count]
        let file = root.deletingLastPathComponent().appendingPathComponent("image-share-\(imageShareSequence)-\(stage).json")
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: file)
    }
    func completeDelayedWikipedia() async {
        guard let record = model.records.first(where: { $0.sequence == 12 }),
              let reference = C5WikipediaProbe.reference() else { return }
        _ = try? await model.archive.attachWikipedia(id: record.id, reference: reference)
        await model.reloadHistory(); status = "wiki-ready-12"
    }
    func appendRow() async {
        let id = UUID()
        _ = try? await model.archive.create(id:id,jpeg:Self.jpeg(.green),capturedAt:Date())
        _ = try? await model.archive.complete(id:id,result:.init(names:["新增但不跳頂"],summary:"新回覆"),message:nil)
        await model.reloadHistory(); status = "appended-\(model.records.count)"
    }
    func recordSearch(_ url: URL) {
        // Intercept only in this fixture. Never open Google or another app in tests.
        openedURLs.append(url.absoluteString)
        if ProcessInfo.processInfo.arguments.contains("--web-url-links") {
            status = "web-opened-\(openedURLs.count)-calls-\(calls)"; return
        }
        if let wiki = model.records.first(where: { $0.wikipedia?.canonicalURL == url }) {
            status = "wiki-correct-\(wiki.sequence)-calls-\(calls)"; return
        }
        if let text = model.records.first(where: { $0.currentTextWikipedia().contains { $0.canonicalURL == url } }) {
            status = "text-wiki-correct-\(text.sequence)-calls-\(calls)"; return
        }
        let match = model.records.first { $0.googleSearch?.googleURL == url }
        status = match.map { "search-correct-\($0.sequence)-calls-\(calls)" } ?? "search-wrong-card"
    }
    static func barcodeImage(_ value: String, turns: Int = 0) -> UIImage {
        let filter = CIFilter(name: "CICode128BarcodeGenerator")!
        filter.setValue(Data(value.utf8), forKey: "inputMessage")
        let output = filter.outputImage!
        let cg = CIContext().createCGImage(output, from: output.extent)!
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 768, height: 768), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 768, height: 768))
            context.cgContext.translateBy(x: 384, y: 384)
            context.cgContext.rotate(by: CGFloat(turns) * .pi / 2)
            context.cgContext.interpolationQuality = .none
            UIImage(cgImage: cg).draw(in: CGRect(x: -320, y: -100, width: 640, height: 200))
        }
    }
    func runBarcodeChecks() async -> [String:Bool] {
        var checks: [String:Bool] = [:]
        let payload = "0012345678905"
        // Only generated pixels enter this diagnostic; no camera, account, or private OCR.
        var diagnostic: [String: String] = [:]
        let sample = Self.barcodeImage(payload).jpegData(compressionQuality: 0.82)!
        for revision in VNDetectBarcodesRequest.supportedRevisions {
            let request = VNDetectBarcodesRequest(); request.revision = revision
            do {
                try VNImageRequestHandler(data: sample).perform([request])
                diagnostic["revision-\(revision)"] = String(describing: request.results?.compactMap(\.payloadStringValue) ?? [])
            } catch { diagnostic["revision-\(revision)"] = String(describing: error) }
        }
        let diagnosticURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("c3-vision-diagnostic.json")
        try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys, .prettyPrinted]).write(to: diagnosticURL)
        for turn in 0..<4 {
            let values = await SourceBarcodeDecoder.shared.decode(Self.barcodeImage(payload, turns: turn).jpegData(compressionQuality: 0.82)!)
            checks["vision_rotation_\(turn * 90)_preserves_leading_zero"] = values == [payload]
        }
        checks["vision_blank_does_not_guess"] = await SourceBarcodeDecoder.shared.decode(Self.jpeg(.white)).isEmpty
        checks["vision_invalid_data_does_not_guess"] = await SourceBarcodeDecoder.shared.decode(Data([1,2,3])).isEmpty
        let host = C2FixtureHost(name: "real-vision-source", realBarcodes: true)
        try? FileManager.default.removeItem(at: host.root); await host.model.bootstrap()
        _ = host.model.beginAcquisition(); host.feed(source: Self.barcodeImage(payload, turns: 1))
        await host.settle { host.waiter != nil }
        checks["decoded_before_AI_reply_and_persisted"] = host.model.records.first?.decodedBarcodes == [payload]
        checks["camera_path_persists_decision_and_targeted_pass"] = host.model.records.first?.barcodeDiagnostics?.observations.contains { $0.symbology == "code128" && $0.decision == .unsupportedSymbology } == true && host.model.records.first?.barcodeDiagnostics?.attempts.contains { $0.pass == .targetedEAN } == true
        checks["decoder_receives_exact_sent_JPEG"] = await host.barcodeProbe.lastJPEG == host.lastJPEG && host.lastJPEG != nil
        let firstID = host.model.records.first?.id
        await host.complete()
        checks["AI_other_barcode_cannot_replace_decoded_source"] = host.model.records.first?.result?.barcodes == [payload]
        checks["share_includes_source_barcode_and_same_id"] = host.model.records.first?.shareResult?.barcodes == [payload] && host.model.records.first?.shareResult?.sourceImageID == firstID
        _ = host.model.beginAcquisition(); host.feed(.green); await host.settle { host.waiter != nil }; await host.complete()
        checks["next_blank_capture_does_not_borrow_previous_or_AI_code"] = host.model.records.first?.barcodes.isEmpty == true && host.model.records.last?.barcodes == [payload]
        let saved = try? await RecognitionArchive(root: host.root).load()
        checks["decoded_values_survive_restart"] = saved?.records == host.model.records
        checks["one_AI_request_per_explicit_capture"] = host.calls == 2 && host.model.requestCount == 2
        host.model.closePreview()
        return checks
    }
    func runControllerChecks() async -> [String:Bool] {
        try? FileManager.default.removeItem(at: root)
        var check: [String:Bool] = [:]
        await model.bootstrap()
        check["preview_opens_without_capture_intent"] = starts == 1 && model.previewOpen && !model.acquiring && !model.capture.analysisGate.enabled
        feed(); check["reading_preview_does_not_reserve_or_send"] = calls == 0 && model.records.isEmpty
        check["one_explicit_press_arms"] = model.beginAcquisition()
        check["repeated_press_does_not_queue"] = !model.beginAcquisition()
        feed(.red); await settle { waiter != nil }
        let a = model.records.first
        check["durable_pending_cell_before_reply"] = a?.status == .pending && a?.canShare == false && calls == 1
        check["submitted_preview_is_exact_request_bytes_and_id"] = model.submittedPreview?.jpeg == lastJPEG && model.submittedPreview?.id == a?.id
        let submittedA = model.submittedPreview
        check["preview_stays_open_but_analysis_stops"] = model.previewOpen && !model.capture.analysisGate.enabled && stops == 0
        feed(.blue); check["further_frames_do_not_send"] = calls == 1 && model.records.count == 1
        check["later_frames_do_not_replace_submitted_preview"] = model.submittedPreview?.jpeg == submittedA?.jpeg && model.submittedPreview?.id == submittedA?.id
        check["cannot_continue_while_waiting"] = !model.beginAcquisition()
        await complete()
        let completedA = model.records.first
        check["completion_updates_original_cell"] = completedA?.id == a?.id && completedA?.status == .succeeded && completedA?.canShare == true
        check["success_releases_frozen_image_without_restarting_camera"] = model.submittedPreview == nil && starts == 1 && stops == 0
        check["completion_does_not_rearm"] = !model.acquiring && !model.capture.analysisGate.enabled && model.canContinue
        if let completedA { check["exact_sent_bytes_persisted"] = await model.image(for:completedA) == lastJPEG }
        for turn in 0..<4 {
            _ = model.beginAcquisition(); feed(); await settle { waiter != nil }
            let current = model.records.first
            check["next_preview_uses_own_id_\(turn)"] = model.submittedPreview?.id == current?.id && current?.id != a?.id
            await complete(fail: turn == 1, cancelled: turn == 2)
            if turn == 1 { check["failure_restores_live_without_arming_or_resending"] = model.submittedPreview == nil && model.canContinue && !model.acquiring && !model.capture.analysisGate.enabled && calls == 3 }
            if turn == 2 { check["cancellation_restores_live_without_arming_or_resending"] = model.submittedPreview == nil && model.canContinue && !model.acquiring && !model.capture.analysisGate.enabled && calls == 4 }
        }
        check["more_than_three_gestures_send_independent_requests"] = calls == 5 && model.records.count == 5
        check["timeout_keeps_own_row_and_releases_button"] = model.records.contains { $0.status == .failed } && model.canContinue
        _ = model.beginAcquisition(); feed(); await settle { waiter != nil }; let pending = model.records.first?.id
        let beforeStops = stops; model.foreground(.background)
        check["background_really_stops_camera_and_retains_pending"] = stops == beforeStops + 1 && !model.previewOpen && model.records.first?.id == pending
        let startsWhileBackground = starts
        await complete()
        check["late_background_reply_does_not_restart_or_arm"] = starts == startsWhileBackground && !model.previewOpen && !model.acquiring && model.submittedPreview == nil && !model.capture.analysisGate.enabled
        check["late_background_reply_is_saved"] = model.records.first?.status == .succeeded && model.records.first?.id == pending
        model.foreground(.active); await Task.yield()
        check["foreground_requires_explicit_preview_reopen"] = !model.previewOpen && !model.acquiring && starts == startsWhileBackground
        await model.openPreview(explicit: true)
        _ = model.beginAcquisition(); feed(); await settle { waiter != nil }
        let deadline = model.cycle.deadline!; clock.now = deadline; let stopsBeforeExpiry = stops
        model.checkPreviewDeadline()
        check["300_seconds_stops_capture_session"] = stops == stopsBeforeExpiry + 1 && !model.previewOpen && model.expired
        let startsWhileExpired = starts
        await complete()
        check["late_expired_reply_does_not_restart_or_arm"] = starts == startsWhileExpired && !model.previewOpen && !model.acquiring && model.submittedPreview == nil && !model.capture.analysisGate.enabled
        check["expiry_does_not_drop_paid_response"] = model.records.first?.status == .succeeded
        model.foreground(.active); await Task.yield()
        check["expiry_needs_explicit_reopen"] = !model.previewOpen
        await model.openPreview(explicit:true)
        check["explicit_reopen_is_not_auto_capture"] = model.previewOpen && !model.acquiring
        check["completion_event_is_specific_to_last_request"] = model.completionID == model.records.first?.id
        let expected = model.records
        model.closePreview(); let restarted = makeModel(); await restarted.bootstrap()
        check["new_controller_restores_all_rows"] = restarted.records == expected
        check["reload_does_not_emit_completion_scroll"] = restarted.completionID == nil
        restarted.closePreview()
        let focused = C2FixtureHost(name: "focus-before-send")
        try? FileManager.default.removeItem(at: focused.root); await focused.model.bootstrap()
        _ = focused.model.capture.focusGate.begin(session:focused.model.previewGeneration,autofocusSupported:true,adjusting:false,at:focused.clock.now)
        focused.delayValidation = true; _ = focused.model.beginAcquisition(); focused.feed(focus:true)
        await focused.settle { focused.holdBeforeSend != nil }
        _ = focused.model.capture.focusGate.update(adjusting:true,session:focused.model.previewGeneration,at:focused.clock.now)
        focused.holdBeforeSend?.resume();focused.holdBeforeSend=nil
        await focused.model.waitForCurrentWork()
        check["focus_change_before_transport_does_not_send"] = focused.calls == 0 && focused.model.records.first?.status == .failed
        check["focus_failure_releases_for_explicit_retry"] = focused.model.canContinue && focused.model.submittedPreview == nil && !focused.model.acquiring
        focused.model.closePreview()
        let disk = C2FixtureHost(name: "disk-failure")
        try? FileManager.default.removeItem(at: disk.root);await disk.model.bootstrap()
        _ = disk.model.beginAcquisition();disk.feed();await disk.settle { disk.waiter != nil }
        disk.writeFault.set(true);await disk.complete()
        let completionBeforeRetry = disk.model.completionID
        check["paid_reply_kept_in_memory_when_disk_write_fails"] = disk.model.records.first?.status == .succeeded && disk.model.storageError != nil
        check["disk_failure_blocks_new_request"] = !disk.model.beginAcquisition()
        check["unsaved_reply_keeps_own_frozen_preview_until_retry"] = disk.model.submittedPreview?.id == disk.model.records.first?.id
        disk.writeFault.set(false);await disk.model.retrySaving()
        check["saving_retry_does_not_repeat_completion_scroll"] = disk.model.completionID == completionBeforeRetry
        check["saving_retry_restores_safe_continuation"] = disk.model.storageError == nil && disk.model.canContinue && disk.model.submittedPreview == nil && !disk.model.acquiring
        let diskRows = try? await RecognitionArchive(root:disk.root).load().records
        check["saving_retry_persists_paid_reply"] = diskRows == disk.model.records
        disk.model.closePreview()
        // A permission request that completes after leaving foreground must not start a camera.
        var permissionWaiter: CheckedContinuation<Bool,Never>?
        let denied = makeModel(permission: { await withCheckedContinuation { permissionWaiter = $0 } })
        let attempt = Task { await denied.openPreview() }; await settle { permissionWaiter != nil }
        let startsBefore = starts; denied.foreground(.background); permissionWaiter?.resume(returning:true); await attempt.value
        check["late_permission_completion_does_not_start_camera"] = starts == startsBefore && !denied.previewOpen
        check["synthetic_controller_never_started_real_session"] = !model.capture.session.isRunning && !restarted.capture.session.isRunning
        return check
    }
}

@main struct C2FixtureApp: App {
    @State private var host = C2FixtureHost()
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--background62-checks") || ProcessInfo.processInfo.arguments.contains("--refresh62-ui") {
                Background62View()
            } else if ProcessInfo.processInfo.arguments.contains("--semantic45-checks") || ProcessInfo.processInfo.arguments.contains("--semantic45-ui") {
                Semantic45View()
                    .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--dark") ? .dark : .light)
                    .environment(\.dynamicTypeSize, ProcessInfo.processInfo.arguments.contains("--maximum-type") ? .accessibility5 : .large)
            }
            else if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--bounded-replay-") }) { BoundedReplayChecksView() }
            else if ProcessInfo.processInfo.arguments.contains("--history-deletion-checks") {
                HistoryDeletionChecksView()
            } else if ProcessInfo.processInfo.arguments.contains("--original-appearance-comparison") {
                OriginalAppearanceComparison()
            } else if ProcessInfo.processInfo.arguments.contains("--invalid-image-viewer") {
                RecognitionImageViewer(snapshot: .init(id: UUID(), jpeg: Data([0, 1, 2]), allowsImageSharing: true))
            } else if ProcessInfo.processInfo.arguments.contains("--scroll-collapse-checks") {
                ScrollCollapseChecksView()
            } else if ProcessInfo.processInfo.arguments.contains("--barcode-evidence-checks") {
                BarcodeEvidenceChecksView()
            } else if ProcessInfo.processInfo.arguments.contains("--focus-selection-checks") {
                FocusSelectionChecksView()
            } else if ProcessInfo.processInfo.arguments.contains("--photo-import-checks") {
                PhotoImportChecksView()
            } else if ProcessInfo.processInfo.arguments.contains("--original-image-retry-checks") {
                OriginalImageRetryChecksView()
            } else if ProcessInfo.processInfo.arguments.contains("--glass-barcode-checks") {
                Text(host.status).accessibilityIdentifier("glassBarcodeResult").task {
                    let checks = await host.runReportedGlassBarcodeChecks()
                    host.status = checks.values.allSatisfy { $0 } ? "passed \(checks.count)" : "FAILED " + checks.filter { !$0.value }.map(\.key).sorted().joined(separator: ",")
                }
            } else if ProcessInfo.processInfo.arguments.contains("--product-checks") {
                Text(host.status).accessibilityIdentifier("c7-product-result").task {
                    let checks = await host.runProductChecks()
                    let passed = checks.values.allSatisfy { $0 }
                    let report: [String: Any] = ["passed": passed, "checks": checks, "count": checks.count, "realNetworkRequests": 0]
                    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("c7-product.json")
                    try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: url)
                    host.status = passed ? "passed \(checks.count)" : "FAILED " + checks.filter { !$0.value }.map(\.key).sorted().joined(separator: ",")
                }
            } else if ProcessInfo.processInfo.arguments.contains("--entity41-checks") {
                Text(host.status).accessibilityIdentifier("c41-result").task {
                    let checks = await host.runEntity39Checks(version: 16), passed = checks.values.allSatisfy { $0 }
                    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("c41-entities.json")
                    try? JSONSerialization.data(withJSONObject: ["passed": passed, "checks": checks, "count": checks.count, "realNetworkRequests": 0], options: [.prettyPrinted, .sortedKeys]).write(to: url)
                    host.status = passed ? "passed \(checks.count)" : "FAILED " + checks.filter { !$0.value }.map(\.key).sorted().joined(separator: ",")
                }
            } else if ProcessInfo.processInfo.arguments.contains("--entity39-checks") {
                Text(host.status).accessibilityIdentifier("c39-result").task {
                    let checks = await host.runEntity39Checks(), passed = checks.values.allSatisfy { $0 }
                    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("c39-entities.json")
                    try? JSONSerialization.data(withJSONObject: ["passed": passed, "checks": checks, "count": checks.count, "realNetworkRequests": 0], options: [.prettyPrinted, .sortedKeys]).write(to: url)
                    host.status = passed ? "passed \(checks.count)" : "FAILED " + checks.filter { !$0.value }.map(\.key).sorted().joined(separator: ",")
                }
            } else if ProcessInfo.processInfo.arguments.contains("--entity38-checks") {
                Text(host.status).accessibilityIdentifier("c38-result").task {
                    let checks = await host.runEntity38Checks(), passed = checks.values.allSatisfy { $0 }
                    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("c38-entities.json")
                    try? JSONSerialization.data(withJSONObject: ["passed": passed, "checks": checks, "count": checks.count, "realNetworkRequests": 0], options: [.prettyPrinted, .sortedKeys]).write(to: url)
                    host.status = passed ? "passed \(checks.count)" : "FAILED " + checks.filter { !$0.value }.map(\.key).sorted().joined(separator: ",")
                }
            } else if ProcessInfo.processInfo.arguments.contains("--consent-checks") || ProcessInfo.processInfo.arguments.contains("--candidate37-checks") {
                Text(host.status).accessibilityIdentifier("c37-result").task {
                    let checks = ProcessInfo.processInfo.arguments.contains("--consent-checks") ? await host.runConsentChecks() : await host.runCandidate37Checks()
                    let passed = checks.values.allSatisfy { $0 }
                    let name = ProcessInfo.processInfo.arguments.contains("--consent-checks") ? "consent" : "candidates"
                    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("c37-" + name + ".json")
                    try? JSONSerialization.data(withJSONObject: ["passed": passed, "checks": checks, "count": checks.count], options: [.prettyPrinted, .sortedKeys]).write(to: url)
                    host.status = passed ? "passed \(checks.count)" : "FAILED " + checks.filter { !$0.value }.map(\.key).sorted().joined(separator: ",")
                }
            } else if ProcessInfo.processInfo.arguments.contains("--text-wiki-checks") {
                Text(host.status).accessibilityIdentifier("c36-text-wiki-result").task {
                    let checks = await host.runTextWikipediaChecks()
                    let passed = checks.values.allSatisfy { $0 }
                    let report: [String: Any] = ["passed": passed, "checks": checks, "count": checks.count, "realNetworkRequests": 0]
                    let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("c36-text-wiki.json")
                    try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: file)
                    host.status = passed ? "passed \(checks.count)" : "FAILED " + checks.filter { !$0.value }.map(\.key).sorted().joined(separator: ",")
                }
            } else if ProcessInfo.processInfo.arguments.contains("--wiki-checks") {
                Text(host.status).accessibilityIdentifier("c5-wiki-result").task {
                    let checks = await host.runWikipediaChecks(); let passed = checks.values.allSatisfy { $0 }
                    let report: [String: Any] = ["passed": passed, "checks": checks, "count": checks.count, "realNetworkRequests": 0]
                    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("c5-wiki.json")
                    try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: url)
                    host.status = passed ? "passed \(checks.count)" : "FAILED " + checks.filter { !$0.value }.map(\.key).sorted().joined(separator: ",")
                }
            } else if ProcessInfo.processInfo.arguments.contains("--visible-crop-checks") {
                VisibleCropChecksView()
            } else if ProcessInfo.processInfo.arguments.contains("--auth-recovery-checks") {
                AuthRecoveryChecksView()
            } else if ProcessInfo.processInfo.arguments.contains("--progress-layout") {
                RecognitionProgressFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--search-row-layout") {
                SearchRowLayoutFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--barcode-checks") {
                Text(host.status).accessibilityIdentifier("c3-barcode-result").task {
                    let checks = await host.runBarcodeChecks(); let passed = checks.values.allSatisfy { $0 }
                    let report: [String:Any] = ["passed":passed,"checks":checks,"count":checks.count,"cameraStarted":false,"realNetworkRequests":0]
                    let url = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("c3-barcodes.json")
                    try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:url)
                    host.status = passed ? "passed \(checks.count)" : "FAILED " + checks.filter { !$0.value }.map(\.key).sorted().joined(separator:",")
                }
            } else if ProcessInfo.processInfo.arguments.contains("--controller-checks") {
                Text(host.status).accessibilityIdentifier("c2-controller-result").task {
                    let checks = await host.runControllerChecks(); let passed = checks.values.allSatisfy { $0 }
                    let report: [String:Any] = ["passed":passed,"checks":checks,"count":checks.count,"cameraStarted":false,"realNetworkRequests":0]
                    let url = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("c2-controller.json")
                    try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:url)
                    host.status = passed ? "passed \(checks.count)" : "FAILED " + checks.filter { !$0.value }.map(\.key).sorted().joined(separator:",")
                }
            } else {
                VStack(spacing:0) {
                    if !ProcessInfo.processInfo.arguments.contains("--production-layout") {
                    HStack {
                        Text(host.status).font(.caption).accessibilityIdentifier("c2-fixture-status")
                            .accessibilityValue(host.openedURLsJSON)
                        if ProcessInfo.processInfo.arguments.contains("--onboarding-ui") { Text("login-\(host.loginCalls)").accessibilityIdentifier("mockLoginCount") }
                        if ProcessInfo.processInfo.arguments.contains("--web-url-links") {
                            Button("核對網址複製") { host.status = UIPasteboard.general.string == C2FixtureHost.webHTTP ? "web-copy-correct" : "FAILED-web-copy" }.accessibilityIdentifier("verifyWebCopy")
                        }
                        Button("影格") { host.feed() }.accessibilityIdentifier("feedFrames")
                        Button("回覆") { Task { await host.complete() } }.accessibilityIdentifier("completeReply")
                        Button("新增") { Task { await host.appendRow() } }.accessibilityIdentifier("appendRow")
                    }.environment(\.dynamicTypeSize, .large)
                    if ProcessInfo.processInfo.arguments.contains("--actions56") {
                        HStack {
                            Text("calls-\(host.calls)").accessibilityIdentifier("actions56-calls")
                            Button("允許合成送出") {
                                host.delayValidation = false
                                host.holdBeforeSend?.resume(); host.holdBeforeSend = nil
                            }.accessibilityIdentifier("actions56-dispatch")
                        }
                    }
                    if ProcessInfo.processInfo.arguments.contains("--preview-stability") || ProcessInfo.processInfo.arguments.contains("--progress-checks") {
                        Button("失敗回覆") { Task { await host.complete(fail: true) } }.accessibilityIdentifier("failReply")
                    }
                    if ProcessInfo.processInfo.arguments.contains("--progress-checks") {
                        Button("取消回覆") { Task { await host.complete(cancelled: true) } }.accessibilityIdentifier("cancelReply")
                    }
                    if ProcessInfo.processInfo.arguments.contains("--scroll-ui") {
                        HStack {
                            Text("camera-\(host.starts)-\(host.stops)-calls-\(host.calls)-collapsed-\(host.model.previewCollapsed)")
                                .font(.caption2).accessibilityIdentifier("scrollState")
                            Button("合成選圖") { Task {
                                guard let id = host.model.beginPhotoSelection() else { return }
                                _ = host.model.photoTransferStarted(id: id)
                                host.model.photoPickerDismissed(id: id)
                                _ = await host.model.prepareSelectedPhoto(C2FixtureHost.jpeg(.green), selectionID: id)
                            } }.accessibilityIdentifier("selectSyntheticPhoto")
                        }.environment(\.dynamicTypeSize, .large)
                    }
                    if ProcessInfo.processInfo.arguments.contains("--deletion-ui") {
                        HStack {
                            Text("records-\(host.model.records.count)-busy-\(host.model.busy)").font(.caption2).accessibilityIdentifier("deletionState")
                            Button("核對檔案") { Task { await host.inspectDeletionFiles() } }.accessibilityIdentifier("inspectDeletionFiles")
                            Text(host.deletionFileStatus).font(.caption2).accessibilityIdentifier("deletionFileStatus")
                        }.environment(\.dynamicTypeSize, .large)
                    }
                    if ProcessInfo.processInfo.arguments.contains("--selection-ui") {
                        HStack {
                            Text(host.selectionStatus).lineLimit(1).frame(width: 100).accessibilityIdentifier("selectionStatus")
                            if ProcessInfo.processInfo.arguments.contains("--selection-drag") {
                                Button("座標") { host.selectionDragGeometry() }.accessibilityIdentifier("selectionDragGeometry")
                                Button("文字座標") { host.selectionTextGeometry() }.accessibilityIdentifier("selectionTextGeometry")
                            }
                            Button("原文座標") { host.originalDisclosureGeometry() }.accessibilityIdentifier("originalDisclosureGeometry")
                            Button("局部") { host.inspectSelection(copied: true, partial: true) }.accessibilityIdentifier("inspectPartialCopy")
                            Button("核對複製") { host.inspectSelection(copied: true) }.accessibilityIdentifier("inspectSelectionCopy")
                        }.font(.caption2).environment(\.dynamicTypeSize, .large)
                    }
                    if ProcessInfo.processInfo.arguments.contains("--darkness-ui") {
                        Button("合成全黑") { CameraDarknessChecks.blackout(host) }.accessibilityIdentifier("blackCamera")
                    }
                    if ProcessInfo.processInfo.arguments.contains("--action-row-checks") {
                        Text("calls-\(host.calls)").font(.caption).accessibilityIdentifier("actionRowCalls")
                    }
                    if ProcessInfo.processInfo.arguments.contains("--delayed-wiki") {
                        Button("完成百科") { Task { await host.completeDelayedWikipedia() } }.accessibilityIdentifier("finishWiki")
                    }
                    }
                    if host.prepared {
                        if ProcessInfo.processInfo.arguments.contains("--legacy-web-result") {
                            RecognitionResultCard(result: C2FixtureHost.webResult, isPrevious: false, initiallyExpanded: true)
                        } else {
                        SingleCaptureView(model:host.model,shareProbe:host.shareProbe,motionAllowed: !ProcessInfo.processInfo.arguments.contains("--reduce-motion"))
                            .frame(maxWidth: ProcessInfo.processInfo.arguments.contains("--narrow-actions") ? 320 : .infinity)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }.task { await host.prepareUI() }
                    .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--dark") ? .dark : .light)
                    .environment(\.dynamicTypeSize,ProcessInfo.processInfo.arguments.contains("--maximum-type") ? .accessibility5 : .large)
                    .environment(\.openURL, OpenURLAction { url in host.recordSearch(url); return .handled })
            }
        }
    }
}

/// The production label without Link combining its accessibility children.
/// 296 pt is the content width of a 320 pt card with production 12 pt padding.
private struct SearchRowLayoutFixture: View {
    private let args = ProcessInfo.processInfo.arguments
    private var keyword: String {
        if args.contains("--unbroken-query") { return String(repeating: "ABCDEFGHIJ", count: 12) }
        return "Acme C++ & 台灣高山烏龍茶 AB-001 精選系列 #12"
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                RecognitionReferenceLabel(text: "Google 搜尋：" + keyword).accessibilityIdentifier("googleReferenceLabel")
                RecognitionReferenceLabel(text: "維基百科：" + keyword + "（品牌）").accessibilityIdentifier("wikiReferenceLabel")
            }
                .padding(12)
                .frame(width: args.contains("--narrow-row") ? 320 : 390)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("searchLayoutCard")
        }
        .environment(\.dynamicTypeSize, args.contains("--maximum-type") ? .accessibility5 : .large)
    }
}

private struct RecognitionProgressFixture: View {
    private let args = ProcessInfo.processInfo.arguments
    @State private var inactive = false
    var body: some View {
        VStack(spacing: 24) {
            Button("切換生命週期") { inactive.toggle() }.accessibilityIdentifier("toggleProgressLifecycle")
            Text(inactive ? "inactive" : "active").accessibilityIdentifier("progressLifecycle")
            Button {} label: { RecognitionActionLabel(title: "開始辨識") }
                .buttonStyle(RecognitionActionButtonStyle()).accessibilityIdentifier("readyButton")
            Button {} label: { RecognitionActionLabel(title: "等待停穩 1 秒") }
                .buttonStyle(RecognitionActionButtonStyle()).disabled(true).accessibilityIdentifier("acquiringButton")
            Button {} label: { RecognitionActionLabel(title: "開始辨識", pending: true, motionAllowed: !args.contains("--reduce-motion")) }
                .buttonStyle(RecognitionActionButtonStyle(pending: true)).disabled(true)
                .accessibilityIdentifier("progressButton")
                .environment(\.scenePhase, inactive ? .inactive : .active)
            RecognitionPendingBadge(motionAllowed: !args.contains("--reduce-motion")).padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityIdentifier("progressCard")
                .environment(\.scenePhase, inactive ? .inactive : .active)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .preferredColorScheme(args.contains("--dark") ? .dark : .light)
        .environment(\.dynamicTypeSize, args.contains("--maximum-type") ? .accessibility5 : .large)
    }
}


extension C2FixtureHost {
    private func selectionTextViews() -> [RecognitionTextView] {
        func descendants(_ view: UIView) -> [RecognitionTextView] {
            (view as? RecognitionTextView).map { [$0] } ?? view.subviews.flatMap(descendants)
        }
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).flatMap(descendants)
    }
    func originalDisclosureGeometry() {
        guard let view = selectionTextViews().first(where: { $0.accessibilityIdentifier == "archiveText-12" }), let frame = view.originalChevronFrame else {
            selectionStatus = "geometry-no-original"; return
        }
        let rect = view.convert(frame, to: nil)
        let coordinates: [Double] = [Double(rect.midX), Double(rect.midY)]
        selectionStatus = String(data: try! JSONEncoder().encode(coordinates), encoding: .utf8)!
    }
    func selectionDragGeometry() {
        guard let view = selectionTextViews().first(where: { $0.accessibilityIdentifier == "archiveText-12" }),
              let selection = view.selectedTextRange else { selectionStatus = "geometry-no-selection"; return }
        let target = (view.textStorage.string as NSString).range(of: "Original 12")
        guard target.location != NSNotFound, let position = view.position(from: view.beginningOfDocument, offset: view.textStorage.length) else { selectionStatus = "geometry-no-target"; return }
        selectionDragInitialLength = view.selectedRange.length
        let startRect = view.convert(view.caretRect(for: selection.end), to: nil)
        let targetRect = view.convert(view.caretRect(for: position), to: nil)
        let coordinates = [startRect.midX, startRect.maxY + 4, targetRect.midX, targetRect.maxY + 12]
        selectionStatus = String(data: try! JSONEncoder().encode(coordinates), encoding: .utf8)!
    }
    func selectionTextGeometry() {
        guard let view = selectionTextViews().first(where: { $0.accessibilityIdentifier == "archiveText-12" }) else {
            selectionStatus = "geometry-no-text"; return
        }
        let rect = view.convert(view.bounds, to: nil)
        selectionStatus = String(data: try! JSONEncoder().encode([rect.minX, rect.minY, rect.width, rect.height]), encoding: .utf8)!
    }
    func inspectSelection(copied: Bool, partial: Bool = false) {
        func descendants(_ view: UIView) -> [RecognitionTextView] {
            (view as? RecognitionTextView).map { [$0] } ?? view.subviews.flatMap(descendants)
        }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let view = windows.flatMap(descendants).first(where: { $0.accessibilityIdentifier == "archiveText-12" }) else {
            selectionStatus = "selection-view-missing"; return
        }
        let range = view.selectedRange
        guard range.length > 0, NSMaxRange(range) <= view.textStorage.length else { selectionStatus = "selection-empty"; return }
        let expected = view.textStorage.attributedSubstring(from: range).string
        var checks: [String: Bool] = [
            "selection_scope": partial ? range.length < view.textStorage.length && (ProcessInfo.processInfo.arguments.contains("--selection-drag") ? range.length > selectionDragInitialLength && expected.contains("原文\nOrig") : !expected.contains("Original 12")) : ["已保存第 12 張", "這是合成說明", "原文", "Original 12"].allSatisfy(expected.contains),
            "does_not_include_another_card": !expected.contains("已保存第 11 張") && !expected.contains("Original 11"),
            "production_text_view_is_selectable_read_only_non_scrolling": view.isSelectable && !view.isEditable && !view.isScrollEnabled,
            "bound_to_same_card": view.recordID == model.records.first(where: { $0.sequence == 12 })?.id,
            "no_model_or_camera": calls == 0 && !model.capture.session.isRunning && C8NetworkProbe.shared.count == 0,
            "text_fits_height": view.sizeThatFits(CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude)).height <= view.bounds.height + 2
        ]
        if ProcessInfo.processInfo.arguments.contains("--selection-links") {
            let record = model.records.first(where: { $0.sequence == 12 })
            checks["both_external_links_present"] = record?.googleSearch?.googleURL != nil &&
                record?.result.map { result in record?.wikipedia?.isCurrent(for: result) == true } == true
            checks["external_open_URL_count_zero"] = openedURLs.isEmpty
        }
        var ancestor = view.superview
        while let current = ancestor, !(current is UICollectionViewCell), !(current is UITableViewCell) { ancestor = current.superview }
        let cellBounds = ancestor?.bounds ?? .zero
        let frameInCell = ancestor.map { view.convert(view.bounds, to: $0) } ?? .null
        if ProcessInfo.processInfo.arguments.contains("--selection-long"), !partial {
            checks["long_actual_text_height"] = view.bounds.height > 600
            checks["long_text_contained_inside_list_cell"] = ancestor != nil && frameInCell.minY >= -2 && frameInCell.maxY <= cellBounds.height + 2
            checks["all_thirty_original_paragraphs_selected"] = range.location == 0 && range.length == view.textStorage.length && expected.components(separatedBy: "長文段落").count == 31
        }
        if copied {
            guard UIPasteboard.general.changeCount != selectionClipboardBaseline else { selectionStatus = "copy-not-performed"; return }
            // Only inspect our own synthetic selection after the user's test Copy.
            let items = UIPasteboard.general.items
            let value = items.first?[UTType.utf8PlainText.identifier]
            let text = (value as? String) ?? (value as? Data).flatMap { String(data: $0, encoding: .utf8) }
            checks["native_copy_exact_selected_text"] = text == expected
            let richValue = items.first?[UTType.rtf.identifier]
            let richData = (richValue as? Data) ?? (richValue as? String).map { Data($0.utf8) }
            let rich = richData.flatMap { try? NSAttributedString(data: $0, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) }
            var links = 0
            rich?.enumerateAttribute(.link, in: NSRange(location: 0, length: rich?.length ?? 0)) { value, _, _ in if value != nil { links += 1 } }
            checks["selection_copy_no_image"] = items.count == 1 && items.first?[UTType.jpeg.identifier] == nil
            checks["selection_copy_RTF_exact_text"] = rich?.string == expected
            checks["selection_copy_RTF_no_disclosure_URL"] = rich != nil && links == 0
            let details: [String: Any] = ["itemTypes": items.map { $0.mapValues { String(describing: type(of: $0)) } }, "selectedText": expected, "richText": rich?.string as Any? ?? NSNull(), "richLinkCount": links]
            try? JSONSerialization.data(withJSONObject: details, options: [.sortedKeys, .prettyPrinted]).write(to: root.deletingLastPathComponent().appendingPathComponent("selection-synthetic-format-details.json"))
        }
        let report: [String: Any] = ["checks": checks, "copied": copied, "range": [range.location, range.length], "fontPointSize": (view.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize ?? 0,
            "actualTextHeight": view.bounds.height, "requiredTextHeight": view.sizeThatFits(CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude)).height, "cellHeight": cellBounds.height, "textBottomInCell": frameInCell.maxY, "textViewCount": windows.flatMap(descendants).count, "passed": checks.values.allSatisfy { $0 }, "realNetworkRequests": C8NetworkProbe.shared.count]
        let file = root.deletingLastPathComponent().appendingPathComponent(partial ? (ProcessInfo.processInfo.arguments.contains("--selection-drag") ? "selection-handle-drag-checks.json" : "selection-partial-copy-checks.json") : ProcessInfo.processInfo.arguments.contains("--selection-long") ? "selection-long-copy-checks.json" : copied ? "selection-copy-checks.json" : "selection-range-checks.json")
        try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: file)
        selectionStatus = checks.values.allSatisfy { $0 } ? (partial ? "selection-partial-passed" : copied ? "selection-copy-passed" : "selection-range-passed") : "selection-failed-" + checks.filter { !$0.value }.map(\.key).joined(separator: ",")
    }
}


/// Exact Build31 text/disclosure structure, next to the production text component.
/// Synthetic text only; no controller, camera, account, archive, or network work.
struct OriginalAppearanceComparison: View {
    @State private var baselineExpanded = false
    @State private var candidateExpanded = false
    @State private var geometry = "pending"
    @State private var baselineNamesHeight: CGFloat = 0
    private let result = RecognitionResult(names: ["Alpha 合成名稱", "Beta 第二行"], summary: "第一段說明\n第二段說明", text: ["Original line one\n日本語第二行"])
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Build31 baseline").font(.caption)
                Text(result.names.joined(separator: "\n")).font(.headline).textSelection(.enabled).accessibilityIdentifier("baselineNames")
                    .background { GeometryReader { proxy in Color.clear.onAppear { baselineNamesHeight = proxy.size.height }.onChange(of: proxy.size.height) { _, value in baselineNamesHeight = value } } }
                Text(result.summary).textSelection(.enabled)
                DisclosureGroup("原文", isExpanded: $baselineExpanded) {
                    Text(result.text.joined(separator: "\n")).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.accessibilityIdentifier("baselineOriginal")
            }.padding(12).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 10) {
                Text("Build33 candidate").font(.caption)
                RecognitionSelectableText(result: result, recordID: UUID(uuidString: "00000000-0000-0000-0000-000000000033")!, sequence: 33, originalExpanded: $candidateExpanded)
            }.padding(12).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            Button("核對幾何") { inspectGeometry() }.accessibilityIdentifier("originalComparisonInspect")
            Text(geometry).font(.caption).accessibilityIdentifier("originalComparisonGeometry")
            Spacer()
        }.padding(16)
    }
    private func inspectGeometry() {
        func descendants(_ view: UIView) -> [RecognitionTextView] {
            (view as? RecognitionTextView).map { [$0] } ?? view.subviews.flatMap(descendants)
        }
        let views = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).flatMap(descendants)
        guard let view = views.first(where: { $0.accessibilityIdentifier == "archiveText-33" }), let frame = view.originalChevronFrame,
              let start = view.position(from: view.beginningOfDocument, offset: 0),
              let end = view.position(from: start, offset: (result.names.joined(separator: "\n") as NSString).length),
              let range = view.textRange(from: start, to: end) else { geometry = "missing"; return }
        let nameBounds = view.selectionRects(for: range).reduce(CGRect.null) { $0.union($1.rect) }
        let arrow = view.convert(frame, to: nil)
        let font = view.textStorage.attribute(.font, at: 0, effectiveRange: nil) as! UIFont
        // A selection highlight includes descender extents; SwiftUI reports its
        // text layout box. One font descender is the bound for that difference,
        // and still rejects the unwanted extra 10 points between name lines.
        let allowance = abs(font.descender)
        let values: [Double] = [Double(arrow.midX), Double(arrow.midY), Double(nameBounds.height), Double(baselineNamesHeight), Double(allowance)]
        geometry = String(data: try! JSONEncoder().encode(values), encoding: .utf8)!
        let report: [String: Any] = ["baselineTextLayoutHeight": baselineNamesHeight, "candidateSelectionRectHeight": nameBounds.height,
            "selectionExtentAllowance": allowance, "nameLineSpacingEquivalent": abs(nameBounds.height - baselineNamesHeight) <= allowance,
            "headingHasNoAddedStateWords": !view.textStorage.string.contains("原文（"),
            "arrowNotPartOfSelectableText": !view.textStorage.string.contains("\u{FFFC}"), "arrowVisible": true,
            "physicalDeviceOperations": 0, "realNetworkRequests": 0]
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("original-appearance-checks.json")
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: file)
    }
}

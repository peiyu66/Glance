import Foundation
import Testing
@testable import GlanceCore

@Test func markdownLinksRoundTripLabelsAndEncodedDestinations() throws {
    let labels = ["Google 搜尋：Lay’s 樂事 樂連連原味", "標題[限定](原味)", "日本語「商品」 C++ & 100% #1",
                  #"括號 ](https://example.invalid) [ \ *強調* _底線_ `code` !<tag> &copy;"#]
    let urls = [URL(string: "https://zh.wikipedia.org/wiki/Example_(brand)")!,
                PublicSearchQuery(query: "Lay’s [限定](原味) C++ & 日本語", category: "product")!.googleURL!]
    for label in labels {
        for url in urls {
            let link = RecognitionShareDocument.Link(label: label, url: url)
            let parsed = try AttributedString(markdown: link.markdown)
            #expect(String(parsed.characters) == label)
            let destinations = parsed.runs.compactMap(\.link)
            #expect(destinations.count == 1)
            let restored = try #require(destinations.first)
            let a = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let b = try #require(URLComponents(url: restored, resolvingAgainstBaseURL: false))
            #expect(a.scheme == b.scheme && a.host == b.host && a.path == b.path && a.queryItems == b.queryItems)
            #expect(link.markdown.hasPrefix("[") && link.markdown.hasSuffix(")"))
            #expect(!link.markdown.contains("/Example_(brand)"))
        }
    }
}

@Test func markdownBodyRemainsVerbatimAndWikiLabelAppearsOnce() {
    let body = "日本語\r\n [原文](不是連結)  <原樣> 👩🏽‍🔬"
    let url = URL(string: "https://zh.wikipedia.org/wiki/%E4%B9%90%E4%BA%8B")!
    let link = RecognitionShareDocument.Link(label: "維基百科：樂事（品牌）", url: url)
    let document = RecognitionShareDocument(body: body, links: [link])
    #expect(document.plainText == body + "\n\n[維基百科：樂事（品牌）](" + url.absoluteString + ")")
    #expect(document.plainText.components(separatedBy: link.label).count == 2)
    #expect(document.displayText == body + "\n\n" + link.label)
    #expect(!document.displayText.contains(url.absoluteString))
}

@Test func barcodeProvenanceNeverPromotesUntypedDigits() {
    typealias Observation = SourceBarcodeDiagnostics.Observation
    let code = "4713213242926"
    for pass in [SourceBarcodeDiagnostics.Pass.general, .targetedEAN] {
        for symbology in ["qr", "code128", "upce", "unknown"] {
            let row = Observation(value: code, symbology: symbology, pass: pass)
            #expect(row.decision == .unsupportedSymbology && row.product == nil)
        }
        for invalid in ["4713213242927", "123", "0000000000000", "2000000000008", "０４７１３２１３２４２９２６"] {
            let row = Observation(value: invalid, symbology: "ean13", pass: pass)
            #expect(row.decision == .invalidProductCode && row.product == nil)
        }
        let valid = Observation(value: code, symbology: "ean13", pass: pass)
        #expect(valid.decision == .acceptedProduct && valid.product?.value == code)
        #expect(Observation(value: "  ", symbology: "ean13", pass: pass).decision == .emptyPayload)
    }
}

@Test func barcodeDiagnosticsPersistWithoutChangingLegacyEligibility() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID()
    let code = "4713213242926"
    let general = SourceBarcodeDiagnostics.Observation(value: code, symbology: "qr", pass: .general)
    let targeted = SourceBarcodeDiagnostics.Observation(value: code, symbology: "ean13", pass: .targetedEAN)
    let diagnostics = SourceBarcodeDiagnostics(observations: [general, targeted], attempts: [
        .init(pass: .general, orientation: 1, revision: 1, observationCount: 1),
        .init(pass: .targetedEAN, orientation: 1, revision: 1, observationCount: 1)])
    _ = try await archive.create(id: id, jpeg: Data([1, 2]), capturedAt: Date(), decodedBarcodes: [code],
        productBarcodes: [try #require(targeted.product)], barcodeDiagnostics: diagnostics)
    _ = try await archive.complete(id: id, result: .init(names: ["玻璃杯"], searchQuery: PublicSearchQuery(query: "玻璃杯", category: "object")), message: nil)
    let current = try #require(try await RecognitionArchive(root: root).load().records.first)
    #expect(current.barcodeDiagnostics == diagnostics && current.googleSearch?.query == "玻璃杯 " + code)
    var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
    old.removeValue(forKey: "barcodeDiagnostics"); old["productBarcodes"] = []
    let bytes = try JSONSerialization.data(withJSONObject: old, options: .sortedKeys)
    let legacy = try JSONDecoder().decode(ArchivedRecognition.self, from: bytes)
    #expect(legacy.barcodeDiagnostics == nil && legacy.googleSearch?.query == "玻璃杯")
    // A diagnostic alone is never used to mint eligibility or rewrite an old card.
    var withAudit = legacy; withAudit.barcodeDiagnostics = diagnostics
    #expect(withAudit.googleSearch?.query == "玻璃杯")
    #expect(legacy.decodedBarcodes == [code] && legacy.productBarcodes == [])
}

@Test func publicDrugPromptSeparatesManualSearchFromPrivateRecordsAndWiki() throws {
    #expect(CameraAnswer.promptRevision == "P20-English-concise-entity-zhTW1")
    for reason in ["sensitive", "conflict", "uncertain"] {
        let raw = try JSONSerialization.data(withJSONObject: ["names": ["Actein 顆粒"], "summary": "", "text": [], "barcodes": [],
            "search": ["query": "Actein 顆粒", "category": "product"], "search_block_reason": reason, "wikipedia": NSNull()])
        let result = try CameraAnswer.parse(String(decoding: raw, as: UTF8.self))
        #expect(result.searchQuery == nil && result.searchRestriction != nil)
    }
}

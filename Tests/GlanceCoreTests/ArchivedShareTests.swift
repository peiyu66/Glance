import Foundation
import Testing
@testable import GlanceCore

private let shareDate = Date(timeIntervalSince1970: 1_800_000_000)
private func linkedResult(_ name: String = "雨傘") -> RecognitionResult {
    .init(names: [name], summary: "原本的完整簡介", text: ["日本語\r\n  Original 👩🏽‍🔬  "], barcodes: ["00123"],
          searchQuery: PublicSearchQuery(query: name, category: "object", automaticWikipediaAllowed: true))
}
private func linkedReference(_ name: String = "雨傘") throws -> WikipediaReference {
    let subject = try #require(WikipediaSubject.matching(linkedResult(name)))
    let page: [String: Any] = ["pageid": 123, "ns": 0, "title": name,
        "canonicalurl": "https://zh.wikipedia.org/wiki/" + name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!,
        "extract": "\(name)是一種日常使用的工具與用品。"]
    return try #require(subject.reference(from: JSONSerialization.data(withJSONObject: ["query": ["pages": [page]]]), at: shareDate))
}
private func card(_ result: RecognitionResult? = linkedResult(), wiki: WikipediaReference? = nil) -> ArchivedRecognition {
    .init(schemaVersion: 1, id: UUID(), sequence: 1, capturedAt: shareDate, imageSHA256: "fixture", imageByteCount: 1,
          status: .succeeded, result: result, message: nil, completedAt: shareDate, wikipedia: wiki)
}

@Test func archivedSharePreservesTextAndAppendsFullEncodedURLs() throws {
    let reference = try linkedReference(), record = card(wiki: reference)
    let original = try #require(record.shareResult?.shareText)
    let google = try #require(record.result?.searchQuery?.googleURL?.absoluteString)
    #expect(record.shareText(at: shareDate) == original + "\n\n[Google 搜尋：雨傘](" + google + ")\n\n[維基百科：雨傘](" + reference.canonicalURL.absoluteString + ")")
    #expect(!record.shareText(at: shareDate).contains(reference.extract))
    let query = try #require(PublicSearchQuery(query: "C++ & 耐熱 100% #1", category: "product"))
    let document = card(.init(names: ["測試"], searchQuery: query)).shareDocument(at: shareDate)
    let url = try #require(document.links.first?.url)
    #expect(document.plainText.contains(document.links[0].markdown))
    #expect(url.scheme == "https" && url.fragment == nil)
    #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [.init(name: "q", value: query.query), .init(name: "gl", value: "tw")])
}

@Test func archivedShareOmitsMissingLinksAndSupportsLegacyAndBarcodeOnlyCards() throws {
    let legacy = try JSONDecoder().decode(RecognitionResult.self, from: Data(#"{"names":["舊卡"],"summary":"簡介","text":["原文"],"barcodes":[]}"#.utf8))
    #expect(card(legacy).shareText(at: shareDate) == legacy.shareText)
    var noGoogle = card(.init(names: ["雨傘"], wikipediaTopics: .init(category: .object, automaticWikipediaAllowed: true,
        classTerms: ["用品"], candidates: [.init(topic: "雨傘", kind: .subject, evidence: "雨傘")])) )
    let subject = try #require(WikipediaSubject.matching(noGoogle.result!))
    let page: [String: Any] = ["pageid": 1, "ns": 0, "title": "雨傘", "canonicalurl": "https://zh.wikipedia.org/wiki/傘", "extract": "雨傘是一種用於遮蔽雨水的日常用品。"]
    noGoogle.wikipedia = try #require(subject.reference(from: JSONSerialization.data(withJSONObject: ["query": ["pages": [page]]]), at: shareDate))
    #expect(noGoogle.shareText(at: shareDate).contains("[維基百科：雨傘](https://"))
    #expect(!noGoogle.shareText(at: shareDate).contains("Google"))
    var barcode = card(nil); barcode.decodedBarcodes = ["00123"]; barcode.status = .failed
    #expect(barcode.shareText(at: shareDate) == "【條碼】\n\n00123")
    barcode.status = .pending
    #expect(barcode.shareText(at: shareDate).isEmpty)
}

@Test func archivedShareRevalidatesWikiExpiryIdentityAndSafeCanonicalURL() throws {
    let reference = try linkedReference(), record = card(wiki: reference)
    for date in [shareDate.addingTimeInterval(-1), shareDate.addingTimeInterval(WikipediaReference.lifetime)] {
        #expect(!record.shareText(at: date).contains("維基百科"))
        #expect(record.shareText(at: date).contains("Google 搜尋"))
    }
    #expect(!card(linkedResult("剪刀"), wiki: reference).shareText(at: shareDate).contains("維基百科"))
    for raw in ["http://zh.wikipedia.org/wiki/雨傘", "https://example.test/wiki/雨傘", "https://user@zh.wikipedia.org/wiki/雨傘", "https://zh.wikipedia.org/wiki/雨傘?x=1", "https://zh.wikipedia.org/wiki/雨傘#x"] {
        var data = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(reference)) as? [String: Any])
        data["canonicalURL"] = raw
        let unsafe = try JSONDecoder().decode(WikipediaReference.self, from: JSONSerialization.data(withJSONObject: data))
        #expect(!card(wiki: unsafe).shareText(at: shareDate).contains("維基百科"))
    }
}

@Test func archivedShareRefreshesLateWikiOnOwnPersistedCardWithoutChangingEarlierSnapshot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), a = UUID(), b = UUID()
    _ = try await archive.create(id: a, jpeg: Data([1]), capturedAt: shareDate)
    _ = try await archive.create(id: b, jpeg: Data([2]), capturedAt: shareDate)
    let initial = try await archive.complete(id: a, result: linkedResult(), message: nil)
    _ = try await archive.complete(id: b, result: linkedResult("剪刀"), message: nil)
    let snapshot = initial.shareText(at: shareDate)
    _ = try await archive.attachWikipedia(id: a, reference: linkedReference(), at: shareDate)
    let loaded = try await RecognitionArchive(root: root).load().records
    let current = try #require(loaded.first { $0.id == a })
    #expect(!snapshot.contains("維基百科"))
    #expect(current.shareText(at: shareDate).contains("維基百科：雨傘"))
    #expect(!current.shareText(at: shareDate).contains("剪刀"))
    #expect(loaded.first { $0.id == b }?.shareText(at: shareDate).contains("維基百科") == false)
    #expect(current.shareResult?.sourceImageID == a)
    #expect(current.imageSHA256 == RecognitionArchive.hash(Data([1])))
}

@Test func wikiDisplayTitleKeepsBrandAndSeriesScopeInline() throws {
    var reference = try linkedReference()
    #expect(reference.displayTitle == "雨傘")
    for (kind, suffix) in [(WikipediaTopics.Kind.brand, "（品牌）"), (.series, "（系列）"), (.subject, "")] {
        reference.relation = .init(kind: kind, classTerm: "用品", relatedTopic: nil, definition: "合成定義", relation: nil)
        #expect(reference.displayTitle == "雨傘" + suffix)
    }
}

@Test func namedShareLinksHideURLsOnlyInRichDisplayAndEscapeOriginalText() throws {
    let name = "曼秀雷敦 AD 高效抗乾修復乳液"
    let query = try #require(PublicSearchQuery(query: name, category: "product"))
    let original = "日本語\r\n  <script>alert('x')</script> & \"Original\" 👩🏽‍🔬  "
    let record = card(.init(names: [name], text: [original], barcodes: ["00123"], searchQuery: query))
    let document = record.shareDocument(at: shareDate)
    #expect(document.displayText.contains(original))
    #expect(document.displayText.hasSuffix("Google 搜尋：" + name))
    #expect(!document.displayText.contains("https://") && !document.displayText.contains("%E"))
    #expect(document.plainText.contains(query.googleURL!.absoluteString))
    #expect(document.html.contains("&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt; &amp; &quot;Original&quot;"))
    #expect(!document.html.contains("<script>"))
    #expect(document.html.components(separatedBy: "<a href=").count == 2)
    #expect(document.body.contains("【條碼】\n\n00123"))
    #expect(record.result?.text == [original])
}

@Test func simplifiedWikiTitleOnlyChangesPresentation() throws {
    let reference = try linkedReference("乐事")
    #expect(reference.displayTitle == "樂事")
    #expect(reference.title == "乐事")
    #expect(reference.canonicalURL.path.hasSuffix("乐事"))
    let document = card(linkedResult("乐事"), wiki: reference).shareDocument(at: shareDate)
    #expect(document.links.last?.label == "維基百科：樂事")
    #expect(document.links.last?.url == reference.canonicalURL)
    var branded = reference
    branded.relation = .init(kind: .brand, classTerm: "洋芋片", relatedTopic: nil, definition: "合成定義", relation: nil)
    #expect(branded.displayTitle == "樂事（品牌）")
}

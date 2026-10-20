import Foundation
import Testing
@testable import GlanceCore

private let topicDate = Date(timeIntervalSince1970: 1_800_000_000)
private func topicResult(series: String? = "脆浪", brand: String = "晴禾", classes: [String] = ["洋芋片"], allowed: Bool = true) -> RecognitionResult {
    let names = [series.map { "\(brand) \($0) 原味洋芋片" } ?? "\(brand) 原味洋芋片"]
    var candidates: [WikipediaTopics.Candidate] = [.init(topic: brand, kind: .brand, evidence: names[0])]
    if let series { candidates.append(.init(topic: series, kind: .series, evidence: names[0])) }
    return .init(names: names, summary: "合成產品摘要", text: ["不要外送的完整原文"],
                 searchQuery: PublicSearchQuery(query: names[0], category: "product"),
                 wikipediaTopics: .init(category: .product, automaticWikipediaAllowed: allowed, classTerms: classes, candidates: candidates))
}
private func topicSubject(_ result: RecognitionResult = topicResult()) -> WikipediaSubject { WikipediaSubject.matching(result, allowLegacy: false)! }
private func topicPayload(_ pages: [[String: Any]]) throws -> Data { try JSONSerialization.data(withJSONObject: ["query": ["pages": pages]]) }
private func topicPage(_ title: String = "晴禾", extract: String = "晴禾是洋芋片品牌。晴禾旗下產品包括脆浪系列。", id: Int = 123, extra: [String: Any] = [:]) -> [String: Any] {
    var page: [String: Any] = ["pageid": id, "ns": 0, "title": title, "canonicalurl": "https://zh.wikipedia.org/wiki/" + title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!, "extract": extract]
    page.merge(extra, uniquingKeysWith: { _, value in value }); return page
}
@Test func wikiTopicsSeparateGoogleQueryAndUseSeriesFirstWithoutSendingClues() throws {
    let result = topicResult(), subject = topicSubject(result)
    #expect(subject.searchTitle == "脆浪" && subject.candidateCount == 2)
    #expect(subject.query(at: 1) == "晴禾")
    #expect(result.searchQuery?.query == "晴禾 脆浪 原味洋芋片")
    for index in 0..<2 {
        let request = subject.request(at: index)
        let items = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(request.url?.host == "zh.wikipedia.org" && request.httpBody == nil)
        #expect(items.first { $0.name == "gsrsearch" }?.value == subject.query(at: index))
        #expect(!items.contains { ($0.value ?? "").contains("原文") || ($0.value ?? "").contains("原味") })
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }
    #expect(CameraAnswer.promptRevision == "P20-English-concise-entity-zhTW1")
}
@Test func wikiTopicsParseInSameAnswerAndMalformedHintsKeepGoogleAndText() throws {
    let hints = try JSONSerialization.jsonObject(with: JSONEncoder().encode(topicResult().wikipediaTopics!))
    var wire: [String: Any] = ["names": topicResult().names, "summary": "完整摘要", "text": ["完整原文"], "barcodes": [], "search": ["query": "晴禾 脆浪 原味洋芋片", "category": "product"], "wikipedia": hints]
    func parse() throws -> RecognitionResult { try CameraAnswer.parse(String(decoding: JSONSerialization.data(withJSONObject: wire), as: UTF8.self)) }
    #expect(try parse().wikipediaTopics != nil)
    #expect(try WikipediaSubject.matching(parse(), allowLegacy: false) != nil)
    for value: Any in [NSNull(), ["class_terms": "bad"], ["automatic_wikipedia": "true"], "invalid"] {
        wire["wikipedia"] = value
        let answer = try parse()
        #expect(answer.wikipediaTopics == nil && answer.summary == "完整摘要" && answer.text == ["完整原文"] && answer.searchQuery != nil)
    }
}
@Test func wikiTopicsRequireConsentExactCluesSafeTermsAndBoundedRoles() {
    #expect(WikipediaSubject.matching(topicResult(allowed: false), allowLegacy: false) == nil)
    let examples: [WikipediaTopics] = [
        .init(category: .product, automaticWikipediaAllowed: true, classTerms: ["洋芋片"], candidates: [.init(topic: "其他品牌", kind: .brand, evidence: "晴禾 原味洋芋片")]),
        .init(category: .product, automaticWikipediaAllowed: true, classTerms: ["洋芋片"], candidates: [.init(topic: "晴禾", kind: .brand, evidence: "晴禾")]),
        .init(category: .product, automaticWikipediaAllowed: true, classTerms: ["洋芋片"], candidates: [.init(topic: "晴禾", kind: .subject, evidence: "晴禾 原味洋芋片")]),
        .init(category: .object, automaticWikipediaAllowed: true, classTerms: [], candidates: [.init(topic: "晴禾", kind: .subject, evidence: "晴禾 原味洋芋片")]),
        .init(category: .product, automaticWikipediaAllowed: true, classTerms: ["洋芋片", "洋芋片"], candidates: [.init(topic: "晴禾", kind: .brand, evidence: "晴禾 原味洋芋片")])
    ]
    for hints in examples {
        #expect(WikipediaSubject.matching(.init(names: ["晴禾 原味洋芋片"], wikipediaTopics: hints), allowLegacy: false) == nil)
    }
    for name in ["未知品牌", "不確定品牌", "可能品牌", "處方藥", "a@example.test", "intitle:晴禾", "Kellen"] {
        let clue = name == "Kellen" ? "Kellens" : name
        let result = RecognitionResult(names: [clue], wikipediaTopics: .init(category: .product, automaticWikipediaAllowed: true, classTerms: ["食品"], candidates: [.init(topic: name, kind: .brand, evidence: clue)]))
        #expect(WikipediaSubject.matching(result, allowLegacy: false) == nil)
    }
}
@Test func wikiTopicsSeriesAndBrandNeedClassAndPositiveRelationship() throws {
    let subject = topicSubject()
    let series = topicPage("脆浪", extract: "脆浪是晴禾旗下的洋芋片產品系列。")
    let first = try #require(subject.reference(from: topicPayload([series]), at: topicDate))
    #expect(first.relation?.kind == .series && first.relation?.relatedTopic == "晴禾")
    let brand = try #require(subject.reference(from: topicPayload([topicPage()]), at: topicDate, candidateIndex: 1))
    #expect(brand.title == "晴禾" && brand.relation?.label == "品牌參考")
    #expect(brand.isCurrent(for: topicResult(), at: topicDate))
    for extract in ["晴禾是洗衣精品牌。晴禾旗下有脆浪系列。", "晴禾是洋芋片品牌。其競爭對手是脆浪品牌。", "晴禾不是洋芋片品牌，脆浪與其無關。", "晴禾是洋芋片品牌，脆浪不屬於晴禾系列。", "晴禾是洋芋片品牌，在超市販售。"] {
        #expect(subject.reference(from: try topicPayload([topicPage(extract: extract)]), at: topicDate, candidateIndex: 1) == nil)
    }
}
@Test func wikiTopicsExactSeriesAliasesTraditionalChineseAndUnlistedBrands() throws {
    let result = topicResult(series: "乐连连", brand: "乐事")
    let subject = topicSubject(result)
    let page = topicPage("樂連連", extract: "樂連連是樂事旗下的洋芋片系列產品。")
    #expect(subject.reference(from: try topicPayload([page]), at: topicDate)?.match == .exactTitle)
    let alias = topicPage("Lay's Stax", extract: "Lay's Stax 是樂事旗下的洋芋片系列產品，又稱樂連連。", extra: ["redirects": [["title": "樂連連", "ns": 0]]])
    #expect(subject.reference(from: try topicPayload([alias]), at: topicDate)?.match == .exactRedirect)
    let unrelated = topicPage("樂連連（樂團）", extract: "樂連連是一個使用洋芋片名稱的音樂團體。")
    #expect(subject.reference(from: try topicPayload([unrelated]), at: topicDate) == nil)
    let arbitrary = topicResult(series: nil, brand: "山澄")
    #expect(topicSubject(arbitrary).reference(from: try topicPayload([topicPage("山澄", extract: "山澄是製作洋芋片及其他零食的品牌。")]), at: topicDate)?.relation?.kind == .brand)
}
@Test func wikiTopicsRejectExactPeopleAndUnknownPages() throws {
    let result = topicResult(series: nil, brand: "Kellens", classes: ["食品"]), subject = topicSubject(result)
    let person = topicPage("Kellens", extract: "Kellens 是一位作家，曾撰寫食品與品牌方面的書籍。", extra: ["categories": [["title": "Category:作家"]]])
    #expect(subject.reference(from: try topicPayload([person]), at: topicDate) == nil)
    let surname = topicPage("Kellens", extract: "Kellens 是食品品牌名稱的來源，亦用於多個地區。", extra: ["categories": [["title": "Category:姓氏"]]])
    #expect(subject.reference(from: try topicPayload([surname]), at: topicDate) == nil)
    #expect(subject.reference(from: try topicPayload([]), at: topicDate) == nil)
    #expect(subject.reference(from: try topicPayload([topicPage("Kellen", extract: "Kellen 是食品品牌，販售多種點心。")]), at: topicDate) == nil)
}
private actor TopicTransport {
    var requests: [URLRequest] = []; let responses: [Data]; let status: Int
    init(_ responses: [Data], status: Int = 200) { self.responses = responses; self.status = status }
    func fetch(_ request: URLRequest) throws -> WikipediaHTTPResponse {
        requests.append(request)
        guard requests.count <= responses.count else { throw URLError(.badServerResponse) }
        return .init(data: responses[requests.count - 1], status: status, url: request.url)
    }
}
@Test func wikiTopicsFallbackUsesAtMostTwoCandidatesAndOneBoundedPageExtract() async throws {
    let subject = topicSubject(), intro = topicPage(extract: "晴禾是製作洋芋片及其他零食的品牌。")
    let full = topicPage(extract: "晴禾是洋芋片品牌。\n\n脆浪\n\n脆浪是本品牌的洋芋片系列產品。")
    let transport = TopicTransport([try topicPayload([]), try topicPayload([intro]), try topicPayload([full])])
    let service = WikipediaLookupService(transport: { try await transport.fetch($0) }, now: { topicDate })
    let reference = try #require(await service.lookup(subject))
    #expect(reference.title == "晴禾" && reference.relation?.kind == .brand && reference.isCurrent(for: topicResult(), at: topicDate))
    let requests = await transport.requests
    #expect(requests.count == 3)
    let last = try #require(URLComponents(url: requests[2].url!, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(last.first { $0.name == "pageids" }?.value == "123")
    #expect(last.first { $0.name == "exchars" } == nil)
    #expect(last.first { $0.name == "exlimit" }?.value == "1")
    #expect(last.first { $0.name == "exintro" } == nil)
    #expect(last.first { $0.name == "gsrsearch" } == nil)
    #expect(await service.lookup(subject) == reference)
    #expect(await transport.requests.count == 3)
}
@Test func wikiTopicsOneExtensionBudgetCannotBeReusedOnBrandFallback() async throws {
    let subject = topicSubject()
    let series = topicPage("脆浪", extract: "脆浪是洋芋片系列產品，提供數種口味。")
    let brand = topicPage(extract: "晴禾是洋芋片品牌，提供數種口味。")
    let transport = TopicTransport([try topicPayload([series]), try topicPayload([series]), try topicPayload([brand])])
    let service = WikipediaLookupService(transport: { try await transport.fetch($0) }, now: { topicDate })
    #expect(await service.lookup(subject) == nil)
    #expect(await transport.requests.count == 3)
    #expect(await service.lookup(subject) == nil)
    #expect(await transport.requests.count == 3)
}
@Test func wikiTopicsHTTPErrorStopsInsteadOfTryingBrand() async throws {
    let transport = TopicTransport([try topicPayload([])], status: 503)
    let service = WikipediaLookupService(transport: { try await transport.fetch($0) })
    #expect(await service.lookup(topicSubject()) == nil)
    #expect(await transport.requests.count == 1)
}
private actor CancellableTopicTransport {
    var calls = 0; var cancelled = false
    func fetch(_ request: URLRequest) async throws -> WikipediaHTTPResponse {
        calls += 1
        do { try await Task.sleep(for: .seconds(60)); throw URLError(.unknown) }
        catch { cancelled = Task.isCancelled; throw error }
    }
}
@Test func wikiTopicsSharedDeadlineCancelsTransportAndSkipsFallback() async {
    let transport = CancellableTopicTransport()
    let service = WikipediaLookupService(transport: { try await transport.fetch($0) }, lookupTimeout: .milliseconds(100))
    #expect(await service.lookup(topicSubject()) == nil)
    #expect(await transport.calls == 1)
    #expect(await transport.cancelled)
}
@Test func wikiTopicsExternalCancellationCancelsTransport() async {
    let transport = CancellableTopicTransport(), subject = topicSubject()
    let service = WikipediaLookupService(transport: { try await transport.fetch($0) })
    let task = Task { await service.lookup(subject) }
    for _ in 0..<1000 { if await transport.calls > 0 { break }; await Task.yield() }
    task.cancel()
    #expect(await task.value == nil)
    #expect(await transport.calls == 1)
    #expect(await transport.cancelled)
}
@Test func wikiTopicsCacheIncludesClassAndRelationshipAndMetadataSurvivesCodable() throws {
    #expect(topicSubject().key != topicSubject(topicResult(classes: ["清潔用品"])).key)
    #expect(topicSubject().key != topicSubject(topicResult(series: "其他系列")).key)
    let result = topicResult().withSourceImage(UUID()).withBarcodes(["0012"])
    #expect(try JSONDecoder().decode(RecognitionResult.self, from: JSONEncoder().encode(result)) == result)
    var data = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
    data["wikipediaTopics"] = ["candidates": "broken"]
    let restored = try JSONDecoder().decode(RecognitionResult.self, from: JSONSerialization.data(withJSONObject: data))
    #expect(restored.names == result.names && restored.sourceImageID == result.sourceImageID && restored.wikipediaTopics == nil)
    data.removeValue(forKey: "wikipediaTopics")
    #expect(try JSONDecoder().decode(RecognitionResult.self, from: JSONSerialization.data(withJSONObject: data)).wikipediaTopics == nil)
}
@Test func wikiTopicsReferencesPersistOnlyOnTheirOwnResultAndOldLinksRemainReadable() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID(), other = UUID()
    let result = topicResult(), subject = topicSubject(result)
    let reference = try #require(subject.reference(from: topicPayload([topicPage()]), at: topicDate, candidateIndex: 1))
    _ = try await archive.create(id: id, jpeg: Data([1]), capturedAt: topicDate)
    _ = try await archive.complete(id: id, result: result, message: nil)
    _ = try await archive.create(id: other, jpeg: Data([2]), capturedAt: topicDate)
    _ = try await archive.complete(id: other, result: topicResult(series: nil, brand: "山澄"), message: nil)
    _ = try await archive.attachWikipedia(id: id, reference: reference, at: topicDate)
    await #expect(throws: (any Error).self) { try await archive.attachWikipedia(id: other, reference: reference, at: topicDate) }
    let restored = try await RecognitionArchive(root: root).load().records
    #expect(restored.first { $0.id == id }?.wikipedia == reference)
    #expect(restored.first { $0.id == other }?.wikipedia == nil)
    let old = RecognitionResult(names: ["雨傘"], searchQuery: PublicSearchQuery(query: "雨傘", category: "object", automaticWikipediaAllowed: true))
    let legacy = try #require(WikipediaSubject.matching(old)?.reference(from: topicPayload([topicPage("雨傘", extract: "雨傘是一種遮蔽雨水或陽光的日常用品。")]), at: topicDate))
    var stored = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]); stored.removeValue(forKey: "relation")
    let oldLink = try JSONDecoder().decode(WikipediaReference.self, from: JSONSerialization.data(withJSONObject: stored))
    #expect(oldLink.isCurrent(for: old, at: topicDate) && WikipediaSubject.matching(old, allowLegacy: false) == nil)
}
@Test func wikiTopicsExtendedExtractMustBeSameSinglePageAndBounded() throws {
    let subject = topicSubject()
    let initial = topicPage(extract: "晴禾是洋芋片品牌，提供數種口味。")
    let page = try #require(subject.page(from: topicPayload([initial]), at: 1))
    #expect(subject.needsExtendedExtract(page))
    for replacement in [topicPage("其他品牌"), topicPage(id: 999), topicPage(extract: String(repeating: "字", count: 6501)), topicPage(extract: "<b>晴禾</b>是洋芋片品牌。") ] {
        #expect(subject.extendedExtract(from: try topicPayload([replacement]), for: page) == nil)
    }
    #expect(subject.extendedExtract(from: try topicPayload([initial, initial]), for: page) == nil)
}
@Test func wikiTopicsCategoriesSupplementDefinitionWithoutAuthorizingHumanPages() throws {
    let subject = topicSubject(topicResult(series: nil))
    let good = topicPage(extract: "晴禾是銷售各種口味零食的品牌。", extra: ["categories": [["title": "Category:洋芋片品牌"]]])
    #expect(subject.reference(from: try topicPayload([good]), at: topicDate) != nil)
    let vague = topicPage(extract: "晴禾於某年開始活動，後來逐漸受到注意。", extra: ["categories": [["title": "Category:洋芋片品牌"]]])
    #expect(subject.reference(from: try topicPayload([vague]), at: topicDate) == nil)
    let person = topicPage(extract: "晴禾是某企業的品牌創辦者，從事食品工作。", extra: ["categories": [["title": "Category:企業家"], ["title": "Category:洋芋片品牌"]]])
    #expect(subject.reference(from: try topicPayload([person]), at: topicDate) == nil)
}

@Test func wikiTopicsContradictionVetoesEarlierPositiveSentenceAndFurtherExtraction() throws {
    let subject = topicSubject()
    let bytes = try topicPayload([topicPage(extract: "晴禾是洋芋片品牌。晴禾旗下有脆浪系列。脆浪不屬於晴禾品牌。")])
    let page = try #require(subject.page(from: bytes, at: 1))
    #expect(subject.reference(page, at: topicDate) == nil)
    #expect(!subject.needsExtendedExtract(page))
    #expect(subject.reference(page, fullExtract: "晴禾旗下有脆浪系列。", at: topicDate) == nil)
}

@Test func wikiTopicsFullArticleKeepsOnlyBoundedCompletePrefix() throws {
    let subject = topicSubject()
    let initial = topicPage(extract: "晴禾是洋芋片品牌，提供數種口味。")
    let page = try #require(subject.page(from: topicPayload([initial]), at: 1))
    let text = String(repeating: "背景文字。", count: 1100) + String(repeating: "字", count: 1100) + "晴禾旗下有脆浪系列。"
    let prefix = try #require(subject.extendedExtract(from: topicPayload([topicPage(extract: text)]), for: page))
    #expect(prefix.count <= 6000 && prefix.hasSuffix("。"))
    #expect(!prefix.contains("脆浪"))
    #expect(subject.reference(page, fullExtract: prefix, at: topicDate) == nil)
    for index in 0..<subject.candidateCount {
        let items = try #require(URLComponents(url: subject.request(at: index).url!, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "exchars" }?.value == "1200")
    }
}

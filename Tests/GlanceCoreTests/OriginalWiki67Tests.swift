import Foundation
import Testing
@testable import GlanceCore

private func result67(_ name: String = "アサヒ生ビール マルエフ", newer: Bool = true) throws -> RecognitionResult {
    let brand = newer ? "アサヒ生ビール" : "アサヒビール"
    let entities = [SearchEntity(id: 0, role: .central, kind: .product, name: name, aliases: [name], sourceText: name),
        SearchEntity(id: 1, role: .related, kind: .brand, name: brand, aliases: [newer ? "アサヒ" : "Asahi Beer"], sourceText: "アサヒ生ビール", relation: .brand_of, relatedTo: 0)]
    let json: [String: Any] = ["schema_version": 17, "names": [name], "summary": "固定辨識輸出，非真模型驗收。", "text": [name, "アサヒ生ビール"],
        "search_entities": try JSONSerialization.jsonObject(with: JSONEncoder().encode(entities))]
    return try CameraAnswer.parse(String(decoding: JSONSerialization.data(withJSONObject: json), as: UTF8.self), expectingStructured: true)
}

private actor MultiTransport67 {
    var requests: [URLRequest] = []
    let exact: Bool
    init(exact: Bool = true) { self.exact = exact }
    func fetch(_ request: URLRequest) throws -> WikipediaHTTPResponse {
        requests.append(request)
        let q = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        let host = request.url!.host!
        func page(_ id: Int, _ title: String, _ index: Int) -> [String: Any] {
            ["ns": 0, "pageid": id, "title": title, "index": index, "canonicalurl": "https://\(host)/wiki/Fixture_\(id)",
             "extract": "\(title) 原文合成首段，不能當作真實身份驗收。\n\n" + String(repeating: "\(title) 是合成資料，", count: 200)]
        }
        var pages: [[String: Any]] = []
        if let titles = q["titles"], exact { pages = titles.components(separatedBy: "|").enumerated().map { page($0.offset + 1, $0.element, $0.offset + 1) } }
        if let term = q["gsrsearch"] { pages = (1...3).reversed().map { page($0, term + " \($0)", $0) } }
        // No extra network or synthetic full document: exercise intro fallback.
        if q["pageids"] != nil { throw URLError(.resourceUnavailable) }
        return .init(data: try JSONSerialization.data(withJSONObject: ["query": ["pages": pages]]), status: 200, url: request.url)
    }
}
private func multiResult67(_ names: [String], aliases: Bool = false) -> RecognitionResult {
    .init(names: [names[0]], text: names, searchContractVersion: 17, searchEntities: names.enumerated().map { i, name in
        .init(id: i, role: i == 0 ? .central : .text, kind: .object, name: name,
              aliases: aliases ? [name + " Alias"] : [], sourceText: name)
    })
}

@Suite struct OriginalWiki67Edges {
    @Test func scriptSelectionIsLocalAndConservativeForMixedOrUnknownNames() {
        for (name, expected) in [("アサヒ生ビール", WikipediaEdition.ja), ("ASAHI マルエフ", .ja), ("ｱｻﾋ", .ja),
                                 ("中文品牌 ABC", .zh), ("東京", .zh), ("한국 맥주", .ko), ("アサヒ 한글", .zh),
                                 ("123", .zh), ("AB", .zh), ("اللغة العربية", .zh), ("University of California", .zh), ("Company Name", .en)] {
            #expect(WikipediaEdition.forName(name) == expected, "\(name)")
        }
    }
    @Test func onlyTwoEditionsAreSentAndThirdEditionIsExplicitlySkipped() async throws {
        let r = multiResult67(["アサヒ", "中文候選", "한국", "Company Name"]), t = MultiTransport67()
        let c = try await WikipediaReviewCollector(transport: { try await t.fetch($0) }).collectWithDiagnostics(for: r)
        #expect(c.plannedTerms.count == 4)
        #expect(c.skippedTerms.map(\.value) == ["한국", "Company Name"])
        #expect(c.sources.map(\.id) == ["jawiki:1", "zhwiki:1"])
        let requests = await t.requests
        #expect(Set(requests.map { $0.url!.host! }) == ["ja.wikipedia.org", "zh.wikipedia.org"])
        #expect(requests.count == 4)
    }
    @Test func crossWikiMergeRetainsEqualPageIDsAndFiveSourceCap() async throws {
        let r = multiResult67(["アサヒ", "中文品牌", "日本語", "中文系列"], aliases: true), t = MultiTransport67()
        let c = try await WikipediaReviewCollector(transport: { try await t.fetch($0) }).collectWithDiagnostics(for: r)
        #expect(c.sources.count == 5 && Set(c.sources.map(\.id)).count == 5)
        #expect(c.sources.prefix(2).map(\.id) == ["jawiki:1", "zhwiki:1"])
        #expect(c.exactMatches.count == 8 && c.fullTextTerms.isEmpty)
        #expect(await t.requests.count == 7)
    }
    @Test func totalSearchBudgetStaysTwoAndAliasesDoNotGainFullTextQueries() async throws {
        let r = multiResult67(["アサヒ", "中文品牌", "日本語", "中文系列"], aliases: true), t = MultiTransport67(exact: false)
        let c = try await WikipediaReviewCollector(transport: { try await t.fetch($0) }).collectWithDiagnostics(for: r)
        #expect(c.fullTextTerms.map(\.value) == ["アサヒ", "中文品牌"])
        #expect(c.sources.count == 5 && Set(c.sources.map(\.id)).count == 5)
        let requests = await t.requests
        #expect(requests.count == 9)
        for request in requests {
            let q = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            if q.contains(where: { $0.name == "gsrsearch" }) { #expect(q.contains { $0.name == "gsrlimit" && $0.value == "3" }) }
            #expect(request.timeoutInterval == 6)
            #expect(q.contains { $0.name == "variant" } == (request.url!.host == "zh.wikipedia.org"))
        }
        let input = try WikipediaSemanticReview.input(result: r, rawStageOne: nil, sources: c.sources)
        #expect(input.count < 128_000)
        let root = try JSONSerialization.jsonObject(with: input) as! [String: Any]
        for source in root["sources"] as! [[String: Any]] {
            let excerpts = source["excerpts"] as! [[String: String]]
            #expect(excerpts.count <= 3 && excerpts.reduce(0) { $0 + $1["text"]!.unicodeScalars.count } <= 1200)
        }
    }
    @Test func officialHostsAreExactAndLegacyValidatorRemainsChineseOnly() {
        for edition in WikipediaEdition.allCases { #expect(WikipediaEdition.from(URL(string: "https://\(edition.host)/wiki/Example")!) == edition) }
        for url in ["http://ja.wikipedia.org/wiki/A", "https://ja.wikipedia.org.evil.example/wiki/A", "https://ja.m.wikipedia.org/wiki/A", "https://user@ja.wikipedia.org/wiki/A", "https://ja.wikipedia.org:443/wiki/A", "https://ja.wikipedia.org/wiki/A?x=1", "https://ja.wikipedia.org/wiki/A#x", "https://evil.example/wiki/A", "https://ja.wikipedia.org/w/api.php"] {
            #expect(WikipediaEdition.from(URL(string: url)!) == nil)
        }
        #expect(!WikipediaReference.allowedURL(source67().url))
    }
    @Test func sourceIdentityBindsCitationToItsOwnEdition() throws {
        let ja = source67(), zh = WikipediaReviewSource(pageID: 67, title: "合成來源", url: URL(string: "https://zh.wikipedia.org/wiki/Fixture")!, fetchedAt: Date(), excerpts: [.init(id: "p0", text: "這是中文站的獨立原文，沒有日文引用。")])
        let answer = WikipediaReviewAnswer(decision: .selected, sourceID: ja.id, relationship: .brand, searchName: "マルエフ", summary: "品牌關係的合成繁中說明。", citations: [.init(excerptID: "p0", quote: ja.excerpts[0].text)])
        let raw = String(decoding: try JSONEncoder().encode(answer), as: UTF8.self)
        #expect(try WikipediaSemanticReview.parse(raw, sources: [ja, zh]) == answer)
        #expect(throws: Error.self) { try WikipediaSemanticReview.parse(raw.replacingOccurrences(of: "jawiki:67", with: "zhwiki:67"), sources: [ja, zh]) }
        #expect(throws: Error.self) { try WikipediaSemanticReview.parse(raw.replacingOccurrences(of: "jawiki:67", with: "enwiki:67"), sources: [ja, zh]) }
        #expect(WikipediaReviewAnswer(decision: .no_match).valid(sources: [ja, zh]))
        #expect(WikipediaSemanticReview.prompt.contains("earlier candidate position is only a retrieval hint"))
    }
    @Test func partialOriginalLanguageExcerptRejectsUndeliveredQuote() throws {
        let r = multiResult67(["マルエフ"]), source = source67()
        let supplied = WikipediaReviewBudget.sources([source], for: r)
        let firstSentence = "アサヒビールは日本のビールメーカーである。"
        #expect(supplied[0].excerpts[0].text == firstSentence)
        func answer(_ quote: String) -> WikipediaReviewAnswer {
            .init(decision: .selected, sourceID: source.id, relationship: .brand, searchName: "マルエフ", summary: "繁體中文合成品牌說明。", citations: [.init(excerptID: "p0", quote: quote)])
        }
        #expect(!answer(source.excerpts[0].text).valid(sources: supplied))
        #expect(answer(firstSentence).valid(sources: supplied))
        let raw = String(decoding: try JSONEncoder().encode(answer(source.excerpts[0].text)), as: UTF8.self)
        #expect(throws: Error.self) { try WikipediaSemanticReview.parse(raw, sources: supplied, result: r) }
    }
    @Test func foreignArchiveReopenAndSharingRetainURLTitleLanguageAndRelationship() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = RecognitionArchive(root: root), id = UUID(), run = UUID(), source = source67(title: "日本の科学")
        let parsed = try result67()
        let r = RecognitionResult(names: parsed.names, summary: parsed.summary, text: parsed.text, sourceImageID: id,
                                  searchContractVersion: 17, searchEntities: parsed.searchEntities)
        _ = try await archive.create(id: id, jpeg: Data([6,7]), capturedAt: Date())
        let completed = try await archive.complete(id: id, result: r, message: nil)
        _ = try await archive.beginSemanticReview(id: id, attemptID: id, runID: run, expectedResult: completed.result!)
        _ = try await archive.updateSemanticReview(id: id, attemptID: id, runID: run, state: .reviewing, sources: [source])
        let answer = WikipediaReviewAnswer(decision: .selected, sourceID: source.id, relationship: .brand, searchName: r.names[0], summary: "以日文原始資料支持的繁體中文品牌說明。", citations: [.init(excerptID: "p0", quote: source.excerpts[0].text)])
        _ = try await archive.updateSemanticReview(id: id, attemptID: id, runID: run, state: .succeeded, answer: answer)
        let saved = try #require(try await RecognitionArchive(root: root).load().records.first)
        let link = try #require(saved.shareDocument().links.first { $0.label.hasPrefix("維基百科：") })
        #expect(link.label == "維基百科：日本の科学（日文）（品牌）" && link.url == source.url)
        #expect(saved.currentSemanticReview?.source == source)
        #expect(saved.currentSemanticReview?.answer?.summary == answer.summary)
        #expect(saved.shareDocument().html.contains("日本の科学（日文）（品牌）"))
    }
}
private func source67(_ language: String = "ja", id: Int = 67, title: String = "アサヒビール") -> WikipediaReviewSource {
    .init(pageID: id, title: title, url: URL(string: "https://\(language).wikipedia.org/wiki/\(title)")!, fetchedAt: Date(),
          excerpts: [.init(id: "p0", text: "アサヒビールは日本のビールメーカーである。これは固定のテスト資料です。")])
}
private actor Transport67 {
    var requests: [URLRequest] = []
    let crossedHost: Bool
    init(crossedHost: Bool = false) { self.crossedHost = crossedHost }
    func fetch(_ request: URLRequest) throws -> WikipediaHTTPResponse {
        requests.append(request)
        let q = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        let host = request.url!.host!
        var pages: [[String: Any]] = []
        if host == "ja.wikipedia.org" {
            let title = q["titles"]?.components(separatedBy: "|").first ?? "アサヒビール"
            pages = [["ns": 0, "pageid": 67, "title": title, "canonicalurl": "https://\(crossedHost ? "zh.wikipedia.org" : host)/wiki/アサヒビール",
                      "extract": "アサヒビールは日本のビールメーカーである。これは固定のテスト資料です。", "index": 1]]
        }
        return .init(data: try JSONSerialization.data(withJSONObject: ["query": ["pages": pages]]), status: 200, url: request.url)
    }
}

@Suite struct OriginalWiki67Baseline {
    @Test(arguments: [false, true]) func bothAsahiOutputsUseJapaneseSourcesWithoutChinesePage(_ newer: Bool) async throws {
        let transport = Transport67(), r = try result67(newer: newer)
        let collection = try await WikipediaReviewCollector(transport: { try await transport.fetch($0) }).collectWithDiagnostics(for: r)
        #expect(collection.sources.map(\.id) == ["jawiki:67"])
        let requests = await transport.requests
        #expect(requests.allSatisfy { $0.url?.host == "ja.wikipedia.org" })
        #expect(requests.count <= 9)
    }
    @Test func samePageIDOnDifferentWikisDoesNotCollide() {
        let ja = source67(), zh = source67("zh")
        #expect(ja.valid && zh.valid)
        #expect(ja.id == "jawiki:67" && zh.id == "zhwiki:67")
        #expect(Set([ja.id, zh.id]).count == 2)
    }
    @Test func inputCarriesOriginalLanguageAndUntranslatedQuotes() throws {
        let input = try WikipediaSemanticReview.input(result: result67(), rawStageOne: nil, sources: [source67()])
        let json = try JSONSerialization.jsonObject(with: input) as! [String: Any]
        let source = (json["sources"] as! [[String: Any]])[0]
        #expect(source["language"] as? String == "ja")
        #expect(source["source_id"] as? String == "jawiki:67")
        #expect((source["excerpts"] as! [[String: String]])[0]["text"] == source67().excerpts[0].text)
    }
    @Test func foreignTitleIsNotConvertedAndLanguageIsVisible() {
        let source = source67(title: "日本の科学"), quote = source.excerpts[0].text
        var review = RecognitionSemanticReview(recordID: UUID(), attemptID: UUID())
        review.state = .succeeded; review.sources = [source]
        review.answer = .init(decision: .selected, sourceID: "jawiki:67", relationship: .brand, searchName: "マルエフ", summary: "這是固定測試的繁體中文簡介。", citations: [.init(excerptID: "p0", quote: quote)])
        #expect(review.displayTitle == "日本の科学（日文）（品牌）")
    }
    @Test func crossWikiResponseIsNotAcceptedAsTheRequestedWiki() async throws {
        let t = Transport67(crossedHost: true)
        let sources = try await WikipediaReviewCollector(transport: { try await t.fetch($0) }).collect(for: result67())
        #expect(sources.isEmpty)
    }
    @Test func oldChineseSourcesDecodeWithTheirOriginalIdentity() throws {
        let s = source67("zh"), data = try JSONEncoder().encode(s)
        let restored = try JSONDecoder().decode(WikipediaReviewSource.self, from: data)
        #expect(restored == s && restored.id == "zhwiki:67" && restored.valid)
    }
}

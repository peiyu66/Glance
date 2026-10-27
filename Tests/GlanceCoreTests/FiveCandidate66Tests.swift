import Foundation
import Testing
@testable import GlanceCore

// Recorded query titles/page IDs/index and introductions: zh.wikipedia.org/w/api.php,
// 2026-10-26 07:20 UTC. Wikipedia text remains under CC BY-SA; each page's canonicalurl
// identifies its attribution/history. Full extracts were not saved for pages 4/5.
// Pin the captured zh-only language route to retain this historical ranking regression.
// OriginalWiki67Tests separately exercises the production language route.
// The transport below simulates failed full-extract reads; no network or model is used.
private let recorded66 = #"""
{"stage1":{"summary":"照片中的主體是「アサヒ生ビール マルエフ」，一款日本啤酒。罐身上的「生ビール」表示生啤酒，「お酒」是酒類標示。","text":["アサヒ生ビール","マルエフ","まろやかな泡","生ビール","お酒"],"search_entities":[{"id":0,"status":"ready","source_role":"product_label","basis":"text","source_text":"アサヒ生ビール\nマルエフ","name":"アサヒ生ビール マルエフ","role":"central","related_to":-1,"kind":"product","context_text":["アサヒ生ビール","マルエフ"],"relation":"none","aliases":["アサヒ生ビール マルエフ"]},{"id":1,"status":"ready","source_role":"product_label","basis":"text","source_text":"アサヒ生ビール","name":"アサヒビール","role":"related","related_to":0,"kind":"brand","context_text":["アサヒ生ビール"],"relation":"brand_of","aliases":["Asahi Beer"]}],"schema_version":17,"names":["アサヒ生ビール マルエフ"]},"exact":{"query":{"pages":[{"ns":0,"title":"Asahi Beer","missing":true,"canonicalurl":"https://zh.wikipedia.org/wiki/Asahi_Beer"},{"ns":0,"title":"アサヒビール","missing":true,"canonicalurl":"https://zh.wikipedia.org/wiki/%E3%82%A2%E3%82%B5%E3%83%92%E3%83%93%E3%83%BC%E3%83%AB"},{"ns":0,"title":"アサヒ生ビール マルエフ","missing":true,"canonicalurl":"https://zh.wikipedia.org/wiki/%E3%82%A2%E3%82%B5%E3%83%92%E7%94%9F%E3%83%93%E3%83%BC%E3%83%AB_%E3%83%9E%E3%83%AB%E3%82%A8%E3%83%95"}]}},"brand":{"query":{"pages":[{"pageid":3125994,"ns":0,"title":"麒麟啤酒","index":3,"canonicalurl":"https://zh.wikipedia.org/wiki/%E9%BA%92%E9%BA%9F%E5%95%A4%E9%85%92","extract":"麒麟啤酒（日語：キリンビール），全稱麒麟麥酒株式會社（日語：麒麟麦酒株式会社；英語：Kirin Brewery Company, Limited），是日本的一家釀酒企業。其法人屬麒麟控股株式會社（由舊麒麟麥酒改組設立）旗下，扮演生產啤酒及發泡酒的事業子公司的角色。麒麟集團則是屬於三菱集團。"},{"pageid":3126021,"ns":0,"title":"朝日啤酒","index":2,"canonicalurl":"https://zh.wikipedia.org/wiki/%E6%9C%9D%E6%97%A5%E5%95%A4%E9%85%92","extract":"朝日啤酒（日語：アサヒビール株式会社，英語：Asahi Breweries, Ltd.）是一間釀製啤酒和生產軟飲料的公司，和麒麟啤酒、三得利、札幌啤酒並列為日本啤酒界四大企業。2016年，朝日啤酒佔據日本啤酒市場39%的份額，位居各企業之首。朝日啤酒是在1949年大日本麥酒分割過程中成立的企業，最初的業務範圍主要是西日本。朝日啤酒在1954年至1960年期間曾是日本啤酒業界第二大企業，但在1960年代之後持續低迷，1980年代前期更幾乎淪為日本啤酒業界第四大企業。然而在公司內改革和朝日超爽啤酒熱銷的幫助下，朝日啤酒在短時間內迅速實現業績回升，在1988年奪回業界第二的位置，並在2001年獲得業界首位（包含發泡酒）。朝日啤酒的企業標語是「分享感動」（その感動を、わかちあう。）。\n自2011年7月開始，朝日啤酒是朝日集團控股的全資子公司。朝日集團控股亦繼承了朝日啤酒東證1部：2502的股票代碼。"},{"pageid":7175236,"ns":0,"title":"超爽大廳","index":1,"canonicalurl":"https://zh.wikipedia.org/wiki/%E8%B6%85%E7%88%BD%E5%A4%A7%E5%BB%B3","extract":"超爽大廳（日語：スーパードライホール，英語：Super Dry Hall）是位於日本東京都墨田區吾妻橋一丁目River Pia吾妻橋的一座建築，毗鄰朝日啤酒總部（朝日啤酒塔）。這座建築竣工於1989年，修建在朝日啤酒吾妻橋工廠的舊址上。建築本身和建築上的雕塑是由法國設計師菲利普·斯塔克設計，是朝日啤酒創建100週年紀念事業的一部分。大廳的一層至三層是餐廳，四至五層則曾設有美術展廳「朝日藝術廣場」（アサヒ・アートスクエア），但已在2016年3月底關閉。"}]}},"central":{"query":{"pages":[{"pageid":274898,"ns":0,"title":"Soft On Demand","index":1,"canonicalurl":"https://zh.wikipedia.org/wiki/Soft_On_Demand","extract":"Soft On Demand株式會社（日語：ソフト・オン・デマンド株式会社；英語：Soft On Demand Company, Limited），通稱SOD，是一個日本的成人影片製造商公司，總部設在東京都中野區，成立於1995年11月。是日本最大成人影片公司之一，因其對成人影片的創造性內容而聞名。"},{"pageid":6099332,"ns":0,"title":"偶像大師 閃耀色彩","index":2,"canonicalurl":"https://zh.wikipedia.org/wiki/%E5%81%B6%E5%83%8F%E5%A4%A7%E5%B8%AB_%E9%96%83%E8%80%80%E8%89%B2%E5%BD%A9","extract":"《偶像大師 閃耀色彩》（日語：アイドルマスター シャイニーカラーズ）是一款由BXD公司（現：萬代南夢宮Nexus)開發，萬代南夢宮娛樂發行的養成網頁和手機遊戲。該遊戲為《偶像大師系列》第二世代的遊戲之一，且首度運用了萬代南夢宮娛樂旗下的HTML5平台「enza」。在遊戲中，玩家將扮演「283（翼）藝能經紀公司」（283（ツバサ）プロダクション）的製作人，以進行培養旗下偶像的工作。《偶像大師 閃耀色彩》由發行商萬代南夢宮娛樂定於2018年4月24日發行，其平台包括PC、iOS和Android。\n2023年3月19日宣布將製作電視動畫，於2024年播出。2023年4月29日宣布發行新題材子遊戲《偶像大師 閃耀色彩 Song for Prism》，5月19日向部分玩家析出測試版名額進行試玩。2023年11月14日開始正式營運。"},{"pageid":7203275,"ns":0,"title":"夏日時光 (漫畫)","index":3,"canonicalurl":"https://zh.wikipedia.org/wiki/%E5%A4%8F%E6%97%A5%E6%99%82%E5%85%89_(%E6%BC%AB%E7%95%AB)","extract":"《夏日時光》（日語：サマータイムレンダ）是田中靖規所創作的懸疑類型日本漫畫，於2017年10月23日至2021年2月1日在少年Jump+連載。本作以日本和歌山縣一個名為「日都島」（日都ヶ島）、人口只有約700人的虛構小島為舞台。本作是少年Jump+免費電子版雜誌創刊號的12套連載作品之一。\n2021年2月1日本作完結，同日宣佈將製作動畫、真實逃脫遊戲，以及真人版影視作品。7月22日，宣佈電視動畫將於2022年首播。10月14日公開電視動畫的特報宣傳片，同日稍後宣佈將由Disney+獨佔網上播映。12月19日，於Jump Festa 2022公開第1條宣傳片，並宣佈動畫將於2022年4月首播，會做到故事結束，共25集。2022年2月3日，宣佈動畫首播日期為2022年4月14日，並公開第2張主視覺圖，以及多名配角的聲優。"}]}}}
"""#
private func fixture66() throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(recorded66.utf8)) as! [String: Any] }
private func result66() throws -> RecognitionResult {
    let wire = try JSONSerialization.data(withJSONObject: fixture66()["stage1"]!)
    return try CameraAnswer.parse(String(decoding: wire, as: UTF8.self), expectingStructured: true)
}
private actor Transport66 {
    var calls: [[String: String]] = []
    let cancelFourth: Bool
    init(cancelFourth: Bool = false) { self.cancelFourth = cancelFourth }
    func fetch(_ request: URLRequest) throws -> WikipediaHTTPResponse {
        let q = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        calls.append(q)
        if let id = q["pageids"] {
            if cancelFourth && id == "3126021" { throw CancellationError() }
            throw URLError(.timedOut) // Keep saved introductions, not invented full extracts.
        }
        let key = q["titles"] != nil ? "exact" : q["gsrsearch"] == "アサヒビール" ? "brand" : "central"
        return .init(data: try JSONSerialization.data(withJSONObject: fixture66()[key]!), status: 200, url: request.url)
    }
}
private func fullSources66(_ count: Int = 5) -> [WikipediaReviewSource] {
    (0..<count).map { i in
        .init(pageID: 6600 + i, title: "合成候選\(i)", url: URL(string: "https://zh.wikipedia.org/wiki/Fixture_\(i)")!, fetchedAt: Date(timeIntervalSince1970: 0),
              excerpts: (0..<3).map { j in .init(id: "p\(j)", text: "アサヒビール \(i) \(j) " + String(repeating: "有界來源", count: 120)) })
    }
}
@Suite struct FiveCandidate66Tests {
    @Test func recordedAsahiRankTwoReachesStageTwoWithoutChangingQueriesOrRanking() async throws {
        let network = Transport66(), result = try result66()
        let collection = try await WikipediaReviewCollector(transport: { try await network.fetch($0) }, languageResolver: { _ in .zh }).collectWithDiagnostics(for: result)
        #expect(collection.sources.map(\.pageID) == [274898, 7175236, 6099332, 3126021, 7203275])
        #expect(collection.exactMatches.isEmpty)
        #expect(collection.fullTextTerms.map(\.value) == ["アサヒ生ビール マルエフ", "アサヒビール"])
        let calls = await network.calls
        #expect(calls.count == 8)
        #expect(calls.filter { $0["titles"] != nil }.count == 1)
        #expect(calls.filter { $0["gsrsearch"] != nil }.allSatisfy { $0["gsrlimit"] == "3" && $0["exlimit"] == "3" })
        #expect(calls.compactMap { $0["pageids"] } == ["274898", "7175236", "6099332", "3126021", "7203275"])
        let input = try WikipediaSemanticReview.input(result: result, rawStageOne: nil, sources: collection.sources)
        let root = try JSONSerialization.jsonObject(with: input) as! [String: Any]
        let sources = root["sources"] as! [[String: Any]]
        #expect(sources.map { $0["source_id"] as! String } == collection.sources.map(\.id))
        let asahi = try #require(sources.first { $0["source_id"] as? String == "zhwiki:3126021" })
        #expect(asahi["title"] as? String == "朝日啤酒")
        let stage = root["stage_one"] as! [String: Any]
        #expect(stage["names"] as? [String] == result.names && stage["text"] as? [String] == result.text)
        #expect(root["raw_stage_one_json"] is NSNull)
    }
    @Test func fiveFullPagesKeepAllExcerptsWithinExistingInputAndModelContract() throws {
        let result = try result66(), sources = fullSources66()
        let input = try WikipediaSemanticReview.input(result: result, rawStageOne: nil, sources: sources)
        let root = try JSONSerialization.jsonObject(with: input) as! [String: Any]
        let pages = root["sources"] as! [[String: Any]]
        #expect(pages.count == 5 && input.count < 128_000)
        var count = 0
        for page in pages {
            let excerpts = page["excerpts"] as! [[String: String]]
            #expect(excerpts.count == 3)
            for excerpt in excerpts { #expect(excerpt["text"]!.unicodeScalars.count == 400); count += excerpt["text"]!.unicodeScalars.count }
        }
        #expect(count == 6000)
        #expect((pages[4]["excerpts"] as! [[String: String]])[2]["text"]!.contains("アサヒビール 4 2"))
        let request = try WikipediaSemanticReview.request(input: input, catalog: [SIWCModel(slug: "gpt-6-luna", display_name: "Fixture", visibility: "list")])
        let body = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        #expect(body["model"] as? String == "gpt-6-luna" && (body["reasoning"] as? [String: String])?["effort"] == "none")
        #expect(body["max_output_tokens"] == nil && body["tools"] == nil)
        let messages = body["input"] as! [[String: Any]]
        #expect(messages.count == 2)
        #expect((messages[0]["content"] as! [[String: String]])[0]["text"] == WikipediaSemanticReview.prompt)
        #expect((messages[1]["content"] as! [[String: String]])[0]["text"] == String(decoding: input, as: UTF8.self))
    }
    @Test func sixthSourceDuplicatesAndInvalidCitationsRemainRejected() throws {
        let result = try result66(), sources = fullSources66()
        #expect(throws: Error.self) { try WikipediaSemanticReview.input(result: result, rawStageOne: nil, sources: fullSources66(6)) }
        #expect(throws: Error.self) { try WikipediaSemanticReview.input(result: result, rawStageOne: nil, sources: [sources[0], sources[0]]) }
        #expect(WikipediaReviewAnswer(decision: .no_match).valid(sources: sources))
        let supported = WikipediaReviewAnswer(decision: .selected, sourceID: sources[4].id, relationship: .brand, searchName: "合成產品", summary: "合成品牌摘要", citations: [.init(excerptID: "p0", quote: String(sources[4].excerpts[0].text.prefix(40)))])
        #expect(supported.valid(sources: sources))
        #expect(!supported.valid(sources: fullSources66(6)))
        let bad = WikipediaReviewAnswer(decision: .selected, sourceID: sources[4].id, relationship: .brand, searchName: "合成產品", summary: "合成品牌摘要", citations: [.init(excerptID: "p0", quote: "不存在的引用資料不應通過")])
        #expect(!bad.valid(sources: sources))
    }
    @Test func fiveSourceArchiveRoundTripPreservesFirstStageOnNoMatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = RecognitionArchive(root: root), id = UUID(), run = UUID(), result = try result66()
        _ = try await archive.create(id: id, jpeg: Data([1,2,3]), capturedAt: Date())
        let original = try await archive.complete(id: id, result: result, message: nil)
        _ = try await archive.beginSemanticReview(id: id, attemptID: id, runID: run, expectedResult: original.result!)
        await #expect(throws: Error.self) { try await archive.updateSemanticReview(id: id, attemptID: id, runID: run, state: .reviewing, sources: fullSources66(6)) }
        _ = try await archive.updateSemanticReview(id: id, attemptID: id, runID: run, state: .reviewing, sources: fullSources66())
        let saved = try await archive.updateSemanticReview(id: id, attemptID: id, runID: run, state: .noMatch, answer: .init(decision: .no_match))
        #expect(saved.semanticReview?.sources.count == 5 && saved.result == original.result && saved.presentationResult == original.presentationResult)
        #expect(try await RecognitionArchive(root: root).load().records.first == saved)
    }
    @Test func cancellationAtFourthExtractStopsBeforeFifth() async throws {
        let network = Transport66(cancelFourth: true), result = try result66()
        await #expect(throws: CancellationError.self) { try await WikipediaReviewCollector(transport: { try await network.fetch($0) }, languageResolver: { _ in .zh }).collect(for: result) }
        #expect(await network.calls.compactMap { $0["pageids"] } == ["274898", "7175236", "6099332", "3126021"])
    }
}

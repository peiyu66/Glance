import Foundation
import Testing
@testable import GlanceCore

// All sources/replies in this file are synthetic; none asserts live model quality.
private func subject60(_ aliases: [String] = [], related: Bool = true) -> RecognitionResult {
    let text = ["中央書名", "作者甲", "其他主題"]
    var entities = [SearchEntity(kind: .object, name: text[0], aliases: aliases, sourceRole: .public_text, sourceText: text[0])]
    if related { entities += [.init(id: 1, role: .text, kind: .object, name: text[1], sourceRole: .public_text, sourceText: text[1]), .init(id: 2, role: .text, kind: .object, name: text[2], sourceRole: .public_text, sourceText: text[2])] }
    return .init(names: [text[0]], summary: "合成中央書籍與文字。", text: text, searchContractVersion: 17, searchEntities: entities)
}
private func page60(_ id: Int, _ title: String, index: Int? = nil, text: String = "這是離線合成的公開來源內容。") -> [String: Any] {
    var p: [String: Any] = ["pageid": id, "ns": 0, "title": title, "canonicalurl": "https://zh.wikipedia.org/wiki/Fixture\(id)", "extract": text]
    if let index { p["index"] = index }; return p
}
private func response60(_ pages: [[String: Any]], maps: [String: [[String: String]]] = [:]) throws -> Data {
    var query: [String: Any] = ["pages": pages]
    for (k,v) in maps { query[k] = v }
    return try JSONSerialization.data(withJSONObject: ["query": query])
}
private actor Network60 {
    let exact: Data
    let searches: [String: Data]
    var calls: [[String: String]] = []
    init(exact: Data, searches: [String: Data] = [:]) { self.exact = exact; self.searches = searches }
    func fetch(_ request: URLRequest) async throws -> WikipediaHTTPResponse {
        let params = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        calls.append(params)
        let data: Data
        if params["titles"] != nil { data = exact }
        else if let query = params["gsrsearch"] {
            if query == "作者甲" { try await Task.sleep(for: .milliseconds(15)) }
            data = searches[query] ?? Data(#"{"batchcomplete":true}"#.utf8)
        } else { // Force the collector to retain the original partial lead.
            throw URLError(.timedOut)
        }
        return .init(data: data, status: 200, url: request.url)
    }
}
@Test func central60RolePriorityDoesNotUseMinimumIDWhileWireAdmissionStaysSeparate() {
    let rows: [SearchEntity] = [.init(id: 0, role: .text, kind: .object, name: "作者", sourceText: "作者"), .init(id: 3, role: .central, kind: .object, name: "中央書名", sourceText: "中央書名"), .init(id: 1, role: .text, kind: .object, name: "其他", sourceText: "其他")]
    #expect(WikipediaReviewCollector.prioritizedEntities(rows).map(\.id) == [3,0,1])
    let result = RecognitionResult(names: ["中央書名"], summary: "合成", text: rows.map(\.name), searchContractVersion: 17, searchEntities: rows)
    #expect(!SearchEntity.matching(result).contains { $0.role == .central }) // Existing v17 ID=0 contract, not relaxed here.
}
@Test func central60ExactTitleSurvivesRelatedQuotaAndDuplicatePages() async throws {
    let network = try Network60(exact: response60([page60(90,"中央書名")]), searches: ["作者甲": response60([page60(2,"作者甲",index:2),page60(90,"中央書名",index:1)]), "其他主題": response60([page60(90,"中央書名",index:1),page60(3,"其他主題",index:2)])])
    let sources = try await WikipediaReviewCollector(transport: { try await network.fetch($0) }).collect(for: subject60())
    #expect(sources.map(\.pageID) == [90,2,3])
    let calls = await network.calls
    #expect(calls.count == 6 && calls.filter { $0["titles"] != nil }.count == 1 && calls.filter { $0["gsrsearch"] != nil }.count == 2)
    #expect(calls[0]["redirects"] == "1" && calls[0]["converttitles"] == "1")
    #expect(calls.filter { $0["pageids"] != nil }.compactMap { $0["pageids"] } == ["90","2","3"])
}
@Test func central60ExactPageLastInSearchIsReservedBeforeAuthor() async throws {
    let network = try Network60(exact: response60([]), searches: ["中央書名": response60([page60(1,"作者甲",index:1),page60(2,"其他主題",index:2),page60(90,"中央書名",index:3)]), "作者甲": response60([page60(3,"第三相關頁",index:1)])])
    let sources = try await WikipediaReviewCollector(transport: { try await network.fetch($0) }).collect(for: subject60())
    #expect(sources.map(\.pageID) == [90,1,3])
}
@Test func central60AliasConversionAndRedirectUseCanonicalTitleAndDeduplicate() async throws {
    let network = try Network60(exact: response60([page60(90,"正式書名"),page60(90,"正式書名")], maps:["converted":[["from":"中央書名","to":"中央书名"]],"redirects":[["from":"中央书名","to":"正式書名"],["from":"另一別名","to":"正式書名"]]]))
    let sources = try await WikipediaReviewCollector(transport: { try await network.fetch($0) }).collect(for: subject60(["中央书名","另一別名"], related: false))
    #expect(sources.count == 1 && sources.first?.title == "正式書名" && sources.first?.pageID == 90)
    #expect(await network.calls.first?["titles"] == "中央書名|另一別名")
    #expect(await network.calls.count == 2)
}
@Test func central60HomonymDoesNotProduceAutomaticIdentityOrOverwriteFirstCard() async throws {
    let network = try Network60(exact: response60([page60(90,"中央書名",text:"中央書名是合成遊戲，與相同名稱的書籍不同。")]))
    let result = subject60(related: false)
    let sources = try await WikipediaReviewCollector(transport: { try await network.fetch($0) }).collect(for: result)
    let raw = #"{"schema_version":2,"decision":"insufficient_evidence","source_id":"","relationship":"none","search_name":"","summary":"","citations":[]}"#
    let answer = try WikipediaSemanticReview.parse(raw, sources: sources, result: result)
    #expect(answer.decision == .insufficient_evidence && answer.relationship == .none)
    #expect(result.names == ["中央書名"] && sources.count == 1)
    #expect(WikipediaSemanticReview.prompt.contains("never proof of same_entity") && WikipediaSemanticReview.prompt.contains("including homonyms"))
}
@Test func central60MissingDedicatedPageKeepsSupportedRelatedFallback() async throws {
    let network = try Network60(exact: response60([]), searches:["中央書名":response60([]),"作者甲":response60([page60(2,"作者甲",text:"作者甲寫了中央書名這部作品。")])])
    let result = subject60(), sources = try await WikipediaReviewCollector(transport: { try await network.fetch($0) }).collect(for: result)
    #expect(sources.map(\.title) == ["作者甲"])
    let answer = WikipediaReviewAnswer(decision:.selected,sourceID:sources[0].id,relationship:.contextual,searchName:"作者甲",summary:"作者甲寫了中央書名。",citations:[.init(excerptID:"p0",quote:"作者甲寫了中央書名這部作品。")])
    #expect(try WikipediaSemanticReview.parse(String(decoding: JSONEncoder().encode(answer),as:UTF8.self),sources:sources,result:result) == answer)
}
@Test func central60SearchIndexOverridesArrayOrderWithDeterministicMissingIndexFallback() async throws {
    let network = try Network60(exact: response60([]), searches:["中央書名":response60([page60(30,"甲頁",index:2),page60(20,"乙頁",index:1),page60(10,"丙頁")])])
    let sources = try await WikipediaReviewCollector(transport: { try await network.fetch($0) }).collect(for: subject60(related:false))
    #expect(sources.map(\.pageID) == [20,30,10])
}
@Test func central60RejectsUnmappedExactAndDisambiguationPages() async throws {
    var disambiguation = page60(90,"中央書名"); disambiguation["pageprops"] = ["disambiguation":""]
    let network = try Network60(exact: response60([disambiguation,page60(99,"無關標題")]))
    #expect(try await WikipediaReviewCollector(transport: { try await network.fetch($0) }).collect(for: subject60(related:false)).isEmpty)
}
@Test func central60BoundsThreeExactNamesAndUnchangedInputBudget() async throws {
    let network = try Network60(exact: response60([page60(90,"中央書名",text:String(repeating:"有界合成來源。",count:1000))]))
    let result = subject60(["別名甲","別名乙","別名丙"],related:false)
    let sources = try await WikipediaReviewCollector(transport: { try await network.fetch($0) }).collect(for: result)
    #expect(await network.calls.first?["titles"] == "中央書名|別名甲|別名乙")
    let input = try WikipediaSemanticReview.input(result:result,rawStageOne:nil,sources:sources)
    #expect(input.count <= 128000 && sources.count <= 3)
    #expect(sources.flatMap(\.excerpts).reduce(0) { $0 + $1.text.unicodeScalars.count } <= 3600)
}

@Test func central60UncertainCentralCannotSuppressReadyPublicTextOrSearchPrivateName() async throws {
    // Same status/role pattern as the user report; personal label text is replaced.
    let result = RecognitionResult(names:["合成姓名"],summary:"裝飾貼紙與地名標籤。",text:["台北社子","合成姓名"],searchContractVersion:17,searchEntities:[
        .init(kind:.object,name:"貼紙",status:.uncertain,basis:.appearance,sourceRole:.unknown),
        .init(id:1,role:.text,kind:.object,name:"台北社子",sourceRole:.public_text,sourceText:"台北社子",contextText:["台北社子"]),
        .init(id:2,role:.text,kind:.object,name:"合成姓名",status:.uncertain,sourceRole:.unknown)])
    let network = try Network60(exact:response60([]), searches:["台北社子":response60([page60(269800,"社子",index:1,text:"社子是臺北市士林區的一個次分區。")])])
    let sources = try await WikipediaReviewCollector(transport: { try await network.fetch($0) }).collect(for:result)
    #expect(WikipediaReviewCollector.queries(for:result) == ["台北社子"])
    #expect(sources.map(\.pageID) == [269800])
    let calls = await network.calls
    #expect(calls.count == 2 && calls.allSatisfy { $0["titles"] == nil })
    #expect(calls.compactMap { $0["gsrsearch"] } == ["台北社子"])
    #expect(GoogleSearchQuery.resolve(result:result,decodedBarcodes:[],productBarcodes:[])?.query == "台北社子")
}

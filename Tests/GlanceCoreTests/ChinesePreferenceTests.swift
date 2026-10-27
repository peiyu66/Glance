import Foundation
import Testing
@testable import GlanceCore

private func preferenceResult(_ style: String = "kirin") -> RecognitionResult {
    let product = style == "kirin" ? "キリン一番搾り生ビール" : "アサヒ生ビール マルエフ"
    let brand = style == "kirin" ? "キリンビール" : style == "asahi-old" ? "アサヒビール" : "アサヒ生ビール"
    let alias = style == "kirin" ? "KIRIN BEER" : style == "asahi-old" ? "Asahi Beer" : "アサヒ"
    return .init(names: [style == "kirin" ? "麒麟一番搾り生啤酒" : product], summary: "合成辨識資料", text: [product, brand], searchContractVersion: 17, searchEntities: [
        .init(id: 0, role: .central, kind: .product, name: product, aliases: [style == "kirin" ? "一番搾り" : product], sourceText: product),
        .init(id: 1, role: .related, kind: .brand, name: brand, aliases: [alias], sourceText: brand, relation: .brand_of, relatedTo: 0)])
}

private actor PreferenceTransport {
    enum Mode: Sendable { case linked, absent, failChinese, unsafe, wrongChinesePage, disambiguation, dense, duplicate }
    let mode: Mode
    var requests: [URLRequest] = []
    init(_ mode: Mode = .linked) { self.mode = mode }
    func fetch(_ request: URLRequest) throws -> WikipediaHTTPResponse {
        requests.append(request)
        let q = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        let host = request.url!.host!
        func page(_ id: Int, _ title: String, linked: Bool = false) -> [String: Any] {
            var value: [String: Any] = ["ns": 0, "pageid": id, "index": id, "title": title, "canonicalurl": "https://\(host)/wiki/\(title)",
                "extract": "\(title) 是隔離測試摘錄，不是真實百科內容。\n\n" + String(repeating: "測試證據保留原文與關係。", count: 150)]
            if linked && mode != .absent {
                let target = mode == .duplicate ? "中文對應1" : "中文對應\(id)"
                value["langlinks"] = [["lang": "zh", "title": target, "url": "https://\(mode == .unsafe ? "zh.wikipedia.org.evil.example" : "zh.wikipedia.org")/wiki/\(target)"]]
            }
            return value
        }
        var pages: [[String: Any]] = []
        if host == "zh.wikipedia.org" {
            if mode == .failChinese { throw URLError(.timedOut) }
            let title = q["titles"] ?? "missing"
            let id = Int(String(title.suffix(1))) ?? 1
            var value = page(id, mode == .wrongChinesePage ? "非請求的中文頁" : title)
            if mode == .disambiguation { value["pageprops"] = ["disambiguation": ""] }
            pages = [value]
        } else if let ids = q["pageids"], let id = Int(ids) {
            pages = [page(id, "原文候選\(id)", linked: true)]
        } else if q["titles"] != nil {
            // Empty exact result forces both original full-text queries, exercising maximum search budget.
            pages = []
        } else if let term = q["gsrsearch"] {
            let first = term.contains("一番") || term.contains("マルエフ") ? 1 : 4
            pages = (first...(first + (mode == .dense || mode == .duplicate ? 2 : 0))).map { page($0, "原文候選\($0)") }
        }
        return .init(data: try JSONSerialization.data(withJSONObject: ["query": ["pages": pages]]), status: 200, url: request.url)
    }
}

@Suite private struct ChinesePreference {
    @Test(arguments: ["kirin", "asahi-old", "asahi-new"])
    func chineseCounterpartsAndOriginalsReachOneBoundedReview(_ style: String) async throws {
        let transport = PreferenceTransport(), r = preferenceResult(style)
        let c = try await WikipediaReviewCollector(transport: { try await transport.fetch($0) }).collectWithDiagnostics(for: r)
        #expect(c.sources.map(\.id) == ["zhwiki:1", "jawiki:1", "zhwiki:4", "jawiki:4"])
        #expect(c.sources.filter { $0.edition == .zh }.allSatisfy { $0.url.host == "zh.wikipedia.org" })
        let requests = await transport.requests
        #expect(requests.filter { $0.url!.host == "zh.wikipedia.org" }.count == 2)
        #expect(requests.count <= 11)
        let input = try WikipediaSemanticReview.input(result: r, rawStageOne: nil, sources: c.sources)
        let json = try JSONSerialization.jsonObject(with: input) as! [String: Any]
        let sources = json["sources"] as! [[String: Any]]
        #expect(sources.count <= 5 && input.count <= 128_000)
        for source in sources {
            let snippets = source["excerpts"] as! [[String: String]]
            #expect(snippets.count <= 3 && snippets.reduce(0) { $0 + $1["text"]!.unicodeScalars.count } <= 1200)
        }
    }
    @Test(arguments: [PreferenceTransport.Mode.absent, .failChinese, .unsafe, .wrongChinesePage, .disambiguation])
    func unusableChineseCounterpartKeepsOriginalSources(_ mode: PreferenceTransport.Mode) async throws {
        let transport = PreferenceTransport(mode)
        let c = try await WikipediaReviewCollector(transport: { try await transport.fetch($0) }).collectWithDiagnostics(for: preferenceResult())
        #expect(c.sources.map(\.id) == ["jawiki:1", "jawiki:4"])
        let requests = await transport.requests
        #expect(requests.allSatisfy { ["ja.wikipedia.org", "zh.wikipedia.org"].contains($0.url!.host!) })
        if mode == .absent || mode == .unsafe { #expect(requests.allSatisfy { $0.url!.host == "ja.wikipedia.org" }) }
    }
    @Test func fiveSourceCapKeepsTwoOriginalFallbacksAndRequestsAreBounded() async throws {
        let transport = PreferenceTransport(.dense)
        let c = try await WikipediaReviewCollector(transport: { try await transport.fetch($0) }).collectWithDiagnostics(for: preferenceResult())
        #expect(c.sources.count == 5 && Set(c.sources.map(\.id)).count == 5)
        #expect(c.sources.prefix(4).map(\.id) == ["zhwiki:1", "jawiki:1", "zhwiki:4", "jawiki:4"])
        let requests = await transport.requests
        #expect(requests.count == 10) // one exact + two full text + five original extracts + two Chinese extracts
        #expect(requests.filter { $0.url?.host == "zh.wikipedia.org" }.count == 2)
    }
    @Test func duplicateChineseCounterpartDoesNotConsumeAnotherSourceOrRequest() async throws {
        let transport = PreferenceTransport(.duplicate)
        let c = try await WikipediaReviewCollector(transport: { try await transport.fetch($0) }).collectWithDiagnostics(for: preferenceResult())
        #expect(c.sources.count == 5 && Set(c.sources.map(\.id)).count == 5)
        #expect(c.sources.contains { $0.id == "jawiki:1" } && c.sources.contains { $0.id == "jawiki:4" })
        #expect(await transport.requests.filter { $0.url!.host == "zh.wikipedia.org" }.count == 1)
    }
    @Test func contractPrefersChineseOnlyAfterIdentityAndUsesExistingSearchName() {
        #expect(WikipediaSemanticReview.prompt.contains("Language preference never overrides identity"))
        #expect(WikipediaSemanticReview.prompt.contains("common Chinese search name"))
        #expect(WikipediaSemanticReview.prompt.contains("not replace a product with its brand, manufacturer or parent company"))
        let schema = WikipediaSemanticReview.format["schema"] as! [String: Any]
        let properties = schema["properties"] as! [String: Any]
        #expect(Set(properties.keys) == ["schema_version", "decision", "source_id", "relationship", "search_name", "summary", "citations"])
        #expect((properties["search_name"] as! [String: Any])["description"] as? String != nil)
    }
    @Test func twoEditionPathNeverExceedsElevenRequests() async throws {
        let base = preferenceResult(), transport = PreferenceTransport(.dense)
        let extra = SearchEntity(id: 2, role: .text, kind: .object, name: "Company Name", sourceRole: .public_text, sourceText: "Company Name")
        let result = RecognitionResult(names: base.names, summary: base.summary, text: base.text + ["Company Name"], searchContractVersion: 17, searchEntities: base.searchEntities! + [extra])
        let c = try await WikipediaReviewCollector(transport: { try await transport.fetch($0) }, languageResolver: { $0.id == 2 ? .en : .ja }).collectWithDiagnostics(for: result)
        #expect(c.sources.count == 5)
        #expect(await transport.requests.count == 11)
        #expect(await transport.requests.filter { $0.url!.host == "zh.wikipedia.org" }.count == 2)
    }
    @Test func specifiedChineseSearchNameSurvivesArchiveWithoutChangingIdentityOrSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecognitionArchive(root: root), id = UUID(), run = UUID(), result = preferenceResult()
        _ = try await store.create(id: id, jpeg: Data([1]), capturedAt: Date())
        let finished = try await store.complete(id: id, result: result, message: nil)
        _ = try await store.beginSemanticReview(id: id, attemptID: id, runID: run, expectedResult: finished.result!)
        let quote = "這是測試用製造商證據，並非真實百科事實。"
        let source = WikipediaReviewSource(pageID: 66913, title: "麒麟麦酒", url: URL(string: "https://ja.wikipedia.org/wiki/麒麟麦酒")!, fetchedAt: Date(), excerpts: [.init(id: "p0", text: quote)])
        let chineseName = "麒麟一番搾り生啤酒"
        let answer = WikipediaReviewAnswer(decision: .selected, sourceID: source.id, relationship: .manufacturer, searchName: chineseName, summary: "保留原名的中文說明。", citations: [.init(excerptID: "p0", quote: quote)])
        _ = try await store.updateSemanticReview(id: id, attemptID: id, runID: run, state: .succeeded, sources: [source], answer: answer)
        let reopened = try #require(try await RecognitionArchive(root: root).load().records.first)
        #expect(reopened.googleSearch?.query == chineseName)
        #expect(reopened.result?.searchEntities == result.searchEntities)
        #expect(reopened.currentSemanticReview?.source == source)
        let link = try #require(reopened.shareDocument().links.first { $0.label.hasPrefix("Google 搜尋") })
        #expect(URLComponents(url: link.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value == chineseName)
        #expect(reopened.currentSemanticReview?.answer?.relationship == .manufacturer)
        // Existing schema2 archive fields are sufficient: no language detector or translator is involved.
        let encoded = try JSONEncoder().encode(answer)
        #expect(try JSONDecoder().decode(WikipediaReviewAnswer.self, from: encoded) == answer)
    }

}

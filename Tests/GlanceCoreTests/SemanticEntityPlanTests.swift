import Foundation
import Testing
@testable import GlanceCore

// Fixed proposed model outputs, not claims about real model/image performance.
private func entityPlanResult(_ entities: [SearchEntity], text: [String]? = nil) throws -> RecognitionResult {
    let quotes = text ?? entities.flatMap { [$0.sourceText] + $0.contextText }.filter { !$0.isEmpty }
    let wire: [String: Any] = ["schema_version": 17, "names": [entities.first?.name ?? "物品"],
        "summary": "合成基線", "text": quotes,
        "search_entities": try JSONSerialization.jsonObject(with: JSONEncoder().encode(entities))]
    return try CameraAnswer.parse(String(decoding: JSONSerialization.data(withJSONObject: wire), as: UTF8.self), expectingStructured: true)
}

private actor PlanEdgeTransport {
    enum Mode: Sendable { case eightTitles, chain, cycle, unrelatedExact, tooManyExact, tooManySearch, malformedMapping, failedExtract }
    let mode: Mode
    var requests: [URLRequest] = []
    init(_ mode: Mode) { self.mode = mode }
    func fetch(_ request: URLRequest) throws -> WikipediaHTTPResponse {
        requests.append(request)
        let q = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        func page(_ id: Int, _ title: String) -> [String: Any] {
            ["ns": 0, "pageid": id, "title": title, "canonicalurl": "https://zh.wikipedia.org/wiki/Fixture_\(id)", "extract": "\(title) 是完整的合成測試摘要，仍須交給第二階段核對。", "index": id]
        }
        var query: [String: Any] = ["pages": []]
        if let id = q["pageids"].flatMap(Int.init) {
            if mode == .failedExtract { throw URLError(.timedOut) }
            // Keep the valid, correctly titled intro when a full extract is unavailable.
            query["pages"] = []
            #expect(id > 0)
        } else if let titles = q["titles"]?.components(separatedBy: "|") {
            switch mode {
            case .eightTitles:
                #expect(q["exlimit"] == "8" && q["exchars"] == "1200" && q["exintro"] == "1")
                query["pages"] = titles.enumerated().reversed().map { page(100 + $0.offset, $0.element) }
            case .chain:
                query["normalized"] = [["from": "alias brand", "to": "Alias brand"]]
                query["converted"] = [["from": "Alias brand", "to": "別名品牌"]]
                query["redirects"] = [["from": "別名品牌", "to": "正式品牌"]]
                query["pages"] = [page(71, "正式品牌")]
            case .cycle:
                query["redirects"] = [["from": "Cycle A", "to": "Cycle B"], ["from": "Cycle B", "to": "Cycle A"]]
                query["pages"] = [page(72, "Cycle A")]
            case .unrelatedExact: query["pages"] = [page(73, "Unrequested Page")]
            case .tooManyExact: query["pages"] = (1...9).map { page($0, "Page \($0)") }
            case .malformedMapping: query["normalized"] = [["from": 1, "to": "Name"]]
            case .failedExtract: query["pages"] = [page(74, titles[0])]
            case .tooManySearch: break
            }
        } else if mode == .tooManySearch { query["pages"] = (1...4).map { page($0, "Page \($0)") } }
        return .init(data: try JSONSerialization.data(withJSONObject: ["query": query]), status: 200, url: request.url)
    }
}

@Suite struct SemanticEntityPlannerEdges {
    @Test func allEightExactResultsStayBoundedAndCoverEntitiesBeforeExtraAliases() async throws {
        let names = ["Central Product", "Brand Name", "Company Name", "Series Name"]
        let entities = names.enumerated().map { i, name in namedEntity(name, id: i, role: i == 0 ? .central : .text, aliases: ["Alias \(i)"]) }
        let r = try entityPlanResult(entities), transport = PlanEdgeTransport(.eightTitles)
        // Isolate ranking from language detection; cross-wiki coverage is tested in OriginalWiki67Tests.
        let result = try await WikipediaReviewCollector(transport: { try await transport.fetch($0) }, languageResolver: { _ in .zh }).collectWithDiagnostics(for: r)
        #expect(result.plannedTerms.count == 8 && result.exactMatches.count == 8)
        #expect(result.fullTextTerms.isEmpty)
        #expect(result.sources.map(\.title) == names + ["Alias 0"])
        #expect(result.sources.map(\.pageID) == [100,102,104,106,101])
        #expect(await transport.requests.count == 6) // one lookup plus five bounded full extracts
    }
    @Test func normalizationConversionAndRedirectKeepOriginalProvenance() async throws {
        let r = try entityPlanResult([namedEntity("alias brand", kind: .brand)])
        let transport = PlanEdgeTransport(.chain)
        let result = try await WikipediaReviewCollector(transport: { try await transport.fetch($0) }).collectWithDiagnostics(for: r)
        let hit = try #require(result.exactMatches.first)
        #expect(hit.term.value == "alias brand" && hit.title == "正式品牌" && hit.usedRedirect)
        #expect(hit.mappings.map(\.kind) == ["normalized", "converted", "redirects"])
        #expect(result.fullTextTerms.map(\.value) == ["alias brand"])
        #expect(r.names == ["alias brand"])
    }
    @Test func cyclesAndUnmappedPagesCannotReserveIdentityOrSuppressSearch() async throws {
        for mode in [PlanEdgeTransport.Mode.cycle, .unrelatedExact] {
            let r = try entityPlanResult([namedEntity("Cycle A")]), transport = PlanEdgeTransport(mode)
            let result = try await WikipediaReviewCollector(transport: { try await transport.fetch($0) }).collectWithDiagnostics(for: r)
            #expect(result.exactMatches.isEmpty && result.sources.isEmpty)
            #expect(result.fullTextTerms.map(\.value) == ["Cycle A"])
        }
    }
    @Test func malformedMappingsAndResponsePageOverflowFailClosed() async throws {
        for mode in [PlanEdgeTransport.Mode.tooManyExact, .tooManySearch, .malformedMapping] {
            let transport = PlanEdgeTransport(mode), r = try entityPlanResult([namedEntity("Central Product")])
            await #expect(throws: Error.self) {
                try await WikipediaReviewCollector(transport: { try await transport.fetch($0) }).collect(for: r)
            }
            #expect(await transport.requests.count <= 3)
        }
    }
    @Test func failedSupplementKeepsOnlyValidPartialLeadWithoutRetries() async throws {
        let r = try entityPlanResult([namedEntity("Central Product")]), transport = PlanEdgeTransport(.failedExtract)
        let result = try await WikipediaReviewCollector(transport: { try await transport.fetch($0) }).collectWithDiagnostics(for: r)
        #expect(result.sources.count == 1 && result.sources[0].partial)
        #expect(result.sources[0].excerpts.count == 1)
        #expect(await transport.requests.count == 2)
    }
    @Test func subtitleColonDoesNotPermitURLsOperatorsCredentialsOrChangeLegacyRules() throws {
        #expect(CandidateQuerySafety.accepts("A Book: The Long Road", allowsTitleColon: true))
        #expect(!CandidateQuerySafety.accepts("A Book: The Long Road"))
        for unsafe in ["https://example.com", "https: //example.com", "javascript: alert", "file: /tmp/example", "mailto: user", "intitle: Product", "insource: query", "prefix: Topic", "token: synthetic-value", "密碼: synthetic-value", "Book:No Space", "Book: ", "Book|Other"] {
            #expect(!CandidateQuerySafety.accepts(unsafe, allowsTitleColon: true), "\(unsafe)")
        }
        let r = try entityPlanResult([namedEntity("A Book: The Long Road")])
        #expect(SearchEntity.matching(r).count == 1)
        let legacy = RecognitionResult(names: r.names, text: r.text, searchContractVersion: 16, searchEntities: r.searchEntities)
        #expect(SearchEntity.matching(legacy).isEmpty)
    }
    @Test func dedupKeepsEntityProvenanceAndFirstDistinctAliasWithoutSplitting() throws {
        let r = try entityPlanResult([namedEntity("Brand Name", aliases: ["brand name", "Official Alias", "Unused Alias"]),
            namedEntity("Brand Name", id: 1, role: .text, kind: .company, aliases: ["Other Company Name"])])
        let plan = WikipediaReviewCollector.queryPlan(for: r)
        #expect(plan.map(\.entityID) == [0,0,1,1])
        #expect(plan[1].aliasIndex == 1)
        #expect(WikipediaReviewCollector.queries(for: r) == ["Brand Name", "Official Alias", "Other Company Name"])
        #expect(r.searchEntities?.first?.aliases == ["brand name", "Official Alias", "Unused Alias"])
    }
    @Test func aliasesAndRelatedExcerptsRemainContiguousAndBounded() throws {
        let r = try entityPlanResult([namedEntity("Central Product"), namedEntity("Brand Name", id: 1, role: .related, kind: .brand, aliases: ["Fixture Alias"], relation: .brand_of)])
        let paragraphs = (0..<9).map { WikipediaReviewSource.Excerpt(id: "p\($0)", text: String(repeating: "前文", count: 700) + " Fixture Alias \($0) " + String(repeating: "後文", count: 700)) }
        let excerpts = WikipediaReviewBudget.excerpts(paragraphs, for: r)
        #expect(excerpts.count <= 3 && excerpts.reduce(0) { $0 + $1.text.unicodeScalars.count } <= 1200)
        for excerpt in excerpts {
            #expect(excerpt.text.unicodeScalars.count <= 400)
            #expect(paragraphs.contains { $0.id == excerpt.id && $0.text.contains(excerpt.text) })
        }
    }
}
private func namedEntity(_ name: String, id: Int = 0, role: SearchEntity.Role = .central,
                         kind: SearchEntity.Kind = .product, aliases: [String] = [], relation: SearchEntity.Relation = .none) -> SearchEntity {
    .init(id: id, role: role, kind: kind, name: name, aliases: aliases, sourceText: name,
          relation: relation, relatedTo: role == .related ? 0 : -1)
}
private actor PlanTransport {
    var requests: [URLRequest] = []
    let redirect: Bool
    init(redirect: Bool = false) { self.redirect = redirect }
    func fetch(_ request: URLRequest) throws -> WikipediaHTTPResponse {
        requests.append(request)
        let fields = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        var query: [String: Any] = ["pages": []]
        if redirect && (fields["titles"] != nil || fields["pageids"] != nil) {
            query = ["pages": [["ns": 0, "pageid": 71238, "title": "惊蛰", "canonicalurl": "https://zh.wikipedia.org/wiki/惊蛰", "extract": "惊蛰是二十四節氣之一，這段是固定合成摘錄。"]]]
            if fields["titles"] != nil { query["redirects"] = [["from": "獺祭", "to": "惊蛰"]] }
        }
        return .init(data: try JSONSerialization.data(withJSONObject: ["query": query]), status: 200, url: request.url)
    }
    func values(_ key: String) -> [String] {
        requests.compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == key }?.value }
    }
}
private func checkPlan(_ result: RecognitionResult, titles: Set<String>, searches: [String]? = nil, exactBatches: Int = 1) async throws {
    let transport = PlanTransport()
    let sources = try await WikipediaReviewCollector(transport: { try await transport.fetch($0) }).collect(for: result)
    let batches = await transport.values("titles")
    #expect(batches.count == exactBatches)
    #expect(Set(batches.flatMap { $0.components(separatedBy: "|") }) == titles)
    let actualSearches = await transport.values("gsrsearch")
    if let searches { #expect(Set(actualSearches) == Set(searches)) }
    #expect(actualSearches.count <= 2)
    #expect(await transport.requests.count <= exactBatches + 2)
    #expect(sources.isEmpty)
}

@Suite struct SemanticEntityBaseline {
    @Test func case01DassaiProductBrandAndManufacturerHaveIndependentLookupCoverage() async throws {
        let r = try entityPlanResult([
            namedEntity("獺祭 純米大吟釀 磨き二割三分", aliases: ["獺祭23", "Dassai 23"]),
            namedEntity("獺祭", id: 1, role: .related, kind: .brand, aliases: ["Dassai"], relation: .brand_of),
            namedEntity("旭酒造株式會社", id: 2, role: .related, kind: .company, aliases: ["旭酒造"], relation: .manufacturer_of)])
        #expect(r.searchEntities?[0].aliases.contains("獺祭") == false)
        try await checkPlan(r, titles: ["獺祭 純米大吟釀 磨き二割三分", "獺祭23", "獺祭", "Dassai", "旭酒造株式會社", "旭酒造"], searches: ["獺祭 純米大吟釀 磨き二割三分", "獺祭"], exactBatches: 2)
    }
    @Test func case02JohnnieWalkerKeepsMultiwordBrandAndProduct() async throws {
        let r = try entityPlanResult([namedEntity("Johnnie Walker Black Label"), namedEntity("Johnnie Walker", id: 1, role: .related, kind: .brand, relation: .brand_of)])
        try await checkPlan(r, titles: ["Johnnie Walker Black Label", "Johnnie Walker"], searches: ["Johnnie Walker Black Label", "Johnnie Walker"])
        #expect(r.names == ["Johnnie Walker Black Label"] && r.searchEntities?.count == 2)
    }
    @Test func case03BookAndPublicAuthorRemainSeparateWithoutInventingAuthorRelation() async throws {
        let author = SearchEntity(id: 1, role: .text, kind: .person, name: "合成作者", basis: .text, sourceRole: .public_text,
                                  sourceText: "合成作者", contextText: ["公開文學獎得主", "公開作品：遠方的書"])
        let r = try entityPlanResult([namedEntity("A Book: The Long Road"), author])
        try await checkPlan(r, titles: ["A Book: The Long Road", "合成作者"], exactBatches: 2)
        #expect(r.searchEntities?.last?.relation == SearchEntity.Relation.none)
        let unsupported = SearchEntity(id: 1, role: .text, kind: .person, name: "合成作者", sourceRole: .public_text, sourceText: "合成作者")
        #expect(SearchEntity.matching(try entityPlanResult([namedEntity("A Book: The Long Road"), unsupported])).count == 1)
    }
    @Test func case04MultiwordCompanyIsOnePublicTextEntity() async throws {
        let r = try entityPlanResult([namedEntity("紙本刊物", kind: .object), namedEntity("The New York Times Company", id: 1, role: .text, kind: .company)])
        try await checkPlan(r, titles: ["紙本刊物", "The New York Times Company"], exactBatches: 2)
        #expect(r.searchEntities?.last?.relation == SearchEntity.Relation.none)
    }
    @Test func case05PunctuationAndSpacesSurviveQueryEncoding() async throws {
        let r = try entityPlanResult([namedEntity("Ben & Jerry’s", kind: .brand), namedEntity("AT&T", id: 1, role: .text, kind: .company)])
        try await checkPlan(r, titles: ["Ben & Jerry’s", "AT&T"], searches: ["Ben & Jerry’s", "AT&T"])
        #expect(r.text == ["Ben & Jerry’s", "AT&T"])
    }
    @Test func case06UnbrandedGlassDoesNotGainBrandOrCompany() async throws {
        let r = try entityPlanResult([namedEntity("玻璃杯", kind: .object)])
        try await checkPlan(r, titles: ["玻璃杯"], searches: ["玻璃杯"])
        #expect(SearchEntity.matching(r).count == 1)
    }
    @Test func case07ModelAndEditionStayPartOfTheIdentity() async throws {
        let r = try entityPlanResult([namedEntity("Fixture X-T5 2026 Edition", aliases: ["Fixture X-T5"] )])
        try await checkPlan(r, titles: ["Fixture X-T5 2026 Edition", "Fixture X-T5"], searches: ["Fixture X-T5 2026 Edition"])
        #expect(r.names == ["Fixture X-T5 2026 Edition"])
    }
    @Test func case08ImporterIsNotConvertedToManufacturer() async throws {
        let r = try entityPlanResult([namedEntity("合成商品23"), namedEntity("合成進口公司", id: 1, role: .text, kind: .company)])
        try await checkPlan(r, titles: ["合成商品23", "合成進口公司"])
        #expect(r.searchEntities?.contains { $0.relation == .manufacturer_of } == false)
    }
    @Test func case09RedirectRemainsACandidateAndCannotSuppressFullText() async throws {
        let r = try entityPlanResult([namedEntity("獺祭", kind: .brand)])
        let transport = PlanTransport(redirect: true)
        let sources = try await WikipediaReviewCollector(transport: { try await transport.fetch($0) }).collect(for: r)
        #expect(sources.map(\.pageID) == [71238])
        #expect(await transport.values("gsrsearch") == ["獺祭"])
        // Fixed negative stage-two reply: checks contract handling, not model judgement.
        let raw = String(decoding: try JSONEncoder().encode(WikipediaReviewAnswer(decision: .insufficient_evidence)), as: UTF8.self)
        let answer = try WikipediaSemanticReview.parse(raw, sources: sources, result: r)
        #expect(answer.decision == .insufficient_evidence && answer.relationship == .none && answer.sourceID.isEmpty)
        #expect(r.names == ["獺祭"])
    }
    @Test func case10FourEntitiesGetEightWholeTitlesWithinThreeLookups() async throws {
        let names = ["Alpha Product 23", "Beta Brand", "Gamma Company", "Delta Series"]
        let entities = names.enumerated().map { i, name in namedEntity(name, id: i, role: i == 0 ? .central : .text,
            aliases: ["Official Alias \(i)", "Unused Alias \(i)", "Another Alias \(i)"]) }
        let r = try entityPlanResult(entities)
        try await checkPlan(r, titles: Set(names + (0..<4).map { "Official Alias \($0)" }), searches: Array(names.prefix(2)))
    }
    @Test func case11RelatedAliasesCanSelectLaterContiguousEvidence() throws {
        let r = try entityPlanResult([namedEntity("合成產品23"), namedEntity("合成品牌", id: 1, role: .related, kind: .brand, aliases: ["Fixture Brand"], relation: .brand_of)])
        let quote = "The company owns Fixture Brand and makes products under that name."
        let excerpts = WikipediaReviewBudget.excerpts([.init(id: "p0", text: "這是一個合成公司的概述。"), .init(id: "p1", text: quote), .init(id: "p2", text: "無關的一般歷史段落。")], for: r)
        #expect(excerpts.contains { $0.id == "p1" && $0.text == quote })
        #expect(!excerpts.contains { $0.id == "p2" })
        #expect(excerpts.count <= 3)
    }
    @Test func case12RejectedEntitiesDoNotConsumePublicLookupSlots() async throws {
        let privateEntity = SearchEntity(id: 1, role: .text, kind: .person, name: "私人姓名", status: .personal_data, sourceRole: .private_identity, sourceText: "私人姓名")
        let uncertain = SearchEntity(id: 2, role: .text, kind: .brand, name: "不確定品牌", status: .uncertain, sourceText: "不確定品牌")
        let conflict = SearchEntity(id: 3, role: .text, kind: .company, name: "衝突公司", status: .conflict, sourceText: "衝突公司")
        let r = try entityPlanResult([namedEntity("公開物件", kind: .object), privateEntity, uncertain, conflict])
        try await checkPlan(r, titles: ["公開物件"], searches: ["公開物件"])
        #expect(r.searchEntities?.count == 4 && SearchEntity.matching(r).count == 1)
    }
    @Test func case13OldCardAndFailedRefreshKeepExactSavedEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = RecognitionArchive(root: root), id = UUID(), attempt = UUID()
        let r = try entityPlanResult([namedEntity("Old Name: Full 23", aliases: ["Old Alias"])])
        let raw = #"{"schema_version":17,"names":["Old Name: Full 23"],"legacy":"original spaces & punctuation"}"#
        _ = try await archive.create(id: id, jpeg: Data([1,2,3]), capturedAt: Date())
        let original = try await archive.complete(id: id, result: r, message: nil, modelResponse: .capture(raw, sourceImageID: id, attemptID: id, appVersion: "0.1.0", appBuild: "64", promptRevision: "P20-English-concise-entity-zhTW1"))
        let reopened = try #require(try await RecognitionArchive(root: root).load().records.first)
        #expect(reopened.result == original.result && reopened.modelJSONDocument.rawText == raw)
        _ = try await archive.beginRetry(id: id, attemptID: attempt)
        let failed = try await archive.complete(id: id, result: nil, message: "合成失敗", attemptID: attempt)
        #expect(failed.presentationResult == original.result && failed.modelJSONDocument.rawText == raw)
        #expect(failed.shareDocument() == original.shareDocument())
        #expect(try await archive.image(for: failed) == Data([1,2,3]))
    }
}

import Foundation
import Testing
@testable import GlanceCore

private let lead43 = "曙光公司是一家釀酒企業，生產多種飲料；其中包括初しぼり啤酒。"
private let product43 = "初しぼり生ビール\n只使用第一道麥芽汁生產的啤酒，是該公司的主力商品。"
private func result43(source: String = "初しぼり", contexts: [String] = [],
                      name: String = "曙光初榨啤酒", kind: SearchEntity.Kind = .product,
                      basis: SearchCandidate.Basis = .text, version: Int = 16,
                      text: [String]? = nil, related: Bool = false,
                      sourceRole: SearchCandidate.SourceRole = .product_label) throws -> RecognitionResult {
    var entities: [SearchEntity] = [.init(kind: kind, name: name, aliases: ["Aurora First Brew"],
        basis: basis, sourceRole: sourceRole, sourceText: source, contextText: contexts)]
    if related { entities.append(.init(id: 1, role: .related, kind: .brand, name: "曙光公司", basis: .logo,
        relation: .brand_of, relatedTo: 0)) }
    let wire: [String: Any] = ["schema_version": version, "names": [name], "summary": "合成回歸案例",
        "text": text ?? ([source] + contexts), "search_entities": try JSONSerialization.jsonObject(with: JSONEncoder().encode(entities))]
    return try CameraAnswer.parse(String(decoding: JSONSerialization.data(withJSONObject: wire), as: UTF8.self), expectingStructured: true)
}
private func row43(section: String = product43, lead: String = lead43) -> [String: Any] {
    ["pageid": 4301, "ns": 0, "title": "曙光公司", "canonicalurl": "https://zh.wikipedia.org/wiki/Aurora",
     "extract": lead + "\n\n== 現行商品 ==\n=== 啤酒 ===\n" + section]
}
private func page43(_ result: RecognitionResult, section: String = product43, lead: String = lead43) throws -> EntityWikipediaPage {
    try #require(EntityWikipediaPage.parse(row43(section: section, lead: lead), supplement: true,
        entities: SearchEntity.matching(result), contractVersion: result.searchContractVersion))
}
private func proof43(_ result: RecognitionResult, page: EntityWikipediaPage? = nil, id: Int = 0) throws -> EntityWikipediaEvidence? {
    guard let entity = SearchEntity.matching(result).first(where: { $0.id == id }) else { return nil }
    return EntityWikipediaEvidence.verify(page: try page ?? page43(result), entity: entity, in: result).0
}

@Test func wiki43OriginalPhraseBindsTranslatedProductToActualManufacturingParagraph() throws {
    for version in [15, 16] {
        let result = try result43(version: version), proof = try #require(try proof43(result))
        #expect(proof.entityID == 0 && proof.role == .manufacturer)
        #expect(proof.relationship == "曙光公司／現行產品／" + product43)
        #expect(proof.isValid(for: result))
        #expect(result.searchEntities?.first?.aliases == ["Aurora First Brew"])
        #expect(SearchEntity.googleTerms(for: result) == "曙光初榨啤酒 Aurora First Brew")
    }
}
@Test func wiki43ContextProductWithTrademarkWorksWithoutInventingAlias() throws {
    let result = try result43(source: "AURORA BEER", contexts: ["AURORA BEER", "初しぼり®"])
    let proof = try #require(try proof43(result))
    #expect(proof.relationship == "曙光公司／現行產品／" + product43)
    #expect(result.searchEntities?.first?.contextText.last == "初しぼり®")
    #expect(result.searchEntities?.first?.sourceText == "AURORA BEER")
}
@Test func wiki43HistoricalProseCannotBecomeProductHeadingOrBrandShortcut() throws {
    let unrelated = try result43(source: "別款商品", related: true)
    let historical = "曙光公司創業以來一直釀造另一種拉格啤酒。\n採用傳統方式釀造並且生產其他口味的飲料。"
    let page = try page43(unrelated, section: historical)
    #expect(page.manufacturedEntries.isEmpty)
    #expect(try proof43(unrelated, page: page) == nil)
    #expect(try proof43(unrelated, page: page, id: 1) == nil)
    // Older persisted evidence must be rechecked too, not just new API parsing.
    let oldPage = EntityWikipediaPage(id: page.id, title: page.title, url: page.url, lead: page.lead,
        redirects: [], categories: [], officialNames: [], facts: [], passages: [],
        manufacturedEntries: [historical], supplemented: true)
    #expect(try proof43(unrelated, page: oldPage, id: 1) == nil)
}
@Test func wiki43RelatedBrandUsesCentralProductProofAndCannotSelectLagerHistory() throws {
    let result = try result43(related: true)
    let historical = "曙光公司創業以來一直釀造另一種拉格啤酒。\n採用傳統方式釀造並且生產其他口味的飲料。\n"
    let page = try page43(result, section: historical + product43)
    for id in [0, 1] {
        let proof = try #require(try proof43(result, page: page, id: id))
        #expect(proof.relationship == "曙光公司／現行產品／" + product43)
        #expect(proof.role == .manufacturer)
    }
}
@Test func wiki43ManufacturingRejectsImportedLicensedNegativeAndCompetingProduct() throws {
    let result = try result43()
    for prefix in ["授權進口，", "委託代工，", "代理，", "其他公司", "競爭品牌", "並非"] {
        let section = product43.replacingOccurrences(of: "只使用", with: prefix + "只使用")
        #expect(try proof43(result, page: page43(result, section: section)) == nil)
    }
    #expect(try proof43(result, page: page43(result, section: "初しぼり生ビール\n這段只介紹包裝外觀，並未說明商品與公司關係。")) == nil)
    #expect(try proof43(result, page: page43(result, lead: "曙光公司是一家投資公司，提供管理與金融服務。")) == nil)
}
@Test func wiki43GenericFlavorAndCompanyIdentityCannotProveSpecificProduct() throws {
    for source in ["經典原味", "Original", "曙光公司"] {
        let result = try result43(source: source, related: true)
        let page = try page43(result, section: source + "\n只使用第一道麥芽汁生產的啤酒，是該公司的主力商品。")
        #expect(try proof43(result, page: page) == nil)
        #expect(try proof43(result, page: page, id: 1) == nil)
    }
}
@Test func wiki43MultipleProductContextsDoNotChooseFirstManufacturedEntry() throws {
    let result = try result43(source: "AURORA BEER", contexts: ["初しぼり", "夕しぼり"])
    let section = product43 + "\n" + product43.replacingOccurrences(of: "初しぼり", with: "夕しぼり")
    #expect(try proof43(result, page: page43(result, section: section)) == nil)
}
@Test func wiki43EnglishBoundariesAndUnanchoredOrPrivateContextStillReject() throws {
    let result = try result43(source: "Core")
    #expect(try proof43(result, page: page43(result, section: product43.replacingOccurrences(of: "初しぼり", with: "ScoreBox"))) == nil)
    for text in [["AURORA BEER"], ["AURORA BEER", "患者服用初しぼり"]] {
        let invalid = try result43(source: "AURORA BEER", contexts: ["初しぼり"], text: text)
        #expect(SearchEntity.matching(invalid).isEmpty)
        #expect(try proof43(invalid) == nil)
    }
}
@Test func wiki43SeriesAndFlavorNamesNeedSameLiteralProductEvidence() throws {
    for kind in [SearchEntity.Kind.product, .series] {
        let result = try result43(name: "曙光初榨經典原味", kind: kind)
        #expect(try proof43(result)?.relationship == "曙光公司／現行產品／" + product43)
    }
}
@Test func wiki43LogoProductWithAnchoredLabelNormalizesToText() throws {
    let result = try result43(basis: .logo)
    #expect(SearchEntity.matching(result).first?.basis == .text)
    #expect(result.entityDiagnostics?.first?.adjustments?.contains("logoProductValidatedAsText") == true)
    #expect(try proof43(result)?.relationship == "曙光公司／現行產品／" + product43)
}
@Test func wiki43LogoProductFallbackDoesNotAdmitAbsentPrivateOrVisualOnlySources() throws {
    for invalid in [try result43(source: "", basis: .logo),
                    try result43(basis: .logo, text: ["完全不同的文字"]),
                    try result43(basis: .logo, text: ["患者服用初しぼり"]),
                    try result43(basis: .logo, version: 15),
                    try result43(basis: .logo, sourceRole: .object_appearance)] {
        #expect(SearchEntity.matching(invalid).isEmpty)
    }
}
@Test func wiki43BackLabelKeepsProductSearchRatherThanImporterWithoutInventedProductProof() throws {
    let entities: [SearchEntity] = [
        .init(kind: .product, name: "AURORA 啤酒", aliases: ["曙光公司"], basis: .logo, sourceText: "製造廠商曙光公司"),
        .init(id: 1, role: .related, kind: .company, name: "曙光公司", sourceRole: .public_text,
              sourceText: "製造廠商曙光公司", relation: .manufacturer_of, relatedTo: 0),
        .init(id: 2, role: .text, kind: .company, name: "海島進口公司", sourceRole: .public_text, sourceText: "進口商海島進口公司")]
    let wire: [String: Any] = ["schema_version": 16, "names": ["AURORA 啤酒"], "summary": "合成背面標籤",
        "text": ["製造廠商曙光公司", "進口商海島進口公司"],
        "search_entities": try JSONSerialization.jsonObject(with: JSONEncoder().encode(entities))]
    let result = try CameraAnswer.parse(String(decoding: JSONSerialization.data(withJSONObject: wire), as: UTF8.self), expectingStructured: true)
    #expect(SearchEntity.matching(result).count == 3)
    #expect(SearchEntity.googleTerms(for: result) == "AURORA 啤酒 曙光公司")
    #expect(try proof43(result) == nil)
    #expect(try proof43(result, id: 1) == nil)
}
@Test func wiki43DisambiguationCannotGainProductSourceProof() throws {
    let result = try result43()
    #expect(EntityWikipediaPage.parse(row43(lead: "曙光公司可能指不同公司，這是消歧義頁面。"), supplement: true,
        entities: SearchEntity.matching(result), contractVersion: 16) == nil)
}

private actor Transport43 {
    var urls: [URL] = []
    func send(_ request: URLRequest) throws -> WikipediaHTTPResponse {
        let url = request.url!; urls.append(url)
        let supplement = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.contains { $0.name == "pageids" }
        var row = row43(section: supplement ? product43 : "", lead: "曙光公司是一家釀酒企業，生產多種不同風味的包裝飲料。")
        row["redirects"] = [["title": "AURORA"]]
        return .init(data: try JSONSerialization.data(withJSONObject: ["query": ["pages": [row]]]), status: 200, url: url)
    }
}
@Test func wiki43AnchoredCompanyContextOnlyEnablesBoundedSupplementNeverExtraSearchTerms() async throws {
    let result = try result43(contexts: ["AURORA BEER", "初しぼり"])
    let transport = Transport43()
    let found = await WikipediaLookupService(transport: { try await transport.send($0) }).lookupReferences(for: result)
    #expect(found.subject?.entityEvidence?.relationship == "曙光公司／現行產品／" + product43)
    let urls = await transport.urls
    #expect(urls.count == 3)
    let searches = urls.compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "gsrsearch" }?.value }
    #expect(searches == ["曙光初榨啤酒", "Aurora First Brew"])
}
@Test func wiki43UnrelatedOrAbsentCompanyContextCannotEnableSupplement() async throws {
    for contexts in [[], ["AURORAWOOD BEER"]] {
        let result = try result43(contexts: contexts), transport = Transport43()
        let found = await WikipediaLookupService(transport: { try await transport.send($0) }).lookupReferences(for: result)
        #expect(found.subject == nil)
        #expect(await transport.urls.count == 2)
    }
}
@Test func wiki43ShortExplicitProductNamesRetainExistingManufacturingEvidence() throws {
    let result = try result43(source: "曙光", name: "曙光")
    let section = "曙光生ビール\n只使用第一道麥芽汁生產的啤酒，是該公司的主力商品。"
    #expect(try proof43(result, page: page43(result, section: section))?.role == .manufacturer)
}

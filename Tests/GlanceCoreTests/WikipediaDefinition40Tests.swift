import Foundation
import Testing
@testable import GlanceCore

private let brandLead40 = "曙光（Aurora，早期稱為晴光（Sun），另一地區稱為Cloud），是一種點心系列的商品名，也是一個食品品牌。"
private let productList40 = "現有三種商品：直接切片的「晴光片」，烘烤的「旋脆片」（Spiral Crisps），以及「曙光卷」。"

private func result40(source: String = "旋脆片", product: String = "曙光旋脆片原味", version: Int = 15) throws -> RecognitionResult {
    let entities: [SearchEntity] = [
        .init(kind: .product, name: product, sourceText: source),
        .init(id: 1, role: .related, kind: .brand, name: "曙光", aliases: ["Aurora"], basis: .logo, relation: .brand_of, relatedTo: 0)
    ]
    let wire: [String: Any] = ["schema_version": version, "names": [product], "summary": "不把模型摘要當百科關係證據。",
        "text": ["Aurora", "旋脆片", "原味", "Original"],
        "search_entities": try JSONSerialization.jsonObject(with: JSONEncoder().encode(entities))]
    return try CameraAnswer.parse(String(decoding: JSONSerialization.data(withJSONObject: wire), as: UTF8.self), expectingStructured: true)
}
private func row40(_ lead: String, title: String = "曙光", id: Int = 4001) -> [String: Any] {
    ["pageid": id, "ns": 0, "title": title, "canonicalurl": "https://zh.wikipedia.org/wiki/" + title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!, "extract": lead, "redirects": [["title": "Aurora"]]]
}
private func page40(_ lead: String = brandLead40 + productList40, in result: RecognitionResult) throws -> EntityWikipediaPage {
    try #require(EntityWikipediaPage.parse(row40(lead), supplement: true, entities: SearchEntity.matching(result)))
}
private func proof40(_ page: EntityWikipediaPage, _ result: RecognitionResult) throws -> (EntityWikipediaEvidence?, WikipediaDiagnostic.Outcome) {
    try EntityWikipediaEvidence.verify(page: page, entity: #require(SearchEntity.matching(result).first { $0.id == 1 }), in: result)
}

@Test func wiki40NestedAliasesDoNotBecomeDefinitionAndLegacyStaysUnchanged() throws {
    let result = try result40(), page = try page40(in: result)
    #expect(page.kind == .object && page.kind(for: 14) == .object)
    #expect(page.kind(for: 15) == .brand)
    #expect(EntityWikipediaPage.removingParentheticalAnnotations("主體（外層(inner)）是一個品牌。") == "主體是一個品牌。")
}
@Test func wiki40UnbalancedOrMismatchedParenthesesFailClosed() throws {
    for lead in ["曙光（別名是一個食品品牌。", "曙光）是一個合成食品品牌。", "曙光（Alias)是一個食品品牌。"] {
        #expect(EntityWikipediaPage.removingParentheticalAnnotations(lead) == nil)
        #expect(try page40(lead, in: result40()).kind(for: 15) == .unknown)
    }
}
@Test func wiki40OnlyCoordinatedDefinitionsDescribeSameSubject() throws {
    let result = try result40()
    #expect(try page40("曙光是一種點心系列的商品名，也是一個食品品牌。", in: result).kind(for: 15) == .brand)
    #expect(try page40("曙光是一種點心系列的商品名，另一家公司是一個食品品牌。", in: result).kind(for: 15) == .series)
    #expect(try page40("曙光是一種點心系列的商品名。另一家是食品品牌。", in: result).kind(for: 15) == .series)
    #expect(try page40("曙光是一個食品品牌，條目沒有包含包裝標語。", in: result).kind(for: 15) == .brand)
}
@Test func wiki40AliasBrandWordingCannotReclassifyCompany() throws {
    let page = try page40("曙光（曾使用別家品牌（Alias）），是一家製造商，提供多種食品。", in: result40())
    #expect(page.kind(for: 15) == .company)
}
@Test func wiki40NegativeOrDescriptiveCopulaDoesNotEstablishBrand() throws {
    let result = try result40()
    for lead in ["曙光不是一個品牌，而是一件一般物件。", "曙光在廣告中被稱為食品品牌，沒有其他身分證據。"] {
        #expect(try page40(lead, in: result).kind(for: 15) == .unknown)
    }
}
@Test func wiki40OwnExplicitQuotedProductListSupportsBrandNotExactVariant() throws {
    let result = try result40(), page = try page40(in: result)
    let proof = try #require(proof40(page, result).0)
    #expect(proof.role == .brand && proof.relationship?.contains("同頁商品名") == true)
    #expect(proof.reference(for: result, at: Date()).displayTitle == "曙光（品牌）")
    let product = try #require(SearchEntity.matching(result).first { $0.id == 0 })
    #expect(EntityWikipediaEvidence.verify(page: page, entity: product, in: result).0 == nil)
    #expect(result.names == ["曙光旋脆片原味"] && result.searchEntities?.first?.aliases == [])
}
@Test func wiki40OtherActorNegationLicensingAndCompetitorListsCannotBind() throws {
    let result = try result40()
    for list in ["其他公司現有商品：「旋脆片」等食品。", "目前別家公司商品：「旋脆片」等食品。",
                 "現有三種商品：不包含「旋脆片」，沒有出售。", "現有商品：代理「旋脆片」和其他食品。",
                 "現有商品：「旋脆片」是競爭品牌的點心。", "現有商品：授權「旋脆片」在此地銷售。"] {
        #expect(try proof40(page40(brandLead40 + list, in: result), result).0 == nil)
    }
}
@Test func wiki40LooseSubstringAndUnquotedMentionAreNotProductListProof() throws {
    let result = try result40()
    for list in ["現有商品：烘烤的「超級旋脆片」和「其他點心」。", "現有商品：烘烤的旋脆片以及多種點心。",
                 "有人提到「旋脆片」的包裝，但是沒有說明品牌關係。"] {
        #expect(try proof40(page40(brandLead40 + list, in: result), result).0 == nil)
    }
}
@Test func wiki40GenericFlavorAndUnboundSourceCannotSupplyProductIdentity() throws {
    for (source, name) in [("原味", "曙光原味"), ("Original", "Aurora Original") , ("旋脆片", "曙光別的商品")] {
        let result = try result40(source: source, product: name)
        let page = try page40(brandLead40 + "現有商品：「\(source)」及多種食品。", in: result)
        #expect(try proof40(page, result).0 == nil)
    }
}
@Test func wiki40BrandListCannotInventManufacturerOrOverrideWrongIdentity() throws {
    let result = try result40(), brand = try #require(SearchEntity.matching(result).last)
    let company = try page40("曙光是一家投資公司。" + productList40, in: result)
    #expect(try proof40(company, result).0 == nil)
    let wrong = try #require(EntityWikipediaPage.parse(row40("另一家是一個食品品牌。" + productList40, title: "另一家"), entities: [brand]))
    // The fixture's explicit Aurora redirect establishes identity; remove it to test the wrong page.
    var row = row40(wrong.lead, title: "另一家"); row["redirects"] = []
    let unrelated = try #require(EntityWikipediaPage.parse(row, entities: [brand]))
    #expect(try proof40(unrelated, result).0 == nil)
}
@Test func wiki40LegacyCardsDoNotAcquireNewBrandListEvidence() throws {
    let old = try result40(version: 14), page = try page40("曙光是一個食品品牌。" + productList40, in: old)
    #expect(try proof40(page, old).0 == nil)
}
@Test func wiki40FormalLookupChoosesOneBrandWithBoundedRequestsAndNegativeAmbiguity() async throws {
    let result = try result40()
    let data = try JSONSerialization.data(withJSONObject: ["query": ["pages": [row40(brandLead40 + productList40)]]])
    let service = WikipediaLookupService(transport: { request in .init(data: data, status: 200, url: request.url) })
    let found = await service.lookupReferences(for: result)
    #expect(found.subject?.displayTitle == "曙光（品牌）" && found.subject?.isCurrent(for: result) == true)
    #expect(found.diagnostics.filter { $0.stage == .transport }.count <= 6)
    let duplicate = try JSONSerialization.data(withJSONObject: ["query": ["pages": [row40(brandLead40 + productList40), row40(brandLead40 + productList40, id: 4002)]]])
    let uncertain = await WikipediaLookupService(transport: { request in .init(data: duplicate, status: 200, url: request.url) }).lookupReferences(for: result)
    #expect(uncertain.subject == nil && uncertain.diagnostics.contains { $0.outcome == .ambiguous })
}

@Test func wiki40LaterTruncatedHistoryDoesNotEraseValidFirstDefinition() throws {
    let result = try result40()
    #expect(try page40("曙光是一個食品品牌。歷史段落（未完成", in: result).kind(for: 15) == .brand)
    #expect(try page40("林範例是一位作家，也是品牌的代言人。", in: result).kind(for: 15) == .person)
}

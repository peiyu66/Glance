import Foundation
import Testing
@testable import GlanceCore

private let lead42 = "曙光（Aurora）是一個合成點心品牌，提供多種包裝食品。"
private let list42 = "現有三種商品：烘烤的「旋脆片」，切片的「晴光片」，以及「曙光卷」。"
private func result42(name: String = "旋脆片原味", source: String = "曙光旋脆片原味",
                      contexts: [String] = ["曙光", "旋脆片", "原味"], text: [String]? = nil,
                      version: Int = 16, sourceRole: SearchCandidate.SourceRole = .product_label) throws -> RecognitionResult {
    let entities: [SearchEntity] = [
        .init(kind: .product, name: name, sourceRole: sourceRole, sourceText: source, contextText: contexts),
        .init(id: 1, role: .related, kind: .brand, name: "曙光", aliases: ["Aurora"], basis: .logo, relation: .brand_of, relatedTo: 0)
    ]
    let wire: [String: Any] = ["schema_version": version, "names": [name], "summary": "合成商品測試",
        "text": text ?? ["Aurora曙光", "旋脆片", "原味"],
        "search_entities": try JSONSerialization.jsonObject(with: JSONEncoder().encode(entities))]
    return try CameraAnswer.parse(String(decoding: JSONSerialization.data(withJSONObject: wire), as: UTF8.self), expectingStructured: true)
}
private func row42(_ lead: String = lead42 + list42, title: String = "曙光", id: Int = 4201) -> [String: Any] {
    ["pageid": id, "ns": 0, "title": title,
     "canonicalurl": "https://zh.wikipedia.org/wiki/" + title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!, "extract": lead]
}
private func proof42(_ result: RecognitionResult, row: [String: Any] = row42()) throws -> EntityWikipediaEvidence? {
    let values = SearchEntity.matching(result)
    guard let brand = values.first(where: { $0.id == 1 }) else { return nil }
    let page = try #require(EntityWikipediaPage.parse(row, supplement: true, entities: values, contractVersion: result.searchContractVersion))
    return EntityWikipediaEvidence.verify(page: page, entity: brand, in: result).0
}

@Test func wiki42LongSourceUsesLiteralContextProductAndKeepsBrandRole() throws {
    let result = try result42(), found = try proof42(result)
    let proof = try #require(found)
    #expect(SearchEntity.matching(result).count == 2)
    #expect(proof.role == .brand && proof.relationship?.contains("同頁商品名") == true)
    #expect(proof.reference(for: result, at: Date()).displayTitle == "曙光（品牌）")
    #expect(proof.isValid(for: result))
    #expect(result.text == ["Aurora曙光", "旋脆片", "原味"])
    #expect(result.searchEntities?.first?.sourceText == "曙光旋脆片原味")
    #expect(result.searchEntities?.first?.aliases.isEmpty == true)
    let central = try #require(result.searchEntities?.first)
    #expect(EntityWikipediaEvidence.verify(page: proof.page, entity: central, in: result).0 == nil)
}

@Test func wiki42WhitespaceAndDuplicateContextDoNotChangeProductProof() throws {
    for source in ["曙光旋脆片原味", "曙光 旋脆片 原味", "曙光\n旋脆片\n原味"] {
        let result = try result42(source: source, contexts: ["旋脆片", "旋脆片", "原味"])
        #expect(try proof42(result)?.role == .brand)
    }
}

@Test func wiki42ContextMustBelongToSourceCentralNameAndOriginalText() throws {
    let unrelatedName = try result42(name: "曙光別的點心")
    let unrelatedSource = try result42(source: "曙光晴光片原味", contexts: ["旋脆片"], text: ["曙光晴光片原味", "旋脆片"])
    let absentOriginal = try result42(contexts: ["晴光片"])
    #expect(SearchEntity.matching(unrelatedName).count == 2)
    #expect(SearchEntity.matching(unrelatedSource).count == 2)
    for result in [unrelatedName, unrelatedSource, absentOriginal] { #expect(try proof42(result) == nil) }
}

@Test func wiki42GenericFlavorOrBrandItselfCannotBindProduct() throws {
    for anchor in ["經典原味", "Original", "Aurora"] {
        let result = try result42(name: anchor + " 點心", source: "曙光 " + anchor + " 點心", contexts: [anchor], text: ["曙光", anchor, "點心"])
        #expect(SearchEntity.matching(result).count == 2)
        let row = row42(lead42 + "現有商品：「\(anchor)」以及多種包裝點心。")
        #expect(try proof42(result, row: row) == nil)
    }
}

@Test func wiki42EnglishWordBoundaryAndLiteralSourceStayIntact() throws {
    let joinedWord = try result42(name: "Core Original", source: "Aurora ScoreBox", contexts: ["Core"], text: ["Aurora ScoreBox", "Core"])
    #expect(SearchEntity.matching(joinedWord).count == 2)
    #expect(try proof42(joinedWord, row: row42(lead42 + "現有商品：「Core」以及多種包裝點心。")) == nil)
    let differentScript = try result42(name: "脆乐片原味", source: "曙光脆樂片原味", contexts: ["脆乐片"], text: ["曙光脆樂片原味", "脆乐片"])
    #expect(SearchEntity.matching(differentScript).count == 2)
    #expect(try proof42(differentScript, row: row42(lead42 + "現有商品：「脆樂片」以及多種包裝點心。")) == nil)
}

@Test func wiki42UnquotedSubstringAndOrdinaryMentionCannotReplaceOwnList() throws {
    let result = try result42()
    for list in ["現有商品：烘烤的「超級旋脆片」與「晴光片」。", "現有商品：烘烤的旋脆片以及多種點心。",
                 "文章介紹「旋脆片」的包裝，沒有說明品牌關係。"] {
        #expect(try proof42(result, row: row42(lead42 + list)) == nil)
    }
}

@Test func wiki42OtherActorsNegativeListsAndLicensingRemainRejected() throws {
    let result = try result42()
    for list in ["其他公司現有商品：「旋脆片」等食品。", "目前別家公司商品：「旋脆片」等食品。",
                 "現有商品：不包含「旋脆片」，沒有出售。", "現有商品：代理「旋脆片」等多種食品。",
                 "現有商品：「旋脆片」是競爭品牌的點心。", "現有商品：授權「旋脆片」在此地銷售。",
                 "現有商品：已停止推出「旋脆片」等食品。", "現有商品：進口「旋脆片」等多種食品。"] {
        #expect(try proof42(result, row: row42(lead42 + list)) == nil)
    }
}

@Test func wiki42BrandIdentityTypeAndManufacturerEvidenceRemainRequired() throws {
    let result = try result42()
    #expect(try proof42(result, row: row42("另一家是一個合成食品品牌。" + list42, title: "另一家")) == nil)
    #expect(try proof42(result, row: row42("曙光是一家投資公司，提供多種服務。" + list42)) == nil)
    #expect(try proof42(result, row: row42("曙光是一家食品製造商，提供多種服務。" + list42)) == nil)
    let publicText = try result42(sourceRole: .public_text)
    #expect(SearchEntity.matching(publicText).count == 2)
    #expect(try proof42(publicText) == nil)
}

@Test func wiki42MultipleListedProductAnchorsAreAmbiguous() throws {
    let result = try result42(name: "旋脆片晴光片原味", source: "曙光旋脆片晴光片原味", contexts: ["旋脆片", "晴光片"], text: ["曙光旋脆片晴光片原味"])
    #expect(SearchEntity.matching(result).count == 2)
    #expect(try proof42(result) == nil)
}

@Test func wiki42LegacyLongSourceAndPrivateContextDoNotGainEvidence() throws {
    let old = try result42(text: ["Aurora曙光旋脆片原味"], version: 15)
    #expect(SearchEntity.matching(old).count == 2)
    #expect(try proof42(old) == nil)
    let privateResult = try result42(text: ["患者服用曙光", "旋脆片", "原味"])
    #expect(try proof42(privateResult) == nil)
}

@Test func wiki42FormalLookupPersistenceAndPageAmbiguityKeepOriginalContract() async throws {
    let result = try result42()
    let data = try JSONSerialization.data(withJSONObject: ["query": ["pages": [row42()]]])
    let found = await WikipediaLookupService(transport: { request in .init(data: data, status: 200, url: request.url) }).lookupReferences(for: result)
    let reference = try #require(found.subject)
    #expect(reference.displayTitle == "曙光（品牌）" && reference.isCurrent(for: result))
    let decoded = try JSONDecoder().decode(WikipediaReference.self, from: JSONEncoder().encode(reference))
    #expect(decoded == reference && decoded.isCurrent(for: result))
    #expect(found.diagnostics.filter { $0.stage == .transport }.count <= 6)
    let duplicate = try JSONSerialization.data(withJSONObject: ["query": ["pages": [row42(), row42(id: 4202)]]])
    let uncertain = await WikipediaLookupService(transport: { request in .init(data: duplicate, status: 200, url: request.url) }).lookupReferences(for: result)
    #expect(uncertain.subject == nil && uncertain.diagnostics.contains { $0.outcome == .ambiguous })
}

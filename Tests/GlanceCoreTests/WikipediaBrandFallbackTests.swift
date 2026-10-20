import Foundation
import Testing
@testable import GlanceCore

private func brandWire(name: String = "Lay’s 樂事 樂連連原味", summary: String = "這是原味洋芋片。", text: [String] = ["Lay’s 樂事\n樂連連\n原味"], wikipedia: Any? = nil, restriction: String? = nil, search: [String: Any]? = nil) throws -> RecognitionResult {
    var wire: [String: Any] = ["names": [name], "summary": summary, "text": text, "barcodes": [],
        "search": search ?? ["query": name, "category": "product"]]
    if let wikipedia { wire["wikipedia"] = wikipedia }
    if let restriction { wire["search_block_reason"] = restriction }
    return try CameraAnswer.parse(String(decoding: JSONSerialization.data(withJSONObject: wire), as: UTF8.self))
}
private func brandPage(_ title: String, definition: String, extra: [String: Any] = [:]) throws -> Data {
    var page: [String: Any] = ["pageid": 123, "ns": 0, "title": title,
        "canonicalurl": "https://zh.wikipedia.org/wiki/" + title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!, "extract": definition]
    page.merge(extra, uniquingKeysWith: { _, new in new })
    return try JSONSerialization.data(withJSONObject: ["query": ["pages": [page]]])
}

@Test func wikiMissingTopicsRecoverExplicitBilingualBrandWithoutProductNameGuessing() throws {
    for value: Any? in [nil, NSNull()] {
        let result = try brandWire(wikipedia: value)
        #expect(result.wikipediaCandidateStatus == .localBrandFallback)
        let topics = try #require(result.wikipediaTopics)
        #expect(topics.candidates == [.init(topic: "樂事", kind: .brand, evidence: "Lay’s 樂事")])
        #expect(topics.classTerms.isEmpty && topics.matchScope == .brandIdentity)
        let subject = try #require(WikipediaSubject.matching(result, allowLegacy: false))
        #expect(subject.candidateCount == 1 && subject.searchTitle == "樂事")
        #expect(subject.request.url?.host == "zh.wikipedia.org")
        #expect(!subject.request.url!.absoluteString.contains("%E5%8E%9F%E5%91%B3"))
        #expect(result.names == ["Lay’s 樂事 樂連連原味"] && result.text == ["Lay’s 樂事\n樂連連\n原味"])
    }
}

@Test func wikiBrandFallbackIsNotASpecificBrandWhitelist() throws {
    for (name, clue) in [("晴禾洋芋片", "品牌：晴禾"), ("山澄洋芋片", "山澄®"), ("晴禾原味洋芋片", "Sunny 晴禾")] {
        let result = try brandWire(name: name, text: [clue])
        #expect(result.wikipediaCandidateStatus == .localBrandFallback)
        let subject = try #require(WikipediaSubject.matching(result, allowLegacy: false))
        let ref = subject.reference(from: try brandPage(subject.searchTitle, definition: "\(subject.searchTitle)（Sunny）是一個製作洋芋片的品牌，販售多種口味。"), at: Date())
        #expect(ref?.relation?.kind == .brand)
    }
}

@Test func wikiBrandFallbackRejectsNounsManufacturerGuessAndAmbiguousBrands() throws {
    let samples: [(String, String, [String])] = [
        ("樂事樂連連原味", "這是洋芋片。", ["樂事", "樂連連", "原味"]),
        ("一般洋芋片包裝", "這是洋芋片。", ["Chips 洋芋片"]),
        ("精品咖啡包裝", "這是咖啡。", ["品牌：咖啡"]),
        ("Coffee 咖啡", "這是咖啡。", ["Brand: Coffee"]),
        ("台灣茶葉", "這是茶葉。", ["Taiwan 台灣"]),
        ("晴禾洋芋片", "這是洋芋片。", ["製造商：晴禾"]),
        ("晴禾洋芋片", "這是洋芋片。", ["品牌：晴禾", "品牌：山澄"]),
        ("晴禾洋芋片", "這是洋芋片。", ["品牌：山澄"]),
        ("Kellens 紙品", "這是紙巾。", ["Brand: Kellen"])
    ]
    for (name, summary, text) in samples {
        #expect(try brandWire(name: name, summary: summary, text: text).wikipediaTopics == nil)
    }
}

@Test func wikiBrandFallbackCannotBypassMetadataRefusalOrMalformedValue() throws {
    let rejected: [Any] = [false, "invalid", ["automatic_wikipedia": false], ["automatic_wikipedia": "true"],
        ["automatic_wikipedia": false, "category": "product", "class_terms": ["洋芋片"], "candidates": [["topic": "樂事", "kind": "brand", "evidence": "Lay’s 樂事"]]]]
    for value in rejected {
        let result = try brandWire(wikipedia: value)
        #expect(result.wikipediaCandidateStatus != .localBrandFallback)
        #expect(WikipediaSubject.matching(result, allowLegacy: false) == nil)
    }
    for restriction in ["sensitive", "uncertain", "conflict", "invalid"] {
        let result = try brandWire(restriction: restriction)
        #expect(result.wikipediaCandidateStatus == .blocked && result.wikipediaTopics == nil)
    }
    for permission: Any in [false, "true"] {
        let result = try brandWire(search: ["query": "樂事樂連連原味", "category": "product", "automatic_wikipedia": permission])
        #expect(result.wikipediaCandidateStatus == .disabled && result.wikipediaTopics == nil)
    }
    let nonProduct = try brandWire(search: ["query": "樂事樂連連原味", "category": "object"])
    #expect(nonProduct.wikipediaTopics == nil)
}

@Test func wikiBrandFallbackRejectsSensitiveAndUncertainContextEvenWithBrandClue() throws {
    for text in ["患者姓名：王小明", "私人訊息", "姓名：王小明", "銀行帳戶", "處方箋", "健康保健食品", "地址：台北市中山區某路1號", "a@example.test", "品牌歸屬不確定", "品牌不是樂事", "這是假冒品牌", "這是金融名片"] {
        let result = try brandWire(text: ["Lay’s 樂事", text])
        #expect(result.wikipediaTopics == nil)
    }
    #expect(try brandWire(name: "Actein 顆粒", summary: "這是藥品。", text: ["Brand: Actein"]).wikipediaTopics == nil)
}

@Test func wikiBrandFallbackStillRejectsPeopleNonBrandsAndDisambiguation() throws {
    let result = try brandWire(name: "Kellens 紙品", summary: "這是紙巾。", text: ["Brand: Kellens"])
    let subject = try #require(WikipediaSubject.matching(result, allowLegacy: false))
    for (definition, extra) in [
        ("Kellens是一位研究紙巾品牌的作家。", ["categories": [["title": "Category:作家"]]] as [String: Any]),
        ("Kellens是一個研究咖啡品牌的博物館。", [:]),
        ("Kellens是一個紙巾品牌，名稱也可能指其他事物。", ["pageprops": ["disambiguation": ""]])
    ] {
        #expect(subject.reference(from: try brandPage("Kellens", definition: definition, extra: extra), at: Date()) == nil)
    }
}

@Test func wikiCandidateDiagnosticsSurviveCopiesArchiveAndDoNotEnrichOldHistory() throws {
    let result = try brandWire(), id = UUID()
    let copied = result.withBarcodes(["123"]).withSourceImage(id)
    #expect(copied.wikipediaCandidateStatus == .localBrandFallback && copied.wikipediaTopics == result.wikipediaTopics)
    #expect(try JSONDecoder().decode(RecognitionResult.self, from: JSONEncoder().encode(copied)) == copied)
    var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
    old.removeValue(forKey: "wikipediaTopics"); old.removeValue(forKey: "wikipediaCandidateStatus")
    let restored = try JSONDecoder().decode(RecognitionResult.self, from: JSONSerialization.data(withJSONObject: old))
    #expect(restored.wikipediaCandidateStatus == nil && restored.wikipediaTopics == nil)
    #expect(WikipediaSubject.matching(restored, allowLegacy: false) == nil)
}

@Test func wikiModelCandidatesRemainAuthoritativeEvenWhenEvidenceInvalid() throws {
    let hints: [String: Any] = ["automatic_wikipedia": true, "category": "product", "class_terms": ["洋芋片"],
        "candidates": [["topic": "其他品牌", "kind": "brand", "evidence": "其他品牌"]]]
    let result = try brandWire(wikipedia: hints)
    #expect(result.wikipediaCandidateStatus == .modelProvided)
    #expect(result.wikipediaTopics?.candidates.first?.topic == "其他品牌")
    #expect(WikipediaSubject.matching(result, allowLegacy: false) == nil)
}

@Test func wikiFallbackNeverUsesTruncatedContextToClearPrivacy() throws {
    let lines = ["Lay’s 樂事"] + Array(repeating: "原味", count: 31) + ["患者姓名：某人"]
    #expect(try brandWire(text: lines).wikipediaTopics == nil)
    #expect(try brandWire(summary: "這是洋芋片。" + String(repeating: "一般描述", count: 400) + "私人紀錄").wikipediaTopics == nil)
    #expect(try brandWire(text: ["Lay’s 樂事", String(repeating: "標示", count: 501) + "病歷"]).wikipediaTopics == nil)
}


// De-identified necessary text from the Build19 real-card regression. No ID,
// timestamp, image, device or account fields; omitted Wiki is reconstructed,
// because the original model wire was not retained.
private let actualBrandSummary = "樂事是以馬鈴薯零食聞名的品牌；這款「樂連連」屬於其玉米零食系列，名稱與包裝上的玉米圖樣相呼應。"
private func actualBrandResult(summary: String = actualBrandSummary) throws -> RecognitionResult {
    try brandWire(name: "樂事樂連連原味", summary: summary, text: ["Lay's 樂事", "樂連連", "原味"],
                  search: ["query": "樂事 樂連連 原味", "category": "product"])
}
@Test func wikiActualBrandTextWorksAcrossSummaryWordingAndMissingClass() throws {
    for summary in [actualBrandSummary, "這是一款玉米零食。", "這是馬鈴薯製作的點心。", "這款產品標示為原味。", ""] {
        let result = try actualBrandResult(summary: summary)
        #expect(result.wikipediaCandidateStatus == .localBrandFallback)
        let subject = try #require(WikipediaSubject.matching(result, allowLegacy: false))
        let ref = try #require(subject.reference(from: brandPage("樂事", definition: "樂事（Lay's）是一種洋芋片系列的商品名，也是一個洋芋片品牌。"), at: Date()))
        #expect(ref.relation?.scope == .brandIdentity && ref.relation?.classTerm == "品牌")
        #expect(ref.relation?.relatedTopic == nil && ref.isCurrent(for: result))
        #expect(result.summary == summary)
    }
}
@Test func wikiBrandIdentityMatchesOtherBrandsWithoutClassVocabulary() throws {
    for (name, clue, title, definition) in [
        ("晴禾晨光款", "Sunny 晴禾", "晴禾", "晴禾（Sunny）是一個日用品品牌。"),
        ("山澄經典款", "品牌：山澄", "山澄", "山澄是一個戶外用品商標。"),
        ("Aster 經典款", "Aster®", "Aster", "Aster是一個家庭用品品牌。")
    ] {
        let result = try brandWire(name: name, summary: "", text: [clue])
        let subject = try #require(WikipediaSubject.matching(result, allowLegacy: false))
        #expect(subject.reference(from: try brandPage(title, definition: definition), at: Date())?.isCurrent(for: result) == true)
    }
}
@Test func wikiBrandIdentityNeedsOwnDefinitionAndBilingualAlias() throws {
    let result = try actualBrandResult(), subject = try #require(WikipediaSubject.matching(result, allowLegacy: false))
    for definition in [
        "樂事是一個洋芋片品牌。", // bilingual evidence must be corroborated
        "樂事（Other）是一個洋芋片品牌。",
        "樂事（Lay's）是一位研究品牌的作家。",
        "樂事（Lay's）是一個介紹食品品牌的博物館。",
        "樂事（Lay's）是一家品牌的供應商。",
        "樂事（Lay's）是專門代理日本咖啡品牌。",
        "樂事（Lay's）是品牌創辦人的名字。",
        "樂事（Lay's）不是品牌，只是一句話。",
        "樂事（Lay's）是一個活動。山澄是一個品牌。",
        "樂事（Lay's）是一個私人醫療品牌。"
    ] {
        #expect(subject.reference(from: try brandPage("樂事", definition: definition), at: Date()) == nil)
    }
    #expect(subject.reference(from: try brandPage("其他品牌", definition: "其他品牌（Lay's）是一個品牌。"), at: Date()) == nil)
}
@Test func wikiModelCannotSelectLocalBrandIdentityPolicy() throws {
    let metadata: [String: Any] = ["category": "product", "automatic_wikipedia": true, "class_terms": [],
        "match_scope": "brandIdentity", "candidates": [["topic": "樂事", "kind": "brand", "evidence": "Lay’s 樂事"]]]
    let result = try brandWire(wikipedia: metadata)
    #expect(result.wikipediaCandidateStatus == .modelProvided)
    #expect(WikipediaSubject.matching(result, allowLegacy: false) == nil)
    let original = try actualBrandResult()
    let copied = RecognitionResult(names: original.names, summary: original.summary, text: ["品牌：其他"], searchQuery: original.searchQuery,
        wikipediaTopics: original.wikipediaTopics, wikipediaCandidateStatus: .localBrandFallback)
    #expect(WikipediaSubject.matching(copied, allowLegacy: false) == nil)
}
@Test func wikiBrandIdentityDoesNotClaimProductClassOrRelaxModelClassChecks() throws {
    let local = try brandWire(name: "山澄晨光款", summary: "這是紙品。", text: ["品牌：山澄"])
    let page = try brandPage("山澄", definition: "山澄是一個製作咖啡的品牌。")
    let localSubject = try #require(WikipediaSubject.matching(local, allowLegacy: false))
    let reference = try #require(localSubject.reference(from: page, at: Date()))
    #expect(reference.relation?.scope == .brandIdentity && reference.relation?.classTerm == "品牌")
    let model = RecognitionResult(names: local.names, summary: local.summary, text: local.text, searchQuery: local.searchQuery,
        wikipediaTopics: .init(category: .product, automaticWikipediaAllowed: true, classTerms: ["紙品"], candidates: [.init(topic: "山澄", kind: .brand, evidence: "品牌：山澄")]), wikipediaCandidateStatus: .modelProvided)
    #expect(WikipediaSubject.matching(model, allowLegacy: false)?.reference(from: page, at: Date()) == nil)
    #expect(!reference.isCurrent(for: model))
}

@Test func wikiBrandIdentityConflictingAliasesRejectAndCacheDoesNotCrossAliases() throws {
    #expect(try brandWire(name: "晴禾晨光款", summary: "", text: ["Sunny 晴禾", "Other 晴禾"]).wikipediaTopics == nil)
    let a = try brandWire(name: "晴禾晨光款", summary: "", text: ["Sunny 晴禾", "品牌：晴禾"])
    let b = try brandWire(name: "晴禾晨光款", summary: "", text: ["Other 晴禾"])
    let sa = try #require(WikipediaSubject.matching(a, allowLegacy: false))
    let sb = try #require(WikipediaSubject.matching(b, allowLegacy: false))
    #expect(sa.key != sb.key && a.wikipediaTopics?.candidates.first?.evidence == "Sunny 晴禾")
    let page = try brandPage("晴禾", definition: "晴禾（Sunny）是一個製作日用品的品牌。")
    let ref = try #require(sa.reference(from: page, at: Date()))
    #expect(!ref.isCurrent(for: b) && sb.reference(from: page, at: Date()) == nil)
}

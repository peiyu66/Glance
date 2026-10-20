import Foundation
import Testing
@testable import GlanceCore

private func hanResult(source: String = "曙光晨光原味", text: [String] = ["AURORA曙光", "晨光", "原味"], version: Int = 16,
                       extra: [SearchEntity] = [], context: [String] = []) throws -> RecognitionResult {
    let central = SearchEntity(kind: .product, name: "晨光原味", sourceText: source, contextText: context)
    let brand = SearchEntity(id: 1, role: .related, kind: .brand, name: "曙光", sourceText: "AURORA曙光", relation: .brand_of, relatedTo: 0)
    let wire: [String: Any] = ["schema_version": version, "names": ["曙光晨光原味"], "summary": "合成測試",
                              "text": text, "search_entities": try JSONSerialization.jsonObject(with: JSONEncoder().encode([central, brand] + extra))]
    return try CameraAnswer.parse(String(decoding: JSONSerialization.data(withJSONObject: wire), as: UTF8.self), expectingStructured: true)
}

@Test func hanAdjacentLineBoundariesPreserveOriginalTextAndRelations() throws {
    for text in [["AURORA曙光", "晨光", "原味"], ["AURORA曙光\n晨光\r\n原味"], ["AURORA曙光", "晨光\n原味", "原味"]] {
        for source in ["曙光晨光原味", "曙光 晨光原味", "曙光晨光 原味", "曙光\n晨光\n原味"] {
            let parsed = try hanResult(source: source, text: text)
            #expect(SearchEntity.matching(parsed).map(\.id) == [0, 1])
            #expect(parsed.text == text && parsed.summary == "合成測試")
            #expect(parsed.searchEntities?.first?.sourceText == EntityValidation15.whitespace(source))
            #expect(GoogleSearchQuery.resolve(result: parsed, decodedBarcodes: [], productBarcodes: [])?.query == "曙光 晨光原味")
            #expect(try JSONDecoder().decode(RecognitionResult.self, from: JSONEncoder().encode(parsed)) == parsed)
        }
    }
}

@Test func hanJoinedContextUsesSameBoundedRuleAndRecordsAdjustment() throws {
    let parsed = try hanResult(context: ["曙光晨光原味"])
    #expect(parsed.entityDiagnostics?.first?.adjustments?.contains("sourceHanLineJoin") == true)
    #expect(parsed.entityDiagnostics?.first?.adjustments?.contains("contextHanLineJoin") == true)
    let old = try hanResult(version: 15)
    #expect(SearchEntity.matching(old).isEmpty)
    #expect(try SearchEntity.matching(hanResult(source: "晨光", version: 15)).map(\.id) == [0, 1])
}

@Test func hanLineJoinNeverErasesInlineLatinDigitOrPunctuationBoundaries() {
    for (source, text) in [
        ("曙光晨光原味", ["曙光 晨光", "原味"]),
        ("AURORADRINK", ["AURORA", "DRINK"]),
        ("曙光500毫升", ["曙光", "500毫升"]),
        ("曙光500毫升", ["曙光500", "毫升"]),
        ("曙光原味", ["曙光、", "原味"]),
        ("曙光原味", ["曙光", "（原味）"])
    ] {
        #expect(!EntityValidation15.anchor(source, in: text, allowHanLineJoins: true).matched)
    }
    #expect(EntityValidation15.anchor("AURORA DRINK", in: ["AURORA", "DRINK"], allowHanLineJoins: true).matched)
}

@Test func hanLineJoinRejectsMissingReorderedTranslatedAndNoncontiguousCharacters() throws {
    for source in ["曙光原味", "原味晨光曙光", "曙光晨原味", "曙光晨光海鹽", "Aurora Morning Original"] {
        let parsed = try hanResult(source: source)
        #expect(SearchEntity.matching(parsed).isEmpty)
        #expect(parsed.entityDiagnostics?.first?.fieldIssues?.first?.rule == .sourceAnchorMissing)
        #expect(parsed.entityDiagnostics?[1].fieldIssues?.first?.rule == .centralEntityRejected)
    }
    #expect(!EntityValidation15.anchor("曙光晨光原味", in: ["曙光", "無關內容", "晨光", "原味"], allowHanLineJoins: true).matched)
}

@Test func hanLineJoinKeepsThreeLineLimitAndSupportsHanScalars() {
    #expect(EntityValidation15.anchor("曙光晨光原味", in: ["曙光", "晨光", "原味"], allowHanLineJoins: true).matched)
    #expect(!EntityValidation15.anchor("曙光晨光原味", in: ["曙", "光", "晨光", "原味"], allowHanLineJoins: true).matched)
    #expect(EntityValidation15.anchor("𠀀原味", in: ["𠀀", "原味"], allowHanLineJoins: true).matched)
}

@Test func hanLineJoinRetainsPrivateLabelAndOccurrenceContext() {
    for lines in [["患者姓名：", "晨光", "原味"], ["患者服用晨光", "原味"], ["收件", "人：晨光", "原味"]] {
        let match = EntityValidation15.anchor("晨光原味", in: lines, allowHanLineJoins: true)
        #expect(!match.matched && match.privateOccurrence)
    }
    // A later independent public occurrence stays usable; do not veto the card.
    let independent = EntityValidation15.anchor("晨光原味", in: ["收件", "人：晨光", "原味", "公開品名。", "晨光", "原味"], allowHanLineJoins: true)
    #expect(independent.matched)
}

@Test func hanLineJoinDoesNotRelaxPersonOrCentralRelationshipEvidence() throws {
    let person = SearchEntity(id: 2, role: .text, kind: .person, name: "林範例", sourceRole: .public_text, sourceText: "林範例")
    let parsed = try hanResult(text: ["AURORA曙光", "晨光", "原味", "林", "範例"], extra: [person])
    #expect(SearchEntity.matching(parsed).map(\.id) == [0, 1])
    #expect(parsed.entityDiagnostics?[2].fieldIssues?.contains { $0.rule == .personCluesMissing } == true)
    let invalid = try hanResult(source: "不在原文")
    #expect(SearchEntity.matching(invalid).isEmpty)
    #expect(invalid.entityDiagnostics?[1].fieldIssues?.first?.rule == .centralEntityRejected)
}

@Test func hanLineJoinRejectsUnrelatedContextDespiteValidPrimaryAnchor() throws {
    let result = try hanResult(context: ["原味晨光"])
    #expect(SearchEntity.matching(result).isEmpty)
    #expect(result.entityDiagnostics?.first?.fieldIssues?.contains { $0.rule == .contextAnchorMissing } == true)
}

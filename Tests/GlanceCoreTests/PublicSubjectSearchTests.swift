import Foundation
import Testing
@testable import GlanceCore

/// Public search metadata plus synthetic text only; never copied camera/OCR data.
private func publicEntity(_ name: String, _ aliases: [String] = []) -> [String: Any] {
    ["name": name, "aliases": aliases, "basis": ["text"]]
}
private func retailIdentity(_ tissue: Bool = false, policy: String = "allowed") -> [String: Any] {
    ["category": "product", "subject": NSNull(),
     "brand": publicEntity(tissue ? "舒潔" : "麒麟", [tissue ? "Kleenex" : "KIRIN"]),
     "manufacturer": NSNull(), "series": NSNull(), "model_version": NSNull(), "formal_name": NSNull(),
     "product": publicEntity(tissue ? "舒潔極厚韌抽取式衛生紙" : "一番搾り啤酒", [tissue ? "Kleenex Extra Durable facial tissue" : "KIRIN ICHIBAN"]),
     "disambiguation": [tissue ? "抽取式衛生紙" : "啤酒"],
     "google_keywords": tissue ? ["舒潔 極厚韌 衛生紙", "Kleenex Extra Durable tissue"] : ["KIRIN 一番搾り", "Kirin Ichiban beer"],
     "wikipedia_policy": policy, "wikipedia_candidates": [] as [Any]]
}
private func publicAnswer(_ identity: [String: Any], text: [String] = [], reason: Any = NSNull()) throws -> RecognitionResult {
    let object: [String: Any] = ["schema_version": 11, "names": ["合成公開商品"], "summary": "", "text": text,
        "search_block_reason": reason, "search_identity": identity]
    return try CameraAnswer.parse(String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self), expectingStructured: true)
}

@Test func shortenedRetailKeywordsUseCompleteDeclaredProductWithOriginalDiagnostics() throws {
    for tissue in [false, true] {
        let input = retailIdentity(tissue), result = try publicAnswer(input)
        let expected = tissue ? "舒潔極厚韌抽取式衛生紙" : "一番搾り啤酒"
        #expect(result.searchQuery?.query == expected)
        #expect(result.searchDiagnostic?.googleOutcome == .identityFallback)
        #expect(result.searchDiagnostic?.googleFallbackField == .product)
        #expect(result.searchDiagnostic?.googleFailure == .keywordOrigin)
        #expect(result.searchDiagnostic?.keywordEvidence?.keywords.allSatisfy { $0.match == .unmatched } == true)
        let restored = try JSONDecoder().decode(RecognitionResult.self, from: JSONEncoder().encode(result))
        let code = try #require(ProductBarcode(value: "0012345678905", symbology: .ean13))
        let query = try #require(GoogleSearchQuery.resolve(result: restored, decodedBarcodes: [code.value], productBarcodes: [code, code]))
        #expect(query.query == expected + " " + code.value)
        let params = URLComponents(url: query.googleURL!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(params.first { $0.name == "q" }?.value == query.query)
        #expect(params.first { $0.name == "lr" }?.value == "lang_zh-TW")
        #expect(restored == result)
    }
}

@Test func fallbackUsesGenericRolePriorityWithoutManufacturerOrOCRGuessing() throws {
    var input = retailIdentity(); input["product"] = NSNull(); input["brand"] = publicEntity("晴禾", ["Sungrain"])
    input["google_keywords"] = ["unsupported phrase"]
    let brand = try publicAnswer(input, text: ["未宣告的其他商品"])
    #expect(brand.searchQuery?.query == "晴禾" && brand.searchDiagnostic?.googleFallbackField == .brand)
    input["brand"] = NSNull(); input["manufacturer"] = publicEntity("其他公司")
    #expect(try publicAnswer(input).searchQuery == nil)
    input["manufacturer"] = NSNull(); input["subject"] = publicEntity("木製夾子"); input["category"] = "object"
    let object = try publicAnswer(input)
    #expect(object.searchQuery?.query == "木製夾子" && object.searchDiagnostic?.googleFallbackField == .subject)
    input["category"] = "species"; input["formal_name"] = publicEntity("Passer montanus")
    #expect(try publicAnswer(input).searchQuery?.query == "Passer montanus")
}

@Test func fallbackCannotRecoverUnsafeOrOversizedKeywordsAndPreservesPolicyVetoes() throws {
    for invalid in ["patient record", "person@example.test", "https://example.test", "sk-synthetic12345678", "台北市中區測試路100號"] {
        var input = retailIdentity(); input["google_keywords"] = [invalid]
        let result = try publicAnswer(input)
        #expect(result.searchQuery == nil && result.searchIdentity == nil && result.searchDiagnostic?.googleFallbackField == nil)
    }
    var oversized = retailIdentity(); oversized["google_keywords"] = [String(repeating: "Alpha", count: 12), String(repeating: "Bravo", count: 12), "unmatched"]
    #expect(try publicAnswer(oversized).searchQuery == nil)
    for reason in ["sensitive", "conflict", "uncertain"] {
        #expect(try publicAnswer(retailIdentity(), reason: reason).searchQuery == nil)
    }
    for policy in ["conflict", "uncertain"] {
        #expect(try publicAnswer(retailIdentity(policy: policy)).searchQuery == nil)
    }
    let sensitive = try publicAnswer(retailIdentity(policy: "sensitive"))
    #expect(sensitive.searchQuery != nil && sensitive.wikipediaTopics == nil)
}

@Test func wikipediaQueriesPublicTopicWithoutSendingPackageContactText() throws {
    let syntheticContact = "進口商：範例有限公司\n地址：範例市中區測試路100號\n客服：https://example.test 聯絡：service@example.test"
    for tissue in [false, true] {
        let result = try publicAnswer(retailIdentity(tissue), text: [syntheticContact])
        let subject = try #require(WikipediaSubject.matching(result, allowLegacy: false))
        let url = try #require(subject.request.url)
        let terms = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(terms.first { $0.name == "gsrsearch" }?.value == (tissue ? "舒潔" : "麒麟"))
        #expect(!url.absoluteString.contains("example") && !url.absoluteString.contains("100"))
        #expect(result.text == [syntheticContact])
        #expect(result.wikipediaCandidateStatus == .structuredBrandFallback)
    }
}

@Test func personalContextOrSensitiveQueryNeverUsesPublicBrandAsAnEscape() throws {
    for text in ["收件人：測試人\n範例市中區測試路100號", "患者姓名：測試人", "私人帳單", "處方箋", "個人帳號：test"] {
        let result = try publicAnswer(retailIdentity(), text: [text])
        #expect(result.searchRestriction == .sensitive && result.searchQuery == nil && result.wikipediaTopics == nil)
    }
    for name in ["測試人@example.test", "範例市中區測試路100號", "患者姓名", "sk-synthetic12345678"] {
        var input = retailIdentity(); input["brand"] = publicEntity(name)
        #expect(try publicAnswer(input).wikipediaTopics == nil)
    }
    let oldSensitive = try publicAnswer(retailIdentity(policy: "sensitive"), text: ["進口商地址：範例市中區測試路100號"])
    let restored = try JSONDecoder().decode(RecognitionResult.self, from: JSONEncoder().encode(oldSensitive))
    #expect(WikipediaSubject.matching(restored) == nil && restored.wikipediaCandidateStatus == .disabled)
}

@Test func fallbackArchiveShareUsesSameIdentityAndDoesNotRewriteOriginalKeywords() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID(), result = try publicAnswer(retailIdentity(true))
    _ = try await archive.create(id: id, jpeg: Data([1, 2, 3]), capturedAt: Date())
    let saved = try await archive.complete(id: id, result: result, message: nil)
    let reopened = try #require(try await RecognitionArchive(root: root).load().records.first)
    #expect(saved.googleSearch == reopened.googleSearch)
    #expect(reopened.shareDocument().links.first?.url == reopened.googleSearch?.googleURL)
    #expect(reopened.result?.searchIdentity?.googleKeywords == ["舒潔 極厚韌 衛生紙", "Kleenex Extra Durable tissue"])
    #expect(reopened.result?.searchDiagnostic?.googleFallbackField == .product)
}

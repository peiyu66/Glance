import Foundation
import Testing
@testable import GlanceCore

private func wire16(_ entities: [SearchEntity] = [], names: [String] = ["曙光飲品"], text: [String] = ["AURORA DRINK"], summary: String = "合成知識") throws -> [String: Any] {
    ["schema_version": 16, "names": names, "summary": summary, "text": text,
     "search_entities": try JSONSerialization.jsonObject(with: JSONEncoder().encode(entities))]
}
private func parse16(_ wire: [String: Any]) throws -> RecognitionResult {
    try CameraAnswer.parse(String(decoding: JSONSerialization.data(withJSONObject: wire), as: UTF8.self), expectingStructured: true)
}
private func entity16(_ name: String = "曙光飲品", aliases: [String] = [], source: String = "AURORA DRINK") -> SearchEntity {
    .init(kind: .product, name: name, aliases: aliases, sourceText: source)
}
private func validates16(_ value: Any, _ schema: [String: Any] = EntitySearchContract.format["schema"] as! [String: Any]) -> Bool {
    if let choices = schema["enum"] as? [Any], !choices.contains(where: { String(describing: $0) == String(describing: value) }) { return false }
    switch schema["type"] as? String {
    case "object":
        guard let value = value as? [String: Any], let properties = schema["properties"] as? [String: [String: Any]],
              Set(value.keys) == Set(schema["required"] as? [String] ?? []) else { return false }
        return value.allSatisfy { key, item in properties[key].map { validates16(item, $0) } == true }
    case "array":
        guard let value = value as? [Any], value.count <= (schema["maxItems"] as? Int ?? Int.max), let items = schema["items"] as? [String: Any] else { return false }
        return value.allSatisfy { validates16($0, items) }
    case "string":
        guard let value = value as? String else { return false }
        return ((schema["minLength"] as? Int ?? 0)...(schema["maxLength"] as? Int ?? Int.max)).contains(value.unicodeScalars.count)
    case "integer":
        guard let value = value as? Int else { return false }
        return ((schema["minimum"] as? Int ?? Int.min)...(schema["maximum"] as? Int ?? Int.max)).contains(value)
    default: return false
    }
}
private func row16(_ title: String = "曙光", lead: String = "曙光是一個食品品牌，這是公開介紹的合成測試資料。", content: String? = nil) -> [String: Any] {
    var row: [String: Any] = ["pageid": 4101, "ns": 0, "title": title, "extract": lead,
        "canonicalurl": "https://zh.wikipedia.org/wiki/" + title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!]
    if let content { row["revisions"] = [["slots": ["main": ["content": content]]]] }
    return row
}
private actor Transport16 {
    let row: Data
    let supplement: Data
    var requests: [URLRequest] = []
    init(_ row: Data, supplement: Data? = nil) { self.row = row; self.supplement = supplement ?? row }
    func send(_ request: URLRequest) throws -> WikipediaHTTPResponse {
        requests.append(request)
        let extra = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "pageids" } == true
        return .init(data: extra ? supplement : row, status: 200, url: request.url)
    }
    var count: Int { requests.count }
    var supplementalCount: Int { requests.filter { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "pageids" } == true }.count }
}

private func transport16(_ row: [String: Any], supplement: [String: Any]? = nil) throws -> Transport16 {
    func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: ["query": ["pages": [value]]]) }
    return try Transport16(data(row), supplement: data(supplement ?? row))
}

@Test func v16ActualRequestUsesShortPromptAndClosedSchemaWithoutTools() throws {
    let data = try CameraAnswer.request(model: "gpt-6-luna", catalog: [.init(slug: "gpt-6-luna", display_name: "Fixture", visibility: "list")], jpeg: Data([1, 2, 3]))
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let content = try #require((body["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
    let format = try #require((body["text"] as? [String: Any])?["format"] as? [String: Any])
    #expect(content.first?["text"] as? String == CameraAnswer.prompt)
    #expect(CameraAnswer.prompt.count < 5000 && CameraAnswer.promptRevision == "P22-English-summary-language-zhTW1")
    #expect(format["name"] as? String == "glance_camera_v17" && format["strict"] as? Bool == true)
    #expect(content.count == 2 && content.last?["image_url"] as? String == "data:image/jpeg;base64,AQID")
    #expect(body["tools"] == nil && body["store"] as? Bool == false && body["stream"] as? Bool == true)
    #expect(validates16(try wire16([entity16()])))
}
@Test func v16FaithfulWholeImageTextAndKnowledgeRemainIndependent() throws {
    let original = ["AURORA\nDRINK", "包装文字 00123", "不相關文字", "AURORA\nDRINK"]
    let result = try parse16(wire16([entity16(aliases: ["Aurora Drink"])], text: original, summary: "一般知識；必要的不確定提示。"))
    #expect(result.usesEntitySearch && result.searchContractVersion == 16)
    #expect(result.text == original && result.names == ["曙光飲品"] && result.summary == "一般知識；必要的不確定提示。")
    #expect(SearchEntity.matching(result).count == 1 && !result.text.contains("曙光飲品"))
    let forged = try parse16(wire16([entity16(source: "曙光飲品")], text: original))
    #expect(SearchEntity.matching(forged).isEmpty)
}
@Test func v16VisibleBarcodeDigitsRemainTextAndNeverBecomeDecodedEvidence() throws {
    let original = ["AURORA DRINK", "0 123456 789012", "0012345678905", "0012345678905"]
    let parsed = try parse16(wire16([entity16()], text: original))
    #expect(parsed.text == original && parsed.barcodes.isEmpty)
    let local = parsed.withBarcodes(["96385074"])
    #expect(local.text == original && local.barcodes == ["96385074"])
    let saved = try JSONDecoder().decode(RecognitionResult.self, from: JSONEncoder().encode(local))
    #expect(saved.text == original && saved.barcodes == ["96385074"])
    // This is a request/consumer boundary check, not evidence that the model transcribes correctly.
    let data = try CameraAnswer.request(model: "gpt-6-luna", catalog: [.init(slug: "gpt-6-luna", display_name: "Fixture", visibility: "list")], jpeg: Data([1]))
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let content = try #require((body["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
    let prompt = try #require(content.first?["text"] as? String)
    #expect(prompt.contains("Transcribe printed barcode digits") && prompt.contains("do not guess encoded content"))
}
@Test func v16DisplayFlavorAndSearchBrandOrAliasNeedNoLiteralEquality() async throws {
    for (display, name, aliases, source) in [
        ("曙光旋脆片原味", "曙光", ["Aurora"], "Aurora"),
        ("曙光旋脆片原味", "Aurora", ["曙光"], "Aurora"),
        ("曙光旋脆片原味", "曙光旋脆片", ["Aurora Spiral"], "旋脆片")
    ] {
        let brand = name == "曙光" || name == "Aurora"
        let proposal = SearchEntity(kind: brand ? .brand : .series, name: name, aliases: aliases, sourceText: source)
        let result = try parse16(wire16([proposal], names: [display], text: ["Aurora", "旋脆片", "原味"]))
        #expect(SearchEntity.matching(result).count == 1 && result.names == [display])
        #expect(SearchEntity.googleTerms(for: result)?.contains(name) == true)
        var row = row16(brand ? "曙光" : "曙光旋脆片", lead: brand ? "曙光是一個食品品牌，這是公開介紹的合成測試資料。" : "曙光旋脆片是一個食品系列，這是公開介紹的合成測試資料。")
        row["redirects"] = [["title": brand ? "Aurora" : "Aurora Spiral"]]
        let transport = try transport16(row)
        let enrichment = await WikipediaLookupService(transport: { try await transport.send($0) }).lookupReferences(for: result)
        #expect(enrichment.subject != nil && enrichment.subject?.isCurrent(for: result) == true)
    }
}
@Test func v16UnboundSourceRejectsOnlyDependentEntities() throws {
    let brand = SearchEntity(id: 1, role: .related, kind: .brand, name: "曙光", basis: .logo, relation: .brand_of, relatedTo: 0)
    let book = SearchEntity(id: 2, role: .text, kind: .object, name: "公開書名", sourceRole: .public_text, sourceText: "Public Book")
    let result = try parse16(wire16([entity16(source: "MISSING SOURCE"), brand, book], names: ["曙光原味"], text: ["AURORA DRINK", "Public Book"]))
    #expect(SearchEntity.matching(result).map(\.id) == [2])
    #expect(result.entityDiagnostics?[0].fieldIssues?.contains { $0.rule == .sourceAnchorMissing } == true)
    #expect(result.entityDiagnostics?[1].fieldIssues?.contains { $0.rule == .centralEntityRejected } == true)
    #expect(SearchEntity.googleTerms(for: result) == "公開書名")
}
@Test func v16SingleCharacterNameWorksThroughLookupCacheAndSavedReference() async throws {
    let result = try parse16(wire16([.init(kind: .species, name: "貓", basis: .appearance, sourceRole: .object_appearance)], names: ["貓"], text: []))
    #expect(SearchEntity.googleTerms(for: result) == "貓")
    let transport = try transport16(row16("貓", lead: "貓是一種動物，也是常見的家養物種，這是合成百科內容。"))
    let service = WikipediaLookupService(transport: { try await transport.send($0) })
    let first = await service.lookupReferences(for: result)
    let reference = try #require(first.subject)
    #expect(reference.isCurrent(for: result))
    let saved = try JSONDecoder().decode(WikipediaReference.self, from: JSONEncoder().encode(reference))
    #expect(saved.isCurrent(for: result) && saved.displayTitle == "貓")
    #expect(await service.lookupReferences(for: result).diagnostics.contains { $0.outcome == .cacheHit })
    #expect(await transport.count == 1)
    var legacy = try wire16([.init(kind: .species, name: "貓", basis: .appearance, sourceRole: .object_appearance)], names: ["貓"], text: [])
    legacy["schema_version"] = 15
    #expect(try SearchEntity.matching(parse16(legacy)).isEmpty)
}
@Test func v16NameBoundsUseJSONCodepointsRatherThanGraphemeClusters() throws {
    for name in [String(repeating: "甲", count: 64), String(repeating: "e\u{301}", count: 32)] {
        let wire = try wire16([entity16(name)], names: [name])
        #expect(try validates16(wire) && SearchEntity.matching(parse16(wire)).count == 1)
    }
    for name in [String(repeating: "甲", count: 65), String(repeating: "e\u{301}", count: 33), ""] {
        let wire = try wire16([entity16(name)], names: [name])
        #expect(try !validates16(wire) && SearchEntity.matching(parse16(wire)).isEmpty)
    }
}
@Test func v16EmptyAndNullValuesHaveConsistentEnvelopeMeaning() throws {
    let empty = try wire16(names: [], text: [], summary: "")
    #expect(try validates16(empty) && SearchEntity.matching(parse16(empty)).isEmpty)
    for field in ["names", "summary", "text", "search_entities"] {
        var wire = empty; wire[field] = NSNull()
        #expect(!validates16(wire))
        #expect(try parse16(wire).entityDiagnostics?.first?.fieldIssues?.first?.rule == .malformedEnvelope)
    }
    let two = try wire16([entity16()], names: ["曙光飲品", "另一個名稱"])
    #expect(try !validates16(two) && SearchEntity.matching(parse16(two)).isEmpty)
    let blank = try wire16([entity16()], names: [" "])
    #expect(try SearchEntity.matching(parse16(blank)).isEmpty)
}
@Test func v16AliasBoundsAndBenignEmptyItemsDoNotLoseValidIdentity() throws {
    for aliases in [[String(repeating: "甲", count: 65)], ["甲", "乙", "丙", "丁"]] {
        let wire = try wire16([entity16(aliases: aliases)])
        #expect(try !validates16(wire) && SearchEntity.matching(parse16(wire)).isEmpty)
    }
    let blank = try wire16([entity16(aliases: ["", " "])])
    #expect(try validates16(blank) && parse16(blank).searchEntities?.first?.aliases == [])
    let wire = try wire16([entity16(aliases: ["曙光飲品", "Aurora Drink", "Aurora Drink"])])
    #expect(try validates16(wire) && (parse16(wire)).searchEntities?.first?.aliases == ["Aurora Drink"])
}
@Test func v16SourceContextAndEnvelopeLimitsMatchSchemaAtBothEdges() throws {
    for count in [120, 121] {
        let source = String(repeating: "甲", count: count), wire = try wire16([entity16(source: source)], text: [source])
        #expect(validates16(wire) == (count == 120))
        #expect(try SearchEntity.matching(parse16(wire)).count == (count == 120 ? 1 : 0))
    }
    for (field, boundary, overflow): (String, Any, Any) in [
        ("summary", String(repeating: "甲", count: 1600), String(repeating: "甲", count: 1601)),
        ("text", Array(repeating: "AURORA DRINK", count: 32), Array(repeating: "AURORA DRINK", count: 33)),
        ("text", ["AURORA DRINK", String(repeating: "甲", count: 1000)], ["AURORA DRINK", String(repeating: "甲", count: 1001)])
    ] {
        var wire = try wire16([entity16()]); wire[field] = boundary
        #expect(try validates16(wire) && SearchEntity.matching(parse16(wire)).count == 1)
        wire[field] = overflow
        #expect(try !validates16(wire) && SearchEntity.matching(parse16(wire)).isEmpty)
    }
}
@Test func v16StandaloneTextIDZeroStillWorksAndDuplicateIDsReject() throws {
    for id in [0, 1] {
        let text = SearchEntity(id: id, role: .text, kind: .object, name: "公開書名", sourceRole: .public_text, sourceText: "Public Book")
        let result = try parse16(wire16([text], names: [], text: ["Public Book"]))
        #expect(SearchEntity.matching(result).count == 1)
    }
    let result = try parse16(wire16([entity16(), entity16()]))
    #expect(result.entityDiagnostics?.last?.outcome == .duplicate && SearchEntity.matching(result).count == 1)
}
@Test func v16LongOptionalSearchPhrasesKeepWholePrimaryName() throws {
    let primary = String(repeating: "甲", count: 60)
    let brand = SearchEntity(id: 1, role: .related, kind: .brand, name: String(repeating: "乙", count: 60), basis: .logo, relation: .brand_of, relatedTo: 0)
    let series = SearchEntity(id: 2, role: .related, kind: .series, name: String(repeating: "丙", count: 60), sourceText: "Series", relation: .series_of, relatedTo: 0)
    for alias in [String(repeating: "丁", count: 60), primary + "原味"] {
        let result = try parse16(wire16([entity16(primary, aliases: [alias]), brand, series], names: [primary], text: ["AURORA DRINK", "Series"]))
        let query = try #require(SearchEntity.googleTerms(for: result))
        #expect(query.hasPrefix(primary) && query.unicodeScalars.count <= 160 && !query.isEmpty)
        #expect(query == primary + " " + brand.name)
    }
}
@Test func v16ModelRejectionAndPrivateSourceStayLocalToEachEntity() throws {
    for status in [SearchCandidate.Status.personal_data, .uncertain, .conflict] {
        let rejected = SearchEntity(kind: .product, name: "曙光飲品", status: status, sourceText: "AURORA DRINK")
        let independent = SearchEntity(id: 1, role: .text, kind: .object, name: "公開書名", sourceRole: .public_text, sourceText: "Public Book")
        let result = try parse16(wire16([rejected, independent], text: ["AURORA DRINK", "Public Book"]))
        #expect(SearchEntity.matching(result).map(\.id) == [1])
    }
    let privateResult = try parse16(wire16([entity16()], text: ["患者姓名：AURORA DRINK"]))
    #expect(SearchEntity.matching(privateResult).isEmpty)
    let person = SearchEntity(kind: .person, name: "合成人名", sourceRole: .public_text, sourceText: "Person Name")
    #expect(try SearchEntity.matching(parse16(wire16([person], names: ["合成人名"], text: ["Person Name"]))).isEmpty)
}
@Test func v16SupplementAndManufacturerRelationshipStillRequired() async throws {
    let result = try parse16(wire16([entity16()]))
    let lead = "曙光公司是一家飲料製造商，提供曙光飲品等各種產品。"
    let base = row16("曙光公司", lead: lead)
    let extra = row16("曙光公司", lead: lead, content: "{{Infobox company\n| products = 曙光飲品\n}}")
    let transport = try transport16(base, supplement: extra)
    let enrichment = await WikipediaLookupService(transport: { try await transport.send($0) }).lookupReferences(for: result)
    #expect(enrichment.subject?.displayTitle == "曙光公司（製造商）" && enrichment.subject?.isCurrent(for: result) == true)
    #expect(await transport.supplementalCount == 1)
    #expect(await transport.count == 2)
    for lead in ["曙光公司是一家控股公司，擁有曙光飲品品牌。", "曙光公司是一家製造商，並非曙光飲品的製造者。"] {
        let row = row16("曙光公司", lead: lead)
        let transport = try transport16(row)
        #expect(await WikipediaLookupService(transport: { try await transport.send($0) }).lookupReferences(for: result).subject == nil)
    }
}
@Test func v16WikiWrongTypeAmbiguousPageAndUnboundAliasStillReject() async throws {
    let result = try parse16(wire16([entity16()]))
    for row in [row16("曙光飲品", lead: "曙光飲品是一個食品品牌，並非特定產品。"),
                row16("曙光飲品", lead: "曙光飲品可能指多個不同的物件，這是消歧義條目。"),
                row16("另一飲品", lead: "另一飲品是一款合成測試產品，名稱與畫面無關。") ] {
        let transport = try transport16(row)
        #expect(await WikipediaLookupService(transport: { try await transport.send($0) }).lookupReferences(for: result).subject == nil)
    }
}

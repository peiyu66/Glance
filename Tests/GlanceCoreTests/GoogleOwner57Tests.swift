import Foundation
import Testing
@testable import GlanceCore

// Complete user-supplied first-stage JSON, reproduced without evidence normalization.
// Public product-label material only; no captured image, account or device data.
private let makers57Raw = #"{"names":["Maker’s Mark 波本威士忌"],"text":["Maker’s","Mark®","KENTUCKY STRAIGHT BOURBON","WHISKY","Handmade","DISTILLED, AGED AND BOTTLED BY THE","MAKER’S MARK DISTILLERY, INC.","STAR HILL FARM, LORETTO, KY USA","200 mL 45% ALC./VOL."],"schema_version":17,"search_entities":[{"kind":"product","basis":"text","source_role":"product_label","related_to":0,"role":"central","status":"ready","relation":"none","source_text":"Maker’s\nMark®","aliases":[],"context_text":["KENTUCKY STRAIGHT BOURBON","WHISKY"],"name":"Maker’s Mark 波本威士忌","id":0},{"kind":"brand","basis":"text","source_role":"product_label","related_to":0,"role":"related","status":"ready","relation":"brand_of","source_text":"Maker’s\nMark®","aliases":[],"context_text":[],"name":"Maker’s Mark","id":1},{"kind":"company","basis":"text","source_role":"product_label","related_to":0,"role":"related","status":"ready","relation":"manufacturer_of","source_text":"MAKER’S MARK DISTILLERY, INC.","aliases":[],"context_text":[],"name":"Maker’s Mark Distillery, Inc.","id":2}],"summary":"這是一瓶 Maker’s Mark 波本威士忌，標示為肯塔基直式波本威士忌，容量 200 mL，酒精濃度 45%。波本威士忌是美國威士忌的一類；標籤並列出蒸餾、熟成與裝瓶業者及其所在地。"}"#
private let makers57Insufficient = #"{"decision":"insufficient_evidence","relationship":"none","summary":"","citations":[],"source_id":"","search_name":"","schema_version":2}"#
private func makers57(_ changes: [String: Any] = [:]) throws -> RecognitionResult {
    if changes.isEmpty { return try CameraAnswer.parse(makers57Raw, expectingStructured: true) }
    var object = try JSONSerialization.jsonObject(with: Data(makers57Raw.utf8)) as! [String: Any]
    var entities = object["search_entities"] as! [[String: Any]]
    for (key, value) in changes { entities[0][key] = value }
    object["search_entities"] = entities
    return try CameraAnswer.parse(String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self), expectingStructured: true)
}
private func google57(_ result: RecognitionResult) -> GoogleSearchQuery? {
    GoogleSearchQuery.resolve(result: result, decodedBarcodes: [], productBarcodes: [])
}
@Test func google57ExactOriginalKeepsNewlineRegisteredMarkAndCurlyApostrophe() throws {
    let result = try makers57(), central = try #require(result.searchEntities?.first)
    #expect(central.sourceText == "Maker’s\nMark®" && central.relatedTo == 0)
    #expect(EntityValidation15.anchor(central.sourceText, in: result.text, allowHanLineJoins: true).matched)
    #expect(SearchEntity.matching(result).map(\.id) == [0,1,2])
    #expect(google57(result)?.query == "Maker’s Mark 波本威士忌")
    #expect(WikipediaReviewCollector.queries(for: result) == ["Maker’s Mark 波本威士忌", "Maker’s Mark", "Maker’s Mark Distillery, Inc."])
    let stored = try JSONDecoder().decode(RecognitionResult.self, from: JSONEncoder().encode(result))
    #expect(stored == result && stored.searchEntities?.first?.relatedTo == 0)
}
@Test func google57MinusOneAndSelfZeroHaveSameQueryWithoutRewritingEither() throws {
    let zero = try makers57(), minusOne = try makers57(["related_to": -1])
    #expect(google57(zero) == google57(minusOne))
    #expect(zero.searchEntities?.first?.relatedTo == 0 && minusOne.searchEntities?.first?.relatedTo == -1)
}
@Test func google57SelfPointerExceptionRetainsShapePrivacyStatusAndEvidenceGuards() throws {
    let cases: [[String: Any]] = [
        ["related_to": 1], ["related_to": -2], ["relation": "brand_of"], ["role": "text"], ["id": 3],
        ["status": "uncertain"], ["source_role": "private_identity"], ["source_role": "unknown"],
        ["source_text": "Maker's\nMark®"], ["context_text": ["NOT ON THE LABEL"]],
        ["name": "token: synthetic"], ["kind": "person", "source_role": "public_text", "context_text": ["WHISKY"]]
    ]
    for changes in cases {
        let result = try makers57(changes)
        #expect(!SearchEntity.matching(result).contains { $0.role == .central })
        #expect(google57(result) == nil) // Names/OCR/related brand never bypass rejection.
    }
}
@Test func google57DoesNotChangeLegacyV14ThroughV16Admission() throws {
    let result = try makers57()
    for version in [14,15,16] {
        let old = RecognitionResult(names: result.names, summary: result.summary, text: result.text, searchContractVersion: version, searchEntities: result.searchEntities)
        #expect(!SearchEntity.matching(old).contains { $0.role == .central })
    }
}
@Test func google57DuplicateIDStillRejectedAtParseBoundary() throws {
    #expect(throws: Error.self) { try makers57(["id": 1]) }
}
@Test(arguments: ["collecting", "reviewing", "insufficient", "noMatch", "failed"])
func google57ArchiveScreenAndShareRetainQueryAcrossStageTwoAndReload(_ stage: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID(), run = UUID(), result = try makers57()
    _ = try await archive.create(id: id, jpeg: Data([57]), capturedAt: Date())
    let response = RecognitionModelResponse.capture(makers57Raw, sourceImageID: id, attemptID: id, appVersion: "0.1.0", appBuild: "55")
    let first = try await archive.complete(id: id, result: result, message: nil, modelResponse: response)
    #expect(first.googleSearch?.query == "Maker’s Mark 波本威士忌")
    var final = try await archive.beginSemanticReview(id: id, attemptID: id, runID: run, expectedResult: first.result!)
    let source = WikipediaReviewSource(pageID: 5701, title: "合成測試來源", url: URL(string: "https://zh.wikipedia.org/wiki/Fixture57")!, fetchedAt: Date(), excerpts: [.init(id: "p0", text: "本段為離線測試來源，不代表品牌識別。")])
    if stage != "collecting" { final = try await archive.updateSemanticReview(id: id, attemptID: id, runID: run, state: .reviewing, sources: [source]) }
    if stage == "insufficient" || stage == "noMatch" {
        let raw = stage == "insufficient" ? makers57Insufficient : makers57Insufficient.replacingOccurrences(of: "insufficient_evidence", with: "no_match")
        let answer = try WikipediaSemanticReview.parse(raw, sources: [source], result: result)
        let reply = RecognitionModelResponse.capture(raw, sourceImageID: id, attemptID: id, appVersion: "0.1.0", appBuild: "57", promptRevision: WikipediaSemanticReview.promptRevision)
        final = try await archive.updateSemanticReview(id: id, attemptID: id, runID: run, state: stage == "insufficient" ? .insufficientEvidence : .noMatch, answer: answer, response: reply)
        #expect(final.semanticJSONDocument?.rawText == raw && answer.searchName.isEmpty)
    } else if stage == "failed" { final = try await archive.updateSemanticReview(id: id, attemptID: id, runID: run, state: .failed) }
    let reopened = try #require(try await archive.load().records.first)
    for record in [final, reopened] {
        #expect(record.result == first.result && record.presentationResult == first.result)
        #expect(record.modelJSONDocument.rawText == makers57Raw)
        #expect(record.googleSearch == first.googleSearch && record.currentSemanticReview?.source == nil)
        let links = record.shareDocument().links
        #expect(links.count == 1 && links.first?.label == "Google 搜尋：Maker’s Mark 波本威士忌" && links.first?.url == record.googleSearch?.googleURL)
    }
}
@Test func owner57OldW2AndW1RequestsRemainReadableButUnknownRevisionDoesNot() throws {
    let input = try JSONSerialization.data(withJSONObject: ["input_version": 2, "stage_one": [:], "raw_stage_one_json": NSNull(), "sources": []])
    let request = try RecognitionModelRequest.capture(input, recordID: UUID(), attemptID: UUID(), runID: UUID(), appVersion: "0.1.0", appBuild: "55")
    var stored = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
    for revision in [WikipediaSemanticReview.legacyPromptRevisionW1, WikipediaSemanticReview.legacyPromptRevisionW2, WikipediaSemanticReview.legacyPromptRevisionW3, WikipediaSemanticReview.promptRevision, "unknown"] {
        stored["promptRevision"] = revision
        let decoded = try JSONDecoder().decode(RecognitionModelRequest.self, from: JSONSerialization.data(withJSONObject: stored))
        #expect(decoded.valid == (revision != "unknown"))
        #expect(decoded.rawPayload == request.rawPayload)
    }
}
@Test func owner57QuotedBrandOwnershipNeedsNoExactProductMentionInValidator() throws {
    // Handwritten answer + synthetic ownership sentence: parser coverage, not a new model result.
    let quote = "麒麟控股擁有麒麟啤酒品牌。"
    let source = WikipediaReviewSource(pageID: 2876406, title: "麒麟控股", url: URL(string: "https://zh.wikipedia.org/wiki/Kirin_Holdings")!, fetchedAt: Date(), excerpts: [.init(id: "p0", text: quote)])
    let answer = WikipediaReviewAnswer(decision: .selected, sourceID: source.id, relationship: .brand_owner, searchName: "麒麟一番搾啤酒", summary: "麒麟一番搾啤酒所屬的麒麟啤酒品牌由麒麟控股持有。", citations: [.init(excerptID: "p0", quote: quote)])
    let raw = String(decoding: try JSONEncoder().encode(answer), as: UTF8.self)
    #expect(try WikipediaSemanticReview.parse(raw, sources: [source]) == answer)
    #expect(WikipediaSemanticReview.prompt.contains("Use the supplied product-to-brand relation and quoted ownership evidence"))
    #expect(!source.excerpts[0].text.contains("一番搾"))
    let ascii = WikipediaSemanticReview.prompt.unicodeScalars.allSatisfy { $0.isASCII }
    #expect(ascii)
}

private func ordering57Result() -> RecognitionResult {
    let names = ["中央書名", "作者甲", "著者乙", "第四主題"]
    return .init(names: [names[0]], summary: "離線排序測試", text: names, searchContractVersion: 17,
        searchEntities: names.enumerated().map { .init(id: $0.offset, role: $0.offset == 0 ? .central : .text, kind: .object,
            name: $0.element, aliases: [$0.element, "合成別名"], sourceRole: .public_text, sourceText: $0.element) })
}
private actor Ordering57Transport {
    let onlyCentral: Bool
    var searches: [String] = []
    var extracts: [Int] = []
    init(onlyCentral: Bool) { self.onlyCentral = onlyCentral }
    func fetch(_ request: URLRequest) async throws -> WikipediaHTTPResponse {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let query = items.first { $0.name == "gsrsearch" }?.value
        let ids: [Int]
        if items.contains(where: { $0.name == "titles" }) {
            ids = [] // Build60 spends its first slot on exact central titles.
        } else if let query {
            searches.append(query)
            switch query {
            case "中央書名": ids = [3,1,2]; try await Task.sleep(for: .milliseconds(40))
            case "作者甲": ids = onlyCentral ? [] : [3,4,1]; try await Task.sleep(for: .milliseconds(20))
            default: ids = onlyCentral ? [] : [3,4,5]
            }
        } else {
            let id = Int(items.first { $0.name == "pageids" }!.value!)!
            extracts.append(id); ids = [id]
        }
        // Deliberately disagree with array order: Build60 uses API index.
        let rows: [[String: Any]] = ids.map { ["pageid": $0, "index": $0, "ns": 0, "title": "合成來源\($0)", "canonicalurl": "https://zh.wikipedia.org/wiki/Fixture\($0)", "extract": "合成公開來源內容。"] }
        return .init(data: try JSONSerialization.data(withJSONObject: ["query": ["pages": rows]]), status: 200, url: request.url)
    }
}
@Test func ordering60ExactMissLeavesTwoRankedSearchSlots() async throws {
    let result = ordering57Result(), transport = Ordering57Transport(onlyCentral: false)
    #expect(WikipediaReviewCollector.queries(for: result) == ["中央書名", "作者甲", "著者乙"])
    let sources = try await WikipediaReviewCollector(transport: { try await transport.fetch($0) }).collect(for: result)
    #expect(sources.map(\.pageID) == [1,3,2])
    #expect(Set(await transport.searches) == ["中央書名", "作者甲"])
    #expect(await transport.extracts == [1,3,2])
}
@Test func ordering60SpareSlotsUseVerifiedSearchIndexOrder() async throws {
    let transport = Ordering57Transport(onlyCentral: true)
    let sources = try await WikipediaReviewCollector(transport: { try await transport.fetch($0) }).collect(for: ordering57Result())
    #expect(sources.map(\.pageID) == [1,2,3])
    #expect(await transport.extracts == [1,2,3])
}
@Test func identity57SourceTitleAndURLNeverBecomeBookTitleInScreenOrShareProjection() async throws {
    // Reduced synthetic fixture shaped like the reported book/author result;
    // only the supplied quote is used, not a reconstructed complete user payload.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID(), run = UUID()
    let result = RecognitionResult(names: ["摩訶止觀"], summary: "一本佛教典籍。", text: ["摩訶止觀", "隋天台智者大師說", "天台三大部"], searchContractVersion: 17, searchEntities: [.init(kind: .object, name: "摩訶止觀", sourceRole: .public_text, sourceText: "摩訶止觀"), .init(id: 1, role: .text, kind: .person, name: "智者大師", sourceRole: .public_text, sourceText: "隋天台智者大師說", contextText: ["摩訶止觀", "天台三大部"])])
    let quote = "智者大師完成了「天台三大部」《法華文句》、《法華玄義》、《摩訶止觀》"
    let source = WikipediaReviewSource(pageID: 4063, title: "智顗", url: URL(string: "https://zh.wikipedia.org/wiki/智顗")!, fetchedAt: Date(), excerpts: [.init(id: "p0", text: quote)])
    let answer = WikipediaReviewAnswer(decision: .selected, sourceID: source.id, relationship: .same_entity, searchName: "摩訶止觀", summary: "摩訶止觀為天台三大部之一。", citations: [.init(excerptID: "p0", quote: quote)])
    let raw = String(decoding: try JSONEncoder().encode(answer), as: UTF8.self)
    #expect(try WikipediaSemanticReview.parse(raw, sources: [source], result: result) == answer) // No local semantic identity adjudication.
    _ = try await archive.create(id: id, jpeg: Data([57]), capturedAt: Date())
    let first = try await archive.complete(id: id, result: result, message: nil)
    _ = try await archive.beginSemanticReview(id: id, attemptID: id, runID: run, expectedResult: first.result!)
    _ = try await archive.updateSemanticReview(id: id, attemptID: id, runID: run, state: .reviewing, sources: [source])
    let final = try await archive.updateSemanticReview(id: id, attemptID: id, runID: run, state: .succeeded, answer: answer)
    #expect(final.currentSemanticReview?.displayTitle == "智顗" && final.currentSemanticReview?.source?.url == source.url)
    #expect(final.presentationResult?.names == ["摩訶止觀"] && final.googleSearch?.query == "摩訶止觀")
    #expect(final.shareDocument().links.contains { $0.label == "維基百科：智顗" && $0.url == source.url })
    #expect(!final.shareDocument().links.contains { $0.label == "維基百科：摩訶止觀" })
    #expect(try await archive.load().records.first?.shareDocument() == final.shareDocument())
}

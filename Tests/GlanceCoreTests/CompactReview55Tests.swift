import Foundation
import Testing
@testable import GlanceCore

private func compact55Result(text: [String] = ["Aurora", "Manufacturer: Aurora Works", "Imported by Beta"]) -> RecognitionResult {
    .init(names: ["曙光"], summary: "第一階段原始簡介", text: text, searchContractVersion: 17,
          searchEntities: [.init(kind: .brand, name: "曙光", aliases: ["Aurora"], basis: .logo, sourceText: "Aurora")])
}
private func compact55Source(id: Int = 5501, excerpts: [WikipediaReviewSource.Excerpt]) -> WikipediaReviewSource {
    .init(pageID: id, title: "曙光公司", url: URL(string: "https://zh.wikipedia.org/wiki/Aurora")!, fetchedAt: Date(timeIntervalSince1970: 0), excerpts: excerpts)
}

@Test func compact55BudgetKeepsThreeCandidatesExactSubstringsAndStableIDs() {
    let result = compact55Result()
    let source = compact55Source(excerpts: (0..<4).map { .init(id: "p\($0)", text: "Aurora \($0) " + String(repeating: "品牌背景。", count: 250)) })
    let sources = (1...3).map { compact55Source(id: $0, excerpts: source.excerpts) }
    let compact = WikipediaReviewBudget.sources(sources, for: result)
    #expect(compact.map(\.pageID) == [1,2,3])
    #expect(compact.allSatisfy { $0.valid && $0.partial && $0.excerpts.count <= 3 && $0.excerpts.allSatisfy { $0.text.unicodeScalars.count <= 400 } && $0.excerpts.reduce(0, { $0 + $1.text.unicodeScalars.count }) <= 1200 })
    for page in compact { for excerpt in page.excerpts { #expect(source.excerpts.first { $0.id == excerpt.id }!.text.contains(excerpt.text)) } }
    #expect(WikipediaReviewBudget.sources(compact, for: result) == compact)
}
@Test func compact55LateIdentityGetsNearbyExactContextWithoutInventingText() {
    let relation = "此公司不製造 Aurora，只進口該品牌商品。"
    let original = String(repeating: "背景", count: 650) + relation + String(repeating: "其他", count: 650)
    let source = compact55Source(excerpts: [.init(id: "p0", text: "公開頁面首段簡介。"), .init(id: "p4", text: original)])
    let compact = WikipediaReviewBudget.sources([source], for: compact55Result())[0]
    #expect(compact.excerpts.first { $0.id == "p4" }?.text.contains(relation) == true)
    #expect(original.contains(compact.excerpts[1].text))
}
@Test func compact55DeduplicatesExactParagraphsButKeepsIndependentCandidatePages() {
    let text = "Aurora 是一個合成測試品牌。"
    let sources = [compact55Source(excerpts: [.init(id: "p0", text: text), .init(id: "p2", text: text)]), compact55Source(id: 5502, excerpts: [.init(id: "p0", text: text)])]
    let compact = WikipediaReviewBudget.sources(sources, for: compact55Result())
    #expect(compact.count == 2 && compact.allSatisfy { $0.excerpts.count == 1 })
}
@Test func compact55OCRIsBoundedAndRetainsLateIdentityContextWithoutMutatingOriginal() throws {
    let original = (0..<24).map { "營養資料\($0)：" + String(repeating: "資料", count: 40) } + ["Imported by Beta", "Manufacturer: Aurora Works", "Aurora", "Aurora"]
    let result = compact55Result(text: original)
    let selected = WikipediaReviewBudget.text(original, for: result)
    #expect(selected.reduce(0, { $0 + $1.unicodeScalars.count }) <= 1600)
    #expect(selected.contains("Manufacturer: Aurora Works") && selected.contains("Imported by Beta"))
    #expect(selected.filter { $0 == "Aurora" }.count == 1)
    #expect(result.text == original)
    let source = compact55Source(excerpts: [.init(id: "p0", text: "Aurora 是一個合成測試品牌。")])
    let data = try WikipediaSemanticReview.input(result: result, rawStageOne: "EXACT ORIGINAL JSON", sources: [source])
    let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(payload["input_version"] as? Int == 2 && payload["raw_stage_one_json"] is NSNull)
    #expect((payload["stage_one"] as? [String: Any])?["text_is_partial"] as? Bool == true)
    #expect(!String(decoding: data, as: UTF8.self).contains("EXACT ORIGINAL JSON"))
}
@Test func compact55ShortOCRRemainsCompleteAndLegacyRequestRemainsReadable() throws {
    let result = compact55Result(), source = compact55Source(excerpts: [.init(id: "p0", text: "Aurora 是一個合成測試品牌。")])
    let data = try WikipediaSemanticReview.input(result: result, rawStageOne: nil, sources: [source])
    var payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let stage = payload["stage_one"] as! [String: Any]
    #expect(stage["text"] as? [String] == result.text && stage["text_is_partial"] as? Bool == false)
    payload["input_version"] = 1; payload["raw_stage_one_json"] = "{\"legacy\":true}"
    let old = try JSONSerialization.data(withJSONObject: payload)
    let current = try RecognitionModelRequest.capture(old, recordID: UUID(), attemptID: UUID(), runID: UUID(), appVersion: "0.1.0", appBuild: "54")
    var archive = try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as! [String: Any]
    archive["promptRevision"] = WikipediaSemanticReview.legacyPromptRevisionW1
    let request = try JSONDecoder().decode(RecognitionModelRequest.self, from: JSONSerialization.data(withJSONObject: archive))
    #expect(request.valid && request.rawPayload == String(decoding: old, as: UTF8.self))
}
@Test func compact55LocalPhaseCheckpointsPersistWithoutClaimingServerUsage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID(), run = UUID()
    _ = try await archive.create(id: id, jpeg: Data([55]), capturedAt: Date())
    let record = try await archive.complete(id: id, result: compact55Result(), message: nil)
    _ = try await archive.beginSemanticReview(id: id, attemptID: id, runID: run, expectedResult: record.result!)
    let source = compact55Source(excerpts: [.init(id: "p0", text: "Aurora 是一個合成測試品牌。")])
    let reviewing = try await archive.updateSemanticReview(id: id, attemptID: id, runID: run, state: .reviewing, sources: [source])
    #expect(reviewing.semanticReview?.sourcesFinishedAt != nil && reviewing.semanticReview?.requestDispatchStartedAt == nil)
    let payload = try WikipediaSemanticReview.input(result: record.result!, rawStageOne: nil, sources: [source])
    var request = try RecognitionModelRequest.capture(payload, recordID: id, attemptID: id, runID: run, appVersion: "0.1.0", appBuild: "55")
    _ = try await archive.saveSemanticRequest(id: id, attemptID: id, runID: run, request: request)
    request.delivery = .dispatching
    let dispatch = try await archive.saveSemanticRequest(id: id, attemptID: id, runID: run, request: request)
    request.delivery = .submitted
    let sent = try await archive.saveSemanticRequest(id: id, attemptID: id, runID: run, request: request)
    #expect(dispatch.semanticReview?.requestDispatchStartedAt != nil && sent.semanticReview?.requestDispatchStartedAt == dispatch.semanticReview?.requestDispatchStartedAt)
    let final = try await archive.updateSemanticReview(id: id, attemptID: id, runID: run, state: .insufficientEvidence)
    #expect(final.semanticReview?.finishedAt != nil && final.semanticReview?.modelRequest?.byteCount == payload.count)
    #expect(try await archive.load().records.first?.semanticReview == final.semanticReview)
}

@Test func compact55ShortUnrelatedLeadAndLateSeriesParagraphNeedNoCategoryVeto() throws {
    // User-reported identity/quote, with explicitly synthetic distractor bodies.
    // This is not a reconstruction of the user's unprovided complete HTTP payload.
    let result = RecognitionResult(names: ["樂連連"], summary: "樂連連海苔壽司口味包裝。", text: ["樂連連", "海苔壽司口味"], searchContractVersion: 17,
        searchEntities: [.init(kind: .product, name: "樂連連", sourceText: "樂連連", contextText: ["海苔壽司口味"])])
    let quote = "樂無限/樂連連（Lay's Stax）是菲多利旗下馬鈴薯片的產品。於2003年推出，是家樂氏品客（Pringles）的競爭商品。"
    let page = WikipediaReviewSource(pageID: 899874, title: "樂事", url: URL(string: "https://zh.wikipedia.org/wiki/Lay%27s")!, fetchedAt: Date(), excerpts: [
        .init(id: "p0", text: "樂事是一個洋芋片品牌。"),
        .init(id: "p1", text: "品牌歷史：" + String(repeating: "企業的過往歷史。", count: 150)),
        .init(id: "p3", text: "\n== 樂無限/樂連連（Lay's Stax） ==\n"),
        .init(id: "p4", text: quote)])
    let unrelated = WikipediaReviewSource(pageID: 1368444, title: "連詩雅", url: URL(string: "https://zh.wikipedia.org/wiki/FixturePerson1")!, fetchedAt: Date(), excerpts: [.init(id: "p0", text: "連詩雅，香港女歌手及演員。" + String(repeating: "合成人物背景資料。", count: 100)), .init(id: "p5", text: String(repeating: "合成生平段落。", count: 100))])
    let another = WikipediaReviewSource(pageID: 8565409, title: "連家穎", url: URL(string: "https://zh.wikipedia.org/wiki/FixturePerson2")!, fetchedAt: Date(), excerpts: [.init(id: "p0", text: "連家穎是此合成測試的人物候選。" + String(repeating: "合成人物背景資料。", count: 100))])
    let compact = WikipediaReviewBudget.sources([page, unrelated, another], for: result)
    #expect(compact.count == 3 && compact[1].pageID == 1368444 && compact[2].pageID == 8565409)
    #expect(compact[1].excerpts.count == 1 && compact[1].excerpts[0].text == "連詩雅，香港女歌手及演員。")
    #expect(compact[0].excerpts.map(\.id) == ["p0", "p4"])
    let expected = WikipediaReviewAnswer(decision: .selected, sourceID: "zhwiki:899874", relationship: .series, searchName: "樂連連海苔壽司口味洋芋片", summary: "包裝是樂連連海苔壽司口味；樂連連是菲多利旗下的馬鈴薯片系列，於2003年推出。", citations: [.init(excerptID: "p4", quote: quote)])
    #expect(expected.valid(sources: compact)) // The page need not mention this flavor.
    #expect(WikipediaReviewBudget.sources(compact, for: result) == compact)
}

@Test func compact55UncertainCentralEntityExplainsSkipButIndependentPublicTextCanQuery() async throws {
    // User-reported shape; the personal-name text is replaced with a synthetic name.
    let raw = #"{"schema_version":17,"names":["台北社子"],"summary":"影像中央是一枚以彩色手推車圖案為主的別針，旁有「台北社子」與「合成姓名」字樣。由於僅憑照片無法確認別針圖案所指的具體主題，中央主體無法可靠辨識。","text":["台北社子","台","合成姓名"],"search_entities":[{"kind":"object","basis":"appearance","source_role":"object_appearance","source_text":"","context_text":[],"name":"台北社子","relation":"none","role":"central","aliases":[],"id":0,"status":"uncertain","related_to":-1}]}"#
    let original = try CameraAnswer.parse(raw, expectingStructured: true)
    #expect(WikipediaReviewCollector.queries(for: original).isEmpty)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID()
    _ = try await archive.create(id: id, jpeg: Data([55]), capturedAt: Date())
    let saved = try await archive.complete(id: id, result: original, message: nil)
    #expect(saved.semanticRequestJSONDocument.message.contains("皆為 uncertain") && saved.semanticRequestJSONDocument.message.contains("不是網路失敗證據"))
    #expect(saved.semanticRequestJSONDocument.rawText == nil && saved.semanticReview == nil)
    // Hypothetical corrected proposal checks the general route, not model quality.
    let textEntity = SearchEntity(id: 1, role: .text, kind: .object, name: "台北社子", sourceRole: .public_text, sourceText: "台北社子")
    let withPublicText = RecognitionResult(names: original.names, summary: original.summary, text: original.text, searchContractVersion: 17, searchEntities: original.searchEntities! + [textEntity])
    #expect(WikipediaReviewCollector.queries(for: withPublicText) == ["台北社子"])
    #expect(!WikipediaReviewCollector.queries(for: withPublicText).contains("合成姓名"))
    #expect(original.text == ["台北社子", "台", "合成姓名"] && saved.result?.summary == original.summary)
}

@Test func compact55BothOutgoingPromptsOmitBoilerplateButKeepNecessaryUncertainty() throws {
    #expect(CameraAnswer.prompt.unicodeScalars.allSatisfy(\.isASCII) && WikipediaSemanticReview.prompt.unicodeScalars.allSatisfy(\.isASCII))
    for prompt in [CameraAnswer.prompt, WikipediaSemanticReview.prompt] {
        #expect(prompt.contains("Omit generic caveats") && prompt.contains("Preserve necessary warnings"))
    }
    #expect(WikipediaSemanticReview.prompt.contains("need not mention the photographed flavor"))
    #expect(CameraAnswer.prompt.contains("An uncertain central object must not suppress"))
    let warning = "無法確認藥品身分，請勿憑外觀服用。"
    let parsed = try CameraAnswer.parse(String(decoding: JSONSerialization.data(withJSONObject: ["names": [], "summary": warning, "text": [], "barcodes": []]), as: UTF8.self))
    #expect(parsed.summary == warning) // No regex deletion or rewriting of model/raw output.
}

private func compact55TextTopics(_ id: UUID? = nil) -> RecognitionResult {
    .init(names: ["別針"], summary: "這是一枚彩色圖案別針。", text: ["台北社子", "合成姓名"], sourceImageID: id, searchContractVersion: 17,
          searchEntities: [.init(kind: .object, name: "別針", status: .uncertain, basis: .appearance, sourceRole: .object_appearance),
            .init(id: 1, role: .text, kind: .object, name: "台北", sourceRole: .public_text, sourceText: "台北"),
            .init(id: 2, role: .text, kind: .object, name: "社子", sourceRole: .public_text, sourceText: "社子")])
}
private actor Compact55TopicTransport {
    var searches: [String] = []
    var extracts = 0
    func fetch(_ request: URLRequest) throws -> WikipediaHTTPResponse {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let query = items.first { $0.name == "gsrsearch" }?.value
        let ids: [Int]
        if let query { searches.append(query); ids = query == "台北" ? [101,102,103] : [201,202,203] }
        else { extracts += 1; ids = [Int(items.first { $0.name == "pageids" }!.value!)!] }
        let rows: [[String: Any]] = ids.map { ["pageid": $0, "ns": 0, "title": "合成地名\($0)", "canonicalurl": "https://zh.wikipedia.org/wiki/Fixture\($0)", "extract": "本段是合成公開地名資料，用於驗證查詢分配。"] }
        return .init(data: try JSONSerialization.data(withJSONObject: ["query": ["pages": rows]]), status: 200, url: request.url)
    }
}
@Test func compact55IndependentTextQueriesEachGetCandidateWithoutSearchingPersonalName() async throws {
    let result = compact55TextTopics(), transport = Compact55TopicTransport()
    #expect(WikipediaReviewCollector.queries(for: result) == ["台北", "社子"])
    let sources = try await WikipediaReviewCollector(transport: { try await transport.fetch($0) }).collect(for: result)
    #expect(sources.map(\.pageID) == [101,201,102])
    #expect(Set(await transport.searches) == ["台北", "社子"] && sources.count == 3)
    #expect(await transport.extracts == 3)
}
@Test func compact55ContextualLinkPreservesObjectNameSearchOriginalAndExplicitRole() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID(), run = UUID(), result = compact55TextTopics(id)
    let quote = "社子是這份合成測試資料介紹的地名主題。"
    let source = WikipediaReviewSource(pageID: 5505, title: "社子", url: URL(string: "https://zh.wikipedia.org/wiki/FixtureTopic")!, fetchedAt: Date(), excerpts: [.init(id: "p0", text: quote)])
    let answer = WikipediaReviewAnswer(decision: .selected, sourceID: source.id, relationship: .contextual, searchName: "社子", summary: "別針文字提及的社子，可參考這個地名主題。", citations: [.init(excerptID: "p0", quote: quote)])
    let raw = String(decoding: try JSONEncoder().encode(answer), as: UTF8.self)
    #expect(try WikipediaSemanticReview.parse(raw, sources: [source], result: result) == answer)
    #expect(throws: Error.self) { try WikipediaSemanticReview.parse(raw, sources: [source], result: compact55Result()) }
    _ = try await archive.create(id: id, jpeg: Data([55]), capturedAt: Date())
    let original = try await archive.complete(id: id, result: result, message: nil)
    _ = try await archive.beginSemanticReview(id: id, attemptID: id, runID: run, expectedResult: original.result!)
    _ = try await archive.updateSemanticReview(id: id, attemptID: id, runID: run, state: .reviewing, sources: [source])
    let saved = try await archive.updateSemanticReview(id: id, attemptID: id, runID: run, state: .succeeded, answer: answer)
    #expect(saved.result == original.result && saved.presentationResult?.names == ["別針"])
    #expect(saved.googleSearch == original.googleSearch)
    #expect(saved.presentationResult?.summary == original.result!.summary + "\n\n" + answer.summary)
    #expect(saved.currentSemanticReview?.displayTitle == "社子（文字主題）")
    #expect(try await archive.load().records.first == saved)
}

// Opt-in local evidence audit. No credentials, network, image or device access.
// Real historical bodies and answers stay outside Git; only measured metadata is exported.
@Test(.enabled(if: ProcessInfo.processInfo.environment["GLANCE55_AUDIT_ROOT"] != nil), arguments: [152,153,149,147])
func compact55HistoricalFourCaseEvidenceRemainsUsable(_ sequence: Int) throws {
    let base = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GLANCE55_AUDIT_ROOT"]))
    let bodyURL = base.appendingPathComponent("glance-semantic-text-trial-build46-20261019/air-approved-run/GlanceTextTrial46/input/\(sequence).json")
    let oldData = try Data(contentsOf: bodyURL), old = try JSONSerialization.jsonObject(with: oldData) as! [String: Any]
    let input = old["input"] as! [[String: Any]], oldText = (input[1]["content"] as! [[String: String]])[0]["text"]!
    let oldPayload = try JSONSerialization.jsonObject(with: Data(oldText.utf8)) as! [String: Any], stage = oldPayload["stage_one"] as! [String: Any]
    let entities = try JSONDecoder().decode([SearchEntity].self, from: JSONSerialization.data(withJSONObject: stage["search_entities"]!))
    let result = RecognitionResult(names: stage["names"] as! [String], summary: stage["summary"] as! String, text: stage["text"] as! [String], searchContractVersion: 17, searchEntities: entities)
    let sources = try TextTrialContract.sources(in: oldData), compact = WikipediaReviewBudget.sources(sources, for: result)
    let responseURL = base.appendingPathComponent("glance-refresh-text-trial-build48-20261019/air-complete-run/response-\(sequence).json")
    let response = try String(contentsOf: responseURL, encoding: .utf8)
    let answer = try WikipediaSemanticReview.parse(response, sources: sources)
    let selected = try #require(compact.first { $0.id == answer.sourceID })
    let retained = answer.citations.filter { quote in selected.excerpts.contains { $0.id == quote.excerptID && $0.text.contains(quote.quote) } }
    #expect(retained.contains { $0.excerptID == "p0" }) // every original identity/brand/series anchor
    if sequence == 149 { #expect(retained.contains { $0.excerptID == "p4" }) }
    if sequence != 147 { #expect(try WikipediaSemanticReview.parse(response, sources: compact) == answer) }
    // 147's optional product-range history quote may be removed deliberately;
    // never claim that an old history-bearing answer is valid without its quote.
    let payload = try WikipediaSemanticReview.input(result: result, rawStageOne: oldPayload["raw_stage_one_json"] as? String, sources: compact)
    let body = try WikipediaSemanticReview.request(input: payload, catalog: [.init(slug: "gpt-6-luna", display_name: "Offline", visibility: "list")])
    var trial = try JSONSerialization.jsonObject(with: body) as! [String: Any]; trial["max_output_tokens"] = 8192
    let trialBody = try JSONSerialization.data(withJSONObject: trial)
    #expect(payload.count < oldText.utf8.count && trialBody.count < oldData.count)
    func size(_ value: String) -> [String: Int] { ["unicodeScalars": value.unicodeScalars.count, "utf8Bytes": value.utf8.count] }
    func jsonSize(_ value: Any) throws -> [String: Int] { size(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys,.withoutEscapingSlashes,.fragmentsAllowed]), as: UTF8.self)) }
    let newPayload = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
    let prompt = (input[0]["content"] as! [[String: String]])[0]["text"]!
    #expect(prompt == WikipediaSemanticReview.legacyPromptW1)
    let metrics: [String: Any] = ["sequence": sequence, "oldBodySHA256": RecognitionArchive.hash(oldData), "oldBody": size(String(decoding: oldData, as: UTF8.self)), "oldInput": size(oldText), "newInput": size(String(decoding: payload, as: UTF8.self)), "newProductBody": size(String(decoding: body, as: UTF8.self)), "newComparableTrialBody": size(String(decoding: trialBody, as: UTF8.self)), "oldPrompt": size(prompt), "newPrompt": size(WikipediaSemanticReview.prompt), "oldFormat": try jsonSize(WikipediaSemanticReview.legacyFormatW1), "newFormat": try jsonSize(WikipediaSemanticReview.format), "oldSchema": try jsonSize(WikipediaSemanticReview.legacyFormatW1["schema"]!), "newSchema": try jsonSize(WikipediaSemanticReview.format["schema"]!), "oldStageOne": try jsonSize(stage), "newStageOne": try jsonSize(newPayload["stage_one"]!), "oldRawStageOne": size(oldPayload["raw_stage_one_json"] as! String), "oldSources": try jsonSize(oldPayload["sources"]!), "newSources": try jsonSize(newPayload["sources"]!), "oldExcerptScalars": sources.flatMap(\.excerpts).reduce(0, { $0 + $1.text.unicodeScalars.count }), "newExcerptScalars": compact.flatMap(\.excerpts).reduce(0, { $0 + $1.text.unicodeScalars.count }), "oldOCR": size(result.text.joined(separator: "\n")), "newOCR": size(WikipediaReviewBudget.text(result.text, for: result).joined(separator: "\n")), "sourceIDsPreserved": compact.map(\.id) == sources.map(\.id), "existingCitationsRetained": retained.count, "existingCitationCount": answer.citations.count, "existingAnswerStillValid": answer.valid(sources: compact), "actualUsageAvailable": false, "newAIRequests": 0, "note": "New sizes are locally built unsent bodies, not measured model latency or new semantic acceptance."]
    let out = base.appendingPathComponent("glance-compact-review-build55-20261020/payload-audit")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]).write(to: out.appendingPathComponent("\(sequence)-metrics.json"))
    try payload.write(to: out.appendingPathComponent("\(sequence)-compact-input.json"))
}

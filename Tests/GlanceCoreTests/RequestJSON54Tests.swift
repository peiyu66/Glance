import Foundation
import Testing
@testable import GlanceCore

private func result54(_ id: UUID? = nil) -> RecognitionResult {
    .init(names: ["公開書名"], summary: "初步簡介", text: ["公開書名", "原語 👩🏽‍🔬"], sourceImageID: id,
          searchContractVersion: 17, searchEntities: [.init(kind: .series, name: "公開書名", sourceText: "公開書名")])
}
private func source54() -> WikipediaReviewSource {
    .init(pageID: 54, title: "公開書名", url: URL(string: "https://zh.wikipedia.org/wiki/Book")!, fetchedAt: Date(), excerpts: [.init(id: "p0", text: "這是來源摘錄，保留原語及 Unicode 👩🏽‍🔬。")])
}
private func request54(_ id: UUID, _ run: UUID) throws -> RecognitionModelRequest {
    try .capture(WikipediaSemanticReview.input(result: result54(id), rawStageOne: "{\"exact\":1e2,\"text\":\"👩🏽‍🔬\"}", sources: [source54()]), recordID: id, attemptID: id, runID: run, appVersion: "0.1.0", appBuild: "54")
}
private func ready54(_ root: URL, _ id: UUID, _ run: UUID) async throws -> RecognitionArchive {
    let archive = RecognitionArchive(root: root)
    _ = try await archive.create(id: id, jpeg: Data([1,2,3]), capturedAt: Date())
    let first = RecognitionModelResponse.capture("{\"exact\":1e2,\"text\":\"👩🏽‍🔬\"}", sourceImageID: id, attemptID: id, appVersion: "0.1.0", appBuild: "54")
    let record = try await archive.complete(id: id, result: result54(id), message: nil, modelResponse: first)
    _ = try await archive.beginSemanticReview(id: id, attemptID: id, runID: run, expectedResult: record.result!)
    _ = try await archive.updateSemanticReview(id: id, attemptID: id, runID: run, state: .reviewing, sources: [source54()])
    return archive
}

@Test func request54ExactPersistedPayloadIsTheUserInputInHTTPBody() throws {
    let evidence = try request54(UUID(), UUID())
    let body = try WikipediaSemanticReview.request(input: Data(evidence.rawPayload.utf8), catalog: [.init(slug: "gpt-6-luna", display_name: "Fixture", visibility: "list")])
    let root = try JSONSerialization.jsonObject(with: body) as! [String: Any]
    let input = root["input"] as! [[String: Any]], content = input[1]["content"] as! [[String: String]]
    #expect(content[0]["text"] == evidence.rawPayload && evidence.valid)
    let payload = try JSONSerialization.jsonObject(with: Data(evidence.rawPayload.utf8)) as! [String: Any]
    #expect(Set(payload.keys) == ["input_version", "stage_one", "raw_stage_one_json", "sources"])
    #expect(payload["raw_stage_one_json"] is NSNull) // Build55 sends the structured first stage once.
    #expect(!evidence.rawPayload.contains("Authorization") && !evidence.rawPayload.contains("Bearer "))
}

@Test func request54NetworkFailureRetainsExactRequestAcrossReloadAndCombinedShare() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID(), run = UUID(), archive = try await ready54(root, id, run)
    var request = try request54(id, run)
    let prepared = try await archive.saveSemanticRequest(id: id, attemptID: id, runID: run, request: request)
    #expect(prepared.semanticRequestJSONDocument.message.contains("尚未進入送出"))
    request.delivery = .dispatching
    _ = try await archive.saveSemanticRequest(id: id, attemptID: id, runID: run, request: request)
    request.delivery = .submitted
    _ = try await archive.saveSemanticRequest(id: id, attemptID: id, runID: run, request: request)
    _ = try await archive.updateSemanticReview(id: id, attemptID: id, runID: run, state: .failed, failure: .init(stage: .requestingModel, code: .network, status: -1009))
    let saved = try await RecognitionArchive(root: root).load().records[0]
    #expect(saved.semanticRequestJSONDocument.rawText == request.rawPayload)
    #expect(saved.semanticRequestJSONDocument.message.contains("已交給網路傳輸"))
    let combined = saved.combinedJSONShareText
    #expect(combined.hasPrefix("第一階段回覆\n{\"exact\":1e2"))
    #expect(combined.contains("\n\n第二階段請求\n") && combined.contains(request.rawPayload))
    #expect(combined.contains("第二階段回覆\n百科補充失敗") && combined.contains("第二階段尚無保存的原始 JSON。"))
    #expect(saved.semanticJSONDocument?.message.contains("requestingModel / network（-1009）") == true)
    #expect(saved.result == result54(id) && saved.semanticReview?.state == .failed)
}

@Test func request54LegacyUnknownAndNewUnpreparedAreDifferent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID(), run = UUID(), archive = try await ready54(root, id, run)
    let record = try await archive.updateSemanticReview(id: id, attemptID: id, runID: run, state: .failed, failure: .init(stage: .sourceSearch, code: .apiWarning))
    #expect(record.semanticRequestJSONDocument.rawText == nil && record.semanticRequestJSONDocument.message.contains("尚未組成，也未送出"))
    var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
    var review = old["semanticReview"] as! [String: Any]; review.removeValue(forKey: "requestCaptureVersion"); old["semanticReview"] = review
    let legacy = try JSONDecoder().decode(ArchivedRecognition.self, from: JSONSerialization.data(withJSONObject: old))
    #expect(legacy.semanticRequestJSONDocument.message.contains("歷史未保存") && !legacy.combinedJSONShareText.contains("尚未組成"))
}

@Test func request54CombinedExportPreservesAllThreeRawSections() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID(), run = UUID(), archive = try await ready54(root, id, run)
    let request = try request54(id, run)
    _ = try await archive.saveSemanticRequest(id: id, attemptID: id, runID: run, request: request)
    let rawReply = "{ \"schema_version\":1, \"decision\":\"no_match\", \"source_id\":\"\", \"relationship\":\"none\", \"search_name\":\"\", \"summary\":\"\", \"citations\":[] }\n"
    let reply = RecognitionModelResponse.capture(rawReply, sourceImageID: id, attemptID: id, appVersion: "0.1.0", appBuild: "54", promptRevision: WikipediaSemanticReview.promptRevision)
    let record = try await archive.updateSemanticReview(id: id, attemptID: id, runID: run, state: .noMatch, answer: .init(decision: .no_match), response: reply)
    let shared = record.combinedJSONShareText
    #expect(shared.hasPrefix("第一階段回覆\n{\"exact\":1e2,\"text\":\"👩🏽‍🔬\"}\n\n第二階段請求\n"))
    #expect(shared.contains(request.rawPayload + "\n\n第二階段回覆\n" + rawReply))
    #expect(shared.hasSuffix(rawReply))
    #expect(!shared.contains("sourceImageID") && !shared.contains("imageSHA256"))
}

@Test func request54BindingTamperAndMonotonicStateGuards() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID(), run = UUID(), archive = try await ready54(root, id, run)
    var request = try request54(id, run)
    await #expect(throws: Error.self) { try await archive.saveSemanticRequest(id: id, attemptID: id, runID: UUID(), request: request) }
    var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]; encoded["rawPayload"] = "{}"
    let corrupt = try JSONDecoder().decode(RecognitionModelRequest.self, from: JSONSerialization.data(withJSONObject: encoded))
    #expect(!corrupt.valid)
    await #expect(throws: Error.self) { try await archive.saveSemanticRequest(id: id, attemptID: id, runID: run, request: corrupt) }
    _ = try await archive.saveSemanticRequest(id: id, attemptID: id, runID: run, request: request)
    request.delivery = .submitted
    await #expect(throws: Error.self) { try await archive.saveSemanticRequest(id: id, attemptID: id, runID: run, request: request) }
    request.delivery = .dispatching
    _ = try await archive.saveSemanticRequest(id: id, attemptID: id, runID: run, request: request)
    request.delivery = .prepared
    await #expect(throws: Error.self) { try await archive.saveSemanticRequest(id: id, attemptID: id, runID: run, request: request) }
}

@Test func request54LateReceiptCannotRestartCancelledOrDeletedRecord() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID(), run = UUID(), archive = try await ready54(root, id, run)
    var request = try request54(id, run)
    _ = try await archive.saveSemanticRequest(id: id, attemptID: id, runID: run, request: request)
    request.delivery = .dispatching
    _ = try await archive.saveSemanticRequest(id: id, attemptID: id, runID: run, request: request)
    _ = try await archive.updateSemanticReview(id: id, attemptID: id, runID: run, state: .cancelled)
    request.delivery = .submitted
    let cancelled = try await archive.saveSemanticRequest(id: id, attemptID: id, runID: run, request: request)
    #expect(cancelled.semanticReview?.state == .cancelled && cancelled.semanticReview?.answer == nil)
    _ = try await archive.delete(ids: [id])
    await #expect(throws: Error.self) { try await archive.saveSemanticRequest(id: id, attemptID: id, runID: run, request: request) }
    #expect(try await archive.load().records.isEmpty)
}

@Test func request54InterruptedDispatchIsNotClaimedSent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID(), run = UUID(), archive = try await ready54(root, id, run)
    var request = try request54(id, run)
    _ = try await archive.saveSemanticRequest(id: id, attemptID: id, runID: run, request: request)
    request.delivery = .dispatching
    _ = try await archive.saveSemanticRequest(id: id, attemptID: id, runID: run, request: request)
    let interrupted = try await RecognitionArchive(root: root).load().records[0]
    #expect(interrupted.semanticReview?.state == .interrupted)
    #expect(interrupted.semanticRequestJSONDocument.message.contains("實際傳送狀態未確認"))
}

@Test func request54MissingDurablePayloadDoesNotFalselyClaimUnassembled() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID(), run = UUID(), archive = try await ready54(root, id, run)
    let failed = try await archive.updateSemanticReview(id: id, attemptID: id, runID: run, state: .failed, failure: .init(stage: .savingRequest, code: .storage))
    #expect(failed.semanticRequestJSONDocument.rawText == nil)
    #expect(failed.semanticRequestJSONDocument.message.contains("已組成但未保存，未送出"))
    var cancelled = failed; cancelled.semanticReview?.state = .cancelled; cancelled.semanticReview?.failure = nil
    #expect(cancelled.semanticRequestJSONDocument.message.contains("尚無已保存的請求，未送出"))
    #expect(!cancelled.semanticRequestJSONDocument.message.contains("尚未組成"))
}

private func rangeWarning54(_ parameter: String = "exchars") -> [String: Any] {
    ["code": "outofrange", "module": "query+extracts", "key": "paramvalidator-outofrange-minmax", "params": [["plaintext": parameter], ["plaintext": "1600"], ["num": 1], ["num": 1200]], "data": ["min": 1, "curmax": 1200, "max": 1200, "highmax": 1200]]
}
private func wikiPage54() -> [String: Any] {
    ["query": ["pages": [["ns": 0, "pageid": 54, "title": "公開書名", "canonicalurl": "https://zh.wikipedia.org/wiki/Book", "extract": "這是有界限的本機來源摘錄。"]]]]
}
@Test func wiki54LegalSearchAndSingleExtractParameters() async throws {
    let values = try await WikipediaReviewCollector(transport: { request in
        let params = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        #expect(params["errorformat"] == "raw")
        if params["generator"] != nil || params["titles"] != nil { #expect(params["exchars"] == "1200" && params["exlimit"] == "3" && params["exintro"] == "1") }
        else { #expect(params["exchars"] == nil && params["exlimit"] == "1" && params["pageids"] == "54") }
        return .init(data: try JSONSerialization.data(withJSONObject: wikiPage54()), status: 200, url: request.url)
    }).collect(for: result54())
    #expect(values.count == 1 && values[0].partial)
}
@Test func wiki54KnownRangeWarningContinuesOnlyWithValidBoundedCandidates() async throws {
    let sources = try await WikipediaReviewCollector(transport: { request in
        var body = wikiPage54(); body["warnings"] = [rangeWarning54()]
        return .init(data: try JSONSerialization.data(withJSONObject: body), status: 200, url: request.url)
    }).collect(for: result54())
    #expect(sources.count == 1)
    do {
        _ = try await WikipediaReviewCollector(transport: { request in
            .init(data: try JSONSerialization.data(withJSONObject: ["warnings": [rangeWarning54()]]), status: 200, url: request.url)
        }).collect(for: result54()); Issue.record("Missing query must still fail")
    } catch let failure as SemanticReviewFailure { #expect(failure.code == .invalidEnvelope) }
}
@Test func wiki54FatalErrorsUnknownWarningsAndOtherParametersStillStop() async throws {
    for scenario in 0..<4 {
        do {
            _ = try await WikipediaReviewCollector(transport: { request in
                var body = wikiPage54()
                if scenario == 0 { body["errors"] = [["code": "maxlag"]] }
                if scenario == 1 { body["error"] = ["code": "maxlag"] }
                if scenario == 2 { body["warnings"] = [["code": "unknown", "module": "query+extracts"]] }
                if scenario == 3 { body["warnings"] = [rangeWarning54("gsrlimit")] }
                return .init(data: try JSONSerialization.data(withJSONObject: body), status: 200, url: request.url)
            }).collect(for: result54()); Issue.record("Expected stop")
        } catch let failure as SemanticReviewFailure { #expect(failure.stage == .sourceSearch && failure.code == (scenario < 2 ? .apiError : .apiWarning)) }
    }
}

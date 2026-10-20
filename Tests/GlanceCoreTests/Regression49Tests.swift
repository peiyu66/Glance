import Foundation
import Testing
@testable import GlanceCore

private func book49() -> RecognitionResult {
    .init(names: ["摩訶止觀"], summary: "初步簡介", text: ["摩訶止觀", "摩訶止觀卷第一(上)", "隋天台智者大師說", "門人灌頂記"], searchContractVersion: 17,
        searchEntities: [.init(kind: .product, name: "摩訶止觀", sourceText: "摩訶止觀", contextText: ["摩訶止觀卷第一(上)", "隋天台智者大師說", "門人灌頂記"])])
}
private actor Calls49 {
    var count = 0
    func called() { count += 1 }
}
@Test func collector49BookAdmissionAndSuccessfulSourceDoesNotDependOnKindHeuristic() async throws {
    let calls = Calls49()
    #expect(WikipediaReviewCollector.queries(for: book49()) == ["摩訶止觀"])
    let sources = try await WikipediaReviewCollector(transport: { request in
        await calls.called()
        let body: [String: Any] = ["batchcomplete": true, "query": ["pages": [["pageid": 4901, "ns": 0, "title": "摩訶止觀", "canonicalurl": "https://zh.wikipedia.org/wiki/摩訶止觀", "extract": "這是本機合成的公開書籍候選。\n\n第二段內容。"]]]]
        return .init(data: try JSONSerialization.data(withJSONObject: body), status: 200, url: request.url)
    }).collect(for: book49())
    #expect(sources.count == 1 && sources.first?.title == "摩訶止觀")
    #expect(await calls.count == 2)
}
@Test func collector49FailuresPreserveTransportOrEnvelopeCategoryWithoutRetry() async throws {
    let cases: [(String, Int, SemanticReviewFailure.Code)] = [
        ("{}", 503, .httpStatus), ("not JSON", 200, .invalidJSON),
        ("{\"error\":{\"code\":\"maxlag\"}}", 200, .apiError),
        ("{\"warnings\":{\"extracts\":\"diagnostic\"}}", 200, .apiWarning),
        ("{\"query\":{}}", 200, .invalidEnvelope)
    ]
    for (body, status, expected) in cases {
        let calls = Calls49()
        do {
            _ = try await WikipediaReviewCollector(transport: { request in
                await calls.called(); return .init(data: Data(body.utf8), status: status, url: request.url)
            }).collect(for: book49())
            Issue.record("Expected failure: \(expected)")
        } catch let failure as SemanticReviewFailure {
            #expect(failure.stage == .sourceSearch && failure.code == expected)
            #expect(failure.status == (status == 503 ? 503 : nil))
            let serialized = String(decoding: try JSONEncoder().encode(failure), as: UTF8.self)
            #expect(!serialized.contains("摩訶") && !serialized.contains("diagnostic"))
        }
        #expect(await calls.count == 1)
    }
    do {
        _ = try await WikipediaReviewCollector(transport: { _ in throw URLError(.notConnectedToInternet) }).collect(for: book49())
        Issue.record("Expected offline failure")
    } catch let failure as SemanticReviewFailure {
        #expect(failure.stage == .sourceSearch && failure.code == .network && failure.status == -1009)
    }
}
@Test func collector49EmptySearchAndOptionalExtractFailureAreNotFatal() async throws {
    let empty = try await WikipediaReviewCollector(transport: { request in
        .init(data: Data("{\"batchcomplete\":true}".utf8), status: 200, url: request.url)
    }).collect(for: book49())
    #expect(empty.isEmpty)
    let sources = try await WikipediaReviewCollector(transport: { request in
        if request.url!.query!.contains("pageids") { throw URLError(.timedOut) }
        let body: [String:Any] = ["query": ["pages": [["ns": 0, "pageid": 4901, "title": "摩訶止觀", "canonicalurl": "https://zh.wikipedia.org/wiki/摩訶止觀", "extract": "本機合成的可用首段。"]]]]
        return .init(data: try JSONSerialization.data(withJSONObject: body), status: 200, url: request.url)
    }).collect(for: book49())
    #expect(sources.count == 1 && sources[0].partial)
}
@Test func semantic49FailurePersistsAndOldFailureIsTerminalWithoutInventingReason() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID(), run = UUID()
    _ = try await archive.create(id: id, jpeg: Data([1]), capturedAt: Date())
    let initial = try await archive.complete(id: id, result: book49(), message: nil)
    _ = try await archive.beginSemanticReview(id: id, attemptID: id, runID: run, expectedResult: initial.result!)
    let error = SemanticReviewFailure(stage: .sourceSearch, code: .network, status: -1009)
    let failed = try await archive.updateSemanticReview(id: id, attemptID: id, runID: run, state: .failed, failure: error)
    #expect(failed.semanticReview?.failure == error && failed.semanticReview?.isPending == false)
    #expect(failed.result == initial.result && failed.presentationResult == initial.result)
    let loaded = try await RecognitionArchive(root: root).load().records[0]
    #expect(loaded.semanticReview?.failure == error && loaded.semanticReview?.state == .failed)
    var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(failed.semanticReview!)) as! [String:Any]
    old.removeValue(forKey: "failure")
    let decoded = try JSONDecoder().decode(RecognitionSemanticReview.self, from: JSONSerialization.data(withJSONObject: old))
    #expect(decoded.failure == nil && !decoded.isPending && decoded.statusText.contains("失敗，已停止"))
}

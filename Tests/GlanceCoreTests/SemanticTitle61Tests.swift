import Foundation
import Testing
@testable import GlanceCore

// Regression title is the reported "乐事". The excerpt/page ID are synthetic:
// this fixture exercises production archive/share paths without a network call.
private func titleSource61(_ title: String = "乐事") -> WikipediaReviewSource {
    .init(pageID: 6101, title: title, url: URL(string: "https://zh.wikipedia.org/wiki/乐事")!,
          fetchedAt: Date(timeIntervalSince1970: 1_792_476_000),
          excerpts: [.init(id: "p0", text: "乐事是这个合成回归样本中的品牌名称。")])
}
private func titleAnswer61(_ relation: WikipediaReviewAnswer.Relationship = .brand) -> WikipediaReviewAnswer {
    .init(decision: .selected, sourceID: "zhwiki:6101", relationship: relation,
          searchName: "樂事洋芋片", summary: "這是使用樂事名稱的合成回歸樣本。",
          citations: [.init(excerptID: "p0", quote: "乐事是这个合成回归样本中的品牌名称。")])
}

@Test func semantic61SimplifiedTitleSurvivesSaveReopenAndAllShareFormatsWithoutRewritingEvidence() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID(), run = UUID(), jpeg = Data([6, 1, 0, 255])
    let result = RecognitionResult(names: ["樂事洋芋片"], summary: "第一階段原始簡介", text: ["乐事", "LAY'S"],
        sourceImageID: id, searchContractVersion: 17,
        searchEntities: [.init(kind: .brand, name: "樂事", sourceText: "乐事")])
    let originalRaw = #"{"schema_version":17,"names":["樂事洋芋片"],"summary":"第一階段原始簡介","text":["乐事","LAY'S"],"search_entities":[]}"#
    let raw = RecognitionModelResponse.capture(originalRaw, sourceImageID: id, attemptID: id, appVersion: "0.1.0", appBuild: "60")
    _ = try await archive.create(id: id, jpeg: jpeg, capturedAt: Date())
    let original = try await archive.complete(id: id, result: result, message: nil, modelResponse: raw)
    _ = try await archive.beginSemanticReview(id: id, attemptID: id, runID: run, expectedResult: result)
    let source = titleSource61(), answer = titleAnswer61()
    _ = try await archive.updateSemanticReview(id: id, attemptID: id, runID: run, state: .reviewing, sources: [source])
    let input = try WikipediaSemanticReview.input(result: result, rawStageOne: originalRaw, sources: [source])
    let request = try RecognitionModelRequest.capture(input, recordID: id, attemptID: id, runID: run, appVersion: "0.1.0", appBuild: "60")
    _ = try await archive.saveSemanticRequest(id: id, attemptID: id, runID: run, request: request)
    let answerRaw = String(decoding: try JSONEncoder().encode(answer), as: UTF8.self)
    let response = RecognitionModelResponse.capture(answerRaw, sourceImageID: id, attemptID: id,
        appVersion: "0.1.0", appBuild: "60", promptRevision: WikipediaSemanticReview.promptRevision)
    let saved = try await archive.updateSemanticReview(id: id, attemptID: id, runID: run, state: .succeeded, answer: answer, response: response)
    let reopened = try #require(try await RecognitionArchive(root: root).load().records.first)
    for card in [saved, reopened] {
        // SingleCaptureView uses this exact title property for its Link label.
        #expect(card.currentSemanticReview?.displayTitle == "樂事（品牌）")
        let document = card.shareDocument()
        let link = try #require(document.links.first { $0.label.hasPrefix("維基百科：") })
        #expect(link.label == "維基百科：樂事（品牌）")
        #expect(link.url == source.url)
        #expect(document.plainText.contains("[維基百科：樂事（品牌）]"))
        #expect(document.html.contains("維基百科：樂事（品牌）</a>"))
        #expect(card.currentSemanticReview?.source == source)
        #expect(card.currentSemanticReview?.answer == answer)
        #expect(card.currentSemanticReview?.modelRequest == request)
        #expect(card.currentSemanticReview?.modelResponse == response)
        #expect(card.result == original.result && card.modelResponses == original.modelResponses)
        #expect(card.modelJSONDocument.rawText == originalRaw)
        #expect(card.currentSemanticReview?.source?.title == "乐事")
        #expect(card.currentSemanticReview?.source?.id == "zhwiki:6101")
        #expect(card.currentSemanticReview?.answer?.citations.first?.quote == source.excerpts.first?.text)
        #expect(try await archive.image(for: card) == jpeg)
    }
    #expect(saved == reopened)
}

@Test func semantic61TraditionalDisplayKeepsRelationshipLabelsAndOriginalLanguage() {
    for relation in [WikipediaReviewAnswer.Relationship.same_entity, .brand, .series, .brand_owner, .manufacturer, .contextual] {
        for (sourceTitle, displayed) in [("乐事", "樂事"), ("樂事", "樂事"), ("Lay's", "Lay's")] {
            var review = RecognitionSemanticReview(recordID: UUID(), attemptID: UUID())
            review.state = .succeeded; review.sources = [titleSource61(sourceTitle)]; review.answer = titleAnswer61(relation)
            let suffix = relation.label.isEmpty ? "" : "（\(relation.label)）"
            #expect(review.displayTitle == displayed + suffix)
            #expect(review.source?.title == sourceTitle)
        }
    }
    var pending = RecognitionSemanticReview(recordID: UUID(), attemptID: UUID())
    pending.sources = [titleSource61()]; pending.answer = titleAnswer61()
    #expect(pending.displayTitle == nil)
}

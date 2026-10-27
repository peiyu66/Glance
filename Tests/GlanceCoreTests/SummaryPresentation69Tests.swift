import Foundation
import Testing
@testable import GlanceCore

// User-reported prose; all page/quote/controller evidence below is synthetic.
// These tests never call a model, Wikipedia, or a physical device.
private let reported69 = "『アサヒ生ビール マルエフ』はアサヒビールのブランドのビールです。アサヒビールは日本の大手ビールメーカーで、主力商品『アサヒスーパードライ』などを展開しています。"
private let originalName69 = "アサヒ生ビール マルエフ"
private let chinese69 = "這是一款日本啤酒，產品原名為アサヒ生ビール マルエフ。"
private func card69(first: String = chinese69, second: String? = reported69) -> ArchivedRecognition {
    let id = UUID(), result = RecognitionResult(names: [originalName69], summary: first,
        text: ["アサヒ生ビール", "マルエフ"], sourceImageID: id, searchContractVersion: 17,
        searchEntities: [.init(kind: .product, name: originalName69, sourceText: "アサヒ生ビール\nマルエフ")])
    var card = ArchivedRecognition(schemaVersion: 1, id: id, sequence: 1, capturedAt: Date(), imageSHA256: String(repeating: "a", count: 64), imageByteCount: 1, status: .succeeded, result: result, message: nil, completedAt: Date())
    if let second {
        let source = WikipediaReviewSource(pageID: 69, title: "アサヒビール", url: URL(string: "https://ja.wikipedia.org/wiki/アサヒビール")!, fetchedAt: Date(), excerpts: [.init(id: "p0", text: "アサヒビールは日本のビールメーカーである。")])
        var review = RecognitionSemanticReview(recordID: id, attemptID: id)
        review.state = .succeeded; review.sources = [source]
        review.answer = .init(decision: .selected, sourceID: source.id, relationship: .brand, searchName: originalName69, summary: second, citations: [.init(excerptID: "p0", quote: source.excerpts[0].text)])
        card.semanticReview = review
    }
    return card
}

@Suite struct SummaryPresentation69 {
    @Test func firstStageDisplaysAllLanguagesAndEmptyVerbatim() {
        for text in [chinese69, reported69, "这是一款啤酒，原名保留。", "Beer from Japan.", "日本製麦酒", "Asahi", "12345", "", "原名まろやかな泡，這段是中文。"] {
            let card = card69(first: text, second: nil)
            #expect(card.presentationResult?.summary == text)
            #expect(card.shareResult?.summary == text)
            #expect(card.result?.summary == text)
        }
    }
    @Test func validSecondStageDisplaysVerbatimWithoutLanguageFallback() {
        for text in [chinese69, reported69, "这是一款啤酒，保留原字形。", "Beer from Japan.", "これは日本のビールです。這是中文。", "日本製麦酒"] {
            let card = card69(second: text)
            #expect(card.currentSemanticReview?.source != nil)
            #expect(card.presentationResult?.summary == text)
            #expect(card.shareResult?.summary == text)
            #expect(card.result?.summary == chinese69)
        }
    }
    @Test func quotedJapaneseInsideChineseDoesNotRemoveIntroduction() {
        let text = "照片中央是印有「マルエフ」的日本啤酒罐。マルエフ是朝日啤酒的品牌名稱；罐身可見的「まろやかな泡」意為口感柔和的泡沫。"
        let card = card69(first: text, second: nil)
        #expect(card.presentationResult?.summary == text)
        #expect(card.shareDocument().body.contains(text))
    }
    @Test func actualMixedReplyRemainsOriginalRatherThanUnavailable() {
        let text = "アサヒビール株式会社は日本の大手ビールメーカーで、現在はアサヒグループジャパンの100％子会社です。產品上的「アサヒ生ビール マルエフ」屬於「アサヒビール」品牌。"
        let card = card69(second: text)
        #expect(card.presentationResult?.summary == text)
        #expect(!card.shareDocument().body.contains("並非百科補充"))
        #expect(!card.shareDocument().body.contains("尚未取得"))
    }
    @Test func contextualKeepsOriginalTwoStageConcatenationAndEmptyFiltering() {
        for first in [chinese69, ""] {
            var card = card69(first: first)
            card.result = .init(names: [originalName69], summary: first, text: ["アサヒビール"], sourceImageID: card.id, searchContractVersion: 17,
                searchEntities: [.init(id: 1, role: .text, kind: .company, name: "アサヒビール", sourceRole: .public_text, sourceText: "アサヒビール")])
            let old = card.semanticReview!.answer!
            card.semanticReview?.answer = .init(decision: .selected, sourceID: old.sourceID, relationship: .contextual, searchName: "アサヒビール", summary: reported69, citations: old.citations)
            #expect(card.currentSemanticReview?.source != nil)
            #expect(card.presentationResult?.summary == [first, reported69].filter { !$0.isEmpty }.joined(separator: "\n\n"))
        }
    }
    @Test func failedReviewPreservesFirstAndEmptyWithoutNewNotice() {
        for first in [chinese69, "", reported69] {
            var card = card69(first: first)
            card.semanticReview?.state = .failed
            #expect(card.currentSemanticReview?.source == nil)
            #expect(card.presentationResult?.summary == first)
            #expect(card.shareResult?.summary == first)
        }
    }
    @Test func staleAttemptCannotReplaceCurrentFirstStage() {
        var card = card69()
        card.attempts = [.init(id: UUID(), startedAt: Date(), outcome: .succeeded)]
        #expect(card.currentSemanticReview == nil)
        #expect(card.presentationResult?.summary == chinese69)
    }
    @Test func emptyOrInvalidCitationStillCannotBecomeSelectedSource() throws {
        let card = card69(), review = card.semanticReview!, old = review.answer!
        for answer in [WikipediaReviewAnswer(decision: .selected, sourceID: old.sourceID, relationship: .brand, searchName: originalName69, summary: "", citations: old.citations), WikipediaReviewAnswer(decision: .selected, sourceID: old.sourceID, relationship: .brand, searchName: originalName69, summary: reported69, citations: [.init(excerptID: "p0", quote: "這句不在來源中。")])] {
            let raw = String(decoding: try JSONEncoder().encode(answer), as: UTF8.self)
            #expect(throws: (any Error).self) { try WikipediaSemanticReview.parse(raw, sources: review.sources, result: card.result) }
            var invalid = card; invalid.semanticReview?.answer = answer
            #expect(invalid.currentSemanticReview?.source == nil)
            #expect(invalid.presentationResult?.summary == chinese69)
        }
        let noMatch = WikipediaReviewAnswer(decision: .no_match)
        var unmatched = card; unmatched.semanticReview?.answer = noMatch
        #expect(unmatched.presentationResult?.summary == chinese69)
    }
    @Test func oldCardReopenSharesChosenSummaryAndPreservesRawJSONEvidence() throws {
        var card = card69(); let answer = card.semanticReview!.answer!; let id = card.id
        let raw = String(decoding: try JSONEncoder().encode(answer), as: UTF8.self)
        card.semanticReview?.modelResponse = .capture(raw, sourceImageID: id, attemptID: id, appVersion: "0.1.0", appBuild: "68", promptRevision: "W5-English-summary-language-zhTW1")
        let encoded = try JSONEncoder().encode(card)
        let reopened = try JSONDecoder().decode(ArchivedRecognition.self, from: encoded)
        let doc = reopened.shareDocument()
        #expect(reopened.presentationResult?.summary == reported69)
        for text in [doc.body, doc.plainText, doc.html] { #expect(text.contains(reported69)); #expect(!text.contains("並非百科補充")) }
        #expect(reopened.semanticJSONDocument?.rawText == raw)
        #expect(reopened.semanticReview?.answer?.citations == answer.citations)
        #expect(doc.links.first { $0.label.hasPrefix("維基百科：") }?.url == card.semanticReview?.source?.url)
        #expect(reopened.result == card.result)
        #expect(reopened.semanticReview == card.semanticReview)
        #expect(reopened.result?.names == [originalName69])
        #expect(reopened.result?.text == ["アサヒ生ビール", "マルエフ"])
    }
    @Test func legacySchemaHasSameUnmodifiedProjection() throws {
        for version in [16, 17] {
            var card = card69(first: "这段中文包含まろやかな泡。", second: nil)
            card.result = .init(names: [originalName69], summary: card.result!.summary, text: [], searchContractVersion: version)
            let reopened = try JSONDecoder().decode(ArchivedRecognition.self, from: JSONEncoder().encode(card))
            #expect(reopened.presentationResult?.summary == "这段中文包含まろやかな泡。")
        }
    }
    @Test func assembledRequestsKeepP22W5ChineseRequirement() throws {
        let catalog = [SIWCModel(slug: "gpt-6-luna", display_name: "Fixture", visibility: "list")]
        let camera = try JSONSerialization.jsonObject(with: CameraAnswer.request(model: "gpt-6-luna", catalog: catalog, jpeg: Data([6,9]))) as! [String:Any]
        let first = ((camera["input"] as! [[String:Any]])[0]["content"] as! [[String:Any]])[0]["text"] as! String
        let card = card69(), review = card.semanticReview!
        let wiki = try JSONSerialization.jsonObject(with: WikipediaSemanticReview.request(result: card.result!, rawStageOne: nil, sources: review.sources, catalog: catalog)) as! [String:Any]
        let second = ((wiki["input"] as! [[String:Any]])[0]["content"] as! [[String:Any]])[0]["text"] as! String
        for prompt in [first, second] { #expect(prompt.contains("Summary prose must always be Taiwan Traditional Chinese")) }
        #expect(CameraAnswer.promptRevision == "P22-English-summary-language-zhTW1")
        #expect(WikipediaSemanticReview.promptRevision == "W5-English-summary-language-zhTW1")
    }
    @Test func storedW4RequestCompatibilityAndFiveSourcesRemain() throws {
        let card = card69(), input = try WikipediaSemanticReview.input(result: card.result!, rawStageOne: nil, sources: card.semanticReview!.sources)
        let request = try RecognitionModelRequest.capture(input, recordID: card.id, attemptID: card.id, runID: UUID(), appVersion: "0.1.0", appBuild: "67")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String:Any]
        json["promptRevision"] = "W4-English-central-priority-zhTW1"
        let legacy = try JSONDecoder().decode(RecognitionModelRequest.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.valid && legacy.rawPayload == request.rawPayload)
        #expect(WikipediaSemanticReview.prompt.hasPrefix(WikipediaSemanticReview.legacyPromptW4))
        #expect(WikipediaReviewBudget.sourceLimit == 5 && WikipediaSemanticReview.inputVersion == 3)
    }
}

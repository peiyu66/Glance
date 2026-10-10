import Foundation
import Testing
@testable import GlanceCore

@Test func summarySchemaAcceptsLegacyMissingNullAndEmpty() throws {
    for extra in ["", #",\"summary\":null"#, #",\"summary\":\"  \""#] {
        let suffix = extra.replacingOccurrences(of: "\\\"", with: "\"")
        let result = try CameraAnswer.parse(#"{"names":["瓶子"],"text":["日本語"],"barcodes":["00123"]"# + suffix + "}")
        #expect(result.summary.isEmpty)
        #expect(result.lines == ["瓶子", "日本語", "00123"])
    }
}
@Test func summarySchemaRejectsWrongTypeAndMissingRequiredArrays() {
    for raw in [#"{"names":[],"summary":[],"text":[],"barcodes":[]}"#,
                #"{"names":[],"summary":42,"text":[],"barcodes":[]}"#,
                #"{"summary":"看得到瓶子"}"#] {
        #expect(throws: (any Error).self) { try CameraAnswer.parse(raw) }
    }
}
@Test func summarySupportsParagraphsAndBoundsLongContent() throws {
    let long = String(repeating: "這是清楚可見的合成包裝介紹。\n", count: 180)
    let data = try JSONSerialization.data(withJSONObject: ["names": [], "summary": long, "text": ["原文を保持"], "barcodes": []])
    let result = try CameraAnswer.parse(String(decoding: data, as: UTF8.self))
    #expect(result.summary.count <= 1600 && result.summary.contains("\n"))
    #expect(result.text == ["原文を保持"])
    #expect(!result.lines.isEmpty)
    let onlySummary = try CameraAnswer.parse(#"{"names":[],"summary":"可見一個白色瓶子。","text":[],"barcodes":[]}"#)
    #expect(onlySummary.lines == ["可見一個白色瓶子。"])
}
@Test func syntheticJapaneseMedicineSummaryKeepsOriginalEvidenceSeparate() throws {
    // Authored fixture, never a real user's label or a claim about model behavior.
    let result = try CameraAnswer.parse(#"{"names":["日文標示藥瓶"],"summary":"這是帶有日文標籤的藥瓶。可讀標籤標示第二類醫藥品，內容量為30錠；其餘細節無法確認。","text":["合成サンプル","第2類医薬品","内容量 30錠","ABC-001"],"barcodes":["0012345678905"]}"#)
    #expect(result.summary.contains("日文標籤") && result.summary.contains("其餘細節無法確認"))
    #expect(result.text == ["合成サンプル", "第2類医薬品", "内容量 30錠", "ABC-001"])
    #expect(result.barcodes == ["0012345678905"])
    #expect(result.summary != result.text.joined(separator: "\n"))
}
@Test func summaryPromptRequiresGroundingAndMedicineRestraint() throws {
    let model = SIWCModel(slug: "gpt-6-luna", display_name: "Fixture", visibility: "list")
    let data = try CameraAnswer.request(model: model.slug, catalog: [model], jpeg: Data([1]))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let input = try #require(object["input"] as? [[String: Any]])
    let content = try #require(input.first?["content"] as? [[String: Any]])
    let prompt = try #require(content.first?["text"] as? String)
    for required in ["AI-authored summary", "zh-Hant-TW", "only clearly visible evidence", "not a line-by-line translation", "empty summary string", "never infer therapeutic effects, ingredients, dosage or suitability", "never give personal medical advice", "No web lookup, outside facts"] {
        #expect(prompt.contains(required))
    }
}
@Test func readingIdentityUsesContentAndSummaryIsNotDropped() {
    let a = RecognitionResult(names: ["瓶子"], summary: "日文標籤的瓶子。", text: ["サンプル"])
    let same = RecognitionResult(names: ["瓶子"], summary: "日文標籤的瓶子。", text: ["サンプル"])
    let b = RecognitionResult(names: ["瓶子"], summary: "另一個有不同標籤的瓶子。", text: ["サンプル"])
    #expect(a == same && Set([a, same, b]).count == 2)
    #expect(a.lines == ["瓶子", "日文標籤的瓶子。", "サンプル"])
}

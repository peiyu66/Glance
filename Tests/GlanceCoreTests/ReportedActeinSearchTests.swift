import Foundation
import Testing
@testable import GlanceCore

@Suite struct ReportedActeinSearchTests {
    let summary = "這是標示為 Actein 的藥品顆粒包裝；顆粒劑是將藥物製成可分散或吞服的小顆粒的劑型。"
    let original = ["synmosa", "3g", "Actein®", "Granules 66.7mg/gm"]
    func card(_ result: RecognitionResult) -> ArchivedRecognition {
        .init(schemaVersion: 1, id: UUID(), sequence: 1, capturedAt: Date(), imageSHA256: "synthetic", imageByteCount: 1,
              status: .succeeded, result: result, message: nil, completedAt: Date(), decodedBarcodes: [], productBarcodes: [])
    }
    @Test func exactReportedPublicPackageGetsFallbackAndSharedURL() throws {
        let result = RecognitionResult(names: ["Actein 顆粒"], summary: summary, text: original)
        let first = card(result)
        let restored = try JSONDecoder().decode(ArchivedRecognition.self, from: JSONEncoder().encode(first))
        for item in [first, restored] {
            #expect(item.result?.searchQuery == nil && item.result?.searchRestriction == nil)
            #expect(item.googleSearch?.query == "Actein 顆粒")
            let url = try #require(item.googleSearch?.googleURL), document = item.shareDocument()
            #expect(document.links == [.init(label: "Google 搜尋：Actein 顆粒", url: url)])
            #expect(document.plainText.contains(url.absoluteString) && document.html.contains("href=\""))
            #expect(original.allSatisfy { document.body.contains($0) })
            #expect(!document.displayText.contains("維基百科"))
        }
    }
    @Test func resultLanguageDoesNotRestrictOrTranslateKeywordLanguage() throws {
        for (name, ocr) in [("Actein", original), ("Actein Granules", original), ("アクテイン顆粒", ["アクテイン", "顆粒", "3g"]), ("Actein 顆粒", original)] {
            for base in [nil, PublicSearchQuery(query: name, category: "product")] {
                let item = card(.init(names: [name], text: ocr, searchQuery: base))
                let url = try #require(item.googleSearch?.googleURL)
                #expect(item.googleSearch?.query == name)
                #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [.init(name: "q", value: name), .init(name: "gl", value: "tw"), .init(name: "lr", value: "lang_zh-TW")])
                #expect(item.shareDocument().links.first?.label == "Google 搜尋：" + name)
                #expect(item.result?.text == ocr)
            }
        }
    }
    @Test func hiddenRejectionMetadataCanExplainSameVisibleTextWithoutProvingIncident() throws {
        for reason in [ManualSearchRestriction.sensitive, .conflict, .uncertain, .invalidRestriction, .rejectedSearch] {
            let item = card(.init(names: ["Actein 顆粒"], summary: summary, text: original, searchRestriction: reason))
            #expect(item.googleSearch == nil && item.shareDocument().links.isEmpty)
            #expect(item.shareDocument().body == card(.init(names: ["Actein 顆粒"], summary: summary, text: original)).shareDocument().body)
        }
        let base: [String: Any] = ["names": ["Actein 顆粒"], "summary": summary, "text": original, "barcodes": []]
        for category in ["medicine", "drug"] {
            var payload = base; payload["search"] = ["query": "Actein", "category": category]
            let parsed = try CameraAnswer.parse(String(decoding: JSONSerialization.data(withJSONObject: payload), as: UTF8.self))
            #expect(parsed.searchRestriction == .rejectedSearch && card(parsed).googleSearch == nil)
        }
    }
    @Test func publicPackageOCRDoesNotTriggerPatientFilterButPrivateRecordsStillStopFallback() {
        #expect(card(.init(names: ["Actein 顆粒"], summary: summary, text: original)).googleSearch != nil)
        for marker in ["Patient name: Synthetic", "患者姓名：合成人名", "Medical history"] {
            #expect(card(.init(names: ["Actein 顆粒"], text: original + [marker])).googleSearch == nil)
        }
    }
    @Test func sensitiveRestrictionHasExplicitWireOriginsNotDrugNameDetection() throws {
        let base: [String: Any] = ["names": ["Actein 顆粒"], "summary": summary, "text": original, "barcodes": [], "wikipedia": NSNull()]
        var ordinary = base
        ordinary["search"] = ["query": "Actein", "category": "product"]
        ordinary["search_block_reason"] = NSNull()
        let publicResult = try CameraAnswer.parse(String(decoding: JSONSerialization.data(withJSONObject: ordinary), as: UTF8.self))
        #expect(publicResult.searchRestriction == nil && publicResult.wikipediaTopics == nil)
        #expect(card(publicResult).googleSearch?.query == "Actein")
        // A model privacy reason and a model private-category value both map to
        // the same saved enum. The archive cannot reconstruct which wire shape it received.
        var explicit = ordinary; explicit["search_block_reason"] = "sensitive"
        var category = base; category["search"] = ["query": "Actein", "category": "medical_record"]
        for payload in [explicit, category] {
            let parsed = try CameraAnswer.parse(String(decoding: JSONSerialization.data(withJSONObject: payload), as: UTF8.self))
            #expect(parsed.searchRestriction == .sensitive && parsed.searchQuery == nil)
            #expect(card(parsed).googleSearch == nil)
        }
    }
    @Test func missingPublicDrugSearchAndExplicitPrivateMedicalRecordRemainDifferent() throws {
        let base: [String: Any] = ["names": ["Actein 顆粒"], "text": original, "barcodes": [], "search": NSNull(), "wikipedia": NSNull()]
        let publicResult = try CameraAnswer.parse(String(decoding: JSONSerialization.data(withJSONObject: base), as: UTF8.self))
        #expect(publicResult.searchRestriction == nil && card(publicResult).googleSearch?.query == "Actein 顆粒")
        var privateRecord = base
        privateRecord["text"] = original + ["患者姓名：合成測試", "用藥紀錄"]
        privateRecord["search_block_reason"] = "sensitive"
        let privateResult = try CameraAnswer.parse(String(decoding: JSONSerialization.data(withJSONObject: privateRecord), as: UTF8.self))
        #expect(privateResult.searchRestriction == .sensitive && card(privateResult).googleSearch == nil)
        privateRecord["search_block_reason"] = NSNull()
        let missingReason = try CameraAnswer.parse(String(decoding: JSONSerialization.data(withJSONObject: privateRecord), as: UTF8.self))
        #expect(missingReason.searchRestriction == nil && card(missingReason).googleSearch == nil)
    }
}

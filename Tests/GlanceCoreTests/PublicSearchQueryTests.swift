import Foundation
import Testing
@testable import GlanceCore

@Test func publicSearchEncodesOneQueryWithoutURLInjection() throws {
    for raw in ["麒麟 一番搾", "C++ & 耐熱 100% #1", "Acme A/B ?q=second&x=3"] {
        let search = try #require(PublicSearchQuery(query: raw, category: "product"))
        let url = try #require(search.googleURL)
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.scheme == "https" && parts.host == "www.google.com" && parts.path == "/search")
        #expect(parts.queryItems == [URLQueryItem(name: "q", value: raw), URLQueryItem(name: "gl", value: "tw")])
        #expect(parts.fragment == nil && parts.user == nil)
        #expect(!url.absoluteString.contains("+"))
    }
}

@Test func publicSearchRejectsPrivateOrUnboundedValues() {
    for value in ["", "X", "a@example.test", "https://example.test", "www.example.test", "0900-123-456", "密碼 abc", "token ABC", "0123456789012", "AB\n私人內容", String(repeating: "物", count: 121)] {
        #expect(PublicSearchQuery(query: value, category: "product") == nil)
    }
    for category in ["person", "document", "medical_record", "unknown", ""] {
        #expect(PublicSearchQuery(query: "私人名稱", category: category) == nil)
    }
    #expect(PublicSearchQuery(query: "Acme AB-001", category: "product") != nil)
}

@Test func optionalSearchDoesNotBreakOldOrMalformedAnswers() throws {
    let prefix = #"{"names":["茶罐"],"summary":"類別介紹","text":["私人 OCR 不能自動成為搜尋"],"barcodes":[]"#
    for suffix in ["}", #", "search":null}"#, #", "search":"bad"}"#, #", "search":{"query":"a@example.test","category":"product"}}"#] {
        let result = try CameraAnswer.parse(prefix + suffix)
        #expect(result.names == ["茶罐"] && result.searchQuery == nil)
    }
    let good = try CameraAnswer.parse(prefix + #", "search":{"query":"Acme Tea AB-001","category":"product"}}"#)
    #expect(good.searchQuery?.query == "Acme Tea AB-001")
    let unknown = try CameraAnswer.parse(#"{"names":[" "],"text":[],"barcodes":[],"search":{"query":"Acme Tea","category":"product"}}"#)
    #expect(unknown.searchQuery == nil)
}

@Test func searchSurvivesOwnCardCompletionAndRestartWithoutCrossCardCopy() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root)
    let a = UUID(), b = UUID()
    let first = PublicSearchQuery(query: "Acme Tea AB-001", category: "product")!
    let second = PublicSearchQuery(query: "Camellia sinensis", category: "species")!
    _ = try await archive.create(id: a, jpeg: Data([1]), capturedAt: Date(), decodedBarcodes: ["00001"])
    _ = try await archive.create(id: b, jpeg: Data([2]), capturedAt: Date(), decodedBarcodes: [])
    _ = try await archive.complete(id: b, result: .init(names: ["茶樹"], searchQuery: second), message: nil)
    _ = try await archive.complete(id: a, result: .init(names: ["茶罐"], text: ["未修改\r\n原文"], barcodes: ["00001"], searchQuery: first), message: nil)
    let restored = try await RecognitionArchive(root: root).load().records
    #expect(restored.map(\.id) == [b, a])
    #expect(restored.map { $0.result?.searchQuery } == [second, first])
    #expect(restored.last?.shareResult?.sourceImageID == a)
    let shared = try #require(restored.last?.shareResult?.shareText)
    #expect(shared.contains("\n\n【原文】\n\n未修改\r\n原文\n\n【條碼】\n\n00001"))
    #expect(shared.components(separatedBy: "00001").count == 2)
    #expect(!shared.contains("google") && !shared.contains(first.query))
}

@Test func legacyPersistedResultWithoutSearchRemainsReadable() throws {
    let data = Data(#"{"names":["舊卡"],"summary":"介紹","text":[],"barcodes":[]}"#.utf8)
    let result = try JSONDecoder().decode(RecognitionResult.self, from: data)
    #expect(result.searchQuery == nil && result.names == ["舊卡"])
}

@Test func searchPromptKeepsSingleImageNoSearchToolsAndPrivacyBoundary() throws {
    let model = SIWCModel(slug: "gpt-6-luna", display_name: "Fixture", visibility: "list")
    let body = try CameraAnswer.request(model: model.slug, catalog: [model], jpeg: Data([1, 2]))
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["tools"] == nil)
    let input = try #require(object["input"] as? [[String: Any]])
    let content = try #require(input.first?["content"] as? [[String: String]])
    #expect(content.filter { $0["type"] == "input_image" }.count == 1)
}

@Test func googleAppendsOnlyTypedSameCardBarcodeAndPreservesOriginalRepresentation() throws {
    let base = try #require(PublicSearchQuery(query: "Maker’s Mark C++ & 200 ml", category: "product"))
    for (raw, symbology) in [("085246139462", ProductBarcode.Symbology.upca), ("0085246139462", .ean13), ("96385074", .ean8)] {
        let barcode = try #require(ProductBarcode(value: raw, symbology: symbology))
        let search = try #require(GoogleSearchQuery(base: base, productBarcodes: [barcode, barcode]))
        #expect(search.query == base.query + " " + raw)
        #expect(search.query.components(separatedBy: raw).count == 2)
        #expect(GoogleSearchQuery(base: base, productBarcodes: [barcode, barcode]) == search)
        let url = try #require(search.googleURL)
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [.init(name: "q", value: search.query), .init(name: "gl", value: "tw")])
        #expect(!url.absoluteString.contains("+") && url.fragment == nil)
        #expect(base.query == "Maker’s Mark C++ & 200 ml")
    }
}

@Test func googleWithoutTrustedCodeKeepsBaseAndAmbiguousCodesAreNotGuessed() throws {
    let base = try #require(PublicSearchQuery(query: "公開  商品", category: "product"))
    #expect(GoogleSearchQuery(base: base, productBarcodes: [])?.query == base.query)
    let a = try #require(ProductBarcode(value: "3017620422003", symbology: .ean13))
    let b = try #require(ProductBarcode(value: "5901234123457", symbology: .ean13))
    #expect(GoogleSearchQuery(base: base, productBarcodes: [a,b])?.query == base.query)
    #expect(GoogleSearchQuery(base: nil, productBarcodes: [a,b]) == nil)
    let upc = try #require(ProductBarcode(value: "085246139462", symbology: .upca))
    let ean = try #require(ProductBarcode(value: "0085246139462", symbology: .ean13))
    #expect(GoogleSearchQuery(base: base, productBarcodes: [ean,upc])?.query.hasSuffix(" 0085246139462") == true)
}

@Test func googleBarcodeOnlyWorksOnFailedCardWithoutOCROrAIBarcodeFallback() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID(), other = UUID()
    let barcode = try #require(ProductBarcode(value: "0085246139462", symbology: .ean13))
    let pending = try await archive.create(id: id, jpeg: Data([1]), capturedAt: Date(), decodedBarcodes: [barcode.value], productBarcodes: [barcode])
    #expect(pending.googleSearch == nil && !pending.canShare)
    let failed = try await archive.complete(id: id, result: nil, message: "辨識失敗")
    #expect(failed.googleSearch?.query == barcode.value)
    #expect(failed.shareText().contains("Google 搜尋：" + barcode.value))
    _ = try await archive.create(id: other, jpeg: Data([2]), capturedAt: Date(), decodedBarcodes: [barcode.value])
    let untyped = try await archive.complete(id: other, result: .init(names: ["物件"], text: ["住址、電話 0900123456"], barcodes: [barcode.value]), message: nil)
    #expect(untyped.googleSearch == nil && !untyped.shareText().contains("Google 搜尋"))
    let restored = try await RecognitionArchive(root: root).load().records
    #expect(restored.first { $0.id == id }?.googleSearch == failed.googleSearch)
    #expect(restored.first { $0.id == other }?.googleSearch == nil)
}

@Test func googleShareUsesExactlySameDerivedQueryAndURLWithoutChangingModelAnswer() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID()
    let barcode = try #require(ProductBarcode(value: "0085246139462", symbology: .ean13))
    let base = try #require(PublicSearchQuery(query: "美格 200 ml", category: "product", automaticWikipediaAllowed: true))
    _ = try await archive.create(id: id, jpeg: Data([1]), capturedAt: Date(), decodedBarcodes: [barcode.value], productBarcodes: [barcode])
    let card = try await archive.complete(id: id, result: .init(names: ["美格"], searchQuery: base), message: nil)
    let search = try #require(card.googleSearch)
    #expect(card.result?.searchQuery == base)
    #expect(search.query == "美格 200 ml 0085246139462")
    #expect(card.shareText().contains("[Google 搜尋：" + search.query + "](" + search.googleURL!.absoluteString + ")"))
    #expect(card.shareText().components(separatedBy: "Google 搜尋：").count == 2)
}

@Test func googleWithoutLanguageFilterKeepsOriginalQueryLanguageAndShareOneURL() throws {
    let code = try #require(ProductBarcode(value: "0085246139462", symbology: .ean13))
    for raw in ["台湾 茶", "臺灣 茶", "English tea", "日本語 茶"] {
        let base = try #require(PublicSearchQuery(query: raw, category: "product"))
        for barcodes in [[ProductBarcode](), [code]] {
            let search = try #require(GoogleSearchQuery(base: base, productBarcodes: barcodes))
            let url = try #require(search.googleURL)
            let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(parts.queryItems == [.init(name: "q", value: raw + (barcodes.isEmpty ? "" : " " + code.value)), .init(name: "gl", value: "tw")])
            #expect(!url.absoluteString.contains("site:"))
            var record = ArchivedRecognition(schemaVersion: 1, id: UUID(), sequence: 1, capturedAt: Date(), imageSHA256: "fixture", imageByteCount: 1, status: .succeeded, result: .init(names: ["合成"], searchQuery: base), message: nil, completedAt: Date())
            record.productBarcodes = barcodes
            #expect(record.shareDocument().links.first?.url == url)
        }
    }
    let onlyCode = try #require(GoogleSearchQuery(base: nil, productBarcodes: [code]))
    #expect(URLComponents(url: onlyCode.googleURL!, resolvingAgainstBaseURL: false)?.queryItems == [.init(name: "q", value: code.value), .init(name: "gl", value: "tw")])
}

@Test func legacyQueryRegeneratesURLWithoutLanguageFilterAfterArchiveReopen() async throws {
    // Old records save only query/category, never a stale URL or language setting.
    let query = try JSONDecoder().decode(PublicSearchQuery.self,
        from: Data(#"{"query":"日本語 茶","category":"product"}"#.utf8))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID()
    _ = try await archive.create(id: id, jpeg: Data([1, 2, 3]), capturedAt: Date())
    _ = try await archive.complete(id: id, result: .init(names: ["茶"], searchQuery: query), message: nil)
    let reopened = try await RecognitionArchive(root: root).load()
    let card = try #require(reopened.records.first)
    let url = try #require(card.googleSearch?.googleURL)
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(items == [.init(name: "q", value: "日本語 茶"), .init(name: "gl", value: "tw")])
    #expect(card.result?.searchQuery == query)
    #expect(card.shareDocument().links.first?.url == url)
}

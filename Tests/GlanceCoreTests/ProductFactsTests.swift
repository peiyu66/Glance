import Foundation
import Testing
@testable import GlanceCore
private let foodCode = ProductBarcode(value: "3017620422003", symbology: .ean13)!

@Test func productBarcodeRequiresChecksumSymbologyAndGlobalNumericCode() throws {
    #expect(foodCode.code == "3017620422003")
    #expect(ProductBarcode(value: "96385074", symbology: .ean8) != nil)
    let upc = try #require(ProductBarcode(value: "034000470693", symbology: .upca))
    #expect(upc.code == "0034000470693")
    let ean8 = try #require(ProductBarcode(value: "96385074", symbology: .ean8))
    let padded = try #require(ProductBarcode(value: "0000096385074", symbology: .ean13))
    #expect(ean8.code == padded.code && padded.value == "0000096385074")
    for raw in ["3017620422004", "301762042200", " 3017620422003", "https://example.test/3017620422003", "３０１７６２０４２２００３", "0000000000000", "2000000000008", "0500000000005", "0000000000017"] {
        #expect(ProductBarcode(value: raw, symbology: .ean13) == nil)
    }
    #expect(ProductBarcode(value: "3017620422003", symbology: .ean8) == nil)
    #expect(ProductBarcode(value: "00000017", symbology: .ean8) == nil)
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(ProductBarcode.self, from: Data(#"{"value":"3017620422004","symbology":"ean13"}"#.utf8))
    }
}

@Test func legacyProductMetadataRemainsReadableButNotShared() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID(), date = Date()
    _ = try await archive.create(id: id, jpeg: Data([1,2]), capturedAt: date, decodedBarcodes: [foodCode.value], productBarcodes: [foodCode])
    let facts = ProductFacts(code: foodCode.code, provider: .food, fields: [.init(kind: .name, value: "舊商品資料")], checkedAt: date)
    _ = try await archive.attachProductFacts(id: id, facts: facts)
    let answer = RecognitionResult(names: ["原名稱"], summary: "原簡介", text: ["原文"])
    let saved = try await archive.complete(id: id, result: answer, message: nil)
    let recordURL = root.appendingPathComponent(id.uuidString).appendingPathComponent("record.json")
    let before = try Data(contentsOf: recordURL)
    let restored = try #require(try await RecognitionArchive(root: root).load().records.first)
    #expect(restored == saved && restored.productFacts == facts)
    #expect(restored.result?.summary == "原簡介" && restored.result?.text == ["原文"])
    #expect(restored.barcodes == [foodCode.value] && restored.imageSHA256 == RecognitionArchive.hash(Data([1,2])))
    #expect(try Data(contentsOf: recordURL) == before)
    for omitted in ["舊商品資料", "openfoodfacts", "Open Food Facts", "ODbL", "DbCL"] { #expect(!restored.shareText().contains(omitted)) }
    #expect(restored.shareText().contains("Google 搜尋：" + foodCode.value))
    var payload = try #require(JSONSerialization.jsonObject(with: before) as? [String: Any])
    payload["productFacts"] = ["unsupported": true]
    let malformed = try JSONDecoder().decode(ArchivedRecognition.self, from: JSONSerialization.data(withJSONObject: payload))
    #expect(malformed.productFacts == nil && malformed.result == restored.result && malformed.productBarcodes == restored.productBarcodes)
}

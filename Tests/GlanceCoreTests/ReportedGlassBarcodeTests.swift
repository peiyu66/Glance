import Foundation
import Testing
@testable import GlanceCore

@Suite struct ReportedGlassBarcodeTests {
    let digits = "4713213242926"
    func card(products: [ProductBarcode] = [], decoded: [String]? = nil, search: Bool = true, name: String = "玻璃杯") -> ArchivedRecognition {
        .init(schemaVersion: 1, id: UUID(), sequence: 1, capturedAt: Date(), imageSHA256: "synthetic", imageByteCount: 1,
              status: .succeeded, result: .init(names: [name], text: [digits], barcodes: [digits],
                searchQuery: search ? PublicSearchQuery(query: name, category: "object") : nil),
              message: nil, completedAt: Date(), decodedBarcodes: decoded, productBarcodes: products)
    }
    @Test func reportedDigitsPassExistingGTINRulesWithoutRelaxation() throws {
        #expect(ProductBarcode.normalized(digits) == digits)
        #expect(try #require(ProductBarcode(value: digits, symbology: .ean13)).value == digits)
        #expect(ProductBarcode(value: "4713213242925", symbology: .ean13) == nil)
    }
    @Test func typedEANAppendsToSameQueryAcrossPersistenceAndShare() throws {
        let code = try #require(ProductBarcode(value: digits, symbology: .ean13))
        let original = card(products: [code], decoded: [digits])
        let restored = try JSONDecoder().decode(ArchivedRecognition.self, from: JSONEncoder().encode(original))
        for item in [original, restored] {
            let q = try #require(item.googleSearch), url = try #require(q.googleURL)
            #expect(q.query == "玻璃杯 " + digits)
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value == q.query)
            let document = item.shareDocument()
            #expect(document.links == [.init(label: "Google 搜尋：" + q.query, url: url)])
            #expect(document.plainText.contains(url.absoluteString))
            #expect(document.html.contains("href=\""))
            #expect(item.result?.searchQuery?.query == "玻璃杯")
        }
    }
    @Test func visibleDigitsDoNotProveTypedProductProvenance() throws {
        // New untyped local decode and legacy AI-only barcode display look alike.
        for decoded in [[digits], nil] as [[String]?] {
            let item = card(decoded: decoded)
            #expect(item.barcodes == [digits] && item.result?.text == [digits])
            #expect(item.googleSearch?.query == "玻璃杯")
            #expect(item.shareDocument().links.first?.label == "Google 搜尋：玻璃杯")
        }
        #expect(card(decoded: []).barcodes.isEmpty) // modern empty local result overrides model guesses
        #expect(card(decoded: ["諮詢電話：0800-388-100"]).googleSearch?.query == "玻璃杯")
    }
    @Test func fallbackStillUsesSameGTINCompositionAndDoesNotPromoteGlassGenericName() throws {
        let code = try #require(ProductBarcode(value: digits, symbology: .ean13))
        #expect(card(products: [code], decoded: [digits], search: false, name: "Acme Glass X100").googleSearch?.query == "Acme Glass X100 " + digits)
        #expect(card(products: [code], decoded: [digits], search: false).googleSearch?.query == digits)
        #expect(card(decoded: [digits], search: false).googleSearch == nil)
    }
    @Test func multipleDistinctProductsDoNotChooseAnArbitraryCode() throws {
        let codes = try [digits, "3017620422003"].map { try #require(ProductBarcode(value: $0, symbology: .ean13)) }
        #expect(card(products: codes, decoded: codes.map(\.value)).googleSearch?.query == "玻璃杯")
    }
}

import Foundation
import UIKit
import CoreImage

@MainActor final class C7FactsProbe {
    static let firstCode = ProductBarcode(value: "3017620422003", symbology: .ean13)!
    static let secondCode = ProductBarcode(value: "5901234123457", symbology: .ean13)!
    static func facts(_ code: ProductBarcode) -> ProductFacts {
        .init(code: code.code, provider: .food, fields: [.init(kind: .name, value: "舊版合成商品 " + code.code)], checkedAt: Date())
    }
    static func image(_ code: ProductBarcode) -> UIImage {
        let left = ["0001101","0011001","0010011","0111101","0100011","0110001","0101111","0111011","0110111","0001011"]
        let even = ["0100111","0110011","0011011","0100001","0011101","0111001","0000101","0010001","0001001","0010111"]
        let patterns = ["LLLLLL", "LLGLGG", "LLGGLG", "LLGGGL", "LGLLGG", "LGGLLG", "LGGGLL", "LGLGLG", "LGLGGL", "LGGLGL"]
        let digits = code.code.compactMap(\.wholeNumberValue), parity = Array(patterns[code.code.first!.wholeNumberValue!])
        var bits = "101"
        if digits.count == 8 { for digit in digits.prefix(4) { bits += left[digit] } }
        else { for i in 0..<6 { bits += parity[i] == "L" ? left[digits[i + 1]] : even[digits[i + 1]] } }
        bits += "01010"
        for digit in digits.suffix(digits.count == 8 ? 4 : 6) { bits += String(left[digit].map { $0 == "0" ? "1" : "0" }) }
        bits += "101"
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 768, height: 768), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 768, height: 768))
            UIColor.black.setFill()
            for (index, bit) in bits.enumerated() where bit == "1" { context.fill(CGRect(x: 99 + index * 6, y: 284, width: 6, height: 200)) }
        }
    }
}

extension C2FixtureHost {
    func runReportedGlassBarcodeChecks() async -> [String: Bool] {
        var checks: [String: Bool] = [:], rows: [[String: Any]] = []
        for kind in ["EAN13", "EAN8", "QR", "Code128"] {
            let digits = kind == "EAN8" ? "96385074" : "4713213242926"
            let code = ProductBarcode(value: digits, symbology: kind == "EAN8" ? .ean8 : .ean13)!
            let image: UIImage
            if kind.hasPrefix("EAN") { image = C7FactsProbe.image(code) }
            else {
                let filter = CIFilter(name: kind == "QR" ? "CIQRCodeGenerator" : "CICode128BarcodeGenerator")!
                filter.setValue(Data(digits.utf8), forKey: "inputMessage")
                let output = filter.outputImage!, cg = CIContext().createCGImage(output, from: output.extent)!
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                image = UIGraphicsImageRenderer(size: CGSize(width: 768, height: 768), format: format).image { context in
                    UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 768, height: 768))
                    context.cgContext.interpolationQuality = .none
                    UIImage(cgImage: cg).draw(in: kind == "QR" ? CGRect(x: 84, y: 84, width: 600, height: 600) : CGRect(x: 60, y: 280, width: 648, height: 208))
                }
            }
            let host = C2FixtureHost(name: "reported-glass-" + kind, realBarcodes: true)
            try? FileManager.default.removeItem(at: host.root); await host.model.bootstrap()
            _ = host.model.beginAcquisition(); host.feed(source: image); await host.settle { host.waiter != nil }
            guard host.waiter != nil else { checks[kind + "_provider_reached"] = false; host.model.closePreview(); continue }
            host.waiter?.resume(returning: .init(names: ["玻璃杯"], text: [digits], barcodes: [digits], searchQuery: PublicSearchQuery(query: "玻璃杯", category: "object"))); host.waiter = nil
            await host.model.waitForCurrentWork()
            guard let card = host.model.records.first else { checks[kind + "_record_exists"] = false; continue }
            let expected = kind.hasPrefix("EAN") ? "玻璃杯 " + digits : "玻璃杯"
            checks[kind + "_local_decoder_has_exact_digits"] = card.decodedBarcodes == [digits]
            checks[kind + "_typed_product_provenance"] = card.productBarcodes == (kind.hasPrefix("EAN") ? [code] : [])
            checks[kind + "_saved_decoder_decision"] = card.barcodeDiagnostics?.observations.contains { $0.value == digits && $0.decision == (kind.hasPrefix("EAN") ? .acceptedProduct : .unsupportedSymbology) } == true
            checks[kind + "_targeted_EAN_pass"] = card.barcodeDiagnostics?.attempts.contains { $0.pass == .targetedEAN && $0.observationCount != nil } == true
            if kind.hasPrefix("EAN") {
                checks[kind + "_targeted_pass_has_exact_valid_product"] = card.barcodeDiagnostics?.observations.contains { $0.pass == .targetedEAN && $0.product == code } == true
            }
            checks[kind + "_query_and_URL_match"] = card.googleSearch?.query == expected && card.googleSearch?.googleURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value } == expected
            checks[kind + "_share_has_same_label_and_URL"] = card.shareText().contains("Google 搜尋：" + expected) && card.googleSearch?.googleURL.map { card.shareText().contains($0.absoluteString) } == true
            let reopened = host.makeModel(); await reopened.bootstrap()
            checks[kind + "_reopen_preserves_query_without_resend"] = reopened.records.first?.googleSearch == card.googleSearch && host.calls == 1
            checks[kind + "_diagnostics_survive_reopen"] = reopened.records.first?.barcodeDiagnostics == card.barcodeDiagnostics
            rows.append(["generatedSymbol": kind, "localValues": card.decodedBarcodes ?? [], "typedProducts": card.productBarcodes?.map(\.value) ?? [], "query": card.googleSearch?.query ?? "", "url": card.googleSearch?.googleURL?.absoluteString ?? "", "fixtureCalls": host.calls])
            host.model.closePreview(); reopened.closePreview()
        }
        checks["no_real_network"] = C8NetworkProbe.shared.count == 0
        let report: [String: Any] = ["checks": checks, "count": checks.count, "passed": checks.values.allSatisfy { $0 }, "cases": rows, "syntheticImagesOnly": true, "physicalCameraStarted": false, "realNetworkRequests": C8NetworkProbe.shared.count]
        try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: root.deletingLastPathComponent().appendingPathComponent("reported-glass-barcode.json"))
        return checks
    }
    func runProductChecks() async -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let host = C2FixtureHost(name: "barcode-google", realBarcodes: true)
        try? FileManager.default.removeItem(at: host.root); await host.model.bootstrap()
        _ = host.model.beginAcquisition(); host.feed(source: C7FactsProbe.image(C7FactsProbe.firstCode))
        await host.settle { host.waiter != nil }
        let id = host.model.records.first?.id
        checks["real_Vision_keeps_typed_barcode"] = host.model.records.first?.productBarcodes?.first?.value == C7FactsProbe.firstCode.value
        checks["pending_has_no_finished_search"] = host.model.records.first?.googleSearch == nil
        host.waiter?.resume(returning: C5WikipediaProbe.result("雨傘")); host.waiter = nil
        await host.model.waitForCurrentWork()
        let card = host.model.records.first!
        let query = "雨傘 " + C7FactsProbe.firstCode.value
        checks["Google_query_appends_same_source_barcode"] = card.googleSearch?.query == query
        checks["Google_URL_is_same_exact_query"] = card.googleSearch?.googleURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first?.value } == query
        checks["share_contains_same_query_and_URL"] = card.shareText().contains("Google 搜尋：" + query) && card.shareText().contains(card.googleSearch!.googleURL!.absoluteString)
        checks["no_product_fetch_or_attachment"] = card.productFacts == nil
        checks["same_request_image_ID"] = card.id == id && card.shareResult?.sourceImageID == id && host.calls == 1
        let reopened = host.makeModel(); await reopened.bootstrap()
        checks["restart_preserves_query_without_resend"] = reopened.records.first?.googleSearch == card.googleSearch && host.calls == 1
        _ = host.model.beginAcquisition(); host.feed(.white); await host.settle { host.waiter != nil }; await host.complete()
        let nextCard = host.model.records.first
        // The existing name fallback may search the new card's own explicit name.
        // Assert isolation directly instead of assuming every barcode-free card has no query.
        checks["no_barcode_next_card_does_not_borrow"] = nextCard?.id != card.id && nextCard?.sequence == 2 &&
            nextCard?.decodedBarcodes?.isEmpty == true && nextCard?.productBarcodes?.isEmpty == true &&
            nextCard?.googleSearch?.query == "合成第 2 張" && host.model.records.last?.googleSearch?.query == query
        checks["no_OFF_share_or_licenses"] = !card.shareText().contains("openfoodfacts") && !card.shareText().contains("ODbL") && !card.shareText().contains("DbCL")
        checks["no_real_network_requests"] = C8NetworkProbe.shared.count == 0
        host.model.closePreview(); reopened.closePreview()
        return checks
    }
}

final class C8NetworkProbe: @unchecked Sendable {
    static let shared = C8NetworkProbe()
    private let lock = NSLock()
    private var value = 0
    func record() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

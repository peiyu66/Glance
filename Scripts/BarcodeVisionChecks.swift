import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Compile together with Sources/GlanceCore/ProductFacts.swift and App/SourceBarcodeDecoder.swift on macOS.
/// All pixels are generated; there is no file input, camera, account, or network.
@main enum BarcodeVisionChecks {
    static func image(kind: String, turns: Int) -> Data {
        let context = CGContext(data: nil, width: 768, height: 768, bitsPerComponent: 8,
            bytesPerRow: 768 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 768, height: 768))
        context.translateBy(x: 384, y: 384); context.rotate(by: CGFloat(turns) * .pi / 2)
        context.interpolationQuality = .none
        if kind == "code128" {
            let filter = CIFilter(name: "CICode128BarcodeGenerator")!
            filter.setValue(Data("4713213242926".utf8), forKey: "inputMessage")
            let output = filter.outputImage!
            context.draw(CIContext().createCGImage(output, from: output.extent)!, in: CGRect(x: -320, y: -100, width: 640, height: 200))
        } else if kind == "qr" {
            let filter = CIFilter(name: "CIQRCodeGenerator")!
            filter.setValue(Data("4713213242926".utf8), forKey: "inputMessage")
            let output = filter.outputImage!
            context.draw(CIContext().createCGImage(output, from: output.extent)!, in: CGRect(x: -240, y: -240, width: 480, height: 480))
        } else if kind.hasPrefix("ean") {
            // Independent EAN-13 fixture encoder, not a production decoder.
            let left = ["0001101","0011001","0010011","0111101","0100011","0110001","0101111","0111011","0110111","0001011"]
            let even = ["0100111","0110011","0011011","0100001","0011101","0111001","0000101","0010001","0001001","0010111"]
            let raw = kind == "ean8" ? "96385074" : kind == "ean13glass" ? "4713213242926" : "5901234123457"
            let digits = raw.compactMap(\.wholeNumberValue)
            let parities = ["LLLLLL", "LLGLGG", "LLGGLG", "LLGGGL", "LGLLGG", "LGGLLG", "LGGGLL", "LGLGLG", "LGLGGL", "LGGLGL"]
            var bits = "101"
            if kind == "ean8" { for digit in digits.prefix(4) { bits += left[digit] } }
            else {
                let parity = Array(parities[digits[0]])
                for i in 0..<6 { bits += parity[i] == "L" ? left[digits[i + 1]] : even[digits[i + 1]] }
            }
            bits += "01010"
            for digit in digits.suffix(kind == "ean8" ? 4 : 6) { bits += String(left[digit].map { $0 == "0" ? "1" : "0" }) }
            bits += "101"
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            for (index, bit) in bits.enumerated() where bit == "1" {
                context.fill(CGRect(x: -285 + index * 6, y: -100, width: 6, height: 200))
            }
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }
    static func main() async throws {
        var checks: [String: Bool] = [:]
        var elapsed: [String: Double] = [:]
        for (kind, expected) in [("code128", "4713213242926"), ("qr", "4713213242926"), ("ean13", "5901234123457"), ("ean13glass", "4713213242926"), ("ean8", "96385074")] {
            for turn in 0..<4 {
                let jpeg = image(kind: kind, turns: turn)
                let start = ContinuousClock.now
                let scan = await SourceBarcodeDecoder.shared.scan(jpeg)
                let result = scan.values
                let key = "\(kind)_\(turn * 90)"
                checks[key] = result == [expected]
                checks[key + "_lookup_eligibility"] = kind.hasPrefix("ean") ? scan.products.map(\.code) == [expected] : scan.products.isEmpty
                let diagnostics = scan.diagnostics!
                checks[key + "_both_passes_same_image"] = Set(diagnostics.attempts.map(\.pass)) == [.general, .targetedEAN]
                checks[key + "_typed_decisions"] = diagnostics.observations.contains { $0.value == expected && $0.decision == (kind.hasPrefix("ean") ? .acceptedProduct : .unsupportedSymbology) }
                if kind.hasPrefix("ean") {
                    checks[key + "_targeted_pass_decoded"] = diagnostics.observations.contains { $0.pass == .targetedEAN && $0.product?.value == expected }
                }
                elapsed[key] = Double(start.duration(to: .now).components.attoseconds) / 1e15 + Double(start.duration(to: .now).components.seconds) * 1000
            }
        }
        checks["blank"] = await SourceBarcodeDecoder.shared.decode(image(kind: "blank", turns: 0)).isEmpty
        checks["invalid"] = await SourceBarcodeDecoder.shared.decode(Data([1, 2, 3])).isEmpty
        let report: [String: Any] = ["platform": "macOS Apple Vision", "syntheticOnly": true, "checks": checks, "elapsedMilliseconds": elapsed]
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
        if !checks.values.allSatisfy({ $0 }) { exit(1) }
    }
}

import Foundation
import Vision
import ImageIO

/// Decode only the immutable JPEG saved and sent for this capture. Both passes
/// run off the main actor, without camera, network, OCR guessing or cross-frame data.
actor SourceBarcodeDecoder {
    static let shared = SourceBarcodeDecoder()
    func decode(_ jpeg: Data) -> [String] { scan(jpeg).values }

    func scan(_ jpeg: Data) -> SourceBarcodeScan {
        typealias Diagnostics = SourceBarcodeDiagnostics
        var products: [ProductBarcode] = [], values: [String] = []
        var evidence: [Diagnostics.Observation] = [], attempts: [Diagnostics.Attempt] = []
        var seenValues = Set<String>(), seenEvidence = Set<Diagnostics.Observation>()
        let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
        if !jpeg.isEmpty {
            // A separate EAN-only request can recover product codes missed by the
            // general decoder. It uses the exact same bytes, even if general finds QR.
            for pass in [Diagnostics.Pass.general, .targetedEAN] {
                for orientation in orientations {
                    func perform(legacy: Bool) -> [VNBarcodeObservation]? {
                        let request = VNDetectBarcodesRequest()
                        if pass == .targetedEAN { request.symbologies = [.ean8, .ean13] }
                        if legacy { request.revision = VNDetectBarcodesRequestRevision1 }
                        do {
                            try VNImageRequestHandler(data: jpeg, orientation: orientation).perform([request])
                            let result = request.results ?? []
                            attempts.append(.init(pass: pass, orientation: orientation.rawValue,
                                revision: request.revision, observationCount: result.count))
                            return result
                        } catch {
                            attempts.append(.init(pass: pass, orientation: orientation.rawValue,
                                revision: request.revision, observationCount: nil))
                            // Runtime failure only. An ordinary empty result is not retried.
                            if !legacy && request.revision != VNDetectBarcodesRequestRevision1 { return perform(legacy: true) }
                            return nil
                        }
                    }
                    for observation in perform(legacy: false) ?? [] {
                        let kind: String
                        switch observation.symbology {
                        case .ean8: kind = "ean8"
                        case .ean13: kind = "ean13" // Includes zero-prefixed UPC-A as reported by Vision.
                        case .qr: kind = "qr"
                        case .code128: kind = "code128"
                        default: kind = observation.symbology.rawValue
                        }
                        let row = Diagnostics.Observation(value: observation.payloadStringValue, symbology: kind, pass: pass)
                        if seenEvidence.insert(row).inserted { evidence.append(row) }
                        if let value = row.value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           seenValues.insert(value).inserted { values.append(value) }
                        if let product = row.product, !products.contains(product) { products.append(product) }
                    }
                }
            }
        }
        return .init(values: values, products: products, diagnostics: .init(observations: evidence, attempts: attempts))
    }
}

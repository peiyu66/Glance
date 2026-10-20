import Foundation

/// Provenance is supplied by the local decoder, never by a model or OCR digit string.
public struct ProductBarcode: Codable, Equatable, Hashable, Sendable {
    public enum Symbology: String, Codable, Sendable { case ean8, ean13, upca }
    public let value: String
    public let symbology: Symbology
    public init?(value: String, symbology: Symbology) {
        let count = symbology == .ean8 ? 8 : symbology == .upca ? 12 : 13
        guard value.utf8.count == count, Self.normalized(value) != nil else { return nil }
        self.value = value; self.symbology = symbology
    }
    public var code: String { Self.normalized(value)! }
    public static func normalized(_ value: String) -> String? {
        let digits = Array(value.utf8)
        guard [8, 12, 13].contains(digits.count), digits.allSatisfy({ (48...57).contains($0) }),
              Set(digits).count > 1 else { return nil }
        let sum = digits.dropLast().reversed().enumerated().reduce(0) { $0 + Int($1.element - 48) * ($1.offset.isMultiple(of: 2) ? 3 : 1) }
        guard (sum + Int(digits.last! - 48)).isMultiple(of: 10) else { return nil }
        // OFF stores equivalent zero-prefixed codes at 8 or 13 digits.
        // Keep the original decoder payload in value for display/provenance.
        let significant = String(value.drop(while: { $0 == "0" }))
        let length = significant.count <= 8 ? 8 : 13
        let code = String(repeating: "0", count: length - significant.count) + significant
        // Restricted circulation / variable-weight and coupon prefixes are not global product IDs.
        // Conservatively skip short zero-prefixed and reserved/coupon-style codes too.
        guard !(code.count == 8 && code.hasPrefix("0")),
              !code.hasPrefix("2"), !code.hasPrefix("02"), !code.hasPrefix("04"), !code.hasPrefix("05"),
              !code.hasPrefix("98"), !code.hasPrefix("99") else { return nil }
        return code
    }
    private enum CodingKeys: String, CodingKey { case value, symbology }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let valid = Self(value: try c.decode(String.self, forKey: .value), symbology: try c.decode(Symbology.self, forKey: .symbology)) else {
            throw DecodingError.dataCorruptedError(forKey: .value, in: c, debugDescription: "Invalid product barcode")
        }
        self = valid
    }
}

public struct SourceBarcodeScan: Sendable {
    public let values: [String]
    public let products: [ProductBarcode]
    public let diagnostics: SourceBarcodeDiagnostics?
    public init(values: [String], products: [ProductBarcode] = [], diagnostics: SourceBarcodeDiagnostics? = nil) {
        self.values = values; self.products = products; self.diagnostics = diagnostics
    }
}

/// Local decoder provenance, stored with the same immutable image. No model output,
/// OCR guesses, raw error messages, or inferred identities are accepted as evidence.
public struct SourceBarcodeDiagnostics: Codable, Equatable, Sendable {
    public enum Pass: String, Codable, Sendable { case general, targetedEAN }
    public struct Observation: Codable, Equatable, Hashable, Sendable {
        public enum Decision: String, Codable, Sendable {
            case acceptedProduct, unsupportedSymbology, invalidProductCode, emptyPayload
        }
        public let value: String?
        public let symbology: String
        public let pass: Pass
        public let decision: Decision
        public init(value: String?, symbology: String, pass: Pass) {
            self.value = value; self.symbology = symbology; self.pass = pass
            if value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { decision = .emptyPayload }
            else if !["ean8", "ean13"].contains(symbology) { decision = .unsupportedSymbology }
            else if let value, let kind = ProductBarcode.Symbology(rawValue: symbology),
                    ProductBarcode(value: value, symbology: kind) != nil { decision = .acceptedProduct }
            else { decision = .invalidProductCode }
        }
        public var product: ProductBarcode? {
            guard decision == .acceptedProduct, let value, ["ean8", "ean13"].contains(symbology),
                  let kind = ProductBarcode.Symbology(rawValue: symbology) else { return nil }
            return ProductBarcode(value: value, symbology: kind)
        }
    }
    public struct Attempt: Codable, Equatable, Sendable {
        public let pass: Pass
        public let orientation: UInt32
        public let revision: Int
        /// nil means decoder failure; zero is a successful scan with no observations.
        public let observationCount: Int?
        public init(pass: Pass, orientation: UInt32, revision: Int, observationCount: Int?) {
            self.pass = pass; self.orientation = orientation; self.revision = revision; self.observationCount = observationCount
        }
    }
    public let version: Int
    public let observations: [Observation]
    public let attempts: [Attempt]
    public init(observations: [Observation], attempts: [Attempt]) {
        self.version = 1; self.observations = observations; self.attempts = attempts
    }
}

/// A narrowly extracted field from locally decoded, same-image barcode text.
/// It is evidence to compare with the image, never an instruction or verified identity.
/// Do not initialize this from model-generated barcodes or OCR / another card.
public struct BarcodeProductNameEvidence: Equatable, Sendable {
    public let name: String
    public enum Assessment: Equatable, Sendable { case absent, name(String), conflicting, rejected }
    public init?(decodedValues: [String]) {
        guard case .name(let name) = Self.assess(decodedValues: decodedValues) else { return nil }
        self.name = name
    }
    public static func assess(decodedValues: [String]) -> Assessment {
        guard decodedValues.count <= 32, decodedValues.allSatisfy({ $0.utf8.count <= 4096 }) else { return .rejected }
        var candidates = Set<String>()
        for payload in decodedValues {
            for line in payload.components(separatedBy: .newlines) {
                guard let separator = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { continue }
                let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
                guard ["品名", "產品名稱", "商品名稱", "product name"].contains(key) else { continue }
                let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                // Reject the entire candidate set on malformed explicit fields: do not
                // truncate an instruction / private value into a plausible product name.
                guard ProductNameSafety.accepts(value) else { return .rejected }
                candidates.insert(value)
            }
        }
        guard candidates.count <= 1 else { return .conflicting }
        return candidates.first.map(Assessment.name) ?? .absent
    }
}

/// Legacy Build 7 metadata, retained only to read saved cards without deleting data.
public struct ProductFacts: Codable, Equatable, Sendable {
    public enum Provider: String, Codable, CaseIterable, Sendable {
        case food, beauty, petfood, product
        public var host: String {
            switch self {
            case .food: "world.openfoodfacts.org"
            case .beauty: "world.openbeautyfacts.org"
            case .petfood: "world.openpetfoodfacts.org"
            case .product: "world.openproductsfacts.org"
            }
        }
        public var name: String {
            switch self {
            case .food: "Open Food Facts"
            case .beauty: "Open Beauty Facts"
            case .petfood: "Open Pet Food Facts"
            case .product: "Open Products Facts"
            }
        }
    }
    public struct Field: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case name, brand, quantity, ingredients, nutrition100g, nutrition100ml
            public var label: String {
                switch self {
                case .name: "品名"
                case .brand: "品牌"
                case .quantity: "容量／重量"
                case .ingredients: "成分"
                case .nutrition100g: "營養（每 100 g，未調製）"
                case .nutrition100ml: "營養（每 100 ml，未調製）"
                }
            }
        }
        public let kind: Kind
        public let value: String
    }
    public let code: String
    public let provider: Provider
    public let fields: [Field]
    public let checkedAt: Date
    public static let databaseLicense = URL(string: "https://opendatacommons.org/licenses/odbl/1-0/")!
    public static let contentsLicense = URL(string: "https://opendatacommons.org/licenses/dbcl/1-0/")!
    // Only a validated found product's returned code and allowlisted serving domain
    // form this documented OFF page route. Never a model-supplied manufacturer URL.
    public var sourceURL: URL { URL(string: "https://\(provider.host)/product/\(code)")! }
    public var title: String { fields.first { $0.kind == .name }?.value ?? code }
    public func isValid(for products: [ProductBarcode]) -> Bool {
        ProductBarcode.normalized(code) == code && products.contains { $0.code == code } &&
        checkedAt.timeIntervalSince1970.isFinite && !fields.isEmpty && fields.count <= 6 &&
        Set(fields.map(\.kind)).count == fields.count &&
        fields.allSatisfy { Self.text($0.value, maximum: $0.kind == .ingredients ? 2_000 : 600) == $0.value }
    }
    static func text(_ value: Any?, maximum: Int = 600) -> String? {
        guard let raw = value as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= maximum, !value.contains("<"), !value.contains(">"),
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\r" || $0 == "\t" }),
              !value.unicodeScalars.contains(where: { (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }) else { return nil }
        return value
    }
}

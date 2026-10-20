import Foundation

/// A short public-subject query from the same recognition response. Never OCR fallback.
public struct PublicSearchQuery: Codable, Equatable, Hashable, Sendable {
    public enum Category: String, Codable, Sendable { case product, species, object }
    public let query: String
    public let category: Category
    /// Explicit same-response privacy assessment for automatic third-party lookup.
    /// Old answers / missing or malformed flags remain manual-Google-only.
    public let automaticWikipediaAllowed: Bool

    public init?(query: String, category: String, automaticWikipediaAllowed: Bool = false) {
        guard let category = Category(rawValue: category),
              query.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...120).contains(value.count), value.utf8.count <= 360,
              value.split(whereSeparator: \.isWhitespace).count <= 12,
              !ProductNameSafety.containsAddress(value),
              value.range(of: #"(?i)@|://|\bwww\.|\b(password|passwd|token|secret|ssn)\b|密碼|身分證|身份證|病歷|住址|信用卡"#, options: .regularExpression) == nil,
              value.range(of: #"\+?\d[\d ()-]{7,}\d"#, options: .regularExpression) == nil else { return nil }
        self.query = value; self.category = category
        self.automaticWikipediaAllowed = automaticWikipediaAllowed
    }
    private enum CodingKeys: String, CodingKey {
        case query, category
        case automaticWikipediaAllowed = "automatic_wikipedia"
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let query = try container.decode(String.self, forKey: .query)
        let category = try container.decode(String.self, forKey: .category)
        let automatic = (try? container.decode(Bool.self, forKey: .automaticWikipediaAllowed)) ?? false
        guard let safe = Self(query: query, category: category, automaticWikipediaAllowed: automatic) else {
            throw DecodingError.dataCorruptedError(forKey: .query, in: container, debugDescription: "Invalid public search query")
        }
        self = safe
    }
    public var googleURL: URL? {
        googleSearchURL(query)
    }
}

/// Manual Google search derived from one saved card. Model/OCR digits never enter here.
/// The original public query remains unchanged for Wikipedia and archive compatibility.
public struct GoogleSearchQuery: Equatable, Sendable {
    public let query: String
    private init(query: String) { self.query = query }
    public static func reviewedName(_ value: String) -> Self? {
        CandidateQuerySafety.accepts(value, limit: 160, minimum: 1) ? Self(query: value) : nil
    }
    /// One pure resolver for screen and share, including old saved cards. No network or writes.
    public static func resolve(result: RecognitionResult?, decodedBarcodes: [String], productBarcodes: [ProductBarcode]) -> Self? {
        if let result, result.usesEntitySearch {
            guard let query = SearchEntity.googleTerms(for: result) else { return nil }
            let central = SearchEntity.matching(result).first { $0.role == .central }
            let codes = Set(productBarcodes.map(\.code))
            let product = central?.kind == .product && codes.count == 1 ? productBarcodes.first : nil
            return Self(query: product.map { query + " " + $0.value } ?? query)
        }
        if let result, result.searchContractVersion != nil {
            let candidates = SearchCandidate.matching(result)
            guard let candidate = candidates.first(where: { $0.role == .central }) ?? candidates.first else { return nil }
            // No legacy OCR/QR/GTIN fallback when v13 has no accepted candidate.
            // The candidate is already a complete necessary name, never a private value.
            let codes = Set(productBarcodes.map(\.code))
            let product = candidate.kind == .product && codes.count == 1 ? productBarcodes.first : nil
            let value = product.map { candidate.query + " " + $0.value } ?? candidate.query
            return Self(query: value)
        }
        guard result?.searchRestriction?.blocksAllSearch != true else { return nil }
        if let result, result.searchIdentity != nil {
            let context = result.names + [result.summary] + result.text + decodedBarcodes
            guard context.count <= 100, context.reduce(0, { $0 + $1.utf8.count }) <= 32_768,
                  !context.contains(where: SearchIdentity.containsPrivateContext) else { return nil }
        }
        // A structured card may keep independently supported phrases. Resolve old
        // and new cards from the same checked identity without rewriting the archive.
        // All source-unmatched phrases may use a complete validated identity;
        // rejected phrases themselves and arbitrary OCR never become a query.
        if let identity = result?.searchIdentity {
            let normalized = identity.normalizedForSearch()
            guard normalized.validForIdentity, normalized.wikipediaPolicy != .conflict,
                  normalized.wikipediaPolicy != .uncertain else { return nil }
            if !normalized.googleKeywords.isEmpty {
                guard result?.names.isEmpty == false, let base = normalized.googleQuery else { return nil }
                return Self(base: base, productBarcodes: productBarcodes)
            }
        }
        if let base = result?.searchQuery { return Self(base: base, productBarcodes: productBarcodes) }
        // A rejected search value is not an ordinary missing value. Keep only the
        // pre-existing independently validated GTIN route, never recover its text.
        if result?.searchRestriction != nil { return Self(base: nil, productBarcodes: productBarcodes) }
        switch ProductSearchFallback.resolve(result: result, decodedBarcodes: decodedBarcodes) {
        case .blocked: return nil
        case .unavailable: return Self(base: nil, productBarcodes: productBarcodes)
        case .query(let query): return Self(base: query, productBarcodes: productBarcodes)
        }
    }
    public init?(base: PublicSearchQuery?, productBarcodes: [ProductBarcode]) {
        let codes = Set(productBarcodes.map(\.code))
        let barcode = codes.count == 1 ? productBarcodes.first : nil
        var text = base?.query ?? ""
        if let barcode {
            // Keep the original decoded representation, including leading zeros.
            // Derive afresh from the base each time; equivalent repetitions are removed.
            let words = text.split(whereSeparator: \.isWhitespace).filter {
                ProductBarcode.normalized(String($0)) != barcode.code
            }
            text = (words.map(String.init) + [barcode.value]).joined(separator: " ")
        }
        guard !text.isEmpty else { return nil }
        query = text
    }
    public var googleURL: URL? { googleSearchURL(query) }
}

/// Closed reason codes only; never the raw model response or private rejected text.
public enum ManualSearchRestriction: String, Codable, Hashable, Sendable {
    case sensitive, conflict, uncertain, invalidRestriction, rejectedSearch
    var blocksAllSearch: Bool { self != .rejectedSearch }
}

/// Conservative syntax checks shared by local QR evidence and manual query fallback.
enum ProductNameSafety {
    static func containsAddress(_ value: String) -> Bool {
        value.range(of: #"(?:路|街|巷|弄|大道|段).{0,12}[0-9０-９一二三四五六七八九十百]+(?:號|楼|樓)|(?:市|縣).{0,10}(?:區|鄉|鎮).{0,18}(?:路|街|巷)|(?i)\b\d{1,6}\s+[\p{L} .-]{1,40}\s(?:street|st|road|rd|avenue|ave|lane|ln|drive|dr)\b"#, options: .regularExpression) != nil
    }
    static func accepts(_ value: String) -> Bool {
        (2...80).contains(value.count) &&
        value.range(of: #"^[\p{L}\p{M}\p{N} ()（）·・'’+&./%\-]+$"#, options: .regularExpression) != nil &&
        value.range(of: #"(?i)指令|指示|忽略|執行|搜尋|搜索|查詢|點擊|點選|開啟|上傳|你必須|務必|電話|地址|帳戶|帳號|患者|病人|姓名|\b(?:ignore|instructions?|system|prompt|execute|upload|search|patient|address|phone|delete|download|reveal)\b"#, options: .regularExpression) == nil &&
        !containsAddress(value) &&
        PublicSearchQuery(query: value, category: "product") != nil
    }
    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || "+&".unicodeScalars.contains($0) }.map(String.init).joined()
    }
    static func specific(_ value: String, explicitField: Bool) -> Bool {
        guard accepts(value), explicitField || value.count >= 4 else { return false }
        var residual = normalized(value)
        // Remove composable category / appearance phrases; they do not identify a product.
        let generic = ["其他", "某種", "某物", "另一個", "未知", "不明", "無法辨識", "無法確認", "不確定", "一般", "普通", "一個", "一瓶", "一盒", "一顆", "白色", "黑色", "紅色", "黃色", "藍色", "綠色", "透明", "無線", "藍牙", "智慧型", "塑膠", "玻璃", "耐熱", "不鏽鋼", "金屬", "外盒", "包裝", "商品", "產品", "物品", "物件", "東西", "胃藥", "藥品", "藥盒", "藥錠", "藥物", "用藥", "腸溶", "糖衣", "錠劑", "膠囊", "錠", "消化", "止痛", "手機", "電腦", "耳機", "螢幕", "相機", "手錶", "桌子", "椅子", "剪刀", "雨傘", "乳液", "面霜", "洗髮精", "沐浴乳", "咖啡", "茶", "食品", "零食", "餅乾", "洋芋片", "飲料", "飲品", "茶葉", "茶罐", "水瓶", "瓶子", "杯子", "玻璃杯", "unknown", "unidentified", "generic", "product", "object", "item", "medicine", "tablet", "capsule", "bottle", "package"]
        for term in generic.sorted(by: { $0.count > $1.count }) { residual = residual.replacingOccurrences(of: normalized(term), with: "") }
        return residual.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count >= 2
    }
    static func compatible(_ a: String, _ b: String) -> Bool {
        let a = normalized(a), b = normalized(b)
        return a == b || a.hasPrefix(b) || b.hasPrefix(a)
    }
}

private enum ProductSearchFallback {
    enum Decision { case query(PublicSearchQuery), unavailable, blocked }
    static func resolve(result: RecognitionResult?, decodedBarcodes: [String]) -> Decision {
        let names = result?.names ?? [], text = result?.text ?? []
        let contextParts = names + [result?.summary ?? ""] + text + decodedBarcodes
        guard contextParts.count <= 100, contextParts.reduce(0, { $0 + $1.utf8.count }) <= 32768 else { return .blocked }
        let context = contextParts.joined(separator: "\n")
        // Public package contact details are allowed to remain in OCR/QR, but never
        // in the query. Private-document markers and explicit identity conflicts stop fallback.
        let sensitive = #"(?i)病歷|(?:病人|患者)(?:姓名|編號|資料|ID)|(?:病人|患者)\s*[:：]|處方箋|處方籤|用藥紀錄|醫療紀錄|診療紀錄|收件人|寄件人|私人|私密|個人帳戶|個人帳號|身分證|身份證|信用卡|(?:姓名|住址|帳號)\s*[:：]|medical\s+(?:record|history)|patient\s*(?:name|id|record|[:：])|private\s+(?:document|message)|recipient"#
        let conflict = #"(?i)(?:品名|名稱|身分|身份|商品|條碼|QR).{0,16}(?:不符|衝突|矛盾|不一致|不相符|無法確認|不確定)|(?:無法確認|不確定).{0,12}(?:品名|名稱|身分|身份)|不是同一商品|辨識不確定|無法(?:可靠)?辨識主體|(?:name|identity|barcode|product).{0,16}(?:conflict|mismatch|uncertain)"#
        guard context.range(of: sensitive, options: .regularExpression) == nil,
              (names + [result?.summary ?? ""]).joined(separator: "\n").range(of: conflict, options: .regularExpression) == nil else { return .blocked }
        let qr = BarcodeProductNameEvidence.assess(decodedValues: decodedBarcodes)
        let visibleField = BarcodeProductNameEvidence.assess(decodedValues: text)
        if qr == .conflicting || qr == .rejected || visibleField == .conflicting || visibleField == .rejected { return .blocked }
        // Invalid name strings are not shortened into a safer-looking query.
        guard names.allSatisfy({ $0.count < 2 || ProductNameSafety.accepts($0) }) else { return .blocked }
        let specificNames = names.filter { ProductNameSafety.specific($0, explicitField: false) }
        var candidates = specificNames
        if case .name(let name) = qr, ProductNameSafety.specific(name, explicitField: true) { candidates.append(name) }
        guard !candidates.isEmpty else { return .unavailable }
        let anchor = candidates[0]
        var compared = candidates
        if case .name(let visible) = visibleField { compared.append(visible) }
        // A short common prefix must not conceal conflicts between two longer variants.
        guard compared.allSatisfy({ a in compared.allSatisfy({ ProductNameSafety.compatible(a, $0) }) }) else { return .blocked }
        // Prefer the explicit recognition name; QR supplies a name only when the result is generic/absent.
        guard let query = PublicSearchQuery(query: anchor, category: "product") else { return .blocked }
        return .query(query)
    }
}

private func googleSearchURL(_ query: String) -> URL? {
    var components = URLComponents()
    components.scheme = "https"; components.host = "www.google.com"; components.path = "/search"
    components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "gl", value: "tw"), URLQueryItem(name: "lr", value: "lang_zh-TW")]
    // Preserve literal plus signs in Google's form query.
    components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    return components.url
}

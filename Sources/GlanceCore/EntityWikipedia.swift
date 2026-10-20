import Foundation

public struct WikipediaDiagnostic: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable { case admission, cache, transport, identity, relationship, selection, persistence }
    public enum Outcome: String, Codable, Sendable {
        case noCandidates, started, busy, throttled, cacheHit, negativeHit, expired, http, timeout, cancelled, invalidEnvelope
        case unsafePage, aliasMissing, entityMismatch, personEvidence, relationUnproven, ambiguous, verified, selected, noMatch, budget
        case saved, saveFailed, consentRevoked, background, staleAttempt, deleted
    }
    public let stage: Stage
    public let outcome: Outcome
    public let at: Date
    public var entityID: Int? = nil
    public var pageID: Int? = nil
    public var requestNumber: Int? = nil
    public var httpStatus: Int? = nil
    public var milliseconds: Int? = nil
    public init(_ stage: Stage, _ outcome: Outcome, at: Date = Date(), entityID: Int? = nil, pageID: Int? = nil,
                requestNumber: Int? = nil, httpStatus: Int? = nil, milliseconds: Int? = nil) {
        self.stage = stage; self.outcome = outcome; self.at = at; self.entityID = entityID; self.pageID = pageID
        self.requestNumber = requestNumber; self.httpStatus = httpStatus; self.milliseconds = milliseconds
    }
}

/// Only bounded, public article evidence is retained; never a whole response or image transcription.
public struct EntityWikipediaPage: Codable, Equatable, Sendable {
    public struct Fact: Codable, Equatable, Sendable { public let field: String; public let value: String }
    public let id: Int
    public let title: String
    public let url: URL
    public let lead: String
    public let redirects: [String]
    public let categories: [String]
    public let officialNames: [String]
    public let facts: [Fact]
    public let passages: [String]
    public let manufacturedEntries: [String]
    public let supplemented: Bool
    enum ArticleKind: String { case product, series, brand, company, species, person, object, unknown }
    static func normalized(_ value: String) -> String { WikipediaSubject.normalize(value) }
    /// Unicode word boundaries prevent KIRIN matching unrelated Kirinwood; CJK keeps exact phrases.
    static func contains(_ value: String, _ needle: String) -> Bool {
        let a = normalized(value), b = normalized(needle)
        guard !b.isEmpty else { return false }
        let ascii = b.unicodeScalars.allSatisfy { $0.isASCII }
        if ascii {
            return a.range(of: #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: b) + #"(?![\p{L}\p{N}])"#, options: .regularExpression) != nil
        }
        return a.contains(b)
    }
    static func positive(_ value: String) -> Bool {
        value.range(of: #"並非|并非|不是|不屬於|不属于|而非|無關|无关|未曾|沒有|没有|(?i)\b(?:not|never|unrelated|unconfirmed)\b"#, options: .regularExpression) == nil
    }
    var identities: [String] { [title] + redirects + officialNames }
    /// Original product phrases are evidence, not extra network search terms or
    /// invented aliases. The current contract already anchors each supplied span.
    static func productEvidenceTerms(_ product: SearchEntity, version: Int?) -> [String] {
        var terms = product.names
        if [15, 16].contains(version ?? -1), [.product, .series].contains(product.kind),
           product.role == .central, product.basis == .text, product.sourceRole == .product_label {
            terms += [product.sourceText] + product.contextText
        }
        let generic = Set(["原味", "經典", "經典原味", "全新口味", "無糖", "啤酒", "食品", "飲料", "original", "classic", "new", "sugar free", "beer", "product"])
        var seen = Set<String>()
        return terms.enumerated().compactMap { index, raw in
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"[®™]+$"#, with: "", options: .regularExpression)
            let key = normalized(term)
            guard ((index < product.names.count ? 1 : 3)...120).contains(term.count), !generic.contains(key),
                  term.range(of: #"[\p{L}]"#, options: .regularExpression) != nil,
                  seen.insert(key).inserted else { return nil }
            return term
        }
    }
    static func isProductHeading(_ text: String) -> Bool {
        (2...120).contains(text.count) && !text.hasPrefix("=") && positive(text) &&
        text.range(of: #"[。！？；;：:]|公司|企業|創業|成立|釀造|酿造|醸造|製造|制造|生產|生产|(?i)\b(?:is|was|were|company|manufactur\w*|produc\w*|brewed)\b"#, options: .regularExpression) == nil
    }
    var kind: ArticleKind {
        let withoutAliases = lead.replacingOccurrences(of: #"[（(][^（）()]*[）)]"#, with: "", options: .regularExpression)
        let firstSentence = withoutAliases.components(separatedBy: CharacterSet(charactersIn: "。！？\n")).first ?? ""
        guard let range = firstSentence.range(of: #"(?:是|為|为|(?i)\b(?:is|was|are)\b)[^。！？\n，；]{2,150}"#, options: .regularExpression) else { return .unknown }
        let definition = String(firstSentence[range])
        guard Self.positive(definition) else { return .unknown }
        return classifyDefinition(definition)
    }
    /// Preserve legacy saved-card interpretation. v15 reads the article's own
    /// definition, excluding nested alias annotations and unrelated later clauses.
    func kind(for contractVersion: Int?) -> ArticleKind {
        guard [15, 16].contains(contractVersion ?? -1) else { return kind }
        guard let clean = Self.removingParentheticalAnnotations(lead, stopAfterFirstSentence: true) else { return .unknown }
        let sentence = clean.components(separatedBy: CharacterSet(charactersIn: "。！？\n")).first ?? ""
        guard let range = sentence.range(of: #"(?<!稱)(?<!称)(?<!作)(?<!成)(?:是|為|为|(?i)\b(?:is|was|are)\b)[^。！？\n，,；;]{2,150}"#, options: .regularExpression) else { return .unknown }
        let definition = String(sentence[range])
        let previous = sentence[..<range.lowerBound].last
        guard previous != "不", previous != "非", previous != "未", Self.positive(definition) else { return .unknown }
        var definitions = [definition]
        // “is a series name, and is also a brand” describes one subject. A new
        // named subject after the comma is not evidence about this article.
        let tail = String(sentence[range.upperBound...]).components(separatedBy: CharacterSet(charactersIn: "，,；;"))
        for part in tail.dropFirst() {
            let clause = part.trimmingCharacters(in: .whitespaces)
            guard clause.range(of: #"^(?:也|亦|同時|同时)(?:也|亦)?(?:是|為|为)[^。！？\n]{2,150}$"#, options: .regularExpression) != nil else { break }
            guard Self.positive(clause) else { return .unknown }
            definitions.append(clause)
        }
        return classifyDefinition(definitions.joined(separator: "；"))
    }
    static func removingParentheticalAnnotations(_ text: String, stopAfterFirstSentence: Bool = false) -> String? {
        var closing: [Character] = [], output = ""
        for character in text {
            if character == "（" || character == "(" { closing.append(character == "（" ? "）" : ")") }
            else if character == "）" || character == ")" {
                guard closing.last == character else { return nil }; closing.removeLast()
            } else if closing.isEmpty {
                output.append(character)
                if stopAfterFirstSentence && "。！？\n".contains(character) { return output }
            }
        }
        return closing.isEmpty ? output : nil
    }
    private func classifyDefinition(_ definition: String) -> ArticleKind {
        if WikipediaSubject.rejectsPerson(lead, categories: categories) { return .person }
        let normalized = Self.normalized(definition)
        func has(_ p: String) -> Bool { normalized.range(of: p, options: .regularExpression) != nil }
        if has(#"品牌|商標|\bbrand\b|trademark"#) { return .brand }
        if has(#"系列|\bseries\b|product line"#) { return .series }
        if has(#"公司|企業|企業體|製造商|生產商|釀造商|\bcompany\b|corporation|brewery|manufacturer"#) { return .company }
        if has(#"作家|演員|歌手|學者|政治人物|科學家|詩人|生於|born|\bauthor\b|\bwriter\b"#) { return .person }
        if has(#"物種|植物|動物|屬於.{0,20}科|\bspecies\b"#) { return .species }
        if has(#"產品|商品|啤酒|飲料|食品|型號|機型|藥品|\bproduct\b|\bbeer\b|\bmodel\b"#) { return .product }
        return .object
    }
    /// A brand reference does not claim an exact flavor/model article. A quoted
    /// product name in this brand's own explicit product list can bind a longer
    /// image-derived product name, without inventing an alias or a manufacturer.
    func listedProductRelationship(to product: SearchEntity, brand: SearchEntity, in result: RecognitionResult) -> String? {
        guard [.product, .series].contains(product.kind), product.basis == .text,
              product.sourceRole == .product_label else { return nil }
        let generic = ["原味", "經典", "經典原味", "全新口味", "無糖", "original", "classic", "new", "sugar free"]
        func eligible(_ anchor: String) -> Bool {
            (3...120).contains(anchor.count) &&
            product.names.contains(where: { Self.contains($0, anchor) }) &&
            !brand.names.contains(where: { Self.normalized($0) == Self.normalized(anchor) }) &&
            !generic.map(Self.normalized).contains(Self.normalized(anchor)) &&
            anchor.range(of: #"[\p{L}]"#, options: .regularExpression) != nil
        }
        let sentences = lead.components(separatedBy: CharacterSet(charactersIn: "。！？\n")) + passages
        let ownLists = sentences.filter { sentence in
            let value = sentence.trimmingCharacters(in: .whitespaces)
            return (12...600).contains(value.count) && Self.positive(value) &&
                value.range(of: #"其他|其它|競爭|竞争|競品|對手|对手|別家|代理|進口|进口|授權|授权|聯名|联名|代工|不(?:包括|包含|再)|未(?:包括|包含|推出)|停止"#, options: .regularExpression) == nil &&
                value.range(of: #"^(?:(?:本|該|此)(?:品牌|系列)(?:的)?(?:現有|目前|主要|旗下)?|現有|目前|主要|旗下)(?:的|有)?(?:[一二三四五六七八九十百千數多幾0-9]+(?:種|項|款|個|类|類))?(?:商品|產品|产品)(?:包括|包含|有|為|为)?[：:]"#, options: .regularExpression) != nil
        }
        func proof(_ anchor: String) -> String? {
            guard eligible(anchor) else { return nil }
            let quoted = [("「", "」"), ("『", "』"), ("“", "”"), ("\"", "\"")].map { $0.0 + anchor + $0.1 }
            return ownLists.first { sentence in quoted.contains { Self.contains(sentence, $0) } }
                .map { title + "／同頁商品名／" + $0.trimmingCharacters(in: .whitespaces) }
        }
        // Keep the Build40 whole-source proof and legacy saved-card behavior.
        if let direct = proof(product.sourceText) { return direct }
        guard result.searchContractVersion == EntityContract16.version else { return nil }
        // v16 may quote brand + product + flavor as one source. An already
        // anchored context phrase can identify the product within that span;
        // it must also occur in the central name and this brand's own list.
        var matches: [String: String] = [:]
        for anchor in product.contextText where Self.contains(product.sourceText, anchor) &&
            EntityValidation15.anchor(anchor, in: [product.sourceText]).matched &&
            EntityValidation15.anchor(anchor, in: result.text, allowHanLineJoins: true).matched {
            if let relationship = proof(anchor) { matches[Self.normalized(anchor)] = relationship }
        }
        // Two independently listed product names cannot silently choose one.
        return matches.count == 1 ? matches.values.first : nil
    }
    var valid: Bool { valid(for: nil) }
    func valid(for contractVersion: Int?) -> Bool {
        let minimum = contractVersion == 16 ? 1 : 2
        return id > 0 && CandidateQuerySafety.accepts(title, limit: 120, minimum: minimum) && WikipediaReference.allowedURL(url) &&
        (12...2000).contains(lead.count) && !lead.contains("<") && !lead.contains(">") &&
        !["可能指", "可以指", "消歧義", "消歧义"].contains(where: String(lead.prefix(180)).contains) &&
        redirects.count <= 50 && categories.count <= 40 && categories.allSatisfy({ $0.count <= 160 }) && officialNames.count <= 16 && facts.count <= 16 && passages.count <= 4 && manufacturedEntries.count <= 2 &&
        manufacturedEntries.allSatisfy({ (12...650).contains($0.count) && !$0.contains("<") && !$0.contains(">") }) &&
        (redirects + officialNames).allSatisfy({ CandidateQuerySafety.accepts($0, limit: 120, minimum: minimum) }) &&
        facts.allSatisfy({ Self.factFields.contains($0.field) && !$0.value.isEmpty && $0.value.count <= 300 }) &&
        passages.allSatisfy({ !$0.isEmpty && $0.count <= 600 && !$0.contains("<") && !$0.contains(">") })
    }
    static let nameFields: Set<String> = ["name", "native_name", "other_name", "other_names", "english_name", "company_name", "company_name_en", "company_name_native", "abbreviation", "trading_name", "名稱", "中文名稱", "英文名稱", "原名", "簡稱"]
    static let factFields = nameFields.union(["manufacturer", "製造商", "製造者", "生產商", "生产商", "brand", "品牌", "products", "產品", "產品列表", "type", "類型"])
    static func cleanWiki(_ value: String) -> String {
        var s = value.replacingOccurrences(of: #"<ref\b[^>]*>.*?</ref>|<ref[^>]*/>"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"\[\[(?:[^\]|]+\|)?([^\]]+)\]\]"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<br\s*/?>"#, with: "、", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "'''", with: "").replacingOccurrences(of: "''", with: "")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func parse(_ row: [String: Any], supplement: Bool = false, entities: [SearchEntity], contractVersion: Int? = nil) -> Self? {
        guard row["ns"] as? Int == 0, row["missing"] == nil,
              (row["pageprops"] as? [String: Any])?["disambiguation"] == nil,
              row["invalid"] == nil, let id = row["pageid"] as? Int, let title = row["title"] as? String,
              let rawURL = row["canonicalurl"] as? String ?? row["fullurl"] as? String, let url = URL(string: rawURL),
              let extract = row["extract"] as? String else { return nil }
        let minimum = contractVersion == 16 ? 1 : 2
        let lead = String(extract.prefix(1800))
        let redirects = (row["redirects"] as? [[String: Any]] ?? []).filter { $0["fragment"] == nil }.compactMap { $0["title"] as? String }
        let categories = (row["categories"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
        var names: [String] = [], facts: [Fact] = []
        if supplement, let revisions = row["revisions"] as? [[String: Any]], revisions.count == 1,
           let slots = revisions[0]["slots"] as? [String: Any], let main = slots["main"] as? [String: Any],
           let content = main["content"] as? String, content.utf8.count <= 128_000 {
            // Read literal allowlisted fields, never expand templates, execute markup or follow URLs.
            for line in content.prefix(24000).components(separatedBy: .newlines) where facts.count < 16 {
                guard line.trimmingCharacters(in: .whitespaces).hasPrefix("|"), let eq = line.firstIndex(of: "=") else { continue }
                let field = line[..<eq].trimmingCharacters(in: CharacterSet(charactersIn: "| \t")).lowercased()
                let value = cleanWiki(String(line[line.index(after: eq)...]))
                guard factFields.contains(field), !value.isEmpty, value.count <= 300,
                      !value.contains("{{"), !value.contains("<"), !value.contains("http") else { continue }
                facts.append(.init(field: field, value: value))
                if nameFields.contains(field), CandidateQuerySafety.accepts(value, limit: 120, minimum: minimum) { names.append(value) }
            }
            let pattern = #"'''([^'\n]{2,120})'''"#
            if let re = try? NSRegularExpression(pattern: pattern) {
                let text = String(content.prefix(24000))
                for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).prefix(16) {
                    if let range = Range(m.range(at: 1), in: text) {
                        let value = cleanWiki(String(text[range]))
                        // Bold in the lead is a name only when it also occurs in its definition.
                        if contains(String(lead.prefix(500)), value), CandidateQuerySafety.accepts(value, limit: 120, minimum: minimum) { names.append(value) }
                    }
                }
            }
        }
        // Explicit parenthetical official names in the definition can establish cross-language identity.
        if let re = try? NSRegularExpression(pattern: #"[（(]([^（）()\n]{2,120})[）)]"#) {
            let text = String(lead.prefix(400))
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).prefix(8) {
                guard let range = Range(m.range(at: 1), in: text) else { continue }
                guard let whole = Range(m.range, in: text) else { continue }
                let before = String(text[..<whole.lowerBound]).trimmingCharacters(in: .whitespaces)
                guard ([title] + names).contains(where: { before.hasSuffix($0) }) else { continue }
                let parts = String(text[range]).components(separatedBy: CharacterSet(charactersIn: "，、；;"))
                for part in parts {
                    let label = #"^(?:英文|英語|英语|日文|日語|日语|原名|正式名稱|official name)[:：]\s*"#
                    guard part.range(of: label, options: [.regularExpression, .caseInsensitive]) != nil else { continue }
                    let cleaned = part.replacingOccurrences(of: label, with: "", options: [.regularExpression, .caseInsensitive])
                    if CandidateQuerySafety.accepts(cleaned, limit: 120) { names.append(cleaned) }
                }
            }
        }
        var seen = Set<String>()
        names = names.filter { seen.insert(normalized($0)).inserted }
        let needles = entities.flatMap { $0.names + ($0.sourceText.isEmpty ? [] : [$0.sourceText]) + Self.productEvidenceTerms($0, version: contractVersion) }
        // Relevant passages are chosen below; keep whole sentences, never combine unrelated clauses.
        let relevant = supplement ? String(extract.prefix(6000)).components(separatedBy: CharacterSet(charactersIn: "。！？\n"))
            .filter { sentence in (12...600).contains(sentence.count) && needles.contains { contains(sentence, $0) } } : []
        // A current-product section on a manufacturing article may establish a relationship
        // across its product heading and immediately following production paragraph.
        // Import/licensing/agency sections cannot become evidence of manufacture.
        var entries: [String] = [], productSection = false, excludedSection = false
        if supplement {
            let lines = String(extract.prefix(6000)).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("== ") {
                    productSection = trimmed.range(of: #"^== (?:現行商品|主要產品|產品|商品|Products|Current products) ==$"#, options: [.regularExpression, .caseInsensitive]) != nil
                    excludedSection = false
                } else if trimmed.hasPrefix("===") {
                    excludedSection = trimmed.range(of: #"外國|外来|進口|进口|授權|授权|代理|其他公司|foreign|import|licens|distribut"#, options: [.regularExpression, .caseInsensitive]) != nil
                }
                guard productSection, !excludedSection, entries.count < 2, Self.isProductHeading(trimmed),
                      needles.contains(where: { contains(trimmed, $0) }), index + 1 < lines.count else { continue }
                let paragraph = lines[index + 1]
                guard (12...500).contains(paragraph.count), positive(paragraph),
                      paragraph.range(of: #"生產|生产|製造|制造|釀造|酿造|醸造|manufactur|produc|brew"#, options: [.regularExpression, .caseInsensitive]) != nil,
                      (trimmed + paragraph).range(of: #"進口|进口|代理|授權|授权|委託|委托|代工|其他公司|其它公司|別家|競爭|竞争|import|licens|contract|competitor"#, options: [.regularExpression, .caseInsensitive]) == nil else { continue }
                entries.append(trimmed + "\n" + paragraph)
            }
        }
        let page = Self(id: id, title: title, url: url, lead: lead, redirects: redirects, categories: categories, officialNames: Array(names.prefix(16)),
                        facts: facts, passages: Array(relevant.prefix(4)), manufacturedEntries: entries, supplemented: supplement)
        return page.valid(for: contractVersion) ? page : nil
    }
    static func searchRequest(_ name: String) -> URLRequest {
        request([.init(name: "generator", value: "search"), .init(name: "gsrsearch", value: name), .init(name: "gsrnamespace", value: "0"),
                 .init(name: "gsrlimit", value: "5"), .init(name: "exintro", value: "1"), .init(name: "exchars", value: "1200"), .init(name: "exlimit", value: "5")])
    }
    func supplementalRequest() -> URLRequest {
        Self.request([.init(name: "pageids", value: String(id)), .init(name: "prop", value: "info|extracts|pageprops|redirects|categories|revisions"),
                      .init(name: "rvprop", value: "content"), .init(name: "rvslots", value: "main"), .init(name: "rvsection", value: "0"),
                      .init(name: "exlimit", value: "1")])
    }
    private static func request(_ extra: [URLQueryItem]) -> URLRequest {
        var c = URLComponents(string: "https://zh.wikipedia.org/w/api.php")!
        let base: [URLQueryItem] = [.init(name: "action", value: "query"), .init(name: "format", value: "json"), .init(name: "formatversion", value: "2"),
            .init(name: "prop", value: "info|extracts|pageprops|redirects|categories"), .init(name: "inprop", value: "url"), .init(name: "ppprop", value: "disambiguation"),
            .init(name: "rdprop", value: "title|fragment"), .init(name: "rdnamespace", value: "0"), .init(name: "rdlimit", value: "50"),
            .init(name: "cllimit", value: "40"), .init(name: "clshow", value: "!hidden"),
            .init(name: "rdshow", value: "!fragment"), .init(name: "explaintext", value: "1"), .init(name: "variant", value: "zh-tw"), .init(name: "maxlag", value: "5")]
        c.queryItems = base.filter { item in !extra.contains { $0.name == item.name } } + extra
        var r = URLRequest(url: c.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        r.setValue("Glance/0.1.0 (https://github.com/peiyu66/Glance)", forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept"); return r
    }
}

public struct EntityWikipediaEvidence: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case exact, brand, series, manufacturer, company }
    public let entityID: Int
    public let role: Role
    public let matchedName: String
    public let page: EntityWikipediaPage
    public let relationship: String?
    var rank: Int { switch role { case .exact: 0; case .brand: 1; case .series: 2; case .company: 3; case .manufacturer: 4 } }

    static func verify(page: EntityWikipediaPage, entity: SearchEntity, in result: RecognitionResult) -> (Self?, WikipediaDiagnostic.Outcome) {
        guard page.valid(for: result.searchContractVersion) else { return (nil, .unsafePage) }
        let values = SearchEntity.matching(result)
        guard values.contains(entity) else { return (nil, .entityMismatch) }
        let identity = entity.names.first { name in page.identities.contains { EntityWikipediaPage.normalized($0) == EntityWikipediaPage.normalized(name) } }
        let sourceBound = [15, 16].contains(result.searchContractVersion ?? -1) || entity.basis == .logo || entity.basis == .appearance || page.identities.contains { name in
            EntityWikipediaPage.contains(entity.sourceText, name) || EntityWikipediaPage.normalized(name) == EntityWikipediaPage.normalized(entity.sourceText)
        }
        let sentences = (page.lead.components(separatedBy: CharacterSet(charactersIn: "。！？\n")) + page.passages).filter(EntityWikipediaPage.positive)
        func relation(to subject: SearchEntity, pattern: String) -> String? {
            let targets = EntityWikipediaPage.productEvidenceTerms(subject, version: result.searchContractVersion)
                .filter { target in !page.identities.contains { EntityWikipediaPage.normalized($0) == EntityWikipediaPage.normalized(target) } }
            // Both endpoints and a positive relation must occur in one sentence; parent/owner alone is insufficient.
            for sentence in sentences where sentence.count <= 600 {
                let s = EntityWikipediaPage.normalized(sentence)
                for target in targets where EntityWikipediaPage.contains(s, target) {
                    for actor in page.identities where EntityWikipediaPage.contains(s, actor) {
                        let a = NSRegularExpression.escapedPattern(for: EntityWikipediaPage.normalized(actor))
                        let b = NSRegularExpression.escapedPattern(for: EntityWikipediaPage.normalized(target))
                        let active = a + #"(?:公司|企業)?[\s，,]*(?:旗下|的)?(?:所|主要|專門|负责|負責)?[\s]*(?:"# + pattern + #")[^。！？；\n]{0,60}"# + b
                        let passive = b + #"[^。！？；\n]{0,30}(?:由|by)[\s]*"# + a + #"[\s]*(?:公司)?[\s]*(?:所)?(?:"# + pattern + ")"
                        if s.range(of: active, options: [.regularExpression, .caseInsensitive]) != nil || s.range(of: passive, options: [.regularExpression, .caseInsensitive]) != nil { return sentence }
                    }
                }
            }
            let entries = page.manufacturedEntries.filter { entry in
                let heading = entry.components(separatedBy: "\n")[0]
                return EntityWikipediaPage.isProductHeading(heading) &&
                    targets.contains { EntityWikipediaPage.contains(heading, $0) }
            }
            if page.kind(for: result.searchContractVersion) == .company, EntityWikipediaPage.positive(page.lead),
               page.lead.range(of: #"製造商|生產商|釀酒企業|釀造商|manufactur|brewer"#, options: [.regularExpression, .caseInsensitive]) != nil,
               entries.count == 1, let entry = entries.first {
                return page.title + "／現行產品／" + entry
            }
            // A literal products field on an explicitly manufacturing company can supply the relationship.
            if page.kind(for: result.searchContractVersion) == .company, page.lead.range(of: #"製造商|生產商|釀酒企業|釀造商|manufactur|brewer"#, options: [.regularExpression, .caseInsensitive]) != nil,
               EntityWikipediaPage.positive(page.lead), let fact = page.facts.first(where: { fact in
                   ["products", "產品", "產品列表"].contains(fact.field) && EntityWikipediaPage.positive(fact.value) &&
                   targets.contains(where: { EntityWikipediaPage.contains(fact.value, $0) }) }) {
                return page.title + "／" + fact.field + "：" + fact.value
            }
            return nil
        }
        let manufacturing = #"製造|制造|生產|生产|釀造|酿造|\bmanufactur(?:e[ds]?|ing)\b|\bproduc(?:e[ds]?|ing)\b|\bbrew(?:s|ed|ing)?\b"#
        if page.kind(for: result.searchContractVersion) == .company && [.product, .series, .brand].contains(entity.kind) {
            // A related brand must prove this central product's manufacture;
            // matching the company's own name cannot bypass that dependency.
            let subject = entity.role == .related ? values.first(where: { $0.id == entity.relatedTo }) : entity
            guard let subject, let proof = relation(to: subject, pattern: manufacturing) else { return (nil, .relationUnproven) }
            // A relationship cannot rescue a completely unrelated source phrase.
            guard [15, 16].contains(result.searchContractVersion ?? -1) || entity.basis == .logo || entity.basis == .appearance || entity.names.contains(where: { EntityWikipediaPage.contains(entity.sourceText, $0) }) else { return (nil, .aliasMissing) }
            return (.init(entityID: entity.id, role: .manufacturer, matchedName: entity.name, page: page, relationship: proof), .verified)
        }
        guard let identity, sourceBound else { return (nil, .aliasMissing) }
        let expected: EntityWikipediaPage.ArticleKind
        switch entity.kind { case .product: expected = .product; case .series: expected = .series; case .brand: expected = .brand
        case .company: expected = .company; case .species: expected = .species; case .person: expected = .person; case .object: expected = .object }
        guard page.kind(for: result.searchContractVersion) == expected else { return (nil, .entityMismatch) }
        if entity.kind == .person {
            let clues = entity.contextText.filter { clue in sentences.contains { EntityWikipediaPage.contains($0, clue) } }
            guard entity.independentClues(clues).count >= 2 else { return (nil, .personEvidence) }
        }
        var relationProof: String?
        var role: Role = entity.kind == .brand ? .brand : entity.kind == .series ? .series : entity.kind == .company ? .company : .exact
        if entity.role == .related {
            guard let central = values.first(where: { $0.id == entity.relatedTo }) else { return (nil, .relationUnproven) }
            let pattern = entity.relation == .manufacturer_of ? manufacturing : #"旗下|品牌|系列|\bbrand\b|\bseries\b|product line"#
            relationProof = relation(to: central, pattern: pattern)
            if relationProof == nil, [15, 16].contains(result.searchContractVersion ?? -1), entity.kind == .brand,
               entity.relation == .brand_of, page.kind(for: result.searchContractVersion) == .brand {
                relationProof = page.listedProductRelationship(to: central, brand: entity, in: result)
            }
            guard relationProof != nil else { return (nil, .relationUnproven) }
            if entity.relation == .manufacturer_of { role = .manufacturer }
        }
        return (.init(entityID: entity.id, role: role, matchedName: identity, page: page, relationship: relationProof), .verified)
    }
    func reference(for result: RecognitionResult, at date: Date) -> WikipediaReference {
        WikipediaReference(subjectKey: SearchEntity.cacheKey(for: result), title: page.title, canonicalURL: page.url,
            extract: page.lead, pageID: page.id, checkedAt: date, matchedQuery: matchedName,
            match: EntityWikipediaPage.normalized(page.title) == EntityWikipediaPage.normalized(matchedName) ? .exactTitle : .exactRedirect,
            entityEvidence: self)
    }
    func isValid(for result: RecognitionResult) -> Bool {
        guard let entity = SearchEntity.matching(result).first(where: { $0.id == entityID }) else { return false }
        return Self.verify(page: page, entity: entity, in: result).0 == self
    }
}

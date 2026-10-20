import Foundation

/// Closed diagnostics only. Old archives omit this field and are not enriched on load.
public enum WikipediaCandidateStatus: String, Codable, Hashable, Sendable {
    case modelProvided, localBrandFallback, structuredBrandFallback, missing, disabled, malformed, blocked
}

/// A local fallback for a missing/null optional field in a NEW response only.
/// Brand roles must be present on the same card; a product noun is never a brand.
enum WikipediaBrandFallback {
    static func latinAlias(in evidence: String) -> String? {
        let pattern = #"^([A-Za-z][A-Za-z'’.-]{1,23})\s+[\p{Han}]{2,12}$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: evidence, range: NSRange(evidence.startIndex..., in: evidence)),
              let range = Range(match.range(at: 1), in: evidence) else { return nil }
        return WikipediaSubject.normalize(String(evidence[range]).replacingOccurrences(of: "’", with: "'"))
    }
    private static let genericLabels: Set<String> = [
        "brand", "logo", "original", "quality", "product", "coffee", "tea", "chips", "paper",
        "phone", "computer", "headphones", "cream", "lotion", "chocolate", "cookie", "cookies",
        "drink", "beverage", "品牌", "商標", "標誌", "原味", "原創", "經典", "精選", "進口", "台灣", "臺灣", "中國"
    ]
    static func resolve(_ result: RecognitionResult) -> WikipediaTopics? {
        guard result.wikipediaTopics == nil, let candidate = candidate(for: result) else { return nil }
        return WikipediaTopics(category: .product, automaticWikipediaAllowed: true, classTerms: [],
            candidates: [candidate], matchScope: .brandIdentity)
    }
    /// Rechecked when admitting/restoring locally derived topics. Model metadata
    /// cannot select the brand-only matching policy.
    static func candidate(for result: RecognitionResult) -> WikipediaTopics.Candidate? {
        guard result.searchRestriction == nil,
              result.names.count == 1, let name = result.names.first,
              let search = result.searchQuery, search.category == .product,
              ProductNameSafety.specific(name, explicitField: false) else { return nil }
        let nonNumericCodes = result.barcodes.filter { $0.range(of: #"\p{L}"#, options: .regularExpression) != nil }
        let parts = result.names + [result.summary, search.query] + result.text + nonNumericCodes
        guard parts.count <= 100, parts.reduce(0, { $0 + $1.utf8.count }) <= 16_384 else { return nil }
        let context = parts.joined(separator: "\n")
        guard !WikipediaSubject.containsSensitiveContent(context), !ProductNameSafety.containsAddress(context),
              context.range(of: #"(?i)不確定|不确定|未知|不明|疑似|可能|無法確認|無法辨識|矛盾|衝突|不符|不一致|仿冒|假冒|仿製|不是.{0,12}品牌|非.{0,6}品牌|(?:品牌|商標).{0,12}不是|收件人|寄件人|姓名|名片|帳單|账单|金融|\b(unknown|uncertain|maybe|conflict|mismatch|counterfeit|private|patient|invoice|bank|insurance)\b"#, options: .regularExpression) == nil else { return nil }
        let lines = result.text.flatMap { $0.components(separatedBy: .newlines) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard lines.count <= 32 else { return nil }
        let patterns = [
            #"(?i)^(?:品牌|商標|商标|brand)\s*[:：]\s*([\p{Han}A-Za-z][\p{Han}A-Za-z'’ -]{1,23})$"#,
            #"^([\p{Han}A-Za-z][\p{Han}A-Za-z'’ -]{1,23})\s*[®™]$"#,
            #"^[A-Za-z][A-Za-z'’.-]{1,23}\s+([\p{Han}]{2,12})$"#
        ]
        var evidence: [String: (topic: String, line: String)] = [:]
        var aliases: [String: Set<String>] = [:]
        for line in lines {
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let range = Range(match.range(at: 1), in: line) else { continue }
                let topic = String(line[range]).trimmingCharacters(in: .whitespaces)
                guard WikipediaTopics.safeTerm(topic), ProductNameSafety.specific(topic, explicitField: true),
                      !genericLabels.contains(WikipediaSubject.normalize(topic)) else { continue }
                let key = WikipediaSubject.normalize(topic)
                if let alias = latinAlias(in: line) { aliases[key, default: []].insert(alias) }
                guard aliases[key, default: []].count <= 1 else { return nil }
                // Preserve the stronger bilingual clue regardless of OCR line order.
                if evidence[key] == nil || latinAlias(in: line) != nil { evidence[key] = (topic, line) }
            }
        }
        // A second explicit brand is ambiguity, even if one matches the item name.
        guard evidence.count == 1, let brand = evidence.values.first,
              WikipediaTopics.containsTerm(name, brand.topic), WikipediaTopics.containsTerm(search.query, brand.topic) else { return nil }
        // Role labels with ASCII ':' are never query terms. Keep the existing
        // evidence syntax guard by using the same card's whole name in that case.
        let clue = WikipediaTopics.safeTerm(brand.line, maximum: 120) ? brand.line : name
        return .init(topic: brand.topic, kind: .brand, evidence: clue)
    }
}

/// Optional hints from the same image response. Neither names nor transcribed text
/// are independent ground truth; the API checks below only corroborate a topic relation.
public struct WikipediaTopics: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case subject, series, brand }
    public enum MatchScope: String, Codable, Sendable { case brandIdentity, structuredIdentity }
    public struct Candidate: Codable, Equatable, Hashable, Sendable {
        public let topic: String
        public let kind: Kind
        public let evidence: String
        public let aliases: [String]?
        public init(topic: String, kind: Kind, evidence: String, aliases: [String]? = nil) {
            self.topic = topic; self.kind = kind; self.evidence = evidence; self.aliases = aliases
        }
    }
    public let category: PublicSearchQuery.Category
    public let automaticWikipediaAllowed: Bool
    public let classTerms: [String]
    public let candidates: [Candidate]
    public let matchScope: MatchScope?
    public init(category: PublicSearchQuery.Category, automaticWikipediaAllowed: Bool,
                classTerms: [String], candidates: [Candidate], matchScope: MatchScope? = nil) {
        self.category = category; self.automaticWikipediaAllowed = automaticWikipediaAllowed
        self.classTerms = classTerms; self.candidates = candidates
        self.matchScope = matchScope
    }
    enum CodingKeys: String, CodingKey {
        case category, candidates
        case automaticWikipediaAllowed = "automatic_wikipedia"
        case classTerms = "class_terms"
        case matchScope = "match_scope"
    }
    /// A bounded term in a model-generated clue is only an admission check, never page proof.
    static func containsTerm(_ text: String, _ term: String) -> Bool {
        let text = WikipediaSubject.normalize(text), term = WikipediaSubject.normalize(term)
        guard !term.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: term)
        // Preserve Latin token boundaries (Kellen != Kellens). Chinese clues do not
        // have spaces; their containment alone can never qualify a Wikipedia page.
        let pattern = "(?<![a-z0-9])" + escaped + "(?![a-z0-9])"
        return text.range(of: pattern, options: .regularExpression) != nil
    }
    static func safeTerm(_ text: String, maximum: Int = 48) -> Bool {
        (2...maximum).contains(text.count) && text.utf8.count <= maximum * 4 &&
        text.split(whereSeparator: \.isWhitespace).count <= 8 &&
        !WikipediaSubject.containsSensitiveContent(text) &&
        text.range(of: #"不確定|不确定|未知|可能|疑似|(?i)\b(unknown|uncertain|maybe)\b"#, options: .regularExpression) == nil &&
        text.range(of: #"[\p{C}:|*\[\]{}<>\"=]"#, options: .regularExpression) == nil &&
        text.range(of: #"[\p{L}]"#, options: .regularExpression) != nil
    }
    func validated(for result: RecognitionResult) -> Self? {
        if matchScope == .structuredIdentity {
            guard result.wikipediaCandidateStatus == result.searchIdentity?.wikipediaCandidateSource,
                  let expected = result.searchIdentity?.topics(for: result), self == expected else { return nil }
            return expected
        }
        if matchScope == .brandIdentity {
            guard result.wikipediaCandidateStatus == .localBrandFallback, category == .product,
                  classTerms.isEmpty, candidates.count == 1,
                  candidates.first == WikipediaBrandFallback.candidate(for: result) else { return nil }
        } else {
            guard (1...2).contains(classTerms.count) else { return nil }
        }
        guard automaticWikipediaAllowed, (1...2).contains(candidates.count),
              !result.names.isEmpty, result.names.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !WikipediaSubject.containsSensitiveContent($0) }),
              classTerms.allSatisfy({ Self.safeTerm($0, maximum: 24) }),
              Set(classTerms.map(WikipediaSubject.normalize)).count == classTerms.count,
              Set(candidates.map { WikipediaSubject.normalize($0.topic) }).count == candidates.count else { return nil }
        let clues = (result.names + result.text).flatMap { $0.components(separatedBy: .newlines) }.map(WikipediaSubject.normalize)
        for candidate in candidates {
            guard Self.safeTerm(candidate.topic), Self.safeTerm(candidate.evidence, maximum: 120),
                  clues.contains(WikipediaSubject.normalize(candidate.evidence)),
                  Self.containsTerm(candidate.evidence, candidate.topic) else { return nil }
        }
        if category == .product {
            guard candidates.allSatisfy({ $0.kind == .series || $0.kind == .brand }),
                  Set(candidates.map(\.kind)).count == candidates.count else { return nil }
        } else {
            guard candidates.count == 1, candidates[0].kind == .subject else { return nil }
        }
        // A model returning reversed candidates cannot change the priority.
        return Self(category: category, automaticWikipediaAllowed: true, classTerms: classTerms,
                    candidates: candidates.sorted { $0.kind == .series && $1.kind == .brand }, matchScope: matchScope)
    }
    var cacheKey: String {
        if matchScope == .structuredIdentity {
            return "structured-v10|" + category.rawValue + "|" + classTerms.map(WikipediaSubject.normalize).joined(separator: ";") + "|" + candidates.map { $0.kind.rawValue + ":" + WikipediaSubject.normalize($0.topic) + ":" + ($0.aliases ?? []).map(WikipediaSubject.normalize).sorted().joined(separator: ",") }.joined(separator: ";")
        }
        let base = (matchScope == .brandIdentity ? "brand-identity-v1|" : "topics-v1|") + category.rawValue + "|" + classTerms.map(WikipediaSubject.normalize).joined(separator: ";") + "|" +
        candidates.map { $0.kind.rawValue + ":" + WikipediaSubject.normalize($0.topic) }.joined(separator: ";")
        return matchScope == .brandIdentity ? base + "|alias:" + (candidates.first.flatMap { WikipediaBrandFallback.latinAlias(in: $0.evidence) } ?? "") : base
    }
}

public struct WikipediaRelationEvidence: Codable, Equatable, Sendable {
    public let kind: WikipediaTopics.Kind
    public let classTerm: String
    public let relatedTopic: String?
    /// Short API-derived positive definition / relation, not model-authored evidence.
    public let definition: String
    public let relation: String?
    public var scope: WikipediaTopics.MatchScope? = nil
    public var label: String {
        switch kind { case .brand: "品牌參考"; case .series: "系列參考"; case .subject: "主題參考" }
    }
}

extension WikipediaSubject {
    struct Page: Sendable {
        let id: Int; let title: String; let url: URL; let extract: String
        let categories: [String]; let match: WikipediaReference.Match; let topicIndex: Int
    }
    static func rejectsPerson(_ extract: String, categories: [String]) -> Bool {
        let classText = categories.map(normalize).joined(separator: " ")
        let lead = normalize(String(extract.prefix(220)))
        let people = #"人物|人名|姓氏|出生|逝世|在世|演員|歌手|作家|政治家|政治人物|運動員|企業家|傳教士|科學家|歷史學家|人類學家|家族"#
        return classText.range(of: people, options: .regularExpression) != nil ||
            lead.range(of: #"是一位|為一位|出生於|生於|逝世於|(?i)\b(born|surname|actor|politician|singer)\b"#, options: .regularExpression) != nil
    }
    private static func clauses(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "。！？\n；"))
            .map(normalize).filter { !$0.isEmpty }
    }
    private static func positive(_ text: String) -> Bool {
        text.range(of: #"並非|不是|不屬於|而非|無關|競爭|對手|不要|非.{0,6}品牌"#, options: .regularExpression) == nil
    }
    private func baseRelation(_ page: Page) -> (String, String)? {
        guard let topics, !Self.rejectsPerson(page.extract, categories: page.categories) else { return nil }
        if topics.matchScope == .brandIdentity || (topics.matchScope == .structuredIdentity && topics.candidates[page.topicIndex].kind == .brand) {
            return brandIdentityDefinition(page).map { ("品牌", $0) }
        }
        // Match a positive definition near the article beginning, not a product word
        // anywhere in a biography. Categories are supplementary, not a replacement.
        guard let definition = Self.clauses(String(page.extract.prefix(420))).prefix(2).first(where: {
            Self.positive($0) && $0.range(of: #"是|為|屬於"#, options: .regularExpression) != nil
        }) else { return nil }
        let kind = topics.candidates[page.topicIndex].kind
        if topics.matchScope == .structuredIdentity {
            let candidate = topics.candidates[page.topicIndex]
            guard let copula = definition.range(of: #"是|為|屬於"#, options: .regularExpression) else { return nil }
            let head = String(definition[..<copula.lowerBound])
            guard [page.title, candidate.topic].map(Self.normalize).contains(where: { name in
                head == name || head.range(of: "^" + NSRegularExpression.escapedPattern(for: name) + #"[\s（(，,：:]"#, options: .regularExpression) != nil
            }), (candidate.aliases ?? []).allSatisfy({ WikipediaTopics.containsTerm(definition, $0) }) else { return nil }
        }
        if kind == .brand && definition.range(of: #"品牌|商標|商品名"#, options: .regularExpression) == nil { return nil }
        if kind == .series && definition.range(of: #"系列|產品|商品"#, options: .regularExpression) == nil { return nil }
        let predicate = definition.range(of: #"是|為|屬於"#, options: .regularExpression).map { String(definition[$0.upperBound...]) } ?? ""
        let classTerm = topics.classTerms.first { term in
            let normal = Self.normalize(term)
            return WikipediaTopics.containsTerm(predicate, term) || page.categories.contains { category in
                let category = Self.normalize(category).replacingOccurrences(of: "category:", with: "").replacingOccurrences(of: "分類:", with: "")
                return category == normal || category == normal + "品牌" || category == normal + "製造商"
            }
        }
        return classTerm.map { ($0, definition) }
    }
    /// Exact title/redirect selection happens before this check. Require the
    /// article's own opening definition to identify a brand, not merely mention
    /// one. Bilingual OCR also needs its Latin alias in that definition.
    private func brandIdentityDefinition(_ page: Page) -> String? {
        guard let topics, topics.candidates.indices.contains(page.topicIndex) else { return nil }
        let candidate = topics.candidates[page.topicIndex]
        guard candidate.kind == .brand, !Self.containsSensitiveContent(String(page.extract.prefix(420))) else { return nil }
        let lead = String(page.extract.prefix(420))
        let definitions = Self.clauses(lead).prefix(2)
        for definition in definitions {
            guard Self.positive(definition),
                  let copula = definition.range(of: #"是|為|屬於"#, options: .regularExpression) else { continue }
            let head = String(definition[..<copula.lowerBound])
            let names = [page.title, candidate.topic].map(Self.normalize)
            guard names.contains(where: { name in
                head == name || head.range(of: "^" + NSRegularExpression.escapedPattern(for: name) + #"[\s（(，,：:]"#, options: .regularExpression) != nil
            }) else { continue }
            let predicate = String(definition[copula.upperBound...])
            guard predicate.range(of: #"研究|介紹|收藏|評論|報導|代理|代言|推廣|提及|收錄|贊助"#, options: .regularExpression) == nil,
                  predicate.range(of: #"^(?:(?!不是|並非|非品牌).){0,180}?(?:品牌|商標|商品名)(?:之一)?(?:[，,；;。.]|$)"#, options: .regularExpression) != nil else { continue }
            if topics.matchScope == .brandIdentity, let alias = WikipediaBrandFallback.latinAlias(in: candidate.evidence) {
                guard WikipediaTopics.containsTerm(definition.replacingOccurrences(of: "’", with: "'"), alias) else { continue }
            }
            if topics.matchScope == .structuredIdentity {
                guard (candidate.aliases ?? []).allSatisfy({ alias in
                    WikipediaTopics.containsTerm(definition.replacingOccurrences(of: "’", with: "'"), alias.replacingOccurrences(of: "’", with: "'"))
                }) else { continue }
            }
            return definition
        }
        return nil
    }
    private func relatedTopic(for page: Page) -> String? {
        guard let topics else { return nil }
        let opposite: WikipediaTopics.Kind = topics.candidates[page.topicIndex].kind == .brand ? .series : .brand
        return topics.candidates.first { $0.kind == opposite }?.topic
    }
    private func contradictsRelation(_ page: Page, text: String) -> Bool {
        guard let topics, let related = relatedTopic(for: page) else { return false }
        let current = topics.candidates[page.topicIndex].topic
        return Self.clauses(text).contains { clause in
            WikipediaTopics.containsTerm(clause, related) && !Self.positive(clause) &&
                (WikipediaTopics.containsTerm(clause, current) || WikipediaTopics.containsTerm(clause, page.title) ||
                 clause.hasPrefix("本品牌") || clause.hasPrefix("該品牌") || clause.hasPrefix("旗下"))
        }
    }
    private func relationClause(_ page: Page, text: String) -> String? {
        guard let topics, let related = relatedTopic(for: page) else { return nil }
        let current = topics.candidates[page.topicIndex]
        for clause in Self.clauses(text) where clause.count <= 500 {
            guard Self.positive(clause), WikipediaTopics.containsTerm(clause, related),
                  clause.range(of: #"旗下|所屬|推出|系列|產品|商品|品牌"#, options: .regularExpression) != nil else { continue }
            // Require both names in a relation clause, or a statement scoped to the
            // article's own products. Merely mentioning a competitor is insufficient.
            if WikipediaTopics.containsTerm(clause, current.topic) || WikipediaTopics.containsTerm(clause, page.title) ||
                clause.hasPrefix("現有") || clause.hasPrefix("旗下") || clause.hasPrefix("本品牌") || clause.hasPrefix("該品牌") {
                return clause
            }
        }
        // TextExtracts plain sections: a short heading names the related series,
        // followed by a positive product definition with a corroborating class term.
        if current.kind == .brand {
            let paragraphs = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            for index in paragraphs.indices.dropLast() {
                let heading = paragraphs[index]
                guard heading.count <= 80, !heading.contains("。"), WikipediaTopics.containsTerm(heading, related) else { continue }
                guard let next = Self.clauses(paragraphs[index + 1]).first, next.count <= 500, Self.positive(next),
                      WikipediaTopics.containsTerm(next, related), next.range(of: #"是|為|屬於"#, options: .regularExpression) != nil,
                      next.range(of: #"旗下|產品|商品|系列"#, options: .regularExpression) != nil,
                      topics.classTerms.contains(where: { WikipediaTopics.containsTerm(next, $0) }) else { continue }
                return heading + "：" + next
            }
        }
        return nil
    }
    func needsExtendedExtract(_ page: Page) -> Bool {
        baseRelation(page) != nil && relatedTopic(for: page) != nil &&
            !contradictsRelation(page, text: page.extract) && relationClause(page, text: page.extract) == nil
    }
    func relationEvidence(_ page: Page, fullExtract: String? = nil) -> WikipediaRelationEvidence? {
        guard let topics, let (term, definition) = baseRelation(page),
              !contradictsRelation(page, text: page.extract),
              fullExtract.map({ !contradictsRelation(page, text: $0) }) ?? true else { return nil }
        let related = relatedTopic(for: page)
        let relation = related == nil ? nil : relationClause(page, text: page.extract) ?? fullExtract.flatMap { relationClause(page, text: $0) }
        guard related == nil || relation != nil else { return nil }
        return .init(kind: topics.candidates[page.topicIndex].kind, classTerm: term, relatedTopic: related,
                     definition: String(definition.prefix(500)), relation: relation.map { String($0.prefix(600)) }, scope: topics.matchScope)
    }
}

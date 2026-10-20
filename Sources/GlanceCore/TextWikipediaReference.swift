import Foundation
import CryptoKit

/// Original-text references are independent of the central subject's introduction.
/// The same response supplies selection, public-context permission and verbatim anchors.
public struct TextWikipediaCandidate: Codable, Equatable, Hashable, Sendable {
    public let query: String
    public let sourceText: String
    public let reason: String
    public let contextText: [String]
    public var candidate13: SearchCandidate? = nil
    enum CodingKeys: String, CodingKey {
        case query, reason, candidate13
        case sourceText = "source_text", contextText = "context_text"
    }
    public init(query: String, sourceText: String, reason: String, contextText: [String] = [], candidate13: SearchCandidate? = nil) {
        self.query = query; self.sourceText = sourceText; self.reason = reason; self.contextText = contextText
        self.candidate13 = candidate13
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        query = try c.decode(String.self, forKey: .query)
        sourceText = try c.decode(String.self, forKey: .sourceText)
        reason = try c.decode(String.self, forKey: .reason)
        contextText = try c.decodeIfPresent([String].self, forKey: .contextText) ?? []
        candidate13 = try c.decodeIfPresent(SearchCandidate.self, forKey: .candidate13)
    }
    static func normalized(_ value: String) -> String {
        WikipediaSubject.normalize(value).replacingOccurrences(of: "臺", with: "台")
    }
    static func contains(_ text: String, _ term: String) -> Bool {
        WikipediaTopics.containsTerm(normalized(text), normalized(term))
    }
    static func safe(_ value: String, limit: Int) -> Bool {
        (2...limit).contains(value.count) && value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
        !WikipediaSubject.containsSensitiveContent(value) && !SearchIdentity.containsPrivateContext(value) &&
        !ProductNameSafety.containsAddress(value) &&
        value.range(of: #"[\p{C}:|*\[\]{}<>\"=]|(?i)\b(?:sk|sess|gh[pousr]|github_pat)[-_][a-z0-9_-]{8,}|\beyJ[a-z0-9_-]{12,}"#, options: .regularExpression) == nil &&
        value.range(of: #"[\p{L}]"#, options: .regularExpression) != nil
    }
    func valid(in text: [String]) -> Bool {
        guard Self.safe(query, limit: 64), Self.safe(sourceText, limit: 120),
              !reason.isEmpty, reason.count <= 120, reason.rangeOfCharacter(from: .controlCharacters) == nil,
              contextText.count <= 3, contextText.allSatisfy({ Self.safe($0, limit: 64) }),
              text.contains(where: { $0.contains(sourceText) }), Self.contains(sourceText, query),
              contextText.allSatisfy({ clue in text.contains { $0.contains(clue) } }),
              Set(contextText.map(Self.normalized)).count == contextText.count else { return false }
        return true
    }
    public static func matching(_ result: RecognitionResult) -> [Self] {
        if result.searchContractVersion != nil {
            return SearchCandidate.matching(result).filter { $0.role == .text }.map {
                .init(query: $0.query, sourceText: $0.sourceText, reason: "", contextText: $0.contextText, candidate13: $0)
            }
        }
        guard result.textWikipediaPolicy == .allowed,
              result.searchRestriction != .sensitive, result.searchRestriction != .invalidRestriction,
              let values = result.textWikipediaCandidates, values.count <= 3,
              result.text.count <= 32, result.text.allSatisfy({ $0.count <= 1000 }),
              !result.lines.contains(where: SearchIdentity.containsPrivateContext) else { return [] }
        var seen = Set<String>()
        return values.filter { $0.candidate13 == nil && $0.valid(in: result.text) && seen.insert(normalized($0.query)).inserted }
    }
    public var key: String {
        if let candidate13 { return candidate13.key }
        let fields = [Self.normalized(query), sourceText] + contextText.map(Self.normalized).sorted()
        let bytes = try! JSONEncoder().encode(fields)
        return "text-v12:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    public var request: URLRequest {
        let subject = WikipediaSubject(key: key, searchTitle: query, category: .object, topics: nil, candidate13: candidate13)
        var request = subject.request
        var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        url.queryItems = url.queryItems!.map { item in
            if item.name == "prop" { return .init(name: "prop", value: "info|extracts|pageprops|redirects|categories") }
            if item.name == "exchars" { return .init(name: "exchars", value: "1200") }
            return item
        }
        if candidate13 == nil { url.queryItems! += [.init(name: "cllimit", value: "40"), .init(name: "clshow", value: "!hidden")] }
        request.url = url.url
        return request
    }
    public func reference(from data: Data, at date: Date = Date()) -> TextWikipediaReference? {
        let subject = WikipediaSubject(key: key, searchTitle: query, category: .object, topics: nil, candidate13: candidate13)
        guard let page = subject.page(from: data, at: 0), page.categories.count <= 40,
              let proof = proof(extract: page.extract, categories: page.categories) else { return nil }
        return .init(candidateKey: key, title: page.title, canonicalURL: page.url, extract: page.extract,
                     pageID: page.id, checkedAt: date, matchedQuery: query, match: page.match,
                     categories: page.categories, contextEvidence: proof)
    }
    func proof(extract: String, categories: [String]) -> [String]? {
        if let candidate13 { return candidate13.proof(extract: extract, categories: categories) }
        let positiveClauses = extract.components(separatedBy: CharacterSet(charactersIn: "。！？\n；"))
            .filter { $0.range(of: #"並非|不是|不屬於|而非|無關|未曾|沒有|(?i)\b(?:not|never|unrelated)\b"#, options: .regularExpression) == nil }
        let matches = contextText.filter { clue in positiveClauses.contains { Self.contains($0, clue) } }
        if WikipediaSubject.rejectsPerson(extract, categories: categories) {
            // A matching name is never identity evidence. Require two distinct,
            // substantial image-text anchors, not a generic two-character class.
            var independent: [String] = []
            for clue in matches where clue.count >= 4 && !Self.contains(clue, query) && !Self.contains(query, clue) {
                if independent.allSatisfy({ !Self.contains($0, clue) && !Self.contains(clue, $0) }) { independent.append(clue) }
            }
            return independent.count >= 2 ? independent : nil
        }
        guard Self.contains(String(extract.prefix(500)), query), contextText.isEmpty || !matches.isEmpty else { return nil }
        return matches
    }
}

public struct TextWikipediaReference: Codable, Equatable, Sendable {
    public let candidateKey: String
    public let title: String
    public let canonicalURL: URL
    public let extract: String
    public let pageID: Int
    public let checkedAt: Date
    public let matchedQuery: String
    public let match: WikipediaReference.Match
    public let categories: [String]
    public let contextEvidence: [String]
    public var displayTitle: String { title.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? title }
    public func isCurrent(for result: RecognitionResult, at date: Date = Date()) -> Bool {
        if result.searchContractVersion != nil {
            guard date.timeIntervalSince(checkedAt) >= 0, date.timeIntervalSince(checkedAt) < WikipediaReference.lifetime,
                  pageID > 0, WikipediaReference.allowedURL(canonicalURL), CandidateQuerySafety.accepts(title, limit: 120),
                  let candidate = TextWikipediaCandidate.matching(result).first(where: { $0.key == candidateKey }),
                  matchedQuery == candidate.query,
                  candidate.proof(extract: extract, categories: categories) == contextEvidence else { return false }
            return match == .exactRedirect || WikipediaSubject.normalize(title) == WikipediaSubject.normalize(matchedQuery)
        }
        guard date.timeIntervalSince(checkedAt) >= 0, date.timeIntervalSince(checkedAt) < WikipediaReference.lifetime,
              pageID > 0, WikipediaReference.allowedURL(canonicalURL), WikipediaReference.validExtract(extract),
              TextWikipediaCandidate.safe(title, limit: 120), categories.count <= 40,
              let candidate = TextWikipediaCandidate.matching(result).first(where: { $0.key == candidateKey }),
              matchedQuery == candidate.query,
              match == .exactRedirect || WikipediaSubject.normalize(title) == WikipediaSubject.normalize(matchedQuery),
              candidate.proof(extract: extract, categories: categories) == contextEvidence else { return false }
        return true
    }
}

public struct WikipediaEnrichment: Equatable, Sendable {
    public let subject: WikipediaReference?
    public let text: [TextWikipediaReference]
    public let diagnostics: [WikipediaDiagnostic]
    public init(subject: WikipediaReference? = nil, text: [TextWikipediaReference] = [], diagnostics: [WikipediaDiagnostic] = []) { self.subject = subject; self.text = text; self.diagnostics = diagnostics.count <= 64 ? diagnostics : Array(diagnostics.prefix(8)) + Array(diagnostics.suffix(56)) }
}

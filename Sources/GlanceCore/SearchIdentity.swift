import Foundation
import CoreFoundation

/// Closed failure codes plus bounded, safety-checked search-only provenance.
/// Never stores the response, OCR, arbitrary keys or decoder error descriptions.
public struct SearchParseDiagnostic: Codable, Equatable, Hashable, Sendable {
    public enum Shape: String, Codable, Sendable { case missing, null, object, array, string, number, boolean, other }
    public enum Outcome: String, Codable, Sendable { case missing, null, decoded, decodingFailed }
    public enum Version: String, Codable, Sendable { case missing, null, expected10, expected11, expected12, unsupportedOrWrongType }
    public enum Reason: String, Codable, Sendable { case missing, null, sensitive, conflict, uncertain, invalid }
    public enum Field: String, Codable, Sendable {
        case schema_version, names, summary, text, search_block_reason, search_identity
        case category, subject, brand, manufacturer, series, product, model_version, formal_name
        case disambiguation, google_keywords, automatic_wikipedia, wikipedia_policy, wikipedia_candidates
        case name, aliases, basis, topic, kind
    }
    public let parserRevision: Int
    public let version: Version
    public let reason: Reason
    public let identityShape: Shape
    public let identityOutcome: Outcome
    public let decodingField: Field?
    public let validationFailure: SearchIdentity.ValidationFailure?
    public let googleFailure: SearchIdentity.ValidationFailure?
    public let wikipediaFailure: SearchIdentity.ValidationFailure?
    public let entityField: Field?
    public let entityFailure: SearchIdentity.EntityFailure?
    public let missingRootFields: [Field]
    public let missingIdentityFields: [Field]
    public let contentWithinBounds: Bool
    public enum EvidenceSuppression: String, Codable, Sendable {
        case blockedOrPrivate, invalidContract, missingIdentity, bounds, unsafeSearchText
    }
    public let keywordEvidence: SearchKeywordEvidence?
    public let evidenceSuppression: EvidenceSuppression?
    public let normalizationFields: [Field]?
    public var wikipediaPolicy: SearchIdentity.WikipediaPolicy? = nil
    public enum GoogleOutcome: String, Codable, Sendable { case complete, partial, identityFallback, unavailable, blocked }
    public var googleOutcome: GoogleOutcome? = nil
    public var googleFallbackField: Field? = nil

    static func inspect(_ data: Data, identity: SearchIdentity?, decodingField: Field?,
                        complete: Bool, allowSearchText: Bool) -> Self {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        func shape(_ value: Any?) -> Shape {
            guard let value else { return .missing }
            if value is NSNull { return .null }
            if value is [String: Any] { return .object }
            if value is [Any] { return .array }
            if value is String { return .string }
            if let value = value as? NSNumber {
                return CFGetTypeID(value) == CFBooleanGetTypeID() ? .boolean : .number
            }
            return .other
        }
        let identityShape = shape(root["search_identity"])
        let version: Version = root["schema_version"] == nil ? .missing :
            root["schema_version"] is NSNull ? .null :
            shape(root["schema_version"]) == .number && (root["schema_version"] as? NSNumber)?.doubleValue == 10 ? .expected10 :
            shape(root["schema_version"]) == .number && (root["schema_version"] as? NSNumber)?.doubleValue == 11 ? .expected11 :
            shape(root["schema_version"]) == .number && (root["schema_version"] as? NSNumber)?.doubleValue == 12 ? .expected12 : .unsupportedOrWrongType
        let reason: Reason = root["search_block_reason"] == nil ? .missing :
            root["search_block_reason"] is NSNull ? .null :
            (root["search_block_reason"] as? String).flatMap { value in
                ["sensitive", "conflict", "uncertain"].contains(value) ? Reason(rawValue: value) : nil
            } ?? .invalid
        let required: [Field] = [.schema_version, .names, .summary, .text, .search_block_reason, .search_identity]
        let identityFields: [Field] = [.category, .subject, .brand, .manufacturer, .series, .product,
            .model_version, .formal_name, .disambiguation, .google_keywords, [.expected11, .expected12].contains(version) ? .wikipedia_policy : .automatic_wikipedia, .wikipedia_candidates]
        let object = root["search_identity"] as? [String: Any]
        let normalized = identity?.normalizedForSearch()
        let missingRoot = required.filter { root[$0.rawValue] == nil }
        let missingIdentity = object.map { object in identityFields.filter { object[$0.rawValue] == nil } } ?? []
        let evidence: SearchKeywordEvidence?
        let suppression: EvidenceSuppression?
        if !allowSearchText || reason != .null {
            evidence = nil; suppression = .blockedOrPrivate
        } else if !complete || ![.expected10, .expected11, .expected12].contains(version) || !missingRoot.isEmpty || !missingIdentity.isEmpty {
            evidence = nil; suppression = .invalidContract
        } else if let identity {
            (evidence, suppression) = identity.diagnosticEvidence()
        } else {
            evidence = nil; suppression = .missingIdentity
        }
        return .init(parserRevision: version == .expected12 ? 33 : 32, version: version, reason: reason,
            identityShape: identityShape,
            identityOutcome: identityShape == .missing ? .missing : identityShape == .null ? .null : identity == nil ? .decodingFailed : .decoded,
            decodingField: decodingField, validationFailure: normalized?.validationFailure,
            googleFailure: normalized?.googleValidationFailure, wikipediaFailure: normalized?.wikipediaValidationFailure,
            entityField: normalized?.invalidEntity?.0, entityFailure: normalized?.invalidEntity?.1,
            missingRootFields: missingRoot, missingIdentityFields: missingIdentity,
            contentWithinBounds: complete, keywordEvidence: evidence, evidenceSuppression: suppression,
            normalizationFields: identity.flatMap { raw in normalized.map { raw.changedFields(comparedTo: $0) } }, wikipediaPolicy: identity?.wikipediaPolicy,
            googleOutcome: suppression == nil ? (version == .expected12 && normalized?.emptyKeywordFallback != nil ? .identityFallback : normalized?.googleOutcome) : .blocked,
            googleFallbackField: suppression == nil ? (version == .expected12 ? normalized?.emptyKeywordFallback?.field ?? normalized?.googleFallbackField : normalized?.googleFallbackField) : nil)
    }
}

/// Same-response visual interpretation, not independently verified facts. Kept
/// apart from verbatim transcription and local barcode provenance.
public struct SearchIdentity: Codable, Equatable, Hashable, Sendable {
    public enum WikipediaPolicy: String, Codable, Sendable { case allowed, sensitive, conflict, uncertain }
    public enum Basis: String, Codable, Sendable { case text, logo, appearance, qr }
    public enum EntityFailure: String, Codable, Sendable { case nameSafety, aliasSafety, duplicateTerms, basis }
    public struct Entity: Codable, Equatable, Hashable, Sendable {
        public let name: String
        public let aliases: [String]
        public let basis: [Basis]
        var terms: [String] { [name] + aliases }
        var failure: EntityFailure? {
            guard Self.safe(name) else { return .nameSafety }
            guard aliases.count <= 3 && aliases.allSatisfy(Self.safe) else { return .aliasSafety }
            guard Set(terms.map(WikipediaSubject.normalize)).count == terms.count else { return .duplicateTerms }
            guard !basis.isEmpty && basis.count <= 4 && Set(basis).count == basis.count else { return .basis }
            return nil
        }
        var valid: Bool { failure == nil }
        private static func safe(_ term: String) -> Bool {
            term == term.trimmingCharacters(in: .whitespacesAndNewlines) &&
            term.count <= 64 && SearchIdentity.safeSearchText(term)
        }
        func normalizedForSearch() -> Self {
            // Check every ORIGINAL value and raw count before removing duplicates.
            // Unsafe data or an oversized list cannot be repaired into acceptance.
            guard name.count <= 64, SearchIdentity.safeSearchText(name), aliases.count <= 3,
                  aliases.allSatisfy({ $0.count <= 64 && SearchIdentity.safeSearchText($0) }),
                  basis.count <= 4 else { return self }
            let name = name.trimmingCharacters(in: .whitespaces)
            var seen = Set([SearchKeywordOrigin.key(name)])
            let aliases = aliases.map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { seen.insert(SearchKeywordOrigin.key($0)).inserted }
            var seenBasis = Set<Basis>()
            return .init(name: name, aliases: aliases, basis: basis.filter { seenBasis.insert($0).inserted })
        }
    }
    public struct Topic: Codable, Equatable, Hashable, Sendable {
        public let topic: String
        public let kind: WikipediaTopics.Kind
    }
    public let category: PublicSearchQuery.Category
    public let subject: Entity?
    public let brand: Entity?
    public let manufacturer: Entity?
    public let series: Entity?
    public let product: Entity?
    public let modelVersion: Entity?
    public let formalName: Entity?
    public let disambiguation: [String]
    public let googleKeywords: [String]
    public let automaticWikipedia: Bool
    public let wikipediaCandidates: [Topic]
    public var wikipediaPolicy: WikipediaPolicy? = nil
    enum CodingKeys: String, CodingKey {
        case category, subject, brand, manufacturer, series, product, disambiguation
        case modelVersion = "model_version", formalName = "formal_name"
        case googleKeywords = "google_keywords", automaticWikipedia = "automatic_wikipedia"
        case wikipediaCandidates = "wikipedia_candidates", wikipediaPolicy = "wikipedia_policy"
    }
    static func containsPrivateContext(_ value: String) -> Bool {
        value.range(of: #"(?i)病歷|病历|(?:病人|患者)(?:姓名|編號|資料|ID)|(?:病人|患者)\s*[:：]|處方箋|處方籤|用藥紀錄|醫療紀錄|診療紀錄|收件人|寄件人|私人|私密|個人帳戶|個人帳號|身分證|身份證|信用卡|(?:姓名|住址|帳號)\s*[:：]|medical\s+(?:record|history)|patient\s*(?:name|id|record|[:：])|private\s+(?:document|message)|recipient"#, options: .regularExpression) != nil
    }
    private static func safeSearchText(_ value: String) -> Bool {
        ProductNameSafety.accepts(value) && !containsPrivateContext(value) &&
        value.range(of: #"(?i)\b(?:sk|sess|gh[pousr]|github_pat)[-_][a-z0-9_-]{8,}|\beyJ[a-z0-9_-]{12,}"#, options: .regularExpression) == nil
    }
    private var entities: [Entity] { [subject, brand, manufacturer, series, product, modelVersion, formalName].compactMap { $0 } }
    var invalidEntity: (SearchParseDiagnostic.Field, EntityFailure)? {
        let fields: [(SearchParseDiagnostic.Field, Entity?)] = [(.subject, subject), (.brand, brand),
            (.manufacturer, manufacturer), (.series, series), (.product, product),
            (.model_version, modelVersion), (.formal_name, formalName)]
        return fields.compactMap { field, entity in entity?.failure.map { (field, $0) } }.first
    }
    public enum ValidationFailure: String, Codable, Sendable {
        case entityFields, listBoundsOrValues, manufacturerBasis, categoryRoles
        case keywordOrigin, googleQuery, candidateDuplicates, candidateRoleOrTopic
    }
    var validationFailure: ValidationFailure? {
        structuralFailure ?? googleValidationFailure ?? wikipediaValidationFailure
    }
    private var structuralFailure: ValidationFailure? {
        guard !entities.isEmpty, entities.allSatisfy(\.valid) else { return .entityFields }
        guard
              disambiguation.count <= 2, disambiguation.allSatisfy({ Self.safeSearchText($0) && $0.count <= 24 }),
              Set(disambiguation.map(WikipediaSubject.normalize)).count == disambiguation.count,
              googleKeywords.count <= 8, googleKeywords.allSatisfy({ Self.safeSearchText($0) && $0.count <= 64 }),
              Set(googleKeywords.map(WikipediaSubject.normalize)).count == googleKeywords.count,
              wikipediaCandidates.count <= 2 else { return .listBoundsOrValues }
        // A logo identifies a brand, never proves who manufactures this version.
        if let manufacturer, !manufacturer.basis.allSatisfy({ $0 == .text || $0 == .qr }) { return .manufacturerBasis }
        if category != .product && [brand, manufacturer, series, product, modelVersion].contains(where: { $0 != nil }) { return .categoryRoles }
        return nil
    }
    var googleValidationFailure: ValidationFailure? {
        guard structuralFailure == nil else { return structuralFailure }
        let sources = keywordSources
        guard googleKeywords.allSatisfy({ SearchKeywordOrigin.match($0, sources: sources).kind != .unmatched }) else { return .keywordOrigin }
        guard googleKeywords.isEmpty || uncheckedGoogleQuery != nil else { return .googleQuery }
        return nil
    }
    var wikipediaValidationFailure: ValidationFailure? {
        guard structuralFailure == nil else { return structuralFailure }
        // Query topics must come from their declared semantic role, not a brand
        // substring in OCR, the display name, or a manufacturer name.
        guard Set(wikipediaCandidates.map { $0.kind }).count == wikipediaCandidates.count,
              Set(wikipediaCandidates.map { WikipediaSubject.normalize($0.topic) }).count == wikipediaCandidates.count else { return .candidateDuplicates }
        guard wikipediaCandidates.allSatisfy({ candidate in
            guard WikipediaTopics.safeTerm(candidate.topic), let entity = entity(for: candidate) else { return false }
            return entity.terms.contains { WikipediaSubject.normalize($0) == WikipediaSubject.normalize(candidate.topic) }
        }) else { return .candidateRoleOrTopic }
        return nil
    }
    var valid: Bool { validationFailure == nil }
    func normalizedForSearch() -> Self {
        func terms(_ values: [String], count: Int, length: Int) -> [String] {
            guard values.count <= count, values.allSatisfy({ $0.count <= length && Self.safeSearchText($0) }) else { return values }
            var seen = Set<String>()
            return values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { seen.insert(SearchKeywordOrigin.key($0)).inserted }
        }
        let subject = subject?.normalizedForSearch(), brand = brand?.normalizedForSearch()
        let manufacturer = manufacturer?.normalizedForSearch(), series = series?.normalizedForSearch()
        let product = product?.normalizedForSearch(), modelVersion = modelVersion?.normalizedForSearch()
        let formalName = formalName?.normalizedForSearch()
        var candidates = wikipediaCandidates
        if candidates.count <= 2 && candidates.allSatisfy({ WikipediaTopics.safeTerm($0.topic) }) {
            var seen = Set<String>()
            candidates = candidates.compactMap { candidate in
                let fields: [(String, Entity?)]
                switch candidate.kind {
                case .brand: fields = [("brand", brand)]
                case .series: fields = [("series", series)]
                case .subject: fields = [("formal_name", formalName), ("subject", subject)]
                }
                // Equivalent aliases of ONE declared entity may repeat a role.
                // Unknown or conflicting topics remain present for normal rejection.
                for (field, entity) in fields {
                    if let term = entity?.terms.first(where: { SearchKeywordOrigin.key($0) == SearchKeywordOrigin.key(candidate.topic) }) {
                        guard seen.insert(candidate.kind.rawValue + ":" + field).inserted else { return nil }
                        return .init(topic: term, kind: candidate.kind)
                    }
                }
                return candidate
            }
        }
        return .init(category: category, subject: subject, brand: brand, manufacturer: manufacturer,
            series: series, product: product, modelVersion: modelVersion, formalName: formalName,
            disambiguation: terms(disambiguation, count: 2, length: 24),
            googleKeywords: terms(googleKeywords, count: 8, length: 64),
            automaticWikipedia: automaticWikipedia, wikipediaCandidates: candidates, wikipediaPolicy: wikipediaPolicy)
    }
    func changedFields(comparedTo other: Self) -> [SearchParseDiagnostic.Field] {
        let pairs: [(SearchParseDiagnostic.Field, Bool)] = [(.subject, subject != other.subject), (.brand, brand != other.brand),
            (.manufacturer, manufacturer != other.manufacturer), (.series, series != other.series),
            (.product, product != other.product), (.model_version, modelVersion != other.modelVersion),
            (.formal_name, formalName != other.formalName), (.disambiguation, disambiguation != other.disambiguation),
            (.google_keywords, googleKeywords != other.googleKeywords), (.wikipedia_candidates, wikipediaCandidates != other.wikipediaCandidates)]
        return pairs.compactMap { $0.1 ? $0.0 : nil }
    }
    // A safe but unsupported Google term cannot invalidate independently checked
    // identity roles or Wiki candidates. Unsafe syntax/privacy still fails closed.
    var validForIdentity: Bool { structuralFailure == nil && wikipediaValidationFailure == nil }
    var keywordSources: [SearchKeywordEvidence.Source] {
        let fields: [(SearchParseDiagnostic.Field, Entity?)] = [(.subject, subject), (.brand, brand),
            (.manufacturer, manufacturer), (.series, series), (.product, product),
            (.model_version, modelVersion), (.formal_name, formalName)]
        return fields.flatMap { field, entity -> [SearchKeywordEvidence.Source] in
            guard let entity else { return [] }
            return [.init(field: field, kind: .name, index: 0, text: entity.name, basis: entity.basis)] +
                entity.aliases.enumerated().map { .init(field: field, kind: .alias, index: $0.offset, text: $0.element, basis: entity.basis) }
        } + disambiguation.enumerated().map { .init(field: .disambiguation, kind: .disambiguation, index: $0.offset, text: $0.element, basis: []) }
    }
    func diagnosticEvidence() -> (SearchKeywordEvidence?, SearchParseDiagnostic.EvidenceSuppression?) {
        guard entities.allSatisfy({ $0.aliases.count <= 3 && $0.basis.count <= 4 }),
              disambiguation.count <= 2, googleKeywords.count <= 8, wikipediaCandidates.count <= 2 else { return (nil, .bounds) }
        let sources = keywordSources
        let texts = sources.map(\.text) + googleKeywords + wikipediaCandidates.map(\.topic)
        guard sources.count <= 30, texts.allSatisfy({ $0.count <= 64 }),
              texts.reduce(0, { $0 + $1.utf8.count }) <= 10_240 else { return (nil, .bounds) }
        // Diagnostics never promote unsafe text into storage just because parsing
        // rejected it. Public medicine names remain allowed; private contexts do not.
        guard texts.allSatisfy(Self.safeSearchText) else { return (nil, .unsafeSearchText) }
        let keywords = googleKeywords.enumerated().map { index, text in
            let match = SearchKeywordOrigin.match(text, sources: sources)
            return SearchKeywordEvidence.Keyword(index: index, text: text, match: match.kind, sourceIndices: match.sources)
        }
        return (.init(category: category, sources: sources, keywords: keywords,
            automaticWikipedia: automaticWikipedia, wikipediaCandidates: wikipediaCandidates, wikipediaPolicy: wikipediaPolicy), nil)
    }
    private func entity(for candidate: Topic) -> Entity? {
        switch candidate.kind {
        case .brand: return category == .product ? brand : nil
        case .series: return category == .product ? series : nil
        case .subject:
            guard category != .product else { return nil }
            return [formalName, subject].compactMap { $0 }.first { entity in
                entity.terms.contains { WikipediaSubject.normalize($0) == WikipediaSubject.normalize(candidate.topic) }
            }
        }
    }
    private var supportedGoogleKeywords: [String] {
        let sources = keywordSources
        return googleKeywords.filter { SearchKeywordOrigin.match($0, sources: sources).kind != .unmatched }
    }
    var googleQuery: PublicSearchQuery? {
        // Validate every raw value first. Only safe, source-unmatched whole phrases
        // may be omitted; never salvage substrings, unsafe syntax or conflicting roles.
        guard validForIdentity, wikipediaPolicy != .conflict, wikipediaPolicy != .uncertain else { return nil }
        return uncheckedGoogleQuery
    }
    /// Only the new wire contract permits a missing keyword list to use a
    /// complete declared public identity. Never infer it from the OCR or title.
    var emptyKeywordFallback: (field: SearchParseDiagnostic.Field, query: PublicSearchQuery)? {
        guard googleKeywords.isEmpty, validForIdentity, wikipediaPolicy != .conflict,
              wikipediaPolicy != .uncertain else { return nil }
        return fallbackGoogleSelection
    }
    private var uncheckedGoogleQuery: PublicSearchQuery? {
        // Preserve the original combined query bounds/safety before omitting words.
        guard PublicSearchQuery(query: googleKeywords.joined(separator: " "), category: category.rawValue) != nil else { return nil }
        let supported = supportedGoogleKeywords
        if !supported.isEmpty { return PublicSearchQuery(query: supported.joined(separator: " "), category: category.rawValue) }
        // A different, complete declared identity is independent evidence. Never
        // repair rejected phrases, infer translations, or take words from OCR.
        return fallbackGoogleSelection?.query
    }
    private var fallbackGoogleSelection: (field: SearchParseDiagnostic.Field, query: PublicSearchQuery)? {
        let choices: [(SearchParseDiagnostic.Field, Entity?)] = category == .product
            ? [(.product, product), (.brand, brand)] : [(.formal_name, formalName), (.subject, subject)]
        for (field, entity) in choices {
            guard let entity, entity.valid, ProductNameSafety.specific(entity.name, explicitField: true),
                  let query = PublicSearchQuery(query: entity.name, category: category.rawValue) else { continue }
            return (field, query)
        }
        return nil
    }
    var googleFallbackField: SearchParseDiagnostic.Field? {
        googleOutcome == .identityFallback ? fallbackGoogleSelection?.field : nil
    }
    var googleOutcome: SearchParseDiagnostic.GoogleOutcome {
        guard validForIdentity, wikipediaPolicy != .conflict, wikipediaPolicy != .uncertain else { return .blocked }
        guard googleQuery != nil else { return .unavailable }
        if supportedGoogleKeywords.isEmpty { return .identityFallback }
        return supportedGoogleKeywords.count == googleKeywords.count ? .complete : .partial
    }
    // Only an explicit NEW policy may generate a missing brand suggestion.
    // Legacy true/false and saved cards with unknown reasons keep their meaning.
    var effectiveWikipediaCandidates: [Topic] {
        guard wikipediaCandidates.isEmpty, wikipediaPolicy == .allowed,
              automaticWikipedia, category == .product, let brand, brand.valid else { return wikipediaCandidates }
        let terms = brand.terms.filter { WikipediaTopics.safeTerm($0) }
        guard let topic = terms.first(where: { $0.unicodeScalars.contains { $0.properties.isIdeographic } }) ?? terms.first else { return [] }
        return [.init(topic: topic, kind: .brand)]
    }
    var wikipediaCandidateSource: WikipediaCandidateStatus {
        wikipediaCandidates.isEmpty && !effectiveWikipediaCandidates.isEmpty ? .structuredBrandFallback : .modelProvided
    }
    func boundToWire(version: Int?) -> Self {
        .init(category: category, subject: subject, brand: brand, manufacturer: manufacturer,
              series: series, product: product, modelVersion: modelVersion, formalName: formalName,
              disambiguation: disambiguation, googleKeywords: googleKeywords,
              automaticWikipedia: [11, 12].contains(version ?? -1) ? wikipediaPolicy == .allowed : automaticWikipedia,
              wikipediaCandidates: wikipediaCandidates, wikipediaPolicy: [11, 12].contains(version ?? -1) ? wikipediaPolicy : nil)
    }
    func topics(for result: RecognitionResult) -> WikipediaTopics? {
        let topics = effectiveWikipediaCandidates
        guard validForIdentity, automaticWikipedia, wikipediaPolicy == nil || wikipediaPolicy == .allowed, result.searchRestriction == nil, !result.names.isEmpty,
              !topics.isEmpty, !result.barcodes.contains(where: Self.containsPrivateContext) else { return nil }
        let context = result.names + [result.summary] + result.text
        // Transcription is not a query. A public package's company address or
        // contact URL must not suppress its independently validated public brand.
        // Explicit private-document context still blocks, including restored cards.
        guard context.count <= 100, context.reduce(0, { $0 + $1.utf8.count }) <= 32_768,
              !context.contains(where: Self.containsPrivateContext),
              !disambiguation.contains(where: { WikipediaSubject.containsSensitiveContent($0) || ProductNameSafety.containsAddress($0) }),
              !disambiguation.isEmpty || topics.allSatisfy({ $0.kind == .brand }) else { return nil }
        let candidates = topics.compactMap { topic -> WikipediaTopics.Candidate? in
            guard let entity = entity(for: topic) else { return nil }
            return .init(topic: topic.topic, kind: topic.kind, evidence: entity.name,
                aliases: entity.terms.filter { WikipediaSubject.normalize($0) != WikipediaSubject.normalize(topic.topic) })
        }.sorted { $0.kind == .series && $1.kind == .brand }
        return WikipediaTopics(category: category, automaticWikipediaAllowed: true, classTerms: disambiguation,
            candidates: candidates, matchScope: .structuredIdentity)
    }
}

// Archives keep the legacy boolean plus an optional new policy. Decoding an old
// archive never invents permission. Wire versions are checked separately below.
extension SearchIdentity {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        category = try c.decode(PublicSearchQuery.Category.self, forKey: .category)
        subject = try c.decodeIfPresent(Entity.self, forKey: .subject)
        brand = try c.decodeIfPresent(Entity.self, forKey: .brand)
        manufacturer = try c.decodeIfPresent(Entity.self, forKey: .manufacturer)
        series = try c.decodeIfPresent(Entity.self, forKey: .series)
        product = try c.decodeIfPresent(Entity.self, forKey: .product)
        modelVersion = try c.decodeIfPresent(Entity.self, forKey: .modelVersion)
        formalName = try c.decodeIfPresent(Entity.self, forKey: .formalName)
        disambiguation = try c.decode([String].self, forKey: .disambiguation)
        googleKeywords = try c.decode([String].self, forKey: .googleKeywords)
        automaticWikipedia = try c.decodeIfPresent(Bool.self, forKey: .automaticWikipedia) ?? false
        wikipediaCandidates = try c.decode([Topic].self, forKey: .wikipediaCandidates)
        wikipediaPolicy = try c.decodeIfPresent(WikipediaPolicy.self, forKey: .wikipediaPolicy)
    }
}

/// Enough to replay source admission without storing OCR or the model response.
public struct SearchKeywordEvidence: Codable, Equatable, Hashable, Sendable {
    public struct Source: Codable, Equatable, Hashable, Sendable {
        public enum Kind: String, Codable, Sendable { case name, alias, disambiguation }
        public let field: SearchParseDiagnostic.Field
        public let kind: Kind
        public let index: Int
        public let text: String
        public let basis: [SearchIdentity.Basis]
    }
    public enum Match: String, Codable, Sendable { case singleSource, composedSources, unmatched }
    public struct Keyword: Codable, Equatable, Hashable, Sendable {
        public let index: Int
        public let text: String
        public let match: Match
        public let sourceIndices: [Int]
    }
    public let category: PublicSearchQuery.Category
    public let sources: [Source]
    public let keywords: [Keyword]
    public let automaticWikipedia: Bool
    public let wikipediaCandidates: [SearchIdentity.Topic]
    public var wikipediaPolicy: SearchIdentity.WikipediaPolicy? = nil
}

/// Exact normalized token coverage, not fuzzy similarity or OCR inference.
enum SearchKeywordOrigin {
    static func key(_ value: String) -> String { tokens(value).joined(separator: "\u{1f}") }
    static func tokens(_ value: String) -> [String] {
        let text = WikipediaSubject.normalize(value)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"(?<=[\p{L}\p{N}])'(?=[\p{L}\p{N}])"#, with: "", options: .regularExpression)
        var result: [String] = [], word = ""
        func flush() { if !word.isEmpty { result.append(word); word = "" } }
        for scalar in text.unicodeScalars {
            if scalar.properties.isIdeographic {
                flush(); result.append(String(scalar))
            } else if CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar) {
                word.unicodeScalars.append(scalar)
            } else {
                flush()
                // Formatting punctuation may separate source terms. Meaningful
                // model/name symbols remain tokens: C++ never becomes C.
                if !CharacterSet.whitespaces.contains(scalar) && !".'-·・()".unicodeScalars.contains(scalar) {
                    result.append(String(scalar))
                }
            }
        }
        flush(); return result
    }
    static func match(_ keyword: String, sources: [SearchKeywordEvidence.Source]) -> (kind: SearchKeywordEvidence.Match, sources: [Int]) {
        guard keyword.count <= 64, ProductNameSafety.accepts(keyword), sources.count <= 30 else { return (.unmatched, []) }
        let query = tokens(keyword), terms = sources.map { tokens($0.text) }
        guard !query.isEmpty, query.count <= 64 else { return (.unmatched, []) }
        // Preserve the old ability to select a contiguous phrase from ONE source,
        // with whole Latin tokens. No cross-source single-character word building.
        for (index, term) in terms.enumerated() where term.count >= query.count {
            if (0...(term.count - query.count)).contains(where: { Array(term[$0..<($0 + query.count)]) == query }) {
                return (.singleSource, [index])
            }
        }
        // A composition must consume complete source names/aliases/class terms.
        // Dynamic programming handles shared prefixes without greedy truncation.
        var paths = [[Int]?](repeating: nil, count: query.count + 1)
        paths[0] = []
        for start in 0..<query.count {
            guard let path = paths[start] else { continue }
            for (index, term) in terms.enumerated() where !term.isEmpty && start + term.count <= query.count {
                let end = start + term.count
                if paths[end] == nil && Array(query[start..<end]) == term { paths[end] = path + [index] }
            }
        }
        guard let path = paths[query.count] else { return (.unmatched, []) }
        return (.composedSources, path)
    }
}

/// Restricted same-image QR fields. Unknown lines/URLs never travel to the model.
/// This is not an instruction sanitizer: all retained values stay untrusted data.
public struct BarcodeSearchEvidence: Equatable, Sendable {
    public let fields: [String: String]
    public init?(decodedValues: [String], candidateScoped: Bool = false) {
        guard decodedValues.count <= 32, decodedValues.allSatisfy({ $0.utf8.count <= 4096 }) else { return nil }
        let keys = ["品名":"product", "產品名稱":"product", "商品名稱":"product", "product name":"product",
                    "品牌":"brand", "廠牌":"brand", "brand":"brand", "型號":"model", "model":"model"]
        var fields: [String: String] = [:]
        var rejectedFields = Set<String>()
        for payload in decodedValues {
            // Do not promote a public-looking field out of a private record.
            guard candidateScoped || payload.range(of: #"(?i)患者|病人|病歷|病历|處方箋|處方籤|用藥紀錄|醫療紀錄|姓名|收件人|寄件人|帳號|帳戶|密碼|身分證|身份證|信用卡|\b(patient|password|account|recipient|private)\b"#, options: .regularExpression) == nil else { return nil }
            for line in payload.components(separatedBy: .newlines) {
                guard let colon = line.firstIndex(where: { $0 == ":" || $0 == "：" }),
                      let key = keys[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] else { continue }
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                let safe = candidateScoped ? CandidateQuerySafety.accepts(value) : ProductNameSafety.accepts(value)
                if candidateScoped {
                    if !safe || (fields[key] != nil && fields[key] != value) {
                        rejectedFields.insert(key); fields.removeValue(forKey: key); continue
                    }
                    if rejectedFields.contains(key) { continue }
                } else {
                    guard safe, fields[key] == nil || fields[key] == value else { return nil }
                }
                fields[key] = value
            }
        }
        guard !fields.isEmpty else { return nil }
        self.fields = fields
    }
}

/// Responses API schema; nullable fields mean unknown, not inferred defaults.
/// Its inclusion is tested offline. Account/route acceptance still requires a
/// completed authorized live request; unsupported capability never triggers retry.
public enum CameraAnswerSchema {
    public static var format: [String: Any] { SemanticSearchEntities17.format }
}

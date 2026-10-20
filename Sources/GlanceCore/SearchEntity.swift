import Foundation
import CryptoKit

/// Wire limits for new v16 responses. Legacy stored cards retain their old rules.
enum EntityContract16 {
    static let version = 16, names = 1, name = 64, aliases = 3, entities = 4
    static let summary = 1600, textLines = 32, textLine = 1000, source = 120, contexts = 3, google = 160
    static func length(_ value: String) -> Int { value.unicodeScalars.count }
    static func accepts(_ value: String, limit: Int = name) -> Bool {
        (1...limit).contains(length(value)) && CandidateQuerySafety.accepts(value, limit: limit, minimum: 1)
    }
    static func envelope(names: [String], summary: String, text: [String]) -> Bool {
        names.count <= self.names && names.allSatisfy { (1...name).contains(length($0)) && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } &&
        length(summary) <= self.summary && text.count <= textLines && text.allSatisfy { length($0) <= textLine }
    }
}

/// v14 separates faithful transcription, model identity and independently verified references.
/// A model alias is a search proposal; it is never Wikipedia evidence by itself.
public struct SearchEntity: Codable, Equatable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable { case central, related, text }
    public enum Kind: String, Codable, Sendable { case product, series, brand, company, species, object, person }
    public enum Relation: String, Codable, Sendable { case none, brand_of, series_of, manufacturer_of }
    public let id: Int
    public let role: Role
    public let kind: Kind
    public let name: String
    public let aliases: [String]
    public let status: SearchCandidate.Status
    public let basis: SearchCandidate.Basis
    public let sourceRole: SearchCandidate.SourceRole
    public let sourceText: String
    public let contextText: [String]
    public let relation: Relation
    public let relatedTo: Int
    enum CodingKeys: String, CodingKey {
        case id, role, kind, name, aliases, status, basis, relation
        case sourceRole = "source_role", sourceText = "source_text", contextText = "context_text", relatedTo = "related_to"
    }
    public init(id: Int = 0, role: Role = .central, kind: Kind, name: String, aliases: [String] = [],
                status: SearchCandidate.Status = .ready, basis: SearchCandidate.Basis = .text,
                sourceRole: SearchCandidate.SourceRole = .product_label, sourceText: String = "",
                contextText: [String] = [], relation: Relation = .none, relatedTo: Int = -1) {
        self.id = id; self.role = role; self.kind = kind; self.name = name; self.aliases = aliases
        self.status = status; self.basis = basis; self.sourceRole = sourceRole; self.sourceText = sourceText
        self.contextText = contextText; self.relation = relation; self.relatedTo = relatedTo
    }
    public var names: [String] { [name] + aliases }
    public func validation(in result: RecognitionResult) -> SearchCandidate.Rejection {
        if result.searchContractVersion == 17 { return SemanticSearchEntities17.accepts(self, in: result) ? .accepted : .unsafeValue }
        if [15, 16].contains(result.searchContractVersion ?? -1) { return EntityValidation15.evaluate(self, in: result).outcome }
        return legacyValidation(in: result)
    }
    private func legacyValidation(in result: RecognitionResult) -> SearchCandidate.Rejection {
        guard status == .ready else { return status == .personal_data ? .personalData : status == .conflict ? .conflict : .uncertain }
        guard sourceRole != .private_identity, sourceRole != .unknown else { return sourceRole == .private_identity ? .personalData : .uncertain }
        guard (0..<4).contains(id), aliases.count <= 3, names.allSatisfy({ CandidateQuerySafety.accepts($0) }),
              Set(names.map(SearchCandidate.normalized)).count == names.count,
              sourceText.count <= 120, contextText.count <= 3,
              contextText.allSatisfy({ CandidateQuerySafety.accepts($0) }),
              Set(contextText.map(SearchCandidate.normalized)).count == contextText.count else { return .unsafeValue }
        guard (role == .central && id == 0 && relation == .none && relatedTo == -1) ||
              (role == .text && relation == .none && relatedTo == -1) ||
              (role == .related && relatedTo == 0 && id != 0 &&
               ((kind == .brand && relation == .brand_of) || (kind == .series && relation == .series_of) ||
                (kind == .company && relation == .manufacturer_of))) else { return .malformed }
        func anchored(_ value: String) -> Bool {
            result.text.contains { $0.contains(value) && !CandidateQuerySafety.privateAssociation($0, containing: value) }
        }
        guard contextText.allSatisfy(anchored) else { return .missingSource }
        if role == .text && basis != .text { return .missingSource }
        switch basis {
        case .text:
            guard sourceRole == .public_text || sourceRole == .product_label,
                  CandidateQuerySafety.accepts(sourceText, limit: 120), anchored(sourceText) else { return .missingSource }
        case .qr:
            guard role != .text, kind == .product || kind == .brand || kind == .series,
                  sourceRole == .product_label, result.candidateQRFields?.values.contains(sourceText) == true,
                  CandidateQuerySafety.accepts(sourceText) else { return .missingSource }
        case .logo:
            guard role != .text, kind == .brand, sourceRole == .product_label,
                  sourceText.isEmpty, contextText.isEmpty else { return .missingSource }
        case .appearance:
            guard role == .central, [.product, .series, .object, .species].contains(kind),
                  sourceRole == .object_appearance, sourceText.isEmpty, contextText.isEmpty else { return .missingSource }
        }
        if kind == .person {
            guard role != .related, basis == .text, sourceRole == .public_text,
                  independentClues(contextText).count >= 2 else { return .personEvidence }
        }
        return .accepted
    }
    func independentClues(_ values: [String]) -> [String] {
        var clues: [String] = []
        for value in values where value.count >= 4 && value.range(of: #"^(?:著名|知名|資深|台灣|臺灣)?(?:作家|作者|教授|醫師|演員|藝術家|學者)$"#, options: .regularExpression) == nil && !names.contains(where: { EntityWikipediaPage.contains(value, $0) || EntityWikipediaPage.contains($0, value) }) {
            if clues.allSatisfy({ !EntityWikipediaPage.contains($0, value) && !EntityWikipediaPage.contains(value, $0) }) { clues.append(value) }
        }
        return clues
    }
    public static func matching(_ result: RecognitionResult) -> [Self] {
        if result.searchContractVersion == 17 { return SemanticSearchEntities17.matching(result) }
        guard result.usesEntitySearch, let values = result.searchEntities, values.count <= 4,
              result.text.count <= 32, result.text.allSatisfy({ $0.count <= 1000 }),
              Set(values.map(\.id)).count == values.count else { return [] }
        if result.searchContractVersion == 16 && !EntityContract16.envelope(names: result.names, summary: result.summary, text: result.text) { return [] }
        let accepted = values.compactMap { value -> Self? in
            if [15, 16].contains(result.searchContractVersion ?? -1) { return EntityValidation15.evaluate(value, in: result).entity }
            return value.validation(in: result) == .accepted ? value : nil
        }
        let central = accepted.first { $0.role == .central }
        return accepted.filter { value in
            value.role != .related || (central?.id == value.relatedTo && [.product, .series].contains(central!.kind))
        }.sorted { $0.id < $1.id }
    }
    public static func cacheKey(for result: RecognitionResult) -> String {
        "entities-v\(result.searchContractVersion ?? -1):" + SHA256.hash(data: try! JSONEncoder.sorted.encode(matching(result))).map { String(format: "%02x", $0) }.joined()
    }
    /// Whole supplied phrases only; no arbitrary OCR fallback or synonym splitting.
    static func googleTerms(for result: RecognitionResult) -> String? {
        if result.searchContractVersion == 17 {
            let entities = SemanticSearchEntities17.matching(result)
            return (entities.first { $0.role == .central } ?? entities.first { $0.role == .text })?.name
        }
        let values = matching(result)
        guard let primary = values.first(where: { $0.role == .central }) ?? values.first(where: { $0.role == .text }) else { return nil }
        let related = values.filter { $0.role == .related && $0.relatedTo == primary.id && $0.kind != .company }
        let phrases = related.map(\.name) + [primary.name] + Array(primary.aliases.prefix(1))
        var selected: [String] = []
        for phrase in phrases where !selected.contains(where: { EntityWikipediaPage.contains($0, phrase) }) {
            selected.removeAll { EntityWikipediaPage.contains(phrase, $0) }; selected.append(phrase)
        }
        let query = selected.joined(separator: " ")
        if result.searchContractVersion == 16 {
            if EntityContract16.length(query) <= EntityContract16.google { return query }
            // Start with the exact primary identity when optional phrases exceed
            // the budget. Never truncate a phrase or lose the primary to an alias.
            var bounded = [primary.name]
            for phrase in related.map(\.name) + Array(primary.aliases.prefix(1)) {
                if bounded.contains(where: { EntityWikipediaPage.contains($0, phrase) }) { continue }
                let proposed = bounded + [phrase]
                if EntityContract16.length(proposed.joined(separator: " ")) <= EntityContract16.google { bounded = proposed }
            }
            return bounded.joined(separator: " ")
        }
        return query.count <= 160 ? query : nil
    }
}
private extension JSONEncoder {
    static var sorted: JSONEncoder { let value = JSONEncoder(); value.outputFormatting = .sortedKeys; return value }
}

public struct EntitySearchDiagnostic: Codable, Equatable, Hashable, Sendable {
    public let index: Int
    public let outcome: SearchCandidate.Rejection
    public var entityID: Int? = nil
    public var role: SearchEntity.Role? = nil
    public var kind: SearchEntity.Kind? = nil
    public var basis: SearchCandidate.Basis? = nil
    public var sourceRole: SearchCandidate.SourceRole? = nil
    public var fieldIssues: [EntityFieldIssue]? = nil
    public var adjustments: [String]? = nil
}

enum EntitySearchContract {
    static func parse(_ root: [String: Any], qr: BarcodeSearchEvidence?) -> RecognitionResult {
        if [15, 16].contains(root["schema_version"] as? Int ?? -1) { return EntityValidation15.parse(root, qr: qr) }
        let names = root["names"] as? [String] ?? [], summary = root["summary"] as? String ?? "", text = root["text"] as? [String] ?? []
        let base = RecognitionResult(names: Array(names.prefix(32)).map { String($0.prefix(1000)) }, summary: String(summary.prefix(1600)),
            text: Array(text.prefix(32)).map { String($0.prefix(1000)) }, searchContractVersion: 14, candidateQRFields: qr?.fields, searchEntities: [])
        let allowed: Set<String> = ["schema_version", "names", "summary", "text", "search_entities"]
        guard Set(root.keys) == allowed, root["names"] is [String], root["summary"] is String, root["text"] is [String],
              names.count <= 32, text.count <= 32, (names + text).allSatisfy({ $0.count <= 1000 }), summary.count <= 1600,
              let rows = root["search_entities"] as? [Any], rows.count <= 4 else { return base }
        var entities: [SearchEntity] = [], diagnostics: [EntitySearchDiagnostic] = [], ids = Set<Int>()
        let fields: Set<String> = ["id", "role", "kind", "name", "aliases", "status", "basis", "source_role", "source_text", "context_text", "relation", "related_to"]
        for (index, row) in rows.enumerated() {
            guard let object = row as? [String: Any], Set(object.keys) == fields, JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object), data.count <= 5000,
                  let value = try? JSONDecoder().decode(SearchEntity.self, from: data) else {
                diagnostics.append(.init(index: index, outcome: .malformed)); continue
            }
            let outcome = ids.insert(value.id).inserted ? value.validation(in: base) : .duplicate
            diagnostics.append(.init(index: index, outcome: outcome))
            if outcome == .accepted { entities.append(value) }
        }
        let provisional = RecognitionResult(names: base.names, summary: base.summary, text: base.text, searchContractVersion: 14,
            candidateQRFields: qr?.fields, searchEntities: entities)
        let valid = SearchEntity.matching(provisional)
        diagnostics = diagnostics.map { value in
            guard value.outcome == .accepted, let row = rows[value.index] as? [String: Any], let id = row["id"] as? Int,
                  !valid.contains(where: { $0.id == id }) else { return value }
            return .init(index: value.index, outcome: .missingSource)
        }
        return RecognitionResult(names: base.names, summary: base.summary, text: base.text, searchContractVersion: 14,
            candidateQRFields: qr?.fields, searchEntities: valid, entityDiagnostics: diagnostics)
    }
    static var format: [String: Any] {
        func object(_ p: [String: Any]) -> [String: Any] { ["type": "object", "properties": p, "required": p.keys.sorted(), "additionalProperties": false] }
        func array(_ items: [String: Any], _ max: Int) -> [String: Any] { ["type": "array", "items": items, "maxItems": max] }
        func string(_ max: Int, minimum: Int = 0) -> [String: Any] { ["type": "string", "minLength": minimum, "maxLength": max] }
        func values(_ v: [String]) -> [String: Any] { ["type": "string", "enum": v] }
        func described(_ schema: [String: Any], _ description: String) -> [String: Any] {
            schema.merging(["description": description]) { _, new in new }
        }
        let entity = object([
            "id": described(["type": "integer", "minimum": 0, "maximum": EntityContract16.entities - 1], "Unique IDs; central uses 0 and other entries use successive IDs."),
            "role": described(values(["central", "related", "text"]), "central is the central subject search identity; related is its brand, series or manufacturer; text is an independent public entity in the transcription."),
            "kind": values(["product", "series", "brand", "company", "species", "object", "person"]),
            "name": described(string(EntityContract16.name), "Nonempty when ready. The central identity must be consistent with the subject; a supported brand, series or official alias is allowed and need not exactly match its display name."),
            "aliases": described(array(string(EntityContract16.name), EntityContract16.aliases), "Complete official aliases for the same entity, most reliable first; [] if absent."),
            "status": described(values(["ready", "personal_data", "uncertain", "conflict"]), "Only ready is searchable. Mark personal data, uncertainty or conflicting evidence per entity; do not suppress other independent entities."),
            "basis": described(values(["text", "qr", "logo", "appearance"]), "text quotes the transcription; qr quotes supplied fields; logo identifies a brand or company; appearance identifies the central object or its brand."),
            "source_role": described(values(["public_text", "product_label", "object_appearance", "private_identity", "unknown"]), "For text use public_text or product_label; for qr use product_label; for appearance use object_appearance. private_identity and unknown are not searchable."),
            "source_text": described(string(EntityContract16.source), "For text or qr provide an exact source anchor. For logo or appearance leave empty when no textual evidence exists."),
            "context_text": described(array(string(EntityContract16.name, minimum: 1), EntityContract16.contexts), "Supporting quotations from the transcription; [] if absent. A person requires at least two independent public clues beyond repetitions of the identity name."),
            "relation": described(values(["none", "brand_of", "series_of", "manufacturer_of"]), "related points only to central product or series with ID 0; use brand_of, series_of or manufacturer_of for the corresponding kind. All others use none. Ownership, importing or distribution alone does not prove manufacture."),
            "related_to": described(["type": "integer", "minimum": -1, "maximum": 0], "Use 0 for related and -1 otherwise.")])
        return ["type": "json_schema", "name": "glance_camera_v16", "strict": true, "schema": object([
            "schema_version": ["type": "integer", "enum": [EntityContract16.version]],
            "names": described(array(string(EntityContract16.name, minimum: 1), EntityContract16.names), "One central subject name; [] when it cannot be identified."),
            "summary": string(EntityContract16.summary), "text": array(string(EntityContract16.textLine), EntityContract16.textLines),
            "search_entities": described(array(entity, EntityContract16.entities), "Use [] if no reliable search entity exists. All fields are required. Use an empty string or [] for absent values, never null.")])]
    }
}

/// Closed field-level explanations; never embed rejected names, OCR, or credentials here.
public struct EntityFieldIssue: Codable, Equatable, Hashable, Sendable {
    public enum Field: String, Codable, Sendable { case root, id, status, sourceRole, name, aliases, sourceText, contextText, relation, dependency }
    public enum Rule: String, Codable, Sendable {
        case malformedEnvelope, malformedEntity, duplicateID, outOfBounds, unsafeSyntax, privateOccurrence
        case modelPersonalData, modelUncertain, modelConflict, unknownSource, privateSource
        case relationShape, textBasisRequired, sourceRoleMismatch, sourceAnchorMissing, contextAnchorMissing
        case qrFieldMissing, visualKindMismatch, personCluesMissing, centralEntityRejected
    }
    public let field: Field
    public let rule: Rule
    public var index: Int? = nil
    public let outcome: SearchCandidate.Rejection
}

/// v15 normalization, with explicit v16 bounds. Older stored cards retain their rules.
enum EntityValidation15 {
    struct Assessment {
        let entity: SearchEntity?
        let issues: [EntityFieldIssue]
        let adjustments: [String]
        var outcome: SearchCandidate.Rejection { issues.first?.outcome ?? .accepted }
    }
    static func whitespace(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    /// Only separators introduced between adjacent Han lines may disappear.
    /// Whitespace within an original line, Latin words, digits and punctuation stay intact.
    struct HanLineWindow {
        let text: String
        let ranges: [Range<Int>]
        // Stable physical spans keep a private occurrence private when a shorter
        // overlapping window no longer contains the preceding label.
        func occurrences(of needle: String, startingAt line: Int) -> [String] {
            let value = text as NSString
            var offset = 0, result: [String] = []
            while offset < value.length {
                let found = value.range(of: needle, range: NSRange(location: offset, length: value.length - offset))
                guard found.location != NSNotFound else { break }
                let end = found.location + found.length
                if let first = ranges.firstIndex(where: { $0.contains(found.location) }),
                   let last = ranges.firstIndex(where: { $0.contains(end - 1) }) {
                    result.append("\(line + first):\(found.location - ranges[first].lowerBound)-\(line + last):\(end - ranges[last].lowerBound)")
                }
                offset = found.location + max(found.length, 1)
            }
            return result
        }
    }
    static func hanLineWindows(_ lines: ArraySlice<String>) -> [HanLineWindow] {
        guard let first = lines.first else { return [] }
        func han(_ character: Character?) -> Bool {
            guard let character else { return false }
            return String(character).range(of: #"^\p{Han}$"#, options: .regularExpression) != nil
        }
        var windows = [HanLineWindow(text: first, ranges: [0..<first.utf16.count])], previous = first
        for line in lines.dropFirst() {
            let separators = han(previous.last) && han(line.first) ? [" ", ""] : [" "]
            windows = windows.flatMap { prefix in separators.map { separator in
                let offset = prefix.text.utf16.count + separator.utf16.count
                return HanLineWindow(text: prefix.text + separator + line, ranges: prefix.ranges + [offset..<(offset + line.utf16.count)])
            } }
            previous = line
        }
        return windows
    }
    static func anchor(_ value: String, in text: [String], allowHanLineJoins: Bool = false) -> (matched: Bool, privateOccurrence: Bool, joinedHanLines: Bool) {
        let needle = whitespace(value)
        guard !needle.isEmpty else { return (false, false, false) }
        let lines = text.flatMap { $0.components(separatedBy: .newlines) }.map(whitespace).filter { !$0.isEmpty }
        var privateMatch = false, privateSpans = Set<String>()
        // Only contiguous lines, never an unordered bag of words or translated source.
        for start in lines.indices {
            for count in 1...min(3, lines.count - start) {
                let priorLabel = start > 0 && lines[start - 1].range(of: #"[:：=]$"#, options: .regularExpression) != nil ? lines[start - 1] + " " : ""
                let slice = lines[start..<(start + count)]
                let window = priorLabel + slice.joined(separator: " ")
                if window.contains(needle) {
                    if CandidateQuerySafety.privateAssociation(window, containing: needle) { privateMatch = true }
                    else { return (true, false, false) }
                } else if allowHanLineJoins {
                    let matches = hanLineWindows(slice).filter { $0.text.contains(needle) }
                    guard !matches.isEmpty else { continue }
                    // Retain every original character, label and clause around the
                    // occurrence; only the eligible inter-line separators differ.
                    if matches.contains(where: { CandidateQuerySafety.privateAssociation(priorLabel + $0.text, containing: needle) }) {
                        privateMatch = true
                        for match in matches { privateSpans.formUnion(match.occurrences(of: needle, startingAt: start)) }
                    } else if matches.contains(where: { !$0.occurrences(of: needle, startingAt: start).allSatisfy(privateSpans.contains) }) {
                        return (true, false, true)
                    }
                }
            }
        }
        return (false, privateMatch, false)
    }
    static func evaluate(_ value: SearchEntity, in result: RecognitionResult) -> Assessment {
        let modern = result.searchContractVersion == EntityContract16.version
        func length(_ text: String) -> Int { modern ? EntityContract16.length(text) : text.count }
        func accepts(_ text: String, limit: Int = EntityContract16.name) -> Bool {
            modern ? EntityContract16.accepts(text, limit: limit) : CandidateQuerySafety.accepts(text, limit: limit)
        }
        var issues: [EntityFieldIssue] = [], changes: [String] = []
        func fail(_ field: EntityFieldIssue.Field, _ rule: EntityFieldIssue.Rule, _ outcome: SearchCandidate.Rejection, index: Int? = nil) {
            issues.append(.init(field: field, rule: rule, index: index, outcome: outcome))
        }
        if value.status != .ready {
            let outcome: SearchCandidate.Rejection = value.status == .personal_data ? .personalData : value.status == .conflict ? .conflict : .uncertain
            fail(.status, value.status == .personal_data ? .modelPersonalData : value.status == .conflict ? .modelConflict : .modelUncertain, outcome)
            return .init(entity: nil, issues: issues, adjustments: [])
        }
        if value.sourceRole == .private_identity || value.sourceRole == .unknown {
            fail(.sourceRole, value.sourceRole == .private_identity ? .privateSource : .unknownSource, value.sourceRole == .private_identity ? .personalData : .uncertain)
            return .init(entity: nil, issues: issues, adjustments: [])
        }
        if !(0..<4).contains(value.id) { fail(.id, .outOfBounds, .unsafeValue) }
        let name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name != value.name { changes.append("nameOuterWhitespace") }
        if length(value.name) > EntityContract16.name || !accepts(name) { fail(.name, .unsafeSyntax, .unsafeValue) }
        if value.aliases.count > 3 { fail(.aliases, .outOfBounds, .unsafeValue) }
        var aliases: [String] = [], seen = Set([SearchCandidate.normalized(name)])
        for (index, raw) in value.aliases.prefix(4).enumerated() {
            let alias = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if length(raw) > EntityContract16.name { fail(.aliases, .outOfBounds, .unsafeValue, index: index); continue }
            if alias.isEmpty { changes.append("emptyAliasRemoved"); continue }
            guard accepts(alias) else { fail(.aliases, .unsafeSyntax, .unsafeValue, index: index); continue }
            if !seen.insert(SearchCandidate.normalized(alias)).inserted { changes.append("duplicateAliasRemoved"); continue }
            if alias != raw { changes.append("aliasOuterWhitespace") }; aliases.append(alias)
        }
        if length(value.sourceText) > EntityContract16.source { fail(.sourceText, .outOfBounds, .unsafeValue) }
        if value.contextText.count > 3 { fail(.contextText, .outOfBounds, .unsafeValue) }
        let source = whitespace(value.sourceText)
        if source != value.sourceText { changes.append("sourceWhitespace") }
        var contexts: [String] = [], contextSeen = Set<String>()
        for (index, raw) in value.contextText.prefix(4).enumerated() {
            let context = whitespace(raw)
            guard length(raw) <= EntityContract16.name, accepts(context) else {
                fail(.contextText, .unsafeSyntax, .unsafeValue, index: index); continue
            }
            let match = anchor(context, in: result.text, allowHanLineJoins: modern)
            if !match.matched { fail(.contextText, match.privateOccurrence ? .privateOccurrence : .contextAnchorMissing, .missingSource, index: index) }
            if match.joinedHanLines { changes.append("contextHanLineJoin") }
            if !contextSeen.insert(SearchCandidate.normalized(context)).inserted { changes.append("duplicateContextRemoved"); continue }
            if context != raw { changes.append("contextWhitespace") }; contexts.append(context)
        }
        let shape = (value.role == .central && value.id == 0 && value.relation == .none && value.relatedTo == -1) ||
            (value.role == .text && value.relation == .none && value.relatedTo == -1) ||
            (value.role == .related && value.relatedTo == 0 && value.id != 0 &&
             ((value.kind == .brand && value.relation == .brand_of) || (value.kind == .series && value.relation == .series_of) ||
              (value.kind == .company && value.relation == .manufacturer_of)))
        if !shape { fail(.relation, .relationShape, .malformed) }
        if value.role == .text && value.basis != .text { fail(.sourceRole, .textBasisRequired, .missingSource) }
        func requireTextSource() {
            guard accepts(source, limit: EntityContract16.source) else { fail(.sourceText, .unsafeSyntax, .missingSource); return }
            let match = anchor(source, in: result.text, allowHanLineJoins: modern)
            if !match.matched { fail(.sourceText, match.privateOccurrence ? .privateOccurrence : .sourceAnchorMissing, .missingSource) }
            if match.joinedHanLines { changes.append("sourceHanLineJoin") }
        }
        var effectiveBasis = value.basis
        // A text-bearing product label can be evaluated as text even when the
        // model called it a logo. This never admits an unanchored visual product.
        if modern, value.basis == .logo, value.role == .central,
           [.product, .series].contains(value.kind), value.sourceRole == .product_label,
           !source.isEmpty {
            effectiveBasis = .text; changes.append("logoProductValidatedAsText")
        }
        switch effectiveBasis {
        case .text:
            if value.sourceRole != .public_text && value.sourceRole != .product_label { fail(.sourceRole, .sourceRoleMismatch, .missingSource) }
            requireTextSource()
        case .qr:
            if value.role == .text || ![.product, .brand, .series].contains(value.kind) { fail(.sourceRole, .visualKindMismatch, .missingSource) }
            if value.sourceRole != .product_label { fail(.sourceRole, .sourceRoleMismatch, .missingSource) }
            if !accepts(source, limit: modern ? EntityContract16.source : 64) || result.candidateQRFields?.values.contains(source) != true { fail(.sourceText, .qrFieldMissing, .missingSource) }
        case .logo:
            if value.role == .text || ![.brand, .company].contains(value.kind) { fail(.sourceRole, .visualKindMismatch, .missingSource) }
            if ![.product_label, .object_appearance].contains(value.sourceRole) { fail(.sourceRole, .sourceRoleMismatch, .missingSource) }
            if !source.isEmpty { requireTextSource() }
        case .appearance:
            let kind = (value.role == .central && [.product, .series, .object, .species].contains(value.kind)) ||
                (value.role == .related && value.kind == .brand)
            if !kind { fail(.sourceRole, .visualKindMismatch, .missingSource) }
            if value.sourceRole != .object_appearance { fail(.sourceRole, .sourceRoleMismatch, .missingSource) }
            if !source.isEmpty { requireTextSource() }
        }
        let normalized = SearchEntity(id: value.id, role: value.role, kind: value.kind, name: name, aliases: aliases,
            status: value.status, basis: effectiveBasis, sourceRole: value.sourceRole, sourceText: source,
            contextText: contexts, relation: value.relation, relatedTo: value.relatedTo)
        if value.kind == .person && (value.role == .related || value.basis != .text || value.sourceRole != .public_text || normalized.independentClues(contexts).count < 2) {
            fail(.contextText, .personCluesMissing, .personEvidence)
        }
        return .init(entity: issues.isEmpty ? normalized : nil, issues: issues, adjustments: Array(Set(changes)).sorted())
    }
    static func parse(_ root: [String: Any], qr: BarcodeSearchEvidence?) -> RecognitionResult {
        let names = root["names"] as? [String] ?? [], summary = root["summary"] as? String ?? "", text = root["text"] as? [String] ?? []
        let version = root["schema_version"] as? Int == 16 ? 16 : 15
        let bounded = version == 16 ? EntityContract16.envelope(names: names, summary: summary, text: text) :
            names.count <= 32 && text.count <= 32 && (names + text).allSatisfy({ $0.count <= 1000 }) && summary.count <= 1600
        func result(_ entities: [SearchEntity], _ diagnostics: [EntitySearchDiagnostic]) -> RecognitionResult {
            .init(names: Array(names.prefix(32)).map { String($0.prefix(1000)) }, summary: String(summary.prefix(1600)),
                  text: Array(text.prefix(32)).map { String($0.prefix(1000)) }, searchContractVersion: version,
                  candidateQRFields: qr?.fields, searchEntities: entities, entityDiagnostics: diagnostics)
        }
        let fields: Set<String> = ["id", "role", "kind", "name", "aliases", "status", "basis", "source_role", "source_text", "context_text", "relation", "related_to"]
        guard Set(root.keys) == ["schema_version", "names", "summary", "text", "search_entities"],
              root["names"] is [String], root["summary"] is String, root["text"] is [String],
              bounded,
              let rows = root["search_entities"] as? [Any], rows.count <= 4 else {
            var diagnostic = EntitySearchDiagnostic(index: -1, outcome: .malformed)
            diagnostic.fieldIssues = [.init(field: .root, rule: .malformedEnvelope, outcome: .malformed)]
            return result([], [diagnostic])
        }
        let base = result([], []); var accepted: [SearchEntity] = [], diagnostics: [EntitySearchDiagnostic] = [], ids = Set<Int>()
        for (index, row) in rows.enumerated() {
            guard let object = row as? [String: Any], Set(object.keys) == fields, JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object), data.count <= 5000,
                  let value = try? JSONDecoder().decode(SearchEntity.self, from: data) else {
                var diagnostic = EntitySearchDiagnostic(index: index, outcome: .malformed)
                diagnostic.fieldIssues = [.init(field: .root, rule: .malformedEntity, outcome: .malformed)]
                diagnostics.append(diagnostic); continue
            }
            let assessment = evaluate(value, in: base)
            let duplicate = !ids.insert(value.id).inserted
            var diagnostic = EntitySearchDiagnostic(index: index, outcome: duplicate ? .duplicate : assessment.outcome)
            diagnostic.entityID = value.id; diagnostic.role = value.role; diagnostic.kind = value.kind
            diagnostic.basis = value.basis; diagnostic.sourceRole = value.sourceRole
            diagnostic.fieldIssues = duplicate ? [.init(field: .id, rule: .duplicateID, outcome: .duplicate)] : assessment.issues
            diagnostic.adjustments = assessment.adjustments
            diagnostics.append(diagnostic)
            if !duplicate, let normalized = assessment.entity { accepted.append(normalized) }
        }
        let provisional = result(accepted, []), valid = SearchEntity.matching(provisional)
        diagnostics = diagnostics.map { diagnostic in
            guard diagnostic.outcome == .accepted, !valid.contains(where: { $0.id == diagnostic.entityID }) else { return diagnostic }
            var next = EntitySearchDiagnostic(index: diagnostic.index, outcome: .missingSource)
            next.entityID = diagnostic.entityID; next.role = diagnostic.role; next.kind = diagnostic.kind
            next.basis = diagnostic.basis; next.sourceRole = diagnostic.sourceRole; next.adjustments = diagnostic.adjustments
            next.fieldIssues = [.init(field: .dependency, rule: .centralEntityRejected, outcome: .missingSource)]
            return next
        }
        return result(valid, diagnostics)
    }
}

import Foundation
import CryptoKit

/// Version 13 sends only independently grounded entity names to search services.
/// Legacy contracts keep their original interpretation in their own paths.
public struct SearchCandidate: Codable, Equatable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable { case central, text }
    public enum Kind: String, Codable, Sendable { case product, brand, species, object, person }
    public enum Status: String, Codable, Sendable { case ready, personal_data, uncertain, conflict }
    public enum Basis: String, Codable, Sendable { case text, qr, logo, appearance }
    public enum SourceRole: String, Codable, Sendable { case public_text, product_label, object_appearance, private_identity, unknown }
    public let role: Role
    public let kind: Kind
    public let query: String
    public let queryStatus: Status
    public let basis: Basis
    public let sourceRole: SourceRole
    public let sourceText: String
    public let contextText: [String]
    enum CodingKeys: String, CodingKey {
        case role, kind, query, basis
        case queryStatus = "query_status", sourceRole = "source_role", sourceText = "source_text", contextText = "context_text"
    }
    public init(role: Role, kind: Kind, query: String, queryStatus: Status = .ready, basis: Basis = .text,
                sourceRole: SourceRole = .public_text, sourceText: String? = nil, contextText: [String] = []) {
        self.role = role; self.kind = kind; self.query = query; self.queryStatus = queryStatus
        self.basis = basis; self.sourceRole = sourceRole; self.sourceText = sourceText ?? query; self.contextText = contextText
    }
    public enum Rejection: String, Codable, Sendable { case accepted, personalData, uncertain, conflict, malformed, unsafeValue, missingSource, personEvidence, duplicate }
    public func validation(in result: RecognitionResult) -> Rejection {
        guard queryStatus == .ready else {
            return queryStatus == .personal_data ? .personalData : queryStatus == .conflict ? .conflict : .uncertain
        }
        guard sourceRole != .unknown, sourceRole != .private_identity else { return sourceRole == .unknown ? .uncertain : .personalData }
        guard CandidateQuerySafety.accepts(query), sourceText.count <= 120, contextText.count <= 3,
              contextText.allSatisfy({ CandidateQuerySafety.accepts($0) }),
              Set(contextText.map(Self.normalized)).count == contextText.count else { return .unsafeValue }
        func anchored(_ value: String) -> Bool {
            result.text.contains { line in
                line.contains(value) && !CandidateQuerySafety.privateAssociation(line, containing: value)
            }
        }
        guard contextText.allSatisfy(anchored) else { return .missingSource }
        if role == .text && basis != .text { return .missingSource }
        switch basis {
        case .text:
            guard sourceRole == .public_text || sourceRole == .product_label,
                  !sourceText.isEmpty, Self.normalized(sourceText) == Self.normalized(query), anchored(sourceText) else { return .missingSource }
        case .qr:
            guard role == .central, (kind == .product || kind == .brand), sourceRole == .product_label,
                  sourceText == query, result.candidateQRFields?.values.contains(query) == true else { return .missingSource }
        case .logo, .appearance:
            guard role == .central, kind != .person, sourceText.isEmpty, contextText.isEmpty,
                  (basis == .appearance && sourceRole == .object_appearance && (kind == .object || kind == .species)) ||
                  (basis == .logo && sourceRole == .product_label && kind == .brand) else { return .missingSource }
        }
        if kind == .person {
            guard basis == .text, sourceRole == .public_text, independentClues(contextText).count >= 2 else { return .personEvidence }
        }
        return .accepted
    }
    static func normalized(_ value: String) -> String {
        TextWikipediaCandidate.normalized(value).trimmingCharacters(in: CharacterSet(charactersIn: "《》〈〉「」『』\" "))
    }
    func independentClues(_ values: [String]) -> [String] {
        var clues: [String] = []
        for value in values where value.count >= 4 && !TextWikipediaCandidate.contains(value, query) && !TextWikipediaCandidate.contains(query, value) {
            if clues.allSatisfy({ !TextWikipediaCandidate.contains($0, value) && !TextWikipediaCandidate.contains(value, $0) }) { clues.append(value) }
        }
        return clues
    }
    func proof(extract: String, categories: [String]) -> [String]? {
        guard CandidateQuerySafety.validExtract(extract), categories.count <= 40,
              categories.allSatisfy({ $0.count <= 160 }) else { return nil }
        let clauses = extract.components(separatedBy: CharacterSet(charactersIn: "。！？\n；"))
            .filter { $0.range(of: #"並非|不是|不屬於|而非|無關|未曾|沒有|(?i)\b(?:not|never|unrelated)\b"#, options: .regularExpression) == nil }
        let matches = contextText.filter { clue in clauses.contains { TextWikipediaCandidate.contains($0, clue) } }
        let personPage = WikipediaSubject.rejectsPerson(extract, categories: categories)
        if kind == .person || personPage {
            guard kind == .person, personPage, basis == .text else { return nil }
            let clues = independentClues(matches)
            return clues.count >= 2 ? clues : nil
        }
        guard clauses.contains(where: { TextWikipediaCandidate.contains($0, query) }), contextText.isEmpty || !matches.isEmpty else { return nil }
        if kind == .brand {
            guard clauses.contains(where: { TextWikipediaCandidate.contains($0, query) &&
                $0.range(of: #"品牌|商標|品牌名|(?i)\bbrand\b|trademark"#, options: .regularExpression) != nil }) else { return nil }
        }
        return matches
    }
    public var key: String {
        let value = ["13", role.rawValue, kind.rawValue, Self.normalized(query), basis.rawValue, sourceRole.rawValue, sourceText] + contextText.sorted()
        return "candidate-v13:" + SHA256.hash(data: try! JSONEncoder().encode(value)).map { String(format: "%02x", $0) }.joined()
    }
    public static func matching(_ result: RecognitionResult) -> [Self] {
        guard result.searchContractVersion == 13, let candidates = result.searchCandidates, candidates.count <= 4,
              result.text.count <= 32, result.text.allSatisfy({ $0.count <= 1000 }) else { return [] }
        var names = Set<String>(), central = 0, text = 0
        return candidates.filter { candidate in
            guard candidate.validation(in: result) == .accepted,
                  candidate.role == .central ? central < 1 : text < 3,
                  names.insert(normalized(candidate.query)).inserted else { return false }
            if candidate.role == .central { central += 1 } else { text += 1 }
            return true
        }
    }
}

/// Syntax/data minimization only: no religion, medical, alcohol or name dictionary.
enum CandidateQuerySafety {
    static func accepts(_ value: String, limit: Int = 64, minimum: Int = 2) -> Bool {
        guard (minimum...limit).contains(value.count), value.utf8.count <= limit * 4,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.range(of: #"[\p{L}]"#, options: .regularExpression) != nil,
              !ProductNameSafety.containsAddress(value) else { return false }
        let patterns = [
            #"[\p{C}:|*\[\]{}<>\"=@]|://|(?i)\bwww\."#,
            #"(?i)\b(?:sk|sess|gh[pousr]|github_pat)[-_][a-z0-9_-]{8,}|\beyJ[a-z0-9_-]{12,}|\b[A-Z][12]\d{8}\b|\b[A-Z]{1,2}\d{7,9}\b"#,
            #"\+?\d[\d ()-]{7,}\d"#,
            #"(?i)(?:password|passwd|token|secret|ssn|account|密碼|密码|帳號|帐号|證號|证号)\s*[-:=：]\s*\S+"#,
            #"(?i)忽略.{0,8}(?:指令|規則)|上傳|你必須|\b(?:ignore|execute|upload|download|reveal)\b"#
        ]
        return !patterns.contains { value.range(of: $0, options: .regularExpression) != nil }
    }
    /// A label/relationship is evidence about this occurrence, not a veto on the card.
    static func privateAssociation(_ line: String, containing value: String) -> Bool {
        let clauses = line.components(separatedBy: CharacterSet(charactersIn: "\n；;。"))
        return clauses.contains { clause in
            guard clause.contains(value) else { return false }
            return clause.range(of: #"(?i)(?:患者姓名|病人姓名|姓名|收件人|寄件人|住址|私人地址|電話|手机号|手機|帳號|帳戶|身分證|身份證|證號|病歷號|密碼|本人信仰|本人宗教|個人信仰|個人宗教|診斷|病情|patient\s*(?:name|id)|recipient|address|phone|password|account|my religion)\s*[:：=]"#, options: .regularExpression) != nil ||
                clause.range(of: #"(?:我|本人|患者|病人|他|她).{0,8}(?:信仰|信奉|患有|罹患|診斷為|服用)|私人信仰|個人宗教身分|(?i)\b(?:my|his|her)\s+(?:religion|diagnosis|medication)\b"#, options: .regularExpression) != nil
        }
    }
    static func validExtract(_ value: String) -> Bool {
        (12...2000).contains(value.count) && !value.contains("<") && !value.contains(">") &&
        !["可能指", "可以指", "消歧義", "消歧义"].contains(where: String(value.prefix(180)).contains)
    }
}

public struct CandidateSearchDiagnostic: Codable, Equatable, Hashable, Sendable {
    public let index: Int
    public let outcome: SearchCandidate.Rejection
}

enum CandidateSearchContract {
    static func parse(_ root: [String: Any], qr: BarcodeSearchEvidence?) -> RecognitionResult {
        let names = root["names"] as? [String] ?? [], summary = root["summary"] as? String ?? "", text = root["text"] as? [String] ?? []
        let bounded = names.count <= 32 && text.count <= 32 && (names + text).allSatisfy({ $0.count <= 1000 }) && summary.count <= 1600
        let base = RecognitionResult(names: Array(names.prefix(32)).map { String($0.prefix(1000)) }, summary: String(summary.prefix(1600)),
            text: Array(text.prefix(32)).map { String($0.prefix(1000)) }, searchContractVersion: 13, searchCandidates: [], candidateQRFields: qr?.fields)
        guard bounded, root["names"] is [String], root["summary"] is String, root["text"] is [String],
              root["search_block_reason"] == nil, root["search_identity"] == nil, root["text_wikipedia_policy"] == nil,
              let rows = root["search_candidates"] as? [Any], rows.count <= 4 else { return base }
        var candidates: [SearchCandidate] = [], diagnostics: [CandidateSearchDiagnostic] = []
        var namesSeen = Set<String>(), central = 0, original = 0
        for (index, row) in rows.enumerated() {
            guard JSONSerialization.isValidJSONObject(row), let data = try? JSONSerialization.data(withJSONObject: row), data.count <= 4000,
                  let candidate = try? JSONDecoder().decode(SearchCandidate.self, from: data) else {
                diagnostics.append(.init(index: index, outcome: .malformed)); continue
            }
            var status = candidate.validation(in: base)
            if status == .accepted {
                if !namesSeen.insert(SearchCandidate.normalized(candidate.query)).inserted { status = .duplicate }
                else if candidate.role == .central ? central >= 1 : original >= 3 { status = .malformed }
                else { candidates.append(candidate); if candidate.role == .central { central += 1 } else { original += 1 } }
            }
            diagnostics.append(.init(index: index, outcome: status))
        }
        return RecognitionResult(names: base.names, summary: base.summary, text: base.text, searchContractVersion: 13,
                                 searchCandidates: candidates, candidateQRFields: qr?.fields, candidateDiagnostics: diagnostics)
    }
    static var format: [String: Any] {
        func object(_ p: [String: Any]) -> [String: Any] { ["type": "object", "properties": p, "required": p.keys.sorted(), "additionalProperties": false] }
        func array(_ items: [String: Any], _ max: Int) -> [String: Any] { ["type": "array", "items": items, "maxItems": max] }
        func string(_ max: Int) -> [String: Any] { ["type": "string", "maxLength": max] }
        func values(_ v: [String]) -> [String: Any] { ["type": "string", "enum": v] }
        let candidate = object(["role": values(["central", "text"]), "kind": values(["product", "brand", "species", "object", "person"]),
            "query": string(64), "query_status": values(["ready", "personal_data", "uncertain", "conflict"]),
            "basis": values(["text", "qr", "logo", "appearance"]),
            "source_role": values(["public_text", "product_label", "object_appearance", "private_identity", "unknown"]),
            "source_text": string(120), "context_text": array(string(64), 3)])
        let schema = object(["schema_version": ["type": "integer", "enum": [13]], "names": array(string(1000), 32),
            "summary": string(1600), "text": array(string(1000), 32), "search_candidates": array(candidate, 4)])
        return ["type": "json_schema", "name": "glance_camera_v13", "strict": true, "schema": schema]
    }
}

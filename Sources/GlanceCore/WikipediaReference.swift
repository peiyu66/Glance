import Foundation

/// A general model-selected public entity, gated by a same-response privacy verdict
/// and local content checks. No item vocabulary determines eligibility.
public struct WikipediaSubject: Equatable, Sendable {
    public let key: String
    public let searchTitle: String
    let category: PublicSearchQuery.Category
    let topics: WikipediaTopics?
    var candidate13: SearchCandidate? = nil
    var candidateCount: Int { topics?.candidates.count ?? 1 }
    func query(at index: Int) -> String { topics?.candidates[index].topic ?? searchTitle }

    static func normalize(_ value: String) -> String {
        let text = value.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "_", with: " ")
            .applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? value
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
    static func containsSensitiveContent(_ value: String) -> Bool {
        let patterns = [
            #"(?i)@|://|\bwww\.|\b(password|passwd|token|secret|ssn|account|patient|prescription|medical|medicine|medication|drug|pharmacy|diagnosis|therapy|dosage|insulin|aspirin|paracetamol|acetaminophen|ibuprofen)\b"#,
            #"密碼|密码|身分證|身份證|身份证|病歷|病历|處方|处方|藥|药|醫療|医疗|醫院|医院|診斷|诊断|治療|治疗|劑量|剂量|保健|避孕|懷孕|怀孕|疾病|癌症|糖尿|血壓|血压|住址|地址|帳戶|账户|銀行|银行|信用卡|私訊|私信|私人|私有|個資|个资|護照|护照|先生|女士|小姐"#,
            #"\+?\d[\d ()-]{7,}\d|\b[A-Z][12]\d{8}\b"#
        ]
        return patterns.contains { value.range(of: $0, options: .regularExpression) != nil }
    }
    public static func matching(_ result: RecognitionResult, allowLegacy: Bool = true) -> Self? {
        if result.searchContractVersion != nil {
            guard let candidate = SearchCandidate.matching(result).first(where: { $0.role == .central }) else { return nil }
            return Self(key: candidate.key, searchTitle: candidate.query, category: .object, topics: nil, candidate13: candidate)
        }
        if let raw = result.wikipediaTopics {
            guard let topics = raw.validated(for: result), let first = topics.candidates.first else { return nil }
            return Self(key: topics.cacheKey, searchTitle: first.topic, category: topics.category, topics: topics)
        }
        // Build 5 records remain readable, but new automatic lookups use allowLegacy:false.
        guard allowLegacy else { return nil }
        guard let query = result.searchQuery, query.automaticWikipediaAllowed,
              !result.names.isEmpty, result.names.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              !containsSensitiveContent(query.query), !result.names.contains(where: containsSensitiveContent),
              query.query.range(of: #"[\p{L}]"#, options: .regularExpression) != nil,
              query.query.range(of: #"[\p{C}:|*\[\]{}<>\"=]"#, options: .regularExpression) == nil else { return nil }
        return Self(key: query.category.rawValue + ":" + normalize(query.query), searchTitle: query.query, category: query.category, topics: nil)
    }
    public var request: URLRequest { request(at: 0) }
    func request(at index: Int) -> URLRequest {
        var components = URLComponents(string: "https://zh.wikipedia.org/w/api.php")!
        components.queryItems = [
            .init(name: "action", value: "query"), .init(name: "format", value: "json"),
            .init(name: "formatversion", value: "2"), .init(name: "generator", value: "search"),
            .init(name: "gsrsearch", value: query(at: index)), .init(name: "gsrnamespace", value: "0"),
            .init(name: "gsrlimit", value: "5"), .init(name: "prop", value: topics == nil && candidate13 == nil ? "info|extracts|pageprops|redirects" : "info|extracts|pageprops|redirects|categories"),
            .init(name: "inprop", value: "url"), .init(name: "ppprop", value: "disambiguation"),
            .init(name: "rdprop", value: "title|fragment"), .init(name: "rdnamespace", value: "0"),
            .init(name: "rdlimit", value: "20"), .init(name: "rdshow", value: "!fragment"),
            .init(name: "exintro", value: "1"), .init(name: "explaintext", value: "1"),
            .init(name: "exchars", value: topics == nil && candidate13 == nil ? "500" : "1200"), .init(name: "exlimit", value: "5"),
            .init(name: "variant", value: "zh-tw"), .init(name: "maxlag", value: "5")
        ]
        if topics != nil || candidate13 != nil {
            components.queryItems! += [.init(name: "cllimit", value: "40"), .init(name: "clshow", value: "!hidden")]
        }
        return Self.makeRequest(components.url!)
    }
    private static func makeRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.setValue("Glance/0.1.0 (https://github.com/peiyu66/Glance)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
    private func match(_ page: [String: Any], at index: Int = 0) -> WikipediaReference.Match? {
        guard let title = page["title"] as? String else { return nil }
        if Self.normalize(title) == Self.normalize(query(at: index)) { return .exactTitle }
        // Products require the whole precise title. A model redirect to its brand or
        // product family must never masquerade as a page about the exact version.
        guard (topics != nil || category != .product), let redirects = page["redirects"] as? [[String: Any]] else { return nil }
        let alias = redirects.contains { redirect in
            redirect["fragment"] == nil && (redirect["ns"] as? Int ?? 0) == 0 &&
            (redirect["title"] as? String).map { Self.normalize($0) == Self.normalize(query(at: index)) } == true
        }
        return alias ? .exactRedirect : nil
    }
    static func pages(in data: Data) -> [[String: Any]]? {
        guard data.count <= 256_000,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["error"] == nil, root["warnings"] == nil,
              let query = root["query"] as? [String: Any], let pages = query["pages"] as? [[String: Any]], pages.count <= 5 else { return nil }
        return pages
    }
    func page(from data: Data, at index: Int) -> Page? {
        guard let pages = Self.pages(in: data), (0..<candidateCount).contains(index) else { return nil }
        let candidates = pages.compactMap { page -> ([String: Any], WikipediaReference.Match)? in
            match(page, at: index).map { (page, $0) }
        }
        guard candidates.count == 1, let (page, evidence) = candidates.first,
              page["missing"] == nil, page["invalid"] == nil,
              (page["ns"] as? Int) == 0, let id = page["pageid"] as? Int, id > 0,
              (page["pageprops"] as? [String: Any])?["disambiguation"] == nil,
              let title = page["title"] as? String,
              candidate13 == nil ? !Self.containsSensitiveContent(title) : CandidateQuerySafety.accepts(title, limit: 120),
              let canonical = page["canonicalurl"] as? String,
              let url = URL(string: canonical), WikipediaReference.allowedURL(url),
              let raw = page["extract"] as? String,
              candidate13 == nil ? WikipediaReference.validExtract(raw) : CandidateQuerySafety.validExtract(raw) else { return nil }
        let categories = (page["categories"] as? [[String: Any]])?.compactMap { $0["title"] as? String } ?? []
        guard topics == nil || !Self.rejectsPerson(raw, categories: categories) else { return nil }
        return Page(id: id, title: title, url: url, extract: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                    categories: categories, match: evidence, topicIndex: index)
    }
    public func reference(from data: Data, at date: Date, candidateIndex: Int = 0) -> WikipediaReference? {
        guard let page = page(from: data, at: candidateIndex) else { return nil }
        return reference(page, at: date)
    }
    func reference(_ page: Page, fullExtract: String? = nil, at date: Date) -> WikipediaReference? {
        if let candidate13 {
            guard let proof = candidate13.proof(extract: page.extract, categories: page.categories) else { return nil }
            return WikipediaReference(subjectKey: key, title: page.title, canonicalURL: page.url, extract: page.extract,
                pageID: page.id, checkedAt: date, matchedQuery: candidate13.query, match: page.match,
                candidateEvidence: .init(categories: page.categories, clues: proof, kind: candidate13.kind))
        }
        let relation = topics == nil ? nil : relationEvidence(page, fullExtract: fullExtract)
        guard topics == nil || relation != nil else { return nil }
        return WikipediaReference(subjectKey: key, title: page.title, canonicalURL: page.url,
                                  extract: page.extract, pageID: page.id, checkedAt: date,
                                  matchedQuery: query(at: page.topicIndex), match: page.match, relation: relation)
    }
    func extendedRequest(for page: Page) -> URLRequest {
        var components = URLComponents(string: "https://zh.wikipedia.org/w/api.php")!
        components.queryItems = [.init(name: "action", value: "query"), .init(name: "format", value: "json"),
            .init(name: "formatversion", value: "2"), .init(name: "pageids", value: String(page.id)),
            .init(name: "prop", value: "extracts"), .init(name: "explaintext", value: "1"),
            .init(name: "exlimit", value: "1"),
            .init(name: "exsectionformat", value: "plain"), .init(name: "variant", value: "zh-tw"), .init(name: "maxlag", value: "5")]
        return Self.makeRequest(components.url!)
    }
    func extendedExtract(from data: Data, for page: Page) -> String? {
        guard let pages = Self.pages(in: data), pages.count == 1, let value = pages.first,
              value["pageid"] as? Int == page.id, value["ns"] as? Int == 0,
              (value["title"] as? String).map(Self.normalize) == Self.normalize(page.title),
              let extract = value["extract"] as? String,
              !extract.contains("<"), !extract.contains(">") else { return nil }
        // TextExtracts exchars is capped at 1200. Omit it for one article,
        // retain the existing 256 KB transfer cap, and inspect only this prefix.
        guard extract.count > 6000 else { return extract }
        let prefix = String(extract.prefix(6000))
        guard let boundary = prefix.rangeOfCharacter(from: CharacterSet(charactersIn: "。！？\n"), options: .backwards) else { return nil }
        return String(prefix[..<boundary.upperBound])
    }

}

public struct WikipediaReference: Codable, Equatable, Sendable {
    public struct CandidateEvidence: Codable, Equatable, Sendable {
        public let categories: [String]
        public let clues: [String]
        public var kind: SearchCandidate.Kind? = nil
    }
    public enum Match: String, Codable, Sendable { case exactTitle, exactRedirect }
    public let subjectKey: String
    public let title: String
    public let canonicalURL: URL
    public let extract: String
    public let pageID: Int
    public let checkedAt: Date
    public let matchedQuery: String
    public let match: Match
    public var relation: WikipediaRelationEvidence? = nil
    public var candidateEvidence: CandidateEvidence? = nil
    public var entityEvidence: EntityWikipediaEvidence? = nil
    /// Keep broad references explicit without a separate small-text caption.
    public var displayTitle: String {
        // Presentation only: never change the canonical title, matching key or URL.
        let title = title.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false) ?? title
        if let entityEvidence {
            switch entityEvidence.role {
            case .brand: return title + "（品牌）"
            case .series: return title + "（系列）"
            case .manufacturer: return title + "（製造商）"
            case .company: return title + "（公司）"
            case .exact: return title
            }
        }
        if candidateEvidence?.kind == .brand { return title + "（品牌）" }
        switch relation?.kind {
        case .brand: return title + "（品牌）"
        case .series: return title + "（系列）"
        default: return title
        }
    }
    public static let lifetime: TimeInterval = 86_400
    static func allowedURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "zh.wikipedia.org" && url.port == nil &&
        url.user == nil && url.password == nil && url.query == nil && url.fragment == nil &&
        url.path.hasPrefix("/wiki/") && url.path.count > 6
    }
    static func validExtract(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = WikipediaSubject.normalize(String(text.prefix(180)))
        return (12...2_000).contains(text.count) && !text.contains("<") && !text.contains(">") &&
            !WikipediaSubject.containsSensitiveContent(lead) &&
            !["可能指", "可以指", "消歧義", "消歧义", "樂團", "乐团", "電影", "电影", "電視劇", "电视剧", "專輯", "专辑"].contains(where: lead.contains)
    }
    public func isCurrent(for result: RecognitionResult, at date: Date = Date()) -> Bool {
        let age = date.timeIntervalSince(checkedAt)
        if result.usesEntitySearch {
            guard age >= 0, age < Self.lifetime, let entityEvidence, entityEvidence.isValid(for: result),
                  subjectKey == SearchEntity.cacheKey(for: result), title == entityEvidence.page.title,
                  pageID == entityEvidence.page.id, canonicalURL == entityEvidence.page.url,
                  extract == entityEvidence.page.lead, matchedQuery == entityEvidence.matchedName else { return false }
            return true
        }
        if result.searchContractVersion != nil {
            guard age >= 0, age < Self.lifetime, Self.allowedURL(canonicalURL), pageID > 0,
                  let candidate = WikipediaSubject.matching(result)?.candidate13,
                  candidate.key == subjectKey, candidate.query == matchedQuery,
                  CandidateQuerySafety.accepts(title, limit: 120), let candidateEvidence,
                  candidate.proof(extract: extract, categories: candidateEvidence.categories) == candidateEvidence.clues else { return false }
            return match == .exactRedirect || WikipediaSubject.normalize(title) == WikipediaSubject.normalize(matchedQuery)
        }
        guard age >= 0, age < Self.lifetime, Self.allowedURL(canonicalURL),
              let subject = WikipediaSubject.matching(result), subject.key == subjectKey,
              !WikipediaSubject.containsSensitiveContent(title), pageID > 0, Self.validExtract(extract) else { return false }
        if let topics = subject.topics {
            guard let index = topics.candidates.firstIndex(where: { WikipediaSubject.normalize($0.topic) == WikipediaSubject.normalize(matchedQuery) }),
                  let relation, relation.kind == topics.candidates[index].kind,
                  relation.scope == topics.matchScope,
                  (topics.matchScope == .brandIdentity || (topics.matchScope == .structuredIdentity && relation.kind == .brand)
                    ? relation.kind == .brand && relation.classTerm == "品牌"
                    : topics.classTerms.contains(where: { WikipediaSubject.normalize($0) == WikipediaSubject.normalize(relation.classTerm) })),
                  !relation.definition.isEmpty, relation.definition.count <= 500,
                  relation.relation.map({ !$0.isEmpty && $0.count <= 600 }) ?? true else { return false }
            let other = topics.candidates.first { $0.kind != relation.kind }?.topic
            guard other.map(WikipediaSubject.normalize) == relation.relatedTopic.map(WikipediaSubject.normalize),
                  other == nil || relation.relation != nil else { return false }
            return match == .exactRedirect || WikipediaSubject.normalize(title) == WikipediaSubject.normalize(matchedQuery)
        }
        guard relation == nil, WikipediaSubject.normalize(matchedQuery) == WikipediaSubject.normalize(subject.searchTitle) else { return false }
        switch match {
        case .exactTitle: return WikipediaSubject.normalize(title) == WikipediaSubject.normalize(matchedQuery)
        case .exactRedirect: return subject.category != .product
        }
    }

}

public struct WikipediaHTTPResponse: Sendable {
    public let data: Data
    public let status: Int
    public let url: URL?
    public init(data: Data, status: Int, url: URL?) { self.data = data; self.status = status; self.url = url }
}

/// One short foreground lookup at a time; no queue, retries, cookies or account.
public actor WikipediaLookupService {
    public static let shared = WikipediaLookupService()
    public typealias Transport = @Sendable (URLRequest) async throws -> WikipediaHTTPResponse
    private let transport: Transport
    private let now: @Sendable () -> Date
    private let lookupTimeout: Duration
    private struct Cached { let value: WikipediaReference?; let expires: Date }
    private var cache: [String: Cached] = [:]
    private struct TextCached { let value: TextWikipediaReference?; let expires: Date }
    private var textCache: [String: TextCached] = [:]
    private var cacheGeneration = UUID()
    private var busy = false
    private var lastStarted = Date.distantPast
    private var blockedUntil = Date.distantPast
    public init(transport: @escaping Transport = { try await WikipediaLookupService.fetch($0) },
                now: @escaping @Sendable () -> Date = { Date() }, lookupTimeout: Duration = .seconds(20)) {
        self.transport = transport; self.now = now; self.lookupTimeout = min(.seconds(20), max(.milliseconds(1), lookupTimeout))
    }
    public func lookup(_ subject: WikipediaSubject) async -> WikipediaReference? {
        guard !Task.isCancelled else { return nil }
        let date = now()
        if let cached = cache[subject.key], cached.expires > date { return cached.value }
        guard !busy, date >= blockedUntil, date.timeIntervalSince(lastStarted) >= 2 else { return nil }
        busy = true; lastStarted = date
        let generation = cacheGeneration
        defer { busy = false }
        let deadline = ContinuousClock.now.advanced(by: lookupTimeout)
        do {
            let reference = try await lookupSubject(subject, deadline: deadline)
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            if cacheGeneration == generation {
                cache[subject.key] = Cached(value: reference, expires: now().addingTimeInterval(reference == nil ? 600 : WikipediaReference.lifetime))
                pruneCaches()
            }
            return reference
        } catch {
            if !Task.isCancelled { blockedUntil = max(blockedUntil, now().addingTimeInterval(10)) }
            return nil
        }
    }
    private func lookupSubject(_ subject: WikipediaSubject, deadline: ContinuousClock.Instant) async throws -> WikipediaReference? {
        var reference: WikipediaReference?
        var extendedUsed = false
        // Central reference still has at most two searches and one extract.
        for index in 0..<subject.candidateCount {
            try Task.checkCancellation()
            let data = try await fetchChecked(subject.request(at: index), deadline: deadline)
            guard let page = subject.page(from: data, at: index) else { continue }
            reference = subject.reference(page, at: now())
            if reference == nil, !extendedUsed, subject.needsExtendedExtract(page) {
                extendedUsed = true
                let extra = try await fetchChecked(subject.extendedRequest(for: page), deadline: deadline)
                if let text = subject.extendedExtract(from: extra, for: page) { reference = subject.reference(page, fullExtract: text, at: now()) }
            }
            if reference != nil { break }
        }
        return reference
    }
    /// One admission, one 20-second deadline, at most 3 central + 3 text requests.
    /// It avoids the old per-call throttle silently dropping the second candidate.
    public func lookupReferences(for result: RecognitionResult) async -> WikipediaEnrichment {
        if result.usesEntitySearch { return await lookupEntities(for: result) }
        let candidates = TextWikipediaCandidate.matching(result)
        let subject = WikipediaSubject.matching(result, allowLegacy: false)
        guard !Task.isCancelled, subject != nil || !candidates.isEmpty else { return .init() }
        let date = now()
        let missingSubject = subject.map { cache[$0.key].map { $0.expires <= date } ?? true } ?? false
        let missingText = candidates.filter { textCache[$0.key].map { $0.expires <= date } ?? true }
        if !missingSubject && missingText.isEmpty {
            return .init(subject: subject.flatMap { cache[$0.key]?.value }, text: candidates.compactMap { textCache[$0.key]?.value })
        }
        guard !busy, date >= blockedUntil, date.timeIntervalSince(lastStarted) >= 2 else { return .init() }
        busy = true; lastStarted = date
        let generation = cacheGeneration
        defer { busy = false }
        let deadline = ContinuousClock.now.advanced(by: lookupTimeout)
        var central = subject.flatMap { cache[$0.key].flatMap { $0.expires > date ? $0.value : nil } }
        var references: [TextWikipediaReference] = []
        do {
            if let subject, missingSubject {
                central = try await lookupSubject(subject, deadline: deadline)
                if cacheGeneration == generation {
                    cache[subject.key] = .init(value: central, expires: now().addingTimeInterval(central == nil ? 600 : WikipediaReference.lifetime))
                    pruneCaches()
                }
            }
            for candidate in candidates {
                try Task.checkCancellation()
                if let value = textCache[candidate.key], value.expires > date {
                    if let value = value.value { references.append(value) }
                    continue
                }
                let data = try await fetchChecked(candidate.request, deadline: deadline)
                let value = candidate.reference(from: data, at: now())
                if let value { references.append(value) }
                if cacheGeneration == generation {
                    textCache[candidate.key] = .init(value: value, expires: now().addingTimeInterval(value == nil ? 600 : WikipediaReference.lifetime))
                    pruneCaches()
                }
            }
            try Task.checkCancellation()
        } catch {
            if Task.isCancelled { return .init() }
            blockedUntil = max(blockedUntil, now().addingTimeInterval(10))
        }
        return .init(subject: central, text: references)
    }
    private struct EntityCached { let value: WikipediaEnrichment; let expires: Date }
    private var entityCache: [String: EntityCached] = [:]

    /// v14 has one admission/deadline, at most four name searches and two same-page supplements.
    /// Every candidate is considered before choosing the single best page.
    private func lookupEntities(for result: RecognitionResult) async -> WikipediaEnrichment {
        var events: [WikipediaDiagnostic] = []
        func event(_ stage: WikipediaDiagnostic.Stage, _ outcome: WikipediaDiagnostic.Outcome) -> WikipediaEnrichment {
            .init(diagnostics: events + [.init(stage, outcome, at: now())])
        }
        guard !Task.isCancelled else { return event(.admission, .cancelled) }
        let entities = SearchEntity.matching(result), key = SearchEntity.cacheKey(for: result), date = now()
        guard !entities.isEmpty else { return event(.admission, .noCandidates) }
        if let cached = entityCache[key], cached.expires > date {
            return .init(subject: cached.value.subject, diagnostics: [.init(.cache, cached.value.subject == nil ? .negativeHit : .cacheHit, at: date)])
        }
        if entityCache[key] != nil { events.append(.init(.cache, .expired, at: date)) }
        guard !busy else { return event(.admission, .busy) }
        guard date >= blockedUntil, date.timeIntervalSince(lastStarted) >= 2 else { return event(.admission, .throttled) }
        busy = true; lastStarted = date
        let generation = cacheGeneration
        defer { busy = false }
        let deadline = ContinuousClock.now.advanced(by: lookupTimeout)
        events.append(.init(.admission, .started, at: date))
        var queries: [(Int, String)] = entities.map { ($0.id, $0.name) }
        for entity in entities {
            for name in entity.aliases where queries.count < 4 && !queries.contains(where: { EntityWikipediaPage.normalized($0.1) == EntityWikipediaPage.normalized(name) }) {
                queries.append((entity.id, name))
            }
        }
        var pages: [Int: EntityWikipediaPage] = [:], unsafeIDs = Set<Int>(), requestNumber = 0
        do {
            for (id, query) in queries.prefix(4) {
                requestNumber += 1
                let request = EntityWikipediaPage.searchRequest(query), began = ContinuousClock.now
                let response = try await fetchEntityResponse(request, deadline: deadline)
                let elapsed = began.duration(to: .now).components
                events.append(.init(.transport, .http, at: now(), entityID: id, requestNumber: requestNumber,
                    httpStatus: response.status, milliseconds: Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)))
                try validateEntityResponse(response, request: request)
                for row in WikipediaSubject.pages(in: response.data) ?? [] {
                    guard let page = EntityWikipediaPage.parse(row, entities: entities, contractVersion: result.searchContractVersion) else {
                        events.append(.init(.identity, .unsafePage, at: now(), entityID: id)); continue
                    }
                    if let existing = pages[page.id], existing.url != page.url || existing.title != page.title { unsafeIDs.insert(page.id) }
                    else { pages[page.id] = page }
                }
            }
            for id in unsafeIDs { pages.removeValue(forKey: id) }
            // Only inspect already returned pages related by a whole supplied name/alias/source.
            // An anchored product-label context may also identify a company to
            // inspect; this is not manufacture proof and is never a new query.
            // A result's rank alone never makes it eligible for a supplement or a reference.
            let supplements = pages.values.filter { page in
                entities.contains { entity in
                    entity.names.contains { name in page.identities.contains { EntityWikipediaPage.normalized($0) == EntityWikipediaPage.normalized(name) } } ||
                    (page.kind(for: result.searchContractVersion) == .company && entity.role == .central && EntityWikipediaPage.productEvidenceTerms(entity, version: result.searchContractVersion).contains { EntityWikipediaPage.contains(page.lead, $0) }) ||
                    (result.searchContractVersion == 16 && page.kind(for: result.searchContractVersion) == .company &&
                     entity.role == .central && [.product, .series].contains(entity.kind) && entity.basis == .text && entity.sourceRole == .product_label &&
                     entity.contextText.contains { context in page.identities.contains { EntityWikipediaPage.contains(context, $0) } }) ||
                    (!entity.sourceText.isEmpty && page.identities.contains { EntityWikipediaPage.contains(entity.sourceText, $0) })
                } && entities.contains { EntityWikipediaEvidence.verify(page: page, entity: $0, in: result).0 == nil }
            }.sorted { left, right in
                func relevance(_ page: EntityWikipediaPage) -> Int {
                    entities.reduce(0) { total, entity in total + (entity.names.contains { name in page.identities.contains { EntityWikipediaPage.normalized($0) == EntityWikipediaPage.normalized(name) } } ? 1 : 0) }
                }
                let l = relevance(left), r = relevance(right)
                return l == r ? left.id < right.id : l > r
            }.prefix(2)
            for old in supplements {
                requestNumber += 1
                let request = old.supplementalRequest(), began = ContinuousClock.now
                let response = try await fetchEntityResponse(request, deadline: deadline)
                let elapsed = began.duration(to: .now).components
                events.append(.init(.transport, .http, at: now(), pageID: old.id, requestNumber: requestNumber,
                    httpStatus: response.status, milliseconds: Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)))
                try validateEntityResponse(response, request: request)
                let rows = WikipediaSubject.pages(in: response.data) ?? []
                guard rows.count == 1, let row = rows.first,
                      let page = EntityWikipediaPage.parse(row, supplement: true, entities: entities, contractVersion: result.searchContractVersion),
                      page.id == old.id, page.title == old.title, page.url == old.url else {
                    events.append(.init(.identity, .invalidEnvelope, at: now(), pageID: old.id)); continue
                }
                pages[page.id] = page
            }
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
        } catch {
            if Task.isCancelled { return event(.transport, .cancelled) }
            blockedUntil = max(blockedUntil, now().addingTimeInterval(10))
            return event(.transport, (error as? URLError)?.code == .timedOut ? .timeout : .invalidEnvelope)
        }
        var choices: [(EntityWikipediaEvidence, Int)] = []
        for entity in entities {
            var matched: [EntityWikipediaEvidence] = []
            for page in pages.values.sorted(by: { $0.id < $1.id }) {
                let (proof, outcome) = EntityWikipediaEvidence.verify(page: page, entity: entity, in: result)
                events.append(.init(outcome == .relationUnproven ? .relationship : .identity, outcome, at: now(), entityID: entity.id, pageID: page.id))
                if let proof { matched.append(proof) }
            }
            if let rank = matched.map(\.rank).min() {
                let best = matched.filter { $0.rank == rank }
                guard best.count == 1 else {
                    events.append(.init(.selection, .ambiguous, at: now(), entityID: entity.id)); continue
                }
                choices.append((best[0], rank + (entity.role == .text ? 10 : 0)))
            }
        }
        let rank = choices.map(\.1).min()
        let best = choices.filter { $0.1 == rank }
        let pageIDs = Set(best.map { $0.0.page.id })
        let selected = pageIDs.count == 1 ? best.first?.0 : nil
        events.append(.init(.selection, selected != nil ? .selected : pageIDs.count > 1 ? .ambiguous : .noMatch, at: now(),
                            entityID: selected?.entityID, pageID: selected?.page.id, requestNumber: requestNumber))
        let value = WikipediaEnrichment(subject: selected?.reference(for: result, at: now()), diagnostics: events)
        if generation == cacheGeneration && !Task.isCancelled {
            entityCache[key] = .init(value: value, expires: now().addingTimeInterval(selected == nil ? 600 : WikipediaReference.lifetime))
            pruneCaches()
        }
        return value
    }
    private func fetchEntityResponse(_ request: URLRequest, deadline: ContinuousClock.Instant) async throws -> WikipediaHTTPResponse {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
        let transport = self.transport
        return try await withThrowingTaskGroup(of: WikipediaHTTPResponse.self) { group in
            group.addTask { try await transport(request) }
            group.addTask { try await Task.sleep(until: deadline, clock: .continuous); throw URLError(.timedOut) }
            defer { group.cancelAll() }
            let response = try await group.next()!
            try Task.checkCancellation(); return response
        }
    }
    private func validateEntityResponse(_ response: WikipediaHTTPResponse, request: URLRequest) throws {
        guard response.status == 200, response.url == request.url else {
            blockedUntil = now().addingTimeInterval(response.status == 429 || response.status == 503 ? 60 : 10)
            throw URLError(.badServerResponse)
        }
        guard WikipediaSubject.pages(in: response.data) != nil else { throw URLError(.cannotParseResponse) }
    }

    private func pruneCaches() {
        cache = cache.filter { $0.value.expires > now() }
        textCache = textCache.filter { $0.value.expires > now() }
        entityCache = entityCache.filter { $0.value.expires > now() }
        while cache.count + textCache.count + entityCache.count > 64 {
            let entityOld = entityCache.min { $0.value.expires < $1.value.expires }
            let legacyDate = (cache.values.map(\.expires) + textCache.values.map(\.expires)).min()
            if let entityOld, legacyDate == nil || entityOld.value.expires <= legacyDate! { entityCache.removeValue(forKey: entityOld.key); continue }
            let old = cache.min { $0.value.expires < $1.value.expires }
            let textOld = textCache.min { $0.value.expires < $1.value.expires }
            if let old, textOld == nil || old.value.expires <= textOld!.value.expires { cache.removeValue(forKey: old.key) }
            else if let textOld { textCache.removeValue(forKey: textOld.key) }
        }
    }
    /// nil clears all history-related entries. In-flight work may still return to
    /// its caller, but cannot refill a cache that was explicitly cleared meanwhile.
    public func removeCachedValues(for keys: Set<String>?) {
        cacheGeneration = UUID()
        if let keys { for key in keys { cache.removeValue(forKey: key); textCache.removeValue(forKey: key); entityCache.removeValue(forKey: key) } }
        else { cache.removeAll(); textCache.removeAll(); entityCache.removeAll() }
    }
    private func fetchChecked(_ request: URLRequest, deadline: ContinuousClock.Instant) async throws -> Data {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
        let transport = self.transport
        let response = try await withThrowingTaskGroup(of: WikipediaHTTPResponse.self) { group in
            group.addTask { try await transport(request) }
            group.addTask {
                try await Task.sleep(until: deadline, clock: .continuous)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        try Task.checkCancellation()
        guard response.status == 200, response.url == request.url else {
            blockedUntil = now().addingTimeInterval(response.status == 429 || response.status == 503 ? 60 : 10)
            throw URLError(.badServerResponse)
        }
        guard WikipediaSubject.pages(in: response.data) != nil else { throw URLError(.cannotParseResponse) }
        return response.data
    }
    public static func fetch(_ request: URLRequest) async throws -> WikipediaHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.urlCache = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 6; configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration, delegate: WikipediaNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.expectedContentLength <= 256_000 else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 256_000 else { throw URLError(.dataLengthExceedsMaximum) }
                data.append(byte)
            }
            return WikipediaHTTPResponse(data: data, status: http.statusCode, url: http.url)
        } onCancel: {
            // Cancel the underlying transfer even while the async byte iterator is
            // suspended waiting for its next byte at the shared lookup deadline.
            session.invalidateAndCancel()
        }
    }
}
private final class WikipediaNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

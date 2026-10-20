import Foundation
import Testing
@testable import GlanceCore

private let book = "摩訶止觀"
private func entity(_ name: String) -> [String: Any] { ["name": name, "aliases": [], "basis": ["text"]] }
private func candidate(_ query: String = book, source: String? = nil, context: [String] = []) -> [String: Any] {
    ["query": query, "source_text": source ?? query, "reason": "完整名稱且是原文的重要主題", "context_text": context]
}
private func wire(candidates: Any = [candidate()], text: [String] = [book], policy: Any = "allowed",
                  reason: Any = NSNull(), version: Int = 12, central: Bool = false) -> [String: Any] {
    let identity: [String: Any] = ["category": "object", "subject": entity(book), "formal_name": entity(book),
        "brand": NSNull(), "manufacturer": NSNull(), "series": NSNull(), "product": NSNull(), "model_version": NSNull(),
        "disambiguation": ["論著"], "google_keywords": [], "wikipedia_policy": "allowed", "wikipedia_candidates": []]
    return ["schema_version": version, "names": ["《摩訶止觀》"], "summary": "這是一部天台論著。", "text": text,
        "search_block_reason": reason, "search_identity": central ? identity : NSNull(),
        "text_wikipedia_policy": policy, "text_wikipedia_candidates": candidates]
}
private func parse(_ value: [String: Any]) throws -> RecognitionResult {
    try CameraAnswer.parse(String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self), expectingStructured: true)
}
private func page(_ title: String = book, extract: String? = nil, categories: [String] = [], redirects: [String] = [],
                  extra: [String: Any] = [:], id: Int = 100) throws -> Data {
    var page: [String: Any] = ["pageid": id, "ns": 0, "title": title,
        "canonicalurl": "https://zh.wikipedia.org/wiki/" + title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!,
        "extract": extract ?? "《摩訶止觀》是一部天台宗佛教論著，書中討論止觀。",
        "categories": categories.map { ["title": $0] }, "redirects": redirects.map { ["title": $0, "ns": 0] as [String: Any] }]
    page.merge(extra) { _, new in new }
    return try JSONSerialization.data(withJSONObject: ["query": ["pages": [page]]])
}

@Test func text12KeepsCompleteBookAndCentralIntroductionSeparate() throws {
    let result = try parse(wire(candidates: [candidate(context: ["天台宗"])], text: ["摩訶止觀卷第一（上）", "天台宗"], central: true))
    let value = try #require(TextWikipediaCandidate.matching(result).first)
    #expect(value.query == book && result.text == ["摩訶止觀卷第一（上）", "天台宗"])
    #expect(result.names == ["《摩訶止觀》"] && result.summary == "這是一部天台論著。")
    #expect(result.searchQuery?.query == book && result.searchDiagnostic?.googleOutcome == .identityFallback)
    #expect(result.searchDiagnostic?.version == .expected12 && result.searchDiagnostic?.parserRevision == 33)
    #expect(value.reference(from: try page()) != nil)
    let restored = try JSONDecoder().decode(RecognitionResult.self, from: JSONEncoder().encode(result))
    #expect(restored == result && restored.withSourceImage(UUID()).withBarcodes([]).textWikipediaCandidates == result.textWikipediaCandidates)
}

@Test func text12UsesImportanceWithoutTypeListsAndPreservesCompositeNames() throws {
    for (query, source, extract) in [
        ("社子", "台北社子", "社子是位於臺北市的地區，此地具有河岸聚落景觀。"),
        ("晴禾極厚韌衛生紙", "晴禾極厚韌衛生紙", "晴禾極厚韌衛生紙是一項合成測試用的紙品名稱。"),
        (book, "《摩訶止觀》", "《摩訶止觀》是一部天台宗的佛教論著。")
    ] {
        let result = try parse(wire(candidates: [candidate(query, source: source)], text: [source]))
        let item = try #require(TextWikipediaCandidate.matching(result).first)
        let reference = item.reference(from: try page(query, extract: extract))
        #expect(item.query == query && reference != nil)
        #expect(result.names == ["《摩訶止觀》"])
        let request = URLComponents(url: item.request.url!, resolvingAgainstBaseURL: false)!
        #expect(request.queryItems?.first(where: { $0.name == "gsrsearch" })?.value == query)
        #expect(!item.request.url!.absoluteString.contains("source_text"))
    }
}

@Test func text12RequiresAnchorsAndAtMostThreeCandidates() throws {
    #expect(TextWikipediaCandidate.matching(try parse(wire(candidates: [candidate("臆造名稱")]))).isEmpty)
    #expect(TextWikipediaCandidate.matching(try parse(wire(candidates: [candidate(context: ["臆造線索"])]))).isEmpty)
    let many = try parse(wire(candidates: Array(repeating: candidate(), count: 4)))
    #expect(many.textWikipediaCandidateStatus == .malformed && many.textWikipediaCandidates?.isEmpty == true)
    #expect(TextWikipediaCandidate.matching(try parse(wire(candidates: [candidate(), candidate()]))).count == 1)
    let malformed = try parse(wire(candidates: "wrong"))
    #expect(malformed.names == ["《摩訶止觀》"] && malformed.searchRestriction == nil && malformed.textWikipediaCandidateStatus == .malformed)
    #expect(TextWikipediaCandidate.matching(try parse(wire(policy: true))).isEmpty)
}

@Test(arguments: ["sensitive", "conflict", "uncertain"])
func text12PolicyNeverPermitsRejectedCandidates(_ policy: String) throws {
    #expect(TextWikipediaCandidate.matching(try parse(wire(policy: policy))).isEmpty)
}

@Test(arguments: ["私人文件", "收件人：合成人", "患者姓名：合成人", "個人帳號：synthetic", "病歷"])
func text12PrivateContextStopsBothSearchPaths(_ context: String) throws {
    let result = try parse(wire(text: [book, context], central: true))
    #expect(result.searchRestriction == .sensitive && result.searchQuery == nil)
    #expect(TextWikipediaCandidate.matching(result).isEmpty)
}

@Test(arguments: ["台北市中區測試路100號", "person@example.test", "sk-synthetic12345678", "帳戶密碼", "https://example.test"])
func text12NeverQueriesContactAddressOrCredential(_ query: String) throws {
    #expect(TextWikipediaCandidate.matching(try parse(wire(candidates: [candidate(query)], text: [query]))).isEmpty)
}

@Test func text12DoesNotOverrideSensitiveAndDoesNotPromoteLegacyPermission() throws {
    for version in [10, 11] {
        let result = try parse(wire(version: version))
        #expect(result.textWikipediaCandidates == nil && result.textWikipediaPolicy == nil)
    }
    let blocked = try parse(wire(reason: "sensitive", central: true))
    #expect(blocked.searchDiagnostic?.reason == .sensitive && blocked.searchQuery == nil)
    #expect(TextWikipediaCandidate.matching(blocked).isEmpty)
    let independent = try parse(wire(reason: "uncertain"))
    #expect(independent.searchIdentity == nil && TextWikipediaCandidate.matching(independent).count == 1)
}

@Test func text12PublicBookDoesNotImplyReadersReligionAndPrivateContextStillStops() throws {
    let publicText = [book, "摩訶止觀卷第一（上）", "隋天台智者大師說", "門人灌頂記"]
    let publicResult = try parse(wire(text: publicText, central: true))
    #expect(publicResult.searchRestriction == nil && publicResult.searchQuery?.query == book)
    #expect(TextWikipediaCandidate.matching(publicResult).count == 1)
    for privateText in ["私人信仰日記", "個人宗教身分資料：私人紀錄"] {
        let result = try parse(wire(text: publicText + [privateText], central: true))
        #expect(result.searchRestriction == .sensitive && result.searchQuery == nil && TextWikipediaCandidate.matching(result).isEmpty)
    }
    // Even without a local marker, an explicit model veto is never overturned.
    let denied = try parse(wire(text: publicText, reason: "sensitive", central: true))
    #expect(denied.searchDiagnostic?.reason == .sensitive && denied.searchQuery == nil && TextWikipediaCandidate.matching(denied).isEmpty)
}

@Test func text12PersonRequiresDistinctSubstantialImageClues() throws {
    let title = "李青", clues = ["星河旅途", "山城歲月"]
    let bytes = try page(title, extract: "李青是一位作家，著有星河旅途及山城歲月兩部作品。", categories: ["分類:作家"])
    for context in [[], [clues[0]], ["作家"], ["星河旅途", "著有星河旅途"]] {
        let result = try parse(wire(candidates: [candidate(title, context: context)], text: [title] + context))
        let item = try #require(TextWikipediaCandidate.matching(result).first)
        #expect(item.reference(from: bytes) == nil)
    }
    let result = try parse(wire(candidates: [candidate(title, context: clues)], text: [title] + clues))
    let item = try #require(TextWikipediaCandidate.matching(result).first)
    let reference = try #require(item.reference(from: bytes))
    #expect(reference.contextEvidence == clues && reference.isCurrent(for: result))
    #expect(item.reference(from: try page(title, extract: "李青是一位演員，在多部不同電影中演出角色。", categories: ["分類:演員"])) == nil)
    #expect(item.reference(from: try page(title, extract: "李青是一位作家，但不是星河旅途或山城歲月的作者。", categories: ["分類:作家"])) == nil)
}

@Test func text12ExactPageRedirectAndNoPageRules() throws {
    let result = try parse(wire()), item = try #require(TextWikipediaCandidate.matching(result).first)
    #expect(item.reference(from: try page("另一部書", extract: "另一部書不是摩訶止觀，是完全不同的論著。")) == nil)
    #expect(item.reference(from: try page(extra: ["pageprops": ["disambiguation": ""]])) == nil)
    #expect(item.reference(from: try page(extra: ["missing": true])) == nil)
    #expect(item.reference(from: try page(extra: ["canonicalurl": "https://evil.example/wiki/book"])) == nil)
    let redirect = try #require(item.reference(from: page("摩訶止觀論", extract: "摩訶止觀是一部佛教論著，此處為合成轉向案例。", redirects: [book])))
    #expect(redirect.match == .exactRedirect && redirect.isCurrent(for: result))
    #expect(!redirect.isCurrent(for: result, at: redirect.checkedAt.addingTimeInterval(86_401)))
}

private actor Requests {
    var urls: [URL] = []
    func send(_ request: URLRequest) throws -> WikipediaHTTPResponse {
        urls.append(request.url!)
        let name = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "gsrsearch" }!.value!
        return .init(data: try page(name, extract: "\(name)是一個用來驗證原文參考查詢的合成條目。", id: urls.count), status: 200, url: request.url)
    }
    var count: Int { urls.count }
}

private final class TextClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    func now() -> Date { lock.withLock { date } }
    func advance() { lock.withLock { date = date.addingTimeInterval(3) } }
}

@Test func text12MixedOldAndNewCacheRemainsBoundedAndEvictsOldest() async throws {
    let requests = Requests(), clock = TextClock()
    let service = WikipediaLookupService(transport: { try await requests.send($0) }, now: { clock.now() })
    let first = try parse(wire())
    _ = await service.lookupReferences(for: first)
    for index in 1...64 {
        clock.advance()
        let name = "合成主題\(index)"
        if index.isMultiple(of: 2) {
            let result = try parse(wire(candidates: [candidate(name)], text: [name]))
            _ = await service.lookupReferences(for: result)
        } else {
            let legacy = RecognitionResult(names: [name], searchQuery: PublicSearchQuery(query: name, category: "object", automaticWikipediaAllowed: true))
            _ = await service.lookup(try #require(WikipediaSubject.matching(legacy)))
        }
    }
    let before = await requests.count
    clock.advance(); _ = await service.lookupReferences(for: first)
    let after = await requests.count
    #expect(before == 65 && after == 66)
}

private actor HeldTextTransport {
    var count = 0
    var pending: CheckedContinuation<WikipediaHTTPResponse, Never>?
    var url: URL?
    func send(_ request: URLRequest) async -> WikipediaHTTPResponse {
        count += 1; url = request.url
        return await withCheckedContinuation { pending = $0 }
    }
    func finish() throws { pending?.resume(returning: .init(data: try page(), status: 200, url: url)); pending = nil }
    func ready() -> Bool { pending != nil }
}

@Test func text12ClearDuringFetchCannotRefillCacheAndCancelledBatchDoesNotPersist() async throws {
    let transport = HeldTextTransport(), clock = TextClock(), result = try parse(wire())
    let service = WikipediaLookupService(transport: { await transport.send($0) }, now: { clock.now() })
    let first = Task { await service.lookupReferences(for: result) }
    while !(await transport.ready()) { await Task.yield() }
    await service.removeCachedValues(for: nil); try await transport.finish()
    _ = await first.value
    clock.advance()
    let second = Task { await service.lookupReferences(for: result) }
    while !(await transport.ready()) { await Task.yield() }
    let calls = await transport.count
    #expect(calls == 2)
    second.cancel(); try await transport.finish()
    #expect(await second.value.text.isEmpty)
    clock.advance()
    let third = Task { await service.lookupReferences(for: result) }
    while !(await transport.ready()) { await Task.yield() }
    #expect(await transport.count == 3)
    try await transport.finish(); _ = await third.value
}

@Test func text12BatchDeadlineCancelsTransportAndStopsRemainingQueries() async throws {
    let result = try parse(wire(candidates: [candidate(), candidate("社子")], text: [book, "社子"]))
    actor Counter { var calls = 0; var cancelled = false; func start() { calls += 1 }; func stop() { cancelled = true } }
    let counter = Counter()
    let service = WikipediaLookupService(transport: { request in
        await counter.start()
        do { try await Task.sleep(for: .seconds(10)) }
        catch { await counter.stop(); throw error }
        return .init(data: try page(), status: 200, url: request.url)
    }, lookupTimeout: .milliseconds(40))
    let start = ContinuousClock.now
    let value = await service.lookupReferences(for: result)
    let count = await counter.calls, cancelled = await counter.cancelled
    #expect(value == .init() && count == 1 && cancelled)
    #expect(start.duration(to: .now) < .seconds(2))
}

@Test func text12BatchQueriesThreeWithoutPerCallThrottleAndClearsCache() async throws {
    let names = ["第一個主題", "第二個主題", "第三個主題"]
    let result = try parse(wire(candidates: names.map { candidate($0) }, text: names))
    let requests = Requests(), date = Date()
    let service = WikipediaLookupService(transport: { try await requests.send($0) }, now: { date })
    let first = await service.lookupReferences(for: result)
    let firstCount = await requests.count
    #expect(first.text.count == 3 && first.subject == nil && firstCount == 3)
    let cached = await service.lookupReferences(for: result), cachedCount = await requests.count
    #expect(cached == first && cachedCount == 3)
    await service.removeCachedValues(for: Set(TextWikipediaCandidate.matching(result).map(\.key)))
    let cleared = await service.lookupReferences(for: result), finalCount = await requests.count
    #expect(cleared.text.isEmpty && finalCount == 3)
}

@Test func text12ArchiveSharesOnlyValidatedLinksAndDeletionNeverRecreatesRecord() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID(), date = Date()
    _ = try await archive.create(id: id, jpeg: Data([1, 2, 3]), capturedAt: date)
    let saved = try await archive.complete(id: id, result: parse(wire(central: true)), message: nil)
    let result = try #require(saved.result), item = try #require(TextWikipediaCandidate.matching(result).first)
    let reference = try #require(item.reference(from: page(), at: date))
    let enriched = try await archive.attachWikipediaEnrichment(id: id, expectedResult: result, enrichment: .init(text: [reference]), at: date)
    #expect(enriched.shareDocument(at: date).links.map(\.label) == ["Google 搜尋：摩訶止觀", "原文參考：摩訶止觀"])
    #expect(enriched.shareText(at: date).contains("【原文】") && enriched.shareText(at: date).contains("https://zh.wikipedia.org/"))
    let restored = try #require(try await RecognitionArchive(root: root).load().records.first)
    #expect(restored == enriched && restored.currentTextWikipedia(at: date).count == 1)
    #expect(restored.currentTextWikipedia(at: date.addingTimeInterval(86_401)).isEmpty)
    _ = try await archive.delete(ids: [id])
    await #expect(throws: (any Error).self) { try await archive.attachWikipediaEnrichment(id: id, expectedResult: result, enrichment: .init(text: [reference]), at: date) }
    #expect(try await archive.load().records.isEmpty)
}

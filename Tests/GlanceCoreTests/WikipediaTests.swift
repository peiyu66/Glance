import Foundation
import Testing
@testable import GlanceCore

private let wikiDate = Date(timeIntervalSince1970: 1_800_000_000)
private func result(_ query: String = "雨傘", _ names: [String] = ["雨傘"], category: String = "object") -> RecognitionResult {
    .init(names: names, summary: "私人情境不送百科", text: ["私有原文"], searchQuery: PublicSearchQuery(query: query, category: category, automaticWikipediaAllowed: true))
}
private func subject() -> WikipediaSubject { WikipediaSubject.matching(result())! }
private func page(_ changes: [String: Any] = [:]) -> [String: Any] {
    var value: [String: Any] = ["pageid": 123, "ns": 0, "title": "雨傘", "canonicalurl": "https://zh.wikipedia.org/wiki/%E5%82%98", "extract": "傘是一種遮蔽雨水或陽光的日常用品。", "pageprops": [:]]
    value.merge(changes, uniquingKeysWith: { _, new in new }); return value
}
private func payload(_ pages: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["query": ["pages": pages]])
}

@Test func wikiUsesGeneralModelKeywordsWithContentPrivacyGate() throws {
    for (query, category) in [("望遠鏡", "object"), ("電風扇", "object"), ("機械式計算機", "object"), ("Sony α7 III", "product"), ("Panthera leo", "species")] {
        let candidate = try #require(WikipediaSubject.matching(result(query, [query], category: category)))
        #expect(candidate.searchTitle == query)
        #expect(candidate.key == category + ":" + WikipediaSubject.normalize(query))
        let components = try #require(URLComponents(url: candidate.request.url!, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first { $0.name == "gsrsearch" }?.value == query)
    }
    for query in ["藥物", "Aspirin", "Paracetamol", "處方藥", "王先生的雨傘", "未知私人物件", "雨傘 診斷", "Acme patient device", "intitle:雨傘", "雨傘|姓名"] {
        #expect(WikipediaSubject.matching(result(query, [query])) == nil)
    }
    #expect(WikipediaSubject.matching(result("雨傘", ["藥片"])) == nil)
    #expect(WikipediaSubject.matching(result("雨傘", [])) == nil)
    let legacy = RecognitionResult(names: ["望遠鏡"], searchQuery: PublicSearchQuery(query: "望遠鏡", category: "object"))
    #expect(WikipediaSubject.matching(legacy) == nil)
    let request = subject().request
    #expect(request.httpBody == nil && request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request.timeoutInterval == 6)
    let query = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(!query.contains { ($0.value ?? "").contains("私有原文") || ($0.value ?? "").contains("私人情境") })
}
@Test func wikiGeneralExactAndRedirectMatchesDoNotDowngradeProducts() throws {
    let telescope = try #require(WikipediaSubject.matching(result("望远镜", ["望遠鏡"])))
    let telescopePage = page(["title": "望遠鏡", "extract": "望遠鏡是利用光學元件觀察遠方物體的儀器。"])
    #expect(telescope.reference(from: try payload([telescopePage]), at: wikiDate)?.match == .exactTitle)
    let fan = try #require(WikipediaSubject.matching(result("電風扇", ["風扇"])))
    let fanPage = page(["title": "風扇", "extract": "風扇是利用旋轉葉片推動空氣流動的裝置。", "redirects": [["ns": 0, "title": "電風扇"]]])
    let reference = try #require(fan.reference(from: payload([fanPage]), at: wikiDate))
    #expect(reference.match == .exactRedirect && reference.isCurrent(for: result("電風扇", ["風扇"]), at: wikiDate))
    var section = fanPage; section["redirects"] = [["ns": 0, "title": "電風扇", "fragment": "電動型"]]
    #expect(fan.reference(from: try payload([section]), at: wikiDate) == nil)
    let product = try #require(WikipediaSubject.matching(result("Sony α7 III", ["Sony α7 III"], category: "product")))
    let broad = page(["title": "Sony", "extract": "Sony 是一家製造電子產品的企業。", "redirects": [["title": "Sony α7 III", "ns": 0]]])
    #expect(product.reference(from: try payload([broad]), at: wikiDate) == nil)
    let exact = page(["title": "Sony α7 III", "extract": "Sony α7 III 是一款可更換鏡頭的數位相機。"])
    #expect(product.reference(from: try payload([exact]), at: wikiDate)?.match == .exactTitle)
    #expect(product.reference(from: try payload([page(["title": "Sony α7", "extract": "Sony α7 是一系列可更換鏡頭數位相機。"])]), at: wikiDate) == nil)
}
@Test func wikiAutomaticFlagIsExplicitOptionalAndKeepsOneAIRequest() throws {
    let prefix = #"{"names":["望遠鏡"],"summary":"天文儀器","text":[],"barcodes":[],"search":{"query":"望遠鏡","category":"object""#
    for ending in ["}}", #", "automatic_wikipedia":false}}"#, #", "automatic_wikipedia":"true"}}"#] {
        let answer = try CameraAnswer.parse(prefix + ending)
        #expect(answer.searchQuery != nil && WikipediaSubject.matching(answer) == nil)
    }
    let allowed = try CameraAnswer.parse(prefix + #", "automatic_wikipedia":true}}"#)
    #expect(WikipediaSubject.matching(allowed)?.searchTitle == "望遠鏡")
}
@Test func wikiRequiresUniqueExactEntityCanonicalURLAndNonAmbiguousSummary() throws {
    let reference = try #require(subject().reference(from: payload([page()]), at: wikiDate))
    #expect(reference.title == "雨傘" && reference.pageID == 123)
    #expect(reference.canonicalURL.absoluteString == "https://zh.wikipedia.org/wiki/%E5%82%98")
    #expect(reference.isCurrent(for: result(), at: wikiDate))
    let invalid: [[String: Any]] = [
        ["title": "雨傘品牌"], ["title": "雨具"], ["ns": 1], ["pageid": -1], ["missing": true],
        ["pageprops": ["disambiguation": ""]], ["extract": "傘可能指以下不同的實體與概念。"],
        ["extract": "傘是一個重金屬音樂團體的名稱。"], ["extract": ""], ["extract": "<b>傘</b>是一種遮雨用品。"],
        ["canonicalurl": "https://example.test/wiki/傘"], ["canonicalurl": "http://zh.wikipedia.org/wiki/傘"],
        ["canonicalurl": "https://zh.wikipedia.org/wiki/傘?tracking=1"], ["canonicalurl": "https://zh.wikipedia.org/w/index.php"],
        ["canonicalurl": "https://user@zh.wikipedia.org/wiki/傘"]
    ]
    for change in invalid { #expect(subject().reference(from: try payload([page(change)]), at: wikiDate) == nil) }
    #expect(subject().reference(from: try payload([page(), page(["pageid": 124])]), at: wikiDate) == nil)
    #expect(subject().reference(from: try payload([]), at: wikiDate) == nil)
    #expect(subject().reference(from: Data("{broken".utf8), at: wikiDate) == nil)
    #expect(subject().reference(from: Data(repeating: 32, count: 256_001), at: wikiDate) == nil)
}
@Test func wikiReferenceExpiresAndCannotBeBorrowedByAnotherEntity() throws {
    let reference = try #require(subject().reference(from: payload([page()]), at: wikiDate))
    #expect(reference.isCurrent(for: result(), at: wikiDate.addingTimeInterval(86_399)))
    #expect(!reference.isCurrent(for: result(), at: wikiDate.addingTimeInterval(86_400)))
    #expect(!reference.isCurrent(for: result(), at: wikiDate.addingTimeInterval(-1)))
    #expect(!reference.isCurrent(for: result("剪刀", ["剪刀"]), at: wikiDate))
}
@Test func wikiPersistsOnlyOnOwnExistingCompletedCard() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), a = UUID(), b = UUID()
    _ = try await archive.create(id: a, jpeg: Data([1]), capturedAt: wikiDate)
    _ = try await archive.create(id: b, jpeg: Data([2]), capturedAt: wikiDate)
    _ = try await archive.complete(id: a, result: result(), message: nil)
    _ = try await archive.complete(id: b, result: result("剪刀", ["剪刀"]), message: nil)
    let reference = try #require(subject().reference(from: payload([page()]), at: wikiDate))
    _ = try await archive.attachWikipedia(id: a, reference: reference, at: wikiDate)
    let restored = try await RecognitionArchive(root: root).load().records
    #expect(restored.first { $0.id == a }?.wikipedia == reference)
    #expect(restored.first { $0.id == b }?.wikipedia == nil)
    await #expect(throws: (any Error).self) { try await archive.attachWikipedia(id: b, reference: reference, at: wikiDate) }
    try FileManager.default.removeItem(at: root.appendingPathComponent(a.uuidString))
    await #expect(throws: (any Error).self) { try await archive.attachWikipedia(id: a, reference: reference, at: wikiDate) }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(a.uuidString).path))
}

private final class WikiClock: @unchecked Sendable {
    private let lock = NSLock(); private var time = wikiDate
    func now() -> Date { lock.withLock { time } }
    func advance(_ delta: TimeInterval) { lock.withLock { time = time.addingTimeInterval(delta) } }
}
private actor WikiTransport {
    var calls = 0
    var data: Data
    var status = 200
    var wrongURL = false
    init(_ data: Data) { self.data = data }
    func fetch(_ request: URLRequest) -> WikipediaHTTPResponse {
        calls += 1
        return .init(data: data, status: status, url: wrongURL ? URL(string: "https://example.test") : request.url)
    }
    func configure(status: Int = 200, wrongURL: Bool = false) { self.status = status; self.wrongURL = wrongURL }
}
@Test func wikiCacheThrottleAndNegativeCacheBoundRequests() async throws {
    let clock = WikiClock(), transport = WikiTransport(try payload([page()]))
    let service = WikipediaLookupService(transport: { await transport.fetch($0) }, now: { clock.now() })
    let first = await service.lookup(subject())
    #expect(first != nil)
    #expect(await service.lookup(subject()) == first)
    #expect(await transport.calls == 1)
    let other = try #require(WikipediaSubject.matching(result("剪刀", ["剪刀"])))
    #expect(await service.lookup(other) == nil)
    #expect(await transport.calls == 1)
    clock.advance(2)
    #expect(await service.lookup(other) == nil)
    #expect(await transport.calls == 2)
    clock.advance(5)
    #expect(await service.lookup(other) == nil)
    #expect(await transport.calls == 2)
    clock.advance(600)
    #expect(await service.lookup(other) == nil)
    #expect(await transport.calls == 3)
    clock.advance(86_400)
    #expect(await service.lookup(subject()) != nil)
    #expect(await transport.calls == 4)
}
@Test func wikiHTTPFailureAndRedirectDoNotCreateLinks() async throws {
    let clock = WikiClock(), transport = WikiTransport(try payload([page()]))
    let service = WikipediaLookupService(transport: { await transport.fetch($0) }, now: { clock.now() })
    await transport.configure(status: 429)
    #expect(await service.lookup(subject()) == nil)
    clock.advance(3)
    #expect(await service.lookup(subject()) == nil)
    #expect(await transport.calls == 1)
    clock.advance(60); await transport.configure(wrongURL: true)
    #expect(await service.lookup(subject()) == nil)
    #expect(await transport.calls == 2)
    let failing = WikipediaLookupService(transport: { _ in throw URLError(.timedOut) })
    #expect(await failing.lookup(subject()) == nil)
}
private actor WikiHeldTransport {
    var calls = 0
    var pending: CheckedContinuation<WikipediaHTTPResponse, Never>?
    func fetch(_ request: URLRequest) async -> WikipediaHTTPResponse {
        calls += 1
        return await withCheckedContinuation { pending = $0 }
    }
    func complete(_ value: WikipediaHTTPResponse) { pending?.resume(returning: value); pending = nil }
}
@Test func historyDeletionEvictsRelatedWikipediaCacheAndClearAllEvictsRemainingEntries() async throws {
    let clock = WikiClock(), transport = WikiTransport(try payload([page()]))
    let service = WikipediaLookupService(transport: { await transport.fetch($0) }, now: { clock.now() })
    let first = await service.lookup(subject()); #expect(first != nil)
    await service.removeCachedValues(for: ["unrelated-key"])
    #expect(await service.lookup(subject()) == first); #expect(await transport.calls == 1)
    await service.removeCachedValues(for: [subject().key]); clock.advance(3)
    #expect(await service.lookup(subject()) != nil); #expect(await transport.calls == 2)
    await service.removeCachedValues(for: nil); clock.advance(3)
    #expect(await service.lookup(subject()) != nil); #expect(await transport.calls == 3)
}
@Test func historyDeletionPreventsLateWikipediaResultFromRefillingClearedCache() async throws {
    let clock = WikiClock(), transport = WikiHeldTransport()
    let service = WikipediaLookupService(transport: { await transport.fetch($0) }, now: { clock.now() })
    let first = Task { await service.lookup(subject()) }
    for _ in 0..<100 { if await transport.calls == 1 { break }; await Task.yield() }
    await service.removeCachedValues(for: [subject().key])
    await transport.complete(.init(data: try payload([page()]), status: 200, url: subject().request.url))
    #expect(await first.value != nil)
    clock.advance(3)
    let second = Task { await service.lookup(subject()) }
    for _ in 0..<100 { if await transport.calls == 2 { break }; await Task.yield() }
    #expect(await transport.calls == 2)
    await transport.complete(.init(data: try payload([page()]), status: 200, url: subject().request.url))
    #expect(await second.value != nil)
}
@Test func wikiConcurrentAndCancelledLookupsDoNotQueueOrCacheLateResults() async throws {
    let clock = WikiClock(), transport = WikiHeldTransport()
    let service = WikipediaLookupService(transport: { await transport.fetch($0) }, now: { clock.now() })
    let first = Task { await service.lookup(subject()) }
    for _ in 0..<100 { if await transport.calls == 1 { break }; await Task.yield() }
    clock.advance(3)
    #expect(await service.lookup(subject()) == nil)
    #expect(await transport.calls == 1)
    first.cancel()
    await transport.complete(.init(data: try payload([page()]), status: 200, url: subject().request.url))
    #expect(await first.value == nil)
    let second = Task { await service.lookup(subject()) }
    for _ in 0..<100 { if await transport.calls == 2 { break }; await Task.yield() }
    #expect(await transport.calls == 2)
    await transport.complete(.init(data: try payload([page()]), status: 200, url: subject().request.url))
    #expect(await second.value != nil)
}

@Test func legacyAndMalformedOptionalWikiKeepOriginalCardReadable() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID()
    _ = try await archive.create(id: id, jpeg: Data([1]), capturedAt: wikiDate)
    let record = try await archive.complete(id: id, result: result(), message: nil)
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
    object.removeValue(forKey: "wikipedia")
    let legacy = try JSONDecoder().decode(ArchivedRecognition.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(legacy.result == record.result && legacy.wikipedia == nil)
    object["wikipedia"] = ["title": "invalid metadata", "pageID": "bad"]
    let corrupted = try JSONDecoder().decode(ArchivedRecognition.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(corrupted.result == record.result && corrupted.wikipedia == nil && corrupted.id == id)
}

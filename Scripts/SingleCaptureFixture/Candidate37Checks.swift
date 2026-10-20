import Foundation

@MainActor final class C37CandidateProbe {
    var calls = 0
    var pending: [UUID: CheckedContinuation<WikipediaEnrichment, Never>] = [:]
    var results: [UUID: RecognitionResult] = [:]
    func lookup(_ result: RecognitionResult) async -> WikipediaEnrichment {
        calls += 1; let id = result.sourceImageID!; results[id] = result
        return await withCheckedContinuation { pending[id] = $0 }
    }
    func finish(_ id: UUID) { if let result = results[id] { pending.removeValue(forKey: id)?.resume(returning: Self.enrichment(result)) } }
    static func result() -> RecognitionResult {
        let candidates: [SearchCandidate] = [.init(role: .central, kind: .person, query: "林範例", contextText: ["合成文學獎", "合成大學教授"]),
            .init(role: .text, kind: .object, query: "摩訶止觀"), .init(role: .text, kind: .product, query: "阿斯匹靈"), .init(role: .text, kind: .brand, query: "海尼根")]
        let root: [String: Any] = ["schema_version": 13, "names": ["林範例"], "summary": "公開文字人物與原文實體的合成案例。", "text": ["林範例", "合成文學獎", "合成大學教授", "摩訶止觀", "阿斯匹靈", "海尼根", "患者姓名：測試甲"], "search_candidates": try! JSONSerialization.jsonObject(with: JSONEncoder().encode(candidates))]
        return try! CameraAnswer.parse(String(decoding: JSONSerialization.data(withJSONObject: root), as: UTF8.self), expectingStructured: true)
    }
    static func page(_ query: String, id: Int) -> Data {
        let extract = query == "林範例" ? "林範例是一位臺灣作家，曾獲合成文學獎，並任合成大學教授。" : query + "是一個公開介紹的品牌或主題，這是合成測試條目。"
        return try! JSONSerialization.data(withJSONObject: ["query": ["pages": [["pageid": id, "ns": 0, "title": query,
            "canonicalurl": "https://zh.wikipedia.org/wiki/" + query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!,
            "extract": extract, "categories": query == "林範例" ? [["title": "Category:臺灣作家"]] : []]]]])
    }
    static func enrichment(_ result: RecognitionResult) -> WikipediaEnrichment {
        let central = WikipediaSubject.matching(result)
        return .init(subject: central.flatMap { $0.reference(from: page($0.searchTitle, id: 3700), at: Date()) },
            text: TextWikipediaCandidate.matching(result).enumerated().compactMap { index, candidate in
                candidate.reference(from: page(candidate.query, id: 3701 + index))
            })
    }
}
extension C2FixtureHost {
    func runCandidate37Checks() async -> [String: Bool] {
        var c: [String: Bool] = [:]
        let probe = C37CandidateProbe()
        let host = C2FixtureHost(name: "candidate37-lifecycle", wikipediaReferencesLookup: { await probe.lookup($0) })
        try? FileManager.default.removeItem(at: host.root); await host.model.bootstrap()
        func recognize() async -> UUID? {
            _ = host.model.beginAcquisition(); host.feed(); await host.settle { host.waiter != nil }
            host.waiter?.resume(returning: C37CandidateProbe.result()); host.waiter = nil
            await host.model.waitForCurrentWork(); await host.settle { !probe.pending.isEmpty }
            return host.model.records.first?.id
        }
        guard let first = await recognize() else { return ["first_record": false] }
        c["query_is_name_without_private_background"] = host.model.records.first?.googleSearch?.query == "林範例"
        probe.finish(first); await host.model.waitForWikipediaWork()
        c["central_person_and_three_original_references"] = host.model.records.first?.wikipedia != nil && host.model.records.first?.currentTextWikipedia().count == 3
        c["share_has_five_independent_links"] = host.model.records.first?.shareDocument().links.count == 5
        c["saved_contract_is_v13"] = host.model.records.first?.result?.searchContractVersion == 13
        host.model = host.makeModel(); await host.model.bootstrap()
        c["restart_no_extra_queries"] = probe.calls == 1 && host.model.records.first?.shareDocument().links.count == 5
        guard let second = await recognize() else { return c }
        host.model.foreground(.background); probe.finish(second); await Task.yield()
        c["background_discards_late_reference"] = host.model.records.first?.textWikipedia == nil
        host.model.foreground(.active); await host.settle { host.model.previewOpen }
        guard let third = await recognize() else { return c }
        host.model.withdrawDataUse(); probe.finish(third); await Task.yield()
        c["withdraw_discards_late_reference"] = host.model.records.first?.textWikipedia == nil
        c["withdraw_preserves_existing_reference"] = host.model.records.first(where: { $0.id == first })?.shareDocument().links.count == 5
        c["withdraw_blocks_new_capture"] = !host.model.beginAcquisition() && host.calls == 3
        c["withdraw_keeps_delete"] = await host.model.deleteRecord(id: third)
        c["no_extra_model_or_wiki_calls"] = host.calls == 3 && probe.calls == 3
        host.model.closePreview(); return c
    }
}

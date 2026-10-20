import Foundation

@MainActor final class C36TextProbe {
    var calls = 0
    var pending: [UUID: CheckedContinuation<WikipediaEnrichment, Never>] = [:]
    var results: [UUID: RecognitionResult] = [:]
    func lookup(_ result: RecognitionResult) async -> WikipediaEnrichment {
        calls += 1
        let id = result.sourceImageID!
        results[id] = result
        return await withCheckedContinuation { pending[id] = $0 }
    }
    func finish(_ id: UUID) {
        guard let result = results[id] else { return }
        pending.removeValue(forKey: id)?.resume(returning: Self.enrichment(result))
    }
    static func result() -> RecognitionResult {
        let names = ["摩訶止觀", "社子", "晴禾極厚韌衛生紙"]
        let wire: [String: Any] = ["schema_version": 12, "names": ["《摩訶止觀》"],
            "summary": "這是合成的完整作品名稱與原文參考卡片。", "text": names,
            "search_block_reason": NSNull(), "search_identity": [
                "category": "object", "subject": ["name": names[0], "aliases": [], "basis": ["text"]] as [String: Any],
                "formal_name": NSNull(), "brand": NSNull(), "manufacturer": NSNull(), "product": NSNull(), "series": NSNull(), "model_version": NSNull(),
                "disambiguation": ["論著"], "google_keywords": [names[0]], "wikipedia_policy": "allowed", "wikipedia_candidates": []],
            "text_wikipedia_policy": "allowed", "text_wikipedia_candidates": names.map {
                ["query": $0, "source_text": $0, "reason": "完整專名且語意重要", "context_text": []] as [String: Any]
            }]
        return try! CameraAnswer.parse(String(decoding: JSONSerialization.data(withJSONObject: wire), as: UTF8.self), expectingStructured: true)
    }
    static func enrichment(_ result: RecognitionResult) -> WikipediaEnrichment {
        .init(text: TextWikipediaCandidate.matching(result).enumerated().compactMap { index, candidate in
            let page: [String: Any] = ["pageid": 3601 + index, "ns": 0, "title": candidate.query,
                "canonicalurl": "https://zh.wikipedia.org/wiki/" + candidate.query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!,
                "extract": "\(candidate.query)是一個用於驗證原文參考顯示與分享的合成條目。"]
            return candidate.reference(from: try! JSONSerialization.data(withJSONObject: ["query": ["pages": [page]]]))
        })
    }
}

extension C2FixtureHost {
    func runTextWikipediaChecks() async -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let probe = C36TextProbe()
        let host = C2FixtureHost(name: "text-wiki-lifecycle", wikipediaReferencesLookup: { await probe.lookup($0) })
        try? FileManager.default.removeItem(at: host.root)
        await host.model.bootstrap()
        func recognize() async -> UUID? {
            _ = host.model.beginAcquisition(); host.feed()
            await host.settle { host.waiter != nil }
            host.waiter?.resume(returning: C36TextProbe.result()); host.waiter = nil
            await host.model.waitForCurrentWork()
            await host.settle { !probe.pending.isEmpty }
            return host.model.records.first?.id
        }
        guard let first = await recognize() else { return ["first_record": false] }
        checks["does_not_block_continue"] = host.model.canContinue && host.model.records.first?.shareDocument().links.count == 1
        probe.finish(first); await host.model.waitForWikipediaWork()
        checks["three_references_on_same_card"] = host.model.records.first?.currentTextWikipedia().count == 3
        checks["full_title_and_four_share_links"] = host.model.records.first?.shareDocument().links.count == 4 && host.model.records.first?.shareText().contains("原文參考：摩訶止觀") == true
        let before = probe.calls
        host.model = host.makeModel(); await host.model.bootstrap()
        checks["restart_preserves_without_lookup"] = probe.calls == before && host.model.records.first?.currentTextWikipedia().count == 3
        guard let second = await recognize() else { return checks.merging(["second_record": false]) { _, b in b } }
        host.model.foreground(.background); probe.finish(second); await host.model.waitForWikipediaWork()
        checks["background_rejects_late_enrichment"] = host.model.records.first(where: { $0.id == second })?.textWikipedia == nil
        host.model.foreground(.active)
        await host.settle { host.model.previewOpen }
        guard let third = await recognize() else { return checks.merging(["third_record": false]) { _, b in b } }
        let deleted = await host.model.deleteRecord(id: third)
        probe.finish(third); await Task.yield()
        let stored = try? await host.model.archive.load()
        checks["delete_then_late_reply_does_not_restore"] = deleted && !host.model.records.contains { $0.id == third } && stored?.records.contains { $0.id == third } == false
        checks["other_reference_card_preserved"] = host.model.records.first(where: { $0.id == first })?.currentTextWikipedia().count == 3
        checks["no_extra_model_requests"] = host.calls == 3 && probe.calls == 3
        return checks
    }
}

import Foundation

@MainActor final class C39EntityProbe {
    var calls = 0
    var pending: [UUID: CheckedContinuation<WikipediaEnrichment, Never>] = [:]
    var results: [UUID: RecognitionResult] = [:]
    func lookup(_ result: RecognitionResult) async -> WikipediaEnrichment {
        calls += 1; let id = result.sourceImageID!; results[id] = result
        return await withCheckedContinuation { pending[id] = $0 }
    }
    func finish(_ id: UUID) {
        if let result = results[id] { pending.removeValue(forKey: id)?.resume(returning: Self.enrichment(result)) }
    }
    static func result(_ index: Int = 12, version: Int = 15) -> RecognitionResult {
        let entity = SearchEntity(kind: index == 12 ? .product : .brand, name: index == 12 ? "晨光原味" : "曙光", aliases: index == 12 ? ["Morning Original", "晨光原味"] : ["Aurora", "曙光"], sourceText: index == 12 ? "Morning Original" : "Aurora")
        let root: [String: Any] = ["schema_version": version, "names": [index == 12 ? "晨光原味飲品" : "曙光飲料品牌"], "summary": "合成測試：AI名稱與忠實原文分開，百科只提供一個已核對的角色參考。", "text": [index == 12 ? "Morning\nOriginal" : "Aurora", "〈 麦芽100% 〉"], "search_entities": try! JSONSerialization.jsonObject(with: JSONEncoder().encode([entity]))]
        return try! CameraAnswer.parse(String(decoding: JSONSerialization.data(withJSONObject: root), as: UTF8.self), expectingStructured: true)
    }
    static func enrichment(_ result: RecognitionResult) -> WikipediaEnrichment {
        guard let entity = SearchEntity.matching(result).first else { return .init(diagnostics: [.init(.admission, .noCandidates)]) }
        let company = entity.kind == .product, title = company ? "曙光公司" : "曙光"
        let row: [String: Any] = ["pageid": company ? 3801 : 3802, "ns": 0, "title": title, "canonicalurl": "https://zh.wikipedia.org/wiki/" + title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!,
            "redirects": company ? [] : [["title": "Aurora"]],
            "extract": company ? "曙光公司是一家飲料製造商。曙光公司製造 Morning Original 與晨光原味飲品。" : "曙光是一個飲料品牌，這是公開品牌介紹的合成案例。"]
        let page = EntityWikipediaPage.parse(row, entities: SearchEntity.matching(result))!
        let evidence = EntityWikipediaEvidence.verify(page: page, entity: entity, in: result).0
        return .init(subject: evidence?.reference(for: result, at: Date()), diagnostics: [.init(.selection, evidence == nil ? .noMatch : .selected)])
    }
}
extension C2FixtureHost {
    func runEntity39Checks(version: Int = 15) async -> [String: Bool] {
        var c: [String: Bool] = [:]
        let probe = C39EntityProbe()
        let host = C2FixtureHost(name: "entity-contract-\(version)-lifecycle", wikipediaReferencesLookup: { await probe.lookup($0) })
        try? FileManager.default.removeItem(at: host.root); await host.model.bootstrap()
        func recognize(_ supplied: RecognitionResult? = nil) async -> UUID? {
            let result = supplied ?? C39EntityProbe.result(version: version)
            _ = host.model.beginAcquisition(); host.feed(); await host.settle { host.waiter != nil }
            host.waiter?.resume(returning: result); host.waiter = nil
            await host.model.waitForCurrentWork(); await host.settle { !probe.pending.isEmpty }
            return host.model.records.first?.id
        }
        guard let first = await recognize() else { return ["first_record": false] }
        probe.finish(first); await host.model.waitForWikipediaWork()
        let initial = host.model.records.first!
        c["v\(version)_routed_and_original_kept"] = initial.result?.searchContractVersion == version && initial.result?.text == ["Morning\nOriginal", "〈 麦芽100% 〉"]
        if version == 16 { c["display_variant_does_not_reject_search_identity"] = initial.result?.names == ["晨光原味飲品"] && initial.result?.searchEntities?.first?.name == "晨光原味" }
        c["duplicate_alias_recorded_and_removed"] = initial.result?.entityDiagnostics?.first?.adjustments?.contains("duplicateAliasRemoved") == true && initial.result?.searchEntities?.first?.aliases == ["Morning Original"]
        c["one_manufacturer_link"] = initial.wikipedia?.displayTitle == "曙光公司（製造商）" && initial.currentTextWikipedia().isEmpty
        c["google_combines_whole_names"] = initial.googleSearch?.query == "晨光原味 Morning Original"
        c["share_same_role_and_two_links"] = initial.shareDocument().links.count == 2 && initial.shareText().contains("維基百科：曙光公司（製造商）")
        c["closed_save_diagnostic"] = initial.wikipediaDiagnostics?.last?.outcome == .saved
        host.model = host.makeModel(); await host.model.bootstrap()
        c["reopen_no_queries_same_url_role"] = probe.calls == 1 && host.model.records.first?.shareDocument() == initial.shareDocument()
        guard let second = await recognize() else { return c }
        host.model.foreground(.background); probe.finish(second); await Task.yield()
        c["background_discards_late_reference"] = host.model.records.first?.wikipedia == nil
        host.model.foreground(.active); await host.settle { host.model.previewOpen }
        c["foreground_no_requery"] = probe.calls == 2
        guard let third = await recognize() else { return c }
        let deleted = await host.model.deleteRecord(id: third); probe.finish(third); await Task.yield()
        c["deleted_not_recreated_by_late_reference"] = deleted && !host.model.records.contains { $0.id == third } && !FileManager.default.fileExists(atPath: host.root.appendingPathComponent(third.uuidString).path)
        guard let fourth = await recognize() else { return c }
        host.writeFault.set(true); probe.finish(fourth); await host.model.waitForWikipediaWork(); host.writeFault.set(false)
        c["optional_save_failure_has_closed_diagnostic"] = host.model.wikipediaDiagnostics[fourth]?.last?.outcome == .saveFailed && host.model.records.first?.status == .succeeded
        let empty = RecognitionResult(names: ["可讀但無安全候選"], searchContractVersion: version, searchEntities: [])
        guard let fifth = await recognize(empty) else { return c }
        probe.finish(fifth); await host.model.waitForWikipediaWork()
        c["no_candidate_reason_persisted"] = host.model.records.first?.wikipediaDiagnostics?.contains { $0.outcome == .noCandidates } == true
        c["no_candidate_keeps_readable_card"] = host.model.records.first?.result?.names == ["可讀但無安全候選"] && host.model.records.first?.wikipedia == nil
        guard let sixth = await recognize() else { return c }
        host.model.withdrawDataUse(); probe.finish(sixth); await Task.yield()
        c["withdraw_discards_late_reference"] = host.model.records.first?.wikipedia == nil
        c["withdraw_blocks_new_capture"] = !host.model.beginAcquisition() && host.calls == 6
        c["withdraw_preserves_prior_link"] = host.model.records.first(where: { $0.id == first })?.shareDocument().links.count == 2
        c["only_expected_provider_and_wiki_calls"] = host.calls == 6 && probe.calls == 6
        c["no_real_network"] = C8NetworkProbe.shared.count == 0
        host.model.closePreview(); return c
    }
}

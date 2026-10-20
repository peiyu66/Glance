import Foundation

@MainActor final class C5WikipediaProbe {
    var calls = 0
    var pending: [String: CheckedContinuation<WikipediaReference?, Never>] = [:]
    func lookup(_ subject: WikipediaSubject) async -> WikipediaReference? {
        calls += 1
        return await withCheckedContinuation { pending[subject.key] = $0 }
    }
    static func result(_ name: String = "雨傘") -> RecognitionResult {
        .init(names: [name], searchQuery: PublicSearchQuery(query: name, category: "object"),
              wikipediaTopics: .init(category: .object, automaticWikipediaAllowed: true,
                classTerms: [name == "雨傘" ? "用品" : "工具"], candidates: [.init(topic: name, kind: .subject, evidence: name)]))
    }
    static func reference(_ name: String = "雨傘", date: Date = Date()) -> WikipediaReference? {
        guard let subject = WikipediaSubject.matching(result(name)) else { return nil }
        let umbrella = name == "雨傘"
        let page: [String: Any] = ["pageid": umbrella ? 123 : 456, "ns": 0, "title": umbrella ? "雨傘" : "剪刀",
                                  "canonicalurl": umbrella ? "https://zh.wikipedia.org/wiki/%E5%82%98" : "https://zh.wikipedia.org/wiki/%E5%89%AA%E5%88%80",
                                  "extract": umbrella ? "傘是一種遮蔽雨水或陽光的日常用品。" : "剪刀是切割紙張或布料使用的一種工具。"]
        let data = try! JSONSerialization.data(withJSONObject: ["query": ["pages": [page]]])
        return subject.reference(from: data, at: date)
    }
    func finish(_ name: String = "雨傘", date: Date = Date()) {
        let key = WikipediaSubject.matching(Self.result(name))!.key
        pending.removeValue(forKey: key)?.resume(returning: Self.reference(name, date: date))
    }
}

@MainActor private final class C19BrandProbe {
    var subjects: [WikipediaSubject] = []
    func lookup(_ subject: WikipediaSubject) async -> WikipediaReference? {
        subjects.append(subject)
        let page: [String: Any] = ["pageid": 123, "ns": 0, "title": "樂事", "canonicalurl": "https://zh.wikipedia.org/wiki/%E4%B9%90%E4%BA%8B",
            "extract": "樂事（Lay's）是一個製作洋芋片的品牌，販售多種口味的商品。"]
        let data = try! JSONSerialization.data(withJSONObject: ["query": ["pages": [page]]])
        return subject.reference(from: data, at: Date())
    }
}

extension C2FixtureHost {
    func runWikipediaChecks() async -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let probe = C5WikipediaProbe()
        let host = C2FixtureHost(name: "wiki-binding", wikipediaLookup: { await probe.lookup($0) })
        try? FileManager.default.removeItem(at: host.root); await host.model.bootstrap()
        func recognize(_ name: String) async -> UUID? {
            _ = host.model.beginAcquisition(); host.feed(); await host.settle { host.waiter != nil }
            host.waiter?.resume(returning: C5WikipediaProbe.result(name)); host.waiter = nil
            await host.model.waitForCurrentWork(); return host.model.records.first?.id
        }
        let first = await recognize("雨傘")
        await host.settle { probe.calls == 1 }
        checks["wiki_does_not_block_continue_or_live"] = host.model.canContinue && host.model.submittedPreview == nil && !host.model.acquiring
        let beforeWikiShare = host.model.records.first?.shareText() ?? ""
        let second = await recognize("剪刀")
        await host.settle { probe.calls == 2 }
        probe.finish("剪刀"); await host.settle { host.model.records.first?.wikipedia != nil }
        probe.finish(); await host.model.waitForWikipediaWork()
        checks["out_of_order_wiki_returns_stay_on_own_UUID"] = host.model.records.first(where: { $0.id == first })?.wikipedia?.subjectKey == WikipediaSubject.matching(C5WikipediaProbe.result("雨傘"))!.key && host.model.records.first(where: { $0.id == second })?.wikipedia?.subjectKey == WikipediaSubject.matching(C5WikipediaProbe.result("剪刀"))!.key
        let firstShared = host.model.records.first(where: { $0.id == first })?.shareText() ?? ""
        checks["share_refreshes_late_wiki_on_same_card"] = !beforeWikiShare.contains("維基百科") && firstShared.contains("維基百科：雨傘") && !firstShared.contains("剪刀")
        let restored = try? await RecognitionArchive(root: host.root).load().records
        checks["wiki_links_survive_restart_without_requery"] = restored == host.model.records && probe.calls == 2
        _ = await recognize("處方藥")
        await Task.yield()
        checks["sensitive_subject_does_not_start_lookup"] = probe.calls == 2
        let backgroundID = await recognize("雨傘"); await host.settle { probe.pending[WikipediaSubject.matching(C5WikipediaProbe.result("雨傘"))!.key] != nil }
        let starts = host.starts; host.model.foreground(.background)
        probe.finish(); await Task.yield(); await Task.yield()
        let backgroundSaved = try? await RecognitionArchive(root: host.root).load().records
        checks["background_cancel_discards_late_wiki_without_camera_restart"] = backgroundSaved?.first(where: { $0.id == backgroundID })?.wikipedia == nil && host.starts == starts && !host.model.previewOpen
        host.model.foreground(.active); await host.settle { host.model.previewOpen }
        checks["foreground_does_not_replay_cancelled_wiki"] = probe.calls == 3
        let expiredID = await recognize("雨傘"); await host.settle { probe.pending[WikipediaSubject.matching(C5WikipediaProbe.result("雨傘"))!.key] != nil }
        probe.finish(date: Date().addingTimeInterval(-86_401)); await host.model.waitForWikipediaWork()
        checks["expired_wiki_response_is_ignored"] = host.model.records.first(where: { $0.id == expiredID })?.wikipedia == nil
        let deletedID = await recognize("雨傘"); await host.settle { probe.pending[WikipediaSubject.matching(C5WikipediaProbe.result("雨傘"))!.key] != nil }
        if let deletedID { try? FileManager.default.removeItem(at: host.root.appendingPathComponent(deletedID.uuidString)) }
        await host.model.reloadHistory(); probe.finish(); await host.model.waitForWikipediaWork()
        checks["deleted_card_is_not_recreated_by_wiki"] = deletedID.map { id in !FileManager.default.fileExists(atPath: host.root.appendingPathComponent(id.uuidString).path) && !host.model.records.contains(where: { $0.id == id }) } ?? false
        let timedID = await recognize("雨傘"); await host.settle { probe.pending[WikipediaSubject.matching(C5WikipediaProbe.result("雨傘"))!.key] != nil }
        host.clock.now = host.model.cycle.deadline!; let before = host.starts; host.model.checkPreviewDeadline()
        probe.finish(); await Task.yield(); await Task.yield()
        checks["deadline_cancelled_wiki_does_not_reopen_preview"] = host.starts == before && !host.model.previewOpen && host.model.expired && host.model.records.first(where: { $0.id == timedID })?.wikipedia == nil
        checks["wiki_does_not_add_AI_calls"] = host.calls == 7 && host.model.requestCount == 7
        host.model.closePreview()
        let brandProbe = C19BrandProbe()
        let fallbackHost = C2FixtureHost(name: "wiki-fallback", wikipediaLookup: { await brandProbe.lookup($0) })
        try? FileManager.default.removeItem(at: fallbackHost.root); await fallbackHost.model.bootstrap()
        _ = fallbackHost.model.beginAcquisition(); fallbackHost.feed()
        await fallbackHost.settle { fallbackHost.waiter != nil }
        let wire = #"{"schema_version":10,"names":["樂連連原味洋芋片"],"summary":"合成結構化回應，未驗證模型辨識品質。","text":["Lay's樂事","樂連連","原味"],"search_block_reason":null,"search_identity":{"category":"product","subject":{"name":"樂連連原味洋芋片","aliases":[],"basis":["appearance"]},"brand":{"name":"樂事","aliases":["Lay's"],"basis":["logo"]},"manufacturer":null,"series":null,"product":null,"model_version":null,"formal_name":null,"disambiguation":[],"google_keywords":["樂事","樂連連原味洋芋片"],"automatic_wikipedia":true,"wikipedia_candidates":[{"topic":"樂事","kind":"brand"}]}}"#
        let composedWire = wire.replacingOccurrences(of: #""google_keywords":["樂事","樂連連原味洋芋片"]"#, with: #""google_keywords":["Lay’s 樂連連原味洋芋片"]"#)
        let parsed = try! CameraAnswer.parse(composedWire, expectingStructured: true)
        fallbackHost.waiter?.resume(returning: parsed); fallbackHost.waiter = nil
        await fallbackHost.model.waitForCurrentWork(); await fallbackHost.model.waitForWikipediaWork()
        let card = fallbackHost.model.records.first
        checks["structured_brand_queries_once_after_same_card_completion"] = brandProbe.subjects.count == 1 && brandProbe.subjects.first?.searchTitle == "樂事" && fallbackHost.calls == 1
        checks["structured_reference_and_identity_persist_on_original_UUID"] = card?.wikipedia != nil && card?.result?.wikipediaCandidateStatus == .modelProvided && card?.result?.searchIdentity?.brand?.name == "樂事" && card?.result?.sourceImageID == card?.id
        checks["structured_share_keeps_google_and_brand_wiki"] = card?.shareDocument().links.count == 2 && card?.shareText().contains("維基百科：樂事（品牌）") == true
        checks["composed_keyword_and_source_mapping_survive_actual_controller"] = card?.result?.searchQuery?.query == "Lay’s 樂連連原味洋芋片" && card?.result?.searchDiagnostic?.keywordEvidence?.keywords.first?.match == .composedSources
        let fallbackRestored = try? await RecognitionArchive(root: fallbackHost.root).load().records
        checks["structured_restart_keeps_reference_without_new_AI_or_query"] = fallbackRestored == fallbackHost.model.records && fallbackHost.calls == 1 && brandProbe.subjects.count == 1
        fallbackHost.model.closePreview()
        let photoProbe = C19BrandProbe()
        let photoHost = C2FixtureHost(name: "wiki-fallback-photo", wikipediaLookup: { await photoProbe.lookup($0) })
        try? FileManager.default.removeItem(at: photoHost.root); await photoHost.model.bootstrap()
        let selection = photoHost.model.beginPhotoSelection()!
        _ = photoHost.model.photoTransferStarted(id: selection)
        photoHost.model.photoPickerDismissed(id: selection)
        _ = await photoHost.model.prepareSelectedPhoto(C2FixtureHost.jpeg(.blue), selectionID: selection)
        await photoHost.settle { photoHost.waiter != nil }
        photoHost.waiter?.resume(returning: parsed); photoHost.waiter = nil
        await photoHost.model.waitForCurrentWork(); await photoHost.model.waitForWikipediaWork()
        checks["photo_library_structured_does_not_require_open_camera"] = !photoHost.model.previewOpen && photoHost.model.records.first?.source == .photoLibrary && photoHost.model.records.first?.wikipedia != nil
        checks["photo_library_wiki_adds_no_camera_start_or_AI_request"] = photoHost.starts == 1 && photoHost.calls == 1 && photoProbe.subjects.count == 1
        photoHost.model.closePreview()
        let rejectedProbe = C19BrandProbe()
        let rejectedHost = C2FixtureHost(name: "wiki-safe-identity-invalid-google", wikipediaLookup: { await rejectedProbe.lookup($0) })
        try? FileManager.default.removeItem(at: rejectedHost.root); await rejectedHost.model.bootstrap()
        _ = rejectedHost.model.beginAcquisition(); rejectedHost.feed()
        await rejectedHost.settle { rejectedHost.waiter != nil }
        let rejectedWire = wire.replacingOccurrences(of: #""google_keywords":["樂事","樂連連原味洋芋片"]"#, with: #""google_keywords":["無依據型號"]"#)
        rejectedHost.waiter?.resume(returning: try! CameraAnswer.parse(rejectedWire, expectingStructured: true)); rejectedHost.waiter = nil
        await rejectedHost.model.waitForCurrentWork(); await rejectedHost.model.waitForWikipediaWork()
        let rejectedCard = rejectedHost.model.records.first
        checks["unsupported_keywords_use_brand_without_changing_independent_wiki_or_AI_calls"] = rejectedCard?.wikipedia != nil && rejectedCard?.result?.searchQuery?.query == "樂事" && rejectedCard?.result?.searchDiagnostic?.googleFallbackField == .brand && rejectedHost.calls == 1 && rejectedProbe.subjects.count == 1
        checks["brand_fallback_and_wiki_share_omit_unsupported_keywords"] = rejectedCard?.shareDocument().links.count == 2 && rejectedCard?.shareText().contains("Google 搜尋：樂事") == true && rejectedCard?.shareText().contains("無依據型號") == false
        let rejectedRestored = try? await RecognitionArchive(root: rejectedHost.root).load().records.first
        checks["unsupported_keyword_text_and_source_labels_persist_without_whole_wire"] = rejectedRestored?.result?.searchDiagnostic?.keywordEvidence?.keywords.first?.text == "無依據型號" && rejectedRestored?.result?.searchDiagnostic?.keywordEvidence?.sources.contains(where: { $0.field == .brand && $0.text == "樂事" && $0.basis == [.logo] }) == true
        rejectedHost.model.closePreview()
        // Replay only card 98's exported safe search fields. Pixel input, summary
        // and OCR here are synthetic; this is not the original model response.
        let card98Wire = #"{"schema_version":10,"names":["樂事樂連連原味"],"summary":"","text":[],"search_block_reason":null,"search_identity":{"category":"product","subject":null,"brand":{"name":"樂事","aliases":["Lay's","樂事"],"basis":["text","logo"]},"manufacturer":null,"series":{"name":"樂連連","aliases":[],"basis":["text"]},"product":{"name":"樂事樂連連原味","aliases":[],"basis":["text"]},"model_version":null,"formal_name":null,"disambiguation":["馬鈴薯零食"],"google_keywords":["Lay's 樂事","樂連連原味","馬鈴薯零食"],"automatic_wikipedia":false,"wikipedia_candidates":[]}}"#
        let card98Probe = C19BrandProbe()
        let card98Host = C2FixtureHost(name: "card98-safe-metadata", wikipediaLookup: { await card98Probe.lookup($0) })
        try? FileManager.default.removeItem(at: card98Host.root); await card98Host.model.bootstrap()
        _ = card98Host.model.beginAcquisition(); card98Host.feed()
        await card98Host.settle { card98Host.waiter != nil }
        card98Host.waiter?.resume(returning: try! CameraAnswer.parse(card98Wire, expectingStructured: true)); card98Host.waiter = nil
        await card98Host.model.waitForCurrentWork(); await card98Host.model.waitForWikipediaWork()
        let card98 = card98Host.model.records.first
        checks["card98_actual_search_fields_now_keep_google_and_normalized_alias"] = card98?.result?.searchQuery?.query == "Lay's 樂事 樂連連原味 馬鈴薯零食" && card98?.result?.searchIdentity?.brand?.aliases == ["Lay's"] && card98?.shareDocument().links.count == 1
        checks["card98_wiki_false_stays_disabled_without_lookup_or_retry"] = card98?.result?.wikipediaCandidateStatus == .disabled && card98?.wikipedia == nil && card98Probe.subjects.isEmpty && card98Host.calls == 1
        let card98Saved = try? await RecognitionArchive(root: card98Host.root).load().records.first
        checks["card98_normalized_fields_and_original_duplicate_evidence_survive_restart"] = card98Saved?.result?.searchDiagnostic?.normalizationFields == [.brand] && card98Saved?.result?.searchDiagnostic?.keywordEvidence?.sources.contains(where: { $0.field == .brand && $0.kind == .alias && $0.text == "樂事" }) == true
        card98Host.model.closePreview()
        // Safe card 98 fields, plus an EXPLICITLY SYNTHETIC schema-11 allowed
        // decision. Never reinterpret the actual legacy false as permission.
        let policyWire = card98Wire.replacingOccurrences(of: #""schema_version":10"#, with: #""schema_version":11"#)
            .replacingOccurrences(of: #""automatic_wikipedia":false"#, with: #""wikipedia_policy":"allowed""#)
        let policyProbe = C19BrandProbe()
        let policyHost = C2FixtureHost(name: "card98-fields-synthetic-policy11", wikipediaLookup: { await policyProbe.lookup($0) })
        try? FileManager.default.removeItem(at: policyHost.root); await policyHost.model.bootstrap()
        _ = policyHost.model.beginAcquisition(); policyHost.feed()
        await policyHost.settle { policyHost.waiter != nil }
        policyHost.waiter?.resume(returning: try! CameraAnswer.parse(policyWire, expectingStructured: true)); policyHost.waiter = nil
        await policyHost.model.waitForCurrentWork(); await policyHost.model.waitForWikipediaWork()
        let policyCard = policyHost.model.records.first
        checks["policy11_explicit_allowed_with_empty_suggestions_generates_brand_once"] = policyCard?.result?.wikipediaCandidateStatus == .structuredBrandFallback && policyProbe.subjects.count == 1 && policyProbe.subjects.first?.searchTitle == "樂事" && policyHost.calls == 1
        checks["policy11_google_wiki_share_stays_on_same_UUID"] = policyCard?.shareDocument().links.count == 2 && policyCard?.shareText().contains("維基百科：樂事（品牌）") == true && policyCard?.result?.sourceImageID == policyCard?.id
        let policySaved = try? await RecognitionArchive(root: policyHost.root).load().records.first
        checks["policy11_policy_and_diagnostic_persist_without_requery"] = policySaved == policyCard && policySaved?.result?.searchIdentity?.wikipediaPolicy == .allowed && policySaved?.result?.searchDiagnostic?.wikipediaPolicy == .allowed && policyProbe.subjects.count == 1 && policyHost.calls == 1
        policyHost.model.closePreview()
        let photoPending = C5WikipediaProbe()
        let backgroundPhoto = C2FixtureHost(name: "wiki-photo-background", wikipediaLookup: { await photoPending.lookup($0) })
        try? FileManager.default.removeItem(at: backgroundPhoto.root); await backgroundPhoto.model.bootstrap()
        let backgroundSelection = backgroundPhoto.model.beginPhotoSelection()!
        _ = backgroundPhoto.model.photoTransferStarted(id: backgroundSelection)
        backgroundPhoto.model.photoPickerDismissed(id: backgroundSelection)
        _ = await backgroundPhoto.model.prepareSelectedPhoto(C2FixtureHost.jpeg(.blue), selectionID: backgroundSelection)
        await backgroundPhoto.settle { backgroundPhoto.waiter != nil }
        backgroundPhoto.waiter?.resume(returning: C5WikipediaProbe.result()); backgroundPhoto.waiter = nil
        await backgroundPhoto.model.waitForCurrentWork(); await backgroundPhoto.settle { photoPending.calls == 1 }
        backgroundPhoto.model.foreground(.background); photoPending.finish()
        await Task.yield(); await Task.yield()
        let backgroundPhotoSaved = try? await RecognitionArchive(root: backgroundPhoto.root).load().records
        checks["photo_library_background_cancels_late_reference"] = photoPending.calls == 1 && backgroundPhotoSaved?.first?.wikipedia == nil && !backgroundPhoto.model.previewOpen
        return checks
    }
}

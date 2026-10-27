import SwiftUI
import UniformTypeIdentifiers

@MainActor final class Semantic45Probe {
    var calls = 0
    var sourceCalls = 0
    var emptySources = false
    var sourceFailure: SemanticReviewFailure?
    var waits: [UUID: CheckedContinuation<String, Error>] = [:]
    var lastRaw = ""
    var holdSources = false
    var sourceWait: CheckedContinuation<[WikipediaReviewSource], Error>?
    func sources(_ result: RecognitionResult) async throws -> [WikipediaReviewSource] {
        sourceCalls += 1
        if let sourceFailure { throw sourceFailure }
        if holdSources { return try await withCheckedThrowingContinuation { sourceWait = $0 } }
        return emptySources ? [] : [Self.source]
    }
    func finishSources() { sourceWait?.resume(returning: [Self.source]); sourceWait = nil }
    func review(_ result: RecognitionResult, sources: [WikipediaReviewSource]) async throws -> String {
        calls += 1
        return try await withCheckedThrowingContinuation { waits[result.sourceImageID!] = $0 }
    }
    func finish(_ id: UUID, invalid: Bool = false, noMatch: Bool = false, cancelled: Bool = false, networkFailure: Bool = false) {
        guard let wait = waits.removeValue(forKey: id) else { return }
        if cancelled { wait.resume(throwing: CancellationError()); return }
        if networkFailure { wait.resume(throwing: URLError(.notConnectedToInternet)); return }
        let answer = noMatch ? WikipediaReviewAnswer(decision: .insufficient_evidence) : Self.answer
        lastRaw = invalid ? "{malformed}" : String(decoding: try! JSONEncoder().encode(answer), as: UTF8.self)
        wait.resume(returning: lastRaw)
    }
    static let quote = "曙光公司持有曙光品牌，旋脆片是該品牌的零食系列。"
    static let title61Quote = "乐事是这个合成回归样本中的品牌名称。"
    // Quote only the contiguous first sentence retained by the production excerpt budget.
    static let original67Quote = "アサヒビールは日本のビールメーカーである。"
    static let reported68 = "『アサヒ生ビール マルエフ』はアサヒビールのブランドのビールです。アサヒビールは日本の大手ビールメーカーで、主力商品『アサヒスーパードライ』などを展開しています。"
    static var source: WikipediaReviewSource {
        if ProcessInfo.processInfo.arguments.contains("--foreign67") {
            return .init(pageID: 67, title: "アサヒビール", url: URL(string: "https://ja.wikipedia.org/wiki/アサヒビール")!, fetchedAt: Date(), excerpts: [.init(id: "p0", text: original67Quote)])
        }
        if ProcessInfo.processInfo.arguments.contains("--title61") {
            return .init(pageID: 6101, title: "乐事", url: URL(string: "https://zh.wikipedia.org/wiki/乐事")!, fetchedAt: Date(), excerpts: [.init(id: "p0", text: title61Quote)])
        }
        if ProcessInfo.processInfo.arguments.contains("--book57") {
            return .init(pageID: 4063, title: "智顗", url: URL(string: "https://zh.wikipedia.org/wiki/智顗")!, fetchedAt: Date(), excerpts: [.init(id: "p0", text: book57Quote)])
        }
        return .init(pageID: 4501, title: "曙光公司", url: URL(string: "https://zh.wikipedia.org/wiki/Aurora")!, fetchedAt: Date(), excerpts: [.init(id: "p0", text: quote)])
    }
    static var answer: WikipediaReviewAnswer {
        if ProcessInfo.processInfo.arguments.contains("--foreign67") {
            if ProcessInfo.processInfo.arguments.contains("--native68") {
                return .init(decision: .selected, sourceID: "jawiki:67", relationship: .brand, searchName: "マルエフ", summary: "該品牌推出スーパードライ系列，這是一句繁體中文介紹。", citations: [.init(excerptID: "p0", quote: original67Quote)])
            }
            if ProcessInfo.processInfo.arguments.contains("--summary68") {
                return .init(decision: .selected, sourceID: "jawiki:67", relationship: .brand, searchName: "アサヒ生ビール マルエフ", summary: reported68, citations: [.init(excerptID: "p0", quote: original67Quote)])
            }
            return .init(decision: .selected, sourceID: "jawiki:67", relationship: .brand, searchName: "マルエフ", summary: "這是日文來源支援的合成繁體中文品牌說明。", citations: [.init(excerptID: "p0", quote: original67Quote)])
        }
        if ProcessInfo.processInfo.arguments.contains("--title61") {
            return .init(decision: .selected, sourceID: "zhwiki:6101", relationship: .brand, searchName: "樂事洋芋片", summary: "這是使用樂事名稱的合成回歸樣本。", citations: [.init(excerptID: "p0", quote: title61Quote)])
        }
        if ProcessInfo.processInfo.arguments.contains("--book57") {
            return .init(decision: .selected, sourceID: "zhwiki:4063", relationship: .same_entity, searchName: "摩訶止觀", summary: "摩訶止觀為天台三大部之一。", citations: [.init(excerptID: "p0", quote: book57Quote)])
        }
        return .init(decision: .selected, sourceID: "zhwiki:4501", relationship: .brand_owner, searchName: "曙光旋脆片", summary: "旋脆片是曙光品牌的零食系列；曙光公司持有這個品牌。", citations: [.init(excerptID: "p0", quote: quote)])
    }
    // Synthetic book/author projection only; does not reproduce the complete user payload.
    static let book57Quote = "智者大師完成了「天台三大部」《法華文句》、《法華玄義》、《摩訶止觀》"
    static var result: RecognitionResult {
        if ProcessInfo.processInfo.arguments.contains("--foreign67") {
            if ProcessInfo.processInfo.arguments.contains("--quoted69") {
                return .init(names: ["アサヒ生ビール マルエフ"], summary: "照片中央是印有「マルエフ」的日本啤酒罐。マルエフ是朝日啤酒的品牌名稱；罐身可見的「まろやかな泡」意為口感柔和的泡沫。", text: ["マルエフ", "まろやかな泡"], searchContractVersion: 17,
                    searchEntities: [.init(kind: .product, name: "アサヒ生ビール マルエフ", sourceText: "マルエフ")])
            }
            if ProcessInfo.processInfo.arguments.contains("--summary68") {
                return .init(names: ["アサヒ生ビール マルエフ"], summary: "アサヒ生ビール マルエフ是一款日本啤酒，Asahi 是品牌原文名稱。", text: ["アサヒ生ビール マルエフ", "アサヒビール"], searchContractVersion: 17,
                    searchEntities: [.init(kind: .product, name: "アサヒ生ビール マルエフ", sourceText: "アサヒ生ビール マルエフ"), .init(id: 1, role: .related, kind: .brand, name: "アサヒビール", aliases: ["Asahi"], sourceText: "アサヒビール", relation: .brand_of, relatedTo: 0)])
            }
            return .init(names: ["マルエフ"], summary: "初步簡介", text: ["マルエフ", "アサヒビール"], searchContractVersion: 17, searchEntities: [.init(kind: .product, name: "マルエフ", sourceText: "マルエフ")])
        }
        if ProcessInfo.processInfo.arguments.contains("--title61") {
            return .init(names: ["樂事洋芋片"], summary: "第一階段簡介", text: ["乐事", "LAY'S"], searchContractVersion: 17, searchEntities: [.init(kind: .brand, name: "樂事", sourceText: "乐事")])
        }
        if ProcessInfo.processInfo.arguments.contains("--book57") {
            return .init(names: ["摩訶止觀"], summary: "一本佛教典籍。", text: ["摩訶止觀"], searchContractVersion: 17, searchEntities: [.init(kind: .object, name: "摩訶止觀", sourceRole: .public_text, sourceText: "摩訶止觀")])
        }
        if ProcessInfo.processInfo.arguments.contains("--google57") {
            // Exact user-supplied public product-label JSON; no image or network.
            return try! CameraAnswer.parse(#"{"names":["Maker’s Mark 波本威士忌"],"text":["Maker’s","Mark®","KENTUCKY STRAIGHT BOURBON","WHISKY","Handmade","DISTILLED, AGED AND BOTTLED BY THE","MAKER’S MARK DISTILLERY, INC.","STAR HILL FARM, LORETTO, KY USA","200 mL 45% ALC./VOL."],"schema_version":17,"search_entities":[{"kind":"product","basis":"text","source_role":"product_label","related_to":0,"role":"central","status":"ready","relation":"none","source_text":"Maker’s\nMark®","aliases":[],"context_text":["KENTUCKY STRAIGHT BOURBON","WHISKY"],"name":"Maker’s Mark 波本威士忌","id":0},{"kind":"brand","basis":"text","source_role":"product_label","related_to":0,"role":"related","status":"ready","relation":"brand_of","source_text":"Maker’s\nMark®","aliases":[],"context_text":[],"name":"Maker’s Mark","id":1},{"kind":"company","basis":"text","source_role":"product_label","related_to":0,"role":"related","status":"ready","relation":"manufacturer_of","source_text":"MAKER’S MARK DISTILLERY, INC.","aliases":[],"context_text":[],"name":"Maker’s Mark Distillery, Inc.","id":2}],"summary":"這是一瓶 Maker’s Mark 波本威士忌，標示為肯塔基直式波本威士忌，容量 200 mL，酒精濃度 45%。波本威士忌是美國威士忌的一類；標籤並列出蒸餾、熟成與裝瓶業者及其所在地。"}"#, expectingStructured: true)
        }
        return .init(names: ["曙光旋脆片"], summary: "初步簡介，百科稍後補充。", text: ["AURORA", "旋脆片", "原味 日本語 👩🏽‍🔬"], searchContractVersion: 17,
            searchEntities: [.init(kind: .product, name: "曙光旋脆片", basis: .logo, sourceText: "AURORA")])
    }
}
extension C2FixtureHost {
    func recognize45(_ probe: Semantic45Probe) async -> UUID? {
        // This helper represents an explicit user press, including reopening a
        // preview closed by a launch/foreground transition in Build62.
        guard await model.startRecognition() else { return nil }
        feed(); await settle { waiter != nil }
        waiter?.resume(returning: Semantic45Probe.result); waiter = nil
        await model.waitForCurrentWork()
        if !probe.emptySources && probe.sourceFailure == nil && !probe.holdSources { await settle { !probe.waits.isEmpty } }
        return model.records.first?.id
    }
    func runSemantic45Checks() async -> [String: Bool] {
        var c: [String: Bool] = [:]
        for scenario in ["success", "background", "withdraw", "account", "delete", "stop", "malformed", "insufficient", "empty", "restart", "providerCancel", "saveFailure", "sourceFailure", "network"] {
            let probe = Semantic45Probe(); probe.emptySources = scenario == "empty"
            if scenario == "sourceFailure" { probe.sourceFailure = .init(stage: .sourceSearch, code: .network, status: -1009) }
            let host = C2FixtureHost(name: "semantic45-" + scenario)
            try? FileManager.default.removeItem(at: host.root)
            host.model = host.makeModel(semantic: probe); await host.model.bootstrap()
            guard let id = await host.recognize45(probe), let initial = host.model.records.first else { c[scenario + "_created"] = false; continue }
            c[scenario + "_stage_one_visible_before_review"] = initial.status == .succeeded && initial.result?.text == Semantic45Probe.result.text && initial.presentationResult?.summary == Semantic45Probe.result.summary && !host.model.busy && initial.googleSearch != nil
            switch scenario {
            case "background": host.model.foreground(.background)
            case "withdraw": host.model.withdrawDataUse()
            case "account": host.model.account.selectedID = "generated-new-account"; host.model.accountStateChanged()
            case "delete": c["delete_succeeds_during_optional_review"] = await host.model.deleteRecord(id: id)
            case "stop": host.model.stopSemanticReview(id: id)
            case "saveFailure": host.writeFault.set(true)
            default: break
            }
            if scenario == "restart" {
                let restored = host.makeModel(semantic: probe); await restored.bootstrap()
                c["restart_no_replay"] = probe.calls == 1 && restored.records.first?.semanticReview?.state == .interrupted && restored.records.first?.result == initial.result
                host.model.stopSemanticReview(id: id); probe.finish(id); restored.closePreview()
            } else {
                probe.finish(id, invalid: scenario == "malformed", noMatch: scenario == "insufficient", cancelled: scenario == "providerCancel", networkFailure: scenario == "network")
                await host.model.waitForWikipediaWork()
                await host.settle { host.model.records.first?.semanticReview?.isPending != true }
                let saved = host.model.records.first
                if scenario == "success" || scenario == "background" {
                    if scenario == "background" { c["background62_completes_with_existing_allowance"] = saved?.semanticReview?.state == .succeeded && !host.model.previewOpen }
                    c["same_card_updates_without_changing_original"] = saved?.id == id && saved?.currentAttemptID == id && saved?.result == initial.result && saved?.presentationResult?.summary == Semantic45Probe.answer.summary
                    c["source_role_and_exact_second_raw_saved"] = saved?.currentSemanticReview?.displayTitle == "曙光公司（品牌持有者）" && saved?.semanticJSONDocument?.rawText == probe.lastRaw
                    c["stage_two_share_uses_updated_summary_and_source"] = saved?.shareText().contains(Semantic45Probe.answer.summary) == true && saved?.shareText().contains("品牌持有者") == true
                    c["old_raw_not_invented"] = saved?.modelJSONDocument.rawText == nil
                    c["request54_success_preserves_actual_payload"] = saved?.semanticRequestJSONDocument.rawText?.contains("source_id") == true && saved?.semanticReview?.modelRequest?.delivery == .submitted
                    c["request54_share_has_all_sections"] = saved?.combinedJSONShareText.contains("第一階段回覆") == true && saved?.combinedJSONShareText.contains("第二階段請求") == true && saved?.combinedJSONShareText.contains(probe.lastRaw) == true
                    let oldSourceCalls = probe.sourceCalls
                    await host.model.reloadHistory(); host.model.foreground(.active); await Task.yield()
                    c["repeat_callbacks_no_resubmit"] = probe.calls == 1 && probe.sourceCalls == oldSourceCalls
                } else if scenario == "delete" {
                    c["late_reply_cannot_recreate_deleted_card"] = host.model.records.isEmpty && !FileManager.default.fileExists(atPath: host.root.appendingPathComponent(id.uuidString).path)
                } else {
                    c[scenario + "_keeps_first_stage_and_no_source"] = saved?.result == initial.result && saved?.presentationResult == initial.result && saved?.currentSemanticReview?.source == nil
                    if scenario == "malformed" { c["malformed_raw_retained_for_JSON"] = saved?.semanticJSONDocument?.rawText == "{malformed}" }
                    if scenario == "empty" { c["empty_sources_no_second_request"] = probe.calls == 0 && saved?.semanticReview?.state == .insufficientEvidence }
                    if scenario == "network" {
                        let request = saved?.semanticRequestJSONDocument.rawText
                        c["request54_network_failure_keeps_request_and_no_reply"] = request?.contains("sources") == true && saved?.semanticReview?.modelRequest?.delivery == .submitted && saved?.semanticJSONDocument?.rawText == nil
                        await host.model.reloadHistory()
                        c["request54_network_failure_survives_reload_no_retry"] = host.model.records.first?.semanticRequestJSONDocument.rawText == request && probe.calls == 1
                    }
                    if scenario == "sourceFailure" {
                        c["request54_source_failure_never_invents_request"] = saved?.semanticRequestJSONDocument.rawText == nil && saved?.semanticRequestJSONDocument.message.contains("尚未組成，也未送出") == true
                        c["failed_source_never_calls_model"] = probe.calls == 0 && probe.sourceCalls == 1
                        c["failed_source_is_terminal_with_reason"] = saved?.semanticReview?.state == .failed && saved?.semanticReview?.failure == probe.sourceFailure && saved?.semanticReview?.isPending == false
                        await host.model.reloadHistory(); host.model.foreground(.active); await Task.yield()
                        c["failed_source_reload_preserves_reason_without_retry"] = host.model.records.first?.semanticReview?.failure == probe.sourceFailure && probe.sourceCalls == 1 && probe.calls == 0
                    }

                }
            }
            host.writeFault.set(false)
            c[scenario + "_legacy_path_unused"] = host.model.wikipediaDiagnostics.isEmpty && host.model.records.allSatisfy { $0.wikipedia == nil }
            host.model.closePreview()
        }
        // Hold collection and model completion independently. Evidence writes must
        // not change the complete first-stage card or signal a scroll adjustment.
        for fail in [false, true] {
            let probe = Semantic45Probe(); probe.holdSources = true
            let host = C2FixtureHost(name: "compact55-stability-\(fail)")
            try? FileManager.default.removeItem(at: host.root); host.model = host.makeModel(semantic: probe); await host.model.bootstrap()
            guard let id = await host.recognize45(probe), let initial = host.model.records.first else { c["compact55_created_\(fail)"] = false; continue }
            await host.settle { probe.sourceWait != nil }
            let card = host.model.cardRecord(for: initial)
            var layoutChanges = 0
            host.model.onRecordsWillChange = { layoutChanges += 1 }
            c["compact55_pending_immediately_\(fail)"] = host.model.isSupplementPending(for: initial) && card.presentationResult == initial.result
            probe.finishSources(); await host.settle { !probe.waits.isEmpty }
            let reviewing = host.model.records.first!
            c["compact55_card_and_scroll_frozen_\(fail)"] = host.model.cardRecord(for: reviewing) == card && layoutChanges == 0 && host.model.isSupplementPending(for: reviewing)
            c["compact55_live_request_not_hidden_\(fail)"] = reviewing.semanticRequestJSONDocument.rawText?.contains("\"input_version\":3") == true && reviewing.semanticReview?.sourcesFinishedAt != nil && reviewing.semanticReview?.requestDispatchStartedAt != nil
            probe.finish(id, networkFailure: fail); await host.model.waitForWikipediaWork()
            let final = host.model.records.first!
            c["compact55_one_atomic_final_update_\(fail)"] = layoutChanges == (fail ? 0 : 1) && !host.model.isSupplementPending(for: final) && host.model.cardRecord(for: final) == final && final.id == id && final.result == initial.result
            c["compact55_final_projection_\(fail)"] = fail ? final.presentationResult == initial.result && final.semanticReview?.state == .failed : final.presentationResult?.summary == Semantic45Probe.answer.summary && final.semanticReview?.source != nil
            host.model.closePreview()
        }
        // Two simultaneous cards resolve in reverse order, independently of viewport/new capture.
        let probe = Semantic45Probe(), host = C2FixtureHost(name: "semantic45-order")
        try? FileManager.default.removeItem(at: host.root); host.model = host.makeModel(semantic: probe); await host.model.bootstrap()
        if let first = await host.recognize45(probe), let second = await host.recognize45(probe) {
            await host.settle { probe.waits.count == 2 }
            probe.finish(second); await host.settle { host.model.records.first?.semanticReview?.state == .succeeded }
            c["second_updates_while_first_waits"] = host.model.records.first?.id == second && host.model.records.last?.semanticReview?.isPending == true
            probe.finish(first); await host.model.waitForWikipediaWork()
            c["reverse_order_preserves_each_card_image_attempt"] = host.model.records.map(\.id) == [second, first] && host.model.records.allSatisfy { $0.semanticReview?.recordID == $0.id && $0.semanticReview?.attemptID == $0.currentAttemptID && $0.semanticReview?.state == .succeeded }
        } else { c["two_cards_created"] = false }
        c["zero_real_network"] = C8NetworkProbe.shared.count == 0
        host.model.closePreview(); return c
    }
}
struct Semantic45View: View {
    @State private var host = C2FixtureHost(name: "semantic45-ui")
    @State private var probe = Semantic45Probe()
    @State private var checks = "running"
    @State private var ready = false
    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--semantic45-checks") {
            Text(checks).accessibilityIdentifier("semantic45-checks").task {
                let result = await host.runSemantic45Checks()
                let passed = result.values.allSatisfy { $0 }
                checks = passed ? "passed \(result.count)" : "FAILED " + result.filter { !$0.value }.map(\.key).sorted().joined(separator: ",")
                let receipt: [String: Any] = ["passed": passed, "checks": result, "realModelRequests": 0, "realNetworkRequests": C8NetworkProbe.shared.count]
                try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted,.sortedKeys]).write(to: host.root.deletingLastPathComponent().appendingPathComponent("semantic45-checks.json"))
            }
        } else {
            VStack {
                HStack {
                    Button("合成初步結果") { Task { _ = await host.recognize45(probe) } }
                        .disabled(!ready || !host.model.canStartRecognition)
                        .accessibilityIdentifier("semantic45-start")
                    Button("百科回覆") {
                        if let id = host.model.records.first?.id {
                            probe.finish(id, noMatch: ProcessInfo.processInfo.arguments.contains("--compact55-insufficient"), networkFailure: ProcessInfo.processInfo.arguments.contains("--compact55-failure"))
                        }
                    }.accessibilityIdentifier("semantic45-finish")
                    if ProcessInfo.processInfo.arguments.contains("--compact55-ui") {
                        Button("來源就緒") { probe.finishSources() }.accessibilityIdentifier("compact55-sources")
                    }
                    if ProcessInfo.processInfo.arguments.contains("--title61") || ProcessInfo.processInfo.arguments.contains("--foreign67") {
                        Button("重讀紀錄") {
                            Task {
                                host.model = host.makeModel(semantic: probe)
                                await host.model.bootstrap()
                                host.status = "title61-reloaded"
                            }
                        }.accessibilityIdentifier("title61-reload")
                    }
                }
                Text(host.status).accessibilityIdentifier("semantic54-copy-status")
                if ProcessInfo.processInfo.arguments.contains("--compact55-ui") {
                    Text(host.model.records.first?.semanticReview.map { $0.state.rawValue + ":" + ($0.modelRequest?.delivery.rawValue ?? "none") } ?? "none")
                        .font(.caption).accessibilityIdentifier("compact55-phase")
                }
                if ready { SingleCaptureView(model: host.model, shareProbe: host.shareProbe) } else { ProgressView() }
            }.task {
                UserDefaults.standard.set(true, forKey: "glance.showModelJSON")
                probe.holdSources = ProcessInfo.processInfo.arguments.contains("--compact55-ui")
                try? FileManager.default.removeItem(at: host.root)
                host.model = host.makeModel(semantic: probe); await host.model.bootstrap()
                var expected = "", presented = false, copies = 0
                host.shareProbe.itemsPresented = { items, copyItems in
                    guard let record = host.model.records.first else { return }
                    let next = record.combinedJSONShareText
                    let allSections = next.contains("第一階段回覆") && next.contains("第二階段請求") && next.contains("第二階段回覆")
                    let rawSummaryBound = !ProcessInfo.processInfo.arguments.contains("--summary68") || next.contains(Semantic45Probe.reported68)
                    let originalLanguageBound = rawSummaryBound && (!ProcessInfo.processInfo.arguments.contains("--foreign67") || (next.contains("jawiki:67") && next.contains("ja.wikipedia.org") && next.contains("\"language\":\"ja\"")))
                    presented = allSections && originalLanguageBound && (expected.isEmpty || expected == next) && items.count == 1 && items.first as? String == next && copyItems.count == 1 && Set(copyItems[0].keys) == [UTType.utf8PlainText.identifier] && copyItems[0][UTType.utf8PlainText.identifier] as? String == next
                    expected = next
                }
                host.shareProbe.activityCompleted = { kind, completed in
                    guard completed, kind == UIActivity.ActivityType.copyToPasteboard.rawValue else { return }
                    let items = UIPasteboard.general.items
                    let value = items.first?[UTType.utf8PlainText.identifier]
                    let copied = (value as? String) ?? (value as? Data).flatMap { String(data: $0, encoding: .utf8) }
                    if presented && items.count == 1 && items.first?.count == 1 && copied == expected { copies += 1; host.status = "semantic54-copy-verified-\(copies)" }
                    else { host.status = "FAILED-semantic54-copy" }
                }
                ready = true
            }
        }
    }
}

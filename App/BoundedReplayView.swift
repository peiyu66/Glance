import SwiftUI

/// No ordinary UI routes here. Both command-line identity and an external permit are required.
@MainActor @Observable final class BoundedSavedReplayCoordinator {
    private(set) var status = "準備受限回放"
    private(set) var model: SingleCaptureController?
    private(set) var completed = false
    private(set) var checks: [String: Bool] = [:]
    private(set) var summaries: [[String: String]] = []
    let shareProbe = SummaryCardProbe()
    private let arguments: [String]
    private let documents: URL
    private let history: URL
    private let build: String
    private let consent: DataConsentController
    private let accountFactory: () -> SIWCController
    private let lookup: @Sendable (RecognitionResult) async -> WikipediaEnrichment
    private var started = false
    private var cancelled = false
    private var stage = "notStarted"
    private var store: BoundedReplayStore?
    init(arguments: [String], documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
         history: URL = RecognitionArchive.defaultRoot(), build: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
         consent: DataConsentController = .shared, accountFactory: @escaping () -> SIWCController = { SIWCController() },
         lookup: @escaping @Sendable (RecognitionResult) async -> WikipediaEnrichment = { await WikipediaLookupService.shared.lookupReferences(for: $0) }) {
        self.arguments = arguments; self.documents = documents; self.history = history; self.build = build
        self.consent = consent; self.accountFactory = accountFactory; self.lookup = lookup
        shareProbe.interceptPreparedShare = { [weak self] content in self?.inspectShare(content); return true }
    }
    static func requested(_ arguments: [String]) -> Bool { arguments.contains { $0.hasPrefix("--bounded-saved-replay") } }
    func run() async {
        guard !started else { return }; started = true
        do {
            stage = "permitValidation"
            let prefix = "--bounded-saved-replay=", hashPrefix = "--bounded-saved-replay-sha="
            let ids = arguments.filter { $0.hasPrefix(prefix) }, hashes = arguments.filter { $0.hasPrefix(hashPrefix) }
            guard ids.count == 1, hashes.count == 1, let id = UUID(uuidString: String(ids[0].dropFirst(prefix.count))),
                  consent.allowsTransfer, !cancelled else { throw BoundedReplayStore.Failure.invalidPermit }
            let base = documents.appendingPathComponent("GlanceBoundedReplay", isDirectory: true)
            let store = try BoundedReplayStore(requestURL: base.appendingPathComponent("request.json"),
                runsRoot: base.appendingPathComponent("runs", isDirectory: true), historyRoot: history,
                runID: id, expectedRequestSHA256: String(hashes[0].dropFirst(hashPrefix.count)), build: build)
            self.store = store
            stage = "existingAccount"
            let account = accountFactory(); account.load()
            guard account.planAccessReady else { throw SIWCError.planDisabled }
            let model = SingleCaptureController(consent: consent, account: account,
                archive: RecognitionArchive(root: store.runDirectory.appendingPathComponent("records", isDirectory: true)),
                permission: { false }, previewStart: { _ in preconditionFailure("Replay never opens a camera") }, previewStop: {},
                wikipediaReferencesLookup: lookup, loadAccount: false, requestTimeout: .seconds(90))
            self.model = model
            await model.reloadHistory() // Only the new isolated directory; never loads original history.
            checks["isolated_archive_initially_empty"] = model.records.isEmpty
            for (index, sample) in store.prepared.enumerated() {
                guard !cancelled, consent.allowsTransfer, model.canStartRecognition else { throw CancellationError() }
                try store.claim(sample.source.id)
                stage = "recognition"
                status = "正在回放 \(index + 1)/2"
                try report()
                guard let outputID = model.beginSavedReplay(sample, validatePermit: { [weak self] in
                    guard let self, !self.cancelled else { throw CancellationError() }
                    try store.validateClaim(sample.source.id)
                }) else { throw BoundedReplayStore.Failure.exhausted }
                await model.waitForCurrentWork(); await model.waitForWikipediaWork()
                stage = "readbackValidation"
                try store.finish(sample.source.id)
                guard let record = model.records.first(where: { $0.id == outputID }), model.storageError == nil else { throw RecognitionArchive.Failure.invalidRecord }
                let loaded = try await RecognitionArchive(root: model.archive.root).load(recoverPending: false)
                guard let saved = loaded.records.first(where: { $0.id == outputID }) else { throw RecognitionArchive.Failure.invalidRecord }
                let exactImage = try await model.archive.image(for: saved)
                let key = String(sample.source.sequence)
                checks[key + "_same_original_image_bytes"] = exactImage == sample.jpeg
                checks[key + "_new_card_original_retained"] = outputID != sample.source.id && store.originalsUnchanged()
                checks[key + "_readback_and_share_identical"] = saved == record && saved.shareDocument() == record.shareDocument()
                if saved.modelResponses?.isEmpty == false {
                    checks[key + "_raw_response_bound_to_attempt"] = saved.modelResponses?.count == 1 && saved.modelResponses?.first?.attemptID == saved.currentAttemptID && saved.modelResponses?.first?.sourceImageID == outputID
                } else { checks[key + "_no_completed_model_reply_on_failure"] = saved.status == .failed }
                checks[key + "_no_extra_attempt"] = saved.attemptNumber == 1
                summaries.append(["sourceSequence": key, "sourceID": sample.source.id.uuidString, "outputID": outputID.uuidString,
                    "status": saved.status.rawValue, "googleQuery": saved.googleSearch?.query ?? "", "wikipediaTitle": saved.wikipedia?.displayTitle ?? "",
                    "wikipediaURL": saved.wikipedia?.canonicalURL.absoluteString ?? "", "rawSHA256": saved.modelResponses?.first?.sha256 ?? ""])
                try report()
                // Request/parse failure is terminal; never spend another image request to repair it.
                guard saved.status == .succeeded, !cancelled else { throw BoundedReplayStore.Failure.stopped }
            }
            checks["exactly_two_claims_and_requests"] = store.state.claimed.count == 2 && model.requestCount == 2
            checks["original_history_unchanged"] = store.originalsUnchanged()
            try store.stop(); completed = true; stage = "completed"; status = "兩筆回放完成，等待內容驗收"
            try report()
        } catch {
            try? store?.stop()
            status = "已停止；不會自動重送"
            checks["stopped_without_retry"] = true
            try? report()
        }
    }
    /// Used by the isolated local UI harness after importing the actual device run.
    /// It never restores an account or schedules recognition/enrichment.
    func loadReadbackOnly(_ directory: URL) async {
        guard !started else { return }; started = true
        let model = SingleCaptureController(consent: consent, archive: RecognitionArchive(root: directory),
            permission: { false }, previewStart: { _ in preconditionFailure("Readback never opens camera") }, previewStop: {},
            access: { false }, wikipediaReferencesLookup: { _ in preconditionFailure("Readback never queries") }, loadAccount: false)
        self.model = model; await model.reloadHistory()
        completed = model.records.count == 2 && model.records.allSatisfy { $0.status == .succeeded }
        stage = "offlineReadback"; status = completed ? "兩筆離線讀回完成" : "離線讀回未完成"
    }
    func background() {
        cancelled = true; model?.foreground(.background)
        try? store?.stop(); status = "已離開前景；不會自動重送"; try? report()
    }
    var verifiedShareCount: Int {
        model?.records.filter { checks["share_\($0.sequence)"] == true }.count ?? 0
    }
    func interceptURL(_ url: URL, recordID: UUID? = nil) {
        let records = model?.records.filter { recordID == nil || $0.id == recordID } ?? []
        let allowed = records.contains { $0.googleSearch?.googleURL == url || $0.wikipedia?.canonicalURL == url }
        checks["last_link_matches_saved_card"] = allowed
        if let record = records.first(where: { $0.googleSearch?.googleURL == url || $0.wikipedia?.canonicalURL == url }) {
            let kind = record.googleSearch?.googleURL == url ? "google" : "wiki"
            checks["link_\(record.sequence)_\(kind)"] = allowed
        }
        checks["external_link_launch_blocked"] = true
        try? report()
    }
    private func inspectShare(_ content: RecognitionShareContent) {
        guard let model, let jpeg = content.jpeg,
              let record = model.records.first(where: { $0.imageSHA256 == RecognitionArchive.hash(jpeg) }) else {
            checks["last_share_matches_saved_card"] = false; try? report(); return
        }
        let document = record.shareDocument()
        checks["last_share_matches_saved_card"] = content.text == document.plainText && content.document == document
        checks["share_\(record.sequence)"] = checks["last_share_matches_saved_card"]
        checks["share_sheet_and_external_receivers_blocked"] = true
        try? report()
    }
    private func report() throws {
        let base = documents.appendingPathComponent("GlanceBoundedReplay", isDirectory: true)
        if FileManager.default.fileExists(atPath: base.path) {
            let statusData: [String: Any] = ["stage": stage, "status": status, "completed": completed,
                "appBuild": build, "runID": store?.request.runID.uuidString ?? "", "controllerAttemptCount": model?.requestCount ?? 0]
            try BoundedReplayStore.write(JSONSerialization.data(withJSONObject: statusData, options: [.prettyPrinted, .sortedKeys]), to: base.appendingPathComponent("status.json"))
        }
        guard let store else { return }
        let data: [String: Any] = ["schemaVersion": 1, "runID": store.request.runID.uuidString,
            "appBuild": build, "promptRevision": CameraAnswer.promptRevision, "recordedUTC": ISO8601DateFormatter().string(from: Date()),
            "stage": stage, "status": status, "completed": completed, "claims": store.state.claimed.count,
            "controllerAttemptCount": model?.requestCount ?? 0, "completedModelReplyCount": model?.records.filter { $0.modelResponses?.isEmpty == false }.count ?? 0, "cameraStarts": 0,
            "automaticRetries": 0, "newLoginStarted": false, "originalsUnchanged": store.originalsUnchanged(),
            "checks": checks, "results": summaries, "realModelContentAccepted": false]
        try BoundedReplayStore.write(JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]),
            to: store.runDirectory.appendingPathComponent("summary.json"))
    }
}

struct BoundedSavedReplayView: View {
    @State var coordinator: BoundedSavedReplayCoordinator
    @Environment(\.scenePhase) private var scenePhase
    init(arguments: [String]) { _coordinator = State(initialValue: .init(arguments: arguments)) }
    init(coordinator: BoundedSavedReplayCoordinator) { _coordinator = State(initialValue: coordinator) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("受限樣本驗收").font(.title2)
                Text(coordinator.status).accessibilityIdentifier("boundedReplayStatus")
                if coordinator.checks["last_share_matches_saved_card"] == true { Text("分享內容已核對").accessibilityIdentifier("boundedShareVerified") }
                if coordinator.checks["last_link_matches_saved_card"] == true { Text("連結內容已核對").accessibilityIdentifier("boundedLinkVerified") }
                Text("分享核對 \(coordinator.verifiedShareCount)；連結核對 \(coordinator.checks.filter { $0.key.hasPrefix("link_") && $0.value }.count)")
                    .font(.caption).accessibilityIdentifier("boundedVerificationCounts")
                Text("只處理指定兩筆原圖。分享與連結僅核對本機內容，不交給外部 App。").font(.footnote)
                if let model = coordinator.model {
                    ForEach(model.records) { record in
                        ArchivedRecognitionRow(record: record,
                            currentRecord: { model.records.first { $0.id == record.id } },
                            image: { try? await model.archive.image(for: record) }, onOpen: { _ in }, shareProbe: coordinator.shareProbe)
                            .environment(\.openURL, OpenURLAction { url in coordinator.interceptURL(url, recordID: record.id); return .handled })
                            .padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityElement(children: .contain).accessibilityIdentifier("boundedRow-\(record.sequence)")
                    }
                }
            }.padding()
        }
        .environment(\.openURL, OpenURLAction { url in coordinator.interceptURL(url); return .handled })
        .task { await coordinator.run() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { coordinator.background() } }
    }
}

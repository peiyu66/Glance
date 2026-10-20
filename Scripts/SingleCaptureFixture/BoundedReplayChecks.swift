import SwiftUI

private final class BoundedReplayWire: @unchecked Sendable {
    static let shared = BoundedReplayWire()
    private let lock = NSLock()
    private var bodies: [Data] = []
    var count: Int { lock.withLock { bodies.count } }
    func append(_ body: Data) -> Int { lock.withLock { bodies.append(body); return bodies.count } }
    func snapshots() -> [Data] { lock.withLock { bodies } }
}
final class BoundedReplayProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.path == "/v1/responses" else {
            C8NetworkProbe.shared.record(); client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(contentsOf: buffer.prefix(n)) }
        }
        let index = BoundedReplayWire.shared.append(body)
        let fail = ProcessInfo.processInfo.arguments.contains("--bounded-replay-failure")
        let name = index == 1 ? "曙光飲品" : "月光洋芋片", source = index == 1 ? "AURORA DRINK" : "MOON CRISPS"
        let entity = SearchEntity(kind: .product, name: name, aliases: [name], sourceText: source)
        let answer = try! JSONSerialization.data(withJSONObject: ["schema_version": 16, "names": [name + "原味"], "summary": "合成回放驗證", "text": [source.replacingOccurrences(of: " ", with: "\n")], "search_entities": try! JSONSerialization.jsonObject(with: JSONEncoder().encode([entity]))])
        let event = try! JSONSerialization.data(withJSONObject: ["type": "response.output_text.delta", "delta": String(decoding: answer, as: UTF8.self)])
        let data = fail ? Data(#"{"error":{"code":"rate_limit_exceeded"}}"#.utf8) : Data(("data: " + String(decoding: event, as: UTF8.self) + "\n\ndata: {\"type\":\"response.completed\"}\n\n").utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: fail ? 429 : 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": fail ? "application/json" : "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor private final class BoundedReplayFixture {
    let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("bounded-fixture-" + UUID().uuidString)
    var coordinator: BoundedSavedReplayCoordinator!
    var arguments: [String] = []
    var images: [Data] = []
    var accountLoads = 0
    let consent = DataConsentController.fixtureAccepted()
    func prepare() async throws {
        let history = root.appendingPathComponent("history"), archive = RecognitionArchive(root: history)
        var samples: [BoundedReplayRequest.Sample] = []
        for index in 0..<2 {
            let id = UUID(), jpeg = C2FixtureHost.jpeg(index == 0 ? .red : .blue); images.append(jpeg)
            _ = try await archive.create(id: id, jpeg: jpeg, capturedAt: Date())
            let record = try await archive.complete(id: id, result: .init(names: ["原始合成卡"], searchContractVersion: 14, searchEntities: []), message: nil)
            let bytes = try Data(contentsOf: history.appendingPathComponent(id.uuidString + "/record.json"))
            samples.append(.init(id: id, sequence: record.sequence, recordSHA256: RecognitionArchive.hash(bytes), imageSHA256: record.imageSHA256, imageByteCount: record.imageByteCount))
        }
        let permit = BoundedReplayRequest(schemaVersion: 1, runID: UUID(), appBuild: "321", promptRevision: CameraAnswer.promptRevision,
            expiresAt: Date().addingTimeInterval(300).timeIntervalSince1970, samples: samples)
        let raw = try JSONEncoder().encode(permit), base = root.appendingPathComponent("GlanceBoundedReplay")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try raw.write(to: base.appendingPathComponent("request.json"))
        arguments = ["--bounded-saved-replay=" + permit.runID.uuidString, "--bounded-saved-replay-sha=" + RecognitionArchive.hash(raw)]
        coordinator = makeCoordinator()
    }
    func makeCoordinator() -> BoundedSavedReplayCoordinator {
        BoundedSavedReplayCoordinator(arguments: arguments, documents: root, history: root.appendingPathComponent("history"), build: "321", consent: consent,
            accountFactory: { [self] in
                accountLoads += 1
                let tokens = SIWCTokens(access: "synthetic-access", refresh: nil, idToken: "synthetic-id", scope: SIWCProtocol.scopes, expiresAt: Date().addingTimeInterval(3600))
                let a = SIWCAccount(clientID: "synthetic-client", subject: "synthetic-subject", tokens: tokens)
                let model = SIWCController(beginSignIn: { preconditionFailure("No login") }, dataTransferRevision: { self.consent.epoch }, allowsDataTransfer: { self.consent.allowsTransfer },
                    authSaveSession: { _ in preconditionFailure("No account writes") }, authLoadSession: { SIWCSaved(hostID: "synthetic-host", accounts: [a], selected: a.id) })
                model.catalog = [.init(slug: "gpt-6-luna", display_name: "Synthetic", visibility: "list")]; return model
            }, lookup: { result in
                guard let entity = SearchEntity.matching(result).first else { return .init() }
                let title = entity.name == "曙光飲品" ? "曙光公司" : "月光公司"
                let row: [String: Any] = ["pageid": entity.name == "曙光飲品" ? 3901 : 3902, "ns": 0, "title": title,
                    "canonicalurl": "https://zh.wikipedia.org/wiki/" + title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!, "extract": "\(title)是一家食品製造商。\(title)製造\(entity.name)。"]
                let page = EntityWikipediaPage.parse(row, entities: SearchEntity.matching(result))!
                return .init(subject: EntityWikipediaEvidence.verify(page: page, entity: entity, in: result).0?.reference(for: result, at: Date()))
            })
    }
    func checks() async throws -> [String: Bool] {
        await coordinator.run()
        let failed = ProcessInfo.processInfo.arguments.contains("--bounded-replay-failure")
        var checks = coordinator.checks
        let before = BoundedReplayWire.shared.count
        checks["bounded_actual_wire_count"] = before == (failed ? 1 : 2)
        checks["completion_matches_request_outcome"] = coordinator.completed == !failed
        checks["ordinary_launch_not_routed_to_replay"] = !BoundedSavedReplayCoordinator.requested(["Glance"])
        checks["no_camera_preview"] = coordinator.model?.previewOpen == false
        checks["existing_account_loaded_only_once"] = accountLoads == 1
        for (index, data) in BoundedReplayWire.shared.snapshots().enumerated() {
            let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let content = (root["input"] as! [[String: Any]])[0]["content"] as! [[String: String]]
            checks["request_\(index)_exact_original_bytes"] = content.first { $0["type"] == "input_image" }?["image_url"] == "data:image/jpeg;base64," + images[index].base64EncodedString()
            checks["request_\(index)_formal_P19_prompt"] = content.first?["text"] == CameraAnswer.prompt && root["model"] as? String == "gpt-6-luna"
            let format = (root["text"] as? [String: Any])?["format"] as? [String: Any]
            checks["request_\(index)_schema17"] = format?["name"] as? String == "glance_camera_v17"
        }
        await coordinator.run()
        checks["same_coordinator_never_repeats"] = BoundedReplayWire.shared.count == before
        let restart = makeCoordinator(); await restart.run()
        checks["relaunch_consumed_permit_never_sends_or_loads_account"] = BoundedReplayWire.shared.count == before && accountLoads == 1 && restart.model == nil
        checks["all_network_intercepted"] = C8NetworkProbe.shared.count == 0
        if !failed {
            checks["two_originals_to_two_separate_result_cards"] = coordinator.model?.records.count == 2
            checks["schema16_response_parsed_and_variant_display_preserved"] = coordinator.model?.records.allSatisfy { $0.result?.searchContractVersion == 16 && $0.result?.names.first?.hasSuffix("原味") == true && $0.result?.searchEntities?.first?.name.hasSuffix("原味") == false } == true
            checks["formal_Wiki_save_and_share_agree"] = coordinator.model?.records.allSatisfy { $0.wikipedia != nil && $0.shareDocument().links.count == 2 && $0.googleSearch != nil } == true
        } else {
            checks["failure_is_not_automatically_retried"] = coordinator.model?.records.count == 1 && coordinator.model?.records.first?.attemptNumber == 1 && coordinator.model?.records.first?.status == .failed
        }
        return checks
    }
}
struct BoundedReplayChecksView: View {
    @State private var fixture = BoundedReplayFixture()
    @State private var displayCoordinator: BoundedSavedReplayCoordinator?
    @State private var status = "running"
    var body: some View {
        Group {
            if let displayCoordinator {
                BoundedSavedReplayView(coordinator: displayCoordinator)
                    .overlay(alignment: .bottom) {
                        if ProcessInfo.processInfo.arguments.contains("--bounded-replay-readback") {
                            Text("offline-wire-\(BoundedReplayWire.shared.count)-other-\(C8NetworkProbe.shared.count)")
                                .font(.caption2).accessibilityIdentifier("boundedOfflineNetwork")
                        }
                    }
            } else { Text(status).accessibilityIdentifier("boundedReplayChecks") }
        }.task {
            do {
                let args = ProcessInfo.processInfo.arguments
                if args.contains("--bounded-replay-readback") {
                    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    let readback = BoundedSavedReplayCoordinator(arguments: [], documents: documents, consent: .fixtureAccepted())
                    // Same frozen P17/P18 replies, reprocessed by the current core.
                    // Earlier derived archives remain intact in their old folders.
                    var folder = args.contains("--bounded-replay-han42") ? "GlanceManufacturing43P18" : args.contains("--bounded-replay-corrected") ? "GlanceManufacturing43P17" : "GlanceBoundedReplayReadback"
                    for name in ["FrontBack", "BrandProduct", "RotatedFront"] where args.contains("--bounded-replay43-" + name) {
                        folder = "GlanceManufacturing43" + name
                    }
                    await readback.loadReadbackOnly(documents.appendingPathComponent(folder + "/records"))
                    displayCoordinator = readback; return
                }
                try await fixture.prepare()
                if args.contains("--bounded-replay-seeded-readback") {
                    await fixture.coordinator.run()
                    let before = BoundedReplayWire.shared.count
                    let readback = BoundedSavedReplayCoordinator(arguments: [], documents: fixture.root, consent: fixture.consent)
                    await readback.loadReadbackOnly(fixture.coordinator.model!.archive.root)
                    await readback.run()
                    guard BoundedReplayWire.shared.count == before, before == 2, fixture.accountLoads == 1 else {
                        status = "FAILED readback caused request"; return
                    }
                    displayCoordinator = readback; return
                }
                if args.contains("--bounded-replay-ui") { displayCoordinator = fixture.coordinator; return }
                let checks = try await fixture.checks(), passed = checks.values.allSatisfy { $0 }
                let raw: [String: Any] = ["passed": passed, "count": checks.count, "checks": checks, "realAIRequests": 0, "deviceOperations": 0]
                let name = ProcessInfo.processInfo.arguments.contains("--bounded-replay-failure") ? "bounded-replay-failure.json" : "bounded-replay-success.json"
                try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]).write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name))
                status = passed ? "passed \(checks.count)" : "FAILED " + checks.filter { !$0.value }.map(\.key).joined(separator: ",")
            } catch { status = "FAILED fixture setup" }
        }
    }
}

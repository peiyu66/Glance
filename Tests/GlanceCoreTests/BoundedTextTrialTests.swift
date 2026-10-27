import Foundation
import Testing
@testable import GlanceCore

private struct TextTrialFiles {
    let root: URL
    let cases: [TextTrialCase]
    let permit: TextTrialPermit
    let hash: String
    let bodies: [Data]
    init(changePermit: ((inout [String: Any]) -> Void)? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("GlanceTextTrialTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("input"), withIntermediateDirectories: true)
        let result = RecognitionResult(names: ["曙光"], summary: "原始簡介", text: ["AURORA"], searchContractVersion: 17,
            searchEntities: [.init(kind: .brand, name: "曙光", sourceText: "AURORA")])
        let source = WikipediaReviewSource(pageID: 4501, title: "曙光公司", url: URL(string: "https://zh.wikipedia.org/wiki/Aurora")!, fetchedAt: Date(), excerpts: [.init(id: "p0", text: "曙光公司持有曙光品牌，產品包含合成驗證用零食。")])
        var specs: [TextTrialCase] = [], data: [Data] = []
        for id in [152, 153, 149, 147] {
            let raw = try WikipediaSemanticReview.request(result: result, rawStageOne: "{\"original\":\(id)}", sources: [source], catalog: [.init(slug: "gpt-6-luna", display_name: "Synthetic", visibility: "list")])
            var value = try JSONSerialization.jsonObject(with: raw) as! [String: Any]; value["max_output_tokens"] = TextTrialContract.maxOutputTokens
            value["text"] = ["format": WikipediaSemanticReview.legacyFormatW1]
            // The historical four-request trial pins input v1, independently of
            // the current product's v3 language-tagged request builder.
            var input = value["input"] as! [[String: Any]]
            input[0]["content"] = [["type": "input_text", "text": WikipediaSemanticReview.legacyPromptW1]]
            var content = input[1]["content"] as! [[String: String]]
            var payload = try JSONSerialization.jsonObject(with: Data(content[0]["text"]!.utf8)) as! [String: Any]
            payload["input_version"] = 1; payload["raw_stage_one_json"] = "{\"original\":\(id)}"
            // Remove v3 source language metadata to reconstruct the immutable v1 trial contract.
            payload["sources"] = (payload["sources"] as! [[String: Any]]).map { source in
                var original = source; original.removeValue(forKey: "language"); return original
            }
            var stage = payload["stage_one"] as! [String: Any]; stage.removeValue(forKey: "text_is_partial"); payload["stage_one"] = stage
            content[0]["text"] = String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
            input[1]["content"] = content; value["input"] = input
            let body = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); data.append(body)
            try body.write(to: root.appendingPathComponent("input/\(id).json")); specs.append(.init(sequence: id, bodySHA256: RecognitionArchive.hash(body), byteCount: body.count))
        }
        bodies = data; cases = specs
        let now = Date().timeIntervalSince1970
        var value: [String: Any] = ["schemaVersion": 2, "runID": UUID().uuidString, "appBuild": "48", "catalogSHA256": try TextTrialContract.catalogHash(specs),
            "issuedAt": now - 1, "expiresAt": now + 300, "consentRevision": TextTrialContract.revision, "allowsFourTextRequests": true, "allowsExistingGrantRefresh": true, "maximumRefreshRequests": 1,
            "maximumRequests": 4, "maximumOutputTokens": TextTrialContract.maxOutputTokens]
        changePermit?(&value)
        let raw = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); hash = RecognitionArchive.hash(raw)
        permit = try JSONDecoder().decode(TextTrialPermit.self, from: raw); try raw.write(to: root.appendingPathComponent("permit.json"))
    }
    func open(beforeWrite: @escaping (URL) throws -> Void = { _ in }) throws -> TextTrialStore {
        try TextTrialStore(base: root, runID: permit.runID, permitSHA256: hash, build: "48", cases: cases, beforeWrite: beforeWrite)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test func textTrialFourExactBodiesAreClaimedOnceAndOrderIsBounded() throws {
    let files = try TextTrialFiles(); defer { files.remove() }; let store = try files.open()
    #expect(store.prepared.map(\.body) == files.bodies)
    #expect(throws: Error.self) { try store.claim(153) }
    for id in [152,153,149,147] {
        try store.claim(id)
        #expect(throws: Error.self) { try store.claim(id) }
        try store.validateClaim(id); try store.finish(id)
        #expect(throws: Error.self) { try store.validateClaim(id) }
    }
    #expect(throws: Error.self) { try store.claim(152) }; try store.stop()
    let saved = try JSONDecoder().decode(TextTrialStore.State.self, from: Data(contentsOf: store.runDirectory.appendingPathComponent("state.json")))
    #expect(saved.claimed == [152,153,149,147] && saved.finished == saved.claimed && saved.terminal)
}
@Test func textTrialRestartCannotResumeEvenWithCopiedPermit() throws {
    let f = try TextTrialFiles(); defer { f.remove() }; let original = try Data(contentsOf: f.root.appendingPathComponent("permit.json")); let store = try f.open()
    try store.claim(152); try original.write(to: f.root.appendingPathComponent("permit.json"))
    #expect(throws: Error.self) { try f.open() }
    #expect(store.state.claimed == [152])
}
@Test func textTrialCancellationAndExpiryPreventLateFinish() throws {
    let f = try TextTrialFiles(); defer { f.remove() }; let s = try f.open(); try s.claim(152)
    #expect(throws: Error.self) { try s.validateClaim(152, now: Date(timeIntervalSince1970: f.permit.expiresAt + 1)) }
    try s.stop(); #expect(throws: Error.self) { try s.finish(152) }; #expect(throws: Error.self) { try s.claim(153) }
}
@Test func textTrialInvalidPermitVariantsNeverConsumeInput() throws {
    let mutations: [(inout [String: Any]) -> Void] = [
        { $0["schemaVersion"] = 1 }, { $0["allowsExistingGrantRefresh"] = false }, { $0["maximumRefreshRequests"] = 2 }, { $0["maximumRequests"] = 5 }, { $0["maximumOutputTokens"] = 9000 }, { $0["allowsFourTextRequests"] = false },
        { $0["consentRevision"] = "old" }, { $0["expiresAt"] = 0.0 }, { $0["issuedAt"] = Date().timeIntervalSince1970 + 100 },
        { $0["expiresAt"] = Date().timeIntervalSince1970 + 1000 }, { $0["appBuild"] = "45" }, { $0["catalogSHA256"] = String(repeating: "0", count: 64) }
    ]
    for mutate in mutations {
        let f = try TextTrialFiles(changePermit: mutate); defer { f.remove() }
        #expect(throws: Error.self) { try f.open() }; #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("permit.json").path))
    }
}
@Test func textTrialModifiedOrSymlinkedBodyPreventsEveryRequest() throws {
    for symlink in [false,true] {
        let f = try TextTrialFiles(); defer { f.remove() }; let target = f.root.appendingPathComponent("input/147.json")
        if symlink {
            try FileManager.default.removeItem(at: target)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: f.root.appendingPathComponent("input/152.json"))
        } else { try Data("modified".utf8).write(to: target) }
        #expect(throws: Error.self) { try f.open() }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("runs").path))
    }
}
@Test func textTrialFailedDurableClaimNeverAuthorizesSend() throws {
    let f = try TextTrialFiles(); defer { f.remove() }; var writes = 0
    let s = try f.open { _ in writes += 1; if writes == 2 { throw CocoaError(.fileWriteOutOfSpace) } }
    #expect(throws: Error.self) { try s.claim(152) }; #expect(s.state.claimed.isEmpty)
    #expect(throws: Error.self) { try s.validateClaim(152) }
}
@Test func textTrialFailedInitialStateWriteStillConsumesPermit() throws {
    let f = try TextTrialFiles(); defer { f.remove() }
    #expect(throws: Error.self) { try f.open { _ in throw CocoaError(.fileWriteOutOfSpace) } }
    #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("permit.json").path))
    #expect(throws: Error.self) { try f.open() }
}
@Test func textTrialOutputCapDoesNotAlterPromptSchemaOrInput() throws {
    let f = try TextTrialFiles(); defer { f.remove() }
    for body in f.bodies {
        #expect(try TextTrialContract.sources(in: body).count == 1)
        let value = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        #expect(value["max_output_tokens"] as? Int == 8192)
        #expect(((value["text"] as? [String: Any])?["format"] as? NSDictionary) == WikipediaSemanticReview.legacyFormatW1 as NSDictionary)
    }
    #expect(SIWCSafeDiagnostic.parameter("max_output_tokens") == "max_output_tokens")
}
@Test func textTrialImagesToolsOrUncappedBodyAreRejected() throws {
    let f = try TextTrialFiles(); defer { f.remove() }
    let original = try JSONSerialization.jsonObject(with: f.bodies[0]) as! [String: Any]
    let mutations: [(inout [String: Any]) -> Void] = [
        { $0.removeValue(forKey: "max_output_tokens") }, { $0["max_output_tokens"] = 16384 },
        { $0["tools"] = [["type":"web_search"]] }, { $0["input"] = [["role":"user","content":[["type":"input_image","image_url":"data:image/png;base64,AAAA"]]]] },
        { $0["model"] = "different" }, { $0["reasoning"] = ["effort":"high"] }
    ]
    for mutate in mutations { var v = original; mutate(&v); #expect(throws: Error.self) { try TextTrialContract.sources(in: JSONSerialization.data(withJSONObject: v)) } }
}

@Test func textTrialRefreshClaimIsDurableSingleUseAndBeforeModelOnly() throws {
    let f = try TextTrialFiles(); defer { f.remove() }; let s = try f.open()
    try s.claimRefresh()
    #expect(s.state.refreshClaimed)
    let disk = try JSONDecoder().decode(TextTrialStore.State.self,from:Data(contentsOf:s.runDirectory.appendingPathComponent("state.json")))
    #expect(disk.refreshClaimed)
    #expect(throws: Error.self) { try s.claimRefresh() }
    try s.claim(152); try s.finish(152)
    #expect(throws: Error.self) { try s.claimRefresh() }
}
@Test func textTrialRefreshFailedClaimOrModelAlreadyClaimedPreventsRefresh() throws {
    let f = try TextTrialFiles(); defer { f.remove() }; var writes = 0
    let s = try f.open { _ in writes += 1; if writes == 2 { throw CocoaError(.fileWriteOutOfSpace) } }
    #expect(throws: Error.self) { try s.claimRefresh() }; #expect(!s.state.refreshClaimed)
    let other = try TextTrialFiles(); defer { other.remove() }; let t = try other.open(); try t.claim(152)
    #expect(throws: Error.self) { try t.claimRefresh() }
}

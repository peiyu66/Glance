// Explicit bounded diagnostic for Build 6. Never included in the App or normal tests.
// Compile together with Sources/GlanceCore/*.swift; uses the actual production client.
// Authorization: three public samples, at most 3 HTTP attempts per sample INCLUDING
// continuation runs. Existing successful responses may be replayed without networking.
import Foundation

private struct Receipt: Codable, Sendable {
    var number: Int; var url: String; var status: Int?; var responseURL: String?
    var file: String?; var milliseconds: Double?; var error: String?
}
private actor EvidenceTransport {
    let directory: URL; let mode: String
    var receipts: [Receipt]
    var replayed = 0
    init(directory: URL, mode: String) throws {
        self.directory = directory; self.mode = mode
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = directory.appendingPathComponent("requests.json")
        receipts = FileManager.default.fileExists(atPath: manifest.path) ? try JSONDecoder().decode([Receipt].self, from: Data(contentsOf: manifest)) : []
        if mode == "live", !receipts.isEmpty { throw CocoaError(.fileWriteFileExists) }
    }
    func save() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipts).write(to: directory.appendingPathComponent("requests.json"), options: .atomic)
    }
    func fetch(_ request: URLRequest) async throws -> WikipediaHTTPResponse {
        guard let url = request.url, url.scheme == "https", url.host == "zh.wikipedia.org", url.path == "/w/api.php",
              request.httpBody == nil, request.value(forHTTPHeaderField: "Authorization") == nil else { throw URLError(.badURL) }
        if mode != "live", let old = receipts.first(where: { $0.url == url.absoluteString }) {
            guard old.error == nil, old.status == 200, let file = old.file else { throw URLError(.cannotLoadFromNetwork) }
            replayed += 1
            return .init(data: try Data(contentsOf: directory.appendingPathComponent(file)), status: old.status!, url: old.responseURL.flatMap(URL.init(string:)))
        }
        guard mode != "replay", receipts.count < 3, !receipts.contains(where: { $0.error != nil || $0.status != 200 }) else { throw URLError(.cannotLoadFromNetwork) }
        let number = receipts.count + 1, index = receipts.count
        receipts.append(.init(number: number, url: url.absoluteString))
        try save() // Consume the attempt before sending; a crash never resets its budget.
        let start = ContinuousClock.now
        do {
            let response = try await WikipediaLookupService.fetch(request)
            let file = "response-\(number).json"
            try response.data.write(to: directory.appendingPathComponent(file), options: .atomic)
            receipts[index].status = response.status; receipts[index].responseURL = response.url?.absoluteString
            receipts[index].file = file; receipts[index].milliseconds = durationMS(start.duration(to: .now))
            try save(); return response
        } catch {
            receipts[index].error = String(describing: error); receipts[index].milliseconds = durationMS(start.duration(to: .now))
            try save(); throw error
        }
    }
    func snapshot() -> [Receipt] { receipts }
    func replayCount() -> Int { replayed }
}
private func durationMS(_ duration: Duration) -> Double {
    let c = duration.components; return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
}
private func sample(_ name: String, category: PublicSearchQuery.Category, classes: [String], candidates: [WikipediaTopics.Candidate]) -> RecognitionResult {
    .init(names: [name], text: [name], wikipediaTopics: .init(category: category, automaticWikipediaAllowed: true, classTerms: classes, candidates: candidates))
}
@main struct WikipediaTopicsLiveCheck {
    static func main() async throws {
        guard CommandLine.arguments.count == 3, ["live", "replay", "continue"].contains(CommandLine.arguments[2]) else { fatalError("Usage: program EVIDENCE_DIRECTORY live|replay|continue") }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true), mode = CommandLine.arguments[2]
        let name = "樂事 樂連連 洋芋片"
        let samples: [(String, RecognitionResult)] = [
            ("lays", sample(name, category: .product, classes: ["洋芋片", "薯片"], candidates: [.init(topic: "樂連連", kind: .series, evidence: name), .init(topic: "樂事", kind: .brand, evidence: name)])),
            ("fan", sample("電風扇", category: .object, classes: ["電器", "風扇"], candidates: [.init(topic: "電風扇", kind: .subject, evidence: "電風扇")])),
            ("kellens", sample("Kellens 紙品", category: .product, classes: ["紙品", "紙巾"], candidates: [.init(topic: "Kellens", kind: .brand, evidence: "Kellens 紙品")]))
        ]
        var rows: [[String: Any]] = []
        for (ordinal, entry) in samples.enumerated() {
            if mode != "replay", ordinal > 0 { try await Task.sleep(for: .seconds(2)) }
            let (key, result) = entry, folder = directory.appendingPathComponent(entry.0, isDirectory: true)
            let transport = try EvidenceTransport(directory: folder, mode: mode)
            guard let subject = WikipediaSubject.matching(result, allowLegacy: false) else { fatalError("Approved sample did not pass production admission") }
            let service = WikipediaLookupService(transport: { try await transport.fetch($0) })
            let start = ContinuousClock.now, reference = await service.lookup(subject)
            let elapsed = durationMS(start.duration(to: .now)), receipts = await transport.snapshot()
            var details: [[String: Any]] = []
            for receipt in receipts {
                var row: [String: Any] = ["attempt": receipt.number, "url": receipt.url, "status": receipt.status ?? 0, "error": receipt.error ?? ""]
                guard let file = receipt.file else { details.append(row); continue }
                let data = try Data(contentsOf: folder.appendingPathComponent(file))
                let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                row["bytes"] = data.count; row["apiError"] = raw?["error"] ?? NSNull(); row["apiWarnings"] = raw?["warnings"] ?? NSNull()
                row["productionPayloadAccepted"] = WikipediaSubject.pages(in: data) != nil
                let items = URLComponents(string: receipt.url)?.queryItems ?? []
                if let query = items.first(where: { $0.name == "gsrsearch" })?.value,
                   let index = (0..<subject.candidateCount).first(where: { subject.query(at: $0) == query }) {
                    let pages = (raw?["query"] as? [String: Any])?["pages"] as? [[String: Any]] ?? []
                    row["query"] = query
                    row["returnedPages"] = pages.map { page -> [String: Any] in
                        let extract = page["extract"] as? String ?? "", cats = (page["categories"] as? [[String: Any]])?.compactMap { $0["title"] as? String } ?? []
                        return ["title": page["title"] ?? "", "redirects": page["redirects"] ?? [], "categories": cats,
                                "validExtract": WikipediaReference.validExtract(extract), "personGuard": WikipediaSubject.rejectsPerson(extract, categories: cats)]
                    }
                    if let page = subject.page(from: data, at: index) {
                        row["identityPage"] = page.title; row["match"] = page.match.rawValue
                        row["relationQualifiedFromIntro"] = subject.reference(page, at: Date()) != nil
                        row["needsExtendedExtract"] = subject.needsExtendedExtract(page)
                    } else { row["rejection"] = "No unique eligible exact title/API alias page after production namespace, URL, extract, disambiguation and person guards." }
                } else { row["singlePageExtract"] = true }
                details.append(row)
            }
            var row: [String: Any] = ["sample": key, "names": result.names, "subjectKey": subject.key,
                                     "attemptsTotalIncludingEarlierRuns": receipts.count, "replayedResponsesThisRun": await transport.replayCount(),
                                     "lookupMS": elapsed, "matched": reference != nil, "requests": details]
            if let reference { row["reference"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reference)) }
            rows.append(row)
            // Stop this diagnostic rather than retry any actual transport or HTTP failure.
            if receipts.contains(where: { $0.error != nil || $0.status != 200 }) { break }
        }
        let output: [String: Any] = ["mode": mode, "recordedAt": ISO8601DateFormatter().string(from: Date()), "maximumHTTPPerSampleAcrossRuns": 3,
                                     "AIRequests": 0, "privateInputs": false, "physicalDeviceOperations": 0, "results": rows]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("summary-\(mode).json"), options: .atomic)
        for row in rows { print("\(row["sample"]!): matched=\(row["matched"]!) HTTP=\(row["attemptsTotalIncludingEarlierRuns"]!) replayed=\(row["replayedResponsesThisRun"]!)") }
    }
}

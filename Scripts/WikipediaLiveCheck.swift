// Explicit, bounded manual diagnostic. Never included in the App target or normal tests.
// Build with: swiftc -parse-as-library Sources/GlanceCore/*.swift Scripts/WikipediaLiveCheck.swift -o /tmp/wiki-check
// Run only with authorization for these three non-sensitive public entity names.
import Foundation

@main struct WikipediaLiveCheck {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Supply a local evidence directory") }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let samples = [("望遠鏡", "object"), ("電風扇", "object"), ("Sony α7 III", "product")]
        var rows: [[String: Any]] = []
        for (index, sample) in samples.enumerated() {
            if index > 0 { try await Task.sleep(for: .seconds(2)) }
            let result = RecognitionResult(names: [sample.0], searchQuery: PublicSearchQuery(query: sample.0, category: sample.1, automaticWikipediaAllowed: true))
            guard let subject = WikipediaSubject.matching(result) else { fatalError("Public diagnostic sample rejected") }
            do {
                let response = try await WikipediaLookupService.fetch(subject.request)
                try response.data.write(to: directory.appendingPathComponent("response-\(index + 1).json"))
                let reference = response.status == 200 && response.url == subject.request.url ? subject.reference(from: response.data, at: Date()) : nil
                let json = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any]
                let query = json?["query"] as? [String: Any]
                let pages = query?["pages"] as? [[String: Any]]
                rows.append(["query": sample.0, "category": sample.1, "status": response.status,
                             "bytes": response.data.count, "sameEndpoint": response.url == subject.request.url,
                             "returnedTitles": pages?.compactMap { $0["title"] as? String } ?? [],
                             "matched": reference != nil, "canonicalURL": reference?.canonicalURL.absoluteString ?? "",
                             "title": reference?.title ?? "", "match": reference?.match.rawValue ?? "",
                             "apiError": json?["error"] ?? NSNull(), "apiWarnings": json?["warnings"] ?? NSNull()])
                if response.status != 200 || json?["error"] != nil { break }
            } catch {
                rows.append(["query": sample.0, "error": String(describing: error)]); break
            }
        }
        let summary: [String: Any] = ["requestsAttempted": rows.count, "maximumRequests": 3, "automaticRetries": 0,
                                     "AIRequests": 0, "privateInputs": false, "results": rows]
        let encoded = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .prettyPrinted])
        try encoded.write(to: directory.appendingPathComponent("summary.json"))
        print(String(decoding: encoded, as: UTF8.self))
    }
}

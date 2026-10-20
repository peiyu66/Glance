// Appended only to the generated fixture's exact SingleCaptureController.swift.
// Starts at the first-stage persistence boundary, without camera/model transport.
extension SingleCaptureController {
    func seedSavedStageOneForReplay(result: RecognitionResult, raw: String, jpeg: Data) async throws {
        let id = UUID()
        let created = try await archive.create(id: id, jpeg: jpeg, capturedAt: Date())
        onRecordsWillChange?(); records.insert(created, at: 0)
        let trace = RecognitionModelResponse.capture(raw, sourceImageID: id, attemptID: id,
            appVersion: "historical-replay", appBuild: "P18-saved", promptRevision: "P18-historical-saved-input")
        await persistCompletion(id: id, attemptID: id, result: result.withSourceImage(id), message: nil, date: Date(), timedOut: false, modelResponse: trace)
        scheduleWikipedia(for: id)
    }
}

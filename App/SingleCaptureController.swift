import SwiftUI
@preconcurrency import AVFoundation

@MainActor @Observable final class SingleCaptureController {
    static let shared = SingleCaptureController()
    let capture = CameraCapture()
    let account: SIWCController
    let consent: DataConsentController
    var showingOnboarding = false
    let archive: RecognitionArchive
    private(set) var cycle = SingleCaptureCycle()
    private(set) var records: [ArchivedRecognition] = []
    // A synchronous layout snapshot must precede publication; SwiftUI onChange
    // can run after the new row has already been measured.
    @ObservationIgnored var onRecordsWillChange: (() -> Void)?
    private(set) var historyReady = false
    private(set) var openingPreview = false
    private(set) var permissionDenied = false
    private(set) var darknessClosed = false
    private(set) var storageError: String?
    private(set) var historyIssues: [String] = []
    private(set) var deletingHistory = false
    private(set) var deletionError: String?
    private(set) var deletionCleanupPending = false
    private var historyRevision = UUID()
    private(set) var status = ""
    private(set) var requestCount = 0
    private(set) var completionID: UUID?
    // UI reading intent is independent from capture and an in-flight response.
    private(set) var previewCollapsed = false
    private(set) var readingHistory = false
    struct PendingPresentation: Equatable {
        let recordID: UUID
        let attemptID: UUID
    }
    private(set) var pendingPresentation: PendingPresentation?
    private(set) var submittedPreview: RecognitionImageSnapshot?
    private(set) var selectedPhoto: RecognitionImageSnapshot?
    private(set) var photoSelectionActive = false
    private(set) var photoLoading = false
    private(set) var photoMessage: String?
    private(set) var focusMessage: String?
    private var photoSelectionID: UUID?
    private var photoMode = false
    private enum PhotoStage { case picking, loading, decoding, ready }
    private var photoStage: PhotoStage?
    private struct PhotoReturnState { let open: Bool; let photoMode: Bool }
    private var photoReturnState: PhotoReturnState?
    // Invalidated by background/settings even if foreground returns before preflight ends.
    private var photoIntentEpoch = UUID()
    private var focusCandidates = FocusCandidateSelector<CameraFrame>()
    private var acquisitionFeedback = CaptureAcquisitionFeedback()
    private var feedbackGeometry: UUID?
    private var candidateScope: FocusCandidateSelector<CameraFrame>.Scope?
    private(set) var previewGeneration = UUID()
    var showingSettings = false
    private let clock: () -> Double
    private let frameClock: () -> Double
    private let permission: () async -> Bool
    private let previewStart: ((UUID) -> Void)?
    private let previewStop: (() -> Void)?
    private let accessOverride: (() -> Bool)?
    private let wikipediaLookup: @Sendable (WikipediaSubject) async -> WikipediaReference?
    private let wikipediaReferencesLookup: @Sendable (RecognitionResult) async -> WikipediaEnrichment
    private let clearWikipediaCache: @Sendable (Set<String>?) async -> Void
    private var wikipediaTasks: [UUID: Task<Void, Never>] = [:]
    private var wikipediaEpoch = UUID()
    private(set) var wikipediaDiagnostics: [UUID: [WikipediaDiagnostic]] = [:]
    private let wikipediaNow: () -> Date
    private let scanBarcodes: @Sendable (Data) async -> SourceBarcodeScan
    private let provider: (@MainActor (Data, UUID, @escaping () throws -> Void, @escaping () throws -> Void) async throws -> RecognitionResult)?
    private let usesSemanticReview: Bool
    private let semanticSources: @Sendable (RecognitionResult) async throws -> [WikipediaReviewSource]
    private let semanticProvider: (@MainActor (RecognitionResult, String?, [WikipediaReviewSource], @escaping () throws -> Void) async throws -> String)?
    private struct SemanticJob { let attemptID: UUID; let runID: UUID; let task: Task<Void, Never> }
    private var semanticJobs: [UUID: SemanticJob] = [:]
    @ObservationIgnored private var semanticCardSnapshots: [UUID: ArchivedRecognition] = [:]
    private var semanticAccountIdentity = ""
    private(set) var semanticRequestCount = 0
    private var initialized = false
    private var appActive = true
    private var startAttempt: UUID?
    private var requiresExplicitReopen = false
    private var analysisBeganAt: Double = 0
    private var focusRevision: UInt64?
    private var watchdog: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private var activeAttemptID: UUID?
    private var requestDeadline: Task<Void, Never>?
    private let requestTimeout: Duration
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundAttempted = false
    private var backgroundEpoch = UUID()
    private let backgroundBegin: ((@escaping () -> Void) -> UIBackgroundTaskIdentifier)?
    private let backgroundEnd: ((UIBackgroundTaskIdentifier) -> Void)?
    private var pipelineOwners: [UUID: UUID] = [:]
    private struct FirstStageWork {
        let recordID: UUID
        let attemptID: UUID
        let accountIdentity: String
        var leftActive = false
        var submitted = false
    }
    private var firstStageWork: FirstStageWork?
    private var attemptStopReasons: [UUID: RecognitionStopReason] = [:]
    private var manualRefresh: PendingPresentation?
    private(set) var missingImageIDs: Set<UUID> = []
    private struct Unsaved {
        let id: UUID; let attemptID: UUID; let result: RecognitionResult?; let message: String?; let date: Date; let timedOut: Bool; let modelResponse: RecognitionModelResponse?; let stopReason: RecognitionStopReason?
    }
    private var unsaved: Unsaved?
    var canRecognize: Bool { consent.allowsTransfer && (accessOverride?() ?? account.planAccessReady) }
    // Image recognition presentation ends with stage one. A manual refresh
    // retains its operation lock while optional enrichment finishes.
    var isRecognizingImage: Bool { cycle.activeID != nil }
    var busy: Bool { isRecognizingImage || manualRefresh != nil }
    var isSynthetic: Bool { previewStart != nil }
    var canContinue: Bool { historyReady && storageError == nil && !deletingHistory && !busy && cycle.canContinue && canRecognize && !showingSettings && selectedPhoto == nil && !photoSelectionActive && !photoLoading }
    var canStartRecognition: Bool {
        historyReady && storageError == nil && !deletingHistory && !busy && !acquiring && !openingPreview &&
        canRecognize && !account.busy && appActive && !showingSettings &&
        selectedPhoto == nil && !photoSelectionActive && !photoLoading
    }
    var canChoosePhoto: Bool { canRecognize && historyReady && storageError == nil && !deletingHistory && !busy && !acquiring && appActive && !showingSettings && !photoSelectionActive && !photoLoading }
    var previewOpen: Bool { cycle.preview == .open }
    var acquiring: Bool { cycle.phase == .acquiring }
    var expired: Bool { cycle.preview == .expired || (requiresExplicitReopen && !darknessClosed) }

    init(consent: DataConsentController = .shared, account: SIWCController = SIWCController(), archive: RecognitionArchive = RecognitionArchive(root: RecognitionArchive.defaultRoot()),
         clock: @escaping () -> Double = CaptureContinuousTime.now,
         frameClock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         permission: @escaping () async -> Bool = SingleCaptureController.cameraPermission,
         previewStart: ((UUID) -> Void)? = nil, previewStop: (() -> Void)? = nil,
         access: (() -> Bool)? = nil,
         decodeBarcodes: (@Sendable (Data) async -> [String])? = nil,
         scanBarcodes: @escaping @Sendable (Data) async -> SourceBarcodeScan = { await SourceBarcodeDecoder.shared.scan($0) },
         wikipediaLookup: @escaping @Sendable (WikipediaSubject) async -> WikipediaReference? = { await WikipediaLookupService.shared.lookup($0) },
         wikipediaReferencesLookup: @escaping @Sendable (RecognitionResult) async -> WikipediaEnrichment = { await WikipediaLookupService.shared.lookupReferences(for: $0) },
         clearWikipediaCache: @escaping @Sendable (Set<String>?) async -> Void = { await WikipediaLookupService.shared.removeCachedValues(for: $0) },
         wikipediaNow: @escaping () -> Date = { Date() },
         provider: (@MainActor (Data, UUID, @escaping () throws -> Void, @escaping () throws -> Void) async throws -> RecognitionResult)? = nil,
         semanticReviewEnabled: Bool? = nil,
         semanticSources: @escaping @Sendable (RecognitionResult) async throws -> [WikipediaReviewSource] = { try await WikipediaReviewCollector().collect(for: $0) },
         semanticProvider: (@MainActor (RecognitionResult, String?, [WikipediaReviewSource], @escaping () throws -> Void) async throws -> String)? = nil,
         loadAccount: Bool = true, requestTimeout: Duration = .seconds(120),
         backgroundBegin: ((@escaping () -> Void) -> UIBackgroundTaskIdentifier)? = nil,
         backgroundEnd: ((UIBackgroundTaskIdentifier) -> Void)? = nil) {
        self.usesSemanticReview = semanticReviewEnabled ?? (previewStart == nil)
        self.semanticSources = semanticSources; self.semanticProvider = semanticProvider
        self.semanticAccountIdentity = account.recognitionAccountIdentity
        self.consent = consent; self.account = account; self.archive = archive; self.clock = clock; self.frameClock = frameClock
        self.permission = permission; self.previewStart = previewStart; self.previewStop = previewStop
        self.accessOverride = access; self.provider = provider; self.requestTimeout = requestTimeout
        self.backgroundBegin = backgroundBegin; self.backgroundEnd = backgroundEnd
        if let decodeBarcodes { self.scanBarcodes = { .init(values: await decodeBarcodes($0)) } }
        else { self.scanBarcodes = scanBarcodes }
        self.wikipediaReferencesLookup = wikipediaReferencesLookup
        self.wikipediaLookup = wikipediaLookup; self.wikipediaNow = wikipediaNow
        self.clearWikipediaCache = clearWikipediaCache
        capture.setFocusSelectionEnabled(true)
        if loadAccount { account.load() }
        capture.onFrame = { [weak self] frame, epoch, _ in
            Task { @MainActor in self?.receive(frame, generation: epoch) }
        }
        capture.onFocusChange = { [weak self] _, epoch in
            Task { @MainActor in self?.focusChanged(epoch) }
        }
        capture.onDarknessChange = { [weak self] decision, epoch in
            Task { @MainActor in self?.cameraDarknessChanged(decision, generation: epoch) }
        }
        capture.onFailure = { [weak self] _ in
            Task { @MainActor in
                self?.closePreview(); self?.status = "無法開啟相機，請稍後重試。"
            }
        }
    }
    private static func cameraPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }
    func bootstrap() async {
        guard !initialized else { return }; initialized = true
        await reloadHistory()
        consent.accountChanged(ready: canRecognize)
        showingOnboarding = !canRecognize
        if canRecognize { await openPreview() }
    }
    func acceptDataUse() {
        guard consent.accept(accountReady: accessOverride?() ?? account.planAccessReady) else { return }
        if canRecognize { showingOnboarding = false }
        else { account.beginNewAccount() }
    }
    func deferSetup() { account.cancel(); showingOnboarding = false; closePreview() }
    func resumeSetup() { showingOnboarding = true; closePreview() }
    func accountStateChanged() {
        if semanticAccountIdentity != account.recognitionAccountIdentity {
            if let attempt = activeAttemptID, let id = cycle.activeID {
                attemptStopReasons[attempt] = .accountChanged
                work?.cancel()
                if records.contains(where: { $0.id == id }) {
                    Task { await finishAttempt(id: id, attemptID: attempt, result: nil,
                        message: "帳戶已變更；這次辨識已停止，沒有自動重送。", timedOut: false) }
                }
            }
            cancelSemanticReviews(reason: .accountChanged); semanticAccountIdentity = account.recognitionAccountIdentity
        }
        consent.accountChanged(ready: accessOverride?() ?? account.planAccessReady)
        if canRecognize { showingOnboarding = false }
        else { closePreview(); invalidatePhotoSelection(); cancelWikipediaLookups() }
    }
    func withdrawDataUse() {
        consent.withdraw(); account.cancel()
        cancelWikipediaLookups(reason: .consentRevoked)
        closePreview(); invalidatePhotoSelection()
        if let attempt = activeAttemptID { attemptStopReasons[attempt] = .consentRevoked }
        work?.cancel(); requestDeadline?.cancel(); cancelWikipediaLookups(reason: .consentRevoked)
        if let id = cycle.activeID, let attemptID = activeAttemptID {
            Task { await finishAttempt(id: id, attemptID: attemptID, result: nil,
                message: "已撤回同意；這次辨識已停止，原圖保留，沒有自動重送。", timedOut: false) }
        }
        status = "已撤回資料傳送同意；可繼續瀏覽與刪除本機紀錄。"
    }
    func reloadHistory() async {
        guard !busy, !deletingHistory else { return }
        let revision = historyRevision
        do {
            let liveAttempts = Set([firstStageWork?.attemptID, unsaved?.attemptID].compactMap { $0 })
            let loaded = try await archive.load(liveAttemptIDs: liveAttempts, liveSemanticRunIDs: Set(semanticJobs.values.map(\.runID)))
            guard historyRevision == revision, !deletingHistory else { return }
            onRecordsWillChange?()
            records = loaded.records; historyIssues = loaded.issues; historyReady = true
            missingImageIDs = loaded.missingImageIDs
            deletionError = loaded.deletionIssues.isEmpty ? nil : loaded.deletionIssues.joined(separator: "\n")
            deletionCleanupPending = !loaded.deletionIssues.isEmpty
            if unsaved == nil { storageError = nil }
        } catch {
            guard historyRevision == revision, !deletingHistory else { return }
            historyReady = false
            storageError = "無法讀取本機紀錄，原資料保留；請確認儲存空間並重試。"
        }
    }
    func canDeleteRecord(_ id: UUID) -> Bool {
        historyReady && !deletingHistory && !acquiring && !photoSelectionActive && !photoLoading && selectedPhoto == nil &&
            cycle.activeID != id && unsaved?.id != id &&
            records.contains { $0.id == id && $0.status != .pending }
    }
    var clearHistoryBlockedReason: String? {
        if !historyReady { return "紀錄尚未讀取完成。" }
        if deletingHistory { return "正在刪除紀錄。" }
        if busy || acquiring || records.contains(where: { $0.status == .pending }) {
            return "辨識進行中，完成後才能清除全部。"
        }
        if photoSelectionActive || photoLoading || selectedPhoto != nil { return "圖片處理中，完成後才能清除全部。" }
        if unsaved != nil { return "請先完成紀錄保存。" }
        return nil
    }
    var canClearHistory: Bool { !records.isEmpty && clearHistoryBlockedReason == nil }
    @discardableResult func deleteRecord(id: UUID) async -> Bool {
        guard canDeleteRecord(id) else { return false }
        return await deleteRecords(ids: [id], clearingAll: false)
    }
    @discardableResult func clearHistory(confirmedIDs: Set<UUID>) async -> Bool {
        guard canClearHistory else { return false }
        guard confirmedIDs == Set(records.map(\.id)) else {
            deletionError = "紀錄已變更，請重新確認清除範圍。"; return false
        }
        return await deleteRecords(ids: confirmedIDs, clearingAll: true)
    }
    private func deleteRecords(ids: Set<UUID>, clearingAll: Bool) async -> Bool {
        deletingHistory = true; historyRevision = UUID(); deletionError = nil
        defer { deletingHistory = false }
        let targets = records.filter { ids.contains($0.id) }
        for id in ids {
            cancelSemanticReview(id: id, reason: .deleted)
            if wikipediaTasks[id] != nil { rememberWikipedia(id, [.init(.persistence, .deleted)]) }
            wikipediaTasks.removeValue(forKey: id)?.cancel()
        }
        do {
            let deletion = try await archive.delete(ids: ids)
            onRecordsWillChange?()
            records.removeAll { deletion.deletedIDs.contains($0.id) }
            for id in deletion.deletedIDs { semanticCardSnapshots[id] = nil }
            if let id = submittedPreview?.id, deletion.deletedIDs.contains(id) { submittedPreview = nil }
            if let id = completionID, deletion.deletedIDs.contains(id) { completionID = nil }
            if let id = pendingPresentation?.recordID, deletion.deletedIDs.contains(id) { pendingPresentation = nil }
            var keys = Set<String>()
            for record in targets where deletion.deletedIDs.contains(record.id) {
                if let result = record.result {
                    if result.usesEntitySearch { keys.insert(SearchEntity.cacheKey(for: result)) }
                    if let subject = WikipediaSubject.matching(result) { keys.insert(subject.key) }
                    keys.formUnion(TextWikipediaCandidate.matching(result).map(\.key))
                }
                if let reference = record.wikipedia { keys.insert(reference.subjectKey) }
                keys.formUnion((record.textWikipedia ?? []).map(\.candidateKey))
            }
            await clearWikipediaCache(clearingAll ? nil : keys)
            deletionError = deletion.issues.isEmpty ? nil : deletion.issues.joined(separator: "\n")
            deletionCleanupPending = deletion.cleanupPending
            return deletion.deletedIDs == ids && deletion.issues.isEmpty
        } catch {
            deletionError = "無法刪除紀錄，原資料保留；請稍後重試。"
            return false
        }
    }
    func retryDeletedFileCleanup() async {
        guard !deletingHistory else { return }
        deletingHistory = true
        defer { deletingHistory = false }
        do {
            let result = try await archive.delete(ids: [])
            deletionError = result.issues.isEmpty ? nil : result.issues.joined(separator: "\n")
            deletionCleanupPending = result.cleanupPending
        } catch { deletionError = "無法清理已刪紀錄的檔案，請稍後重試。" }
    }
    func openPreview(explicit: Bool = false) async {
        guard canRecognize, !showingOnboarding else { return }
        guard appActive, !showingSettings, !previewOpen, !openingPreview,
              selectedPhoto == nil, !photoMode, !photoSelectionActive, !photoLoading,
              explicit || !previewCollapsed,
              explicit || !requiresExplicitReopen else { return }
        let attempt = UUID(); startAttempt = attempt; openingPreview = true
        let allowed = await permission()
        guard startAttempt == attempt else { return }
        openingPreview = false; startAttempt = nil
        guard appActive, !showingSettings else { return }
        guard allowed else { permissionDenied = true; status = "請在系統設定允許 Glance 使用相機。"; return }
        permissionDenied = false; darknessClosed = false; requiresExplicitReopen = false; previewCollapsed = false
        previewGeneration = UUID(); focusRevision = nil
        cycle.openPreview(at: clock())
        capture.darknessGate.begin(session: previewGeneration)
        capture.setAnalysisEnabled(false)
        if let previewStart { previewStart(previewGeneration) }
        else { capture.start(generation: previewGeneration, firstCaptureOnly: true, liveCurrent: true, analyzing: false) }
        status = "按開始辨識，停穩 1 秒後辨識一張。"
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self else { return }
                self.checkPreviewDeadline()
                self.updateAcquisitionWaitingHint()
            }
        }
    }
    @discardableResult func beginAcquisition() -> Bool {
        checkPreviewDeadline()
        guard canContinue, cycle.arm() else { return false }
        readingHistory = false
        analysisBeganAt = frameClock(); focusRevision = nil
        focusCandidates.begin(at: analysisBeganAt); candidateScope = nil; focusMessage = nil
        acquisitionFeedback.reset(); feedbackGeometry = nil
        capture.setAnalysisEnabled(true)
        status = "停穩 1 秒後辨識一張。"; return true
    }
    /// One explicit press reopens (if necessary) and arms a fresh capture.
    @discardableResult func startRecognition() async -> Bool {
        guard canStartRecognition else { return false }
        photoMode = false; photoMessage = nil
        if !previewOpen { await openPreview(explicit: true) }
        guard !previewCollapsed else { return false }
        return beginAcquisition()
    }
    var canReopenHistoryPreview: Bool {
        previewCollapsed && historyReady && storageError == nil && unsaved == nil && !deletingHistory &&
        !busy && !acquiring && !openingPreview && !account.busy && appActive && !showingSettings &&
        selectedPhoto == nil && !photoSelectionActive && !photoLoading
    }
    /// Explicit overscroll opens only live preview. It never grants a capture slot.
    @discardableResult func reopenPreviewFromHistoryPull() async -> Bool {
        guard canReopenHistoryPreview else { return false }
        photoMode = false; photoMessage = nil; submittedPreview = nil; focusMessage = nil
        await openPreview(explicit: true)
        return previewOpen && !previewCollapsed
    }
    /// Called only by an actual drag in the history list, never by scrollTo.
    func historyDragBegan() {
        readingHistory = true
        guard !previewCollapsed else { return }
        previewCollapsed = true; focusMessage = nil
        cycle.closePreview()
        stopCamera(cancelEnrichment: false)
        // Work already handed to the transport keeps its completion/persistence.
        // A captured image still in preflight fails its existing preview/focus gate.
    }
    func cancelAcquisition() {
        guard acquiring else { return }
        // Close only the intent; reopening the logical preview does not reset its deadline.
        cycle.cancelAcquisition(); capture.setAnalysisEnabled(false)
        focusCandidates.resetCandidates(); candidateScope = nil; focusMessage = nil
        status = "取景已取消，鏡頭仍開啟。"
    }
    func checkPreviewDeadline() {
        guard cycle.expire(at: clock()) else { return }
        requiresExplicitReopen = true
        stopCamera()
        status = "鏡頭已連續開啟 5 分鐘並關閉；紀錄保留。"
    }
    func updateAcquisitionWaitingHint() {
        guard acquiring, focusCandidates.needsWaitingHint(at: frameClock()) else { return }
        // Guidance does not consume the user's one-shot intent or extend the
        // preview deadline. Existing frame/focus/stability gates still decide.
        let message = acquisitionFeedback.waitingMessage
        if focusMessage != message { focusMessage = message; status = message }
    }
    private func stopCamera(cancelEnrichment: Bool = true) {
        if cancelEnrichment { cancelWikipediaLookups() }
        startAttempt = nil; openingPreview = false
        capture.setAnalysisEnabled(false); capture.focusGate.stop(); capture.darknessGate.stop()
        focusCandidates.resetCandidates(); candidateScope = nil; focusMessage = nil
        if let previewStop { previewStop() } else { capture.stop() }
        watchdog?.cancel(); watchdog = nil
    }
    func closePreview() { cycle.closePreview(); stopCamera() }
    func foreground(_ phase: ScenePhase) {
        let wasActive = appActive
        appActive = phase == .active
        if appActive {
            if !wasActive { backgroundAttempted = false; endBackgroundAllowance() }
            account.foreground()
            if unsaved != nil { Task { await retrySaving() } }
            // Reconcile orphaned disk markers, preserving actual live attempt/run IDs.
            if initialized { Task { await reloadHistory() } }
        } else {
            firstStageWork?.leftActive = true
            invalidatePhotoSelection()
            requiresExplicitReopen = true
            cycle.closePreview(); stopCamera(cancelEnrichment: false)
            ensureBackgroundAllowance()
        }
    }
    func settingsChanged(_ shown: Bool) {
        showingSettings = shown
        if shown { invalidatePhotoSelection(); closePreview() }
        else {
            if accessOverride == nil { account.load() }
            Task { await openPreview() }
        }
    }
    /// Each picker session authorizes only its explicitly selected image.
    func beginPhotoSelection() -> UUID? {
        guard canChoosePhoto else { return nil }
        photoReturnState = .init(open: previewOpen || openingPreview, photoMode: photoMode)
        closePreview(); photoMode = true; photoMessage = nil; focusMessage = nil
        selectedPhoto = nil; photoSelectionActive = true; photoStage = .picking
        let id = UUID(); photoSelectionID = id; return id
    }
    /// Called after dismissal, not at didFinishPicking: no send behind the picker.
    func photoPickerDismissed(id: UUID) {
        guard photoSelectionID == id else { return }
        photoSelectionActive = false
        if photoStage == .picking {
            let previous = photoReturnState
            clearPhotoSelection()
            photoMode = previous?.photoMode ?? false
            if previous?.open == true {
                Task { [weak self] in await self?.openPreview() }
            }
        } else { submitPreparedPhotoIfReady() }
    }
    @discardableResult func photoTransferStarted(id: UUID) -> Bool {
        guard photoSelectionID == id, photoStage == .picking, appActive, !showingSettings, !busy else { return false }
        photoStage = .loading; photoLoading = true
        photoMessage = "正在載入所選相片，尚未送出。"; return true
    }
    func photoSelectionFailed(id: UUID) {
        guard photoSelectionID == id, photoStage == .loading else { return }
        clearPhotoSelection()
        photoMessage = "無法讀取這張相片，請重新選擇。"
    }
    @discardableResult func prepareSelectedPhoto(_ data: Data, selectionID: UUID) async -> Bool {
        guard photoSelectionID == selectionID, photoStage == .loading, appActive, !showingSettings, !busy else { return false }
        // Claim the callback before suspending; a second callback cannot decode/reserve again.
        photoStage = .decoding
        let result = await Task.detached(priority: .userInitiated) { Result { try SelectedPhoto.jpeg(from: data) } }.value
        guard photoSelectionID == selectionID, photoStage == .decoding, appActive, !showingSettings, !busy else { return false }
        switch result {
        case .success(let jpeg):
            selectedPhoto = .init(id: UUID(), jpeg: jpeg); photoStage = .ready
            submitPreparedPhotoIfReady(); return true
        case .failure:
            clearPhotoSelection()
            photoMessage = "無法載入此圖片，請選擇其他相片（上限 40 MB）。"; return false
        }
    }
    private func clearPhotoSelection() {
        photoSelectionID = nil; photoStage = nil; photoReturnState = nil
        photoSelectionActive = false; photoLoading = false; selectedPhoto = nil
    }
    private func invalidatePhotoSelection() {
        photoIntentEpoch = UUID()
        if photoSelectionID != nil { photoMessage = "相片載入已中止，請重新選擇。" }
        clearPhotoSelection()
    }
    private func submitPreparedPhotoIfReady() {
        guard photoStage == .ready, !photoSelectionActive, let photo = selectedPhoto else { return }
        guard appActive, !showingSettings, historyReady, storageError == nil, !busy,
              canRecognize, !account.busy else {
            clearPhotoSelection()
            photoMessage = "尚未具備辨識資格，沒有送出；請完成登入與方案確認後重新選擇相片。"
            return
        }
        guard cycle.reserveArchived(id: photo.id) else { return }
        let id = photo.id, epoch = photoIntentEpoch
        beginFirstStage(id: id, attemptID: id); completionID = nil; readingHistory = false
        clearPhotoSelection(); photoMessage = nil
        // Show the exact prepared JPEG immediately; the durable thumbnail follows save.
        darknessClosed = false
        submittedPreview = photo
        work = Task { [weak self] in
            guard let self else { return }
            let scan = await scanBarcodes(photo.jpeg)
            do {
                let record = try await archive.create(id: id, jpeg: photo.jpeg, capturedAt: Date(),
                    decodedBarcodes: scan.values, productBarcodes: scan.products, barcodeDiagnostics: scan.diagnostics, imageSource: .photoLibrary)
                onRecordsWillChange?(); records.insert(record, at: 0)
                pendingPresentation = .init(recordID: id, attemptID: id)
            } catch {
                storageError = "圖片尚未保存，沒有送出辨識。請確認儲存空間後重試。"
                photoMessage = "相片尚未保存；恢復儲存空間後請重新選擇。"
                activeAttemptID = nil; firstStageWork = nil; finishPipeline(id: id, attemptID: id); cycle.finish(id: id); submittedPreview = nil
                work = nil; endBackgroundAllowance(); return
            }
            cycle.waiting(id: id)
            let validate = { [self] in
                try Task.checkCancellation()
                guard appActive, !showingSettings, photoIntentEpoch == epoch, canRecognize,
                      cycle.activeID == id, activeAttemptID == id else { throw CancellationError() }
            }
            await performRequest(id: id, attemptID: id, jpeg: photo.jpeg, decoded: scan.values, searchEvidence: .init(decodedValues: scan.values, candidateScoped: true), validate: validate)
        }
    }
    private func beginFirstStage(id: UUID, attemptID: UUID) {
        // A foreground reload started before this reservation must not replace
        // its new row with an older disk snapshot when the read resumes.
        historyRevision = UUID()
        activeAttemptID = attemptID
        firstStageWork = .init(recordID: id, attemptID: attemptID, accountIdentity: account.recognitionAccountIdentity)
        pipelineOwners[id] = attemptID
    }
    private func pipelineMayRun(id: UUID, attemptID: UUID) -> Bool {
        pipelineOwners[id] == attemptID && (appActive || backgroundTask != .invalid)
    }
    private func finishPipeline(id: UUID, attemptID: UUID) {
        if manualRefresh == .init(recordID: id, attemptID: attemptID) { manualRefresh = nil }
        if pipelineOwners[id] == attemptID { pipelineOwners[id] = nil }
        if pipelineOwners.isEmpty { endBackgroundAllowance() }
    }
    private func ensureBackgroundAllowance() {
        guard !appActive, !pipelineOwners.isEmpty, backgroundTask == .invalid, !backgroundAttempted else { return }
        backgroundAttempted = true
        let epoch = UUID(); backgroundEpoch = epoch
        let expire = { [weak self] in
            Task { @MainActor in
                guard self?.backgroundEpoch == epoch else { return }
                self?.backgroundAllowanceExpired(reason: .backgroundTimeExpired)
            }
            return
        }
        backgroundTask = backgroundBegin?(expire) ?? UIApplication.shared.beginBackgroundTask(withName: "CompleteRecognitionPipeline", expirationHandler: expire)
        if backgroundTask == .invalid { backgroundAllowanceExpired(reason: .backgroundTimeUnavailable) }
    }
    private func backgroundAllowanceExpired(reason: RecognitionStopReason) {
        guard !appActive else { endBackgroundAllowance(); return }
        // Revoke admission before cancellation/persistence can suspend.
        pipelineOwners.removeAll()
        if let first = firstStageWork, activeAttemptID == first.attemptID {
            attemptStopReasons[first.attemptID] = reason
            work?.cancel(); requestDeadline?.cancel()
            if records.contains(where: { $0.id == first.recordID }) {
                Task { await finishAttempt(id: first.recordID, attemptID: first.attemptID, result: nil,
                    message: "辨識中斷，尚未完成；背景執行時間已結束，原圖保留，沒有自動重送。", timedOut: false) }
            }
        }
        cancelWikipediaLookups(reason: reason)
        endBackgroundAllowance()
    }
    private func endBackgroundAllowance() {
        guard backgroundTask != .invalid else { return }
        let task = backgroundTask; backgroundTask = .invalid
        backgroundEpoch = UUID()
        if let backgroundEnd { backgroundEnd(task) } else { UIApplication.shared.endBackgroundTask(task) }
    }
    func cameraDarknessChanged(_ decision: CameraDarknessGate.Decision, generation: UUID) {
        guard appActive, previewOpen, generation == previewGeneration else { return }
        guard decision == .temporaryDark || decision == .closeCamera else { return }
        cycle.interruptStability(); focusCandidates.resetCandidates(); candidateScope = nil
        if decision == .closeCamera {
            darknessClosed = true; requiresExplicitReopen = true; focusMessage = nil
            cycle.closePreview(); stopCamera(cancelEnrichment: false)
            status = "畫面持續全黑，相機已關閉"
        }
    }
    private func focusChanged(_ epoch: UUID) {
        guard previewGeneration == epoch, acquiring else { return }
        let focus = capture.focusGate.snapshot
        guard focus.active, focus.session == epoch, focusRevision != focus.revision else { return }
        if focusRevision != nil || focus.adjusting { acquisitionFeedback.autofocusChanged() }
        focusRevision = focus.revision; cycle.interruptStability()
        focusCandidates.resetCandidates(); candidateScope = nil
        capture.resetLiveRegistration()
    }
    func receive(_ frame: CameraFrame?, generation: UUID) {
        checkPreviewDeadline()
        updateAcquisitionWaitingHint()
        guard acquiring, appActive, generation == previewGeneration else { return }
        guard !capture.darknessGate.isBlocked else {
            cycle.interruptStability(); focusCandidates.resetCandidates(); candidateScope = nil; return
        }
        if let stamp = frame?.darknessStamp {
            do { try capture.darknessGate.requireCurrent(stamp) }
            catch { cycle.interruptStability(); focusCandidates.resetCandidates(); candidateScope = nil; return }
        }
        focusChanged(generation)
        let focus = capture.focusGate.snapshot
        if focus.active && focus.adjusting {
            acquisitionFeedback.autofocusChanged(); cycle.interruptStability(); return
        }
        if let frame {
            guard frame.time > analysisBeganAt else { return }
            if let stamp = frame.focusStamp, !capture.focusGate.allows(stamp) {
                acquisitionFeedback.autofocusChanged(); cycle.interruptStability(); return
            }
            if frame.focusStamp == nil && !isSynthetic { cycle.interruptStability(); return }
        }
        let now = frameClock()
        var chosen = frame
        if let frame, !isSynthetic || frame.focusQuality != nil {
            let scope = FocusCandidateSelector<CameraFrame>.Scope(session: generation,
                focusRevision: frame.focusStamp?.revision ?? focus.revision,
                geometryRevision: frame.visibleStamp?.revision ?? generation)
            if let geometry = feedbackGeometry, geometry != scope.geometryRevision { acquisitionFeedback.reset() }
            feedbackGeometry = scope.geometryRevision
            if frame.registration?.sceneChanged == true { acquisitionFeedback.reset(); acquisitionFeedback.sceneMoved() }
            if candidateScope != scope || frame.registration?.sceneChanged == true { cycle.interruptStability() }
            candidateScope = scope
            focusCandidates.observe(payload: frame, capturedAt: frame.time, scope: scope,
                quality: frame.focusQuality ?? .unavailable, sceneChanged: frame.registration?.sceneChanged == true, now: now)
            acquisitionFeedback.observe(frame.focusQuality ?? .unavailable,
                repeatedBlurredFrames: focusCandidates.observedBlurredFrames)
            chosen = focusCandidates.selected(at: now, scope: scope)
        } else if frame == nil { focusCandidates.resetCandidates(); candidateScope = nil }
        // Keep waiting with bounded recent samples; never send a known soft sample.
        guard let chosen else { cycle.interruptStability(); return }
        let acceptedImage: VisibleCaptureGate.AcceptedImage?
        if let visible = chosen.visibleStamp {
            do { acceptedImage = try capture.visibleGate.acceptImage(visible, now: CameraCapture.hostTime()) }
            catch { cycle.interruptStability(); return }
        } else if isSynthetic { acceptedImage = nil }
        else { cycle.interruptStability(); return }
        let invalidations = cycle.stabilityInvalidationCount
        let reserved = cycle.reserve(frame?.fingerprint, capturedAt: frame?.time ?? now, now: now,
                                     sceneChanged: frame?.registration?.sceneChanged == true)
        if cycle.stabilityInvalidationCount != invalidations, cycle.lastStabilityInvalidationReason == "scene-changed" {
            acquisitionFeedback.reset(); acquisitionFeedback.sceneMoved()
        }
        guard let id = reserved else { return }
        let frame = chosen
        focusMessage = nil
        capture.setAnalysisEnabled(false)
        focusCandidates.resetCandidates(); candidateScope = nil
        guard let jpeg = UIImage(cgImage: frame.image).jpegData(compressionQuality: 0.82), !jpeg.isEmpty else {
            cycle.finish(id: id); status = "圖片準備失敗，請重新取景。"; return
        }
        let capturedAt = Date()
        beginFirstStage(id: id, attemptID: id); completionID = nil
        work = Task { [weak self] in
            guard let self else { return }
            let scan = await scanBarcodes(jpeg)
            let decoded = scan.values
            do {
                let record = try await archive.create(id: id, jpeg: jpeg, capturedAt: capturedAt, decodedBarcodes: decoded, productBarcodes: scan.products, barcodeDiagnostics: scan.diagnostics)
                onRecordsWillChange?(); records.insert(record, at: 0)
                pendingPresentation = .init(recordID: id, attemptID: id)
            } catch {
                storageError = "圖片尚未保存，沒有送出辨識。請確認儲存空間後重試。"
                activeAttemptID = nil; firstStageWork = nil; finishPipeline(id: id, attemptID: id); cycle.finish(id: id); work = nil; return
            }
            cycle.waiting(id: id)
            let validate = { [self] in
                try Task.checkCancellation()
                checkPreviewDeadline()
                guard appActive, previewOpen, cycle.activeID == id, activeAttemptID == id, !showingSettings else { throw CancellationError() }
                // Local barcode work, durable storage and model preflight cannot
                // age out an image already checked at capture. Geometry still must match.
                if let acceptedImage { try capture.visibleGate.requireUnchanged(acceptedImage) }
                else if !isSynthetic { throw VisibleCaptureGate.Rejection.geometryChanged }
                if let stamp = frame.darknessStamp { try capture.darknessGate.requireCurrent(stamp) }
                if capture.darknessGate.isBlocked { throw CameraDarknessGate.Rejection.changedBeforeSend }
                if let stamp = frame.focusStamp { try capture.focusGate.requireCurrent(stamp) }
                else if !isSynthetic { throw CameraFocusGate.Rejection.changedBeforeSend }
                // This closure runs on the same bytes and id used by the transport.
                // Revalidation cannot borrow a subsequent live frame or another card.
                submittedPreview = RecognitionImageSnapshot(id: id, jpeg: jpeg)
            }
            await performRequest(id: id, attemptID: id, jpeg: jpeg, decoded: decoded, searchEvidence: .init(decodedValues: decoded, candidateScoped: true), validate: validate)
        }
    }
    func canRetryImage(_ record: ArchivedRecognition) -> Bool {
        historyReady && storageError == nil && unsaved == nil && !deletingHistory && !busy && !acquiring && appActive &&
            !showingSettings && selectedPhoto == nil && !photoSelectionActive && !photoLoading &&
            canRecognize && !account.busy && record.canRetryImage && !missingImageIDs.contains(record.id)
    }
    func missingImageReason(_ record: ArchivedRecognition) -> String? {
        missingImageIDs.contains(record.id) ? "這筆紀錄的原圖無法讀取，不能重新辨識；既有文字仍保留。" : nil
    }
    /// Internal permit-gated replay. Copies exact saved bytes into an isolated archive;
    /// then uses the same barcode, SIWC, parser, completion and Wikipedia paths.
    func beginSavedReplay(_ sample: BoundedReplayStore.Prepared, validatePermit: @escaping () throws -> Void) -> UUID? {
        guard canStartRecognition else { return nil }
        let id = UUID()
        guard cycle.reserveArchived(id: id) else { return nil }
        // A replay is a foreground history-reading session with no live preview.
        // This preserves the ordinary enrichment admission rules for saved camera images.
        previewCollapsed = true; readingHistory = true
        beginFirstStage(id: id, attemptID: id); completionID = nil
        work = Task { [weak self] in
            guard let self else { return }
            let scan = await scanBarcodes(sample.jpeg)
            do {
                try validatePermit(); try Task.checkCancellation()
                let record = try await archive.create(id: id, jpeg: sample.jpeg, capturedAt: Date(),
                    decodedBarcodes: scan.values, productBarcodes: scan.products, barcodeDiagnostics: scan.diagnostics,
                    imageSource: sample.source.source)
                onRecordsWillChange?(); records.insert(record, at: 0)
                pendingPresentation = .init(recordID: id, attemptID: id)
            } catch {
                storageError = "回放來源或保存驗證未通過，沒有送出。"
                activeAttemptID = nil; firstStageWork = nil; finishPipeline(id: id, attemptID: pipelineOwners[id] ?? id); cycle.finish(id: id); work = nil; return
            }
            cycle.waiting(id: id)
            let validate = { [self] in
                try validatePermit(); try Task.checkCancellation()
                guard appActive, !showingSettings, cycle.activeID == id, activeAttemptID == id else { throw CancellationError() }
            }
            await performRequest(id: id, attemptID: id, jpeg: sample.jpeg, decoded: scan.values,
                searchEvidence: .init(decodedValues: scan.values, candidateScoped: true), validate: validate)
        }
        return id
    }
    @discardableResult func retryImage(id: UUID) -> Bool {
        guard let original = records.first(where: { $0.id == id }), canRetryImage(original),
              cycle.reserveArchived(id: id) else { return false }
        let attemptID = UUID()
        cancelSemanticReview(id: id, reason: .replaced)
        beginFirstStage(id: id, attemptID: attemptID); completionID = nil
        manualRefresh = .init(recordID: id, attemptID: attemptID)
        readingHistory = false
        capture.setAnalysisEnabled(false)
        work = Task { [weak self] in
            guard let self else { return }
            let jpeg: Data
            do {
                jpeg = try await archive.image(for: original)
                let pending = try await archive.beginRetry(id: id, attemptID: attemptID)
                replace(pending)
                pendingPresentation = .init(recordID: id, attemptID: attemptID)
            } catch {
                if (try? await archive.image(for: original)) == nil { missingImageIDs.insert(id) }
                status = "原圖或重試紀錄無法讀取／保存，沒有送出；原始資料保留。"
                activeAttemptID = nil; firstStageWork = nil; finishPipeline(id: id, attemptID: pipelineOwners[id] ?? id); cycle.finish(id: id); work = nil; return
            }
            cycle.waiting(id: id)
            let validate = { [self] in
                try Task.checkCancellation()
                guard appActive, !showingSettings, cycle.activeID == id, activeAttemptID == attemptID,
                      records.first(where: { $0.id == id })?.currentAttemptID == attemptID else { throw CancellationError() }
                // Historical bytes are intentionally exempt from live focus/age gates.
                // Only this explicit user gesture can resend them; no camera is opened.
                submittedPreview = RecognitionImageSnapshot(id: id, jpeg: jpeg)
            }
            await performRequest(id: id, attemptID: attemptID, jpeg: jpeg, decoded: original.barcodes, searchEvidence: .init(decodedValues: original.decodedBarcodes ?? [], candidateScoped: true), validate: validate)
        }
        return true
    }
    private func performRequest(id: UUID, attemptID: UUID, jpeg: Data, decoded: [String], searchEvidence: BarcodeSearchEvidence?, validate: @escaping () throws -> Void) async {
        guard activeAttemptID == attemptID else { return }
        let consentEpoch = consent.epoch
        let originalValidate = validate
        let validate = { [self] in
            try Task.checkCancellation()
            guard consent.allowsTransfer, consent.epoch == consentEpoch, !showingSettings,
                  pipelineMayRun(id: id, attemptID: attemptID),
                  activeAttemptID == attemptID, cycle.activeID == id,
                  firstStageWork?.accountIdentity == account.recognitionAccountIdentity else { throw CancellationError() }
            // The foreground gesture already reserved this stable saved image.
            // After leaving active, stopping the camera must not invalidate it.
            if firstStageWork?.leftActive != true { try originalValidate() }
        }
        let submitted = { [self] in
            try validate()
            firstStageWork?.submitted = true
        }
        requestDeadline?.cancel()
        requestDeadline = Task { [weak self, requestTimeout] in
            do { try await Task.sleep(for: requestTimeout) } catch { return }
            guard let self, self.activeAttemptID == attemptID else { return }
            self.attemptStopReasons[attemptID] = .deadline
            self.work?.cancel()
            await self.finishAttempt(id: id, attemptID: attemptID, result: nil,
                message: "這次辨識已逾時；原圖已保留，可重試這張圖片，或按開始辨識拍攝新目標。", timedOut: true)
        }
        let result: RecognitionResult?
        let message: String?
        var timedOut = false
        var modelResponse: RecognitionModelResponse?
        do {
            try validate(); requestCount += 1
            let received: RecognitionResult
            if let provider { received = try await provider(jpeg, attemptID, validate, submitted).withBarcodes(decoded).withSourceImage(id) }
            else {
                received = try await account.recognize(jpeg: jpeg, requestID: attemptID.uuidString,
                    searchEvidence: searchEvidence, validateBeforeImageSend: validate, transportStarted: submitted, capturePreparseResponse: { answer in
                        modelResponse = .capture(answer, sourceImageID: id, attemptID: attemptID,
                            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
                    }).withBarcodes(decoded).withSourceImage(id)
            }
            guard consent.allowsTransfer, consent.epoch == consentEpoch,
                  firstStageWork?.accountIdentity == account.recognitionAccountIdentity else { throw CancellationError() }
            try Task.checkCancellation()
            result = received; message = nil
        } catch is VisibleCaptureGate.Rejection {
            result = nil; message = "取景範圍已改變或圖片已過期，沒有送出；可重試保存的圖片，或開始辨識新目標。"
        } catch is CameraFocusGate.Rejection {
            result = nil; message = "送出前對焦已改變，沒有送出；可重試保存的圖片，或開始辨識新目標。"
        } catch is CancellationError {
            result = nil
            message = attemptStopReasons[attemptID]?.isBackgroundInterruption == true
                ? "辨識中斷，尚未完成；背景執行時間已結束，原圖保留，沒有自動重送。"
                : "這次辨識已中止；原圖已保留，沒有自動重送。"
        } catch {
            result = nil
            timedOut = (error as? URLError)?.code == .timedOut
            message = (timedOut ? "這次辨識已逾時" : "這次辨識未完成") + "；原圖已保留，可重試這張圖片，或按開始辨識拍攝新目標。"
        }
        await finishAttempt(id: id, attemptID: attemptID, result: result, message: message, timedOut: timedOut, modelResponse: modelResponse)
    }
    private func finishAttempt(id: UUID, attemptID: UUID, result: RecognitionResult?, message: String?, timedOut: Bool, modelResponse: RecognitionModelResponse? = nil) async {
        guard activeAttemptID == attemptID, cycle.activeID == id else { return }
        // Claim completion before suspension. Exactly one timer/response may own it.
        activeAttemptID = nil; requestDeadline?.cancel(); requestDeadline = nil
        let stopReason = attemptStopReasons.removeValue(forKey: attemptID)
        await persistCompletion(id: id, attemptID: attemptID, result: result, message: message, date: Date(), timedOut: timedOut, modelResponse: modelResponse, stopReason: stopReason)
        if cycle.finish(id: id) { completionID = id }
        clearSubmittedPreviewIfFinished(id: id); scheduleWikipedia(for: id)
        if firstStageWork?.attemptID == attemptID { firstStageWork = nil }
        work = nil
        if semanticJobs[id] == nil && wikipediaTasks[id] == nil { finishPipeline(id: id, attemptID: attemptID) }
    }
    func stopSemanticReview(id: UUID) { cancelSemanticReview(id: id, reason: .manual) }
    /// The first-stage card stays unchanged while optional work saves its evidence.
    /// JSON inspection still reads the live record, not this display snapshot.
    func cardRecord(for record: ArchivedRecognition) -> ArchivedRecognition {
        (semanticCardSnapshots[record.id] ?? record).displayRecord
    }
    func isSupplementPending(for record: ArchivedRecognition) -> Bool {
        record.currentSemanticReview?.isPending == true || semanticCardSnapshots[record.id] != nil
    }
    private func cancelSemanticReviews(reason: RecognitionStopReason = .previewClosed) {
        for id in Array(semanticJobs.keys) { cancelSemanticReview(id: id, reason: reason) }
    }
    private func cancelSemanticReview(id: UUID, reason: RecognitionStopReason = .previewClosed) {
        guard let job = semanticJobs.removeValue(forKey: id) else { return }
        job.task.cancel()
        if var current = records.first(where: { $0.id == id }), current.semanticReview == nil || (current.semanticReview?.runID == job.runID && current.semanticReview?.isPending == true) {
            if current.semanticReview == nil { current.semanticReview = .init(recordID: id, attemptID: job.attemptID, runID: job.runID) }
            current.semanticReview?.state = .cancelled; current.semanticReview?.finishedAt = Date()
            current.semanticReview?.stopReason = reason; replace(current)
        }
        // Separate task records cancellation even though the worker is cancelled.
        Task { [weak self, archive] in
            defer { self?.finishPipeline(id: id, attemptID: job.attemptID) }
            guard let saved = try? await archive.updateSemanticReview(id: id, attemptID: job.attemptID, runID: job.runID, state: .cancelled, stopReason: reason) else { return }
            self?.replace(saved)
        }
    }
    private func scheduleSemanticReview(for id: UUID) {
        guard consent.allowsTransfer, !showingSettings, unsaved == nil,
              semanticJobs[id] == nil, let record = records.first(where: { $0.id == id }),
              record.status == .succeeded, record.semanticReview == nil, let result = record.result,
              pipelineMayRun(id: id, attemptID: record.currentAttemptID),
              !WikipediaReviewCollector.queries(for: result).isEmpty else { return }
        let attempt = record.currentAttemptID, runID = UUID(), consentEpoch = consent.epoch
        let accountIdentity = account.recognitionAccountIdentity
        // At most two optional jobs; no queue, retry, old-history replay or implicit resubmit.
        let capacityAvailable = semanticJobs.count < 2
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if semanticJobs[id]?.runID == runID {
                    semanticJobs[id] = nil
                    finishPipeline(id: id, attemptID: attempt)
                }
            }
            let validate = { [self] in
                try Task.checkCancellation()
                guard consent.allowsTransfer, consent.epoch == consentEpoch, !showingSettings,
                      pipelineMayRun(id: id, attemptID: attempt),
                      account.recognitionAccountIdentity == accountIdentity,
                      let current = records.first(where: { $0.id == id }), current.currentAttemptID == attempt,
                      current.status == .succeeded, current.result == result,
                      semanticJobs[id]?.runID == runID else { throw CancellationError() }
            }
            var response: RecognitionModelResponse?
            var requestEvidence: RecognitionModelRequest?
            var failureStage: SemanticReviewFailure.Stage = .admission
            let timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(70)) } catch { return }
                guard self?.semanticJobs[id]?.runID == runID else { return }
                self?.cancelSemanticReview(id: id, reason: .deadline)
            }
            defer { timeout.cancel() }
            do {
                try validate()
                let begun = try await archive.beginSemanticReview(id: id, attemptID: attempt, runID: runID, expectedResult: result)
                try validate(); replace(begun)
                guard capacityAvailable else { throw SemanticReviewFailure(stage: .admission, code: .capacity) }
                failureStage = .collecting
                let collected = try await semanticSources(result)
                let sources = WikipediaReviewBudget.sources(collected, for: result)
                try validate()
                failureStage = .savingSources
                if sources.isEmpty {
                    let saved = try await archive.updateSemanticReview(id: id, attemptID: attempt, runID: runID, state: .insufficientEvidence, sources: [])
                    try validate(); replace(saved); return
                }
                let reviewing = try await archive.updateSemanticReview(id: id, attemptID: attempt, runID: runID, state: .reviewing, sources: sources)
                try validate(); replace(reviewing)
                let rawStageOne = record.modelJSONDocument.rawText
                failureStage = .preparingRequest
                let input = try WikipediaSemanticReview.input(result: result, rawStageOne: rawStageOne, sources: sources)
                requestEvidence = try .capture(input, recordID: id, attemptID: attempt, runID: runID,
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                    appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
                failureStage = .savingRequest
                let prepared = try await archive.saveSemanticRequest(id: id, attemptID: attempt, runID: runID, request: requestEvidence!)
                try validate(); replace(prepared)
                let willSend = { [self] in
                    try validate()
                    requestEvidence?.delivery = .dispatching
                    do {
                        let saved = try await archive.saveSemanticRequest(id: id, attemptID: attempt, runID: runID, request: requestEvidence!)
                        try validate(); replace(saved)
                    } catch {
                        if error is CancellationError { throw error }
                        throw SemanticReviewFailure(stage: .savingRequest, code: .storage)
                    }
                }
                let transportStarted: () throws -> Void = { try validate(); requestEvidence?.delivery = .submitted }
                let raw: String
                failureStage = .requestingModel
                semanticRequestCount += 1
                if let semanticProvider {
                    try await willSend(); try validate(); try transportStarted()
                    raw = try await semanticProvider(result, rawStageOne, sources, validate)
                } else {
                    raw = try await account.reviewWikipedia(input: input, validate: validate, willSend: willSend, transportStarted: transportStarted)
                }
                try validate()
                response = .capture(raw, sourceImageID: id, attemptID: attempt,
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                    appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown", promptRevision: WikipediaSemanticReview.promptRevision)
                failureStage = .savingRequest
                if let requestEvidence {
                    let saved = try await archive.saveSemanticRequest(id: id, attemptID: attempt, runID: runID, request: requestEvidence)
                    try validate(); replace(saved)
                }
                failureStage = .parsingReply
                let answer = try WikipediaSemanticReview.parse(raw, sources: sources, result: result)
                let state: RecognitionSemanticReview.State = answer.decision == .selected ? .succeeded : answer.decision == .no_match ? .noMatch : .insufficientEvidence
                failureStage = .savingResult
                let saved = try await archive.updateSemanticReview(id: id, attemptID: attempt, runID: runID, state: state, answer: answer, response: response)
                try validate(); replace(saved)
            } catch {
                // Payload was durably saved before transport. Keep a precise
                // transport receipt on network/HTTP failure as well as success.
                if let requestEvidence, requestEvidence.delivery == .submitted {
                    if Task.isCancelled {
                        Task { [weak self, archive] in
                            if let saved = try? await archive.saveSemanticRequest(id: id, attemptID: attempt, runID: runID, request: requestEvidence) { self?.replace(saved) }
                        }
                    } else if let saved = try? await archive.saveSemanticRequest(id: id, attemptID: attempt, runID: runID, request: requestEvidence) { replace(saved) }
                }
                let cancelled = Task.isCancelled || error is CancellationError
                // A cancellation task owns durable cancellation; late callbacks never publish.
                if cancelled {
                    if !Task.isCancelled, let saved = try? await archive.updateSemanticReview(id: id, attemptID: attempt, runID: runID, state: .cancelled) { replace(saved) }
                    return
                }
                let failure = SemanticReviewFailure.capture(error, stage: failureStage)
                if let saved = try? await archive.updateSemanticReview(id: id, attemptID: attempt, runID: runID, state: .failed, response: response, failure: failure) {
                    if (try? validate()) != nil { replace(saved) }
                } else if (try? validate()) != nil, var current = records.first(where: { $0.id == id }), current.semanticReview == nil || current.semanticReview?.runID == runID {
                    if current.semanticReview == nil { current.semanticReview = .init(recordID: id, attemptID: attempt, runID: runID) }
                    // Optional disk failure must not leave a spinner after the job ends.
                    // The next archive load recovers the durable pending marker without replay.
                    current.semanticReview?.state = .failed; current.semanticReview?.finishedAt = Date()
                    current.semanticReview?.failure = failure; replace(current)
                }
            }
        }
        semanticJobs[id] = .init(attemptID: attempt, runID: runID, task: task)
    }
    private func rememberWikipedia(_ id: UUID, _ events: [WikipediaDiagnostic]) {
        wikipediaDiagnostics[id] = Array(events.suffix(64))
        if wikipediaDiagnostics.count > 64, let other = wikipediaDiagnostics.keys.first(where: { $0 != id }) { wikipediaDiagnostics.removeValue(forKey: other) }
    }
    private func cancelWikipediaLookups(reason: RecognitionStopReason = .previewClosed) {
        cancelSemanticReviews(reason: reason)
        let outcome: WikipediaDiagnostic.Outcome = !consent.allowsTransfer ? .consentRevoked : !appActive ? .background : .cancelled
        for id in wikipediaTasks.keys { rememberWikipedia(id, [.init(.persistence, outcome)]) }
        wikipediaEpoch = UUID()
        wikipediaTasks.values.forEach { $0.cancel() }; wikipediaTasks.removeAll()
    }
    private func scheduleWikipedia(for id: UUID) {
        if usesSemanticReview {
            scheduleSemanticReview(for: id)
            if semanticJobs[id] == nil { semanticCardSnapshots[id] = nil }
            return
        }
        // Legacy mode is retained only for old fixture/replay comparisons; it never
        // receives schema17 results and never vetoes a semantic review selection.
        guard records.first(where: { $0.id == id })?.result?.searchContractVersion != 17 else { return }
        guard consent.allowsTransfer, appActive, !showingSettings, unsaved == nil,
              wikipediaTasks[id] == nil,
              let record = records.first(where: { $0.id == id }), record.status == .succeeded,
              previewOpen || previewCollapsed || darknessClosed || record.source == .photoLibrary,
              let result = record.result else { return }
        let subject = WikipediaSubject.matching(result, allowLegacy: false)
        let candidates = TextWikipediaCandidate.matching(result)
        guard result.usesEntitySearch || subject != nil || !candidates.isEmpty else { return }
        let attempt = record.currentAttemptID
        let epoch = wikipediaEpoch
        // Independent of recognition work and the Continue button. Never query old history.
        wikipediaTasks[id] = Task { [weak self, wikipediaLookup, wikipediaReferencesLookup] in
            let enrichment: WikipediaEnrichment
            if result.usesEntitySearch || !candidates.isEmpty { enrichment = await wikipediaReferencesLookup(result) }
            else if let subject { enrichment = .init(subject: await wikipediaLookup(subject)) }
            else { return }
            guard let self else { return }
            defer {
                if self.wikipediaEpoch == epoch { self.wikipediaTasks[id] = nil }
                self.finishPipeline(id: id, attemptID: attempt)
            }
            guard !Task.isCancelled, self.consent.allowsTransfer, self.wikipediaEpoch == epoch, self.appActive,
                  !self.showingSettings, enrichment.subject != nil || !enrichment.text.isEmpty || !enrichment.diagnostics.isEmpty,
                  let current = self.records.first(where: { $0.id == id }), current.status == .succeeded,
                  self.previewOpen || self.previewCollapsed || self.darknessClosed || current.source == .photoLibrary,
                  let currentResult = current.result, currentResult == result, current.currentAttemptID == attempt else {
                if self.wikipediaDiagnostics[id] == nil { self.rememberWikipedia(id, [.init(.persistence, .staleAttempt)]) }
                return
            }
            do {
                let saved = try await self.archive.attachWikipediaEnrichment(id: id, expectedResult: result, enrichment: enrichment, at: self.wikipediaNow())
                guard !Task.isCancelled, self.consent.allowsTransfer, self.wikipediaEpoch == epoch, self.appActive,
                      self.records.contains(where: { $0.id == id }) else { return }
                self.rememberWikipedia(id, saved.wikipediaDiagnostics ?? [])
                self.replace(saved)
            } catch {
                if Task.isCancelled { return }
                // Bounded closed diagnostics remain in memory if durable optional attachment fails.
                self.rememberWikipedia(id, Array(enrichment.diagnostics.prefix(63)) + [.init(.persistence, .saveFailed)])
            }
        }
    }
    func waitForWikipediaWork() async {
        for task in wikipediaTasks.values { await task.value }
        for job in semanticJobs.values { await job.task.value }
    }
    private func clearSubmittedPreviewIfFinished(id: UUID) {
        // A late completion can release only its own image. This never opens a camera
        // or arms capture; foreground, settings and the original deadline still win.
        if submittedPreview?.id == id, cycle.activeID != id, unsaved == nil {
            submittedPreview = nil
        }
    }
    private func persistCompletion(id: UUID, attemptID: UUID, result: RecognitionResult?, message: String?, date: Date, timedOut: Bool, modelResponse: RecognitionModelResponse? = nil, stopReason: RecognitionStopReason? = nil) async {
        do {
            let record = try await archive.complete(id: id, result: result, message: message, at: date, attemptID: attemptID, timedOut: timedOut, modelResponse: modelResponse, stopReason: stopReason)
            replace(record); unsaved = nil; storageError = nil
        } catch {
            unsaved = Unsaved(id: id, attemptID: attemptID, result: result, message: message, date: date, timedOut: timedOut, modelResponse: modelResponse, stopReason: stopReason)
            if let index = records.firstIndex(where: { $0.id == id }) {
                onRecordsWillChange?()
                records[index].result = result?.withSourceImage(id)
                records[index].status = result == nil ? .failed : .succeeded
                records[index].message = message; records[index].completedAt = date
                if let modelResponse { records[index].modelResponses = Array(((records[index].modelResponses ?? []).filter { $0.attemptID != modelResponse.attemptID } + [modelResponse]).suffix(3)) }
            }
            storageError = "最新回覆尚未寫入本機，請勿關閉 App；確認儲存空間後按重試保存。"
        }
    }
    private func replace(_ record: ArchivedRecognition) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            let current = records[index]
            guard record.attemptNumber >= current.attemptNumber,
                  record.attemptNumber != current.attemptNumber || record.currentAttemptID == current.currentAttemptID else { return }
            // Archive reads and writes resume independently on the main actor.
            // Reject an in-flight reload if a newer attempt/stage has published.
            historyRevision = UUID()
            var merged = record
            // Independent archive writes may resume on the main actor out of order.
            // Enrichment never clears another source or rolls a terminal AI result back.
            if record.currentAttemptID == current.currentAttemptID {
                if let old = current.semanticReview, let next = record.semanticReview, old.runID == next.runID, !old.isPending && next.isPending {
                    merged.semanticReview = old
                } else { merged.semanticReview = record.semanticReview ?? current.semanticReview }
            }
            if record.currentAttemptID == current.currentAttemptID {
                merged.wikipedia = record.wikipedia ?? current.wikipedia
                merged.wikipediaDiagnostics = record.wikipediaDiagnostics ?? current.wikipediaDiagnostics
                merged.textWikipedia = record.textWikipedia ?? current.textWikipedia
            }
            merged.modelResponses = record.modelResponses ?? current.modelResponses
            merged.productFacts = record.productFacts ?? current.productFacts
            if record.currentAttemptID == current.currentAttemptID && record.status == .pending && current.status != .pending {
                merged.status = current.status; merged.result = current.result
                merged.message = current.message; merged.completedAt = current.completedAt
                merged.retainedSuccess = current.retainedSuccess; merged.modelResponses = current.modelResponses
            }
            let before = cardRecord(for: current)
            if current.status == .pending, merged.status == .succeeded, usesSemanticReview,
               consent.allowsTransfer, pipelineMayRun(id: record.id, attemptID: record.currentAttemptID), !showingSettings,
               let result = merged.result, !WikipediaReviewCollector.queries(for: result).isEmpty {
                semanticCardSnapshots[record.id] = merged
            }
            if merged.semanticReview?.isPending == false || merged.status != .succeeded {
                semanticCardSnapshots[record.id] = nil
            }
            // Diagnostic-only transitions (including failure/no match) have no
            // visible row and must not perturb the reading anchor either.
            func layoutRecord(_ value: ArchivedRecognition) -> ArchivedRecognition {
                var value = value
                if value.currentSemanticReview?.source == nil { value.semanticReview = nil }
                value.modelResponses = nil; value.wikipediaDiagnostics = nil
                return value
            }
            if layoutRecord(before) != layoutRecord(cardRecord(for: merged)) { onRecordsWillChange?() }
            records[index] = merged
        }
    }
    func retrySaving() async {
        if let value = unsaved {
            await persistCompletion(id: value.id, attemptID: value.attemptID, result: value.result, message: value.message, date: value.date, timedOut: value.timedOut, modelResponse: value.modelResponse, stopReason: value.stopReason)
            clearSubmittedPreviewIfFinished(id: value.id)
        } else { await reloadHistory() }
    }
    func image(for record: ArchivedRecognition) async -> Data? {
        guard records.contains(where: { $0.id == record.id }) else { return nil }
        do {
            let jpeg = try await archive.image(for: record)
            return records.contains(where: { $0.id == record.id }) ? jpeg : nil
        }
        catch {
            guard records.contains(where: { $0.id == record.id }) else { return nil }
            missingImageIDs.insert(record.id)
            let message = "來源圖片無法讀取，文字及原始檔案均保留。"
            if !historyIssues.contains(message) { historyIssues.append(message) }
            return nil
        }
    }
    func waitForCurrentWork() async { await work?.value }
}

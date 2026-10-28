import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Keep the exact visible card offset through reply/Wiki height changes.
/// GeometryReader supplies SwiftUI's rendered coordinates (a lazy stack can
/// virtualize offscreen UIKit views). UIKit only applies the resulting offset.
@MainActor private final class HistoryReadingPosition: NSObject {
    weak var scroll: UIScrollView?
    private var frames: [UUID: CGRect] = [:]
    private var anchor: (id: UUID, y: CGFloat)?
    private var pending: (id: UUID, y: CGFloat)?
    private var reading = false
    private var offsetObservation: NSKeyValueObservation?
    private var interaction = HistoryPreviewPull()
    private var previousDistance: Double?
    private var towardTop = false
    var onManualStart: (() -> Void)?
    var canReopen: (() -> Bool)?
    var onReachedTop: (() -> Void)?
    func register(_ view: UIView) {
        var ancestor = view.superview
        while let current = ancestor {
            if let found = current as? UIScrollView {
                guard scroll !== found else { return }
                scroll?.panGestureRecognizer.removeTarget(self, action: #selector(panChanged(_:)))
                offsetObservation?.invalidate(); cancelInteraction(); scroll = found
                found.panGestureRecognizer.addTarget(self, action: #selector(panChanged(_:)))
                offsetObservation = found.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                    // UIKit scroll view mutations and this observer execute on main.
                    MainActor.assumeIsolated { self?.offsetChanged() }
                }
                return
            }
            ancestor = current.superview
        }
    }
    var distanceFromTop: Double? {
        guard let scroll else { return nil }
        return Double(scroll.contentOffset.y + scroll.adjustedContentInset.top)
    }
    var isScrollable: Bool {
        guard let scroll else { return false }
        return scroll.contentSize.height + scroll.adjustedContentInset.top + scroll.adjustedContentInset.bottom > scroll.bounds.height + 1
    }
    func cancelInteraction() { interaction.end(); previousDistance = nil; towardTop = false }
    func programmaticScrollWillBegin() { interaction.invalidateForProgrammaticChange() }
    func returnToLatest() {
        guard let scroll else { return }
        interaction.returnToLatest()
        towardTop = false; previousDistance = nil
        // Discard the old reading anchor before jumping, so a late reply/Wiki
        // layout cannot restore the previous card. No animated offset survives
        // into the next gesture, including when Reduce Motion is enabled.
        reading = true; anchor = nil; pending = nil
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: -scroll.adjustedContentInset.top), animated: false)
    }
    @objc private func panChanged(_ pan: UIPanGestureRecognizer) {
        guard let scroll else { return }
        switch pan.state {
        case .began:
            cancelInteraction(); interaction.newGestureBegan(); previousDistance = distanceFromTop
        case .changed:
            let movement = pan.translation(in: scroll)
            guard abs(movement.y) >= 12, abs(movement.y) > abs(movement.x) else { return }
            if !interaction.active {
                // Collapse first, then evaluate eligibility: an expanded preview
                // at gesture start must not force a second gesture at the top.
                onManualStart?(); beginReading()
                interaction.begin(canReopen: canReopen?() == true)
            }
            towardTop = pan.velocity(in: scroll).y > 0
            evaluateTop(manual: scroll.isDragging, toward: towardTop)
        case .ended:
            // UIKit starts deceleration just after this callback. Keep the same
            // permission for its offset events; it expires before another gesture.
            towardTop = pan.velocity(in: scroll).y > 0
            evaluateTop(manual: scroll.isDragging || scroll.isDecelerating, toward: towardTop)
        case .cancelled, .failed:
            cancelInteraction()
        default: break
        }
    }
    private func offsetChanged() {
        guard let scroll, let distance = distanceFromTop else { return }
        let previous = previousDistance; previousDistance = distance
        guard interaction.active else { return }
        if !scroll.isDragging && !scroll.isDecelerating { return }
        let movingUpList = previous.map { distance < $0 - 0.01 } ?? false
        // UIKit can keep isDragging true while decelerating, after the pan has
        // reset and reports zero velocity. Follow the same gesture's offsets
        // during deceleration instead of losing its direction at finger-up.
        let toward = scroll.isDecelerating ? movingUpList && towardTop : scroll.panGestureRecognizer.velocity(in: scroll).y > 0
        evaluateTop(manual: true, toward: toward)
    }
    private func evaluateTop(manual: Bool, toward: Bool) {
        guard let distance = distanceFromTop,
              interaction.update(distanceFromTop: distance, movingTowardTop: toward, isManualScroll: manual) else { return }
        onReachedTop?()
    }
    func beginReading() { reading = true; pending = nil; capture() }
    func endReading() { reading = false; anchor = nil; pending = nil; programmaticScrollWillBegin() }
    private func capture() {
        guard let scroll else { return }
        if let first = frames.filter({ $0.value.maxY > 0 && $0.value.minY < scroll.bounds.height })
            .min(by: { $0.value.minY < $1.value.minY }) {
            anchor = (first.key, first.value.minY)
        }
    }
    func contentChanged() {
        programmaticScrollWillBegin()
        guard reading else { return }
        pending = anchor
    }
    func geometryChanged(_ updated: [UUID: CGRect]) {
        let changed = updated != frames
        frames = updated
        guard reading else { return }
        guard let pending, let frame = updated[pending.id], let scroll else { capture(); return }
        guard changed else { return }
        let delta = frame.minY - pending.y
        if abs(delta) > 0.5 {
            let minimum = -scroll.adjustedContentInset.top
            let maximum = max(minimum, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            let offset = min(maximum, max(minimum, scroll.contentOffset.y + delta))
            if abs(offset - scroll.contentOffset.y) > 0.5 {
                programmaticScrollWillBegin()
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: offset), animated: false)
                return
            }
        }
        // List can publish another geometry pass after inserting a self-sizing
        // row. Retain the same anchor until the next manual gesture or explicit
        // jump, so a provisional matching frame does not end restoration early.
        capture()
    }
}

private struct HistoryFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
private struct HistoryScrollLocator: UIViewRepresentable {
    let keeper: HistoryReadingPosition
    let onManualStart: () -> Void
    let canReopen: () -> Bool
    let onReachedTop: () -> Void
    final class Marker: UIView {
        var register: (() -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); register?() }
    }
    func makeUIView(context: Context) -> Marker {
        let view = Marker(); view.isUserInteractionEnabled = false
        view.register = { [weak view] in if let view { keeper.register(view) } }
        return view
    }
    func updateUIView(_ view: Marker, context: Context) {
        keeper.onManualStart = onManualStart; keeper.canReopen = canReopen; keeper.onReachedTop = onReachedTop
        keeper.register(view)
    }
}

struct SingleCaptureView: View {
    @State private var model: SingleCaptureController
    @AppStorage("glance.showModelJSON") private var showsModelJSON = false
    private let shareProbe: SummaryCardProbe?
    private let motionAllowed: Bool
    @State private var enlargedImage: RecognitionImageSnapshot?
    @State private var readingPosition = HistoryReadingPosition()
    @State private var latestVisibility = HistoryLatestVisibility()
    private struct PhotoPickerRequest: Identifiable { let id: UUID }
    @State private var photoPickerRequest: PhotoPickerRequest?
    @State private var pickerDismissalID: UUID?
    @State private var photoLoadTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(model: SingleCaptureController = .shared, shareProbe: SummaryCardProbe? = nil, motionAllowed: Bool = true) { _model = State(initialValue: model); self.shareProbe = shareProbe; self.motionAllowed = motionAllowed }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                // Expanded geometry stays stable; only a manual history drag collapses it.
                let previewSide = max(0, min(geometry.size.width - 24, geometry.size.height * 0.52))
                let showsPreview = !model.previewCollapsed || model.selectedPhoto != nil || model.photoLoading
                VStack(spacing: 8) {
                    ZStack {
                        Color.black
                        if model.darknessClosed && !model.photoLoading && model.selectedPhoto == nil {
                            Text("畫面持續全黑，相機已關閉").foregroundStyle(.white)
                                .accessibilityIdentifier("cameraDarknessClosed")
                        } else if !model.previewOpen, let snapshot = model.submittedPreview ?? model.selectedPhoto, let image = UIImage(data: snapshot.jpeg) {
                            Image(uiImage: image).resizable().scaledToFit()
                                .frame(width: previewSide, height: previewSide)
                                .accessibilityLabel(model.selectedPhoto != nil ? "所選相簿圖片預覽" : "本次送出的圖片")
                                .accessibilityValue(snapshot.id.uuidString)
                                .accessibilityIdentifier(model.selectedPhoto != nil ? "selectedPhotoPreview" : "singleCaptureFrozenImage")
                        } else if model.previewOpen {
                            Group {
                                if model.isSynthetic { Text("合成預覽").font(.caption).foregroundStyle(.white) }
                                else { CameraVisiblePreview(capture: model.capture) }
                            }.frame(width: previewSide, height: previewSide).clipped()
                                .accessibilityHidden(model.submittedPreview != nil)
                            if let snapshot = model.submittedPreview, let image = UIImage(data: snapshot.jpeg) {
                                // Cover the live layer with the exact request JPEG, without cropping
                                // it again or replacing it with a later frame or archived thumbnail.
                                Color.black
                                Image(uiImage: image).resizable().scaledToFit()
                                    .frame(width: previewSide, height: previewSide)
                                    .accessibilityLabel("本次送出的圖片")
                                    .accessibilityValue(snapshot.id.uuidString)
                                    .accessibilityIdentifier("singleCaptureFrozenImage")
                            } else {
                                // Aiming guide only. The entire visible square is sent.
                                RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.8), lineWidth: 1)
                                    .frame(width: previewSide * 0.78, height: previewSide * 0.78)
                            }
                        } else {
                            Color.black
                            Text(model.photoLoading ? "正在載入所選相片" : model.permissionDenied ? "尚未允許使用相機" : "鏡頭已關閉")
                                .foregroundStyle(.white)
                        }
                    }.frame(width: previewSide, height: previewSide)
                        .frame(height: showsPreview ? previewSide : 0, alignment: .top)
                        .opacity(showsPreview ? 1 : 0)
                        .clipped().accessibilityElement(children: .contain)
                        .accessibilityHidden(!showsPreview)
                        .allowsHitTesting(showsPreview)
                        .accessibilityIdentifier("singleCapturePreview")
                    VStack(spacing: 8) {
                    controls.padding(.horizontal)
                    if model.permissionDenied {
                        Button("在系統設定允許相機") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }.font(.footnote).accessibilityIdentifier("cameraPermissionSettings")
                    }
                    if !model.canRecognize {
                        Button(model.consent.allowsTransfer ? "登入 ChatGPT 以開始辨識" : "完成首次設定以開始辨識") { model.resumeSetup() }
                            .font(.subheadline).disabled(model.busy)
                    }
                    if let error = model.storageError {
                        VStack(spacing: 4) {
                            Text(error).font(.footnote).foregroundStyle(.red)
                            Button("重試保存／讀取") { Task { await model.retrySaving() } }
                                .accessibilityIdentifier("retryArchive")
                        }.padding(.horizontal)
                    }
                    if !model.historyIssues.isEmpty {
                        Text("部分紀錄或圖片無法讀取，原始檔案已保留。")
                            .font(.footnote).foregroundStyle(.orange).padding(.horizontal)
                    }
                    HistoryDeletionNotice(model: model)
                    }.fixedSize(horizontal: false, vertical: true)
                    if model.records.isEmpty {
                        ContentUnavailableView("尚無辨識紀錄", systemImage: "photo.on.rectangle.angled",
                            description: Text("按開始辨識，停穩 1 秒後辨識一張。紀錄會保留在此裝置。"))
                    } else {
                        ScrollViewReader { reader in
                        List {
                                ForEach(model.records) { record in
                                    ArchivedRecognitionRow(record: model.cardRecord(for: record), currentRecord: { model.records.first { $0.id == record.id } },
                                        isRequestPending: model.cycle.activeID == record.id,
                                        showsPendingProgress: false,
                                        image: { await model.image(for: record) },
                                        onOpen: { enlargedImage = $0 }, shareProbe: shareProbe, showsModelJSON: showsModelJSON,
                                        retryEnabled: model.canRetryImage(record), onRetry: { _ = model.retryImage(id: record.id) },
                                        recognitionAction: model.cardRecognitionAction(for: record),
                                        continueEnabled: model.canContinueSecondStage(record),
                                        onContinue: { _ = model.continueSecondStage(id: record.id) },
                                        refreshNotice: record.retainedResultNotice, missingImageReason: model.missingImageReason(record))
                                        .id(record.id)
                                        .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
                                        .listRowSeparator(.hidden)
                                        .listRowBackground(Color.clear)
                                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                            if model.canDeleteRecord(record.id) {
                                                Button("刪除", role: .destructive) {
                                                    Task { _ = await model.deleteRecord(id: record.id) }
                                                }.accessibilityIdentifier("deleteRecord-\(record.sequence)")
                                            }
                                        }
                                        .background(GeometryReader { position in
                                            Color.clear.preference(key: HistoryFrames.self,
                                                value: [record.id: position.frame(in: .named("recognitionHistoryViewport"))])
                                        })
                                .background(HistoryScrollLocator(keeper: readingPosition,
                                    onManualStart: {
                                        withAnimation(reduceMotion || !motionAllowed ? nil : .easeOut(duration: 0.18)) { model.historyDragBegan() }
                                    }, canReopen: { model.canReopenHistoryPreview },
                                    onReachedTop: { Task { await model.reopenPreviewFromHistoryPull() } }))
                                }
                        }.listStyle(.plain).scrollContentBackground(.hidden)
                        // Keep the reading anchor through completion/enrichment/layout changes.
                        .coordinateSpace(name: "recognitionHistoryViewport")
                        .onPreferenceChange(HistoryFrames.self) { frames in
                            readingPosition.geometryChanged(frames)
                            let first = model.records.first?.id
                            latestVisibility.update(firstRowBottom: first.flatMap { frames[$0].map { Double($0.maxY) } },
                                laterRowAtTop: frames.contains { $0.key != first && $0.value.minY <= -8 && $0.value.maxY > 8 },
                                scrollable: readingPosition.isScrollable,
                                atTop: (readingPosition.distanceFromTop ?? 0) <= HistoryPreviewPull.topTolerance)
                        }
                        .accessibilityIdentifier("recognitionArchiveList")
                        .scrollBounceBehavior(.always, axes: .vertical)
                        .overlay(alignment: .bottomTrailing) {
                            if model.previewCollapsed && model.readingHistory && !showsPreview && latestVisibility.visible {
                                Button {
                                    latestVisibility = HistoryLatestVisibility()
                                    readingPosition.returnToLatest()
                                } label: {
                                    Label("回到最新", systemImage: "arrow.up.to.line")
                                        .font(.subheadline.weight(.semibold))
                                        .padding(.horizontal, 16).padding(.vertical, 12)
                                        .frame(minHeight: 44)
                                        .background(.regularMaterial, in: Capsule())
                                        .overlay(Capsule().strokeBorder(.primary.opacity(0.15)))
                                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                                }.buttonStyle(.plain)
                                    .accessibilityIdentifier("returnToLatest")
                                    .accessibilityHint("回到第一筆紀錄，鏡頭保持收合")
                                    .padding(.trailing, 16).padding(.bottom, 12)
                            }
                        }
                        .onChange(of: model.readingHistory) { _, reading in
                            if !reading { readingPosition.endReading() }
                        }
                        .task(id: model.pendingPresentation) {
                            // Also runs when the first pending card creates the list.
                            await Task.yield()
                            guard !Task.isCancelled, !model.readingHistory,
                                  let pending = model.pendingPresentation,
                                  model.records.contains(where: { $0.id == pending.recordID }) else { return }
                            readingPosition.endReading()
                            withAnimation(reduceMotion || !motionAllowed ? nil : .easeOut(duration: 0.18)) {
                                reader.scrollTo(pending.recordID, anchor: .top)
                            }
                        }
                        }
                    }
                }
            }
            .navigationTitle("Glance").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.showingSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("設定")
                }
            }
            .sheet(item: $enlargedImage) { RecognitionImageViewer(snapshot: $0, shareProbe: shareProbe) }
            .onChange(of: model.records.map(\.id)) { _, ids in
                if let id = enlargedImage?.id, !ids.contains(id) { enlargedImage = nil }
            }
            .sheet(item: $photoPickerRequest, onDismiss: {
                if let id = pickerDismissalID { model.photoPickerDismissed(id: id) }
                pickerDismissalID = nil
            }) { request in
                SinglePhotoPicker { provider in
                    let requestID = request.id
                    guard requestID == pickerDismissalID else { return }
                    if let provider,
                       model.photoTransferStarted(id: requestID) {
                        photoLoadTask?.cancel()
                        photoLoadTask = Task {
                            do {
                                let data: Data = try await withCheckedThrowingContinuation { continuation in
                                    provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                                        if let data { continuation.resume(returning: data) }
                                        else { continuation.resume(throwing: error ?? CocoaError(.fileReadCorruptFile)) }
                                    }
                                }
                                guard !Task.isCancelled else { return }
                                _ = await model.prepareSelectedPhoto(data, selectionID: requestID)
                            } catch { model.photoSelectionFailed(id: requestID) }
                        }
                    }
                    photoPickerRequest = nil
                }
            }
            .sheet(isPresented: $model.showingOnboarding) { FirstUseView(model: model).environment(\.dynamicTypeSize, dynamicTypeSize) }
            .onChange(of: model.account.recognitionAccountIdentity) { _, _ in model.accountStateChanged() }
            .onChange(of: model.account.planAccessReady) { _, _ in model.accountStateChanged() }
            .sheet(isPresented: $model.showingSettings) {
                NavigationStack { SingleCaptureSettingsView(model: model) }
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
            }
            .onChange(of: model.showingSettings) { _, shown in if shown { readingPosition.cancelInteraction() }; model.settingsChanged(shown) }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    if !RecognitionShareSession.shared.active { enlargedImage = nil }
                    photoLoadTask?.cancel(); photoPickerRequest = nil
                }
                if phase != .active { readingPosition.cancelInteraction() }
                model.foreground(phase)
            }
            .onDisappear { photoLoadTask?.cancel(); readingPosition.cancelInteraction(); model.onRecordsWillChange = nil }
            .task {
                model.onRecordsWillChange = { [readingPosition] in readingPosition.contentChanged() }
                model.foreground(scenePhase)
                await model.bootstrap()
            }
        }
    }
    private var controls: some View {
        VStack(spacing: 4) {
            RecognitionActionRow {
                if model.isRecognizingImage {
                    // A waiting status stays legible even though another request is disabled.
                    Button {} label: { RecognitionActionLabel(title: "開始辨識", pending: true, motionAllowed: motionAllowed) }
                        .buttonStyle(RecognitionActionButtonStyle(pending: true))
                        .disabled(true).accessibilityIdentifier("continueCapture")
                } else {
                    Button {
                        Task { _ = await model.startRecognition() }
                    } label: { RecognitionActionLabel(title: model.openingPreview ? "開啟中" : model.acquiring ? "等待停穩 1 秒" : "開始辨識") }
                    .buttonStyle(RecognitionActionButtonStyle())
                    .disabled(!model.canStartRecognition).accessibilityIdentifier("continueCapture")
                }
                Button {
                    guard let requestID = model.beginPhotoSelection() else { return }
                    photoLoadTask?.cancel(); pickerDismissalID = requestID
                    photoPickerRequest = .init(id: requestID)
                } label: { RecognitionActionLabel(title: "選擇相簿圖片") }
                .buttonStyle(RecognitionActionButtonStyle(secondary: true))
                .disabled(!model.canChoosePhoto).accessibilityIdentifier("choosePhoto")
            }
            if let message = model.photoMessage { Text(message).font(.footnote).foregroundStyle(.secondary) }
            if let message = model.focusMessage { CaptureActionNotice(message: message) }
            if model.acquiring {
                if model.focusMessage == nil {
                    if dynamicTypeSize.isAccessibilitySize {
                        ScrollView { waitingGuidance }
                            .frame(height: CaptureActionNotice.accessibilityHeight)
                    } else { waitingGuidance }
                }
                Button("取消取景") { model.cancelAcquisition() }
                    .buttonStyle(.bordered).accessibilityIdentifier("cancelCapture")
            }
            if model.expired { Text(model.status).font(.footnote).foregroundStyle(.secondary) }
        }
    }
    private var waitingGuidance: some View {
        Text("請保持手機與目標穩定。")
            .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("captureWaitingGuidance")
    }
}

private struct SingleCaptureSettingsView: View {
    let model: SingleCaptureController
    @State private var showingConsent = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("glance.showModelJSON") private var showsModelJSON = false
    var body: some View {
        // Read consent in this view's body so an already-presented sheet tracks
        // accept/withdraw changes even when no outer presentation state changes.
        let allowsTransfer = model.consent.allowsTransfer
        Form {
            Section("資料處理與同意") {
                if allowsTransfer {
                    DisclosureGroup("資料處理說明") { DataUseExplanation() }
                    Text("已同意版本 \(DataConsent.currentVersion)").font(.footnote)
                        .accessibilityIdentifier("consentAcceptedStatus")
                    Button("撤回資料傳送同意", role: .destructive) { model.withdrawDataUse() }
                        .accessibilityIdentifier("consentWithdraw")
                } else {
                    Button("查看並同意資料傳送說明") { showingConsent = true }
                        .accessibilityIdentifier("consentOpenSettings")
                }
                if let error = model.consent.error { Text(error).foregroundStyle(.red) }
            }
            Section("ChatGPT") {
                SIWCAccountActions(model: model.account).disabled(model.busy || !allowsTransfer)
                if !model.account.status.isEmpty {
                    Text(model.account.status).font(.footnote).textSelection(.enabled).accessibilityIdentifier("siwcStatus")
                }
                if model.account.authenticated {
                    Button("登出 ChatGPT") { model.account.signOut() }.disabled(model.busy || model.account.busy)
                        .accessibilityIdentifier("siwc-sign-out")
                }
                PlanUsageWarning()
            }
            Section("資料與參考資訊") {
                Text("本機紀錄").font(.headline).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("settingsLocalHeading")
                Toggle("顯示 JSON 按鈕", isOn: $showsModelJSON)
                    .accessibilityIdentifier("showModelJSON")
                Text("在每筆紀錄的分享按鈕左側顯示 JSON，可查看與分享已保存的 AI 原始回覆。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Glance 的歷史紀錄保存在此裝置，不會自動刪除；辨識時圖片已送至 OpenAI，刪除本機紀錄不會刪除服務端資料。")
                Text("關閉 App 後仍保留；未完成的辨識不會自動重送。")
                HistoryDeletionSettings(model: model)
                Text("相簿圖片").font(.headline).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("settingsPhotoHeading")
                Text("相簿只讀取你當次選定的一張圖片；返回 App 且載入成功後直接保存並辨識一次。圖片會縮小後保存與辨識，不保留原檔附帶的拍攝位置、時間及相機資訊；照片中的人臉與文字仍會保留。相簿原圖不會被修改；刪除辨識紀錄也不會刪除相簿中的原圖。")
                Text("維基百科").font(.headline).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("settingsWikipediaHeading")
                Text("辨識後，Glance 會將經檢查的搜尋關鍵字送至維基百科；找到候選頁面時，再將第一階段辨識資料與候選頁面摘錄送至 OpenAI，判斷來源並補充內容。這是額外一次文字 AI 請求，會使用你的帳戶額度。沒有合適的關鍵字或候選頁面，就不進行對應步驟。")
                Text("Google 搜尋").font(.headline).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("settingsGoogleHeading")
                Text("Google 搜尋只會在你點選連結後開啟，設定為中文結果並偏向台灣地區；商品搜尋詞可能包含本機可靠辨識的商品條碼。不會自動向 Google 查詢。")
                Text("背景傳送").font(.headline).accessibilityAddTraits(.isHeader)
                Text(DataUseExplanation.backgroundTransferText).accessibilityIdentifier("settingsBackgroundExplanation")
                Link("完整隱私聲明", destination: DataUseExplanation.privacyURL).accessibilityIdentifier("settingsPrivacyLink")
            }
            Section("App 資訊") {
                LabeledContent("版本", value: GlanceBuildVersion.display())
                    .accessibilityIdentifier("glanceBuildVersion")
            }
        }
        // Keep the updated status at the top of this same settings presentation.
        .id(allowsTransfer)
        .sheet(isPresented: $showingConsent) {
            DataUseConsentPage(consent: model.consent, onAccept: {
                model.acceptDataUse()
                if model.consent.allowsTransfer { showingConsent = false }
            }, onClose: { showingConsent = false })
                .environment(\.dynamicTypeSize, dynamicTypeSize)
                .presentationDetents([.large])
        }
        .navigationTitle("設定")
            .toolbar { Button("完成") { model.showingSettings = false } }
    }
}

private struct HistoryDeletionNotice: View {
    let model: SingleCaptureController
    var body: some View {
        if let error = model.deletionError {
            VStack(spacing: 4) {
                Text(error).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("historyDeletionError")
                if model.deletionCleanupPending {
                    Button("重試清理") { Task { await model.retryDeletedFileCleanup() } }
                        .disabled(model.deletingHistory).accessibilityIdentifier("retryHistoryCleanup")
                }
            }.padding(.horizontal)
        }
    }
}

private struct HistoryDeletionSettings: View {
    let model: SingleCaptureController
    @State private var confirming = false
    @State private var confirmedIDs: Set<UUID> = []
    var body: some View {
        Button("清除全部辨識紀錄", role: .destructive) {
            confirmedIDs = Set(model.records.map(\.id)); confirming = true
        }.disabled(!model.canClearHistory).accessibilityIdentifier("clearAllHistory")
            .alert("刪除全部 \(confirmedIDs.count) 筆紀錄及來源圖片？", isPresented: $confirming) {
                Button("取消", role: .cancel) { confirmedIDs = [] }
                Button("刪除全部", role: .destructive) {
                    let ids = confirmedIDs; confirmedIDs = []
                    Task { _ = await model.clearHistory(confirmedIDs: ids) }
                }.accessibilityIdentifier("confirmClearAllHistory")
            } message: {
                Text("只刪除 Glance 內的紀錄與圖片，不影響相簿原圖或已分享內容。刪除後無法復原。")
            }
        if let reason = model.clearHistoryBlockedReason {
            Text(reason).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("clearHistoryBlockedReason")
        }
        HistoryDeletionNotice(model: model)
    }
}

struct CaptureActionNotice: View {
    static let accessibilityHeight: CGFloat = 60
    let message: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            ScrollView { notice }
                // Leave the ongoing acquisition's cancel button inside the
                // safe area while keeping the full guidance scrollable.
                .frame(height: Self.accessibilityHeight).accessibilityIdentifier("captureNoticeScroll")
        } else { notice }
    }
    private var notice: some View {
        Text(message).font(.subheadline)
            .foregroundStyle(colorScheme == .dark
                ? Color(red: 1, green: 0.55, blue: 0.55)
                : Color(red: 0.65, green: 0.10, blue: 0.12))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("captureActionNotice")
    }
}

enum GlanceBuildVersion {
    static func display(bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        return "\(version)（\(build)）"
    }
}

/// A status, not a percentage: the owner inserts it only for the current request.
/// TimelineView owns its schedule; removing the status leaves no timer/task behind.
struct RecognitionProgressLabel: View {
    // Allows a static presentation without overriding the system accessibility setting.
    var motionAllowed = true
    var foreground: Color = .primary
    var wraps = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .body) private var dotSize: CGFloat = 5
    @ScaledMetric(relativeTo: .body) private var dotSpacing: CGFloat = 4
    @State private var visible = false
    private var animates: Bool { visible && motionAllowed && !reduceMotion && scenePhase == .active }
    var body: some View {
        let layout = wraps && dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 8))
        layout {
            Text("辨識中").font(.body.weight(.semibold))
            TimelineView(.animation(minimumInterval: 0.4, paused: !animates)) { context in
                let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 3
                HStack(spacing: dotSpacing) {
                    ForEach(0..<3) { index in
                        Circle().frame(width: dotSize, height: dotSize)
                            .opacity(!animates || phase == index ? 1 : 0.3)
                    }
                }
                .frame(width: dotSize * 3 + dotSpacing * 2, height: dotSize)
            }.accessibilityHidden(true)
        }
        .foregroundStyle(foreground)
        .fixedSize(horizontal: !wraps, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("辨識中")
        .accessibilityAddTraits(.isStaticText)
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }
}

/// Both actions reserve every state, including wrapped labels at large text sizes.
/// The invisible sizing row is static: it creates no hidden animation or AX element.
struct RecognitionActionLabel: View {
    var title: String
    var pending = false
    var motionAllowed = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var dotSize: CGFloat = 5
    @ScaledMetric(relativeTo: .body) private var dotSpacing: CGFloat = 4
    var body: some View {
        let progressLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 8))
        ZStack {
            Text("開始辨識").font(.body.weight(.semibold)).hidden().accessibilityHidden(true)
            Text("等待停穩 1 秒").font(.body.weight(.semibold)).hidden().accessibilityHidden(true)
            Text("選擇相簿圖片").font(.body.weight(.semibold)).hidden().accessibilityHidden(true)
            Text("重新開啟鏡頭").font(.body.weight(.semibold)).hidden().accessibilityHidden(true)
            progressLayout {
                Text("辨識中").font(.body.weight(.semibold))
                Color.clear.frame(width: dotSize * 3 + dotSpacing * 2, height: dotSize)
            }.hidden().accessibilityHidden(true)
            if pending { RecognitionProgressLabel(motionAllowed: motionAllowed, foreground: RecognitionActionButtonStyle.pendingText, wraps: true) }
            else { Text(title).font(.body.weight(.semibold)) }
        }.multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }
}

struct RecognitionActionButtonStyle: ButtonStyle {
    var pending = false
    var secondary = false
    @Environment(\.isEnabled) private var enabled
    static let pendingText = Color(red: 0.23, green: 0.23, blue: 0.24)
    static let pendingBackground = Color(white: 0.92)
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: .infinity)
            .foregroundStyle(pending ? Self.pendingText : secondary ? Color.accentColor : .white)
            // Stable light surface preserves dark-gray contrast in both color schemes.
            .background(pending ? Self.pendingBackground : secondary ? Color.accentColor.opacity(0.12) : Color.accentColor, in: Capsule())
            .contentShape(Capsule())
            .opacity(pending || enabled ? 1 : 0.5)
            .opacity(configuration.isPressed && !pending ? 0.8 : 1)
    }
}

/// Give both controls the same width and the taller label's complete height.
/// Measuring at the final width also handles Dynamic Type wrapping consistently.
struct RecognitionActionRow: Layout {
    private let spacing: CGFloat = 12
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let gaps = spacing * CGFloat(subviews.count - 1)
        let width = proposal.width ?? (subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0) * CGFloat(subviews.count) + gaps
        let itemWidth = max(0, (width - gaps) / CGFloat(subviews.count))
        let height = subviews.map { $0.sizeThatFits(.init(width: itemWidth, height: nil)).height }.max() ?? 44
        return CGSize(width: width, height: max(44, height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let width = max(0, (bounds.width - spacing * CGFloat(subviews.count - 1)) / CGFloat(subviews.count))
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(index) * (width + spacing), y: bounds.minY),
                anchor: .topLeading, proposal: .init(width: width, height: bounds.height))
        }
    }
}

struct RecognitionPendingBadge: View {
    var motionAllowed = true
    var body: some View {
        RecognitionProgressLabel(motionAllowed: motionAllowed, foreground: RecognitionActionButtonStyle.pendingText)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(RecognitionActionButtonStyle.pendingBackground, in: Capsule())
    }
}

private extension ArchivedRecognition {
    // Both row actions use the completed first-stage record, independently of
    // optional encyclopedia work or whether legacy raw JSON was saved.
    var firstStageActionsEnabled: Bool { (status == .succeeded || retainedSuccess != nil) && canShare }
}

struct ArchivedRecognitionRow: View {
    let record: ArchivedRecognition
    let currentRecord: () -> ArchivedRecognition?
    var isRequestPending = false
    var showsPendingProgress = true
    let image: () async -> Data?
    let onOpen: (RecognitionImageSnapshot) -> Void
    var shareProbe: SummaryCardProbe? = nil
    var showsModelJSON = false
    var retryEnabled = false
    var onRetry: (() -> Void)? = nil
    var recognitionAction: SingleCaptureController.CardRecognitionAction = .fullImage
    var continueEnabled = false
    var onContinue: (() -> Void)? = nil
    var refreshNotice: String? = nil
    var missingImageReason: String? = nil
    @State private var jpeg: Data?
    @State private var originalExpanded = false
    private struct JSONSnapshot: Identifiable {
        let id: UUID
        let attempt: Int
        let document: RecognitionJSONDocument
        let secondStage: RecognitionJSONDocument?
        let secondRequest: RecognitionJSONDocument
        let combinedShareText: String
    }
    @State private var jsonSnapshot: JSONSnapshot?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var actionAppearance: RecognitionCardActionAppearance {
        .init(accessibilitySize: dynamicTypeSize.isAccessibilitySize)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let headerLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            headerLayout {
              HStack(alignment: .top, spacing: 12) {
                if let jpeg {
                    RecognitionSourceThumbnail(snapshot: .init(id: record.id, jpeg: jpeg, allowsImageSharing: record.status == .succeeded), onOpenImage: onOpen)
                } else { Image(systemName: "photo").frame(width: 64, height: 64).foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 4) {
                    Text("第 \(record.sequence) 張圖片").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("archiveRow-\(record.sequence)")
                    if record.status == .pending {
                        if isRequestPending && showsPendingProgress {
                            RecognitionPendingBadge()
                                .accessibilityIdentifier("archivePending-\(record.sequence)")
                        } else if !isRequestPending {
                            Text("辨識尚未完成").foregroundStyle(.primary)
                        }
                    }
                    Text((record.source == .photoLibrary ? "相簿・ " : "") + record.captureTimestamp()).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("archiveTimestamp-\(record.sequence)")
                }
              }.frame(maxWidth: .infinity, alignment: .leading)
              HStack(spacing: 12) {
                if showsModelJSON {
                    Button {
                        guard let current = currentRecord(), current.id == record.id, current.firstStageActionsEnabled else { return }
                        jsonSnapshot = .init(id: current.id, attempt: current.displayRecord.attemptNumber, document: current.modelJSONDocument, secondStage: current.semanticJSONDocument, secondRequest: current.semanticRequestJSONDocument, combinedShareText: current.combinedJSONShareText)
                    } label: {
                        Text("JSON")
                            .modifier(RecognitionCardActionLabel(appearance: actionAppearance,
                                enabled: record.firstStageActionsEnabled))
                    }
                    .buttonStyle(RecognitionCardActionButtonStyle())
                    .disabled(!record.firstStageActionsEnabled)
                    .accessibilityLabel("查看第 \(record.sequence) 筆原始 JSON")
                    .accessibilityIdentifier("modelJSON-\(record.sequence)")
                }
                if let onRetry {
                    RecognitionRetryActionButton(state: recognitionAction,
                        appearance: actionAppearance, sequence: record.sequence,
                        retryEnabled: retryEnabled && jpeg != nil,
                        continueEnabled: continueEnabled, missingImageReason: missingImageReason,
                        onRetry: onRetry, onContinue: { onContinue?() })
                }
                RecognitionShareButton(text: record.shareText(), imageAvailable: jpeg != nil, probe: shareProbe, snapshot: {
                        guard let current = currentRecord(), current.id == record.id, current.firstStageActionsEnabled else { return nil }
                        let document = current.shareDocument()
                        return .init(text: document.plainText, jpeg: jpeg, document: document)
                    }, cardActionAppearance: actionAppearance, actionsEnabled: record.firstStageActionsEnabled)
                    .frame(width: actionAppearance.size.width, height: actionAppearance.size.height)
                    .disabled(!record.firstStageActionsEnabled || (record.shareText().isEmpty && jpeg == nil))
              }.fixedSize(horizontal: true, vertical: false)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("archiveActions-\(record.sequence)")
            }
            if !record.barcodes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("【條碼】").font(.body)
                    ForEach(Array(record.barcodes.enumerated()), id: \.offset) { index, value in
                        RecognitionBarcodeValue(text: value)
                            .accessibilityIdentifier("archiveBarcode-\(record.sequence)-\(index)")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("archiveBarcodes-\(record.sequence)")
            }
            if let result = record.presentationResult {
                RecognitionSelectableText(result: result, recordID: record.id, sequence: record.sequence,
                    originalExpanded: $originalExpanded)
            }
            if let query = record.googleSearch, let url = query.googleURL {
                    Link(destination: url) {
                        RecognitionReferenceLabel(text: "Google 搜尋：\(query.query)")
                    }
                    // Opt out of List's automatic whole-row button activation.
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Google 搜尋：\(query.query)")
                    .accessibilityIdentifier("googleSearch-\(record.sequence)")
                }
            if let review = record.currentSemanticReview {
                if let source = review.source, let title = review.displayTitle {
                    Link(destination: source.url) { RecognitionReferenceLabel(text: "維基百科：\(title)") }
                        .buttonStyle(.plain).accessibilityIdentifier("wikipedia-\(record.sequence)")
                }
            } else if let result = record.result, let reference = record.wikipedia {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        if reference.isCurrent(for: result, at: context.date) {
                            Link(destination: reference.canonicalURL) {
                                RecognitionReferenceLabel(text: "維基百科：\(reference.displayTitle)")
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("維基百科：\(reference.displayTitle)")
                            .accessibilityIdentifier("wikipedia-\(record.sequence)")
                        }
                    }
                }
            if record.textWikipedia?.isEmpty == false {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    ForEach(record.currentTextWikipedia(at: context.date), id: \.candidateKey) { reference in
                        Link(destination: reference.canonicalURL) {
                            RecognitionReferenceLabel(text: "原文參考：\(reference.displayTitle)")
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("原文參考：\(reference.displayTitle)")
                        .accessibilityIdentifier("textWikipedia-\(record.sequence)-\(reference.pageID)")
                    }
                }
            }
            // The visible result may be the previous success while a newer
            // attempt is pending or failed. Its attempt metadata is independent.
            Text((currentRecord() ?? record).recognitionStatusSummary())
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("archiveAttempt-\(record.sequence)")
            if let refreshNotice { Text(refreshNotice).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("refreshNotice-\(record.sequence)") }
            if let missingImageReason { Text(missingImageReason).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("refreshMissingImage-\(record.sequence)") }
            if record.status == .failed || record.status == .interrupted, let onRetry {
                Button("重試這張圖片", action: onRetry).buttonStyle(.bordered)
                    .disabled(!retryEnabled || jpeg == nil)
                    .accessibilityIdentifier("retryImage-\(record.sequence)")
            }

        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("archiveCard-\(record.sequence)")
            .sheet(item: $jsonSnapshot) { snapshot in
                RecognitionJSONViewer(firstStage: snapshot.document, secondStage: snapshot.secondStage, secondRequest: snapshot.secondRequest, combinedShareText: snapshot.combinedShareText, attempt: snapshot.attempt, probe: shareProbe)
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
            }
            .task(id: record.id) { jpeg = await image() }
            .onDisappear { jpeg = nil }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { jpeg = await image() } } }
    }
}

private struct RecognitionJSONViewer: View {
    let firstStage: RecognitionJSONDocument
    let secondStage: RecognitionJSONDocument?
    let secondRequest: RecognitionJSONDocument
    let combinedShareText: String
    @State private var stage = 1
    private var document: RecognitionJSONDocument {
        if stage == 3 { return secondRequest }
        if stage == 2 { return secondStage ?? .init(rawText: nil, formattedText: nil, message: "本次未保存第二階段回覆。", version: nil, promptRevision: nil) }
        return firstStage
    }
    private func title(_ value: Int) -> String { value == 1 ? "第一階段回覆" : value == 3 ? "第二階段請求" : "第二階段回覆" }
    let attempt: Int
    let probe: SummaryCardProbe?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("第 \(attempt) 次嘗試・\(title(stage))")
                .font(.subheadline).accessibilityIdentifier("modelJSONOrigin")
            Text("分享會合併三個段落，保留各段原文與缺資料狀態。")
                .font(.footnote).foregroundStyle(.secondary)
            if let version = document.version, let revision = document.promptRevision {
                Text("\(version)・\(revision)").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("modelJSONVersion")
            }
            Text(document.message).font(.footnote).accessibilityIdentifier("modelJSONMessage")
        }.fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    var body: some View {
        NavigationStack {
          GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 8) {
                let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
                    layout {
                        ForEach([1, 3, 2], id: \.self) { value in
                            Button { stage = value } label: {
                                Text(title(value))
                                    .font(.subheadline.weight(stage == value ? .semibold : .regular))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(stage == value ? Color(uiColor: .secondarySystemGroupedBackground) : .clear,
                                                in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(stage == value ? .isSelected : [])
                            .accessibilityIdentifier("modelJSONStage-\(value)")
                        }
                    }.padding(4)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("modelJSONStage")
                if dynamicTypeSize.isAccessibilitySize {
                    ScrollView { details }
                        .frame(maxHeight: document.formattedText == nil ? .infinity : geometry.size.height * 0.45)
                        .accessibilityIdentifier("modelJSONDetails")
                } else {
                    details
                }
                if let text = document.formattedText {
                    RecognitionJSONText(text: text)
                } else { Spacer() }
            }.padding()
          }
                .navigationTitle("AI JSON").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() }.accessibilityIdentifier("closeModelJSON") }
                        ToolbarItem(placement: .topBarTrailing) {
                            RecognitionShareButton(text: combinedShareText, probe: probe, plainTextOnly: true)
                                .frame(width: 44, height: 36)
                        }
                }
        }
    }
}

private struct RecognitionJSONText: UIViewRepresentable {
    let text: String
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 15
    @Environment(\.openURL) private var openURL
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false; view.isSelectable = true; view.isScrollEnabled = true
        view.dataDetectorTypes = []; view.backgroundColor = .clear
        view.delegate = context.coordinator
        view.linkTextAttributes = [.foregroundColor: UIColor.tintColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        // SwiftUI owns the scale, including per-view accessibility settings.
        view.adjustsFontForContentSizeCategory = false
        view.accessibilityIdentifier = "modelJSONText"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.value = self
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let content = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.label])
        RecognitionWebText.addLinks(to: content)
        if !view.attributedText.isEqual(to: content) {
            let changedText = view.text != text
            view.attributedText = content
            if changedText { view.setContentOffset(.zero, animated: false) }
        }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var value: RecognitionJSONText
        init(_ value: RecognitionJSONText) { self.value = value }
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content, RecognitionWebURL.parse(url.absoluteString) != nil else { return nil }
            return UIAction { [weak self] _ in self?.value.openURL(url) }
        }
        func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
            nil // No web preview or implicit external action while reading/selecting JSON.
        }
    }
}

/// A barcode is a whole value: payloads containing prose, numbers or other schemes stay plain.
struct RecognitionBarcodeValue: View {
    let text: String
    @Environment(\.openURL) private var openURL
    var body: some View {
        if let url = RecognitionWebURL.parse(text) {
            Button { openURL(url) } label: {
                Text(verbatim: text).font(.body.monospacedDigit()).underline()
                    .foregroundStyle(Color.accentColor)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityRemoveTraits(.isButton)
            .accessibilityAddTraits(.isLink)
            .accessibilityLabel(text)
            .accessibilityHint("在預設瀏覽器開啟網址")
            .contextMenu {
                Button("複製網址", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
            }
        } else {
            Text(verbatim: text).font(.body.monospacedDigit())
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
}

/// Link styling changes presentation only; selected/shared text remains byte-for-byte source text.
struct RecognitionWebText: View {
    let text: String
    @Environment(\.openURL) private var openURL
    var body: some View {
        Text(Self.content(text))
            .environment(\.openURL, OpenURLAction { url in
                guard RecognitionWebURL.parse(url.absoluteString) != nil else { return .discarded }
                openURL(url)
                return .handled
            })
    }
    static func content(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        for match in RecognitionWebURL.matches(in: text) {
            guard let sourceRange = Range(match.range, in: text),
                  let range = Range(sourceRange, in: result) else { continue }
            result[range].link = match.url
        }
        return result
    }
    static func addLinks(to text: NSMutableAttributedString) {
        for match in RecognitionWebURL.matches(in: text.string) {
            text.addAttributes([.link: match.url, .underlineStyle: NSUnderlineStyle.single.rawValue], range: match.range)
        }
    }
}

/// One readable text run gives both providers identical type and natural wrapping.
struct RecognitionReferenceLabel: View {
    let text: String

    var body: some View {
        Text(text).font(.body)
            // List's automatic Link style can use primary text color.
            // Keep both external references in the app's adaptive accent color.
            .foregroundStyle(Color.accentColor)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
    }
}

/// The delegate reports selection before dismissal, so cancellation and asynchronous
/// iCloud delivery cannot be confused by SwiftUI binding callback ordering.
private struct SinglePhotoPicker: UIViewControllerRepresentable {
    let selected: (NSItemProvider?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(selected: selected) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images; configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    @MainActor final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let selected: (NSItemProvider?) -> Void
        private var delivered = false
        init(selected: @escaping (NSItemProvider?) -> Void) { self.selected = selected }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !delivered else { return }; delivered = true
            selected(results.first?.itemProvider)
        }
    }
}


/// One text storage per saved card lets native selection cross paragraph styles.
/// External search links stay in the row and retain their existing URL actions.
struct RecognitionSelectableText: UIViewRepresentable {
    let result: RecognitionResult
    let recordID: UUID
    let sequence: Int
    @Binding var originalExpanded: Bool
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    static let disclosureURL = URL(string: "glance-text-control://original")!
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> RecognitionTextView {
        let view = RecognitionTextView()
        view.backgroundColor = .clear
        view.isEditable = false; view.isSelectable = true; view.isScrollEnabled = false
        view.dataDetectorTypes = []
        view.textContainerInset = .zero; view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        view.linkTextAttributes = [.foregroundColor: UIColor.tintColor]
        return view
    }
    func updateUIView(_ view: RecognitionTextView, context: Context) {
        context.coordinator.value = self
        let changedCard = view.recordID != recordID
        let content = Self.content(result: result, expanded: originalExpanded, traits: view.traitCollection)
        // SwiftUI state/Timeline updates must not reset an in-progress selection.
        if !view.attributedText.isEqual(to: content) {
            let selected = view.selectedRange
            view.attributedText = content
            if !changedCard, selected.location <= content.length {
                view.selectedRange = NSRange(location: selected.location, length: min(selected.length, content.length - selected.location))
            }
            view.invalidateIntrinsicContentSize()
        }
        if changedCard { view.selectedRange = NSRange(location: 0, length: 0); view.resignFirstResponder() }
        view.recordID = recordID
        view.originalExpanded = originalExpanded
        view.onToggleOriginal = { [weak coordinator = context.coordinator] in coordinator?.value.originalExpanded.toggle() }
        view.setNeedsLayout()
        view.accessibilityIdentifier = "archiveText-\(sequence)"
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: RecognitionTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }
    static func content(result: RecognitionResult, expanded: Bool, traits: UITraitCollection) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        func append(_ text: String, style: UIFont.TextStyle = .body, disclosure: Bool = false, secondary: Bool = false, gapBefore: CGFloat = 10) {
            guard !text.isEmpty else { return }
            if output.length > 0 {
                // Match the former VStack's block spacing; newlines inside one
                // names/summary/original block retain the ordinary line height.
                let last = (output.string as NSString).paragraphRange(for: NSRange(location: output.length - 1, length: 0))
                let previous = (output.attribute(.paragraphStyle, at: last.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                previous.paragraphSpacing = gapBefore
                output.addAttribute(.paragraphStyle, value: previous, range: last)
                var separator = output.attributes(at: output.length - 1, effectiveRange: nil)
                separator.removeValue(forKey: .link)
                separator.removeValue(forKey: .underlineStyle)
                output.append(NSAttributedString(string: "\n", attributes: separator))
            }
            let paragraph = NSMutableParagraphStyle()
            if disclosure { paragraph.tailIndent = -44 }
            var attributes: [NSAttributedString.Key: Any] = [.font: UIFont.preferredFont(forTextStyle: style, compatibleWith: traits),
                .foregroundColor: secondary ? UIColor.secondaryLabel : UIColor.label, .paragraphStyle: paragraph]
            if disclosure { attributes[.link] = disclosureURL }
            let block = NSMutableAttributedString(string: text, attributes: attributes)
            if !disclosure { RecognitionWebText.addLinks(to: block) }
            output.append(block)
        }
        append(result.names.joined(separator: "\n"), style: .headline)
        append(result.summary)
        if !result.text.isEmpty {
            // Keep the heading itself in the same selection range as the body.
            append("原文", disclosure: true)
            if expanded { append(result.text.joined(separator: "\n"), gapBefore: 0) }
        }
        if result.lines.isEmpty { append("沒有可辨識的內容。", secondary: true) }
        return output
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var value: RecognitionSelectableText
        init(_ value: RecognitionSelectableText) { self.value = value }
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content else { return nil }
            if url == RecognitionSelectableText.disclosureURL {
                return UIAction { [weak self] _ in self?.value.originalExpanded.toggle() }
            }
            guard RecognitionWebURL.parse(url.absoluteString) != nil else { return nil }
            return UIAction { [weak self] _ in self?.value.openURL(url) }
        }
        func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
            nil // Keep selection/copy local; do not request a link preview.
        }
    }
}

final class RecognitionTextView: UITextView {
    var recordID: UUID?
    var originalExpanded = false
    var onToggleOriginal: (() -> Void)?
    private let originalChevron = UIButton(type: .system)

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        // The title remains the accessible action and part of the text selection.
        // This is the former disclosure arrow's visual/touch target, not text.
        originalChevron.isAccessibilityElement = false
        originalChevron.tintColor = .label
        originalChevron.contentHorizontalAlignment = .right
        originalChevron.addTarget(self, action: #selector(toggleOriginal), for: .touchUpInside)
        addSubview(originalChevron)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func toggleOriginal() { onToggleOriginal?() }

    override func layoutSubviews() {
        super.layoutSubviews()
        var heading: NSRange?
        textStorage.enumerateAttribute(.link, in: NSRange(location: 0, length: textStorage.length)) { value, range, stop in
            if value as? URL == RecognitionSelectableText.disclosureURL { heading = range; stop.pointee = true }
        }
        guard let heading, let start = position(from: beginningOfDocument, offset: heading.location),
              let end = position(from: start, offset: heading.length), let range = textRange(from: start, to: end) else {
            originalChevron.isHidden = true; return
        }
        let rect = firstRect(for: range)
        guard !rect.isNull, rect.height > 0 else { originalChevron.isHidden = true; return }
        originalChevron.isHidden = false
        let points = UIFontMetrics(forTextStyle: .body).scaledValue(for: 11, compatibleWith: traitCollection)
        originalChevron.setImage(UIImage(systemName: originalExpanded ? "chevron.down" : "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: points, weight: .semibold)), for: .normal)
        originalChevron.frame = CGRect(x: bounds.width - 44, y: rect.midY - max(24, rect.height) / 2, width: 44, height: max(24, rect.height))
    }

    var originalChevronFrame: CGRect? { originalChevron.isHidden ? nil : originalChevron.frame }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // Read-only UIKit text normally omits Select All after a long press.
        // Expose it for this card's text storage without selecting adjacent cards.
        if action == #selector(selectAll(_:)) {
            return isSelectable && textStorage.length > 0 && selectedRange.length < textStorage.length
        }
        return super.canPerformAction(action, withSender: sender)
    }
    override func copy(_ sender: Any?) {
        guard selectedRange.length > 0, NSMaxRange(selectedRange) <= textStorage.length else { return }
        let selected = NSMutableAttributedString(attributedString: textStorage.attributedSubstring(from: selectedRange))
        // The disclosure is a local control, never an exported external link.
        selected.enumerateAttribute(.link, in: NSRange(location: 0, length: selected.length)) { value, range, _ in
            if value as? URL == RecognitionSelectableText.disclosureURL { selected.removeAttribute(.link, range: range) }
        }
        var representations: [String: Any] = [UTType.utf8PlainText.identifier: selected.string]
        if let rtf = try? selected.data(from: NSRange(location: 0, length: selected.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            representations[UTType.rtf.identifier] = rtf
        }
        UIPasteboard.general.items = [representations]
    }
}

/// One fixed action position; only an explicit menu selection starts a new image attempt.
struct RecognitionRetryActionButton: View {
    let state: SingleCaptureController.CardRecognitionAction
    let appearance: RecognitionCardActionAppearance
    let sequence: Int
    let retryEnabled: Bool
    let continueEnabled: Bool
    let missingImageReason: String?
    let onRetry: () -> Void
    let onContinue: () -> Void
    private var enabled: Bool {
        switch state { case .working: false; case .continueSecondStage: continueEnabled; case .fullImage: retryEnabled }
    }
    private var label: String {
        switch state { case .working: "辨識處理中"; case .continueSecondStage: "繼續第二階段"; case .fullImage: "重新辨識這張圖片" }
    }
    private var hint: String {
        switch state {
        case .working: "請等候這次辨識完成，無法重複送出。"
        case .continueSecondStage: "第二階段尚未完成，點此繼續；長按可選擇重新辨識整張。"
        case .fullImage: missingImageReason ?? "使用這筆紀錄的原圖，從第一階段重新辨識。"
        }
    }
    var body: some View {
        Button {
            if state == .continueSecondStage { onContinue() }
            else if state == .fullImage { onRetry() }
        } label: {
            Group {
                if state == .working { ProgressView().tint(.secondary) }
                else if state == .continueSecondStage {
                    Image(systemName: "arrow.clockwise")
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: appearance.pointSize * 0.65, weight: .bold))
                                .symbolRenderingMode(.palette).foregroundStyle(.white, .blue)
                                .offset(x: 7, y: -5)
                        }
                } else { Image(systemName: "arrow.clockwise") }
            }.modifier(RecognitionCardActionLabel(appearance: appearance, enabled: enabled))
        }
        .buttonStyle(RecognitionCardActionButtonStyle())
        .disabled(!enabled)
        .accessibilityLabel(label).accessibilityHint(hint).help(hint)
        .accessibilityIdentifier("refreshRecognition-\(sequence)")
        .contextMenu {
            if state != .working {
                Button("重新辨識整張", systemImage: "arrow.clockwise") { onRetry() }
                    .disabled(!retryEnabled)
                    .accessibilityIdentifier("recognizeWholeImage-\(sequence)")
            }
        }
    }
}

import SwiftUI

@MainActor @Observable final class DataConsentController {
    static let shared = DataConsentController()
    private(set) var record = DataConsent()
    private(set) var error: String?
    private(set) var epoch = UUID()
    private let save: (DataConsent) throws -> Void
    var allowsTransfer: Bool { error == nil && record.allowsTransfer }
    init(load: () throws -> DataConsent = {
        guard let data = UserDefaults.standard.data(forKey: "glance.dataConsent") else { return DataConsent() }
        return try JSONDecoder().decode(DataConsent.self, from: data)
    }, save: @escaping (DataConsent) throws -> Void = {
        let data = try JSONEncoder().encode($0)
        UserDefaults.standard.set(data, forKey: "glance.dataConsent")
        guard UserDefaults.standard.data(forKey: "glance.dataConsent") == data else { throw CocoaError(.fileWriteUnknown) }
    }) {
        self.save = save
        do { record = try load() } catch { self.error = "無法讀取同意紀錄；請重新確認說明。" }
    }
    @discardableResult func accept(accountReady: Bool) -> Bool {
        var next = record; next.accept(accountReady: accountReady)
        do { try save(next); record = next; error = nil; epoch = UUID(); return true }
        catch { self.error = "無法保存同意；尚未開放傳送，請重試。"; return false }
    }
    func accountChanged(ready: Bool) {
        var next = record; next.accountChanged(ready: ready)
        guard next != record else { return }
        do { try save(next); record = next }
        catch { self.error = "無法保存設定狀態；請重試。" }
    }
    func withdraw() {
        record.withdraw(); epoch = UUID()
        do { try save(record); error = nil }
        catch { self.error = "這次已停止傳送，但撤回未能保存；請在關閉 App 前重試。" }
    }
}

struct DataUseExplanation: View {
    var body: some View {
        Group {
            Text("圖片辨識 · OpenAI").font(.headline)
            Text("你按「開始辨識」、重試已保存圖片，或選好相簿圖片後，Glance 會將該次圖片、辨識指令及必要的條碼文字送到 OpenAI，取得名稱、簡介與畫面文字。")
            Text("初步結果會先顯示；若找到維基百科候選，Glance 會再將第一階段辨識資料（名稱、簡介、畫面文字及搜尋主題）與有限維基百科摘錄送至 OpenAI，核對來源並補充同一張卡。這是額外一次文字 AI 請求，會使用你的帳戶額度；沒有合適候選就不送出，也不自動重試。")
            Text("相簿圖片會縮小，並移除檔案附帶的拍攝位置、時間及相機資訊；相簿原圖不會更動。照片中的人臉、文字等可見內容仍會保留。")
            Link("Apple 說明：照片中的拍攝位置", destination: URL(string: "https://support.apple.com/zh-tw/guide/personal-safety/ips0d7a5df82/web")!)
                .accessibilityIdentifier("photoLocationExplanation")
            Text("圖片上的姓名、證件或病歷等內容也可能送出。目前沒有送圖前的敏感資訊遮蔽，請只選擇你願意傳送的圖片。")
            Text("OpenAI 會依其適用政策與帳戶設定處理和保存資料。Glance 無法保證特定保存期限，或資料不會用於訓練；刪除本機紀錄或登出也不會刪除 OpenAI 已收到的資料。")
            Text("維基百科").font(.headline)
            Text("辨識後，Glance 會自動將經檢查的查詢詞送至中文維基百科，尋找對應條目；沒有合適的查詢詞就不查詢。不會附上圖片、完整原文或用來確認人物的其他文字線索，但網站仍會收到一般網路連線資訊。點選維基百科連結時，會由瀏覽器開啟該條目的網站，並依網站政策處理資料。")
            Text("Google").font(.headline)
            Text("Glance 只在本機產生 Google 搜尋連結，不會自動向 Google 查詢。你點選連結後，瀏覽器才會將連結中的搜尋詞送至 Google；商品搜尋詞可能包含辨識到的商品條碼。瀏覽器與 Google 會依各自的設定及政策處理資料。")
            Text("本機紀錄與分享").font(.headline)
            Text("送出的圖片、辨識文字與參考連結會保存在這台裝置，關閉 App 後仍保留，不會自動重送。可左滑刪除單筆，或在設定清除全部；只會移除 Glance 的本機紀錄與相關快取，不會刪除相簿原圖或已分享的副本。辨識歷史已設定不納入系統備份。")
            Text("只有你操作分享時，內容才會交給所選 App 或對象。AI 辨識和維基百科條目都可能不符合圖片，請先核對圖片、文字與連結再使用或分享。")
            Text("登入你的帳戶").font(.headline)
            Text("同意這份說明後，請登入你自己的 ChatGPT 帳戶，依 OpenAI 官方畫面選擇帳戶並授權；已有可用登入時不必重新登入。可用功能與用量依你的帳戶方案，以及 OpenAI 與 Glance 的支援範圍而定。取消或登入失敗後可手動重試，不會每次回到 App 就自動開啟登入。")
            Text("同意與撤回").font(.headline)
            Text("同意此版本說明後，Glance 才會開放圖片辨識與自動維基百科查詢。同意版本與首次設定狀態會保存在這台裝置；設定中可重看說明、撤回同意或登出帳戶。")
            Text("撤回後會停止新的圖片／文字 AI 傳送及自動維基百科查詢；已送出的資料無法收回。你仍可瀏覽和刪除本機紀錄。資料接收方或用途有重大變動時，會更新說明並再次徵求同意。")
            Text("說明版本 \(DataConsent.currentVersion)").font(.caption).foregroundStyle(.secondary)
        }.fixedSize(horizontal: false, vertical: true)
    }
}

/// The same document and explicit consent action for first use and Settings.
/// Keep the action outside the scrollable text, including at accessibility sizes.
struct DataUseConsentPage: View {
    let consent: DataConsentController
    let onAccept: () -> Void
    let onClose: () -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { DataUseExplanation() }
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .accessibilityIdentifier("consentDocument")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    if let error = consent.error {
                        Text(error).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("consentSaveError")
                    }
                    Button(action: onAccept) {
                        Text("同意並繼續")
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("consentAccept")
                }.padding().background(.bar)
            }
            .navigationTitle("資料傳送說明").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉", action: onClose).accessibilityIdentifier("consentDefer")
                }
            }
        }
    }
}

struct FirstUseView: View {
    let model: SingleCaptureController
    var body: some View {
        if !model.consent.allowsTransfer {
            DataUseConsentPage(consent: model.consent, onAccept: model.acceptDataUse, onClose: model.deferSetup)
                .interactiveDismissDisabled()
        } else {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                        Text("登入後開始使用").font(.title2)
                        Text("請登入你自己的 ChatGPT 帳戶，依 OpenAI 官方畫面選擇帳戶並授權。取消或失敗後可在此重試，不會反覆自動開啟登入。")
                        SIWCAccountActions(model: model.account)
                        if !model.account.status.isEmpty { Text(model.account.status).font(.footnote) }
                    if let error = model.consent.error { Text(error).foregroundStyle(.red) }
                    Button("稍後登入，瀏覽本機紀錄") {
                        model.deferSetup()
                    }.accessibilityIdentifier("consentDefer")
                }.padding()
            }.navigationTitle("開始使用 Glance").navigationBarTitleDisplayMode(.inline)
        }.interactiveDismissDisabled()
        }
    }
}

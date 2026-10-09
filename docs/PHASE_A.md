# A 階段：無帳戶原生 loopback 探針

2026-10-09 本輪已核准 A 階段。先以實體 iPhone 核對連線與鎖定；使用既有簽名，無需登入 OpenAI。所有測試只用合成 state 與 `probe-only` 標記，不會建立 OAuth 權限、接觸帳戶或保存 token。

## 方法與驗收

- 只在 127.0.0.1 綁定臨時 TCP listener，路徑 `/auth/callback`，驗證精確 path、state、marker 及單次消耗。拒絕其他來源的可疑請求；本機頁面無第三方資源。
- 以系統瀏覽器打開本機 `/probe` 頁，分別延遲 2 秒與 45 秒才導向測試 callback。前者驗證短切換，後者檢查一般 app 背景暫停後能否回呼；不借用 debugger 令 app 保持執行，也不申請特殊背景模式。
- 90 秒期限；cancel、timeout、完成均關閉 listener；回前景檢查期限。診斷只記相對時間、生命週期、成功／失敗，不記 request URL、state、硬體識別或個人名稱。
- 使用者遇到信任、Developer Mode、unexpected signing/keychain 或其他安全批准時自行處理，不代點。
- A 通過須實機有回呼與生命週期/取消/逾時證據；僅 simulator、編譯或短延遲通過都不能證明完整 A 或真實 OAuth 可用。B 正式認證仍另有用戶正式同意關卡。

目前裝置已找到唯一實體 iPhone 13 mini；連線与簽名識別只記本地交接。結果完成後更新本頁。公開檔案不含個人裝置名稱／UDID／team ID。

## 本輪實機結果

2026-10-09，實體 iPhone 13 mini / iOS 26.7.1；有線配對、Developer Mode 已開啟。曾因裝置鎖定造成 CoreDevice 12040 / 10003，使用者解鎖後安裝與啟動成功；**這個安裝阻礙已解除**。沿用既有開發簽名，未更動信任或安全設定。

Xcode 27.0 實機建置成功；八項 host 核心測試通過（原六項加上合成 callback 單次接受、錯誤／模糊參數拒絕）。沒有 debugger attach 或特殊背景保活。

| 實驗 | 系統瀏覽器載入本機頁 | app 進背景 | 背景期間 callback | 帶回前景後 callback |
| --- | --- | --- | --- | --- |
| 2 秒延遲 | 1.0 秒 | 0.9 秒 | 報告無接受事件 | 27.7 秒接受，28.1 秒 active |
| 45 秒延遲 | 0.5 秒 | 0.9 秒 | 超過延遲後報告仍無接受事件 | 67.6 秒接受，68.0 秒 active |

時間相對於各輪 probe-started。每輪先從本 app data container 讀出背景中的報告，再用系統工具將既有 app 帶回前景，讀回新報告。未只憑使用者看到測試頁就判定 pass。原始合成事件報告留本地，不含 URL、state、裝置識別或 token；公開保留本表摘要。

**結論：本機 HTTP listener 與合成 callback 驗證可在實機運作，但直接切去系統瀏覽器後，兩輪均須回到 Glance 前景才完成處理。這條自動回呼路徑未通過 A，不能直接進入正式 Pro 登入。** 這是實際觀察；背景暫停是符合觀察的原因推論，尚未測所有系統瀏覽器／OS 組合，不宣稱原生 iPhone 絕對不可行。

尚未實測取消／逾時 UI、長時間完整登入、OIDC、帳戶模型清單、影像辨識或續期。90 秒清理受 iOS 暫停影響，恢復執行後先檢查逾時；不宣稱被暫停時還能定時執行。沒有任何 OpenAI 登入或模型請求。

## 下一步提案（尚未执行）

評估並建立另一個無帳戶探針，使用 Apple `ASWebAuthenticationSession` 的系統認證視窗，沿用相同 127.0.0.1 HTTP listener；檢查宿主生命週期、2 秒／45 秒合成回呼、取消與逾時。Apple SDK 有 nullable callbackURLScheme 介面，但這不等於官方 OpenAI 承諾 iPhone 相容；不可虛構 custom scheme。若出現系統授權提示由使用者決定，不代點。

這項是 A 的下一個具體技術提案，不是 B 正式 OAuth；先確認本地生命週期與合法支援方式，再決定正式登入。官方 Pro 方案授權、模型與會話保留仍待使用者正式操作。

參考：[Apple ASWebAuthenticationSession](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession) 與 Xcode 27 SDK 的 AuthenticationServices/ASWebAuthenticationSession.h。已讀本機官方 header，未把只有 JavaScript 的網頁當成充分說明。

## 重現方式

開啟 Xcode 專案，以自己的既有開發簽名建置安裝，啟動引數：

```sh
xcrun devicectl device process launch --device <device-id> \
  local.peiyu.Glance --loopback-probe --probe-delay=2
xcrun devicectl device copy from --device <device-id> \
  --domain-type appDataContainer --domain-identifier local.peiyu.Glance \
  --source Documents/probe-report.json --destination /tmp/glance-probe-report.json
```

第二輪重啟 app 並改為 `--probe-delay=45`。不要掛 debugger，停留瀏覽器超過指定延遲後先讀報告，再帶回 app 讀第二份，以區分背景成功與恢復前景後才處理。裝置 ID、簽名 team 與私人名稱不得寫進公開 repo。

## A2 實驗設計（同一已核准範圍）

Apple Xcode 27 SDK 的新 Callback 介面只有 customScheme 與需 associated domain 的 HTTPS，沒有 HTTP loopback callback 物件；舊初始化 `callbackURLScheme: nil` 仍可用。A2 不虛構任何 scheme，將系統認證視窗作為 browser，由同一個 127.0.0.1 listener 驗證合成 callback 後關閉視窗。這是待實測的組合，不等於官方 OpenAI 已保證支援。

合成頁面不需帳戶 cookies，採 ephemeral session；不建立 OAuth 權限。只在本 app 前景測試期間避免自動熄屏，結束恢复，不新增背景執行或修改系統安全設定。實測 2 秒／45 秒，另以同一取消路徑在2秒執行取消，及測試專用3秒期限驗證 timeout。出現任何需用戶決定的系統提示即交回，不自行點同意。

A2 狀態：Xcode 實機建置成功，已安裝至同一 iPhone；啟動被 Locked（CoreDevice 10002 / FBSOpenApplicationErrorDomain 7）拒絕。沒有系統認證視窗／callback 結果。目前僅需用戶解鎖一次，不需修改全域自動鎖定。

## A2 實機結果：無帳戶可行性通過

2026-10-09，同一實體 iPhone 13 mini / iOS 26.7.1，Apple 系統認證視窗（ASWebAuthenticationSession、ephemeral、callbackURLScheme nil）搭配同一個 127.0.0.1 HTTP listener。沒有自訂 callback scheme、真 OAuth、帳戶 cookies、debugger attach、背景保活或全域安全設定修改。

| 測試 | 實際事件 | 判定 |
| --- | --- | --- |
| 2 秒延遲 | 1.0 秒 browser-page-loaded；3.1 秒 callback-accepted | 自動完成，未人工回前景 |
| 45 秒延遲 | 0.3 秒 browser-page-loaded；45.3 秒 callback-accepted | 自動完成，未人工回前景 |
| 取消 | callback 延遲45秒；2.0秒 cancelled | 同一取消路徑已觸發 |
| 逾時 | 測試期限3秒、callback延遲45秒；3.0秒 timeout | 同一逾時路徑已觸發 |

以上四輪均無 app-background 事件；這與外部瀏覽器兩輪需回前景的結果不同。取消/逾時由探針參數觸發，沒有模擬手指按系統取消鈕；也未單獨用第二個 socket 檢查 port 關閉。清理路徑已執行，仍不能宣稱完整 OAuth 錯誤恢复驗收。

所有探針已結束，app 回到預設 Mock 畫面，使用者不需要再按測試按鈕或守著手機。未更動全域自動鎖定。測試期間僅本 app 前景避免自動熄屏，已恢復。

**A 的本機無帳戶技術可行性已通過；G0 正式 Pro 授權仍未通過。** 未測官方授權端是否接受此原生組合、實際帳戶模型、圖片請求、身份/權限、refresh 或撤銷。下一關為 B 正式 SIWC 最小驗證，必須清楚告知持續權限及憑證保留，讓使用者在官方頁面自行登入與同意。

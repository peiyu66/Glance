# Build72 續做次數與安全逐輪紀錄

2026-10-28；0.1.0（72）。三項最小修正已完成隔離驗證，指定裝置簽署封裝與驗簽已完成。

## 行為

- 每張卡分開顯示「整圖辨識第 N 次嘗試」及「第二階段第 N 次嘗試」。整圖重試保留時間；第二階段序號限目前整圖 attempt，不把來源查詢或准入輪數稱作 AI 呼叫次數。
- 第二階段顯示尚未送出、送出狀態未確認或已交付傳輸。已交付傳輸不證明遠端收到、完成或計費；舊資料缺送出紀錄顯示未知，不補造資訊。
- `semanticRunHistory` 保留最近 12 個被新輪取代的第二階段安全摘要，目前輪仍在 `semanticReview`。包含 run／attempt ID、輪數、時間、階段、終態、送出證據、錯誤代碼／HTTP status及停止原因。無 token、憑證、請求／回覆全文、來源摘錄或額外圖片。整圖重試也保留先前第二階段摘要；隨原紀錄刪除。
- 舊檔缺歷史欄位仍可讀；超限資料只取最後 12 筆。既有完整 AI JSON 功能不新增複製；摘要只記錄新版本能觀察的輪次，無法恢復舊版覆寫的失敗內容。
- 續做與整圖共用原既有 grant 的 session 可用性流程，序列化 refresh，排隊取消或換帳戶後不送出。遵守原 earliest-refresh 規則；冷啟動模型目錄為空時使用原目錄讀取與可見性篩選。
- prompt、固定模型、schema、候選策略、來源數量及 timeout 不變；每輪最多一次模型請求，沒有自動連續重送，也不啟動新的登入授權。

## 驗證

- 最後核心：725 通過、1 選用私人歷史 fixture 略過（工具總數 726）。未讀私人歷史材料。
- UI／控制器：9/9；最後修改後補驗3/3，涵蓋session控制器、既有生命週期及最大字級兩種次數可視。版號工具7/7。
- 隔離session：測試逾期、0／1／30／59／60／61／3600秒、earliest-refresh有效／過期、並行只更新一次、排隊取消與換帳戶，以及冷啟動目錄與已有目錄的續做。HTTP一律由catch-all URLProtocol假回應或599拒絕，session僅synthetic值與記憶體，fixture移除Keychain實作；未真登入／refresh／AI。
- 故障注入：離線、timeout、transport cancel、HTTP429／503、無效回覆、CancellationError、session資格不足、空來源；核對續做、終態分類、前輪摘要、第一階段不重跑、取消與遲到回覆隔離。
- 有界摘要、整圖重試保留、舊檔缺欄位、刪除／清空與UUID保護均回歸。最大字級以正常捲動顯示完整兩種次數，不縮小動態字級。
- baseline界線：舊續做直接要求token剩餘超過60秒，而整圖使用既有session helper；舊輪資料被覆寫、次數未接UI均由來源確認。這些實作落差不是任何個人案例反覆失敗的已證實根因，實際網路／模型品質仍待後續驗收。

[最大字級兩種次數合成截圖](../images/build72-counts-maximum.png)。

## 重製與限制

`swift test`；`python3 Scripts/prepare-single-capture-checks.py <fixture目錄>` 後，以模擬器執行 `testResume71ControllerLifecycleAndContinuation`、`testSemantic45LifecycleIsolationAndLateReplies`、`testBuild72BothCountsAtMaximumType`。測試版本與合成控制列不是正式App畫面的一部分。

本輪未操作實體裝置，未安裝或啟動App。簽署IPA只供指定裝置本機交付，不發布GitHub Release或App Store。合成驗證不能代替真實帳戶、模型品質或實機生命週期驗收。

## 簽署封裝

來源 `5c4f032120fd3bad005864f84c5dcde464fc3522` 建立0.1.0（72），286份追蹤建置輸入前後雜湊一致。Archive／匯出strict簽章、版本、43個Mach-O區段與UUID一致；沿用既有distribution憑證與entitlements。內嵌profile與已驗證保存副本完全相同，精確兩台指定iPhone、有效至2027-05-03，get-task-allow=false。

IPA SHA-256：`909da4fabd7058d17518b6fb3ea6cc81d01ff689ed2cd9a2d99f2940ac4bb840`。僅本機交付，未安裝／啟動實體裝置。簽署檔、裝置識別及IPA不加入公開Git樹。

# 非 active 狀態與第二階段取消

2026-10-20 唯讀核對 Build60 產品提交 `04f50d340e4357ed6d9a2265f56f2510be0e9b00`。本頁記錄Build60／61的既有行為；Build62已另獲准有限背景完成，目前測試中。

## 何時開始取消

`SingleCaptureView.swift:384` 的 `onChange(scenePhase)` 每次都呼叫 `model.foreground(phase)`。`SingleCaptureController.foreground`（382行）只區分 active 與非 active；inactive 和 background 都在同一分支直接呼叫 closePreview。

呼叫鏈為 foreground → closePreview → stopCamera（預設 cancelEnrichment=true）→ cancelWikipediaLookups → cancelSemanticReviews → cancelSemanticReview。程式收到該狀態變更後就發起取消，沒有 grace period、debounce 或等待幾秒。這是 App 的現有策略，不是系統已經暫停或殺掉 App 的證據。

控制中心等短暫系統覆蓋**若**使 scene 變成 inactive，就會走同一條路；程式沒有區分短暫覆蓋與真正退背景。此輪沒有裝置事件量測，不宣稱每種彈窗都必然發生 phase 改變。分享旗標只保護放大圖片不被關閉，沒有豁免第二階段取消。

## 同步狀態與非同步收尾

`cancelSemanticReview`（759行）先從工作表移除工作、呼叫 `job.task.cancel()`；若該次狀態仍待完成，在同一 MainActor 呼叫中更新記憶體為 cancelled 並記 finishedAt。持久化另開 Task 寫入 archive，不是同一瞬間保證落盤。

第二階段 AI 使用獨立 `SIWCHTTP`。`SIWCController.reviewWikipedia`（SIWCView.swift:457起）的 `withTaskCancellationHandler` 會在取消時排入 MainActor 執行 client.cancelRequests；後者在 SIWCStorageNetwork.swift:254 呼叫 URLSession.invalidateAndCancel。這會取消本機連線／請求，但不保證同一瞬間停止伺服器計算，也不能收回已送資料。晚回結果仍受 cancellation、attempt、runID、同意與帳戶驗證阻擋。

已完成的工作若已移出工作表，不會被這個取消函式重新標成 cancelled。持久化狀態競速另受 archive 的 run／attempt 檢查約束，不能只由某個畫面時間推定網路是否收到了回覆。

## 為何其他 App 可以短暫續行

iOS 提供有限的背景延續機制；離開 active 不等於立刻沒有執行時間。Apple 的 [ScenePhase.inactive](https://developer.apple.com/documentation/swiftui/scenephase/inactive) 與[延長背景執行時間](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)說明相關生命週期及申請方式。

Glance 確實有 `beginBackgroundTask(withName: "SaveRecognitionResult")`：foreground 的非 active 分支先 closePreview，之後才在 busy 時申請；busy 的定義是 `cycle.activeID != nil`（97行），表示第一階段仍忙碌。它保護既有辨識／保存收尾，不會復活或保護剛取消的第二階段。因此即使系統尚可給背景時間，第二階段仍已被 App 主動取消。

## 設計理由的證據界線

既有 Build45 規則盤點寫明停止／背景／撤回／換帳戶／刪除後不套用遲到結果，程式也以同意、帳戶、attempt與runID檢查。這支持「阻止過期結果套用」的目的；未找到說明為何短暫 inactive 也必須立即取消、為何不用背景時間完成補充的獨立決策紀錄。不能把缺少該紀錄補寫成系統必然限制。

使用者已回報不中斷 App 時社子 Wiki 成功，該例完成；舊第183筆的精確取消觸發仍未知。本次唯讀診斷當時沒有改程式；後續已另批准Build62有限背景完成。舊版立即取消的說明不再是62的設計規則，進度見[Build62](../驗證與建置/Build62進度.md)。

# Glance 專案與認證試驗報告

日期：2026-10-09。狀態：個人iPhone原型；A／A2完成，B正式登入、身份／方案權限驗證與帳戶模型目錄通過。合成圖與會話生命週期驗收待完成。

## 專案與已定範圍

Glance 是個人 iPhone 單張辨識原型。live 相機只作本地取景，中央區域穩定約一秒才擷取單張；不做逐格雲端影音。辨識到的物件名稱、OCR文字與條碼代號一起顯示，使用者不選模式；不做商品資料查詢或百科解說。

結果固定畫面下方，移開立即隱藏。再次對準同一目標且有結果才顯示快取；背面視為新目標，不跨面整合。未辨識、等待中、查無一律靜默。請求去重，晚回的A結果不可掛到B。照片不持久保存、不記敏感日誌；耗電、延遲和用量可量測，門檻由實測調整。

原型只使用正式獲准的 OpenAI Pro 方案路徑，不另收費 API、不借用其他app憑證、不透過遠端轉接規避。帳戶目錄已確認gpt-6-luna；reasoning.effort=none與影像輸入仍須實際請求驗證。

## 已交付基線

- 公開 MIT repository：[peiyu66/Glance](https://github.com/peiyu66/Glance)。
- SwiftUI iPhone Mock shell、純Swift辨識狀態核心、兩種無帳戶loopback探針。
- 16項host測試通過；Xcode27實機簽名建置通過。Mock模擬器啟動已核對；實體iPhone已安裝並執行本輪探針。
- ProjectHub正式登錄及本地雙向入口完成；私人治理文件、原始測試日誌、裝置識別、憑證與照片未納入公開repository或本附件。

## A：外部瀏覽器實測

裝置類型為實體iPhone13 mini、iOS26.7.1；沒有debugger或特殊背景保活。

| 測試 | 觀察 | 結論 |
| --- | --- | --- |
| 2秒延遲 | 本機頁於1.0秒載入；背景報告沒有callback；回到Glance後27.7秒才接受 | 外部瀏覽器自動回呼未通過 |
| 45秒延遲 | 本機頁於0.5秒載入；背景報告沒有callback；回到Glance後67.6秒才接受 | 同樣受宿主背景生命週期影響 |

背景暫停是符合結果的原因推論；沒有單憑這兩輪就宣稱所有原生iPhone路徑不可能。裝置曾鎖定造成安裝／啟動阻礙，解鎖後已解除；沒有證據把上述背景回呼延遲全部歸因於自動鎖定。

## A2：Apple系統認證視窗實測

Apple官方SDK的新callback物件提供custom scheme或HTTPS；舊初始化允許callbackURLScheme為nil。探針沒有自行發明scheme，而是由127.0.0.1 HTTP listener處理回呼，Apple系統認證視窗只負責呈現合成本機頁。使用ephemeral session，不需要既有cookies或帳戶。

| 測試 | 實際結果 |
| --- | --- |
| 2秒callback | 3.1秒自動接受；沒有人工切回app |
| 45秒callback | 45.3秒自動接受；沒有人工切回app |
| 取消 | 2.0秒記錄cancelled，同一取消路徑觸發 |
| 逾時 | 測試專用3秒期限於3.0秒記錄timeout |

四輪沒有app-background事件。取消／逾時由測試參數觸發，不是手指操作系統取消鈕；未另外做socket關閉探測。原始合成報告由Glance自身容器讀回，並非只看畫面就判定成功。

**A階段結束時僅無帳戶技術可行性通過；後續正式登入結果見下方B。** 原外部瀏覽器失敗結果保留。所有探針已結束，app回到預設Mock，不需再按按鈕或保持亮屏。沒有修改全域自動鎖定或安全設定。

## B：正式登入與模型目錄

使用者知悉持續權限與本機安全保留後，親自完成官方授權。Glance的實體iPhone回呼、官方token交換、JWKS簽章與身份／scope校驗以及Keychain保存成功，非敏感狀態為authenticated-plan-enabled。使用者讀取模型後，狀態為catalog-loaded，可見模型數7，並確認包含gpt-6-luna。

會話僅在此iPhone的Keychain、解鎖時可讀，不同步iCloud；其他app憑證未讀取。沒有API key或遠端轉接。模型清單成功不等於圖片請求已成功。後續受控圖測試HTTP200後在驗證／解碼停止，未確認完成，詳見末節。

官方Usage頁用於管理方案及額外點數。本機確認勾選只記錄使用者已核對，不是官方要求，也不改動後端設定；已查SIWC文件未提供讀取此開關的公開API。私人帳戶截圖、餘額、tokens與裝置識別不包含在本報告。

## 待完成與後續順序

1. B：兩次合成圖嘗試已停止，受控重試HTTP200但無完成事件；不讀相機或相簿，不繼續自動重送。登入狀態UI已更新，冷啟動會話恢復通過。自然到期refresh及正式撤銷仍需獨立驗收，不以程式碼存在代替實測。
2. C：B全關卡完成後另依核准範圍接相機ROI、穩定度、單張擷取與認回；目前尚未實作。
3. D：個人原型名稱／OCR／條碼、低光／反光、前背景及影像生命週期驗收，量測延遲、耗電與用量。

目前不需重新登入。G0尚未整體通過；尚未做真實相機、自然續期或撤銷實測。這份報告不是上架、商業化、分享或跨面整合計畫。

## 來源與專案文件

- [B正式驗證與限制](https://github.com/peiyu66/Glance/blob/main/docs/PHASE_B.md)
- [完整A／A2實測與限制](https://github.com/peiyu66/Glance/blob/main/docs/PHASE_A.md)
- [後續計畫與任務](https://github.com/peiyu66/Glance/blob/main/docs/NEXT_STEPS.md)
- [OpenAI官方登入流程](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
- [帳戶模型與推論](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
- [方案預覽限制](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)
- [Apple系統認證視窗](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)

本報告只概括本次指定裝置／版本的觀察，未測的項目均保留未確認；官方文件與服務可能更新。

## 合成圖停止與受控重試（2026-10-09）

首次按鈕測試顯示通用「驗證或連線未通過」；舊安全報告只留下stopped，因此無法追溯HTTP、耗時或輸出。沒有把這次標成成功，也不能聲稱未消耗用量。

離線核查確定一個程式問題：Foundation的AsyncSequence.lines略過空白行，原SSE解析器依賴空白行分隔事件；簡單fixture重現後已改成逐位元組保留LF／CRLF／CR分隔，並測Unicode、失敗終止、未完成、非法JSON／UTF8及缺少type。此問題確實存在，但不能直接認定為首次實機停止的唯一根因。

獲准的唯一一次受控重試已執行，沒有重新登入或讀取私圖：

| 驗證 | 實測結果 |
| --- | --- |
| 既有會話 | 安裝新版後冷啟動恢復成功，restoredSessionAtLaunch=true |
| 模型／方案確認 | 7個可見模型，候選存在，planOnlyConfirmed=true |
| 合成圖HTTP | 200；回應驗證／解碼約1576毫秒後停止 |
| 完成／輸出 | 未確認response.completed，沒有保存可驗證的合成圖輸出 |

重試版診斷仍未保留失敗的精細子階段，不能判定是Content-Type或SSE內容。已再補failureStage、contentTypeClass、UTF8／JSON／缺type／大小限制分類；**未再發送模型請求**。G0圖片關卡受阻，無須重登；不能由HTTP200推定推論成功。後續須經明確安排再驗證一次，而不是盲目循環。

安全報告只記階段、HTTP狀態、允許清單內的錯誤碼／參數、耗時、終止事件及合成fixture符合與否。不寫token、帳號、Authorization、base64圖片、模型原始文字或一般回應。正式續期與撤銷未實測，相機未實作。

最後冷啟動核對：2026-10-09 11:21:04 UTC，ready、authenticated=true、planEnabled=true、planOnlyConfirmed=true、restoredSessionAtLaunch=true，request為空。未帶自動登入／推論旗標；目錄數0是新程序尚未重新查詢，不能解讀成模型被撤回。新版已安裝，未額外送圖。16項離線測試及最新實機build通過。

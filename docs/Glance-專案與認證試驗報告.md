# Glance 專案與認證試驗報告

日期：2026-10-09。狀態：個人iPhone原型；A／A2完成，B正式登入、身份／方案權限驗證與帳戶模型目錄通過。合成图gpt-6-luna/none與冷啟動會話恢復已通過；自然續期與撤銷仍待實測。

## 專案與已定範圍

Glance 是個人 iPhone 單張辨識原型。live 相機只作本地取景，中央區域穩定約一秒才擷取單張；不做逐格雲端影音。辨識到的物件名稱、OCR文字與條碼代號一起顯示，使用者不選模式；不做商品資料查詢或百科解說。

結果固定畫面下方，移開立即隱藏。再次對準同一目標且有結果才顯示快取；背面視為新目標，不跨面整合。未辨識、等待中、查無一律靜默。請求去重，晚回的A結果不可掛到B。照片不持久保存、不記敏感日誌；耗電、延遲和用量可量測，門檻由實測調整。

原型只使用正式獲准的 OpenAI Pro 方案路徑，不另收費 API、不借用其他app憑證、不透過遠端轉接規避。帳戶目錄已確認gpt-6-luna；reasoning.effort=none與合成影像輸入已實測成功。

## 已交付基線

- 公開 MIT repository：[peiyu66/Glance](https://github.com/peiyu66/Glance)。
- SwiftUI iPhone Mock shell、純Swift辨識狀態核心、兩種無帳戶loopback探針。
- 17項host測試通過；Xcode27實機簽名建置通過。Mock模擬器啟動已核對；實體iPhone已安裝並執行本輪探針。
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

## B：正式登入、模型與合成圖成功

使用者知悉持續權限與本機保留後親自完成官方授權。實體iPhone的callback、token交換、JWKS簽章、身份／scope驗證與Keychain保存通過，帳戶目錄有7個可見模型並包含gpt-6-luna。會話只存在此iPhone解鎖時可讀的Keychain，不同步iCloud，未讀其他app憑證。

2026-10-09 11:26:47 UTC，同一會話使用gpt-6-luna、reasoning.effort=none、store:false、stream:true完成合成PNG辨識：HTTP200，headers與首筆資料約1.366秒，response.completed與總耗時約2.580秒。結果為：

> A solid red square appears in the upper-left area. Below it, the readable text is “GLANCE 123” in large black letters.

紅色、方形及文字均符合測試圖；沒有讀取相簿或相機。這證明本次帳戶／裝置的官方Pro單圖路徑可用，不證明真實相機與商品／條碼產品驗收。

先前停止原因經分步診斷釐清：程式原先用會略過空白行的Foundation.lines，已改逐byte保留SSE邊界；另有實測回應缺Content-Type，原App因此在標頭階段拒絕有效SSE。放寬缺標頭但仍嚴格要求有效事件及response.completed後成功。較早缺診斷的嘗試不能反推唯一原因，也不宣稱沒有用量。

17項離線測試、實機build通過。新版已安裝；UI標題為「ChatGPT 登入驗證」，保存會話顯示已登入，不要求重按Continue。無自動請求的冷啟動已確認Keychain恢復，之後測試均沿用原會話。手機保留成功結果，不繼續送圖。

## 邊界與後續

官方Usage頁管理方案及額外點數；本機確認勾選只記錄已核對，不改官方設定。私人帳戶截圖、餘額與識別不包含本報告。安全診斷記錄階段、HTTP、分類及分段耗時；明確合成fixture測試可保存短純文字答案，一般回應、token或圖像base64不保存。

自然到期refresh與正式撤銷未實測；仍保留有效會話，不為驗收強制到期或登出。完整生命週期關卡尚未結束。相機、ROI穩定／認回、真實條碼、低光、耗電和產品延遲仍未實作／驗收，C／D須另依核准範圍執行。

使用者目前無需重登、重按圖片測試或更改帳戶設定；此次最小單圖驗證已完成。

## 來源與專案文件

- [B正式驗證與限制](https://github.com/peiyu66/Glance/blob/main/docs/PHASE_B.md)
- [完整A／A2實測與限制](https://github.com/peiyu66/Glance/blob/main/docs/PHASE_A.md)
- [後續計畫與任務](https://github.com/peiyu66/Glance/blob/main/docs/NEXT_STEPS.md)
- [OpenAI官方登入流程](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
- [帳戶模型與推論](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
- [方案預覽限制](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)
- [Apple系統認證視窗](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)

本報告只概括本次指定裝置／版本的觀察，未測的項目均保留未確認；官方文件與服務可能更新。

## 診斷歷史

先前首次通用stopped與一次HTTP200後1.576秒的驗證／解碼停止均保留於專案B文件。新增細診斷後確認缺Content-Type的標頭拒絕，經修正及離線測試後，上方最新合成圖完成。沒有用HTTP200、清單成功或本機編譯替代完成事件。

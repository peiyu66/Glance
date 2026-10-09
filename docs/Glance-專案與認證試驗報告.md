# Glance 專案與認證試驗報告

日期：2026-10-09。狀態：個人 iPhone 原型；無帳戶原生回呼試驗完成，正式 OpenAI Pro 登入尚未執行。

## 專案與已定範圍

Glance 是個人 iPhone 單張辨識原型。live 相機只作本地取景，中央區域穩定約一秒才擷取單張；不做逐格雲端影音。辨識到的物件名稱、OCR文字與條碼代號一起顯示，使用者不選模式；不做商品資料查詢或百科解說。

結果固定畫面下方，移開立即隱藏。再次對準同一目標且有結果才顯示快取；背面視為新目標，不跨面整合。未辨識、等待中、查無一律靜默。請求去重，晚回的A結果不可掛到B。照片不持久保存、不記敏感日誌；耗電、延遲和用量可量測，門檻由實測調整。

原型只使用正式獲准的 OpenAI Pro 方案路徑，不另收費 API、不借用其他app憑證、不透過遠端轉接規避。候選 gpt-6-luna、reasoning.effort=none 仍須在正式登入後核對帳戶可用模型和能力。

## 已交付基線

- 公開 MIT repository：[peiyu66/Glance](https://github.com/peiyu66/Glance)。
- SwiftUI iPhone Mock shell、純Swift辨識狀態核心、兩種無帳戶loopback探針。
- 八項host核心測試通過；Xcode27實機簽名建置通過。Mock模擬器啟動已核對；實體iPhone已安裝並執行本輪探針。
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

**A的無帳戶技術可行性已通過；正式Pro授權關卡仍未通過。** 原外部瀏覽器失敗結果保留。所有探針已結束，app回到預設Mock，不需再按按鈕或保持亮屏。沒有修改全域自動鎖定或安全設定。

## 尚未驗證

未啟動真實OAuth、未輸入或儲存憑證、未查帳戶模型、未做真實圖片辨識、refresh或撤銷。無帳戶探針不能證明官方授權端接受這個原生整合，也不能证明Pro帳戶可用指定模型。真實相機、影像穩定度與認回、完整UI互動、耗電／延遲／用量均留待後續。

## 後續順序與使用者關卡

1. **B：正式SIWC最小驗證。** 先準備可審閱的註冊、PKCE/state/nonce、身份驗證、授予scope與Keychain會話方案。需要正式持續權限時由使用者在官方頁面親自登入及同意；不得自動接受。驗收真實callback、身份/權限、帳戶模型目錄、一張非敏感合成圖片、續期與撤銷處理。B未通過就停止整套相機app開發。
2. **C：本地相機與目標判定。** B通過後另依核准範圍接ROI穩定度、單張擷取、認回與去重；驗收A→B、背面、移開、晚回及低光。相機權限由使用者授予。
3. **D：個人原型驗收。** 檢查名稱／文字／條碼同時顯示、下方結果區、靜默空結果、前背景切換與照片生命週期，量測延遲、耗電與用量後調門檻。

目前最小下一步是決定進入B，並在正式權限頁親自操作；本輪未進入B。這份報告不是上架、商業化、商品百科、分享或跨面整合計畫。

## 來源與專案文件

- [完整A／A2實測與限制](https://github.com/peiyu66/Glance/blob/main/docs/PHASE_A.md)
- [後續計畫與任務](https://github.com/peiyu66/Glance/blob/main/docs/NEXT_STEPS.md)
- [OpenAI官方登入流程](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
- [帳戶模型與推論](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
- [方案預覽限制](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)
- [Apple系統認證視窗](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)

本報告只概括本次指定裝置／版本的觀察，未測的項目均保留未確認；官方文件與服務可能更新。

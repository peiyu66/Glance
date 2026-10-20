# B 正式 SIWC 最小驗證

後續更新（2026-10-09）：C已實作相機，並實測自然refresh成功一次；撤銷仍未測。下文為B階段時間點的證據，現况以[Phase C](PHASE_C.md)與[合併報告](Glance-專案與認證試驗報告.md)為準。


2026-10-09。使用者在知悉持續權限與本機Keychain保留後，已親自完成正式授權。實體iPhone上的官方回呼、token交換、JWKS簽章與claims／scope校驗、Keychain保存，以及帳戶模型目錄均通過。同一會話的gpt-6-luna/none合成圖片已成功；冷啟動保留會話通過。自然續期與正式撤銷仍未實測，完整生命週期關卡尚未完成；相機未實作。

## 最新結果（先讀本節）

2026-10-09 11:26:47 UTC，官方圖片請求HTTP200，收到response.completed；headers與first-data均1366ms，terminal與總耗時2580ms。仍使用先前會話，沒有重新OAuth。目錄7個可見模型且含gpt-6-luna，實際body使用reasoning.effort=none、store:false、stream:true與程式生成PNG。

合成圖輸出：A solid red square appears in the upper-left area. Below it, the readable text is “GLANCE 123” in large black letters.

紅色、方形及文字檢查皆通過。此結果只驗證合成圖片模型路徑，不證明live相機、實際商品或條碼。

### 已確認根因與修正

- 離線確認Foundation.lines會略過SSE空行，已改逐byte解析並覆蓋LF／CRLF／CR、Unicode與終止事件。
- 細診斷實測官方回應沒有Content-Type，HTTP200且首段是SSE。此前App的強制標頭檢查在response-headers階段拒絕回應；headers1432ms、first-data1433ms。這是該次受控失敗的確定原因，不能倒推所有更早嘗試的唯一根因。
- 對缺標頭容許進入嚴格SSE解析，仍拒絕不相容的明示類型、無效事件、失敗／未完成及沒有response.completed的回應。修正後用同一模型與方案成功，未改付費方式。

### 已完成與未完成

17項離線測試及最新實機build通過，新版已安裝；UI改「ChatGPT 登入驗證」，已有會話顯示已登入，不再要求Continue。冷啟動自身狀態ready且authenticated/restoredSessionAtLaunch均true，無自動請求；模型目錄於需要時重新讀取。

安全診斷包含階段、HTTP、安全分類、header／first-data／terminal時間；此明確啟用的合成fixture可保存4096 bytes內的純文字答案供驗證，一般回應、帳戶、token／header、圖片base64不保存。沒有API可由本機勾選直接更改官方credits設定；既有官方點數停用核對仍有效，未改帳戶設定。

自然refresh與正式撤銷尚未實測，未把編譯或程式碼存在当成驗收。後面保留診斷歷史；其中stopped／尚未完成描述是當時狀態，以上成功結果取代圖片關卡的受阻結論。

## 官方規格（本輪重新讀取）

- [登入](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)：首次 `dynamic_agent_client`，穩定host ID、名稱Glance；系統認證視窗、PKCE S256、state/nonce、HTTP127.0.0.1回呼。新授權回傳issued client ID，不能拿dynamic_agent_client交換token。
- [會話](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)：每帳戶／client隔離；近到期序列化refresh，輪替後存最新token。登出以discovery的revocation_endpoint撤銷refresh token，再清本機；遠端未確認須明示。
- [token](https://developers.openai.com/siwc/token-sharing-open-source/token-reference)：保存expires_in、earliest_refresh_at；refresh省略scope，不擴權。
- [模型與推論](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)、[限制](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)：GET /v1/models帳戶目錄，POST /v1/responses；store:false、stream:true、input陣列，無background、max_output_tokens、previous_response_id等不支援欄位。
- 公開discovery/JWKS唯讀核對：issuer https://auth.openai.com；支援ID-token算法RS256。使用Apple Security驗RSA簽章，驗issuer/audience/expiry/iat/nonce/sub；任何不符即停止。

## 準備範圍與邊界

只實作最小SIWC驗證頁、loopback listener、請求建構、嚴格身份驗證、Glance專用Keychain帳戶記錄、序列化續期、模型清單、合成PNG與SSE完成檢查。所有正式請求只由用戶在頁面明確操作觸發；啟動app不自動註冊、登入或推論。不讀其他app token，不設API key欄位。

scope：openid、profile、email（身份）；offline_access（重啟後續期）；resource.invoke、chatgpt.tokens.use.direct（用ChatGPT方案呼叫模型）。

保存：本機Keychain、WhenUnlockedThisDeviceOnly、不同步iCloud，包含host ID、issued client ID、驗證後subject/email、access/refresh/ID token、授予scope、expiry/earliest-refresh及用戶對方案限制的確認。暫時state、nonce、PKCE、code僅留記憶體，完成／取消／逾時清除。無token或完整授權URL寫日誌、檔案、Git、Library。

官方usage設定可允許額外credits，已查文件未提供可據此保證plan-only的請求欄位。正式推論前到 [ChatGPT Settings→Usage](https://chatgpt.com/settings/usage) 確認應用程式超過方案上限後使用點數已停用，再在本機記錄確認；此勾選不是API驗證或官方設定操作。遇方案／模型／scope錯誤停止，不重試另一付費方式。

## 首次交接點

準備完成後請使用者在Glance「正式SIWC驗證」頁，先讀權限與本機保留說明，再親自按 Continue with ChatGPT。此動作才開始初次dynamic registration並開啟官方auth.openai.com登入／同意頁。實際官方頁文案與核准帳戶要當時確認，不預造畫面。由使用者親自輸入、選帳戶、核准或拒絕；代理不得代按。

登入後先顯示帳戶及授予權限，只有用戶按「讀取可用模型」才查目錄；指定gpt-6-luna只在目錄存在時選用，reasoning.effort=none的實際支援仍由最小測試驗證。第一次僅發程式畫的幾何圖與測試文字，不讀照片或相機。

撤銷：Glance登出先嘗試官方refresh token撤銷，再清本機tokens；失敗明示，使用者可在ChatGPT設定斷開Glance。保留非秘密帳戶/client映射與host ID供同一註冊重驗，不每次新建client。失效／撤銷／終止refresh錯誤才要求重登，暫時網路錯誤不清會話或默默重登。

## 本輪驗收範圍

17項host測試涵蓋原辨識狀態、合成回呼、PKCE向量、state/client/replay/到期拒絕、JWT簽章及claims、scope、模型與Responses欄位、SSE必須完成。編譯和mock不代表相機驗收。

已實測正式登入、Keychain寫入與模型目錄；圖片推論、冷啟動恢復、自然到期refresh與正式撤銷分別記錄，不因前項成功推定後項。使用者已授權在首次停止後安裝修正版和一次受控重試，結果見末節。正式登入成功後不應再次點Continue；新介面以「已登入ChatGPT」表示保存會話。

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

最後冷啟動核對：2026-10-09 11:21:04 UTC，ready、authenticated=true、planEnabled=true、planOnlyConfirmed=true、restoredSessionAtLaunch=true，request為空。未帶自動登入／推論旗標；目錄數0是新程序尚未重新查詢，不能解讀成模型被撤回。新版已安裝，未額外送圖。17項離線測試及最新實機build通過。

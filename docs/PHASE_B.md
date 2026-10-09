# B 正式 SIWC 最小驗證

2026-10-09。使用者在知悉持續權限與本機Keychain保留後，已親自完成正式授權。實體iPhone上的官方回呼、token交換、JWKS簽章與claims／scope校驗、Keychain保存，以及帳戶模型目錄均通過。單張合成圖片與會話生命週期尚未完成全部驗收；G0仍未整體通過。相機未實作。

## 實際證據與限制

- Glance自己的非敏感狀態先為`awaiting-user-in-official-window`且未登入，再為`authenticated-plan-enabled`。後者僅在官方token交換、簽章／claims驗證與Keychain寫入成功後產生，不是A2 mock。
- 帳戶模型請求回報`catalog-loaded`，可見模型數7；使用者看到gpt-6-luna。清單成功不證明該模型的影像輸入或none參數已可用。
- 最新受控圖測試已stopped，HTTP200後驗證／解碼失敗；冷啟動恢復已通過，詳見末節。自然到期refresh與正式撤銷未實測，不重登或撤銷現有會話。
- 16項host測試通過；最新實機簽名建置通過。已登入提示及用量說明修正已安裝，既有會話恢復成功；更細診斷修正不增加推論請求。
- 本機確認勾選由Glance自行加入，不是官方要求，也不會更改官方計費設定。官方文件指向Usage頁管理app方案與credits；已查SIWC文件未提供讀取該開關的公開API。只保留驗證結論，帳戶設定截圖、餘額與私人識別不入公開檔案。

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

16項host測試涵蓋原辨識狀態、合成回呼、PKCE向量、state/client/replay/到期拒絕、JWT簽章及claims、scope、模型與Responses欄位、SSE必須完成。編譯和mock不代表相機驗收。

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

最後冷啟動核對：2026-10-09 11:21:04 UTC，ready、authenticated=true、planEnabled=true、planOnlyConfirmed=true、restoredSessionAtLaunch=true，request為空。未帶自動登入／推論旗標；目錄數0是新程序尚未重新查詢，不能解讀成模型被撤回。新版已安裝，未額外送圖。16項離線測試及最新實機build通過。

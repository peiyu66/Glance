# 模擬器示意截圖

2026-10-27，Build70 實際 SwiftUI 介面，iOS Simulator，原尺寸 1260 × 2736。茶品圖片、文字、page ID 與引用片段都是固定合成資料，不是相機實拍或 AI／Wikipedia 實測結果。沒有帳號或私人紀錄。

| 畫面 | 原圖 |
| --- | --- |
| 明確標示鏡頭預覽區 | [preview.png](preview.png) |
| 歷史卡片、中文示意簡介與日文來源 | [history.png](history.png) |
| 已保存的第一階段 AI JSON | [json.png](json.png) |
| 付費帳戶與方案使用權限要求 | [settings.png](settings.png) |

## 重製

```sh
python3 Scripts/prepare-github-screenshots.py /tmp/glance-readme-fixture
```

開啟輸出的 `CaptureFixture.xcodeproj`，選擇 iOS Simulator，執行 `CaptureUITests/testReadme70Screenshots`。四張原始截圖保存在 xcresult 附件中，可用 Xcode 或 `xcrun xcresulttool export attachments` 匯出。

截圖 host 先寫完示意歷史再呈現 UI，停用實際相機、帳戶、網路及外部連結開啟。只有隔離工程的合成預覽加上「鏡頭預覽區／模擬器示意 · 未啟用相機」；正式 App 不包含此截圖入口，正常預覽顯示相機畫面。圖片由 XCTest 直接擷取，沒有後製改造介面。

## Build71 續做狀態

另附 `resume71-stopped.png`、`resume71-progress.png`、`resume71-menu.png`、`resume71-completed.png`，來自隔離模擬器 UI 回歸的實際畫面。上方工具列與計數只存在於測試宿主；主卡片與按鈕採用正式來源。資料為合成、沒有模型或相機請求；不是實機驗收。

# AI 指令與契約

當前版本以[完整指令與 schema](../目前AI完整指令與Schema.md)為唯一可讀總表；本輪從 Build62 Swift 核心直接匯出，沒有沿用 Build 45 的過時全文。

| 階段 | 指令 | 回覆 schema | 輸入 |
| --- | --- | --- | --- |
| 圖片辨識 | P20-English-concise-entity-zhTW1 | glance_camera_v17 | 指令＋可用 QR 文字＋JPEG |
| 百科語意核對 | W4-English-central-priority-zhTW1 | glance_wikipedia_review_v2 | input_version 2，僅文字 |

- [機器可讀的實際契約與合成範例](Build62/實際契約.json)
- [匯出程式文字](Build62/產生器.swift.txt)
- [來源與內容雜湊](Build62/來源與雜湊.json)
- [候選蒐集與兩階段設計](../使用與設計/百科候選與兩階段.md)

合成範例使用虛構的「曙光旋脆片／Aurora Swirls」與頁面，未呼叫模型或核實該網址存在。它證明資料形狀及本機解析相容，不是答案品質或 Wikipedia 原文證據。

import Foundation
import Testing
@testable import GlanceCore

@Test func shareIncludesOriginalWithoutTranslationOrTruncation() {
    let original = "雪芙蘭\nCREAM\r\n滋養霜　乳霜＋綿羊油\n日本語：保湿クリーム 🧴 e\u{301}"
    let value = RecognitionResult(names:["藍色乳霜罐","Blue jar"],summary:"這是乳霜罐。",text:[original,"  原樣保留  "],barcodes:["0012345678905"])
    #expect(value.shareText == "藍色乳霜罐\nBlue jar\n\n這是乳霜罐。\n\n【原文】\n\n" + original + "\n  原樣保留  \n\n【條碼】\n\n0012345678905")
}
@Test func shareOmitsAbsentSectionsWithoutInventingOriginal() {
    #expect(RecognitionResult(summary:"只有簡介",text:["", " \n "]).shareText == "只有簡介")
    #expect(RecognitionResult().shareText.isEmpty)
    #expect(RecognitionResult(barcodes:["00001"]).shareText == "【條碼】\n\n00001")
    #expect(RecognitionResult(text:["原文內容"]).shareText == "【原文】\n\n原文內容")
    #expect(RecognitionResult(names:["名稱","簡介"],summary:"內容仍有名稱與簡介。").shareText == "名稱\n簡介\n\n內容仍有名稱與簡介。")
}
@Test func shareKeepsLongMultilingualTextAndLineBreaks() {
    let original = (0..<1200).map { "第\($0)行 日本語が/が 👩🏽‍🔬\tABC-001" }.joined(separator:"\r\n")
    let summary = String(repeating:"繁體中文解說。\n",count:300)
    let value = RecognitionResult(summary:summary,text:[original])
    let expected = summary.trimmingCharacters(in:.whitespacesAndNewlines) + "\n\n【原文】\n\n" + original
    #expect(Array(value.shareText.utf8) == Array(expected.utf8))
}
@Test func selectedHistoryShareRemainsIndependentOfNewResults() {
    let first = RecognitionHistory.Entry(id:.init(),sequence:1,capturedAt:0,completedAt:1,result:.init(names:["第一筆"],summary:"舊答案",text:["旧い原文"]))
    var history = RecognitionHistory(capacity:nil)
    let mutationOutcome1 = (history.insert(first));#expect(mutationOutcome1)
    let selected = history.entries[0], snapshot = selected.result.shareText
    let mutationOutcome2 = (history.insert(.init(id:.init(),sequence:2,capturedAt:2,completedAt:3,result:.init(names:["第二筆"],text:["別の原文"])) ));#expect(mutationOutcome2)
    #expect(selected.result.shareText == snapshot)
    #expect(snapshot == "第一筆\n\n舊答案\n\n【原文】\n\n旧い原文")
    #expect(history.latest?.result.shareText != snapshot)
}

@Test func sourceImagesBoundCountBytesAndNeverReplaceIdentity() {
    let a=UUID(),b=UUID(),c=UUID();var store=RecognitionSourceImages(maximumCount:2,maximumBytes:5)
    let mutationOutcome3 = (store.insert(Data([1,2]),for:a));#expect(mutationOutcome3);let mutationOutcome4 = (store.insert(Data([3,4]),for:b));#expect(mutationOutcome4)
    let mutationOutcome5 = (!store.insert(Data([9]),for:a));#expect(mutationOutcome5);#expect(store.image(for:a) == Data([1,2]))
    let mutationOutcome6 = (store.insert(Data([5,6,7]),for:c));#expect(mutationOutcome6);#expect(store.image(for:a) == nil)
    #expect(store.count == 2 && store.byteCount == 5)
    let mutationOutcome7 = (!store.insert(Data(repeating:0,count:6),for:UUID()));#expect(mutationOutcome7);#expect(store.byteCount == 5)
    let mutationOutcome8 = (!store.insert(Data(),for:UUID()));#expect(mutationOutcome8)
    store.removeAll();#expect(store.count == 0 && store.byteCount == 0 && store.image(for:c) == nil)
}
@Test func sourceCountLimitIsIndependentOfByteLimit() {
    var store=RecognitionSourceImages(maximumCount:1,maximumBytes:100)
    let a=UUID(),b=UUID();store.insert(Data([1]),for:a);store.insert(Data([2]),for:b)
    #expect(store.image(for:a) == nil && store.image(for:b) == Data([2]))
    var disabled=RecognitionSourceImages(maximumCount:0);let mutationOutcome9 = (!disabled.insert(Data([1]),for:a));#expect(mutationOutcome9)
}
@Test func cachedAnswerUsesOriginalSourceNotCurrentFrame() {
    var state=RecognitionState(stableDuration:0)
    let a=state.observe("A",at:0)!,b=state.observe("B",at:1)!
    let resultA=RecognitionResult(names:["A"]).withSourceImage(a.id)
    state.complete(a,result:resultA);state.complete(b,result:RecognitionResult(names:["B"]).withSourceImage(b.id))
    _ = state.observe("B",at:2);#expect(state.visible?.sourceImageID == b.id)
    _ = state.observe("A",at:3);#expect(state.visible?.sourceImageID == a.id)
    #expect(state.visible?.shareText == "A")
}
@Test func historySurvivesImageEvictionWithoutSubstitution() {
    let a=UUID(),b=UUID();var store=RecognitionSourceImages(maximumCount:1)
    let old=RecognitionResult(names:["old"]).withSourceImage(a)
    store.insert(Data([1]),for:a);store.insert(Data([2]),for:b)
    #expect(old.shareText == "old" && store.image(for:old.sourceImageID) == nil)
    #expect(store.image(for:b) == Data([2]))
}
@Test func shareFileKeepsExactBytesUntilFinishAndCrashCleanupIsScoped() throws {
    let base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let scoped=base.appendingPathComponent("GlanceShareSources")
    try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:base) }
    let unrelated=base.appendingPathComponent("research.jpg");try Data([99]).write(to:unrelated)
    let bytes=Data([0xff,0xd8,1,2,3,0xff,0xd9])
    let lease=try RecognitionShareFile(jpeg:bytes,directory:scoped)
    #expect(try Data(contentsOf:lease.url) == bytes)
    lease.finish();lease.finish();#expect(!FileManager.default.fileExists(atPath:lease.url.path))
    let crash=try RecognitionShareFile(jpeg:bytes,directory:scoped)
    RecognitionShareFile.removeOrphans(directory:scoped)
    #expect(!FileManager.default.fileExists(atPath:crash.url.path))
    #expect(try Data(contentsOf:unrelated) == Data([99]))
}

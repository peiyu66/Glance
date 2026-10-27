// Simulator-only introduction fixture. Never compiled into the Glance target.
// All text, page IDs, evidence and images below are invented presentation data.
import SwiftUI

struct ReadmeScreenshotView: View {
    @State private var host = C2FixtureHost(name: "readme70-synthetic")
    @State private var loaded = false
    @State private var prepared = false
    @State private var failure: String?
    var body: some View {
        Group {
            if let failure { Text(failure).accessibilityIdentifier("readmeFailure") }
            else if prepared { SingleCaptureView(model: host.model, motionAllowed: false) }
            else { ProgressView("準備示意資料") }
        }
        .preferredColorScheme(.light)
        .environment(\.dynamicTypeSize, .large)
        .environment(\.openURL, OpenURLAction { _ in .handled })
        .task {
            guard !loaded else { return }; loaded = true
            do { try await seed(); prepared = true } catch { failure = "Screenshot fixture failed: \(error)" }
        }
    }
    @MainActor private func seed() async throws {
        try? FileManager.default.removeItem(at: host.root)
        UserDefaults.standard.set(true, forKey: "glance.showModelJSON")
        let archive = host.model.archive
        let names = ["綠茶", "抹茶"]
        for (index, name) in names.enumerated() {
            let id = UUID(), date = ISO8601DateFormatter().date(from: "2026-10-27T01:41:00Z")!.addingTimeInterval(Double(index)*60)
            let original = index == 1 ? ["抹茶", "MATCHA", "100% GREEN TEA"] : ["綠茶", "GREEN TEA"]
            let summary = index == 1 ? "這是標示為抹茶的茶品包裝。包裝上可見 MATCHA 與 GREEN TEA 等原文。" : "這是標示為綠茶的茶品包裝，可見 GREEN TEA 字樣。"
            let object:[String:Any] = ["schema_version":17,"names":[name],"summary":summary,"text":original,"search_entities":[["id":0,"status":"ready","source_role":"product_label","basis":"text","source_text":original[0],"name":name,"role":"central","related_to":-1,"kind":"product","context_text":original,"relation":"none","aliases":[]]]]
            let raw = String(decoding: try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]),as:UTF8.self)
            let result = try CameraAnswer.parse(raw,expectingStructured:true)
            _ = try await archive.create(id:id,jpeg:Self.image(name:name,subtitle:index == 1 ? "MATCHA" : "GREEN TEA"),capturedAt:date)
            let record = try await archive.complete(id:id,result:result,message:nil,at:date,modelResponse:.capture(raw,sourceImageID:id,attemptID:id,appVersion:"0.1.0",appBuild:"70"))
            if index == 1 {
                let run = UUID(), quote = "抹茶は茶葉を粉末にしたものである。" // Synthetic source passage, not a retrieved quote.
                let source = WikipediaReviewSource(pageID:70001,title:"抹茶",url:URL(string:"https://ja.wikipedia.org/wiki/抹茶")!,fetchedAt:Date(),excerpts:[.init(id:"p0",text:quote)])
                let answer = WikipediaReviewAnswer(decision:.selected,sourceID:source.id,relationship:.same_entity,searchName:"抹茶",summary:"抹茶是將茶葉研磨成細粉的茶類，可用於沖泡飲用。這張示意卡呈現中文簡介與日文維基來源的搭配。",citations:[.init(excerptID:"p0",quote:quote)])
                _ = try await archive.beginSemanticReview(id:id,attemptID:id,runID:run,expectedResult:record.result!)
                _ = try await archive.updateSemanticReview(id:id,attemptID:id,runID:run,state:.reviewing,sources:[source])
                let raw2=String(decoding:try JSONEncoder().encode(answer),as:UTF8.self)
                _ = try await archive.updateSemanticReview(id:id,attemptID:id,runID:run,state:.succeeded,answer:answer,response:.capture(raw2,sourceImageID:id,attemptID:id,appVersion:"0.1.0",appBuild:"70",promptRevision:WikipediaSemanticReview.promptRevision))
            }
        }
        await host.model.bootstrap()
        await host.model.openPreview(explicit: true)
        guard host.model.records.first?.currentSemanticReview?.source?.id == "jawiki:70001" else { throw SIWCError.invalidResponse }
        guard !host.model.capture.session.isRunning, C8NetworkProbe.shared.count == 0, host.calls == 0 else { throw SIWCError.invalidResponse }
    }
    @MainActor static func image(name:String,subtitle:String)->Data {
        UIGraphicsImageRenderer(size:CGSize(width:400,height:400)).image { c in
            UIColor(red:0.94,green:0.94,blue:0.88,alpha:1).setFill();c.fill(CGRect(x:0,y:0,width:400,height:400))
            UIColor(red:0.20,green:0.36,blue:0.25,alpha:1).setFill();UIBezierPath(roundedRect:CGRect(x:90,y:48,width:220,height:304),cornerRadius:12).fill()
            let style=NSMutableParagraphStyle();style.alignment = .center
            (name as NSString).draw(in:CGRect(x:90,y:118,width:220,height:65),withAttributes:[.font:UIFont.systemFont(ofSize:44,weight:.semibold),.foregroundColor:UIColor.white,.paragraphStyle:style])
            (subtitle as NSString).draw(in:CGRect(x:90,y:190,width:220,height:35),withAttributes:[.font:UIFont.systemFont(ofSize:20,weight:.medium),.foregroundColor:UIColor.white,.paragraphStyle:style])
            ("示意圖片" as NSString).draw(in:CGRect(x:90,y:284,width:220,height:25),withAttributes:[.font:UIFont.systemFont(ofSize:16),.foregroundColor:UIColor.white.withAlphaComponent(0.8),.paragraphStyle:style])
        }.jpegData(compressionQuality:0.92)!
    }
}

import SwiftUI

@MainActor @Observable final class CaptureFixtureHost {
    let clock = CaptureFixtureClock()
    var model: CameraController
    var result = "running"
    var shareFixture = ShareFixtureState()
    init() { model = CameraController.captureLimitFixtureModel(clock); model.seedCaptureLimitFixtureAnswer() }
}
@main struct CaptureFixtureApp: App {
    @State private var host = CaptureFixtureHost()
    var body: some Scene {
        WindowGroup {
            VStack {
                if ProcessInfo.processInfo.arguments.contains("--thumbnail-checks") {
                    HStack {
                        Text(host.shareFixture.status).accessibilityIdentifier("thumbnail-status")
                        Button("安排替換") { host.shareFixture.scheduleReplacement() }.accessibilityIdentifier("replace-thumbnail-source")
                    }
                    CameraView(readingFixture:host.shareFixture.reading,model:host.model)
                } else if ProcessInfo.processInfo.arguments.contains("--share-checks") {
                    Text(host.shareFixture.status).accessibilityIdentifier("share-status")
                    CameraView(readingFixture:host.shareFixture.reading,model:host.model)
                } else if ProcessInfo.processInfo.arguments.contains("--focus-checks") {
                    Text(host.result).accessibilityIdentifier("focus-result").task {
                        let checks=await CameraController.runFocusControllerChecks()
                        let passed=checks.values.allSatisfy{$0}
                        let report:[String:Any] = ["passed":passed,"checks":checks,"count":checks.count,"cameraStarted":false,"networkRequests":0,"opticalCalls":CaptureFixtureOpticalCalls.count]
                        let file=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first!.appendingPathComponent("focus-fixture.json")
                        try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:file)
                        host.result=passed ? "passed \(checks.count)" : "FAILED: "+checks.filter{!$0.value}.map(\.key).sorted().joined(separator:",")
                    }
                } else if ProcessInfo.processInfo.arguments.contains("--controller-checks") {
                    Text(host.result).accessibilityIdentifier("fixture-result").task {
                        let checks = await CameraController.runCaptureLimitControllerChecks()
                        let passed = checks.values.allSatisfy{$0}
                        let report:[String:Any] = ["passed":passed,"checks":checks,"count":checks.count,"cameraStarted":false,"networkRequests":0,"opticalCalls":CaptureFixtureOpticalCalls.count,"scope":"Actual controller with injected monotonic clock, capture start/stop counters, camera permission and synthetic provider. No real camera, optical work, Keychain or AI."]
                        let file=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first!.appendingPathComponent("capture-limit-fixture.json")
                        try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:file)
                        host.result = passed ? "passed \(checks.count)" : "FAILED: "+checks.filter{!$0.value}.map(\.key).sorted().joined(separator:",")
                    }
                } else {
                    HStack {
                        Text(host.model.running ? "running" : "paused").accessibilityIdentifier("fixture-running")
                        Button("跳到300秒") { host.clock.now=300;host.model.foreground(.active) }.accessibilityIdentifier("fixture-expire")
                    }.font(.caption)
                    CameraView(model:host.model)
                }
            }.environment(\.dynamicTypeSize,ProcessInfo.processInfo.arguments.contains("--maximum-type") ? .accessibility5 : .large)
        }
    }
}

@MainActor @Observable final class ShareFixtureState {
    var status="ready"
    let reading:SummaryReadingFixtureState
    private let jpeg:Data
    private var file:URL?
    init() {
        let id=UUID()
        let result=RecognitionResult(names:["合成第一筆"],summary:"台灣繁中摘要",text:["日本語 原文\nABC-001 👩🏽‍🔬"],barcodes:["0012345678905"],sourceImageID:id)
        reading=SummaryReadingFixtureState(result);reading.paused=true
        jpeg=UIGraphicsImageRenderer(size:CGSize(width:32,height:24)).image { c in UIColor.blue.setFill();c.fill(CGRect(x:0,y:0,width:32,height:24)) }.jpegData(compressionQuality:0.82)!
        if !ProcessInfo.processInfo.arguments.contains("--missing-source") { reading.sources.insert(jpeg,for:id) }
        reading.records=[.init(id:UUID(),sequence:1,capturedAt:0,completedAt:1,result:result),.init(id:UUID(),sequence:2,capturedAt:2,completedAt:3,result:.init(names:["合成第二筆"],text:["Second original"]))]
        if ProcessInfo.processInfo.arguments.contains("--thumbnail-checks") {
            reading.result = .init(names: result.names, summary: String(repeating:"這是合成長文，用來驗證捲動閱讀時來源縮圖仍固定可用。", count: 35), text: result.text, barcodes: result.barcodes, sourceImageID: id)
            reading.records[0] = .init(id: reading.records[0].id, sequence: 1, capturedAt: 0, completedAt: 1, result: reading.result)
            if ProcessInfo.processInfo.arguments.contains("--pending-preview") {
                reading.pending = .init(id: UUID(), jpeg: Self.redJPEG())
                reading.paused = false
            }
        }
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--copy-checks") { UIPasteboard.general.items=[] }
        #endif
        let expectedText="合成第一筆\n\n台灣繁中摘要\n\n原文\n日本語 原文\nABC-001 👩🏽‍🔬\n\n條碼\n0012345678905"
        let hasImage = !ProcessInfo.processInfo.arguments.contains("--missing-source")
        for probe in [reading.probe,reading.historyProbe.card] {
            if ProcessInfo.processInfo.arguments.contains("--replace-while-enlarged") {
                probe.imagePresented={ [weak self] data in
                    guard let self else { return }
                    guard data == self.jpeg else { self.status="wrong-selected-JPEG";return }
                    self.scheduleReplacement()
                }
            }
            probe.combinedPresented={ [weak self] text,url,count in
                guard let self else { return };self.file=url
                let imageCorrect=hasImage ? url.flatMap { try? Data(contentsOf:$0) } == self.jpeg : url == nil
                self.reading.result = .init(names:["合成第三筆"],text:["New original"])
                self.reading.records.append(.init(id:UUID(),sequence:3,capturedAt:4,completedAt:5,result:self.reading.result))
                self.reading.sources.removeAll();self.reading.records=[]
                self.status=text == expectedText && imageCorrect && count == (hasImage ? 2 : 1) ? "combined-snapshot-ok" : "FAILED-combined-snapshot"
            }
            probe.shareFinished={ [weak self] in
                guard let self else { return }
                let removed=self.file.map { !FileManager.default.fileExists(atPath:$0.path) } ?? true
                self.status=removed && !RecognitionShareSession.shared.active ? "finished-clean" : "FAILED-cleanup"
            }
            probe.activityCompleted={ [weak self] kind,completed in
                #if targetEnvironment(simulator)
                guard let self,ProcessInfo.processInfo.arguments.contains("--copy-checks") else { return }
                let board=UIPasteboard.general
                let textMatches=board.strings?.contains(expectedText) == true
                let expectedImage=UIImage(data:self.jpeg)
                let expectedPixels=expectedImage.flatMap(Self.pixels)
                let imageMatches=hasImage ? board.images?.contains(where:{ image in
                    guard let expectedPixels,let actualPixels=Self.pixels(image),
                          let expectedCG=expectedImage?.cgImage,let actualCG=image.cgImage else { return false }
                    return actualCG.width == expectedCG.width && actualCG.height == expectedCG.height && actualPixels == expectedPixels
                }) == true : (board.images?.isEmpty ?? true)
                let removed=self.file.map { !FileManager.default.fileExists(atPath:$0.path) } ?? true
                let checks=["systemCopyCompleted":completed && kind == UIActivity.ActivityType.copyToPasteboard.rawValue,
                    "completeTextMatches":textMatches,"sourceImagePixelsMatch":imageMatches,
                    "separateItemCount":board.items.count == (hasImage ? 2 : 1),"temporaryFileRemoved":removed]
                let passed=checks.values.allSatisfy{$0}
                let report:[String:Any] = ["passed":passed,"checks":checks,"itemCount":board.items.count,
                    "imageCount":board.images?.count ?? 0,"stringCount":board.strings?.count ?? 0,
                    "itemTypes":board.items.map{Array($0.keys).sorted()},"activityType":kind ?? "none",
                    "hasSourceImage":hasImage,"simulatorOnly":true]
                let file=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first!.appendingPathComponent(hasImage ? "combined-copy-fixture.json" : "text-only-copy-fixture.json")
                try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:file)
                self.status=passed ? (hasImage ? "copy-both-ok" : "copy-text-only-ok") : "FAILED-copy:"+checks.filter{!$0.value}.map(\.key).sorted().joined(separator:",")
                #endif
            }
        }
    }
    private static func redJPEG() -> Data {
        UIGraphicsImageRenderer(size:CGSize(width:32,height:24)).image { c in UIColor.red.setFill();c.fill(CGRect(x:0,y:0,width:32,height:24)) }.jpegData(compressionQuality:0.82)!
    }
    func scheduleReplacement() {
        status="scheduled"
        Task { @MainActor in
            try? await Task.sleep(for:.seconds(4))
            let id=UUID()
            reading.sources.removeAll()
            reading.sources.insert(Self.redJPEG(),for:id)
            reading.result = .init(names:["替換後 B"],summary:"新的完整回覆",sourceImageID:id)
            reading.records.append(.init(id:UUID(),sequence:3,capturedAt:4,completedAt:5,result:reading.result))
            reading.pending=nil
            status="changed"
        }
    }
    #if targetEnvironment(simulator)
    private static func pixels(_ image:UIImage)->Data? {
        guard let cg=image.cgImage else { return nil }
        var bytes=[UInt8](repeating:0,count:cg.width*cg.height*4)
        let ok=bytes.withUnsafeMutableBytes { pointer in
            guard let context=CGContext(data:pointer.baseAddress,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height));return true
        }
        return ok ? Data(bytes) : nil
    }
    #endif
}

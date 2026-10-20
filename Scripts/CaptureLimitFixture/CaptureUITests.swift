import XCTest
@MainActor final class CaptureUITests: XCTestCase {
    private func start(_ flags:[String]=[]) -> XCUIApplication {
        let app=XCUIApplication();app.launchArguments=["--siwc-auth-fixture"]+flags;app.launch();return app
    }
    func testActualControllerLifecycleAndLateReplies() {
        let app=start(["--controller-checks"])
        let result=app.staticTexts["fixture-result"]
        XCTAssertTrue(result.waitForExistence(timeout:15))
        let completed=expectation(for:NSPredicate(format:"label != %@","running"),evaluatedWith:result)
        wait(for:[completed],timeout:20)
        XCTAssertTrue(result.label.hasPrefix("passed "),result.label)
    }
    func testActualFocusPipelineAndTransportBoundary() {
        let app=start(["--focus-checks"])
        let result=app.staticTexts["focus-result"]
        XCTAssertTrue(result.waitForExistence(timeout:15))
        let completed=expectation(for:NSPredicate(format:"label != %@","running"),evaluatedWith:result)
        wait(for:[completed],timeout:20)
        XCTAssertTrue(result.label.hasPrefix("passed "),result.label)
    }
    func testLegacyFalseStartAndManualPauseWithWarning() {
        let app=start()
        let begin=app.buttons["開始取景"];XCTAssertTrue(begin.waitForExistence(timeout:10))
        let warning=app.descendants(matching:.any).matching(identifier:"planUsageWarning").firstMatch
        XCTAssertFalse(warning.exists)
        XCTAssertFalse(app.switches["siwc-plan-only"].exists);XCTAssertTrue(begin.isHittable);begin.tap()
        let pause=app.buttons["暫停"];XCTAssertTrue(pause.waitForExistence(timeout:5));pause.tap()
        XCTAssertTrue(begin.waitForExistence(timeout:5));XCTAssertTrue(begin.isHittable)
        XCTAssertEqual(app.staticTexts["fixture-running"].label,"paused")
        XCTAssertTrue(app.buttons["本次紀錄 1"].exists)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.lifetime = .keepAlways;add(shot)
    }
    func testCombinedShareCollapsedOriginalSnapshot() { checkShare(history:false,copy:false) }
    func testHistoryCombinedShareSnapshot() { checkShare(history:true,copy:false) }
    func testSystemCopyPreservesSeparateImageAndCompleteText() { checkShare(history:false,copy:true) }
    func testHistorySystemCopyPreservesSelectedSnapshot() { checkShare(history:true,copy:true) }
    func testMissingImageSystemCopyUsesOnlyText() { checkShare(history:false,copy:true,missing:true) }
    private func checkShare(history:Bool,copy:Bool,missing:Bool=false) {
        let app=start(["--share-checks"]+(copy ? ["--copy-checks"] : [])+(missing ? ["--missing-source"] : []))
        XCTAssertTrue(app.buttons["shareRecognitionResult"].waitForExistence(timeout:10))
        XCTAssertFalse(app.buttons["shareRecognitionImage"].exists)
        if history {
            app.buttons["sessionHistoryButton"].tap()
            let entry=app.buttons["historyEntry-1"];XCTAssertTrue(entry.waitForExistence(timeout:5));entry.tap()
        }
        XCTAssertFalse(app.staticTexts["名稱"].exists);XCTAssertFalse(app.staticTexts["簡介"].exists)
        XCTAssertTrue(app.staticTexts["合成第一筆"].exists);XCTAssertTrue(app.staticTexts["recognitionSummary"].exists)
        XCTAssertFalse(app.staticTexts["日本語 原文\nABC-001 👩🏽‍🔬"].isHittable)
        let buttons=app.buttons.matching(identifier:"shareRecognitionResult").allElementsBoundByIndex
        guard let share=buttons.first(where:{$0.isHittable}) else { XCTFail(app.debugDescription);return }
        XCTAssertTrue(share.isEnabled);share.tap()
        let status=app.staticTexts["share-status"]
        let ready=expectation(for:NSPredicate(format:"label == %@","combined-snapshot-ok"),evaluatedWith:status);wait(for:[ready],timeout:10)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.lifetime = .keepAlways;add(shot)
        if copy {
            let candidates=["Copy","複製","拷貝","Copy Photo","複製照片","拷貝照片","com.apple.UIKit.activity.CopyToPasteboard"]
            var found:XCUIElement?
            for _ in 0..<3 {
                found=candidates.flatMap{[app.buttons[$0],app.cells[$0],app.staticTexts[$0]]}.first(where:{$0.exists && $0.isHittable})
                if found != nil { break };app.swipeUp()
            }
            guard let found else { XCTFail("System Copy activity unavailable: "+app.debugDescription);return }
            found.tap()
        } else {
            let candidates=["Close","關閉","Cancel","取消","UIActivityContentViewControllerCloseButton"]
            if let close=candidates.map({app.buttons[$0]}).first(where:{$0.exists && $0.isHittable}) { close.tap() }
            else { app.coordinate(withNormalizedOffset:CGVector(dx:0.02,dy:0.15)).tap() }
        }
        let expected=copy ? (missing ? "copy-text-only-ok" : "copy-both-ok") : "finished-clean"
        let done=expectation(for:NSPredicate(format:"label == %@",expected),evaluatedWith:status)
        wait(for:[done],timeout:10);XCTAssertEqual(status.label,expected,app.debugDescription)
    }
    func testCurrentThumbnailStaysFixedAndEnlargedSnapshotSurvivesNewResult() { checkThumbnail(history:false) }
    func testHistoryThumbnailRetainsSelectedImageDuringNewResult() { checkThumbnail(history:true) }
    private func checkThumbnail(history:Bool) {
        let app=start(["--thumbnail-checks","--replace-while-enlarged"])
        let thumb=app.buttons.matching(identifier:"recognitionSourceThumbnail").firstMatch
        XCTAssertTrue(thumb.waitForExistence(timeout:10))
        if history {
            app.buttons["sessionHistoryButton"].tap();app.buttons["historyEntry-1"].tap()
        }
        let selected=app.buttons.matching(identifier:"recognitionSourceThumbnail").allElementsBoundByIndex.first(where:{$0.isHittable})!
        let before=selected.frame
        guard let scroll=app.scrollViews.matching(identifier:"recognitionResult").allElementsBoundByIndex.first(where:{$0.isHittable}) else { XCTFail("Missing selected result scroll view");return }
        scroll.swipeUp()
        XCTAssertTrue(selected.isHittable)
        XCTAssertEqual(selected.frame.minY,before.minY,accuracy:1)
        selected.tap()
        let enlarged=app.images["recognitionSourceEnlarged"]
        XCTAssertTrue(enlarged.waitForExistence(timeout:5));assertColor(enlarged,red:false)
        do {
            let changed=expectation(for:NSPredicate(format:"label == %@","changed"),evaluatedWith:app.staticTexts["thumbnail-status"])
            wait(for:[changed],timeout:10)
            XCTAssertTrue(enlarged.exists);assertColor(enlarged,red:false)
        }
        let shot=XCTAttachment(screenshot:app.screenshot());shot.lifetime = .keepAlways;add(shot)
        app.navigationBars["辨識來源"].buttons["完成"].tap()
        XCTAssertFalse(enlarged.exists)
        if !history { XCTAssertTrue(app.staticTexts["替換後 B"].waitForExistence(timeout:5)) }
    }
    func testPendingThumbnailAndDotsKeepCompletedResultSeparate() {
        let app=start(["--thumbnail-checks","--pending-preview"])
        XCTAssertTrue(app.staticTexts["recognitionWaiting"].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["合成第一筆"].exists)
        XCTAssertEqual(app.buttons.matching(identifier:"shareRecognitionResult").count,1)
        XCTAssertEqual(app.buttons.matching(identifier:"recognitionSourceThumbnail").count,2)
        app.buttons.matching(identifier:"recognitionSourceThumbnail").element(boundBy:0).tap()
        let image=app.images["recognitionSourceEnlarged"]
        XCTAssertTrue(image.waitForExistence(timeout:5));assertColor(image,red:true)
        app.navigationBars["辨識來源"].buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["recognitionWaiting"].exists)
    }
    func testMaximumTypeThumbnailAndShareRemainAvailable() {
        let app=start(["--thumbnail-checks","--maximum-type"])
        XCTAssertTrue(app.buttons["recognitionSourceThumbnail"].waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["recognitionSourceThumbnail"].isHittable)
        XCTAssertTrue(app.buttons["shareRecognitionResult"].isHittable)
    }
    func testBackgroundDismissesCurrentEnlargedImage() { checkBackgroundImage(history:false) }
    func testBackgroundDismissesHistoryEnlargedImage() { checkBackgroundImage(history:true) }
    private func checkBackgroundImage(history:Bool) {
        let app=start(["--thumbnail-checks"])
        XCTAssertTrue(app.buttons["recognitionSourceThumbnail"].waitForExistence(timeout:10))
        if history { app.buttons["sessionHistoryButton"].tap();app.buttons["historyEntry-1"].tap() }
        guard let thumb=app.buttons.matching(identifier:"recognitionSourceThumbnail").allElementsBoundByIndex.first(where:{$0.isHittable}) else { XCTFail("Missing selected thumbnail");return }
        thumb.tap()
        XCTAssertTrue(app.images["recognitionSourceEnlarged"].waitForExistence(timeout:5))
        XCUIDevice.shared.press(.home);app.activate()
        XCTAssertFalse(app.images["recognitionSourceEnlarged"].exists)
    }
    private func assertColor(_ element:XCUIElement,red:Bool,file:StaticString=#filePath,line:UInt=#line) {
        guard let cg=element.screenshot().image.cgImage,
              let pixel=cg.cropping(to:CGRect(x:cg.width/2,y:cg.height/2,width:1,height:1)) else { XCTFail("Missing image pixels",file:file,line:line);return }
        var rgba=[UInt8](repeating:0,count:4)
        let valid=rgba.withUnsafeMutableBytes { data -> Bool in
            guard let c=CGContext(data:data.baseAddress,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            c.draw(pixel,in:CGRect(x:0,y:0,width:1,height:1));return true
        }
        XCTAssertTrue(valid,file:file,line:line)
        XCTAssertTrue(red ? Int(rgba[0]) > Int(rgba[2])+100 : Int(rgba[2]) > Int(rgba[0])+100,"Expected fixed selected source color, got \(rgba)",file:file,line:line)
    }
    func testAutomaticPauseMessageAndPaidCard() { checkVisiblePause(maximum:false) }
    func testMaximumTypeAutomaticPauseMessage() { checkVisiblePause(maximum:true) }
    private func checkVisiblePause(maximum:Bool) {
        let app=start(maximum ? ["--maximum-type"] : [])
        let begin=app.buttons["開始取景"]
        XCTAssertTrue(begin.waitForExistence(timeout:10));begin.tap()
        let running=app.staticTexts["fixture-running"]
        let started=expectation(for:NSPredicate(format:"label == %@","running"),evaluatedWith:running);wait(for:[started],timeout:5)
        app.buttons["fixture-expire"].tap()
        let message=app.staticTexts["captureTimeLimitStatus"]
        XCTAssertTrue(message.waitForExistence(timeout:5));XCTAssertEqual(message.label,"已取景5分鐘，自動暫停")
        XCTAssertTrue(message.isHittable);XCTAssertEqual(running.label,"paused")
        XCTAssertTrue(app.buttons["開始取景"].isHittable)
        XCTAssertTrue(app.buttons["本次紀錄 1"].exists)
        XCTAssertTrue(app.buttons["本次紀錄 1"].isHittable)
        XCTAssertTrue(app.staticTexts["已完成答案 A"].isHittable)
        let screenshot=XCTAttachment(screenshot:app.screenshot());screenshot.lifetime = .keepAlways;add(screenshot)
    }
}

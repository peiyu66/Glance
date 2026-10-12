import XCTest
@MainActor final class ShareUITests:XCTestCase {
    private func start(_ flags:[String]=[]) -> XCUIApplication {
        let app=XCUIApplication();app.launchArguments=flags;app.launch();return app
    }
    func testProductionControllerSourceBindingAndCleanup() {
        let app=start(["--controller-checks"]);let status=app.staticTexts["controller-result"]
        XCTAssertTrue(status.waitForExistence(timeout:10))
        let done=expectation(for:NSPredicate(format:"label != %@","running"),evaluatedWith:status)
        wait(for:[done],timeout:15);XCTAssertEqual(status.label,"passed 10")
    }
    func testExistingReadingLayoutAndHistoryBaseline() {
        let app=start(["--camera-summary-ui-fixture"])
        let status=app.staticTexts["reading-result"]
        let done=expectation(for:NSPredicate(format:"exists == true AND label == %@","passed"),evaluatedWith:status)
        wait(for:[done],timeout:120)
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
}

import XCTest
final class CaptureUITests: XCTestCase {
    @MainActor func testOrdinaryLaunchStaysWaiting() {
        let app = XCUIApplication(); app.launch()
        let status = app.staticTexts["textTrialStatus"]
        XCTAssertTrue(status.waitForExistence(timeout:10))
        #if GLANCE_READINESS_DIAGNOSTIC
        XCTAssertTrue(status.label.contains("一般啟動不會讀取帳戶"))
        XCTAssertTrue(app.staticTexts["Glance 帳戶前檢"].exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format:"label CONTAINS '8,192'")).firstMatch.exists)
        #else
        XCTAssertTrue(status.label.contains("一般啟動不會傳送"))
        #endif
        XCTAssertFalse(app.buttons["stopTextTrial"].exists)
        let attachment = XCTAttachment(screenshot:app.screenshot()); attachment.name = "text-trial-waiting"; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func testBoundedTextTransportMatrix() {
        let app = XCUIApplication(); app.launchArguments = ["--checks"]; app.launch()
        let result = app.staticTexts["fixtureResult"]
        XCTAssertTrue(result.waitForExistence(timeout:10))
        let done = XCTNSPredicateExpectation(predicate:NSPredicate(format:"label BEGINSWITH 'PASS' OR label BEGINSWITH 'FAIL'"),object:result)
        XCTAssertEqual(XCTWaiter.wait(for:[done],timeout:90),.completed); XCTAssertTrue(result.label.hasPrefix("PASS"),result.label)
        let attachment = XCTAttachment(string:result.label); attachment.lifetime = .keepAlways; add(attachment)
    }
}

// Simulator screenshots of actual UI. No link, sign-in or recognition is invoked.
extension CaptureUITests {
    func testReadme70Screenshots() {
        let app=launch(["--readme-screenshots"])
        XCTAssertTrue(app.buttons["modelJSON-2"].waitForExistence(timeout:20),app.debugDescription)
        XCTAssertTrue(app.staticTexts["鏡頭預覽區"].waitForExistence(timeout:10))
        func save(_ name:String) {
            let image=XCTAttachment(screenshot:app.screenshot());image.name=name;image.lifetime = .keepAlways;add(image)
        }
        save("readme70-01-preview")
        let list=historyList(in:app)
        list.swipeUp(velocity:.slow)
        let link=app.links["wikipedia-2"]
        XCTAssertTrue(link.waitForExistence(timeout:5))
        XCTAssertEqual(link.label,"維基百科：抹茶（日文）")
        save("readme70-02-history")
        app.buttons["modelJSON-2"].tap()
        XCTAssertTrue(app.textViews["modelJSONText"].waitForExistence(timeout:5))
        XCTAssertTrue((app.textViews["modelJSONText"].value as? String ?? "").contains("MATCHA"))
        save("readme70-03-json")
        app.buttons["closeModelJSON"].tap()
        app.buttons["設定"].tap()
        XCTAssertTrue(app.staticTexts["siwcPaidRequirement"].waitForExistence(timeout:5))
        XCTAssertFalse(app.staticTexts["siwcAccountSummary"].exists)
        save("readme70-04-settings")
        app.terminate()
    }
}

import XCTest

extension CaptureUITests {
    func testSavedCard152() throws { try replaySavedCard(152) }
    func testSavedCard153() throws { try replaySavedCard(153) }
    func testSavedCard149() throws { try replaySavedCard(149) }
    func testSavedCard147() throws { try replaySavedCard(147) }

    private func replaySavedCard(_ sequence: Int) throws {
        continueAfterFailure = false
        let values = ReplaySamples.values[sequence]!
        let input = try JSONSerialization.jsonObject(with: Data(base64Encoded: values[0])!) as! [String: Any]
        let first = input["stage_one"] as! [String: Any]
        let second = try JSONSerialization.jsonObject(with: Data(base64Encoded: values[1])!) as! [String: Any]
        let source = (input["sources"] as! [[String: Any]]).first { $0["source_id"] as? String == second["source_id"] as? String }!
        let app = XCUIApplication(); app.launchArguments = ["--saved-card=\(sequence)"]; app.launch()
        func wait(_ element: XCUIElement, _ key: String, _ value: String) {
            let e = XCTNSPredicateExpectation(predicate: NSPredicate(format: "%K == %@", key, value), object: element)
            XCTAssertEqual(XCTWaiter.wait(for: [e], timeout: 12), .completed, element.debugDescription)
        }
        func revealReplay(_ element: XCUIElement) {
            let list = app.collectionViews["recognitionArchiveList"]
            for _ in 0..<9 where !element.isHittable {
                if element.exists && element.frame.maxY < list.frame.minY { list.swipeDown() }
                else { list.swipeUp() }
            }
            XCTAssertTrue(element.isHittable, app.debugDescription)
        }
        func setJSON(_ enabled: Bool) {
            app.buttons["設定"].tap()
            let toggle = app.switches["showModelJSON"]
            for _ in 0..<8 {
                if toggle.exists && toggle.isHittable && app.frame.insetBy(dx: 0, dy: 100).contains(CGPoint(x: toggle.frame.midX, y: toggle.frame.midY)) { break }
                app.collectionViews.firstMatch.swipeUp()
            }
            if toggle.value as? String != (enabled ? "1" : "0") { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
            wait(toggle, "value", enabled ? "1" : "0"); app.buttons["完成"].tap()
        }
        func copyShare(_ name: String) {
            let copy = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Copy'")).firstMatch
            XCTAssertTrue(copy.waitForExistence(timeout: 8)); copy.tap()
            wait(app.staticTexts["replay-share"], "label", "copied-" + name)
        }
        func shareCard(_ stage: String) {
            let share = app.otherElements["archiveCard-1"].buttons["shareRecognitionResult"]
            revealReplay(share); share.tap(); copyShare("card-" + stage)
        }
        wait(app.staticTexts["replay-status"], "label", "ready")
        setJSON(true)
        app.buttons["replay-start"].tap()
        wait(app.staticTexts["replay-status"], "label", "first-ready")
        let text = app.textViews["archiveText-1"]
        XCTAssertTrue(text.waitForExistence(timeout: 8))
        XCTAssertTrue((text.value as? String ?? "").contains(first["summary"] as! String))
        XCTAssertFalse(app.links["wikipedia-1"].exists)
        XCTAssertEqual(app.otherElements.matching(identifier: "archiveCard-1").count, 1)
        shareCard("first")
        let jsonButton = app.buttons["modelJSON-1"]; revealReplay(jsonButton); jsonButton.tap()
        XCTAssertTrue(app.textViews["modelJSONText"].waitForExistence(timeout: 5))
        XCTAssertTrue((app.textViews["modelJSONText"].value as? String ?? "").contains("schema_version"))
        app.buttons["shareRecognitionJSON"].tap(); copyShare("json-first")
        app.buttons["closeModelJSON"].tap()
        let before = XCTAttachment(screenshot: app.screenshot()); before.name = "actual-\(sequence)-first-stage"; before.lifetime = .keepAlways; add(before)
        app.buttons["replay-finish"].tap()
        wait(app.staticTexts["replay-status"], "label", "second-ready")
        XCTAssertTrue((text.value as? String ?? "").contains(second["summary"] as! String))
        XCTAssertEqual(app.otherElements.matching(identifier: "archiveCard-1").count, 1)
        for (identifier, expected) in [("googleSearch-1", ""), ("wikipedia-1", source["url"] as! String)] {
            let link = app.descendants(matching: .any).matching(identifier: identifier).firstMatch; revealReplay(link); link.tap()
            if !expected.isEmpty { wait(app.staticTexts["replay-url"], "label", expected) }
            else { XCTAssertTrue(app.staticTexts["replay-url"].label.contains("www.google.com")) }
        }
        shareCard("second")
        revealReplay(jsonButton); jsonButton.tap()
        let stages = app.segmentedControls["modelJSONStage"]
        XCTAssertTrue(stages.waitForExistence(timeout: 5))
        for name in ["第二階段", "第一階段", "第二階段"] {
            stages.buttons[name].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(stages.buttons[name].isSelected)
            let value = app.textViews["modelJSONText"].value as? String ?? ""
            XCTAssertTrue(value.contains(name == "第二階段" ? "source_id" : "search_entities"))
        }
        app.buttons["shareRecognitionJSON"].tap(); copyShare("json-second")
        app.buttons["closeModelJSON"].tap()
        setJSON(false); XCTAssertFalse(app.buttons["modelJSON-1"].exists)
        setJSON(true); XCTAssertTrue(app.buttons["modelJSON-1"].exists)
        let after = XCTAttachment(screenshot: app.screenshot()); after.name = "actual-\(sequence)-second-stage"; after.lifetime = .keepAlways; add(after)
        app.terminate()
    }
}

import XCTest
import UIKit

extension CaptureUITests {
    func testPrivacy63SharedBackgroundDisclosureDoesNotAcceptConsent() { checkPrivacy63([]) }
    func testPrivacy63SharedBackgroundDisclosureAtMaximumType() { checkPrivacy63(["--maximum-type"]) }
    private func checkPrivacy63(_ options: [String]) {
        let app = launch(["--onboarding-ui", "--existing-login"] + options)
        XCTAssertTrue(app.buttons["consentAccept"].waitForExistence(timeout: 15))
        let firstUse = app.staticTexts["consentBackgroundExplanation"]
        scrollConsent(firstUse, app: app)
        let explanation = firstUse.label
        XCTAssertTrue(explanation.contains("第二次文字 AI 請求也可能在背景才開始"))
        XCTAssertTrue(explanation.contains("不會自動重送"))
        let policy = app.descendants(matching: .any).matching(identifier: "consentPrivacyLink").firstMatch
        scrollConsent(policy, app: app); XCTAssertTrue(policy.exists)
        XCTAssertTrue(app.buttons["consentAccept"].isHittable)
        app.buttons["consentDefer"].tap(); ready(app)
        XCTAssertEqual(app.staticTexts["mockLoginCount"].label, "login-0")
        XCTAssertTrue(app.buttons["完成首次設定以開始辨識"].exists)
        app.buttons["設定"].tap()
        let settings = app.staticTexts["settingsBackgroundExplanation"]
        scrollSettings(settings, app: app); XCTAssertEqual(settings.label, explanation)
        let settingsPolicy = app.descendants(matching: .any).matching(identifier: "settingsPrivacyLink").firstMatch
        scrollSettings(settingsPolicy, app: app); XCTAssertTrue(settingsPolicy.exists)
        XCTAssertFalse(app.buttons["consentWithdraw"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "privacy63-settings-\(options.isEmpty ? "normal" : "large")"
        shot.lifetime = .keepAlways; add(shot)
    }
    func testBackground62FinitePipelineRefreshAndRecovery() {
        let app = launch(["--background62-checks"])
        let status = app.staticTexts["background62-checks"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'passed' OR label BEGINSWITH 'FAILED'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 90), .completed)
        XCTAssertTrue(status.label.hasPrefix("passed"), status.label)
    }
    func testRefresh62ActionOrderAndEntirePipelineLock() { checkRefresh62([]) }
    func testRefresh62ActionOrderAndEntirePipelineLockAtLargeType() { checkRefresh62(["--refresh62-large"]) }
    func testCardActionJSONVisibilitySpacing() { checkCardActionJSONVisibilitySpacing([]) }
    func testCardActionJSONVisibilitySpacingAtLargeType() { checkCardActionJSONVisibilitySpacing(["--refresh62-large"]) }
    func testCardActionsUseSameEnabledAndDisabledAppearance() { checkCardActionAppearance([]) }
    func testCardActionsUseSameEnabledAndDisabledAppearanceAtLargeType() { checkCardActionAppearance(["--refresh62-large"]) }
    private func checkCardActionAppearance(_ options: [String]) {
        let app = launch(["--refresh62-ui", "--first63-ui"] + options)
        let json = app.buttons["modelJSON-1"]
        let refresh = app.buttons["refreshRecognition-1"]
        let share = app.otherElements["archiveCard-1"].buttons["shareRecognitionResult"]
        XCTAssertTrue(json.waitForExistence(timeout: 15))
        let controls = [json, refresh, share]
        let expected = options.isEmpty ? CGSize(width: 44, height: 36) : CGSize(width: 64, height: 64)
        for enabled in [false, true] {
            if enabled {
                app.buttons["refresh62-first"].tap()
                // Appearance depends on stage one; stage-two scheduling is tested separately.
                scrollWait(json, "enabled == true")
            }
            for _ in 0..<4 {
                if controls.allSatisfy({ $0.frame.maxY < app.frame.maxY - 24 }) { break }
                app.collectionViews.firstMatch.swipeUp()
            }
            for control in controls {
                XCTAssertEqual(control.isEnabled, enabled)
                XCTAssertEqual(control.frame.width, expected.width, accuracy: 0.5)
                XCTAssertEqual(control.frame.height, expected.height, accuracy: 0.5)
                XCTAssertGreaterThan(control.frame.minY, 0)
                XCTAssertLessThan(control.frame.maxY, app.frame.maxY)
            }
            XCTAssertEqual(refresh.frame.minX - json.frame.maxX, 12, accuracy: 1)
            XCTAssertEqual(share.frame.minX - refresh.frame.maxX, 12, accuracy: 1)
            XCTAssertEqual(json.frame.midY, share.frame.midY, accuracy: 0.5)
            if enabled { XCTAssertTrue(controls.allSatisfy(\.isHittable)) }
            let name = "card-style-\(enabled ? "enabled" : "disabled")-\(options.isEmpty ? "normal" : "large")"
            let frames = zip(["json", "refresh", "share"], controls).map { key, control in
                let rect = control.frame
                return ["name": key, "x": rect.minX, "y": rect.minY,
                        "width": rect.width, "height": rect.height] as [String: Any]
            }
            let data = try! JSONSerialization.data(withJSONObject: ["enabled": enabled,
                "screenWidth": app.frame.width, "screenHeight": app.frame.height, "controls": frames], options: [.sortedKeys])
            let geometry = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            geometry.name = name + "-geometry"; geometry.lifetime = .keepAlways; add(geometry)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = name + "-screen"; screenshot.lifetime = .keepAlways; add(screenshot)
        }
        XCTAssertEqual(share.label, "分享結果")
    }
    private func checkCardActionJSONVisibilitySpacing(_ options: [String]) {
        let app = launch(["--refresh62-ui"] + options)
        let card = app.otherElements["archiveCard-1"]
        let refresh = app.buttons["refreshRecognition-1"]
        let share = card.buttons["shareRecognitionResult"]
        let json = app.buttons["modelJSON-1"]
        let actions = app.otherElements["archiveActions-1"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 15))
        for enabled in [true, false, true] {
            if (json.exists != enabled) {
                app.buttons["設定"].tap()
                let toggle = app.switches["showModelJSON"]
                scrollSettings(toggle, app: app)
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
                XCTAssertEqual(toggle.value as? String, enabled ? "1" : "0")
                app.buttons["完成"].tap()
            }
            for _ in 0..<4 {
                if refresh.isHittable && share.isHittable { break }
                app.collectionViews.firstMatch.swipeUp()
            }
            XCTAssertEqual(json.exists, enabled)
            XCTAssertTrue(refresh.isHittable && share.isHittable)
            XCTAssertTrue(refresh.isEnabled && share.isEnabled)
            XCTAssertEqual(share.frame.minX - refresh.frame.maxX, 12, accuracy: 1)
            XCTAssertGreaterThanOrEqual(refresh.frame.width, 44)
            XCTAssertGreaterThanOrEqual(share.frame.width, 44)
            XCTAssertGreaterThanOrEqual(refresh.frame.height, 36)
            XCTAssertGreaterThanOrEqual(share.frame.height, 36)
            let expectedWidth = refresh.frame.width + share.frame.width + 12
                + (enabled ? json.frame.width + 12 : 0)
            XCTAssertEqual(actions.frame.width, expectedWidth, accuracy: 1)
            if enabled {
                XCTAssertTrue(json.isHittable && json.isEnabled)
                XCTAssertLessThan(json.frame.midX, refresh.frame.midX)
                json.tap()
                XCTAssertTrue(app.staticTexts["modelJSONMessage"].waitForExistence(timeout: 5))
                app.buttons["closeModelJSON"].tap()
            }
            let evidence = XCTAttachment(string: "JSON=\(enabled), refresh=\(refresh.frame), share=\(share.frame), json=\(json.exists ? String(describing: json.frame) : "absent")")
            evidence.name = "card-actions-\(enabled)-\(options.isEmpty ? "normal" : "large")"
            evidence.lifetime = .keepAlways; add(evidence)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = (evidence.name ?? "card-actions") + "-screen"
            screenshot.lifetime = .keepAlways; add(screenshot)
        }
    }
    func testFirst63ProcessingEndsBeforeDelayedWikipedia() {
        let app = launch(["--refresh62-ui", "--first63-ui"])
        let start = app.buttons["continueCapture"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        XCTAssertEqual(start.label, "辨識中")
        XCTAssertFalse(start.isEnabled)
        XCTAssertFalse(app.buttons["choosePhoto"].isEnabled)
        let json = app.buttons["modelJSON-1"]
        let share = app.otherElements["archiveCard-1"].buttons["shareRecognitionResult"]
        XCTAssertFalse(json.isEnabled && share.isEnabled)
        app.buttons["refresh62-first"].tap()
        scrollWait(app.staticTexts["refresh62-count"], "label == '1:1'")
        XCTAssertEqual(start.label, "開始辨識")
        XCTAssertTrue(start.isEnabled && app.buttons["choosePhoto"].isEnabled)
        XCTAssertTrue(json.isEnabled && share.isEnabled)
        XCTAssertFalse(app.links["wikipedia-1"].exists)
        json.tap()
        // This injected provider returns a parsed result without raw response bytes.
        // The real JSON sheet must open and disclose that absence, never invent JSON.
        XCTAssertTrue(app.staticTexts["modelJSONMessage"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["modelJSONMessage"].label.contains("未保存原始 JSON"))
        app.buttons["closeModelJSON"].tap()
        XCTAssertEqual(app.staticTexts["refresh62-count"].label, "1:1")
        app.buttons["refresh62-second"].tap()
        XCTAssertTrue(app.links["wikipedia-1"].waitForExistence(timeout: 5))
        XCTAssertEqual(start.label, "開始辨識")
    }
    private func checkRefresh62(_ options: [String]) {
        let app = launch(["--refresh62-ui"] + options)
        let refresh = app.buttons["refreshRecognition-1"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 15))
        for _ in 0..<3 {
            if refresh.isHittable { break }
            app.collectionViews.firstMatch.swipeUp()
        }
        let json = app.buttons["modelJSON-1"]
        let share = app.otherElements["archiveCard-1"].buttons["shareRecognitionResult"]
        XCTAssertTrue(refresh.isHittable && json.isHittable && share.isHittable)
        XCTAssertLessThan(json.frame.midX, refresh.frame.midX)
        XCTAssertLessThan(refresh.frame.midX, share.frame.midX)
        XCTAssertLessThanOrEqual(json.frame.maxX, refresh.frame.minX)
        XCTAssertLessThanOrEqual(refresh.frame.maxX, share.frame.minX)
        let timestamp = app.staticTexts["archiveTimestamp-1"]
        if !options.isEmpty {
            XCTAssertGreaterThan(timestamp.frame.width, 150)
            XCTAssertLessThan(timestamp.frame.maxY, refresh.frame.minY)
        }
        XCTAssertEqual(refresh.label, "重新辨識這張圖片")
        XCTAssertTrue(app.staticTexts["archiveAttempt-1"].label.hasPrefix("第 1 次辨識・"))
        let originalTimestamp = timestamp.label
        refresh.tap()
        scrollWait(app.staticTexts["refresh62-count"], "label == '2:1'")
        let attempt = app.staticTexts["archiveAttempt-1"]
        XCTAssertTrue(attempt.waitForExistence(timeout: 5))
        let secondAttempt = attempt.label
        XCTAssertTrue(secondAttempt.hasPrefix("第 2 次辨識・"), secondAttempt)
        XCTAssertEqual(secondAttempt, "第 2 次辨識・辨識中…")
        XCTAssertEqual(timestamp.label, originalTimestamp)
        XCTAssertFalse(refresh.isEnabled)
        XCTAssertFalse(app.buttons["continueCapture"].isEnabled)
        XCTAssertEqual(app.buttons["continueCapture"].label, "辨識中")
        XCTAssertEqual(app.staticTexts["refreshNotice-1"].label, "重新辨識中，暫時顯示上次辨識結果。")
        XCTAssertTrue(json.isEnabled && share.isEnabled)
        app.buttons["refresh62-first"].tap()
        scrollWait(app.staticTexts["refresh62-count"], "label == '2:2'")
        XCTAssertTrue(attempt.label.hasPrefix("第 2 次辨識・"))
        XCTAssertFalse(refresh.isEnabled)
        XCTAssertFalse(app.buttons["continueCapture"].isEnabled)
        XCTAssertFalse(app.buttons["choosePhoto"].isEnabled)
        XCTAssertEqual(app.buttons["continueCapture"].label, "開始辨識")
        XCTAssertTrue(json.isEnabled && share.isEnabled)
        XCTAssertFalse(app.links["wikipedia-1"].exists)
        let firstFinished = XCTAttachment(screenshot: app.screenshot())
        firstFinished.name = "refresh63-first-ready-second-pending-\(options.isEmpty ? "normal" : "large")"
        firstFinished.lifetime = .keepAlways; add(firstFinished)
        json.tap()
        // This injected provider returns a parsed result without raw response bytes.
        // The real JSON sheet must open and disclose that absence, never invent JSON.
        XCTAssertTrue(app.staticTexts["modelJSONMessage"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["modelJSONMessage"].label.contains("未保存原始 JSON"))
        app.buttons["closeModelJSON"].tap()
        XCTAssertEqual(app.staticTexts["refresh62-count"].label, "2:2")
        XCTAssertEqual(app.buttons["continueCapture"].label, "開始辨識")
        app.buttons["refresh62-second"].tap()
        scrollWait(app.staticTexts["refresh62-busy"], "label == 'idle'")
        XCTAssertTrue(attempt.label.hasPrefix("第 2 次辨識・已完成 ("))
        XCTAssertTrue(attempt.label.hasSuffix(")"))
        XCTAssertTrue(refresh.isEnabled)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "refresh62-completed-\(options.isEmpty ? "normal" : "large")"; shot.lifetime = .keepAlways; add(shot)
        refresh.tap(); scrollWait(app.staticTexts["refresh62-count"], "label == '3:2'")
        app.buttons["refresh62-fail"].tap(); scrollWait(app.staticTexts["refresh62-busy"], "label == 'idle'")
        let failedAttempt = attempt.label
        XCTAssertTrue(failedAttempt.hasPrefix("第 3 次辨識・"), failedAttempt)
        XCTAssertEqual(timestamp.label, originalTimestamp)
        XCTAssertTrue(app.staticTexts["refreshNotice-1"].label.contains("保留上次成功結果"))
        XCTAssertTrue(app.links["wikipedia-1"].exists && json.isEnabled && share.isEnabled && refresh.isEnabled)
        json.tap()
        XCTAssertTrue(app.staticTexts["modelJSONMessage"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["modelJSONMessage"].label.contains("上次成功"))
        app.buttons["modelJSONStage-2"].tap()
        XCTAssertTrue((app.textViews["modelJSONText"].value as? String ?? "").contains("曙光"))
        app.buttons["closeModelJSON"].tap()
        app.terminate()
        app.launchArguments.append("--refresh63-preserve")
        app.launch()
        let reopened = app.staticTexts["archiveAttempt-1"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 15))
        XCTAssertEqual(reopened.label, failedAttempt)
        XCTAssertEqual(app.staticTexts["archiveTimestamp-1"].label, originalTimestamp)
        XCTAssertEqual(app.staticTexts["refresh62-count"].label, "0:0")
        for _ in 0..<4 {
            if reopened.isHittable { break }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(reopened.isHittable)
        XCTAssertGreaterThan(reopened.frame.height, 0)
        XCTAssertGreaterThanOrEqual(reopened.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(reopened.frame.maxX, app.frame.maxX)
        let restored = XCTAttachment(screenshot: app.screenshot())
        restored.name = "attempt63-failed-reopened-\(options.isEmpty ? "normal" : "large")"
        restored.lifetime = .keepAlways; add(restored)
    }
    func testAttempt63LegacyMissingDateDoesNotInventTimestamp() {
        let app = launch(["--refresh62-ui", "--attempt63-legacy"])
        let attempt = app.staticTexts["archiveAttempt-1"]
        XCTAssertTrue(attempt.waitForExistence(timeout: 15))
        XCTAssertTrue(attempt.label.hasPrefix("第 2 次辨識・第一階段失敗：合成舊紀錄 ("))
        XCTAssertTrue(attempt.label.hasSuffix(")"))
        XCTAssertTrue(app.staticTexts["archiveTimestamp-1"].exists)
        XCTAssertTrue(app.staticTexts["refreshNotice-1"].label.contains("保留上次成功結果"))
    }
    func testRefresh62MissingImageDisablesActionWithReason() {
        let app = launch(["--refresh62-ui", "--refresh62-missing"])
        let refresh = app.buttons["refreshRecognition-1"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 15))
        XCTAssertFalse(refresh.isEnabled)
        XCTAssertTrue(app.staticTexts["refreshMissingImage-1"].exists)
        XCTAssertTrue(app.textViews["archiveText-1"].exists)
        XCTAssertEqual(app.staticTexts["refresh62-count"].label, "1:1")
    }
    private func enableJSON45(_ app: XCUIApplication) {
        app.buttons["設定"].tap()
        let toggle = app.switches["showModelJSON"]
        scrollSettings(toggle, app: app)
        // isHittable can be true when only the label's top edge is visible.
        // A coordinate tap needs the switch's actual center inside the viewport.
        let viewport = app.frame.insetBy(dx: 0, dy: 100)
        for _ in 0..<6 {
            if viewport.contains(CGPoint(x: toggle.frame.midX, y: toggle.frame.midY)) { break }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(viewport.contains(CGPoint(x: toggle.frame.midX, y: toggle.frame.midY)))
        if toggle.value as? String == "0" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 3), .completed)
        app.buttons["完成"].tap()
    }
    func testJSON45TogglePersistsAndImmediatelyUpdatesListRepeatedly() {
        let app = launch(["--json45"]); ready(app)
        XCTAssertFalse(app.buttons["modelJSON-12"].exists)
        for enabled in [true, false, true, false, true] {
            app.buttons["設定"].tap()
            let toggle = app.switches["showModelJSON"]
            scrollSettings(toggle, app: app); toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            XCTAssertEqual(toggle.value as? String, enabled ? "1" : "0")
            app.buttons["完成"].tap()
            XCTAssertEqual(app.buttons["modelJSON-12"].exists, enabled)
        }
        let json = app.buttons["modelJSON-12"]
        let card = app.otherElements["archiveCard-12"]
        let share = card.buttons["shareRecognitionResult"]
        XCTAssertTrue(json.isHittable && share.isHittable)
        XCTAssertLessThan(json.frame.midX, share.frame.midX)
        app.terminate(); app.launchArguments = ["--json45", "--json45-preserve-setting", "--resume-history"]; app.launch(); ready(app)
        XCTAssertTrue(app.buttons["modelJSON-12"].exists)
        app.buttons["設定"].tap(); let toggle = app.switches["showModelJSON"]; scrollSettings(toggle, app: app)
        XCTAssertEqual(toggle.value as? String, "1")
    }
    func testJSON45LongUnicodeScrollAndExactPlainTextSystemCopy() {
        let app = launch(["--json45"]); ready(app); enableJSON45(app)
        app.buttons["modelJSON-12"].tap()
        let text = app.textViews["modelJSONText"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        let content = text.value as? String ?? ""
        XCTAssertTrue(content.contains("摩訶止觀") && content.contains("👩🏽‍🔬") && content.contains("第180行"))
        XCTAssertTrue(content.contains("\n") && content.contains("\\\""))
        text.swipeUp(); text.swipeUp()
        app.buttons["shareRecognitionJSON"].tap()
        let copy = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Copy'")).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5)); copy.tap()
        app.buttons["closeModelJSON"].tap()
        let label = app.staticTexts["c2-fixture-status"]
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'json45-copy-verified'"), object: label)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 5), .completed)
        app.buttons["modelJSON-12"].tap()
        XCTAssertEqual(app.textViews["modelJSONText"].value as? String, content)
        attach37(app, "json45-long-raw")
    }
    func testJSON45LegacyOversizeAndFailedRawAreExplicit() {
        let app = launch(["--json45"]); ready(app); enableJSON45(app)
        for (sequence, message, canShare) in [(11, "未保存原始 JSON", true), (9, "超過保存上限", true)] {
            let button = app.buttons["modelJSON-\(sequence)"]; reveal(button, in: app); button.tap()
            XCTAssertTrue(app.staticTexts["modelJSONMessage"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["modelJSONMessage"].label.contains(message))
            XCTAssertEqual(app.buttons["shareRecognitionJSON"].exists, canShare)
            app.buttons["closeModelJSON"].tap()
        }
        let failed = app.buttons["modelJSON-10"]; reveal(failed, in: app)
        XCTAssertFalse(failed.isEnabled)
        XCTAssertFalse(app.otherElements["archiveCard-10"].buttons["shareRecognitionResult"].isEnabled)
    }
    func testJSON45PendingDoesNotOfferPreviousOrInventedRaw() {
        let app = launch(["--json45"]); ready(app); enableJSON45(app)
        app.buttons["continueCapture"].tap(); app.buttons["feedFrames"].tap()
        let button = app.buttons["modelJSON-13"]
        XCTAssertTrue(button.waitForExistence(timeout: 8)); reveal(button, in: app)
        XCTAssertFalse(button.isEnabled)
        XCTAssertFalse(app.otherElements["archiveCard-13"].buttons["shareRecognitionResult"].isEnabled)
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(app.buttons["closeModelJSON"].exists)
        app.terminate()
        app.launchArguments = ["--json45", "--json45-preserve-setting", "--resume-history"]
        app.launch(); ready(app)
        let interrupted = app.buttons["modelJSON-13"]
        XCTAssertTrue(interrupted.waitForExistence(timeout: 8)); reveal(interrupted, in: app)
        XCTAssertFalse(interrupted.isEnabled)
        XCTAssertFalse(app.otherElements["archiveCard-13"].buttons["shareRecognitionResult"].isEnabled)
    }
    func testJSON45MaximumTypeDarkViewerRemainsReadable() {
        let app = launch(["--json45", "--maximum-type", "--dark"]); ready(app); enableJSON45(app)
        let button = app.buttons["modelJSON-12"]; reveal(button, in: app); button.tap()
        let text = app.textViews["modelJSONText"]
        XCTAssertTrue(text.waitForExistence(timeout: 5) && text.isHittable)
        XCTAssertGreaterThan(text.frame.height, 100)
        XCTAssertTrue(app.buttons["shareRecognitionJSON"].isHittable && app.buttons["closeModelJSON"].isHittable)
        let details = app.scrollViews["modelJSONDetails"]
        XCTAssertTrue(details.exists)
        let version = app.staticTexts["modelJSONVersion"]
        details.swipeUp()
        XCTAssertTrue(version.isHittable)
        XCTAssertTrue(version.label.contains("P21-English-semantic-entities-zhTW1"))
        text.swipeUp(); attach37(app, "json45-maximum-type-dark")
        app.buttons["shareRecognitionJSON"].tap()
        let copy = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Copy'")).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5)); copy.tap()
        app.buttons["closeModelJSON"].tap()
        let label = app.staticTexts["c2-fixture-status"]
        let verified = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'json45-copy-verified'"), object: label)
        XCTAssertEqual(XCTWaiter.wait(for: [verified], timeout: 5), .completed, label.label)
    }
    func testBoundedReplaySuccessUsesFormalPathsAndNeverRepeats() {
        boundedReplayChecks(["--bounded-replay-checks"])
    }
    func testBoundedReplayFailureStopsWithoutRetry() {
        boundedReplayChecks(["--bounded-replay-failure"])
    }
    private func boundedReplayChecks(_ flags: [String]) {
        let app = launch(flags), label = app.staticTexts["boundedReplayChecks"]
        XCTAssertTrue(label.waitForExistence(timeout: 15))
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != 'running'"), object: label)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 40), .completed)
        XCTAssertTrue(label.label.hasPrefix("passed "), label.label)
    }
    func testBoundedReplayUIAndShareStayLocal() {
        checkBothBoundedReplayCards(flag: "--bounded-replay-ui", expectedStatus: "兩筆回放完成，等待內容驗收")
    }
    func testBoundedReplaySeededOfflineReadback() {
        checkBothBoundedReplayCards(flag: "--bounded-replay-seeded-readback", expectedStatus: "兩筆離線讀回完成")
    }
    // Run only after the explicitly authorized device output has been imported locally.
    func testBoundedReplayImportedOfflineReadback() {
        checkBothBoundedReplayCards(flag: "--bounded-replay-readback", expectedStatus: "兩筆離線讀回完成")
    }
    // Evidence of the observed partial result, not a successful two-Wikipedia release gate.
    func testBoundedReplayObservedOfflineReadback() {
        checkBothBoundedReplayCards(flag: "--bounded-replay-readback", expectedStatus: "兩筆離線讀回完成", expectedWikiSequences: [1])
    }
    func testWiki40RealJSONOfflineReadbackAndShare() {
        checkBothBoundedReplayCards(flag: "--bounded-replay-readback", expectedStatus: "兩筆離線讀回完成", corrected: true)
    }
    func testHan42RealJSONOfflineReadbackAndShare() {
        checkBothBoundedReplayCards(flag: "--bounded-replay-readback", expectedStatus: "兩筆離線讀回完成", han42: true)
    }
    func testManufacturing43FrontBackReadbackAndShare() {
        checkBothBoundedReplayCards(flag: "--bounded-replay-readback", expectedStatus: "兩筆離線讀回完成",
            expectedWikiSequences: [146], sequences: [147, 146], folder43: "FrontBack")
    }
    func testManufacturing43BrandAndProductReadbackAndShare() {
        checkBothBoundedReplayCards(flag: "--bounded-replay-readback", expectedStatus: "兩筆離線讀回完成",
            expectedWikiSequences: [149, 148], sequences: [149, 148], folder43: "BrandProduct")
    }
    func testManufacturing43RotatedFrontReadbackAndShare() {
        checkBothBoundedReplayCards(flag: "--bounded-replay-readback", expectedStatus: "兩筆離線讀回完成",
            expectedWikiSequences: [150, 146], sequences: [150, 146], folder43: "RotatedFront")
    }
    private func checkBothBoundedReplayCards(flag: String, expectedStatus: String, expectedWikiSequences: [Int] = [2, 1], corrected: Bool = false, han42: Bool = false,
                                            sequences: [Int] = [2, 1], folder43: String? = nil) {
        let app = launch([flag] + (han42 ? ["--bounded-replay-han42"] : corrected ? ["--bounded-replay-corrected"] : []) + (folder43.map { ["--bounded-replay43-" + $0] } ?? [])), status = app.staticTexts["boundedReplayStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expectedStatus), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 40), .completed)
        XCTAssertFalse(app.buttons["開始辨識"].exists)
        XCTAssertFalse(app.buttons["選擇相簿圖片"].exists)
        for sequence in sequences {
            let row = app.descendants(matching: .any).matching(identifier: "boundedRow-\(sequence)").firstMatch
            let share = row.buttons["shareRecognitionResult"].firstMatch
            for _ in 0..<10 where !share.isHittable { app.swipeUp() }
            XCTAssertTrue(share.isHittable); if share.isHittable { share.tap() }
            XCTAssertTrue(app.staticTexts["boundedShareVerified"].exists)
            let expectedLinks = ["googleSearch-\(sequence)"] + (expectedWikiSequences.contains(sequence) ? ["wikipedia-\(sequence)"] : [])
            if !expectedWikiSequences.contains(sequence) {
                XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "wikipedia-\(sequence)").firstMatch.exists)
            }
            for identifier in expectedLinks {
                let link = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
                for _ in 0..<10 where !link.isHittable { app.swipeUp() }
                XCTAssertTrue(link.isHittable); if link.isHittable { link.tap() }
                XCTAssertTrue(app.staticTexts["boundedLinkVerified"].exists)
            }
            let screen = XCTAttachment(screenshot: app.screenshot()); screen.name = (han42 ? "Build42" : corrected ? "Build40" : "Build39") + "-bounded-card-\(sequence)-" + flag; screen.lifetime = .keepAlways; add(screen)
        }
        XCTAssertEqual(app.staticTexts["boundedVerificationCounts"].label, "分享核對 2；連結核對 \(2 + expectedWikiSequences.count)")
        if flag == "--bounded-replay-readback" { XCTAssertEqual(app.staticTexts["boundedOfflineNetwork"].label, "offline-wire-0-other-0") }
        XCTAssertFalse(app.otherElements["ActivityListView"].exists)
        app.terminate()
    }
    func testEntity41ControllerLifecycleAndDiagnostics() {
        let app = launch(["--entity41-checks"])
        let result = app.staticTexts["c41-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "label BEGINSWITH 'passed' OR label BEGINSWITH 'FAILED'"), evaluatedWith: result)
        waitForExpectations(timeout: 90)
        XCTAssertTrue(result.label.hasPrefix("passed"), result.label)
        XCTAssertGreaterThanOrEqual(Int(result.label.components(separatedBy: " ").last ?? "0") ?? 0, 18)
    }
    func testEntity39ControllerLifecycleAndDiagnostics() {
        let app = launch(["--entity39-checks"])
        let result = app.staticTexts["c39-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "label BEGINSWITH 'passed' OR label BEGINSWITH 'FAILED'"), evaluatedWith: result)
        waitForExpectations(timeout: 90)
        XCTAssertTrue(result.label.hasPrefix("passed"), result.label)
        XCTAssertGreaterThanOrEqual(Int(result.label.components(separatedBy: " ").last ?? "0") ?? 0, 18)
    }
    func testEntity39SingleReferenceNormalType() throws { try checkEntity39Links([]) }
    func testEntity39SingleReferenceMaximumTypeDark() throws { try checkEntity39Links(["--maximum-type", "--dark"]) }
    func testEntity39RichShareAndRestart() {
        let app = launch(["--entity39-links"]); ready(app); shareCard(12, in: app, rich: true)
        app.terminate(); app.launchArguments = ["--entity39-links", "--resume-history", "--expect-share-11"]; app.launch(); ready(app)
        shareCard(11, in: app, rich: true)
    }
    private func checkEntity39Links(_ args: [String]) throws {
        let app = launch(["--entity39-links", "--scroll-ui"] + args); ready(app)
        for (id, query, path) in [("googleSearch-12", "晨光原味 Morning Original", ""), ("wikipedia-12", "", "/wiki/曙光公司")] {
            let link = app.descendants(matching: .any).matching(identifier: id).firstMatch
            reveal(link, in: app); XCTAssertTrue(link.isHittable)
            let shot = link.screenshot(), image = try XCTUnwrap(shot.image.cgImage)
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            var blue = 0
            for offset in stride(from: 0, to: pixels.count, by: 4) {
                let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
                if b > 120 && b - r > 60 && b - g > 30 { blue += 1 }
            }
            XCTAssertGreaterThan(blue, 100)
            if id.hasPrefix("wikipedia") { XCTAssertTrue(link.label.contains("製造商"), link.label) }
            let before = try capturedURLs(app).count; link.tap()
            let opened = Array(try capturedURLs(app).dropFirst(before)); XCTAssertEqual(opened.count, 1)
            let url = try XCTUnwrap(opened.first.flatMap { URLComponents(string: $0) })
            if !query.isEmpty { XCTAssertEqual(url.host, "www.google.com"); XCTAssertEqual(url.queryItems?.first { $0.name == "q" }?.value, query) }
            else { XCTAssertEqual(url.host, "zh.wikipedia.org"); XCTAssertEqual(url.path, path) }
            let evidence = XCTAttachment(data: try JSONSerialization.data(withJSONObject: ["identifier": id, "bluePixels": blue, "openedURLs": opened], options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
            evidence.name = "Build39-link-" + id; evidence.lifetime = .keepAlways; add(evidence)
            let attachment = XCTAttachment(screenshot: shot); attachment.name = "Build39-" + id; attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'textWikipedia-12-'" )).firstMatch.exists)
        let screen = XCTAttachment(screenshot: app.screenshot()); screen.name = "Build39-single-reference-screen"; screen.lifetime = .keepAlways; add(screen)
        XCTAssertTrue(app.staticTexts["scrollState"].label.contains("calls-0"))
    }
    func testEntity38ControllerLifecycleAndDiagnostics() {
        let app = launch(["--entity38-checks"])
        let result = app.staticTexts["c38-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "label BEGINSWITH 'passed' OR label BEGINSWITH 'FAILED'"), evaluatedWith: result)
        waitForExpectations(timeout: 90)
        XCTAssertTrue(result.label.hasPrefix("passed"), result.label)
        XCTAssertGreaterThanOrEqual(Int(result.label.components(separatedBy: " ").last ?? "0") ?? 0, 17)
    }
    func testEntity38SingleReferenceNormalType() throws { try checkEntity38Links([]) }
    func testEntity38SingleReferenceMaximumTypeDark() throws { try checkEntity38Links(["--maximum-type", "--dark"]) }
    func testEntity38RichShareAndRestart() {
        let app = launch(["--entity38-links"]); ready(app); shareCard(12, in: app, rich: true)
        app.terminate(); app.launchArguments = ["--entity38-links", "--resume-history", "--expect-share-11"]; app.launch(); ready(app)
        shareCard(11, in: app, rich: true)
    }
    private func checkEntity38Links(_ args: [String]) throws {
        let app = launch(["--entity38-links", "--scroll-ui"] + args); ready(app)
        for (id, query, path) in [("googleSearch-12", "晨光原味 Morning Original", ""), ("wikipedia-12", "", "/wiki/曙光公司")] {
            let link = app.descendants(matching: .any).matching(identifier: id).firstMatch
            reveal(link, in: app); XCTAssertTrue(link.isHittable)
            let shot = link.screenshot(), image = try XCTUnwrap(shot.image.cgImage)
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            var blue = 0
            for offset in stride(from: 0, to: pixels.count, by: 4) {
                let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
                if b > 120 && b - r > 60 && b - g > 30 { blue += 1 }
            }
            XCTAssertGreaterThan(blue, 100)
            if id.hasPrefix("wikipedia") { XCTAssertTrue(link.label.contains("製造商"), link.label) }
            let before = try capturedURLs(app).count; link.tap()
            let opened = Array(try capturedURLs(app).dropFirst(before)); XCTAssertEqual(opened.count, 1)
            let url = try XCTUnwrap(opened.first.flatMap { URLComponents(string: $0) })
            if !query.isEmpty { XCTAssertEqual(url.host, "www.google.com"); XCTAssertEqual(url.queryItems?.first { $0.name == "q" }?.value, query) }
            else { XCTAssertEqual(url.host, "zh.wikipedia.org"); XCTAssertEqual(url.path, path) }
            let evidence = XCTAttachment(data: try JSONSerialization.data(withJSONObject: ["identifier": id, "bluePixels": blue, "openedURLs": opened], options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
            evidence.name = "Build38-link-" + id; evidence.lifetime = .keepAlways; add(evidence)
            let attachment = XCTAttachment(screenshot: shot); attachment.name = "Build38-" + id; attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'textWikipedia-12-'" )).firstMatch.exists)
        let screen = XCTAttachment(screenshot: app.screenshot()); screen.name = "Build38-single-reference-screen"; screen.lifetime = .keepAlways; add(screen)
        XCTAssertTrue(app.staticTexts["scrollState"].label.contains("calls-0"))
    }
    func testConsentLifecycleAndTransferBoundaries() { check37("--consent-checks", minimum: 20) }
    func testCandidate37ControllerPersistenceAndCancellation() { check37("--candidate37-checks", minimum: 9) }
    private func check37(_ flag: String, minimum: Int) {
        let app = launch([flag]); let result = app.staticTexts["c37-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'passed ' OR label BEGINSWITH 'FAILED '"), object: result)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 80), .completed)
        XCTAssertTrue(result.label.hasPrefix("passed "), result.label)
        XCTAssertGreaterThanOrEqual(Int(result.label.split(separator: " ").last ?? "0") ?? 0, minimum)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Build37-" + flag; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testTextWikipediaControllerLifecycle() {
        let app = launch(["--text-wiki-checks"])
        let result = app.staticTexts["c36-text-wiki-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'passed ' OR label BEGINSWITH 'FAILED '"), object: result)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 40), .completed)
        XCTAssertEqual(result.label, "passed 8", result.label)
    }
    func testCandidate37LinksNormalType() throws { try checkTextWikipediaLinks([], modern: true) }
    func testCandidate37LinksMaximumTypeDark() throws { try checkTextWikipediaLinks(["--maximum-type", "--dark"], modern: true) }
    func testCandidate37RichShareAfterRestart() {
        let app = launch(["--candidate37-links"]); ready(app); shareCard(12, in: app, rich: true)
        app.terminate(); app.launchArguments = ["--candidate37-links", "--resume-history", "--expect-share-11"]; app.launch(); ready(app)
        shareCard(11, in: app, rich: true)
    }
    func testFirstUseConsentAndOneMockLogin() throws {
        let app = launch(["--onboarding-ui"])
        let accept = app.buttons["consentAccept"]; XCTAssertTrue(accept.waitForExistence(timeout: 15))
        attach37(app, "first-use-explanation")
        let apple = app.descendants(matching: .any).matching(identifier: "photoLocationExplanation").firstMatch
        scrollConsent(apple, app: app); attach37(app, "photo-location-explanation-link"); apple.tap()
        for heading in ["維基百科", "Google", "登入你的帳戶"] {
            scrollConsent(app.staticTexts[heading], app: app); attach37(app, "first-use-" + heading)
        }
        scrollConsent(accept, app: app); accept.tap()
        // The intercepted Apple link changes the fixture's status label; wait for
        // the actual login UI instead of the pre-link ready label.
        XCTAssertTrue(app.staticTexts["mockLoginCount"].waitForExistence(timeout: 10))
        XCTAssertEqual(try capturedURLs(app), ["https://support.apple.com/zh-tw/guide/personal-safety/ips0d7a5df82/web"])
        XCTAssertFalse(app.buttons["consentAccept"].exists)
        XCTAssertEqual(app.staticTexts["mockLoginCount"].label, "login-1")
        app.terminate(); app.launchArguments = ["--onboarding-ui", "--resume-consent", "--existing-login", "--resume-history"]; app.launch(); ready(app)
        XCTAssertFalse(app.buttons["consentAccept"].exists)
        XCTAssertEqual(app.staticTexts["mockLoginCount"].label, "login-0")
        attach37(app, "completed-relaunch")
    }
    func testFirstUseDeferAndMaximumType() {
        let app = launch(["--onboarding-ui", "--maximum-type", "--dark"])
        let decline = app.buttons["consentDefer"]; XCTAssertTrue(decline.waitForExistence(timeout: 15))
        scrollConsent(decline, app: app); XCTAssertGreaterThanOrEqual(app.buttons["consentAccept"].frame.height, 60); attach37(app, "first-use-max-type-actions"); decline.tap(); ready(app)
        XCTAssertEqual(app.staticTexts["mockLoginCount"].label, "login-0")
        XCTAssertTrue(app.buttons["完成首次設定以開始辨識"].exists)
    }
    func testFirstUseCancelledLoginDoesNotLoop() {
        let app = launch(["--onboarding-ui", "--cancel-mock-login"])
        let accept = app.buttons["consentAccept"]; XCTAssertTrue(accept.waitForExistence(timeout: 15))
        scrollConsent(accept, app: app); accept.tap()
        let deferButton = app.buttons["consentDefer"]; XCTAssertTrue(deferButton.waitForExistence(timeout: 10)); deferButton.tap(); ready(app)
        XCTAssertEqual(app.staticTexts["mockLoginCount"].label, "login-1")
        app.terminate(); app.launchArguments = ["--onboarding-ui", "--resume-consent", "--cancel-mock-login", "--resume-history"]; app.launch()
        XCTAssertTrue(app.buttons["siwc-authenticate-account"].waitForExistence(timeout: 15))
        app.buttons["consentDefer"].tap(); ready(app)
        XCTAssertEqual(app.staticTexts["mockLoginCount"].label, "login-0")
    }
    func testConsentSettingsReacceptRefreshesWithoutReopening() {
        let app = launch(["--onboarding-ui", "--existing-login"])
        let initial = app.buttons["consentAccept"]
        XCTAssertTrue(initial.waitForExistence(timeout: 15)); scrollConsent(initial, app: app); initial.tap(); ready(app)
        app.buttons["設定"].tap()
        let withdraw = app.buttons["consentWithdraw"], open = app.buttons["consentOpenSettings"]
        for round in 1...2 {
            XCTAssertTrue(withdraw.waitForExistence(timeout: 5)); withdraw.tap()
            XCTAssertFalse(withdraw.exists)
            XCTAssertFalse(app.staticTexts["圖片辨識 · OpenAI"].exists)
            scrollSettings(open, app: app); open.tap()
            let accept = app.buttons["consentAccept"]
            XCTAssertTrue(accept.waitForExistence(timeout: 5)); XCTAssertTrue(accept.isHittable); accept.tap()
            // Stay in this same settings presentation: reopening would hide the regression.
            XCTAssertTrue(withdraw.waitForExistence(timeout: 5), "round \(round): consent saved but settings did not refresh")
            XCTAssertFalse(open.exists); XCTAssertTrue(app.navigationBars["設定"].exists)
            attach37(app, "settings-reaccepted-\(round)")
        }
        app.buttons["完成"].tap(); ready(app)
        XCTAssertEqual(app.staticTexts["mockLoginCount"].label, "login-0")
        XCTAssertTrue(app.buttons["continueCapture"].isEnabled)
        app.terminate(); app.launchArguments = ["--onboarding-ui", "--existing-login", "--resume-consent", "--resume-history"]; app.launch(); ready(app)
        XCTAssertFalse(app.buttons["consentAccept"].exists)
        app.buttons["設定"].tap(); XCTAssertTrue(app.buttons["consentWithdraw"].waitForExistence(timeout: 5))
    }
    func testConsentSettingsDeferredAndCancelledLoginStayConsistent() {
        let app = launch(["--onboarding-ui", "--cancel-mock-login"])
        let initial = app.buttons["consentAccept"]
        XCTAssertTrue(initial.waitForExistence(timeout: 15)); scrollConsent(initial, app: app); initial.tap()
        let deferButton = app.buttons["consentDefer"]
        XCTAssertTrue(deferButton.waitForExistence(timeout: 10)); deferButton.tap(); ready(app)
        app.buttons["設定"].tap()
        let withdraw = app.buttons["consentWithdraw"], open = app.buttons["consentOpenSettings"]
        XCTAssertTrue(withdraw.waitForExistence(timeout: 5)); withdraw.tap()
        XCTAssertFalse(withdraw.exists)
        open.tap()
        XCTAssertTrue(app.buttons["consentAccept"].waitForExistence(timeout: 5))
        app.buttons["consentDefer"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5)); XCTAssertFalse(withdraw.exists)
        // Leaving the explanation without accepting must preserve withdrawal.
        app.buttons["完成"].tap(); ready(app)
        XCTAssertTrue(app.buttons["完成首次設定以開始辨識"].exists)
        app.buttons["設定"].tap(); XCTAssertFalse(withdraw.exists)
        XCTAssertFalse(app.staticTexts["圖片辨識 · OpenAI"].exists)
            scrollSettings(open, app: app); open.tap()
            let accept = app.buttons["consentAccept"]
            XCTAssertTrue(accept.waitForExistence(timeout: 5)); XCTAssertTrue(accept.isHittable); accept.tap()
        XCTAssertTrue(withdraw.waitForExistence(timeout: 5)); XCTAssertFalse(open.exists)
        app.buttons["完成"].tap(); ready(app)
        XCTAssertEqual(app.staticTexts["mockLoginCount"].label, "login-2")
        XCTAssertTrue(app.buttons["登入 ChatGPT 以開始辨識"].exists)
        // Cancelled login does not undo the separately accepted consent or auto-retry on reopen.
        app.terminate(); app.launchArguments = ["--onboarding-ui", "--resume-consent", "--cancel-mock-login", "--resume-history"]; app.launch()
        XCTAssertTrue(app.buttons["siwc-authenticate-account"].waitForExistence(timeout: 15))
        app.buttons["consentDefer"].tap(); ready(app)
        XCTAssertEqual(app.staticTexts["mockLoginCount"].label, "login-0")
        app.buttons["設定"].tap(); XCTAssertTrue(app.buttons["consentWithdraw"].waitForExistence(timeout: 5))
    }
    func testConsent49MaximumTypeStickyActionAndSameSettingsStatus() {
        let app = launch(["--onboarding-ui", "--existing-login", "--maximum-type", "--dark"])
        let accept = app.buttons["consentAccept"]
        XCTAssertTrue(accept.waitForExistence(timeout: 15)); XCTAssertTrue(accept.isHittable)
        XCTAssertGreaterThanOrEqual(accept.frame.height, 44)
        XCTAssertTrue(app.frame.contains(accept.frame))
        let firstUseHeight = accept.frame.height
        attach37(app, "consent49-first-maximum-type")
        accept.tap(); ready(app); app.buttons["設定"].tap()
        let withdraw = app.buttons["consentWithdraw"], open = app.buttons["consentOpenSettings"]
        XCTAssertTrue(withdraw.waitForExistence(timeout: 5)); withdraw.tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5)); XCTAssertFalse(app.staticTexts["圖片辨識 · OpenAI"].exists)
        open.tap(); XCTAssertTrue(accept.waitForExistence(timeout: 5)); XCTAssertTrue(accept.isHittable)
        XCTAssertGreaterThanOrEqual(accept.frame.height, firstUseHeight - 2, "Settings sheet must inherit the same accessibility text size")
        XCTAssertTrue(app.frame.contains(accept.frame))
        let initialY = accept.frame.midY
        for _ in 0..<5 { app.scrollViews["consentDocument"].swipeUp() }
        XCTAssertTrue(accept.isHittable); XCTAssertEqual(accept.frame.midY, initialY, accuracy: 2)
        attach37(app, "consent49-settings-maximum-type")
        app.buttons["consentDefer"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5)); XCTAssertFalse(withdraw.exists)
        open.tap(); XCTAssertTrue(accept.waitForExistence(timeout: 5)); accept.tap()
        XCTAssertTrue(withdraw.waitForExistence(timeout: 5)); XCTAssertTrue(withdraw.isHittable)
        XCTAssertTrue(app.staticTexts["consentAcceptedStatus"].exists); XCTAssertFalse(open.exists)
        attach37(app, "consent49-accepted-maximum-type")
    }
    func testConsent49FailedSaveStaysOnDocumentAndDoesNotGrantOrLogin() {
        let app = launch(["--onboarding-ui", "--fail-consent-save"])
        let accept = app.buttons["consentAccept"]
        XCTAssertTrue(accept.waitForExistence(timeout: 15)); accept.tap()
        XCTAssertTrue(app.staticTexts["consentSaveError"].waitForExistence(timeout: 5)); XCTAssertTrue(accept.isHittable)
        app.buttons["consentDefer"].tap(); ready(app)
        XCTAssertEqual(app.staticTexts["mockLoginCount"].label, "login-0")
        app.buttons["設定"].tap(); app.buttons["consentOpenSettings"].tap()
        XCTAssertTrue(accept.waitForExistence(timeout: 5)); accept.tap()
        XCTAssertTrue(app.staticTexts["consentSaveError"].exists); XCTAssertTrue(accept.isHittable)
        app.buttons["consentDefer"].tap()
        XCTAssertTrue(app.buttons["consentOpenSettings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["consentWithdraw"].exists)
    }
    private func scrollSettings(_ target: XCUIElement, app: XCUIApplication) {
        for _ in 0..<25 { if target.isHittable { return }; app.swipeUp() }
        XCTAssertTrue(target.isHittable)
    }
    private func scrollConsent(_ target: XCUIElement, app: XCUIApplication) {
        for _ in 0..<30 { if target.isHittable { return }; app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(target.isHittable)
    }
    private func attach37(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "Build37-" + name; a.lifetime = .keepAlways; add(a)
    }
    func testTextWikipediaLinksAreBlueAndOpenOnce() throws { try checkTextWikipediaLinks([]) }
    func testTextWikipediaLinksAtMaximumTypeInDarkMode() throws { try checkTextWikipediaLinks(["--maximum-type", "--dark"]) }
    private func checkTextWikipediaLinks(_ arguments: [String], modern: Bool = false) throws {
        let app = launch([modern ? "--candidate37-links" : "--text-wiki-links", "--scroll-ui"] + arguments); ready(app)
        let rows = modern ? [("googleSearch-12", "林範例"), ("wikipedia-12", "林範例"), ("textWikipedia-12-3701", "摩訶止觀"), ("textWikipedia-12-3702", "阿斯匹靈"), ("textWikipedia-12-3703", "海尼根")] : [("googleSearch-12", "摩訶止觀"), ("textWikipedia-12-3601", "摩訶止觀"),
                    ("textWikipedia-12-3602", "社子"), ("textWikipedia-12-3603", "晴禾極厚韌衛生紙")]
        var samples: [[String: Any]] = []
        for (identifier, title) in rows {
            let link = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            reveal(link, in: app); XCTAssertTrue(link.isHittable)
            let shot = link.screenshot(), image = try XCTUnwrap(shot.image.cgImage)
            let attachment = XCTAttachment(screenshot: shot); attachment.name = "Build36-\(identifier)"; attachment.lifetime = .keepAlways; add(attachment)
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            var blue = 0
            for i in stride(from: 0, to: pixels.count, by: 4) {
                if pixels[i + 2] > 120 && Int(pixels[i + 2]) - Int(pixels[i]) > 60 && Int(pixels[i + 2]) - Int(pixels[i + 1]) > 30 { blue += 1 }
            }
            let before = try capturedURLs(app).count; link.tap()
            let opened = Array(try capturedURLs(app).dropFirst(before))
            XCTAssertEqual(opened.count, 1)
            let url = try XCTUnwrap(opened.first.flatMap { URLComponents(string: $0) })
            if identifier.hasPrefix("google") {
                XCTAssertEqual(url.host, "www.google.com"); XCTAssertEqual(url.queryItems?.first { $0.name == "q" }?.value, title)
            } else { XCTAssertEqual(url.host, "zh.wikipedia.org"); XCTAssertEqual(url.path, "/wiki/" + title) }
            XCTAssertGreaterThan(blue, 100)
            samples.append(["identifier": identifier, "bluePixels": blue, "openedURLs": opened])
        }
        let report = XCTAttachment(data: try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        report.name = "Build36-text-reference-links"; report.lifetime = .keepAlways; add(report)
        let screen = XCTAttachment(screenshot: app.screenshot()); screen.name = "Build36-reference-full-screen"; screen.lifetime = .keepAlways; add(screen)
        XCTAssertTrue(app.staticTexts["scrollState"].label.contains("calls-0"))
    }
    func testTextWikipediaRichSharingAfterRestart() {
        let app = launch(["--text-wiki-links"]); ready(app)
        shareCard(12, in: app, rich: true)
        app.terminate(); app.launchArguments = ["--text-wiki-links", "--resume-history", "--expect-share-11"]; app.launch(); ready(app)
        shareCard(11, in: app, rich: true)
    }
    func testExplicitBarcodeURLsPreserveHTTPAndLeaveOtherPayloadsPlain() throws {
        let app = launch(["--web-url-links"]); ready(app)
        XCTAssertEqual(try capturedURLs(app), [])
        let expected = ["http://60.251.161.196/RegDegree/RegisterDegree.aspx", "https://example.com/path?x=1&y=2#part"]
        for (index, url) in expected.enumerated() {
            let link = app.descendants(matching: .any).matching(identifier: "archiveBarcode-12-\(index)").firstMatch
            reveal(link, in: app)
            XCTAssertEqual(link.label, url)
            XCTAssertGreaterThanOrEqual(link.frame.height, 44)
            link.tap()
            XCTAssertEqual(try capturedURLs(app), Array(expected.prefix(index + 1)))
        }
        for index in 2...5 {
            XCTAssertFalse(app.links["archiveBarcode-12-\(index)"].exists)
            XCTAssertTrue(app.staticTexts["archiveBarcode-12-\(index)"].exists)
        }
        attach37(app, "explicit-web-barcodes")
        let first = app.descendants(matching: .any).matching(identifier: "archiveBarcode-12-0").firstMatch
        reveal(first, in: app); first.press(forDuration: 1)
        let copy = app.buttons["複製網址"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5)); copy.tap()
        app.buttons["verifyWebCopy"].tap()
        XCTAssertEqual(app.staticTexts["c2-fixture-status"].label, "web-copy-correct")
        shareCard(12, in: app)
        XCTAssertEqual(try capturedURLs(app), expected)
    }
    func testResultAndJSONURLsOpenOnlyExplicitLinks() throws {
        let app = launch(["--web-url-links"]); ready(app)
        XCTAssertEqual(try capturedURLs(app), [])
        let text = app.textViews["archiveText-12"]
        for url in ["https://name.example/a", "https://summary.example/a"] {
            let link = text.links[url]; reveal(link, in: app); link.tap()
            waitForOpenedWebURL(url, app: app)
            XCTAssertEqual(try capturedURLs(app).last, url)
        }
        let disclosure = text.links["原文"]; reveal(disclosure, in: app); disclosure.tap()
        scrollWait(text, "value CONTAINS 'https://original.example/a'")
        let original = text.links["https://original.example/a"]; reveal(original, in: app); original.tap()
        waitForOpenedWebURL("https://original.example/a", app: app)
        XCTAssertEqual(try capturedURLs(app).count, 3)
        XCTAssertEqual(try capturedURLs(app).last, "https://original.example/a")
        XCTAssertFalse(text.links["example.com"].exists)
        XCTAssertFalse(text.links["0800-388-100"].exists)
        let json = app.buttons["modelJSON-12"]; reveal(json, in: app); json.tap()
        let raw = app.textViews["modelJSONText"]
        XCTAssertTrue(raw.waitForExistence(timeout: 5))
        let before = raw.value as? String
        raw.links["https://json.example/a"].tap()
        XCTAssertEqual(raw.value as? String, before)
        XCTAssertTrue((before ?? "").contains("0012345678905"))
        attach37(app, "explicit-web-json")
        app.buttons["closeModelJSON"].tap()
        waitForOpenedWebURL("https://json.example/a", app: app)
        XCTAssertEqual(try capturedURLs(app).last, "https://json.example/a")
        XCTAssertEqual(try capturedURLs(app).count, 4)
    }
    func testBarcodeURLFullHostAtMaximumTypeInDarkMode() throws {
        let app = launch(["--web-url-links", "--maximum-type", "--dark"]); ready(app)
        let link = app.descendants(matching: .any).matching(identifier: "archiveBarcode-12-0").firstMatch; reveal(link, in: app)
        XCTAssertEqual(link.label, "http://60.251.161.196/RegDegree/RegisterDegree.aspx")
        XCTAssertGreaterThanOrEqual(link.frame.height, 44)
        XCTAssertLessThanOrEqual(link.frame.maxX, app.frame.maxX)
        XCTAssertGreaterThanOrEqual(link.frame.minX, app.frame.minX)
        XCTAssertEqual(try capturedURLs(app), [])
        attach37(app, "explicit-web-maximum-type-dark")
        link.tap()
        XCTAssertEqual(try capturedURLs(app), [link.label])
    }
    func testLegacyResultURLsUseSameExplicitWebRule() throws {
        let app = launch(["--web-url-links", "--legacy-web-result"]); ready(app)
        XCTAssertEqual(try capturedURLs(app), [])
        for url in ["https://name.example/a", "https://summary.example/a", "https://original.example/a"] {
            let link = app.links[url]
            XCTAssertTrue(link.waitForExistence(timeout: 5)); link.tap()
            XCTAssertEqual(try capturedURLs(app).last, url)
        }
        XCTAssertEqual(try capturedURLs(app).count, 3)
        XCTAssertFalse(app.links["0012345678905"].exists)
        attach37(app, "explicit-web-legacy-result")
    }
    private func waitForOpenedWebURL(_ url: String, app: XCUIApplication) {
        // UITextView primary actions finish asynchronously after the tap gesture.
        let arrived = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            (try? capturedURLs(app).last) == url
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [arrived], timeout: 5), .completed)
    }
    private func capturedURLs(_ app: XCUIApplication) throws -> [String] {
        let value = try XCTUnwrap(app.staticTexts["c2-fixture-status"].value as? String)
        return try JSONDecoder().decode([String].self, from: Data(value.utf8))
    }
    func testReferenceLinksAreBlueAndOpenCorrectCardInLightMode() throws {
        try checkReferenceLinkColor([])
    }
    func testReferenceLinksAreBlueAndOpenCorrectCardInDarkMode() throws {
        try checkReferenceLinkColor(["--dark"])
    }
    private func checkReferenceLinkColor(_ appearance: [String]) throws {
        let app = launch(["--wiki-links", "--scroll-ui"] + appearance); ready(app)
        var samples: [[String: Any]] = []
        for sequence in [12, 11] {
            for identifier in ["googleSearch", "wikipedia"] {
                let link = app.descendants(matching: .any).matching(identifier: "\(identifier)-\(sequence)").firstMatch
                reveal(link, in: app)
                XCTAssertTrue(link.isHittable)
                let shot = link.screenshot()
                let attachment = XCTAttachment(screenshot: shot)
                attachment.name = "Build35-\(appearance.isEmpty ? "light" : "dark")-\(identifier)-\(sequence)"
                attachment.lifetime = .keepAlways; add(attachment)
                let image = try XCTUnwrap(shot.image.cgImage)
                let width = image.width, height = image.height
                var pixels = [UInt8](repeating: 0, count: width * height * 4)
                let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                var bluePixels = 0
                for offset in stride(from: 0, to: pixels.count, by: 4) {
                    let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
                    if b > 120 && b - r > 60 && b - g > 30 { bluePixels += 1 }
                }
                // Check the rendered link label itself, not a SwiftUI modifier
                // or a nearby control; black/white text cannot satisfy this.
                let before = try capturedURLs(app)
                link.tap()
                let after = try capturedURLs(app)
                let opened = Array(after.dropFirst(before.count))
                let expectedTitle = sequence == 12 ? "雨傘" : "剪刀"
                let routeCorrect: Bool
                if opened.count == 1, let url = URLComponents(string: opened[0]) {
                    if identifier == "googleSearch" {
                        routeCorrect = url.host == "www.google.com" && url.path == "/search" &&
                            url.queryItems?.first(where: { $0.name == "q" })?.value == expectedTitle
                    } else {
                        routeCorrect = url.host == "zh.wikipedia.org" && url.path == "/wiki/\(sequence == 12 ? "傘" : "剪刀")"
                    }
                } else { routeCorrect = false }
                samples.append(["identifier": "\(identifier)-\(sequence)", "bluePixels": bluePixels,
                    "width": width, "height": height, "actualOpenedURLs": opened, "exactlyOneCorrectURL": routeCorrect])
                XCTAssertTrue(app.staticTexts["scrollState"].label.contains("calls-0"))
            }
        }
        let report = XCTAttachment(data: try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        report.name = "Build35-reference-link-colors-\(appearance.isEmpty ? "light" : "dark")"
        report.lifetime = .keepAlways; add(report)
        let screen = XCTAttachment(screenshot: app.screenshot()); screen.name = "Build35-links-full-screen-\(appearance.isEmpty ? "light" : "dark")"; screen.lifetime = .keepAlways; add(screen)
        for sample in samples {
            XCTAssertGreaterThan(sample["bluePixels"] as! Int, 100, "Rendered link must remain blue: \(sample["identifier"]!)")
            XCTAssertTrue(sample["exactlyOneCorrectURL"] as! Bool, "Wrong or duplicate navigation: \(sample)")
        }
    }
    func testReferenceLinkWhitespaceBoundariesAndSwipeDeletion() throws {
        let app = launch(["--wiki-links", "--scroll-ui", "--deletion-ui"]); ready(app)
        let google = app.descendants(matching: .any).matching(identifier: "googleSearch-12").firstMatch
        let wiki = app.descendants(matching: .any).matching(identifier: "wikipedia-12").firstMatch
        let origin = app.coordinate(withNormalizedOffset: .zero)
        var probes: [[String: Any]] = []
        func probe(_ name: String, point: CGPoint) throws {
            let before = try capturedURLs(app)
            origin.withOffset(CGVector(dx: point.x, dy: point.y)).tap()
            let after = try capturedURLs(app)
            probes.append(["name": name, "point": [point.x, point.y],
                "googleFrame": [google.frame.minX,google.frame.minY,google.frame.width,google.frame.height],
                "wikiFrame": [wiki.frame.minX,wiki.frame.minY,wiki.frame.width,wiki.frame.height],
                "before": before, "opened": Array(after.dropFirst(before.count))])
        }
        let header = app.staticTexts["archiveRow-12"]
        reveal(header, in: app)
        let card = app.otherElements["archiveCard-12"]
        try probe("header-whitespace", point: CGPoint(x: card.frame.maxX - 72, y: header.frame.midY + 20))
        reveal(wiki, in: app)
        XCTAssertGreaterThan(wiki.frame.minY, google.frame.maxY)
        try probe("between-links", point: CGPoint(x: google.frame.midX, y: (google.frame.maxY + wiki.frame.minY) / 2))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Build35-whitespace-geometry-screen"; shot.lifetime = .keepAlways; add(shot)
        reveal(header, in: app)
        let beforeSwipe = try capturedURLs(app)
        swipeHistoryHeader(app, sequence: 12)
        let delete = app.buttons["刪除"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        let afterSwipe = try capturedURLs(app)
        probes.append(["name": "swipe", "opened": Array(afterSwipe.dropFirst(beforeSwipe.count))])
        delete.tap()
        deletionWait(app.staticTexts["deletionState"], "label == 'records-11-busy-false'")
        probes.append(["name": "tap-delete", "opened": Array(try capturedURLs(app).dropFirst(afterSwipe.count))])
        checkDeletionFiles(app, count: 11)
        let proof = XCTAttachment(data: try JSONSerialization.data(withJSONObject: probes, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        proof.name = "Build35-whitespace-and-swipe-opened-URLs"; proof.lifetime = .keepAlways; add(proof)
        for probe in probes {
            // Exact Build33 baseline dispatches Wiki for this point 5 pt above
            // its visible 44 pt frame. Preserve that existing touch boundary;
            // the actual empty header and swipe/delete must dispatch nothing.
            let expected = probe["name"] as? String == "between-links" ? ["https://zh.wikipedia.org/wiki/%E5%82%98"] : []
            XCTAssertEqual(probe["opened"] as? [String], expected, "Unexpected open from \(probe)")
        }
    }

}

extension CaptureUITests {
    private func deletionWait(_ element: XCUIElement, _ predicate: String) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)], timeout: 15), .completed)
    }
    private func openHistorySettings(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["設定"].tap()
        let button = app.buttons["clearAllHistory"].firstMatch
        for _ in 0..<8 {
            if button.exists, button.frame.height > 0, app.frame.contains(CGPoint(x: button.frame.midX, y: button.frame.midY)) { break }
            app.swipeUp()
        }
        XCTAssertTrue(button.exists)
        return button
    }
    private func swipeHistoryHeader(_ app: XCUIApplication, sequence: Int) {
        let row = app.staticTexts["archiveRow-\(sequence)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10)); XCTAssertTrue(row.isHittable)
        let list = historyList(in: app)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: list.frame.minX + list.frame.width * 0.92, dy: row.frame.midY))
        let end = origin.withOffset(CGVector(dx: list.frame.minX + list.frame.width * 0.02, dy: row.frame.midY))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
    private func checkDeletionFiles(_ app: XCUIApplication, count: Int) {
        app.buttons["inspectDeletionFiles"].tap()
        deletionWait(app.staticTexts["deletionFileStatus"], "label == 'passed-\(count)'")
    }
    func testHistoryDeletionControllerProtectionPersistenceAndLateReplies() {
        let app = launch(["--history-deletion-checks"])
        let result = app.staticTexts["historyDeletionChecksResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        deletionWait(result, "label != 'running'")
        XCTAssertTrue(result.label.hasPrefix("passed "), result.label)
    }
    func testHistoryFullSwipeOnlyRevealsDeleteAndTapPersistsAcrossRelaunch() {
        let app = launch(["--deletion-ui", "--scroll-ui"]); ready(app)
        let before = app.staticTexts["scrollState"].label
        swipeHistoryHeader(app, sequence: 12)
        let delete = app.buttons["刪除"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5)); XCTAssertTrue(delete.isHittable)
        XCTAssertEqual(app.staticTexts["deletionState"].label, "records-12-busy-false")
        XCTAssertEqual(app.staticTexts["scrollState"].label, before)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "history-swipe-red-delete-no-full-swipe"; shot.lifetime = .keepAlways; add(shot)
        delete.tap()
        deletionWait(app.staticTexts["deletionState"], "label == 'records-11-busy-false'")
        XCTAssertEqual(app.alerts.count, 0)
        checkDeletionFiles(app, count: 11)
        app.terminate(); app.launchArguments = ["--deletion-ui", "--scroll-ui", "--resume-history"]; app.launch(); ready(app)
        XCTAssertEqual(app.staticTexts["deletionState"].label, "records-11-busy-false")
        XCTAssertFalse(app.staticTexts["archiveRow-12"].exists)
        XCTAssertTrue(app.staticTexts["archiveRow-11"].isHittable)
        checkDeletionFiles(app, count: 11)
    }
    func testHistoryClearAllCancelConfirmEmptyAndRelaunch() {
        let app = launch(["--deletion-ui", "--scroll-ui", "--photo57-label"]); ready(app)
        let clear = openHistorySettings(app)
        clear.tap()
        let dialog = app.alerts["刪除全部 12 筆紀錄及來源圖片？"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "history-clear-confirmation"; shot.lifetime = .keepAlways; add(shot)
        dialog.buttons["取消"].tap()
        app.navigationBars["設定"].buttons["完成"].tap()
        checkDeletionFiles(app, count: 12)
        openHistorySettings(app).tap()
        XCTAssertTrue(dialog.waitForExistence(timeout: 5)); dialog.buttons["刪除全部"].firstMatch.tap()
        deletionWait(app.buttons["clearAllHistory"], "enabled == false")
        app.navigationBars["設定"].buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["尚無辨識紀錄"].waitForExistence(timeout: 5))
        checkDeletionFiles(app, count: 0)
        app.terminate(); app.launchArguments = ["--deletion-ui", "--scroll-ui", "--resume-history"]; app.launch(); ready(app)
        XCTAssertTrue(app.staticTexts["尚無辨識紀錄"].exists)
        checkDeletionFiles(app, count: 0)
        app.buttons["continueCapture"].tap(); app.buttons["feedFrames"].tap()
        deletionWait(app.staticTexts["deletionState"], "label == 'records-1-busy-true'")
        app.buttons["completeReply"].tap()
        deletionWait(app.staticTexts["deletionState"], "label == 'records-1-busy-false'")
        checkDeletionFiles(app, count: 1)
    }
    func testSettings59Light() { checkSettings59([]) }
    func testSettings59Dark() { checkSettings59(["--dark"]) }
    func testSettings59MaximumLight() { checkSettings59(["--maximum-type"]) }
    func testSettings59MaximumDark() { checkSettings59(["--maximum-type", "--dark"]) }
    private func checkSettings59(_ flags: [String]) {
        let app = launch(flags); ready(app); app.buttons["設定"].tap()
        func revealSetting(_ element: XCUIElement) {
            for _ in 0..<20 {
                if element.exists && element.isHittable { return }
                app.swipeUp()
            }
            XCTAssertTrue(element.exists && element.isHittable)
        }
        var heights: [CGFloat] = [], leftEdges: [CGFloat] = []
        let rows = [("Local", "本機紀錄"), ("Photo", "相簿圖片"), ("Wikipedia", "維基百科"), ("Google", "Google 搜尋")]
        for (key, title) in rows {
            let heading = app.staticTexts["settings" + key + "Heading"]
            revealSetting(heading); XCTAssertEqual(heading.label, title)
            heights.append(heading.frame.height); leftEdges.append(heading.frame.minX)
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "settings59-" + key + "-" + (flags.isEmpty ? "light" : flags.joined(separator: "-")); shot.lifetime = .keepAlways; add(shot)
            if key == "Photo" {
                let text = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "相簿原圖不會被修改；刪除辨識紀錄也不會刪除相簿中的原圖。")).firstMatch
                revealSetting(text); XCTAssertTrue(text.exists)
            } else if key == "Wikipedia" {
                let text = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "再將第一階段辨識資料與候選頁面摘錄送至 OpenAI")).firstMatch
                revealSetting(text); XCTAssertTrue(text.exists)
            } else if key == "Google" {
                let text = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Google 搜尋只會在你點選連結後開啟")).firstMatch
                revealSetting(text); XCTAssertTrue(text.exists)
                let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "settings59-google-description-" + flags.joined(separator: "-"); shot.lifetime = .keepAlways; add(shot)
            }
        }
        for height in heights { XCTAssertEqual(height, heights[0], accuracy: 2) }
        for x in leftEdges { XCTAssertEqual(x, leftEdges[0], accuracy: 2) }
    }
    func testHistoryEmptyListDisablesClearAll() {
        let app = launch(["--deletion-ui", "--empty-history"]); ready(app)
        XCTAssertTrue(app.staticTexts["尚無辨識紀錄"].exists)
        XCTAssertFalse(openHistorySettings(app).isEnabled)
        XCTAssertEqual(app.alerts.count, 0)
        app.navigationBars["設定"].buttons["完成"].tap()
        checkDeletionFiles(app, count: 0)
    }
    func testHistoryPendingRowHidesDeleteAndSettingsDisablesClearAll() {
        let app = launch(["--deletion-ui", "--scroll-ui"]); ready(app)
        app.buttons["continueCapture"].tap(); app.buttons["feedFrames"].tap()
        deletionWait(app.staticTexts["deletionState"], "label == 'records-13-busy-true'")
        swipeHistoryHeader(app, sequence: 13)
        XCTAssertFalse(app.buttons["刪除"].exists)
        XCTAssertEqual(app.staticTexts["deletionState"].label, "records-13-busy-true")
        XCTAssertFalse(openHistorySettings(app).isEnabled)
        XCTAssertEqual(app.staticTexts["clearHistoryBlockedReason"].label, "辨識進行中，完成後才能清除全部。")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "history-clear-blocked-during-recognition"; shot.lifetime = .keepAlways; add(shot)
        app.navigationBars["設定"].buttons["完成"].tap()
        app.buttons["completeReply"].tap()
        deletionWait(app.staticTexts["deletionState"], "label == 'records-13-busy-false'")
        checkDeletionFiles(app, count: 13)
    }
}

extension CaptureUITests {
    private func scrollWait(_ element: XCUIElement, _ predicate: String, timeout: TimeInterval = 15) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: timeout), .completed)
    }
    private func assertOnePending(_ app: XCUIApplication, sequence: Int) {
        let row = app.staticTexts["archiveRow-\(sequence)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        scrollWait(row, "hittable == true")
        let thumbnail = app.descendants(matching: .any).matching(identifier: "archiveCard-\(sequence)").firstMatch.buttons["recognitionSourceThumbnail"]
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 10))
        XCTAssertTrue(thumbnail.isHittable)
        XCTAssertEqual(app.buttons["continueCapture"].label, "辨識中")
        XCTAssertFalse(app.staticTexts["archivePending-\(sequence)"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == '辨識中'")).count, 1)
    }
    func testScrollCollapseControllerStatesAndInflightPersistence() {
        let app = launch(["--scroll-collapse-checks"])
        let result = app.staticTexts["scrollCollapseResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        scrollWait(result, "label != 'running'", timeout: 60)
        XCTAssertTrue(result.label.hasPrefix("passed "), result.label)
    }
    func testSustainedBlackShowsClosedPreviewAndRequiresExplicitReopen() {
        let app = launch(["--scroll-ui", "--darkness-ui"]); ready(app)
        app.buttons["continueCapture"].tap(); app.buttons["blackCamera"].tap()
        let notice = app.staticTexts["cameraDarknessClosed"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10)); XCTAssertTrue(notice.isHittable)
        XCTAssertEqual(notice.label, "畫面持續全黑，相機已關閉")
        XCTAssertEqual(app.buttons["continueCapture"].label, "開始辨識")
        XCTAssertTrue(app.staticTexts["scrollState"].label.contains("calls-0"))
        XCUIDevice.shared.press(.home); app.activate()
        scrollWait(notice, "hittable == true")
        XCTAssertTrue(app.staticTexts["scrollState"].label.contains("camera-1-"))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "black-camera-closed"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["continueCapture"].tap()
        XCTAssertFalse(notice.exists)
        XCTAssertEqual(app.buttons["continueCapture"].label, "等待停穩 1 秒")
        XCTAssertTrue(app.staticTexts["scrollState"].label.contains("calls-0"))
    }
    func testManualScrollFromMiddleToTopReopensWithoutSecondGesture() { checkManualTop(coasting: false) }
    func testReturnToLatestKeepsCameraCollapsedUntilNewGesture() { checkReturnToLatest([]) }
    func testReturnToLatestMaximumTypeDarkReduceMotion() { checkReturnToLatest(["--maximum-type", "--dark", "--reduce-motion"]) }
    func testLatestShortcutHiddenWhileFirstCardStillAtTop() {
        let app = launch(["--scroll-ui"]); ready(app)
        let list = historyList(in: app), state = app.staticTexts["scrollState"]
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -40)))
        scrollWait(state, "label CONTAINS 'collapsed-true'")
        let firstCard = app.descendants(matching: .any).matching(identifier: "archiveCard-12").firstMatch
        XCTAssertLessThan(firstCard.frame.minY, list.frame.minY)
        XCTAssertGreaterThan(firstCard.frame.maxY, list.frame.minY + 8)
        XCTAssertFalse(app.buttons["returnToLatest"].exists)
        XCTAssertTrue(state.label.contains("camera-1-"), state.label)
        XCTAssertTrue(state.label.contains("calls-0"), state.label)
    }
    private func checkReturnToLatest(_ args: [String]) {
        let app = launch(["--scroll-ui"] + args); ready(app)
        let list = historyList(in: app), state = app.staticTexts["scrollState"]
        let button = app.buttons["returnToLatest"]
        XCTAssertFalse(button.exists)
        list.swipeUp(); scrollWait(state, "label CONTAINS 'collapsed-true'")
        for _ in 0..<4 where !button.isHittable { list.swipeUp() }
        XCTAssertTrue(button.isHittable)
        XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        XCTAssertGreaterThan(button.frame.midX, list.frame.midX)
        XCTAssertGreaterThan(button.frame.midY, list.frame.midY)
        XCTAssertFalse(app.staticTexts["archiveRow-12"].isHittable)
        let before = state.label
        let visibleShot = XCTAttachment(screenshot: app.screenshot())
        visibleShot.name = "return-to-latest-visible-" + args.joined(separator: "-")
        visibleShot.lifetime = .keepAlways; add(visibleShot)
        button.tap()
        scrollWait(app.staticTexts["archiveRow-12"], "hittable == true")
        XCTAssertEqual(state.label, before)
        XCTAssertFalse(button.exists)
        // Later frame delivery cannot start the camera or capture. Wait for
        // any delayed scroll/layout work before asserting.
        app.buttons["feedFrames"].tap()
        let unexpected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'collapsed-false'"), object: state)
        unexpected.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unexpected], timeout: 1), .completed)
        XCTAssertEqual(state.label, before)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "return-to-latest-collapsed-" + args.joined(separator: "-"); shot.lifetime = .keepAlways; add(shot)
        list.swipeDown()
        scrollWait(state, "label CONTAINS 'collapsed-false'")
        XCTAssertTrue(state.label.contains("camera-2-"), state.label)
        XCTAssertTrue(state.label.contains("calls-0"), state.label)
        XCTAssertEqual(app.buttons["continueCapture"].label, "開始辨識")
        XCTAssertFalse(button.exists)
        app.buttons["feedFrames"].tap()
        XCTAssertTrue(state.label.contains("calls-0"), state.label)
    }
    func testReturnToLatestWhileBusyDoesNotReopenWhenReplyArrives() {
        let app = launch(["--scroll-ui"]); ready(app)
        app.buttons["continueCapture"].tap(); app.buttons["feedFrames"].tap()
        assertOnePending(app, sequence: 13)
        let list = historyList(in: app), state = app.staticTexts["scrollState"]
        list.swipeUp(); scrollWait(state, "label CONTAINS 'collapsed-true'")
        let button = app.buttons["returnToLatest"]
        for _ in 0..<4 where !button.isHittable { list.swipeUp() }
        XCTAssertTrue(button.isHittable); button.tap()
        assertOnePending(app, sequence: 13)
        XCTAssertTrue(state.label.contains("camera-1-"), state.label)
        list.swipeDown() // busy gesture cannot queue a reopen after completion
        app.buttons["completeReply"].tap(); scrollWait(app.buttons["continueCapture"], "enabled == true")
        XCTAssertTrue(state.label.contains("collapsed-true"), state.label)
        XCTAssertTrue(state.label.contains("camera-1-"), state.label)
        XCTAssertTrue(state.label.contains("calls-1"), state.label)
        XCTAssertTrue(app.staticTexts["archiveRow-13"].isHittable)
        list.swipeDown(); scrollWait(state, "label CONTAINS 'collapsed-false'")
        XCTAssertTrue(state.label.contains("camera-2-"), state.label)
        XCTAssertTrue(state.label.contains("calls-1"), state.label)
    }
    func testManualScrollDecelerationToTopReopensOnlyPreview() { checkManualTop(coasting: true) }
    private func checkManualTop(coasting: Bool) {
        let app = launch(["--scroll-ui"]); ready(app)
        let list = historyList(in: app), state = app.staticTexts["scrollState"]
        let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        from.press(forDuration: 0.1, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -180)))
        scrollWait(state, "label CONTAINS 'collapsed-true'")
        XCTAssertFalse(app.staticTexts["archiveRow-12"].isHittable)
        // Start below the top. Exactly one following user gesture must reopen.
        if coasting { list.swipeDown(velocity: .fast) }
        else {
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 500)))
        }
        scrollWait(state, "label CONTAINS 'collapsed-false'")
        XCTAssertTrue(state.label.contains("camera-2-"), state.label)
        XCTAssertTrue(state.label.contains("calls-0"), state.label)
        XCTAssertEqual(app.buttons["continueCapture"].label, "開始辨識")
        app.buttons["feedFrames"].tap()
        XCTAssertTrue(state.label.contains("calls-0"), state.label)
        XCTAssertTrue(app.staticTexts["archiveRow-12"].isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = coasting ? "manual-deceleration-top-preview" : "manual-drag-top-preview"; shot.lifetime = .keepAlways; add(shot)
        list.swipeUp(); scrollWait(state, "label CONTAINS 'collapsed-true'")
        XCTAssertTrue(state.label.contains("calls-0"), state.label)
    }
    func testProgrammaticPendingScrollToTopDoesNotReopenCollapsedCamera() {
        let app = launch(["--scroll-ui"]); ready(app)
        let list = historyList(in: app), state = app.staticTexts["scrollState"]
        list.swipeUp(); scrollWait(state, "label CONTAINS 'collapsed-true'")
        app.buttons["selectSyntheticPhoto"].tap()
        assertOnePending(app, sequence: 13)
        XCTAssertTrue(state.label.contains("collapsed-true"), state.label)
        // A user pull while busy cannot interrupt the photo or queue an opening.
        list.swipeDown()
        XCTAssertTrue(state.label.contains("collapsed-true"), state.label)
        app.buttons["completeReply"].tap(); scrollWait(app.buttons["continueCapture"], "enabled == true")
        XCTAssertTrue(state.label.contains("collapsed-true"), state.label)
        XCTAssertTrue(state.label.contains("camera-1-"), state.label)
        XCTAssertTrue(state.label.contains("calls-1"), state.label)
    }
    func testFirstAndSecondPendingThumbnailVisibleWithoutCollapsing() {
        checkPendingVisibility([])
    }
    func testPendingThumbnailMaximumTypeReduceMotion() {
        checkPendingVisibility(["--maximum-type", "--dark", "--reduce-motion"])
    }
    private func checkPendingVisibility(_ args: [String]) {
        let app = launch(["--empty-history", "--scroll-ui"] + args); ready(app)
        for sequence in 1...2 {
            app.buttons["continueCapture"].tap(); app.buttons["feedFrames"].tap()
            assertOnePending(app, sequence: sequence)
            XCTAssertTrue(app.staticTexts["scrollState"].label.contains("collapsed-false"))
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "pending-\(sequence)-" + args.joined(separator: "-"); shot.lifetime = .keepAlways; add(shot)
            app.buttons["completeReply"].tap()
            scrollWait(app.buttons["continueCapture"], "enabled == true")
            XCTAssertTrue(app.staticTexts["archiveRow-\(sequence)"].isHittable)
            XCTAssertEqual(app.staticTexts.matching(identifier: "archiveRow-\(sequence)").count, 1)
        }
        XCTAssertFalse(app.staticTexts["archiveRow-3"].exists)
    }
    func testManualScrollCollapsesAndCompletionKeepsReadingPosition() { checkReadingPosition([]) }
    func testLongReplyKeepsReadingPosition() { checkReadingPosition(["--preview-stability"]) }
    private func checkReadingPosition(_ args: [String]) {
        let app = launch(["--scroll-ui"] + args); ready(app)
        app.buttons["continueCapture"].tap(); app.buttons["feedFrames"].tap()
        assertOnePending(app, sequence: 13)
        let before = historyList(in: app).frame.height
        let anchor = app.staticTexts["archiveRow-11"]
        reveal(anchor, in: app)
        scrollWait(app.staticTexts["scrollState"], "label CONTAINS 'collapsed-true'")
        XCTAssertGreaterThan(historyList(in: app).frame.height, before + 200)
        XCTAssertTrue(app.buttons["continueCapture"].isHittable)
        XCTAssertEqual(app.buttons["continueCapture"].label, "辨識中")
        let y = anchor.frame.midY
        app.buttons["completeReply"].tap()
        scrollWait(app.buttons["continueCapture"], "enabled == true")
        XCTAssertTrue(anchor.isHittable)
        let measurement = ["beforeY": Double(y), "afterY": Double(anchor.frame.midY), "difference": Double(abs(anchor.frame.midY - y))]
        let measured = XCTAttachment(data: try! JSONSerialization.data(withJSONObject: measurement), uniformTypeIdentifier: "public.json")
        measured.name = "reading-position-" + args.joined(separator: "-"); measured.lifetime = .keepAlways; add(measured)
        XCTAssertLessThan(abs(anchor.frame.midY - y), 35)
        XCTAssertFalse(app.staticTexts["合成第 1 張"].isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "collapsed-reading-completed"
        shot.lifetime = .keepAlways; add(shot)
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(app.staticTexts["scrollState"].label.contains("collapsed-true"))
        XCTAssertTrue(app.buttons["continueCapture"].isHittable)
        app.buttons["continueCapture"].tap()
        scrollWait(app.staticTexts["scrollState"], "label CONTAINS 'collapsed-false'")
        XCTAssertEqual(app.buttons["continueCapture"].label, "等待停穩 1 秒")
        app.buttons["feedFrames"].tap()
        assertOnePending(app, sequence: 14)
        XCTAssertTrue(app.staticTexts["scrollState"].label.contains("calls-2"))
        app.buttons["completeReply"].tap()
    }
    func testPhotoAndOriginalImageRetryUseSingleVisiblePendingCard() {
        let app = launch(["--empty-history", "--scroll-ui", "--progress-checks"]); ready(app)
        app.buttons["selectSyntheticPhoto"].tap()
        XCTAssertFalse(app.buttons["recognizeSelectedPhoto"].exists)
        XCTAssertFalse(app.buttons["returnToCamera"].exists)
        assertOnePending(app, sequence: 1)
        app.buttons["failReply"].tap()
        scrollWait(app.buttons["continueCapture"], "enabled == true")
        let retry = app.buttons["retryImage-1"]; reveal(retry, in: app); retry.tap()
        assertOnePending(app, sequence: 1)
        XCTAssertEqual(app.staticTexts.matching(identifier: "archiveRow-1").count, 1)
        XCTAssertFalse(app.staticTexts["archiveRow-2"].exists)
        app.buttons["completeReply"].tap()
        scrollWait(app.buttons["continueCapture"], "enabled == true")
        XCTAssertTrue(app.staticTexts["archiveRow-1"].isHittable)
        XCTAssertTrue(app.staticTexts["scrollState"].label.contains("calls-2"))
    }
}

@MainActor final class CaptureUITests: XCTestCase {
    func historyList(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "recognitionArchiveList").firstMatch
    }
    func launch(_ args: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = args; app.launch(); return app
    }
    func ready(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["c2-fixture-status"].waitForExistence(timeout:20))
        let expectation = XCTNSPredicateExpectation(predicate:NSPredicate(format:"label BEGINSWITH 'ready-'"),object:app.staticTexts["c2-fixture-status"])
        XCTAssertEqual(XCTWaiter.wait(for:[expectation],timeout:20),.completed)
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let list = historyList(in: app)
        for _ in 0..<16 {
            let viewport = list.frame.insetBy(dx: 0, dy: 8)
            let target = element.exists ? element.frame : .zero
            if element.isHittable && viewport.contains(CGPoint(x: target.midX, y: target.midY)) { return }
            let targetIsAbove = !target.isEmpty && target.midY < viewport.midY
            let start: CGFloat = targetIsAbove ? 0.35 : 0.75
            let end: CGFloat = targetIsAbove ? 0.55 : 0.55
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: start))
                .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: end)))
        }
        XCTFail("Requested card content did not become reachable by scrolling")
    }
    func testWaitingIndicatorLightAnimationAndLifecycle() { checkWaitingIndicator([]) }
    func testBarcodeEvidenceReachesActualRequestAndSurvivesRetry() {
        let app = launch(["--barcode-evidence-checks"])
        let result = app.staticTexts["barcode-evidence-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != 'running'"), object: result)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 40), .completed)
        XCTAssertTrue(result.label.hasPrefix("passed "), result.label)
    }
    func testFocusSelectionPreservesImageAndWaitsUntilQualifiedOrStopped() {
        let app = launch(["--focus-selection-checks"])
        let result = app.staticTexts["focusSelectionResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 30))
        scrollWait(result, "label != 'running'", timeout: 60)
        XCTAssertEqual(result.label, "focus-selection-passed-46")
    }
    func testPhotoAutomaticPendingNormalType() { checkPhotoAutomaticPending([]) }
    func testFocusHintLight() { checkFocusHint([]) }
    func testFocusHintDark() { checkFocusHint(["--dark"]) }
    func testFocusHintMaximumTypeLight() { checkFocusHint(["--maximum-type"]) }
    func testFocusHintMaximumTypeDark() { checkFocusHint(["--maximum-type", "--dark"]) }
    private func checkFocusHint(_ args: [String]) {
        let app = launch(["--focus-hint-preview", "--production-layout"] + args)
        let notice = app.staticTexts["captureActionNotice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 20))
        XCTAssertEqual(notice.label, "正在等待對焦，請將手機稍微拉遠，停穩 1 秒後會自動辨識一張。")
        let preview = app.descendants(matching: .any).matching(identifier: "singleCapturePreview").firstMatch
        let before = preview.frame
        XCTAssertTrue(app.buttons["continueCapture"].isHittable)
        XCTAssertTrue(app.buttons["choosePhoto"].isHittable)
        XCTAssertGreaterThanOrEqual(notice.frame.height, args.contains("--maximum-type") ? 70 : 18)
        XCTAssertGreaterThanOrEqual(notice.frame.minY, app.buttons["choosePhoto"].frame.maxY)
        let noticeViewport = args.contains("--maximum-type") ? app.scrollViews["captureNoticeScroll"] : notice
        XCTAssertLessThanOrEqual(noticeViewport.frame.maxY, app.frame.maxY)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "focus-hint-" + (args.isEmpty ? "light" : args.joined(separator: "-")); shot.lifetime = .keepAlways; add(shot)
        if args.contains("--maximum-type") {
            noticeViewport.swipeUp()
            let bottom = XCTAttachment(screenshot: app.screenshot()); bottom.name = "focus-hint-end-" + args.joined(separator: "-"); bottom.lifetime = .keepAlways; add(bottom)
            XCTAssertLessThanOrEqual(notice.frame.maxY, noticeViewport.frame.maxY + 2)
        }
        XCTAssertFalse(app.buttons["continueCapture"].isEnabled)
        XCTAssertFalse(app.buttons["choosePhoto"].isEnabled)
        XCTAssertTrue(app.buttons["cancelCapture"].isHittable)
        // The dedicated test phone has a 34-point bottom safe area. Hittable
        // alone also passes when the lower half is clipped by the home area.
        XCTAssertLessThanOrEqual(app.buttons["cancelCapture"].frame.maxY, app.frame.maxY - 34)
        app.buttons["cancelCapture"].tap()
        XCTAssertFalse(notice.exists)
        XCTAssertTrue(app.buttons["continueCapture"].isEnabled)
        app.buttons["continueCapture"].tap()
        let waiting = app.staticTexts["captureWaitingGuidance"]
        XCTAssertTrue(waiting.waitForExistence(timeout: 5))
        XCTAssertTrue(waiting.label.contains("保持") && !waiting.label.contains("再按"))
        XCTAssertLessThanOrEqual(app.buttons["cancelCapture"].frame.maxY, app.frame.maxY - 34)
        XCTAssertEqual(preview.frame.width, before.width, accuracy: 2)
        XCTAssertEqual(preview.frame.height, before.height, accuracy: 2)
    }
    func testPhotoAutomaticPendingMaximumType() { checkPhotoAutomaticPending(["--maximum-type"]) }
    func testPhotoAutomaticPendingNarrowMaximumType() { checkPhotoAutomaticPending(["--maximum-type", "--narrow-actions"]) }
    private func checkPhotoAutomaticPending(_ args: [String]) {
        let app = launch(["--photo-preview", "--production-layout"] + args)
        XCTAssertTrue(app.images["singleCaptureFrozenImage"].waitForExistence(timeout: 20))
        let start = app.buttons["continueCapture"]
        XCTAssertTrue(start.isHittable)
        XCTAssertTrue(app.buttons["choosePhoto"].isHittable)
        XCTAssertFalse(app.buttons["returnToCamera"].exists)
        XCTAssertFalse(app.buttons["recognizeSelectedPhoto"].exists)
        XCTAssertEqual(start.label, "辨識中")
        assertActionRow(start, app.buttons["choosePhoto"], in: app)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Photo-preview-" + (args.isEmpty ? "normal" : args.joined(separator: "-"))
        shot.lifetime = .keepAlways; add(shot)
    }
    func testPhotoImportAutomaticallySendsOnceAndKeepsSourceIdentity() {
        let app = launch(["--photo-import-checks"])
        let result = app.staticTexts["photoImportResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 30))
        XCTAssertTrue(result.label.hasPrefix("passed "), result.label)
    }
    func testOriginalImageRetryUsesSavedBytesAndIsolatesLateResponses() {
        let app = launch(["--original-image-retry-checks"])
        let result = app.staticTexts["originalImageRetryResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != 'running'"), object: result)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 30), .completed)
        XCTAssertTrue(result.label.hasPrefix("passed "), result.label)
    }
    func testBuildVersionReadsActualBundle() { checkBuildVersion([]) }
    func testBuildVersionMaximumType() { checkBuildVersion(["--maximum-type"]) }
    private func checkBuildVersion(_ args: [String]) {
        let app = launch(args); ready(app)
        app.buttons["設定"].tap()
        let row = app.descendants(matching: .any).matching(identifier: "glanceBuildVersion").firstMatch
        for _ in 0..<10 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.isHittable)
        // Fixture metadata deliberately differs from production; catches hard-coded app versions.
        XCTAssertTrue(row.label.contains("7.8.9（321）") || (row.value as? String)?.contains("7.8.9（321）") == true || app.staticTexts["7.8.9（321）"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Actual-bundle-version-" + (args.isEmpty ? "normal" : "maximum")
        shot.lifetime = .keepAlways; add(shot)
    }
    func testActualThreeRecognitionStatesLight() { checkActualThreeStates([]) }
    func testActualThreeRecognitionStatesMaximum() { checkActualThreeStates(["--maximum-type"]) }
    func testActionRowNarrowStates() { checkActualThreeStates(["--narrow-actions"]) }
    func testActionRowNarrowMaximumStates() { checkActualThreeStates(["--narrow-actions", "--maximum-type"]) }
    private func assertActionRow(_ left: XCUIElement, _ right: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(left.isHittable); XCTAssertTrue(right.isHittable)
        XCTAssertEqual(left.frame.width, right.frame.width, accuracy: 0.5)
        XCTAssertEqual(left.frame.height, right.frame.height, accuracy: 0.5)
        XCTAssertEqual(left.frame.minY, right.frame.minY, accuracy: 0.5)
        XCTAssertEqual(right.frame.minX - left.frame.maxX, 12, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(left.frame.width, 44 - 0.01)
        XCTAssertGreaterThanOrEqual(left.frame.height, 44 - 0.01)
        XCTAssertGreaterThanOrEqual(left.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(right.frame.maxX, app.frame.maxX)
        XCTAssertLessThanOrEqual(left.frame.maxY, app.frame.maxY)
    }
    private func checkActualThreeStates(_ args: [String]) {
        let app = launch(["--progress-checks", "--action-row-checks", "--empty-history"] + args); ready(app)
        let button = app.buttons["continueCapture"]
        let photo = app.buttons["choosePhoto"]
        let initial = button.frame
        func capture(_ state: String) {
            assertActionRow(button, photo, in: app)
            XCTAssertTrue(button.isHittable)
            XCTAssertEqual(button.frame.width, initial.width, accuracy: 0.5)
            XCTAssertEqual(button.frame.height, initial.height, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(button.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX)
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Actual-" + state + (args.isEmpty ? "-normal" : args.joined(separator: "-"))
            shot.lifetime = .keepAlways; add(shot)
        }
        XCTAssertEqual(app.staticTexts["actionRowCalls"].label, "calls-0")
        XCTAssertTrue(button.isEnabled && photo.isEnabled)
        capture("ready"); button.tap()
        XCTAssertEqual(button.label, "等待停穩 1 秒"); capture("acquiring")
        XCTAssertFalse(button.isEnabled); XCTAssertFalse(photo.isEnabled)
        XCTAssertEqual(app.staticTexts["actionRowCalls"].label, "calls-0")
        app.buttons["feedFrames"].tap()
        XCTAssertTrue(app.staticTexts["archiveRow-1"].waitForExistence(timeout: 10)); capture("pending")
        XCTAssertEqual(button.label, "辨識中")
        XCTAssertFalse(button.isEnabled); XCTAssertFalse(photo.isEnabled)
        XCTAssertEqual(app.staticTexts["actionRowCalls"].label, "calls-1")
        app.buttons["cancelReply"].tap()
    }
    func testPhotoAutoSendThenPickerCancellationDoesNotResend() {
        let app = launch(["--photo-preview", "--empty-history", "--progress-checks", "--action-row-checks"]); ready(app)
        let start = app.buttons["continueCapture"], photo = app.buttons["choosePhoto"]
        XCTAssertTrue(app.images["singleCaptureFrozenImage"].waitForExistence(timeout: 10))
        assertActionRow(start, photo, in: app)
        XCTAssertEqual(start.label, "辨識中")
        XCTAssertFalse(app.buttons["returnToCamera"].exists)
        XCTAssertFalse(app.buttons["recognizeSelectedPhoto"].exists)
        XCTAssertEqual(app.staticTexts["actionRowCalls"].label, "calls-1")
        app.buttons["completeReply"].tap()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: start)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
        photo.tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消", "Close", "關閉"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10)); cancel.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 10)); XCTAssertTrue(start.isEnabled)
        XCTAssertEqual(app.staticTexts["actionRowCalls"].label, "calls-1")
        start.tap()
        XCTAssertEqual(start.label, "等待停穩 1 秒")
        XCTAssertEqual(app.staticTexts["actionRowCalls"].label, "calls-1")
    }
    func testThreeRecognitionStatesComparisonScreenshots() {
        for args in [[String](), ["--dark"], ["--maximum-type", "--dark"]] {
            let app = launch(["--progress-layout", "--reduce-motion"] + args)
            XCTAssertTrue(app.buttons["acquiringButton"].waitForExistence(timeout: 10))
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Three-states-" + (args.isEmpty ? "light" : args.joined(separator: "-"))
            shot.lifetime = .keepAlways; add(shot)
            app.terminate()
        }
    }
    func testWaitingIndicatorDarkAnimationAndLifecycle() { checkWaitingIndicator(["--dark"]) }
    func testWaitingIndicatorReducedMotionIsStatic() { checkWaitingIndicator(["--reduce-motion"]) }
    func testWaitingIndicatorMaximumTextFits() { checkWaitingIndicator(["--maximum-type", "--dark", "--reduce-motion"]) }
    private func checkWaitingIndicator(_ args: [String]) {
        let app = launch(["--progress-layout"] + args)
        let button = app.buttons["progressButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertEqual(button.label, "辨識中")
        XCTAssertFalse(button.isEnabled)
        let ready = app.buttons["readyButton"]
        XCTAssertEqual(ready.frame.width, button.frame.width, accuracy: 0.5, "Ready and pending outer widths must match")
        XCTAssertEqual(ready.frame.height, button.frame.height, accuracy: 0.5)
        let acquiring = app.buttons["acquiringButton"]
        XCTAssertEqual(ready.frame.width, acquiring.frame.width, accuracy: 0.5, "All three outer widths must match")
        XCTAssertEqual(ready.frame.height, acquiring.frame.height, accuracy: 0.5)
        let card = app.staticTexts["progressCard"]
        XCTAssertEqual(card.label, "辨識中") // Dots have no separate accessibility speech.
        let spokenLabels = card.descendants(matching: .any).allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }
        XCTAssertTrue(spokenLabels.allSatisfy { $0 == "辨識中" }, "Decorative dots must not expose changing labels: \(spokenLabels)")
        XCTAssertLessThanOrEqual(button.frame.width, app.frame.width)
        XCTAssertGreaterThan(button.frame.height, 30)
        let frame = button.frame
        var samples: [Data] = []
        for turn in 0..<5 {
            samples.append(button.screenshot().pngRepresentation)
            XCTAssertEqual(button.frame, frame, "Animation must not move or resize the label")
            Thread.sleep(forTimeInterval: 0.17 + Double(turn) * 0.03)
        }
        if args.contains("--reduce-motion") {
            XCTAssertTrue(samples.dropFirst().allSatisfy { $0 == samples[0] }, "Reduced motion must remain visually static")
        } else {
            XCTAssertTrue(samples.dropFirst().contains { $0 != samples[0] }, "Pending dots must visibly advance")
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Waiting-" + (args.isEmpty ? "light" : args.joined(separator: "-"))
        shot.lifetime = .keepAlways; add(shot)
        app.buttons["toggleProgressLifecycle"].tap()
        XCTAssertEqual(app.staticTexts["progressLifecycle"].label, "inactive")
        let inactive = button.screenshot().pngRepresentation
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(button.screenshot().pngRepresentation, inactive, "Inactive scene must stop dot updates")
    }
    func testWaitingEndsOnSuccessFailureAndCancellation() {
        let app = launch(["--progress-checks", "--empty-history"]); ready(app)
        for (index, completion) in ["completeReply", "failReply", "cancelReply"].enumerated() {
            let button = app.buttons["continueCapture"]
            XCTAssertEqual(button.label, "開始辨識")
            let readyWidth = button.frame.width
            button.tap()
            XCTAssertEqual(button.label, "等待停穩 1 秒")
            XCTAssertEqual(button.frame.width, readyWidth, accuracy: 0.5)
            app.buttons["feedFrames"].tap()
            let row = app.staticTexts["archiveRow-\(index + 1)"]
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            XCTAssertEqual(button.label, "辨識中")
            XCTAssertEqual(button.frame.width, readyWidth, accuracy: 0.5)
            XCTAssertFalse(button.isEnabled)
            app.buttons[completion].tap()
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: button)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
            XCTAssertEqual(button.label, "開始辨識")
            XCTAssertTrue(row.exists)
            XCTAssertFalse(app.staticTexts["archivePending-\(index + 1)"].exists)
            XCTAssertFalse(app.images["singleCaptureFrozenImage"].exists)
        }
        app.buttons["continueCapture"].tap(); app.buttons["feedFrames"].tap()
        XCTAssertTrue(app.staticTexts["archiveRow-4"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(app.staticTexts["archiveRow-4"].waitForExistence(timeout: 10))
        app.buttons["completeReply"].tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.staticTexts["archivePending-4"])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed)
    }
    func testPreviewRemainsLargeWithHistoryAcrossLifecycle() { checkPreviewStability(empty: false) }
    func testPreviewRemainsLargeWithoutHistoryAcrossLifecycle() { checkPreviewStability(empty: true) }
    private func checkPreviewStability(empty: Bool) {
        let app = launch(["--preview-stability"] + (empty ? ["--empty-history"] : [])); ready(app)
        continueAfterFailure = true
        let preview = app.descendants(matching: .any).matching(identifier: "singleCapturePreview").firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        var rows: [[String: Any]] = []
        func measure(_ state: String) {
            let frame = preview.frame
            rows.append(["state": state, "width": Double(frame.width), "height": Double(frame.height)])
            XCTAssertEqual(frame.width, frame.height, accuracy: 2, state)
            XCTAssertGreaterThanOrEqual(frame.width, 260, state)
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Preview-" + state
            shot.lifetime = .keepAlways; add(shot)
        }
        func waitReady() {
            let predicate = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["continueCapture"])
            XCTAssertEqual(XCTWaiter.wait(for: [predicate], timeout: 10), .completed)
        }
        XCTAssertEqual(app.buttons["continueCapture"].label, "開始辨識")
        measure("initial")
        app.buttons["continueCapture"].tap(); measure("acquiring")
        app.buttons["feedFrames"].tap()
        XCTAssertTrue(app.images["singleCaptureFrozenImage"].waitForExistence(timeout: 10)); measure("waiting")
        app.buttons["completeReply"].tap(); waitReady(); XCTAssertEqual(app.buttons["continueCapture"].label, "開始辨識"); measure("long-success")
        XCUIDevice.shared.press(.home); app.activate(); waitReady(); measure("foreground")
        app.buttons["continueCapture"].tap(); measure("continue")
        app.buttons["feedFrames"].tap()
        XCTAssertTrue(app.images["singleCaptureFrozenImage"].waitForExistence(timeout: 10)); measure("waiting-again")
        app.buttons["failReply"].tap(); waitReady(); measure("failure")
        XCUIDevice.shared.press(.home); app.activate(); waitReady(); measure("failure-foreground")
        let widths = rows.compactMap { $0["width"] as? Double }
        XCTAssertLessThanOrEqual((widths.max() ?? 0) - (widths.min() ?? 0), 2, "Preview must not follow row measurement or capture state")
        let data = try! JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .prettyPrinted])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = empty ? "preview-empty-history-measurements" : "preview-history-measurements"
        attachment.lifetime = .keepAlways; add(attachment)
    }
    func testWikipediaLifecycleWithMockTransport() {
        let app = launch(["--wiki-checks"])
        let result = app.staticTexts["c5-wiki-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'passed ' OR label BEGINSWITH 'FAILED '"), object: result)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 40), .completed)
        XCTAssertTrue(result.label.hasPrefix("passed "), result.label)
    }
    func testBarcodeGooglePipelineWithoutProductLookup() {
        let app = launch(["--product-checks"])
        let result = app.staticTexts["c7-product-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'passed ' OR label BEGINSWITH 'FAILED '"), object: result)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 45), .completed)
        XCTAssertEqual(result.label, "passed 11", result.label)
    }
    func testBarcodeOnlyGoogleWithoutRecognizedText() throws {
        let app = launch(["--barcode-only"]); ready(app)
        let link = app.descendants(matching: .any).matching(identifier: "googleSearch-12").firstMatch
        reveal(link, in: app)
        XCTAssertEqual(link.label, "Google 搜尋：3017620422003")
        link.tap(); XCTAssertEqual(app.staticTexts["c2-fixture-status"].label, "search-correct-12-calls-0")
        try assertGoogleURLWithoutLanguageFilter("3017620422003", in: app)
        // No first-stage answer: the existing whole-card share gate remains closed.
        let share = app.otherElements["archiveCard-12"].buttons["shareRecognitionResult"]
        XCTAssertTrue(share.exists)
        XCTAssertFalse(share.isEnabled)
        XCTAssertEqual(share.label, "完成辨識後可分享")
    }
    func testLegacyProductCardShowsOnlyGoogleAndWikiAfterReopen() throws {
        let app = launch(["--product-links"]); ready(app)
        let query = "雨傘 3017620422003"
        let first = app.descendants(matching: .any).matching(identifier: "googleSearch-12").firstMatch
        reveal(first, in: app)
        XCTAssertEqual(first.label, "Google 搜尋：" + query)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "productFacts-12").firstMatch.exists)
        XCTAssertFalse(app.links["內容：DbCL"].exists)
        first.tap(); XCTAssertEqual(app.staticTexts["c2-fixture-status"].label, "search-correct-12-calls-0")
        try assertGoogleURLWithoutLanguageFilter(query, in: app)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Google-barcode-no-OFF"; shot.lifetime = .keepAlways; add(shot)
        shareCard(12, in: app)
        app.terminate(); app.launchArguments = ["--product-links", "--expect-share-11", "--resume-history"]; app.launch(); ready(app)
        let second = app.descendants(matching: .any).matching(identifier: "googleSearch-11").firstMatch
        reveal(second, in: app)
        XCTAssertEqual(second.label, "Google 搜尋：剪刀 5901234123457")
        second.tap(); XCTAssertEqual(app.staticTexts["c2-fixture-status"].label, "search-correct-11-calls-0")
        try assertGoogleURLWithoutLanguageFilter("剪刀 5901234123457", in: app)
        shareCard(11, in: app)
    }
    func testWikipediaLinksUseCanonicalURLOfSelectedPersistedCard() {
        let app = launch(["--wiki-links"]); ready(app)
        let first = app.descendants(matching: .any).matching(identifier: "wikipedia-12").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5)); first.tap()
        XCTAssertEqual(app.staticTexts["c2-fixture-status"].label, "wiki-correct-12-calls-0")
        app.terminate(); app.launchArguments = ["--wiki-links", "--resume-history"]; app.launch(); ready(app)
        let second = app.descendants(matching: .any).matching(identifier: "wikipedia-11").firstMatch
        let list = historyList(in: app)
        for _ in 0..<8 {
            if second.isHittable { break }
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        }
        XCTAssertTrue(second.isHittable); second.tap()
        XCTAssertEqual(app.staticTexts["c2-fixture-status"].label, "wiki-correct-11-calls-0")
    }
    func testProductionControllerLifecycle() {
        let app = launch(["--controller-checks"])
        let result = app.staticTexts["c2-controller-result"]
        XCTAssertTrue(result.waitForExistence(timeout:10))
        let expectation = XCTNSPredicateExpectation(predicate:NSPredicate(format:"label BEGINSWITH 'passed '"),object:result)
        XCTAssertEqual(XCTWaiter.wait(for:[expectation],timeout:30),.completed,result.label)
    }
    func testRealVisionSourceBarcodeDecoding() {
        let app = launch(["--barcode-checks"])
        let result = app.staticTexts["c3-barcode-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'passed ' OR label BEGINSWITH 'FAILED '"), object: result)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 60), .completed)
        XCTAssertTrue(result.label.hasPrefix("passed "), result.label)
    }
    func testLargeSquarePreviewLeavesScrollableHistory() {
        let app = launch(); ready(app)
        let preview = app.descendants(matching: .any).matching(identifier: "singleCapturePreview").firstMatch
        let list = historyList(in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(preview.frame.height, 210)
        XCTAssertEqual(preview.frame.width, preview.frame.height, accuracy: 2)
        XCTAssertTrue(app.buttons["continueCapture"].isHittable)
        let first = app.otherElements["archiveCard-12"]
        let second = app.staticTexts["archiveRow-11"]
        XCTAssertTrue(first.exists)
        XCTAssertGreaterThan(list.frame.height, 140)
        reveal(second, in: app)
        XCTAssertTrue(second.isHittable)
        XCTAssertFalse(app.buttons["nextArchiveRecord"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "C3-adaptive-preview"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testPhoto57LabelKeepsDateAcrossReopenWithoutAddedTimeWords() {
        let app = launch(["--photo57-label"]); ready(app)
        let before = app.staticTexts["archiveTimestamp-12"].label
        XCTAssertNotNil(before.range(of: #"^相簿・ \d{4}/\d{2}/\d{2} \d{2}:\d{2}$"#, options: .regularExpression))
        XCTAssertFalse(before.contains("加入時間"))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "photo57-source-date"; shot.lifetime = .keepAlways; add(shot)
        app.terminate(); app.launchArguments = ["--resume-history"]; app.launch(); ready(app)
        XCTAssertEqual(app.staticTexts["archiveTimestamp-12"].label, before)
    }
    func testCaptureDateTimeIsStableAcrossReopen() {
        let app = launch(); ready(app)
        let timestamp = app.staticTexts["archiveTimestamp-12"]
        let before = timestamp.label
        XCTAssertNotNil(before.range(of: #"^\d{4}/\d{2}/\d{2} \d{2}:\d{2}$"#, options: .regularExpression))
        app.terminate(); app.launchArguments = ["--resume-history"]; app.launch(); ready(app)
        XCTAssertEqual(app.staticTexts["archiveTimestamp-12"].label, before)
    }
    func testGoogleSearchOpensOnlySelectedCardAfterTapAndRestart() throws {
        let app = launch(["--search-links"]); ready(app)
        XCTAssertEqual(app.staticTexts["c2-fixture-status"].label, "ready-12")
        let first = app.descendants(matching: .any).matching(identifier: "googleSearch-12").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertEqual(first.label, "Google 搜尋：Acme C++ & 測試 #12")
        XCTAssertGreaterThanOrEqual(first.frame.height, 44)
        reveal(first, in: app)
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        XCTAssertEqual(app.staticTexts["c2-fixture-status"].label, "search-correct-12-calls-0")
        try assertGoogleURLWithoutLanguageFilter("Acme C++ & 測試 #12", in: app)
        app.terminate(); app.launchArguments = ["--resume-history", "--search-links"]; app.launch(); ready(app)
        let list = historyList(in: app)
        let second = app.descendants(matching: .any).matching(identifier: "googleSearch-11").firstMatch
        reveal(second, in: app)
        XCTAssertTrue(second.isHittable)
        XCTAssertEqual(second.label, "Google 搜尋：Acme C++ & 測試 #11")
        second.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertEqual(app.staticTexts["c2-fixture-status"].label, "search-correct-11-calls-0")
        try assertGoogleURLWithoutLanguageFilter("Acme C++ & 測試 #11", in: app)
    }
    func testFallbackNameAndQRLinksShareAfterRestartWithoutAIReplay() {
        let app = launch(["--fallback-links"]); ready(app)
        XCTAssertEqual(app.staticTexts["c2-fixture-status"].label, "ready-12")
        let first = app.descendants(matching: .any).matching(identifier: "googleSearch-12").firstMatch
        reveal(first, in: app)
        XCTAssertEqual(first.label, "Google 搜尋：腹釋寧消化腸溶糖衣錠")
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        XCTAssertEqual(app.staticTexts["c2-fixture-status"].label, "search-correct-12-calls-0")
        shareCard(12, in: app)
        app.terminate(); app.launchArguments = ["--resume-history", "--fallback-links"]; app.launch(); ready(app)
        let second = app.descendants(matching: .any).matching(identifier: "googleSearch-11").firstMatch
        reveal(second, in: app)
        XCTAssertEqual(second.label, "Google 搜尋：腹釋寧消化")
        second.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        XCTAssertEqual(app.staticTexts["c2-fixture-status"].label, "search-correct-11-calls-0")
        shareCard(11, in: app)
    }
    func testUnifiedLinksAtNormalSize() { assertSearchRowLayout([]) }
    func testUnifiedLinksWrapWithinNarrowRow() { assertSearchRowLayout(["--narrow-row"]) }
    func testUnifiedLinksAtMaximumType() { assertSearchRowLayout(["--narrow-row", "--maximum-type"]) }
    func testUnifiedUnbrokenLinksAtMaximumType() { assertSearchRowLayout(["--narrow-row", "--maximum-type", "--unbroken-query"]) }
    private func assertSearchRowLayout(_ args: [String]) {
        let app = launch(["--search-row-layout"] + args)
        let google = app.staticTexts["googleReferenceLabel"]
        let wiki = app.staticTexts["wikiReferenceLabel"]
        XCTAssertTrue(google.waitForExistence(timeout: 5)); XCTAssertTrue(wiki.exists)
        let card = app.descendants(matching: .any).matching(identifier: "searchLayoutCard").firstMatch
        XCTAssertTrue(card.exists)
        let expected = args.contains("--unbroken-query") ? String(repeating: "ABCDEFGHIJ", count: 12) : "Acme C++ & 台灣高山烏龍茶 AB-001 精選系列 #12"
        XCTAssertEqual(google.label, "Google 搜尋：" + expected)
        XCTAssertEqual(wiki.label, "維基百科：" + expected + "（品牌）")
        XCTAssertEqual(google.frame.minX, wiki.frame.minX, accuracy: 1)
        XCTAssertEqual(google.frame.width, wiki.frame.width, accuracy: 1)
        XCTAssertGreaterThanOrEqual(wiki.frame.minY, google.frame.maxY + 9)
        for row in [google, wiki] {
            XCTAssertGreaterThanOrEqual(row.frame.minX, card.frame.minX + 11)
            XCTAssertLessThanOrEqual(row.frame.maxX, card.frame.maxX - 11)
            XCTAssertLessThanOrEqual(row.frame.maxY, card.frame.maxY - 11)
            XCTAssertGreaterThanOrEqual(row.frame.height, 44)
        }
        XCTAssertGreaterThanOrEqual(card.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(card.frame.maxX, app.frame.maxX)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Unified-links-" + (args.isEmpty ? "normal" : args.joined(separator: "-"))
        attachment.lifetime = .keepAlways; add(attachment)
    }
    func testLateWikiShareContainsLatestLinksAndSameImage() {
        let app = launch(["--share-links", "--delayed-wiki"]); ready(app)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "wikipedia-12").firstMatch.exists)
        app.buttons["finishWiki"].tap()
        let status = app.staticTexts["c2-fixture-status"]
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'wiki-ready-12'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 10), .completed)
        let wiki = app.descendants(matching: .any).matching(identifier: "wikipedia-12").firstMatch
        XCTAssertEqual(wiki.label, "維基百科：雨傘")
        XCTAssertFalse(wiki.label.contains("遮蔽"))
        shareCard(12, in: app)
    }
    func testHistoryShareKeepsSelectedLinksAfterReopen() {
        let app = launch(["--share-links", "--expect-share-11"]); ready(app)
        app.terminate(); app.launchArguments = ["--share-links", "--expect-share-11", "--resume-history"]; app.launch(); ready(app)
        shareCard(11, in: app)
    }
    private func assertGoogleURLWithoutLanguageFilter(_ query: String, in app: XCUIApplication) throws {
        let opened = try capturedURLs(app)
        XCTAssertEqual(opened.count, 1)
        let raw = try XCTUnwrap(opened.first)
        let url = try XCTUnwrap(URLComponents(string: raw))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "www.google.com")
        XCTAssertEqual(url.path, "/search")
        XCTAssertEqual(url.queryItems, [.init(name: "q", value: query), .init(name: "gl", value: "tw")])
        XCTAssertNil(url.fragment)
        XCTAssertFalse(raw.contains("+"))
        let evidence = XCTAttachment(string: raw)
        evidence.name = "google-without-language-filter-opened-url"
        evidence.lifetime = .keepAlways; add(evidence)
    }
    func testGoogleOnlyShareKeepsImageAndNoWiki() {
        let app = launch(["--search-links"]); ready(app)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "wikipedia-12").firstMatch.exists)
        shareCard(12, in: app)
    }
    func testDirectShareLongTextCancelAndReopenKeepsBothItems() {
        let app = launch(["--rich-share", "--long-share"]); ready(app)
        shareCard(12, in: app, rich: true)
        shareCard(12, in: app, rich: true)
        shareCard(11, in: app, rich: true)
    }
    func testNamedWikiShareUsesTraditionalLabelAndCanonicalURL() {
        let app = launch(["--rich-share"]); ready(app)
        let wiki = app.descendants(matching: .any).matching(identifier: "wikipedia-12").firstMatch
        reveal(wiki, in: app)
        XCTAssertEqual(wiki.label, "維基百科：樂事（品牌）")
        shareCard(12, in: app, rich: true)
    }
    func testNamedMixedLanguageGoogleSharePreservesOriginalAndImage() {
        let app = launch(["--rich-share"]); ready(app)
        shareCard(11, in: app, rich: true)
    }
    func testReportedGlassSampleRealVisionProvenance() {
        let app = launch(["--glass-barcode-checks"])
        let result = app.staticTexts["glassBarcodeResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 20))
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != 'loading'"), object: result)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 40), .completed)
        XCTAssertEqual(result.label, "passed 35")
    }
    func testReportedGlassSampleUIRichShareAndURLAfterReopen() {
        checkReportedSearchAndRichShare(["--glass-sample"], queries: [12: "玻璃杯 4713213242926", 11: "玻璃杯"])
    }
    func testReportedActeinAndJapaneseUIRichShareAfterReopen() {
        checkReportedSearchAndRichShare(["--actein-sample"], queries: [12: "Actein 顆粒", 11: "アクテイン顆粒"])
    }
    func testFallbackUIUsesEffectiveQueryInRichProviders() {
        checkReportedSearchAndRichShare(["--fallback-links", "--fallback-rich-share"], queries: [12: "腹釋寧消化腸溶糖衣錠", 11: "腹釋寧消化"])
    }
    private func checkReportedSearchAndRichShare(_ args: [String], queries: [Int: String]) {
        let app = launch(args); ready(app)
        for sequence in [12, 11] {
            if sequence == 11 { app.terminate(); app.launchArguments = args + ["--resume-history"]; app.launch(); ready(app) }
            let link = app.descendants(matching: .any).matching(identifier: "googleSearch-\(sequence)").firstMatch
            reveal(link, in: app)
            XCTAssertEqual(link.label, "Google 搜尋：" + queries[sequence]!)
            link.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
            XCTAssertEqual(app.staticTexts["c2-fixture-status"].label, "search-correct-\(sequence)-calls-0")
            shareCard(sequence, in: app, rich: true)
        }
    }
    func testObserveSystemCopyOfReportedGlassSample() throws {
        try observeCopy(["--glass-sample"], sequence: 12)
    }
    func testObserveSystemCopyOfQRFallback() throws {
        try observeCopy(["--fallback-links", "--fallback-rich-share"], sequence: 11)
    }
    func testMentholatumCopyIntoNativeReceivers() throws {
        try observeCopy(["--rich-share", "--paste-receivers"], sequence: 11)
    }
    func testNamedWikiCopyIntoNativeReceivers() throws {
        try observeCopy(["--rich-share", "--paste-receivers"], sequence: 12)
    }
    func testMarkdownPunctuationCopyIntoNativeReceivers() throws {
        try observeCopy(["--rich-share", "--paste-receivers", "--markdown-punctuation"], sequence: 12)
    }
    func testMarkdownLegacyCardCopyIntoNativeReceivers() throws {
        try observeCopy(["--rich-share", "--paste-receivers", "--legacy-rich-card"], sequence: 12)
    }
    func testMarkdownQRFallbackCopyIntoNativeReceivers() throws {
        try observeCopy(["--fallback-links", "--fallback-rich-share", "--paste-receivers"], sequence: 11)
    }
    func testMarkdownNameFallbackCopyIntoNativeReceivers() throws {
        try observeCopy(["--fallback-links", "--fallback-rich-share", "--paste-receivers"], sequence: 12)
    }
    func testPre9MentholatumCopyIntoNativeReceivers() throws {
        try observeCopy(["--rich-share", "--paste-receivers", "--legacy-copy-transport"], sequence: 11)
    }
    func testPre9WikiCopyIntoNativeReceivers() throws {
        try observeCopy(["--rich-share", "--paste-receivers", "--legacy-copy-transport"], sequence: 12)
    }
    func testExplicitCopyPrototypeMentholatumReceivers() throws {
        try observeCopy(["--rich-share", "--paste-receivers", "--explicit-copy-prototype"], sequence: 11)
    }
    func testExplicitCopyPrototypeLaysWikiReceivers() throws {
        try observeCopy(["--rich-share", "--paste-receivers", "--explicit-copy-prototype"], sequence: 12)
    }
    private func observeCopy(_ args: [String], sequence: Int) throws {
        let app = launch(args + ["--observe-copy"]); ready(app)
        if args.contains("--legacy-copy-transport") {
            try XCTSkipUnless(app.staticTexts["c2-fixture-status"].label.hasPrefix("ready-pre9-"), "Requires prepare-pre9-share-comparison.py fixture")
        }
        let share = app.otherElements["archiveCard-\(sequence)"].buttons["shareRecognitionResult"]
        reveal(share, in: app); share.tap()
        let status = app.staticTexts["c2-fixture-status"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", args.contains("--legacy-copy-transport") ? "share-pair-correct" : "rich-share-passed"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        let names = ["Copy", "拷貝", "複製", "复制"]
        let copy = names.flatMap { [app.cells[$0], app.buttons[$0]] }.first { $0.exists && $0.isHittable }
        guard let copy else {
            let tree = XCTAttachment(string: app.debugDescription); tree.name = "Synthetic-copy-sheet-tree"; tree.lifetime = .keepAlways; add(tree)
            XCTFail("System Copy action is unavailable in this synthetic sheet"); return
        }
        copy.tap()
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "copy-observed-\(sequence)"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 15), .completed)
    }
    private func shareCard(_ sequence: Int, in app: XCUIApplication, rich: Bool = false) {
        let card = app.otherElements["archiveCard-\(sequence)"]
        let share = card.buttons["shareRecognitionResult"]
        reveal(share, in: app)
        XCTAssertEqual(card.buttons.matching(identifier: "shareRecognitionResult").count, 1)
        share.tap()
        let status = app.staticTexts["c2-fixture-status"]
        let paired = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", rich ? "rich-share-passed" : "share-pair-correct"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [paired], timeout: 10), .completed)
        if rich {
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Build9-system-share-\(sequence)"; shot.lifetime = .keepAlways; add(shot)
        }
        let names = ["Close", "關閉", "Cancel", "取消", "UIActivityContentViewControllerCloseButton"]
        if let close = names.map({ app.buttons[$0] }).first(where: { $0.exists && $0.isHittable }) { close.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.15)).tap() }
        let cleaned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", rich ? "rich-share-clean" : "share-clean"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [cleaned], timeout: 10), .completed)
    }
    func testRequestPhotoFreezesThenLiveReturnsUnarmed() {
        let app = launch(); ready(app)
        XCTAssertFalse(app.images["singleCaptureFrozenImage"].exists)
        app.buttons["continueCapture"].tap(); app.buttons["feedFrames"].tap()
        let frozen = app.images["singleCaptureFrozenImage"]
        XCTAssertTrue(frozen.waitForExistence(timeout: 10))
        let requestID = frozen.value as? String
        XCTAssertNotNil(requestID)
        XCTAssertFalse(app.buttons["continueCapture"].isEnabled)
        app.buttons["feedFrames"].tap()
        XCTAssertEqual(frozen.value as? String, requestID)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Submitted-request-photo"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["completeReply"].tap()
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: frozen)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["continueCapture"].isEnabled)
        XCTAssertEqual(app.buttons["continueCapture"].label, "開始辨識")
        XCTAssertFalse(app.buttons["cancelCapture"].exists)
        XCTAssertFalse(app.staticTexts["archivePending-14"].exists)
    }
    func testSinglePendingCellCompletesWithoutAutomaticNextRequest() {
        let app=launch();ready(app)
        app.buttons["continueCapture"].tap();app.buttons["feedFrames"].tap()
        XCTAssertTrue(app.staticTexts["archiveRow-13"].waitForExistence(timeout:10))
        XCTAssertFalse(app.buttons["continueCapture"].isEnabled)
        app.buttons["completeReply"].tap()
        XCTAssertTrue(app.textViews["archiveText-13"].waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["continueCapture"].isEnabled)
        XCTAssertFalse(app.staticTexts["archivePending-14"].exists)
        let attachment=XCTAttachment(screenshot:app.screenshot());attachment.name="C2-completed-list";attachment.lifetime = .keepAlways;add(attachment)
    }
    func testScrollPositionSurvivesNewRow() {
        let app=launch();ready(app)
        let list=historyList(in: app)
        let anchor = app.staticTexts["archiveRow-11"]
        reveal(anchor, in: app)
        let label=anchor.label;let y=anchor.frame.midY
        let beforeShot = XCTAttachment(screenshot: app.screenshot()); beforeShot.name = "history-position-before-insert"; beforeShot.lifetime = .keepAlways; add(beforeShot)
        app.buttons["appendRow"].tap()
        let status=app.staticTexts["c2-fixture-status"]
        let expectation=XCTNSPredicateExpectation(predicate:NSPredicate(format:"label == 'appended-13'"),object:status)
        XCTAssertEqual(XCTWaiter.wait(for:[expectation],timeout:10),.completed)
        let after=app.staticTexts[label];XCTAssertTrue(after.isHittable)
        let afterShot = XCTAttachment(screenshot: app.screenshot()); afterShot.name = "history-position-after-insert"; afterShot.lifetime = .keepAlways; add(afterShot)
        XCTAssertLessThan(abs(after.frame.midY-y),35)
        XCTAssertFalse(app.staticTexts["新增但不跳頂"].isHittable)
    }
    func testSourceEnlargementAndOriginalText() {
        let app=launch();ready(app)
        let thumb=app.buttons.matching(identifier:"recognitionSourceThumbnail").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(thumb);thumb?.tap()
        XCTAssertTrue(app.images["recognitionSourceEnlarged"].waitForExistence(timeout:5))
        app.buttons["完成"].tap()
        let original=app.textViews["archiveText-12"].links["原文"]
        reveal(original, in: app); original.tap()
        scrollWait(app.textViews["archiveText-12"], "value CONTAINS 'Original 12'")
    }
    func testHistorySurvivesProcessRestart() {
        let app=launch();ready(app);app.buttons["appendRow"].tap()
        let expectation=XCTNSPredicateExpectation(predicate:NSPredicate(format:"label == 'appended-13'"),object:app.staticTexts["c2-fixture-status"])
        XCTAssertEqual(XCTWaiter.wait(for:[expectation],timeout:10),.completed)
        app.terminate();app.launchArguments=["--resume-history"];app.launch();ready(app)
        XCTAssertEqual(app.staticTexts["c2-fixture-status"].label,"ready-13")
        XCTAssertTrue(app.textViews["archiveText-13"].exists)
        XCTAssertTrue(app.buttons["continueCapture"].isEnabled)
    }
    func testBackgroundRestoresHistoryAndDoesNotArm() {
        let app=launch();ready(app)
        XCUIDevice.shared.press(.home);app.activate()
        XCTAssertTrue(app.textViews["archiveText-12"].waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["continueCapture"].isEnabled)
        XCTAssertEqual(app.buttons["continueCapture"].label,"開始辨識")
    }
    func testShareUsesExistingSystemPanel() {
        let app=launch();ready(app)
        let list=historyList(in: app)
        list.swipeUp()
        let share=app.buttons.matching(identifier:"shareRecognitionResult").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(share);share?.tap()
        let status = app.staticTexts["c2-fixture-status"]
        let paired = XCTNSPredicateExpectation(predicate:NSPredicate(format:"label == 'share-pair-correct'"),object:status)
        XCTAssertEqual(XCTWaiter.wait(for:[paired],timeout:10),.completed)
        let names=["Close","關閉","Cancel","取消","UIActivityContentViewControllerCloseButton"]
        if let close=names.map({ app.buttons[$0] }).first(where: { $0.exists && $0.isHittable }) { close.tap() }
        else { app.coordinate(withNormalizedOffset:CGVector(dx:0.02,dy:0.15)).tap() }
        let cleaned = XCTNSPredicateExpectation(predicate:NSPredicate(format:"label == 'share-clean'"),object:status)
        XCTAssertEqual(XCTWaiter.wait(for:[cleaned],timeout:10),.completed)
    }
    func testMaximumTypeRetainsContinueAndReadableRows() {
        let app=launch(["--maximum-type"]);ready(app)
        XCTAssertTrue(app.buttons["continueCapture"].isHittable)
        XCTAssertTrue(app.textViews["archiveText-12"].exists)
        XCTAssertFalse(app.buttons["nextArchiveRecord"].exists)
        XCTAssertLessThanOrEqual(app.buttons["continueCapture"].frame.maxY, historyList(in: app).frame.minY + 1)
        reveal(app.textViews["archiveText-12"], in: app)
        let attachment=XCTAttachment(screenshot:app.screenshot());attachment.lifetime = .keepAlways;add(attachment)
    }
}

extension CaptureUITests {
    func testPaid70LoginLifecycleWithSyntheticTransport() {
        let app = launch(["--auth-recovery-checks", "--siwc-auth-fixture"])
        let result = app.staticTexts["auth-recovery-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'passed ' OR label BEGINSWITH 'FAILED '"), object: result)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 45), .completed)
        XCTAssertTrue(result.label.hasPrefix("passed "), result.label)
    }

}

extension CaptureUITests {
    func testFullVisibleCropAndBarcodeShareIdentity() {
        let app = launch(["--visible-crop-checks"])
        let result = app.staticTexts["visibleCropResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'passed ' OR label BEGINSWITH 'FAILED '"), object: result)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 30), .completed)
        XCTAssertEqual(result.label, "passed 8")
    }
    func testOrdinarySettingsShowsFailedReplacement() { checkOrdinaryFailure([]) }
    func testOrdinarySettingsFailureAtMaximumType() { checkOrdinaryFailure(["--maximum-type"]) }
    func testCompactSignedInAccountSettings() { checkCompactSettings([]) }
    func testCompactSignedInAccountSettingsMaximumType() { checkCompactSettings(["--maximum-type"]) }
    private func checkCompactSettings(_ args: [String]) {
        let app = launch(["--signed-in-settings", "--siwc-auth-fixture"] + args); ready(app)
        app.buttons["設定"].tap()
        assertCompactAccount(app, suffix: "signed-in-" + args.joined(separator: "-"))
        XCTAssertFalse(app.staticTexts["siwcStatus"].exists)
    }
    private func assertCompactAccount(_ app: XCUIApplication, suffix: String) {
        let summary = app.descendants(matching: .any).matching(identifier: "siwcAccountSummary").firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertTrue(summary.staticTexts["previous@example.invalid"].exists)
        XCTAssertTrue(summary.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已登入 ChatGPT")).firstMatch.exists)
        let top = XCTAttachment(screenshot: app.screenshot()); top.name = "Compact-account-top-" + suffix
        top.lifetime = .keepAlways; add(top)
        let row = app.descendants(matching: .any).matching(identifier: "siwcAccountSwitchRow").firstMatch
        let change = row.buttons["siwc-authenticate-account"]
        for _ in 0..<10 where !change.exists || !change.isHittable { app.swipeUp() }
        XCTAssertTrue(change.exists); XCTAssertTrue(change.isEnabled)
        XCTAssertEqual(change.label, "更換帳戶")
        let explanation = row.staticTexts["siwcAccountSwitchExplanation"]
        XCTAssertTrue(explanation.exists)
        XCTAssertTrue(explanation.label.contains("取消或失敗會保留原帳戶"))
        for _ in 0..<6 where !explanation.isHittable { app.swipeUp() }
        XCTAssertTrue(explanation.isHittable)
        let detail = XCTAttachment(screenshot: app.screenshot()); detail.name = "Compact-account-explanation-" + suffix
        detail.lifetime = .keepAlways; add(detail)
    }
    private func checkOrdinaryFailure(_ args: [String]) {
        let app = launch(["--failed-signin-settings", "--siwc-auth-fixture"] + args); ready(app)
        app.buttons["設定"].tap()
        assertCompactAccount(app, suffix: "failed-" + args.joined(separator: "-"))
        let requirement = app.staticTexts["siwcPaidRequirement"]
        for _ in 0..<8 where !requirement.isHittable { app.swipeUp() }
        XCTAssertTrue(requirement.isHittable)
        XCTAssertTrue(requirement.label.contains("免費帳戶無法使用辨識功能"))
        let status = app.staticTexts["siwcStatus"]
        for _ in 0..<8 where !status.isHittable { app.swipeUp() }
        XCTAssertTrue(status.isHittable)
        XCTAssertTrue(status.label.contains("HTTP 400")); XCTAssertTrue(status.label.contains("原帳戶已保留"))
        XCTAssertTrue(status.label.contains("使用要求：")); XCTAssertTrue(status.label.contains("確認目前登入的帳戶"))
        XCTAssertFalse(app.buttons["安全診斷與帳戶驗證"].exists)
        XCTAssertFalse(app.buttons["siwcReadModels"].exists)
        XCTAssertFalse(app.buttons["siwcTestSyntheticImage"].exists)
        XCTAssertFalse(app.buttons["siwc-retry-registration"].exists)
        XCTAssertFalse(app.debugDescription.contains("generated token=never-store"))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Ordinary-settings-failed-signin-" + (args.isEmpty ? "normal" : "maximum")
        shot.lifetime = .keepAlways; add(shot)
    }
}


extension CaptureUITests {
    private func openImage(_ sequence: Int, app: XCUIApplication) -> XCUIElement {
        let card = app.otherElements["archiveCard-\(sequence)"]
        let thumbnail = card.buttons["recognitionSourceThumbnail"]
        reveal(thumbnail, in: app); thumbnail.tap()
        let image = app.images["recognitionSourceEnlarged"]
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        return image
    }
    private func dismissImageShare(_ app: XCUIApplication) {
        let names = ["Close", "關閉", "Cancel", "取消", "UIActivityContentViewControllerCloseButton"]
        if let close = names.map({ app.buttons[$0] }).first(where: { $0.exists && $0.isHittable }) { close.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.15)).tap() }
    }
    func testImageOnlyShareKeepsSelectedOriginalAndReturnsToPreview() {
        let app = launch(["--image-share"]); ready(app)
        for sequence in [12, 11] {
            let image = openImage(sequence, app: app), originalID = image.value as? String
            let share = app.buttons["shareRecognitionImage"]
            XCTAssertTrue(share.isHittable); XCTAssertEqual(share.label, "分享圖片")
            share.tap()
            let state = app.staticTexts["c2-fixture-status"]
            scrollWait(state, "label == 'image-share-presented-\(sequence)'")
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "image-only-share-\(sequence)"; shot.lifetime = .keepAlways; add(shot)
            dismissImageShare(app)
            scrollWait(state, "label == 'image-share-clean-\(sequence)'")
            XCTAssertTrue(image.isHittable); XCTAssertEqual(image.value as? String, originalID)
            // Reopen the same original; no stale share-session lock or wrong card.
            share.tap(); scrollWait(state, "label == 'image-share-presented-\(sequence)'")
            dismissImageShare(app); scrollWait(state, "label == 'image-share-clean-\(sequence)'")
            app.buttons["closeRecognitionImage"].tap()
        }
    }
    func testImageOnlySaveUsesSystemAddOnlyAction() {
        let app = launch(["--image-share"]); ready(app)
        let image = openImage(12, app: app), originalID = image.value as? String
        XCTAssertEqual(app.alerts.count, 0)
        app.buttons["shareRecognitionImage"].tap()
        scrollWait(app.staticTexts["c2-fixture-status"], "label == 'image-share-presented-12'")
        let save = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Save Image", "儲存影像", "儲存圖片"])).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10)); save.tap()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = system.alerts.firstMatch
        if alert.waitForExistence(timeout: 3) {
            let allow = alert.buttons.matching(NSPredicate(format: "label IN %@", ["Allow Adding Photos", "Allow Add Only", "OK", "允許加入照片", "允許加入相片", "好", "允許"])).firstMatch
            let shot = XCTAttachment(screenshot: system.screenshot()); shot.name = "save-add-only-permission"; shot.lifetime = .keepAlways; add(shot)
            XCTAssertTrue(allow.exists, alert.debugDescription); allow.tap()
        }
        scrollWait(app.staticTexts["c2-fixture-status"], "label == 'image-share-saved-12'")
        XCTAssertTrue(image.isHittable); XCTAssertEqual(image.value as? String, originalID)
    }
    func testImageOnlyMissingAndCorruptSourcesCannotShareAnotherCard() {
        for mode in ["--missing-preview-image", "--corrupt-preview-image"] {
            let app = launch(["--image-share", mode]); ready(app)
            let card = app.otherElements["archiveCard-12"]
            reveal(card, in: app)
            XCTAssertFalse(card.buttons["recognitionSourceThumbnail"].exists)
            XCTAssertFalse(app.buttons["shareRecognitionImage"].exists)
            _ = openImage(11, app: app)
            app.buttons["shareRecognitionImage"].tap()
            scrollWait(app.staticTexts["c2-fixture-status"], "label == 'image-share-presented-11'")
            dismissImageShare(app)
            app.buttons["closeRecognitionImage"].tap()
            app.terminate()
        }
    }
    func testImageOnlyInvalidPreviewAndPendingCardHaveNoShare() {
        let invalid = launch(["--invalid-image-viewer"])
        XCTAssertTrue(invalid.descendants(matching: .any)["recognitionSourceUnavailable"].waitForExistence(timeout: 10))
        XCTAssertFalse(invalid.buttons["shareRecognitionImage"].exists)
        XCTAssertTrue(invalid.buttons["closeRecognitionImage"].exists); invalid.terminate()
        let app = launch(["--image-share", "--scroll-ui"]); ready(app)
        app.buttons["selectSyntheticPhoto"].tap(); assertOnePending(app, sequence: 13)
        _ = openImage(13, app: app)
        XCTAssertFalse(app.buttons["shareRecognitionImage"].exists)
    }
}


extension CaptureUITests {
    func testSingleCardSelectionCrossesHeadingAndCopiesOnlySelectedText() throws { try checkWholeSelection([]) }
    func testLongCardSelectionFitsAllTextAndCopiesAcrossParagraphs() throws { try checkWholeSelection(["--selection-long"]) }
    private func checkWholeSelection(_ args: [String]) throws {
        let app = launch(["--selection-ui", "--selection-links", "--scroll-ui"] + args); ready(app)
        let text = app.textViews["archiveText-12"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        let disclosure = app.textViews["archiveText-12"].links["原文"]
        reveal(disclosure, in: app); disclosure.tap()
        scrollWait(text, "value CONTAINS 'Original 12'")
        XCTAssertFalse((text.value as? String ?? "").contains("原文（"))
        // List accessibility reports the visible intersection. The fixture checks
        // actual UITextView/cell layout and all 30 copied paragraphs below.
        reveal(text, in: app)
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 1.2)
        let selectAll = ["全選", "Select All"].flatMap { [app.menuItems[$0], app.buttons[$0]] }.first { $0.waitForExistence(timeout: 2) }
        XCTAssertNotNil(selectAll, app.debugDescription)
        selectAll?.tap()
        let copy = ["拷貝", "複製", "Copy"].flatMap { [app.menuItems[$0], app.buttons[$0]] }.first { $0.waitForExistence(timeout: 2) }
        XCTAssertNotNil(copy, app.debugDescription); copy?.tap()
        app.buttons["inspectSelectionCopy"].tap()
        scrollWait(app.staticTexts["selectionStatus"], "label == 'selection-copy-passed'")
        XCTAssertTrue(app.staticTexts["scrollState"].label.contains("calls-0"))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Build33-single-card-cross-section-selection"; shot.lifetime = .keepAlways; add(shot)
        // UIKit may omit an offscreen selected link from accessibility. Read
        // the rendered arrow geometry only, then perform real scrolling/taps.
        let list = historyList(in: app)
        var tappedOriginal = false
        for _ in 0..<12 {
            app.buttons["originalDisclosureGeometry"].tap()
            let values = try JSONDecoder().decode([Double].self, from: Data(app.staticTexts["selectionStatus"].label.utf8))
            XCTAssertEqual(values.count, 2)
            let point = CGPoint(x: values[0], y: values[1])
            if list.frame.insetBy(dx: 0, dy: 8).contains(point) {
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
                tappedOriginal = true; break
            }
            // Move toward the measured arrow without a full swipe overshooting
            // it and reopening the preview on the following downward swipe.
            // The trailing margin also keeps the drag outside selected text.
            let limit = list.frame.height * 0.25
            let travel = min(limit, max(-limit, list.frame.midY - point.y))
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: travel > 0 ? 0.35 : 0.65))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: travel)),
                withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(tappedOriginal)
        scrollWait(text, "NOT value CONTAINS 'Original 12'")
        XCTAssertTrue((text.value as? String ?? "").contains("原文"))
        XCTAssertFalse((text.value as? String ?? "").contains("原文（"))
        XCTAssertEqual(try capturedURLs(app), [])
    }
    func testSelectionHandleDragsAcrossOriginalHeadingWithoutCameraOrListGesture() throws {
        let app = launch(["--selection-ui", "--selection-links", "--selection-drag", "--scroll-ui"]); ready(app)
        // A real reading gesture gives both native selection handles room on
        // screen; do not drag toward an offscreen caret below the preview.
        let list = historyList(in: app)
        let readingStart = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        readingStart.press(forDuration: 0.1, thenDragTo: readingStart.withOffset(CGVector(dx: 0, dy: -40)))
        scrollWait(app.staticTexts["scrollState"], "label CONTAINS 'collapsed-true'")
        let text = app.textViews["archiveText-12"]
        let disclosure = app.textViews["archiveText-12"].links["原文"]
        reveal(disclosure, in: app); disclosure.tap()
        scrollWait(text, "value CONTAINS 'Original 12'")
        // Accessibility may expose only the visible intersection of a List row.
        // Fit the actual text view, including space for the end handle, with
        // measured short drags; a broad downward swipe can reopen the preview.
        var textRect = CGRect.zero
        var geometryTrace: [[Double]] = []
        for _ in 0..<10 {
            app.buttons["selectionTextGeometry"].tap()
            let values = try JSONDecoder().decode([Double].self, from: Data(app.staticTexts["selectionStatus"].label.utf8))
            XCTAssertEqual(values.count, 4)
            textRect = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
            let viewport = list.frame.insetBy(dx: 0, dy: 32)
            geometryTrace.append([textRect.minY, textRect.maxY, viewport.minY, viewport.maxY])
            if viewport.contains(textRect) { break }
            let delta = viewport.minY + 8 - textRect.minY
            // Below the pan recognizer's slop a synthetic drag is only a touch.
            let travel = (delta < 0 ? -1.0 : 1.0) * min(100, max(24, abs(delta)))
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: travel > 0 ? 0.35 : 0.65))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: travel)),
                withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        let geometryReport = XCTAttachment(data: try JSONEncoder().encode(geometryTrace), uniformTypeIdentifier: "public.json")
        geometryReport.name = "native-handle-visible-geometry"; geometryReport.lifetime = .keepAlways; add(geometryReport)
        XCTAssertTrue(list.frame.insetBy(dx: 0, dy: 32).contains(textRect), "Measured text rectangle must be entirely visible before selection")
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: textRect.minX + textRect.width * 0.3, dy: textRect.minY + textRect.height * 0.4))
            .press(forDuration: 1.2)
        app.buttons["selectionDragGeometry"].tap()
        let coordinates = try JSONDecoder().decode([Double].self, from: Data(app.staticTexts["selectionStatus"].label.utf8))
        XCTAssertEqual(coordinates.count, 4)
        XCTAssertTrue(list.frame.insetBy(dx: 0, dy: 8).contains(CGPoint(x: coordinates[0], y: coordinates[1])))
        XCTAssertTrue(list.frame.insetBy(dx: 0, dy: 8).contains(CGPoint(x: coordinates[2], y: coordinates[3])))
        let before = app.staticTexts["scrollState"].label
        let beforeShot = XCTAttachment(screenshot: app.screenshot()); beforeShot.name = "Build33-selection-before-handle-drag"; beforeShot.lifetime = .keepAlways; add(beforeShot)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: coordinates[0], dy: coordinates[1])).press(forDuration: 0.15,
            thenDragTo: origin.withOffset(CGVector(dx: coordinates[2], dy: coordinates[3])), withVelocity: .slow, thenHoldForDuration: 0.2)
        let copy = ["Copy", "拷貝", "複製"].flatMap { [app.menuItems[$0], app.buttons[$0]] }.first { $0.waitForExistence(timeout: 2) }
        XCTAssertNotNil(copy, app.debugDescription); copy?.tap()
        app.buttons["inspectPartialCopy"].tap()
        scrollWait(app.staticTexts["selectionStatus"], "label == 'selection-partial-passed'")
        XCTAssertEqual(app.staticTexts["scrollState"].label, before)
        XCTAssertEqual(try capturedURLs(app), [])
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Build33-native-selection-handle-across-heading"; shot.lifetime = .keepAlways; add(shot)
    }
    func testPartialSelectionCopyExcludesHiddenOriginalAndOtherCards() throws {
        let app = launch(["--selection-ui", "--selection-links", "--scroll-ui"]); ready(app)
        let text = app.textViews["archiveText-12"]
        reveal(text, in: app)
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 1.2)
        let copy = ["Copy", "拷貝", "複製"].flatMap { [app.menuItems[$0], app.buttons[$0]] }.first { $0.waitForExistence(timeout: 2) }
        XCTAssertNotNil(copy, app.debugDescription); copy?.tap()
        app.buttons["inspectPartialCopy"].tap()
        scrollWait(app.staticTexts["selectionStatus"], "label == 'selection-partial-passed'")
        XCTAssertEqual(try capturedURLs(app), [])
        XCTAssertTrue(app.staticTexts["scrollState"].label.contains("calls-0"))
    }
    func testSelectableCardMaximumTypeLinksAndScrollRemainIndependent() {
        let app = launch(["--maximum-type", "--dark", "--search-links", "--scroll-ui"]); ready(app)
        let text = app.textViews["archiveText-12"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        let link = app.descendants(matching: .any).matching(identifier: "googleSearch-12").firstMatch
        reveal(link, in: app); link.tap()
        scrollWait(app.staticTexts["c2-fixture-status"], "label == 'search-correct-12-calls-0'")
        XCTAssertTrue(app.staticTexts["scrollState"].label.contains("calls-0"))
        let first = app.staticTexts["archiveRow-11"]
        reveal(first, in: app)
        XCTAssertTrue(first.isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Build33-selectable-card-maximum-type"; shot.lifetime = .keepAlways; add(shot)
    }
}


extension CaptureUITests {
    func testOriginalAppearanceComparison() throws {
        let app = launch(["--original-appearance-comparison"])
        XCTAssertTrue(app.staticTexts["baselineNames"].waitForExistence(timeout: 10))
        let before = XCTAttachment(screenshot: app.screenshot()); before.name = "Build33-original-comparison-collapsed"; before.lifetime = .keepAlways; add(before)
        app.buttons["originalComparisonInspect"].tap()
        let geometry = try JSONDecoder().decode([Double].self, from: Data(app.staticTexts["originalComparisonGeometry"].label.utf8))
        XCTAssertEqual(geometry.count, 5)
        XCTAssertGreaterThan(geometry[3], 0)
        XCTAssertGreaterThan(geometry[4], 0)
        XCTAssertEqual(geometry[2], geometry[3], accuracy: geometry[4])
        app.buttons["baselineOriginal"].tap()
        // Tap the restored arrow itself; the title action is covered separately.
        let origin = app.coordinate(withNormalizedOffset: .zero)
        app.buttons["originalComparisonInspect"].tap()
        let expandedLayout = try JSONDecoder().decode([Double].self, from: Data(app.staticTexts["originalComparisonGeometry"].label.utf8))
        origin.withOffset(CGVector(dx: expandedLayout[0], dy: expandedLayout[1])).tap()
        scrollWait(app.textViews["archiveText-33"], "value CONTAINS 'Original line one'")
        let after = XCTAttachment(screenshot: app.screenshot()); after.name = "Build33-original-comparison-expanded"; after.lifetime = .keepAlways; add(after)
        app.buttons["originalComparisonInspect"].tap()
        let openArrow = try JSONDecoder().decode([Double].self, from: Data(app.staticTexts["originalComparisonGeometry"].label.utf8))
        origin.withOffset(CGVector(dx: openArrow[0], dy: openArrow[1])).tap()
        scrollWait(app.textViews["archiveText-33"], "NOT value CONTAINS 'Original line one'")
        XCTAssertFalse((app.textViews["archiveText-33"].value as? String ?? "").contains("原文（"))
    }
}

extension CaptureUITests {
    func testCompact55StableFirstStageCardLight() { checkCompact55StableCard([]) }
    func testCompact55StableFirstStageCardDark() { checkCompact55StableCard(["--dark"]) }
    func testCompact55FailureKeepsCardWithoutStatus() { checkCompact55StableCard(["--compact55-failure"]) }
    func testCompact55InsufficientKeepsCardWithoutStatus() { checkCompact55StableCard(["--compact55-insufficient"]) }
    func testActions56FirstStageGateLight() { checkActions56([]) }
    func testActions56FirstStageGateDark() { checkActions56(["--dark"]) }
    private func checkActions56(_ flags: [String]) {
        let app = launch(["--json45", "--actions56", "--progress-checks"] + flags); ready(app)
        let calls = app.staticTexts["actions56-calls"]
        func check(_ sequence: Int, enabled: Bool, label: String) {
            let json = app.buttons["modelJSON-\(sequence)"]
            XCTAssertTrue(json.waitForExistence(timeout: 8)); reveal(json, in: app)
            let share = app.otherElements["archiveCard-\(sequence)"].buttons["shareRecognitionResult"]
            XCTAssertTrue(share.waitForExistence(timeout: 5))
            scrollWait(json, enabled ? "enabled == true" : "enabled == false")
            XCTAssertEqual(share.isEnabled, enabled)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "actions56-\(label)-" + (flags.contains("--dark") ? "dark" : "light")
            shot.lifetime = .keepAlways; add(shot)
            if !enabled {
                json.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                XCTAssertFalse(app.buttons["closeModelJSON"].exists)
            }
        }
        check(12, enabled: true, label: "saved-success")
        app.buttons["continueCapture"].tap(); app.buttons["feedFrames"].tap()
        check(13, enabled: false, label: "waiting-before-send")
        XCTAssertEqual(calls.label, "calls-0")
        app.buttons["actions56-dispatch"].tap(); scrollWait(calls, "label == 'calls-1'")
        check(13, enabled: false, label: "first-stage-running")
        app.buttons["completeReply"].tap()
        check(13, enabled: true, label: "first-stage-success")
        app.buttons["modelJSON-13"].tap()
        XCTAssertTrue(app.buttons["closeModelJSON"].waitForExistence(timeout: 5))
        app.buttons["closeModelJSON"].tap()
        app.buttons["continueCapture"].tap(); app.buttons["feedFrames"].tap()
        scrollWait(calls, "label == 'calls-2'")
        app.buttons["failReply"].tap()
        let retry = app.buttons["retryImage-14"]
        XCTAssertTrue(retry.waitForExistence(timeout: 8))
        check(14, enabled: false, label: "first-stage-failed")
        reveal(retry, in: app); retry.tap(); scrollWait(calls, "label == 'calls-3'")
        check(14, enabled: false, label: "retry-running")
        app.buttons["completeReply"].tap()
        check(14, enabled: true, label: "retry-success")
    }
    private func checkCompact55StableCard(_ arguments: [String]) {
        let app = launch(["--semantic45-ui", "--compact55-ui"] + arguments)
        XCTAssertTrue(app.buttons["semantic45-start"].waitForExistence(timeout: 10)); app.buttons["semantic45-start"].tap()
        let text = app.textViews["archiveText-1"], phase = app.staticTexts["compact55-phase"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        let collecting = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'collecting:none'"), object: phase)
        XCTAssertEqual(XCTWaiter.wait(for: [collecting], timeout: 8), .completed)
        let initial = text.value as? String, textFrame = text.frame, google = app.descendants(matching: .any).matching(identifier: "googleSearch-1").firstMatch
        let googleLabel = google.label, googleFrame = google.frame, jsonFrame = app.buttons["modelJSON-1"].frame
        XCTAssertTrue(initial?.contains("初步簡介") == true)
        XCTAssertFalse(app.staticTexts["semanticReviewStatus-1"].exists)
        XCTAssertFalse(app.buttons["cancelSemanticReview-1"].exists)
        XCTAssertTrue(app.buttons["modelJSON-1"].isEnabled && app.buttons["modelJSON-1"].isHittable)
        XCTAssertTrue(app.otherElements["archiveCard-1"].buttons["shareRecognitionResult"].isEnabled)
        let first = XCTAttachment(screenshot: app.screenshot()); first.name = "compact55-stage1-json-blue-\(arguments.isEmpty ? "light" : "dark")"; first.lifetime = .keepAlways; add(first)
        app.buttons["compact55-sources"].tap()
        let reviewing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'reviewing:dispatching'"), object: phase)
        XCTAssertEqual(XCTWaiter.wait(for: [reviewing], timeout: 8), .completed)
        XCTAssertEqual(text.value as? String, initial); XCTAssertEqual(google.label, googleLabel)
        for (before, after) in [(textFrame,text.frame),(googleFrame,google.frame),(jsonFrame,app.buttons["modelJSON-1"].frame)] {
            XCTAssertEqual(before.minY, after.minY, accuracy: 1); XCTAssertEqual(before.height, after.height, accuracy: 1)
        }
        XCTAssertFalse(app.staticTexts["semanticReviewStatus-1"].exists)
        XCTAssertFalse(app.links["wikipedia-1"].exists)
        app.buttons["semantic45-finish"].tap()
        if arguments.contains("--compact55-failure") || arguments.contains("--compact55-insufficient") {
            let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'failed:' OR label BEGINSWITH 'insufficientEvidence:'"), object: phase)
            XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 8), .completed)
            XCTAssertEqual(text.value as? String, initial); XCTAssertEqual(google.label, googleLabel)
            XCTAssertEqual(text.frame.minY, textFrame.minY, accuracy: 1); XCTAssertEqual(text.frame.height, textFrame.height, accuracy: 1)
            XCTAssertEqual(google.frame.minY, googleFrame.minY, accuracy: 1)
            XCTAssertFalse(app.links["wikipedia-1"].exists); XCTAssertFalse(app.staticTexts["semanticReviewStatus-1"].exists)
            XCTAssertTrue(app.buttons["modelJSON-1"].isEnabled)
            XCTAssertTrue(app.otherElements["archiveCard-1"].buttons["shareRecognitionResult"].isEnabled)
            app.buttons["modelJSON-1"].tap(); app.buttons["modelJSONStage-2"].tap()
            let message = app.staticTexts["modelJSONMessage"]
            XCTAssertTrue(message.waitForExistence(timeout: 5))
            if arguments.contains("--compact55-failure") {
                let diagnostic = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'requestingModel / network'"), object: message)
                XCTAssertEqual(XCTWaiter.wait(for: [diagnostic], timeout: 5), .completed, message.label)
            } else {
                let raw = app.textViews["modelJSONText"]
                XCTAssertTrue(raw.waitForExistence(timeout: 5))
                XCTAssertTrue((raw.value as? String ?? "").contains("insufficient_evidence"))
            }
            return
        }
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS '曙光公司持有這個品牌'"), object: text)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 8), .completed)
        XCTAssertTrue(app.links["wikipedia-1"].exists)
        XCTAssertFalse(app.staticTexts["semanticReviewStatus-1"].exists)
        XCTAssertEqual(app.textViews.matching(identifier: "archiveText-1").count, 1)
    }
    func testGoogle57ExactOriginalLinkSurvivesInsufficientReview() {
        let app = launch(["--semantic45-ui", "--compact55-ui", "--compact55-insufficient", "--google57"])
        XCTAssertTrue(app.buttons["semantic45-start"].waitForExistence(timeout: 10)); app.buttons["semantic45-start"].tap()
        let google = app.descendants(matching: .any).matching(identifier: "googleSearch-1").firstMatch
        XCTAssertTrue(google.waitForExistence(timeout: 10))
        XCTAssertEqual(google.label, "Google 搜尋：Maker’s Mark 波本威士忌")
        XCTAssertTrue(app.buttons["modelJSON-1"].isEnabled)
        app.buttons["compact55-sources"].tap()
        let phase = app.staticTexts["compact55-phase"]
        let reviewing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'reviewing:dispatching'"), object: phase)
        XCTAssertEqual(XCTWaiter.wait(for: [reviewing], timeout: 8), .completed)
        app.buttons["semantic45-finish"].tap()
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'insufficientEvidence:'"), object: phase)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 8), .completed)
        XCTAssertEqual(google.label, "Google 搜尋：Maker’s Mark 波本威士忌")
        XCTAssertFalse(app.links["wikipedia-1"].exists)
        XCTAssertTrue(app.buttons["modelJSON-1"].isEnabled)
        XCTAssertTrue(app.otherElements["archiveCard-1"].buttons["shareRecognitionResult"].isEnabled)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "google57-maker-insufficient"; shot.lifetime = .keepAlways; add(shot)
    }
    func testIdentity57BookKeepsRealAuthorPageLabel() {
        let app = launch(["--semantic45-ui", "--book57"])
        XCTAssertTrue(app.buttons["semantic45-start"].waitForExistence(timeout: 10)); app.buttons["semantic45-start"].tap()
        XCTAssertTrue(app.textViews["archiveText-1"].waitForExistence(timeout: 10))
        app.buttons["semantic45-finish"].tap()
        let link = app.links["wikipedia-1"]
        XCTAssertTrue(link.waitForExistence(timeout: 10)); XCTAssertEqual(link.label, "維基百科：智顗")
        let google = app.descendants(matching: .any).matching(identifier: "googleSearch-1").firstMatch
        XCTAssertEqual(google.label, "Google 搜尋：摩訶止觀")
        XCTAssertTrue((app.textViews["archiveText-1"].value as? String ?? "").contains("摩訶止觀"))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "identity57-book-author-page"; shot.lifetime = .keepAlways; add(shot)
    }
    func testOriginalWiki67JapaneseLabelAndChineseSummarySurviveReload() {
        let app = launch(["--semantic45-ui", "--foreign67"])
        XCTAssertTrue(app.buttons["semantic45-start"].waitForExistence(timeout: 10))
        scrollWait(app.buttons["semantic45-start"], "enabled == true")
        app.buttons["semantic45-start"].tap()
        XCTAssertTrue(app.textViews["archiveText-1"].waitForExistence(timeout: 10))
        app.buttons["semantic45-finish"].tap()
        let link = app.links["wikipedia-1"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        XCTAssertEqual(link.label, "維基百科：アサヒビール（日文）（品牌）")
        XCTAssertTrue((app.textViews["archiveText-1"].value as? String ?? "").contains("繁體中文品牌說明"))
        app.buttons["title61-reload"].tap()
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "title61-reloaded"), object: app.staticTexts["semantic54-copy-status"])
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 10), .completed)
        XCTAssertEqual(app.links["wikipedia-1"].label, "維基百科：アサヒビール（日文）（品牌）")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "original67-japanese-wiki-reloaded"; shot.lifetime = .keepAlways; add(shot)
    }
    func testTitle61TraditionalWikiLabelBeforeAndAfterArchiveReload() {
        let app = launch(["--semantic45-ui", "--title61"])
        XCTAssertTrue(app.buttons["semantic45-start"].waitForExistence(timeout: 10))
        scrollWait(app.buttons["semantic45-start"], "enabled == true")
        app.buttons["semantic45-start"].tap()
        XCTAssertTrue(app.textViews["archiveText-1"].waitForExistence(timeout: 10))
        app.buttons["semantic45-finish"].tap()
        let link = app.links["wikipedia-1"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        XCTAssertEqual(link.label, "維基百科：樂事（品牌）")
        app.buttons["title61-reload"].tap()
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "title61-reloaded"), object: app.staticTexts["semantic54-copy-status"])
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 10), .completed)
        XCTAssertTrue(app.links["wikipedia-1"].exists)
        XCTAssertEqual(app.links["wikipedia-1"].label, "維基百科：樂事（品牌）")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "title61-traditional-wiki-reloaded"; shot.lifetime = .keepAlways; add(shot)
    }
    func testOriginalWiki67JSONShareCopiesOriginalSourceAndLanguage() {
        checkRequest54CombinedShareFromEachPage(["--foreign67"])
    }
    func testSummary69ChineseQuotedOCRVisibleBeforeReview() {
        let app = launch(["--semantic45-ui", "--foreign67", "--quoted69"])
        let start = app.buttons["semantic45-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10)); scrollWait(start, "enabled == true"); start.tap()
        let body = app.textViews["archiveText-1"]
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "罐身可見的「まろやかな泡」意為口感柔和的泡沫。"), object: body)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 10), .completed)
        XCTAssertFalse((body.value as? String ?? "").contains("尚未取得"))
    }
    func testSummary69JSONCopyRetainsOriginalForeignResponse() {
        checkRequest54CombinedShareFromEachPage(["--foreign67", "--summary68"])
    }
    func testSummary69ChineseWithUnlistedKatakanaRemainsOriginal() {
        let app = launch(["--semantic45-ui", "--foreign67", "--native68"])
        let start = app.buttons["semantic45-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10)); scrollWait(start, "enabled == true"); start.tap()
        let body = app.textViews["archiveText-1"]
        XCTAssertTrue(body.waitForExistence(timeout: 10)); app.buttons["semantic45-finish"].tap()
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "該品牌推出スーパードライ系列，這是一句繁體中文介紹。"), object: body)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 10), .completed)
        XCTAssertFalse((body.value as? String ?? "").contains("並非百科補充"))
        XCTAssertEqual(app.links["wikipedia-1"].label, "維基百科：アサヒビール（日文）（品牌）")
    }
    func testSummary69ForeignReplyAndOriginalLinkSurviveReload() {
        let app = launch(["--semantic45-ui", "--foreign67", "--summary68"])
        let start = app.buttons["semantic45-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10)); scrollWait(start, "enabled == true"); start.tap()
        let body = app.textViews["archiveText-1"]
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        XCTAssertTrue((body.value as? String ?? "").contains("アサヒ生ビール マルエフ是一款日本啤酒，Asahi"))
        app.buttons["semantic45-finish"].tap()
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "のブランドのビールです"), object: body)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 10), .completed)
        XCTAssertTrue((body.value as? String ?? "").contains("のブランドのビールです"))
        XCTAssertEqual(app.links["wikipedia-1"].label, "維基百科：アサヒビール（日文）（品牌）")
        app.buttons["title61-reload"].tap()
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "title61-reloaded"), object: app.staticTexts["semantic54-copy-status"])
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 10), .completed)
        XCTAssertFalse((body.value as? String ?? "").contains("並非百科補充"))
        XCTAssertTrue((body.value as? String ?? "").contains("のブランドのビールです"))
        XCTAssertEqual(app.links["wikipedia-1"].label, "維基百科：アサヒビール（日文）（品牌）")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "summary69-verbatim-japanese-reloaded"; shot.lifetime = .keepAlways; add(shot)
    }
    func testRequest54CombinedShareFromEachPage() {
        checkRequest54CombinedShareFromEachPage([])
    }
    private func checkRequest54CombinedShareFromEachPage(_ arguments: [String]) {
        let app = launch(["--semantic45-ui"] + arguments)
        XCTAssertTrue(app.buttons["semantic45-start"].waitForExistence(timeout: 10))
        app.buttons["semantic45-start"].tap()
        XCTAssertTrue(app.textViews["archiveText-1"].waitForExistence(timeout: 10))
        app.buttons["semantic45-finish"].tap()
        let phrase = arguments.contains("--summary68") ? "のブランドのビールです" : arguments.contains("--foreign67") ? "繁體中文品牌說明" : "曙光公司持有這個品牌"
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", phrase), object: app.textViews["archiveText-1"])
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 8), .completed)
        for (index, stage) in [1, 3, 2].enumerated() {
            app.buttons["modelJSON-1"].tap()
            let button = app.buttons["modelJSONStage-\(stage)"]
            XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tap()
            app.buttons["shareRecognitionJSON"].tap()
            let copy = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Copy'")).firstMatch
            XCTAssertTrue(copy.waitForExistence(timeout: 5)); copy.tap()
            app.buttons["closeModelJSON"].tap()
            let copied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "semantic54-copy-verified-\(index + 1)"), object: app.staticTexts["semantic54-copy-status"])
            XCTAssertEqual(XCTWaiter.wait(for: [copied], timeout: 5), .completed)
        }
    }
    func testSemantic45LifecycleIsolationAndLateReplies() {
        let app = launch(["--semantic45-checks"])
        let status = app.staticTexts["semantic45-checks"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'passed' OR label BEGINSWITH 'FAILED'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 80), .completed)
        XCTAssertTrue(status.label.hasPrefix("passed"), status.label)
    }
    func testSemantic45SameCardUpdatesWithSecondJSONAndOriginalText() {
        checkSemantic45JSONStageSwitching([])
    }
    func testSemantic45JSONStageSwitchingAtMaximumType() {
        checkSemantic45JSONStageSwitching(["--maximum-type", "--dark"])
    }
    private func checkSemantic45JSONStageSwitching(_ arguments: [String]) {
        let app = launch(["--semantic45-ui"] + arguments)
        let start = app.buttons["semantic45-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10)); start.tap()
        let text = app.textViews["archiveText-1"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertTrue((text.value as? String ?? "").contains("初步簡介"))
        XCTAssertFalse(app.links["wikipedia-1"].exists)
        app.buttons["semantic45-finish"].tap()
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS '曙光公司持有這個品牌'"), object: text)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 8), .completed)
        XCTAssertTrue(app.links["wikipedia-1"].exists)
        app.buttons["modelJSON-1"].tap()
        let stages = app.descendants(matching: .any).matching(identifier: "modelJSONStage").firstMatch
        XCTAssertTrue(stages.waitForExistence(timeout: 5))
        for cycle in 1...3 {
            for (name, value, hasRaw) in [("第二階段回覆", 2, true), ("第二階段請求", 3, true), ("第一階段回覆", 1, false)] {
                let segment = app.buttons["modelJSONStage-\(value)"]
                XCTAssertTrue(segment.isHittable)
                let layout = XCTAttachment(string: stages.debugDescription)
                layout.name = "semantic45-stage-\(cycle)-\(name)-before-tap"; layout.lifetime = .keepAlways; add(layout)
                // Exercise one ordinary physical tap without retrying or
                // bypassing the control; verify selection and displayed raw text.
                segment.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: segment)
                XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed, stages.debugDescription)
                if hasRaw {
                    XCTAssertTrue((app.textViews["modelJSONText"].value as? String ?? "").contains(value == 2 ? "brand_owner" : "source_id"))
                    XCTAssertTrue(app.buttons["shareRecognitionJSON"].isHittable)
                } else {
                    XCTAssertTrue(app.staticTexts["modelJSONMessage"].label.contains("未保存原始 JSON"))
                    XCTAssertTrue(app.buttons["shareRecognitionJSON"].exists)
                    XCTAssertFalse(app.textViews["modelJSONText"].exists)
                }
            }
        }
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "semantic45-two-stage-json"; shot.lifetime = .keepAlways; add(shot)
    }
}


extension CaptureUITests {
    func testResume71ControllerLifecycleAndContinuation() {
        let app = launch(["--resume71-checks"])
        let status = app.staticTexts["resume71-checks"]
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != 'running'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 90), .completed)
        XCTAssertTrue(status.label.hasPrefix("passed "), status.label)
    }
}


extension CaptureUITests {
    func testResume71SingleActionProgressFailureAndSuccess() { checkResume71UI([]) }
    func testResume71SingleActionAtMaximumType() { checkResume71UI(["--maximum-type", "--dark"]) }
    private func checkResume71UI(_ options: [String]) {
        let app = launch(["--resume71-ui"] + options)
        let action = app.buttons["refreshRecognition-1"]
        XCTAssertTrue(action.waitForExistence(timeout: 20))
        scrollWait(action, "enabled == true")
        XCTAssertEqual(action.label, "繼續第二階段")
        XCTAssertTrue(app.staticTexts["archiveAttempt-1"].label.hasPrefix("第 1 次辨識・"))
        if !options.isEmpty {
            // Real history scrolling collapses the preview, making the large card actions visible.
            let list = historyList(in: app)
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -25)), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(action.isHittable)
        XCTAssertTrue(app.frame.contains(action.frame), "Action must be visible in the captured viewport")
        let frame = action.frame
        let stopped = XCTAttachment(screenshot: app.screenshot()); stopped.name = "resume71-stopped-\(options.isEmpty ? "normal" : "large")"; stopped.lifetime = .keepAlways; add(stopped)
        action.tap()
        scrollWait(action, "enabled == false")
        XCTAssertEqual(action.label, "辨識處理中")
        XCTAssertEqual(action.frame.size, frame.size)
        let pending = XCTAttachment(screenshot: app.screenshot()); pending.name = "resume71-progress"; pending.lifetime = .keepAlways; add(pending)
        scrollWait(app.staticTexts["resume71-counts"], "label == 'stage1=1 stage2=1'")
        app.buttons["resume71-fail"].tap()
        scrollWait(action, "enabled == true")
        XCTAssertEqual(action.label, "繼續第二階段")
        action.tap()
        scrollWait(app.staticTexts["resume71-counts"], "label == 'stage1=1 stage2=2'")
        app.buttons["resume71-finish"].tap()
        scrollWait(action, "enabled == true")
        XCTAssertEqual(action.label, "重新辨識這張圖片")
        XCTAssertTrue(app.links["wikipedia-1"].waitForExistence(timeout: 5))
        let done = XCTAttachment(screenshot: app.screenshot()); done.name = "resume71-completed"; done.lifetime = .keepAlways; add(done)
    }
    func testResume71ContextMenuDismissAndWholeImageSelection() {
        let app = launch(["--resume71-ui"])
        let action = app.buttons["refreshRecognition-1"]
        XCTAssertTrue(action.waitForExistence(timeout: 20)); scrollWait(action, "enabled == true")
        action.press(forDuration: 1)
        let whole = app.buttons["重新辨識整張"]
        XCTAssertTrue(whole.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["resume71-counts"].label, "stage1=1 stage2=0")
        let menu = XCTAttachment(screenshot: app.screenshot()); menu.name = "resume71-context-menu"; menu.lifetime = .keepAlways; add(menu)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        XCTAssertFalse(whole.exists)
        XCTAssertEqual(app.staticTexts["resume71-counts"].label, "stage1=1 stage2=0")
        XCTAssertEqual(action.label, "繼續第二階段")
        action.press(forDuration: 1); XCTAssertTrue(whole.waitForExistence(timeout: 5)); whole.tap()
        scrollWait(app.staticTexts["resume71-counts"], "label == 'stage1=2 stage2=0'")
        XCTAssertFalse(action.isEnabled)
        XCTAssertEqual(action.label, "辨識處理中")
        app.buttons["resume71-finish"].tap()
        scrollWait(app.staticTexts["resume71-counts"], "label == 'stage1=2 stage2=1'")
        app.buttons["resume71-finish"].tap(); scrollWait(action, "enabled == true")
        XCTAssertEqual(action.label, "重新辨識這張圖片")
    }
}


extension CaptureUITests {
    func testResume71SettingsSheetStopsAndReturnsContinuation() {
        let app = launch(["--resume71-ui"])
        let action = app.buttons["refreshRecognition-1"]
        XCTAssertTrue(action.waitForExistence(timeout: 20)); scrollWait(action, "enabled == true")
        action.tap(); scrollWait(app.staticTexts["resume71-counts"], "label == 'stage1=1 stage2=1'")
        app.buttons["設定"].tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 5)); app.buttons["完成"].tap()
        scrollWait(action, "enabled == true")
        XCTAssertEqual(action.label, "繼續第二階段")
        app.buttons["resume71-finish"].tap() // Deliver cancelled old request; it must not replace the stopped card.
        XCTAssertEqual(action.label, "繼續第二階段")
        XCTAssertEqual(app.staticTexts["resume71-counts"].label, "stage1=1 stage2=1")
        action.tap(); scrollWait(app.staticTexts["resume71-counts"], "label == 'stage1=1 stage2=2'")
        app.buttons["resume71-finish"].tap(); scrollWait(action, "enabled == true")
        XCTAssertEqual(action.label, "重新辨識這張圖片")
    }
}

extension CaptureUITests {
    func testBuild72BothCountsAtMaximumType() {
        checkResume71UI(["--maximum-type", "--dark"])
        let app = XCUIApplication(bundleIdentifier: "local.peiyu.Glance.C2Fixture")
        let whole = app.staticTexts["archiveAttempt-1"], semantic = app.staticTexts["semanticAttempt-1"]
        XCTAssertTrue(whole.label.hasPrefix("第 1 次辨識・已完成 ("))
        XCTAssertTrue(whole.label.hasSuffix(")"))
        XCTAssertFalse(whole.label.contains("重試"))
        XCTAssertFalse(semantic.exists)
        let list = historyList(in: app)
        for _ in 0..<20 {
            if whole.isHittable && list.frame.contains(whole.frame) { break }
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -120)), withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(list.frame.contains(whole.frame))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "build73-completed-status-maximum"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}

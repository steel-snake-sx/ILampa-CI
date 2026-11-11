import XCTest

final class LampaRuntimePresentationTests: XCTestCase {
    func testOriginalInterfaceCanBePresentedDismissedAndReopenedUsingSameWebView() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["--uitesting"]
        app.launch()
        let settingsTab = app.tabBars.buttons["Настройки"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10))
        settingsTab.tap()
        let sources = app.buttons["navSourcesManagement"]
        XCTAssertTrue(sources.waitForExistence(timeout: 5))
        sources.tap()
        let open = app.buttons["openLampaFromSourcesButton"]
        for _ in 0..<5 where !open.isHittable { app.swipeUp() }
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        let close = app.buttons["closeLampaSheetButton"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let webView = app.webViews.matching(NSPredicate(format: "identifier BEGINSWITH 'sharedLampaRuntime-'")).firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 10))
        let instanceID = webView.identifier
        let runtimeState = app.staticTexts["lampaRuntimeState"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label BEGINSWITH 'ready generation='"), object: runtimeState)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 75), .completed,
                       "Core and plugin restoration must reach ready, not merely show an empty web view")
        let readyGeneration = runtimeState.label
        XCTAssertGreaterThan(webView.frame.width, 300, "Shared runtime must occupy the visible sheet, not its hidden anchor")
        close.tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(webView.waitForExistence(timeout: 5))
        XCTAssertEqual(webView.identifier, instanceID, "Presentation must not create another WKWebView")
        XCTAssertEqual(runtimeState.label, readyGeneration, "Presentation must not restart the JavaScript document")
        XCTAssertGreaterThan(webView.frame.width, 300)
        app.buttons["reloadLampaButton"].tap()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label BEGINSWITH 'ready generation=' AND label != %@", readyGeneration), object: runtimeState)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 75), .completed,
                       "An explicit refresh must restore enabled plugins in a new ready generation")
        XCTAssertEqual(webView.identifier, instanceID, "Even a controlled document restart must reuse the view")
        close.tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
    }
}

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
    func testRealPluginDOMClickOpensNativePlayer() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["--uitesting", "--test-real-plugin-selection"]
        app.launch()

        let lampa = app.tabBars.buttons["Lampa"]
        XCTAssertTrue(lampa.waitForExistence(timeout: 15))
        let source = app.staticTexts["Apple Test Stream (BipBop 1080p)"]
        XCTAssertTrue(source.waitForExistence(timeout: 65),
            "A real plugin component must create source choices in the visible Lampa DOM")
        if !source.isHittable {
            app.webViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(source.isHittable, "The plugin stream must be tappable in WebKit")
        source.tap()
        let player = app.buttons["playerSettingsButton"]
        XCTAssertTrue(player.waitForExistence(timeout: 20),
            "A real trusted plugin row tap must reach AVPlayer, not stop at Component.add")
    }

    func testLampaIsAnInteractiveFirstClassTab() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["--uitesting"]
        app.launch()
        let tab = app.tabBars.buttons["Lampa"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10),
            "Native app must expose the unmodified Lampa plugin environment")
        tab.tap()
        let webView = app.webViews.matching(
            NSPredicate(format: "identifier BEGINSWITH 'sharedLampaRuntime-'")
        ).firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 20))
        XCTAssertGreaterThan(webView.frame.width, 300,
            "Plugin DOM must be a visible interactive WebKit surface")
        let state = app.staticTexts["lampaTabRuntimeState"]
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label BEGINSWITH 'ready generation='"),
            object: state)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 75), .completed,
            "Plugin UI must reach actual Lampa JS readiness, not just show an empty WKWebView")
        let instance = webView.identifier
        let generation = state.label
        let settings = app.tabBars.buttons["Настройки"]
        XCTAssertTrue(settings.exists)
        settings.tap()
        tab.tap()
        XCTAssertTrue(webView.waitForExistence(timeout: 10))
        XCTAssertEqual(webView.identifier, instance, "Tab switching must reuse the WKWebView")
        XCTAssertEqual(state.label, generation, "Tab switching must not restart the JS environment")
    }
}

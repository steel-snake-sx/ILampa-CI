import XCTest

final class AVKitControlUITests: XCTestCase {
    func testIndependentHLSSeekingPauseResumeAndReopen() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let close = app.buttons["controlClose"]
        XCTAssertTrue(close.waitForExistence(timeout: 15))
        XCTAssertTrue(close.isHittable)
        print("[IndependentAVKitUI] same native center-tap gesture as production test")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let scrubber = app.sliders.firstMatch
        XCTAssertTrue(scrubber.waitForExistence(timeout: 10), "Independent AVKit seek control must become available")
        scrubber.adjust(toNormalizedSliderPosition: 0.5)
        let predicate = NSPredicate(format: "label == 'Play/Pause' OR label CONTAINS[c] 'pause' OR (label CONTAINS[c] 'play' AND identifier != 'controlClose')")
        let transport = app.buttons.matching(predicate).firstMatch
        XCTAssertTrue(transport.waitForExistence(timeout: 5))
        transport.tap()
        XCTAssertTrue(transport.waitForExistence(timeout: 5))
        transport.tap()
        close.tap()
        let reopen = app.buttons["controlReopen"]
        XCTAssertTrue(reopen.waitForExistence(timeout: 10))
        reopen.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        XCTAssertTrue(close.isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "IndependentAVKit_Reopened"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        close.tap()
        XCTAssertTrue(reopen.waitForExistence(timeout: 10))
    }
}

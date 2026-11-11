import XCTest
import SwiftUI
@testable import iLampa

final class AppearanceModeTests: XCTestCase {
    func testPersistedModesMapToExpectedSchemes() {
        XCTAssertNil(AppearanceMode(storedValue: "system").colorScheme)
        XCTAssertEqual(AppearanceMode(storedValue: "light").colorScheme, .light)
        XCTAssertEqual(AppearanceMode(storedValue: "dark").colorScheme, .dark)
    }

    func testUnknownStoredValueFallsBackToSystem() {
        let mode = AppearanceMode(storedValue: "unknown")
        XCTAssertEqual(mode, .system)
        XCTAssertNil(mode.colorScheme)
    }
}

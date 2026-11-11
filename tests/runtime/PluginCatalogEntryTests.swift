import XCTest
@testable import iLampa

final class PluginCatalogEntryTests: XCTestCase {
    func testHTTPSIdentityKeepsQueryAndDropsFragment() {
        let url = PluginCatalogEntry.normalizedHTTPSURL("https://EXAMPLE.test/a.js?v=1#details")
        XCTAssertEqual(url?.absoluteString, "https://example.test/a.js?v=1")
        XCTAssertNotEqual(url, PluginCatalogEntry.normalizedHTTPSURL("https://example.test/a.js?v=2"))
    }

    func testInsecureOrCredentialedAddressesAreRejected() {
        XCTAssertNil(PluginCatalogEntry.normalizedHTTPSURL("http://example.test/a.js"))
        XCTAssertNil(PluginCatalogEntry.normalizedHTTPSURL("https://user:password@example.test/a.js"))
        XCTAssertNil(PluginCatalogEntry.normalizedHTTPSURL("not a url"))
    }
}

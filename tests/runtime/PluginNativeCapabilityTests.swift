import XCTest
@testable import iLampa

final class PluginNativeCapabilityTests: XCTestCase {
    func testMatchingContractsDoNotCrossOwnerOrGeneration() {
        let capability = PluginNativeCapability(owner: "https://example.test/plugin.js", generation: 3,
            id: "details", kind: .mediaDetail, contract: .structuredMetadata)
        XCTAssertTrue(capability.hasStructuredNativeContract)
        XCTAssertTrue(capability.matchesScope(owner: "https://example.test/plugin.js", generation: 3))
        XCTAssertFalse(capability.matchesScope(owner: "https://example.test/other.js", generation: 3))
        XCTAssertFalse(capability.matchesScope(owner: "https://example.test/plugin.js", generation: 4))
    }

    func testJavaScriptAndMismatchedContractsNeverQualify() {
        let dom = PluginNativeCapability(owner: "owner", generation: 1, id: "dom", kind: .catalogAction, contract: .javascriptOnly)
        let mismatch = PluginNativeCapability(owner: "owner", generation: 1, id: "setting", kind: .setting, contract: .structuredMetadata)
        let anonymous = PluginNativeCapability(owner: "", generation: 1, id: "setting", kind: .setting, contract: .booleanSetting)
        XCTAssertFalse(dom.hasStructuredNativeContract)
        XCTAssertFalse(mismatch.hasStructuredNativeContract)
        XCTAssertFalse(anonymous.matchesScope(owner: "", generation: 1))
    }

    func testStructuredMetadataValidationAndIdentity() {
        let capability = PluginNativeCapability(owner: "owner", generation: 1, id: "ratings", kind: .mediaDetail, contract: .structuredMetadata)
        let body: [String: Any] = ["title": "Ratings", "state": "ready", "fields": [["label": "Score", "value": "8.5"]]]
        let section = PluginMetadataSection.decode(body, capability: capability, canonicalId: "urn:media:tmdb:movie:1")
        XCTAssertEqual(section?.fields.first?.value, "8.5")
        XCTAssertEqual(section?.canonicalId, "urn:media:tmdb:movie:1")
        XCTAssertNil(PluginMetadataSection.decode(["title": "Ratings", "state": "ready", "fields": [["label": "", "value": "x"]]], capability: capability, canonicalId: "x"))
        XCTAssertNil(PluginMetadataSection.decode(["title": "Ratings", "state": "bogus", "fields": []], capability: capability, canonicalId: "x"))
        XCTAssertNil(PluginMetadataSection.decode(["title": "Ratings", "state": "ready", "fields": [["label": "x", "value": String(repeating: "x", count: 1001)]]], capability: capability, canonicalId: "x"))
    }
}

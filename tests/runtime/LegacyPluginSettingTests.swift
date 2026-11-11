import XCTest
@testable import iLampa

final class LegacyPluginSettingTests: XCTestCase {
    func testDescriptorPreservesLabelsOrderAndGeneration() throws {
        let json = """
        {"id":"12","owner":"plugin","generation":4,"component":"settings","componentName":"Settings",
         "type":"select","name":"Quality","description":"Choose quality","defaultValue":"a","placeholder":"","value":"b",
         "options":[{"value":"a","label":"Low"},{"value":"b","label":"High"}],"onRender":true}
        """
        let setting = try JSONDecoder().decode(LegacyPluginSetting.self, from: Data(json.utf8))
        XCTAssertEqual(setting.generation, 4)
        XCTAssertEqual(setting.options.map(\.label), ["Low", "High"])
        XCTAssertEqual(setting.value, "b")
        XCTAssertTrue(setting.onRender)
    }
}

import Foundation
@testable import LiveWallpaper
import XCTest

final class LocalWebSettingsTests: XCTestCase {
    func testConditionsHandleTypedValuesAndRejectExecutableCode() {
        let values: [String: WebPropertyValue] = [
            "mode": .string("workbench"),
            "enabled": .bool(true),
            "count": .number(3)
        ]
        XCTAssertEqual(
            LocalWebPropertyCondition
                .evaluate(
                    "(mode.value == 'workbench' || enabled.value == false) && count.value > 2",
                    values: values
                ),
            true
        )
        XCTAssertEqual(
            LocalWebPropertyCondition
                .evaluate("!enabled.value || count.value >= 4", values: values),
            false
        )
        XCTAssertEqual(
            LocalWebPropertyCondition.evaluate("count.value != 2 && enabled.value", values: values),
            true
        )
        XCTAssertEqual(
            LocalWebPropertyCondition
                .evaluate("count.value == '3' && enabled.value == 1", values: values),
            true
        )
        XCTAssertEqual(
            LocalWebPropertyCondition.evaluate("count.value === '3'", values: values),
            false
        )
        XCTAssertEqual(
            LocalWebPropertyCondition.evaluate("!count.value == true", values: values),
            false
        )
        XCTAssertNil(LocalWebPropertyCondition.evaluate("while(true){}", values: values))
        XCTAssertNil(LocalWebPropertyCondition.evaluate("mode.value.constructor()", values: values))
    }

    func testSettingsRoundTripPreservesValuesAndIntegrationChoices() throws {
        let id = UUID()
        defer { UserDefaults.standard.removeObject(forKey: "localWebSettings.\(id.uuidString)") }
        let settings = LocalWebSettings(
            values: ["enabled": .bool(false), "count": .number(17), "name": .string("夜の池")],
            audioReactiveEnabled: true,
            mediaEnabled: true
        )
        try settings.save(id: id)
        XCTAssertEqual(try LocalWebSettings.load(id: id), settings)
    }

}

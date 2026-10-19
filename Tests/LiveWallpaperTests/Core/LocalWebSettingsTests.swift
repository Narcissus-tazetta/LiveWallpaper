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

    func testBassReachesTheBandsUsedByBeatDrivenWallpapers() {
        let count = 1600
        let tone = (0 ..< count).map { Float(0.5 * sin(2 * .pi * 2800 * Double($0) / 48000)) }
        let analyzer = WebAudioSpectrum()
        let values = tone.withUnsafeBufferPointer { input in
            analyzer.append(
                left: input.baseAddress!,
                right: input.baseAddress!,
                frames: count,
                stride: 1,
                sampleRate: 48000
            )!
        }
        XCTAssertGreaterThan(values[0 ..< 31].reduce(0, +), 0.001)
    }

    func testSpectrumSeparatesStereoFrequenciesAndHasBoundedLevels() {
        let rate = 48000.0
        let count = 1600
        let left = (0 ..< count).map { Float(0.5 * sin(2 * .pi * 2800 * Double($0) / rate)) }
        let right = (0 ..< count).map { Float(0.5 * sin(2 * .pi * 5600 * Double($0) / rate)) }
        let analyzer = WebAudioSpectrum()
        let values = left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                analyzer.append(
                    left: l.baseAddress!,
                    right: r.baseAddress!,
                    frames: count,
                    stride: 1,
                    sampleRate: rate
                )!
            }
        }
        XCTAssertEqual(values.count, 128)
        let leftEnergy = values[0 ..< 31].reduce(0, +)
        let rightEnergy = values[64 ..< 95].reduce(0, +)
        XCTAssertGreaterThan(leftEnergy, 0.001)
        XCTAssertGreaterThan(rightEnergy, 0.001)
        // High bands (31..<64 and 95..<128) remain empty.
        for band in 31 ..< 64 {
            XCTAssertEqual(values[band], 0, accuracy: 0.0001)
            XCTAssertEqual(values[64 + band], 0, accuracy: 0.0001)
        }
        XCTAssertTrue(values.allSatisfy { $0.isFinite && (0 ... 1).contains($0) })
    }
}

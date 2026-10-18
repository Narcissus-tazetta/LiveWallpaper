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
        let tone = (0 ..< 2048).map { Float(0.4 * sin(2 * .pi * 64 * Double($0) / 48000)) }
        let analyzer = WebAudioSpectrum()
        let values = tone.withUnsafeBufferPointer { input in
            analyzer.append(
                left: input.baseAddress!,
                right: input.baseAddress!,
                frames: 2048,
                stride: 1,
                sampleRate: 48000
            )!
        }
        XCTAssertGreaterThan(values.prefix(3).reduce(0, +) / 3, 0.2)
    }

    func testSpectrumSeparatesStereoFrequenciesAndHasBoundedLevels() {
        let rate = 48000.0
        let count = WebAudioSpectrum.count
        let left = (0 ..< count).map { Float(0.3 * sin(2 * .pi * 440 * Double($0) / rate)) }
        let right = (0 ..< count).map { Float(0.1 * sin(2 * .pi * 4000 * Double($0) / rate)) }
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
        let leftPeak = (0 ..< 64).max { values[$0] < values[$1] }!
        let rightPeak = (0 ..< 64).max { values[64 + $0] < values[64 + $1] }!
        XCTAssertTrue((8 ... 11).contains(leftPeak), "\(leftPeak)")
        XCTAssertTrue((33 ... 37).contains(rightPeak), "\(rightPeak)")
        XCTAssertGreaterThan(values[leftPeak], 0.2)
        XCTAssertGreaterThan(values[rightPeak + 64], 0.08)
        XCTAssertTrue(values.allSatisfy { $0.isFinite && (0 ... 1).contains($0) })
    }
}

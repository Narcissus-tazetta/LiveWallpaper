import XCTest
@testable import LiveWallpaper

final class SpectrumLoudnessTests: XCTestCase {
    private func settle(_ raw: [Float], frames: Int = 120) -> [Float] {
        var loudness = SpectrumLoudness()
        var values = [Float]()
        for _ in 0 ..< frames { values = loudness.process(raw, elapsed: 1.0 / 30) }
        return values
    }

    private func spectrum(band: Int, level: Float) -> [Float] {
        var raw = [Float](repeating: 0, count: 128)
        raw[band] = level
        return raw
    }

    func testSteadyQuietSoundReachesTheSameHeightAsLoudSound() {
        let quiet = settle(spectrum(band: 10, level: 0.02))
        let loud = settle(spectrum(band: 10, level: 0.5))
        XCTAssertEqual(quiet[10], loud[10], accuracy: 0.05)
        XCTAssertGreaterThan(quiet[10], 0.8)
    }

    func testQuietChannelIsOnlyRaisedToAThirdOfTheLoudestGroup() {
        var raw = spectrum(band: 10, level: 0.5)
        raw[64 + 10] = 0.05
        let values = settle(raw)
        XCTAssertEqual(values[10], 1, accuracy: 0.05)
        XCTAssertEqual(values[74], 0.05 / (0.5 * 0.333), accuracy: 0.05)
    }

    func testSilenceIsExactlyZero() {
        let values = settle([Float](repeating: 0.00005, count: 128))
        XCTAssertTrue(values.allSatisfy { $0 == 0 })
    }

    func testRiseIsLimitedPerFrame() {
        var loudness = SpectrumLoudness()
        let values = loudness.process(spectrum(band: 3, level: 0.5), elapsed: 1.0 / 30)
        XCTAssertLessThanOrEqual(values[3], 40.0 / 30 + 0.0001)
        XCTAssertGreaterThan(values[3], 0.3)
    }

    func testSceneBandsTakeTheLoudestOfTheBandsTheyCover() {
        var left = [Float](repeating: 0, count: 64)
        left[5] = 0.9
        let audio = SceneAudioSpectrum(left: left, right: [Float](repeating: 0, count: 64))
        XCTAssertEqual(audio.bands(16, right: false)[1], 0.9)
        XCTAssertEqual(audio.bands(32, right: false)[2], 0.9)
    }
}

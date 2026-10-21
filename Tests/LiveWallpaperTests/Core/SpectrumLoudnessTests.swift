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

    func testSourceBelowTheDivisorFloorStillReachesFullHeight() {
        let quiet = settle(spectrum(band: 10, level: 0.0003), frames: 300)
        XCTAssertGreaterThan(quiet[10], 0.8)
    }

    func testQuietChannelIsOnlyRaisedToAThirdOfTheLoudestGroup() {
        var raw = spectrum(band: 10, level: 0.5)
        raw[64 + 10] = 0.05
        let values = settle(raw)
        XCTAssertEqual(values[10], 1, accuracy: 0.05)
        XCTAssertEqual(values[74], 0.05 / (0.5 * 0.333), accuracy: 0.05)
    }

    func testQuietMomentMidSongDoesNotBlankTheFollowingBars() {
        var loudness = SpectrumLoudness()
        for _ in 0 ..< 120 { _ = loudness.process(spectrum(band: 10, level: 0.02), elapsed: 1.0 / 30) }
        for _ in 0 ..< 10 { _ = loudness.process(spectrum(band: 10, level: 0.00015), elapsed: 1.0 / 30) }
        var values = [Float]()
        for _ in 0 ..< 5 { values = loudness.process(spectrum(band: 10, level: 0.02), elapsed: 1.0 / 30) }
        XCTAssertGreaterThan(values[10], 0.8)
    }

    func testBarsRecoverSoonAfterTheVolumeIsLowered() {
        var loudness = SpectrumLoudness()
        for _ in 0 ..< 120 { _ = loudness.process(spectrum(band: 10, level: 0.004), elapsed: 1.0 / 30) }
        var values = [Float]()
        for _ in 0 ..< 90 { values = loudness.process(spectrum(band: 10, level: 0.0004), elapsed: 1.0 / 30) }
        XCTAssertGreaterThan(values[10], 0.8)
    }

    func testSilenceIsExactlyZero() {
        let values = settle([Float](repeating: 0.00005, count: 128))
        XCTAssertTrue(values.allSatisfy { $0 == 0 })
    }

    func testQuietSoundDoesNotBlinkWhenCrossingTheSilenceThreshold() {
        var loudness = SpectrumLoudness()
        for frame in 0 ..< 120 {
            let level: Float = frame % 3 == 0 ? 0.00015 : 0.00006
            let values = loudness.process(spectrum(band: 10, level: level), elapsed: 1.0 / 30)
            XCTAssertGreaterThan(values[10], 0, "frame \(frame)")
        }
    }

    func testBriefQuietDipsDoNotMuteTheSpectrum() {
        var loudness = SpectrumLoudness()
        for frame in 0 ..< 120 {
            let level: Float = frame % 3 == 0 ? 0.00015 : 0.000001
            let values = loudness.process(spectrum(band: 10, level: level), elapsed: 1.0 / 30)
            XCTAssertGreaterThan(values[10], 0, "frame \(frame)")
        }
    }

    func testSustainedSilenceClearsTheSpectrumAndItsSmoothingHistory() {
        var loudness = SpectrumLoudness()
        for _ in 0 ..< 120 {
            _ = loudness.process(spectrum(band: 10, level: 0.02), elapsed: 1.0 / 30)
        }
        var values = [Float]()
        for _ in 0 ..< 4 {
            values = loudness.process(spectrum(band: 10, level: 0.00004), elapsed: 1.0 / 30)
        }
        XCTAssertTrue(values.allSatisfy { $0 == 0 })

        values = loudness.process(spectrum(band: 20, level: 0.02), elapsed: 1.0 / 30)
        XCTAssertEqual(values[10], 0)
        XCTAssertGreaterThan(values[20], 0)
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

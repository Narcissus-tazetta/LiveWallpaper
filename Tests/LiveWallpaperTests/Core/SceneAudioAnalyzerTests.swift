import XCTest
@testable import LiveWallpaper

/// Expected values come from recordings of the original player playing the same tones.
final class SceneAudioAnalyzerTests: XCTestCase {
    private let sampleRate = 48000.0

    /// Feeds `seconds` of a tone (nil frequency is silence) and returns every frame's output.
    /// A nil level on one side leaves that channel silent.
    private func output(
        _ analyzer: SceneAudioAnalyzer,
        frequency: Double?,
        dBFS: Double = -20,
        right rightDBFS: Double?? = .none,
        seconds: Double
    ) -> [SceneAudioAnalyzer.Output] {
        let count = Int(seconds * sampleRate)
        func tone(_ level: Double?) -> [Float] {
            (0 ..< count).map { index in
                guard let frequency, let level else { return 0 }
                return Float(pow(10, level / 20) * sin(2 * .pi * frequency * Double(index) / sampleRate))
            }
        }
        let left = tone(dBFS)
        let right = rightDBFS.map(tone) ?? left
        var frames = [SceneAudioAnalyzer.Output]()
        left.withUnsafeBufferPointer { left in
            right.withUnsafeBufferPointer { right in
                for start in stride(from: 0, to: count, by: 960) {
                    let length = min(960, count - start)
                    if let values = analyzer.append(left: left.baseAddress! + start, right: right.baseAddress! + start, frames: length, stride: 1) {
                        frames.append(values)
                    }
                }
            }
        }
        return frames
    }

    private func play(_ analyzer: SceneAudioAnalyzer, frequency: Double?, dBFS: Double = -20, seconds: Double) -> [[Float]] {
        output(analyzer, frequency: frequency, dBFS: dBFS, seconds: seconds).map(\.scene)
    }

    func testTonesLandInTheRecordedBands() {
        for (frequency, band) in [(105.0, 4), (483.0, 20), (1001.0, 32), (4290.0, 47), (8315.0, 55), (14118.0, 63), (21000.0, 63)] {
            let analyzer = SceneAudioAnalyzer(sampleRate: sampleRate)
            let last = play(analyzer, frequency: frequency, seconds: 3).last!
            XCTAssertEqual(last[..<64].indices.max { last[$0] < last[$1] }, band, "\(frequency) Hz")
            XCTAssertEqual(last[band], 1, accuracy: 0.02, "\(frequency) Hz")
        }
    }

    func testRiseAfterSilenceTakesAboutTwoSecondsAtMinusTwentyDecibels() {
        let analyzer = SceneAudioAnalyzer(sampleRate: sampleRate)
        _ = play(analyzer, frequency: nil, seconds: 1)
        let frames = play(analyzer, frequency: 1000, seconds: 3).map { $0[32] }
        // Recorded: 1/output falls in a straight line, 0.065 at 0.2 s, 0.117 at 1 s, 0.98 at about 1.9 s.
        XCTAssertEqual(frames[6], 0.065, accuracy: 0.005)
        XCTAssertEqual(frames[30], 0.117, accuracy: 0.008)
        XCTAssertLessThan(frames[54], 0.98)
        XCTAssertGreaterThan(frames[60], 0.98)
    }

    func testShortSilenceKeepsTheGainAndLongerSilenceResetsIt() {
        for (gap, resets) in [(0.1, false), (0.4, true)] {
            let analyzer = SceneAudioAnalyzer(sampleRate: sampleRate)
            _ = play(analyzer, frequency: 1000, seconds: 3)
            _ = play(analyzer, frequency: nil, seconds: gap)
            let resumed = play(analyzer, frequency: 1000, seconds: 0.3).last![32]
            XCTAssertEqual(resumed < 0.5, resets, "\(gap) s of silence")
        }
    }

    func testWebBandsFollowTheAmplitudeWithoutGain() {
        // Recorded at bin 32 for 1 kHz: -50 dBFS 0.0018, -30 dBFS 0.0180, 0 dBFS 0.563.
        for (dBFS, recorded) in [(-50.0, 0.0018), (-30.0, 0.0180), (0.0, 0.563)] {
            let analyzer = SceneAudioAnalyzer(sampleRate: sampleRate)
            let web = output(analyzer, frequency: 1000, dBFS: dBFS, seconds: 1).last!.web
            XCTAssertEqual(Double(web[32]), recorded, accuracy: recorded * 0.03, "\(dBFS) dBFS")
        }
        // 4 kHz at -20 dBFS was recorded at bin 46 as 0.240.
        let analyzer = SceneAudioAnalyzer(sampleRate: sampleRate)
        let web = output(analyzer, frequency: 4000, seconds: 1).last!.web
        XCTAssertEqual(web[..<64].indices.max { web[$0] < web[$1] }, 46)
        XCTAssertEqual(web[46], 0.240, accuracy: 0.01)
    }

    func testWebBandsKeepLeftThenRight() {
        let analyzer = SceneAudioAnalyzer(sampleRate: sampleRate)
        let web = output(analyzer, frequency: 1000, right: .some(nil), seconds: 1).last!.web
        XCTAssertEqual(web[32], 0.0566, accuracy: 0.002)
        XCTAssertEqual(web[64...].max()!, 0)
    }
}

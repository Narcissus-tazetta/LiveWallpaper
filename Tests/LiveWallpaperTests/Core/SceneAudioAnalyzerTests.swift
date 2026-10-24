import XCTest
@testable import LiveWallpaper

/// Expected values come from recordings of the original player playing the same tones.
final class SceneAudioAnalyzerTests: XCTestCase {
    private let sampleRate = 48000.0

    /// Feeds `seconds` of a tone (nil frequency is silence) and returns every frame's 128 values.
    private func play(_ analyzer: SceneAudioAnalyzer, frequency: Double?, dBFS: Double = -20, seconds: Double) -> [[Float]] {
        let count = Int(seconds * sampleRate)
        let amplitude = pow(10, dBFS / 20)
        let samples = (0 ..< count).map { index in
            frequency.map { Float(amplitude * sin(2 * .pi * $0 * Double(index) / sampleRate)) } ?? 0
        }
        var frames = [[Float]]()
        samples.withUnsafeBufferPointer { buffer in
            for start in stride(from: 0, to: count, by: 960) {
                let length = min(960, count - start)
                if let values = analyzer.append(left: buffer.baseAddress! + start, right: buffer.baseAddress! + start, frames: length, stride: 1) {
                    frames.append(values)
                }
            }
        }
        return frames
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
}

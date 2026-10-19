import XCTest
@testable import LiveWallpaper

final class WebAudioSpectrumTests: XCTestCase {
    func testNativePipelineLeavesHighBandsEmpty() {
        let spectrum = WebAudioSpectrum()
        let sampleRate = 48000.0
        let frames = 1600 // 1/30s at 48kHz
        let samples = [Float](repeating: 0.5, count: frames)
        var output: [Float]?
        samples.withUnsafeBufferPointer { ptr in
            output = spectrum.append(
                left: ptr.baseAddress!,
                right: ptr.baseAddress!,
                frames: frames,
                stride: 1,
                sampleRate: sampleRate
            )
        }
        XCTAssertNotNil(output)
        guard let output else { return }
        XCTAssertEqual(output.count, 128)
        // Native clamp restricts assignment to bands 0..<31,
        // leaving bands 31..<64 (and 95..<128 for right channel) zero.
        for band in 31 ..< 64 {
            XCTAssertEqual(output[band], 0, accuracy: 0.0001)
            XCTAssertEqual(output[64 + band], 0, accuracy: 0.0001)
        }
    }

    func testSineToneGeneratesNonZeroEnergyInLowBands() {
        let spectrum = WebAudioSpectrum()
        let sampleRate = 48000.0
        let frames = 1600
        var samples = [Float](repeating: 0, count: frames)
        for index in 0 ..< frames {
            // ~5647Hz tone (bin 2 in 17-point DFT at 48kHz)
            samples[index] = sin(2.0 * Float.pi * 5647.0 * Float(index) / Float(sampleRate))
        }
        var output: [Float]?
        samples.withUnsafeBufferPointer { ptr in
            output = spectrum.append(
                left: ptr.baseAddress!,
                right: ptr.baseAddress!,
                frames: frames,
                stride: 1,
                sampleRate: sampleRate
            )
        }
        XCTAssertNotNil(output)
        guard let output else { return }
        let lowEnergy = output[0 ..< 31].reduce(0, +)
        XCTAssertGreaterThan(lowEnergy, 0.01)
    }
}

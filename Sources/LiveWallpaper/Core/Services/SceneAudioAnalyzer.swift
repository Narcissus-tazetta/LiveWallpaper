import Accelerate
import Foundation

/// The system audio as imported scenes and web wallpapers expect it: 64 bands per channel.
/// Scenes get each group of 8 bands scaled by its own slowly tracked peak; web wallpapers get
/// the same bands without any gain, proportional to the amplitude.
///
/// The sizes and the scale were fitted to recordings of the original player playing known
/// tones (bands, leakage and the rise after silence match to about 0.01). The original's
/// analysis code that was read uses a 17-point transform, which cannot produce the 23 Hz
/// bands those recordings show; the path that produces them was not found.
final class SceneAudioAnalyzer {
    /// The transform is this long, but only the newest `windowLength` samples are filled; the
    /// rest stays zero. That zero padding is what puts a near-null in every third band of a
    /// tone's leakage, as the recordings do.
    let transformLength: Int
    let windowLength: Int
    /// Bins 1 ..< `bandSpan` spread over the 64 bands; every bin above lands in the last one.
    private static let bandSpan = 640
    private static let sceneScale: Float = 0.008635
    /// Fitted to the original's web array at steady 1 kHz tones from -50 to 0 dBFS (0.563 at
    /// 0 dBFS); its bands and leakage then match to the 1e-4 the recordings were rounded to.
    /// It sits 1 % under `sceneScale`, which was fitted less directly, through the auto gain.
    private static let webScale: Float = 0.008552
    let sampleRate: Double
    private let paddedLength: Int
    private let log2PaddedLength: vDSP_Length
    private let setup: FFTSetup
    private let chirpReal: [Float]
    private let chirpImaginary: [Float]
    private let kernelReal: [Float]
    private let kernelImaginary: [Float]
    private let bandOfBin: [Int]
    private let weightOfBin: [Float]
    private var left: [Float]
    private var right: [Float]
    private var cursor = 0
    private var sinceLastOutput = 0
    private var loudness = SceneSpectrumLoudness()
    private var workReal: [Float]
    private var workImaginary: [Float]

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        let factor = max(Float(sampleRate) / 44100, 1) * 64
        transformLength = Int(factor * 30)
        windowLength = Int(factor * 20)
        left = [Float](repeating: 0, count: windowLength)
        right = [Float](repeating: 0, count: windowLength)

        // A transform of any length through power-of-two FFTs (Bluestein): the chirp turns
        // the DFT into a convolution with the kernel.
        let count = transformLength
        var log2 = 0
        while 1 << log2 < 2 * count - 1 { log2 += 1 }
        paddedLength = 1 << log2
        let log2Length = vDSP_Length(log2)
        log2PaddedLength = log2Length
        let setup = vDSP_create_fftsetup(log2Length, FFTRadix(kFFTRadix2))!
        self.setup = setup
        var chirpReal = [Float](repeating: 0, count: count)
        var chirpImaginary = [Float](repeating: 0, count: count)
        var kernelReal = [Float](repeating: 0, count: paddedLength)
        var kernelImaginary = [Float](repeating: 0, count: paddedLength)
        for index in 0 ..< count {
            // n² mod 2N keeps the angle exact for large n.
            let angle = Double.pi * Double(index * index % (2 * count)) / Double(count)
            chirpReal[index] = Float(cos(angle))
            chirpImaginary[index] = Float(-sin(angle))
            kernelReal[index] = Float(cos(angle))
            kernelImaginary[index] = Float(sin(angle))
            if index > 0 {
                kernelReal[paddedLength - index] = Float(cos(angle))
                kernelImaginary[paddedLength - index] = Float(sin(angle))
            }
        }
        kernelReal.withUnsafeMutableBufferPointer { real in
            kernelImaginary.withUnsafeMutableBufferPointer { imaginary in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, log2Length, FFTDirection(kFFTDirection_Forward))
            }
        }
        self.chirpReal = chirpReal
        self.chirpImaginary = chirpImaginary
        self.kernelReal = kernelReal
        self.kernelImaginary = kernelImaginary
        workReal = [Float](repeating: 0, count: paddedLength)
        workImaginary = [Float](repeating: 0, count: paddedLength)

        let span = Self.bandSpan
        var bandOfBin = [Int]()
        var weightOfBin = [Float]()
        var previous = 0
        for bin in 1 ... count / 2 {
            let position = Float(bin - 1) / Float(span - 1)
            let target = min(Int(pow(position, 0.25) * 64), 63)
            let band = min(target, previous + 1)
            previous = band
            bandOfBin.append(band)
            weightOfBin.append(0.501 - 0.499 * cos(Float(bin - 1) * .pi / Float(span - 1)))
        }
        self.bandOfBin = bandOfBin
        self.weightOfBin = weightOfBin
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    struct Output {
        var scene: [Float]
        var web: [Float]
    }

    /// Analyses every 1/30 s of audio and returns the newest result, each 64 left bands then
    /// 64 right bands, or nil when no thirtieth ended in these frames.
    func append(
        left inputLeft: UnsafePointer<Float>,
        right inputRight: UnsafePointer<Float>,
        frames: Int,
        stride: Int
    ) -> Output? {
        // The auto gain advances by the time it is given, so each step is exactly one
        // period, cut at the sample where it ends, whatever size the capture's blocks are.
        let period = Int(sampleRate / 30)
        var result: Output?
        for index in 0 ..< frames {
            left[cursor] = inputLeft[index * stride]
            right[cursor] = inputRight[index * stride]
            cursor = (cursor + 1) % windowLength
            sinceLastOutput += 1
            if sinceLastOutput == period {
                sinceLastOutput = 0
                let raw = bands(left) + bands(right)
                result = Output(
                    scene: loudness.process(raw.map { $0 * Self.sceneScale }, elapsed: Float(Double(period) / sampleRate)),
                    web: raw.map { $0 * Self.webScale }
                )
            }
        }
        return result
    }

    /// Unscaled.
    private func bands(_ samples: [Float]) -> [Float] {
        for index in 0 ..< windowLength {
            let sample = samples[(cursor + index) % windowLength]
            workReal[index] = sample * chirpReal[index]
            workImaginary[index] = sample * chirpImaginary[index]
        }
        for index in windowLength ..< paddedLength {
            workReal[index] = 0
            workImaginary[index] = 0
        }
        workReal.withUnsafeMutableBufferPointer { real in
            workImaginary.withUnsafeMutableBufferPointer { imaginary in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, log2PaddedLength, FFTDirection(kFFTDirection_Forward))
                kernelReal.withUnsafeBufferPointer { kernelReal in
                    kernelImaginary.withUnsafeBufferPointer { kernelImaginary in
                        var kernel = DSPSplitComplex(
                            realp: UnsafeMutablePointer(mutating: kernelReal.baseAddress!),
                            imagp: UnsafeMutablePointer(mutating: kernelImaginary.baseAddress!)
                        )
                        vDSP_zvmul(&split, 1, &kernel, 1, &split, 1, vDSP_Length(paddedLength), 1)
                    }
                }
                vDSP_fft_zip(setup, &split, 1, log2PaddedLength, FFTDirection(kFFTDirection_Inverse))
            }
        }
        // The output chirp has magnitude 1, so the energy needs only the inverse FFT's scale.
        let inverseScale = 1 / Float(paddedLength)
        var result = [Float](repeating: 0, count: 64)
        for (offset, band) in bandOfBin.enumerated() {
            let bin = offset + 1
            let real = workReal[bin] * inverseScale
            let imaginary = workImaginary[bin] * inverseScale
            let value = sqrt((real * real + imaginary * imaginary) * weightOfBin[offset])
            result[band] = max(result[band], value)
        }
        return result
    }
}

/// Per-group auto gain as in the original: each group of 8 bands is divided by a peak that
/// rises by at most 1 and falls by at most 0.5 per second, and a group with little energy is
/// floored at a third of the loudest. These steps reproduce the original's recordings:
/// the linear rise of 1/output after silence, the overshoot when the level steps up, and the
/// reset after about 0.25 s of silence (the low group's small peak halves every frame until
/// it falls under the silence level).
struct SceneSpectrumLoudness {
    static let groupSize = 8
    private static let floor: Float = 0.001
    private static let silence: Float = 0.0001
    private var peaks = [Float](repeating: 0, count: 16)
    private var smoothed = [Float](repeating: 0, count: 128)
    private var output = [Float](repeating: 0, count: 128)

    /// `raw` is 64 left bands then 64 right bands; `elapsed` is the time since the last call.
    mutating func process(_ raw: [Float], elapsed: Float) -> [Float] {
        let dt = min(elapsed, 1)
        var groupMax = (0 ..< 16).map { raw[$0 * Self.groupSize ..< ($0 + 1) * Self.groupSize].max()! }
        let loudest = groupMax.max()!
        let isSilent = loudest < Self.silence
        for group in 0 ..< 16 { groupMax[group] = max(groupMax[group], loudest * 0.333) }

        if peaks[0] <= Self.silence, !isSilent {
            peaks = [Float](repeating: 1, count: 16)
        }
        for group in 0 ..< 16 {
            let difference = groupMax[group] - peaks[group]
            if abs(difference) <= Self.silence {
                peaks[group] = groupMax[group]
            } else {
                peaks[group] += min(abs(difference), dt) * (difference > 0 ? 1 : -0.5)
            }
        }

        guard !isSilent else {
            output = [Float](repeating: 0, count: 128)
            return output
        }
        let blend = min(1, dt * 20)
        let rise = dt * 40
        let fall = max(-1, dt * -40)
        for index in 0 ..< 128 {
            let target = raw[index] / max(peaks[index / Self.groupSize], Self.floor)
            smoothed[index] += (target - smoothed[index]) * blend
            let change = smoothed[index] - output[index]
            output[index] += change > 0 ? min(change, rise) : max(change, fall)
        }
        return output
    }
}

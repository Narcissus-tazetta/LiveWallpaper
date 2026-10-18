import Accelerate
import AVFoundation
import CoreMedia
import ScreenCaptureKit

final class WebAudioSpectrum {
    static let count = 2048
    private let transform = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(count), .FORWARD)!
    private var window = [Float](repeating: 0, count: count)
    private var left = [Float](repeating: 0, count: count)
    private var right = [Float](repeating: 0, count: count)
    private var cursor = 0
    private var filled = 0
    private var sinceLastOutput = 0
    private var real = [Float](repeating: 0, count: count)
    private var imaginary = [Float](repeating: 0, count: count)
    private var outputReal = [Float](repeating: 0, count: count)
    private var outputImaginary = [Float](repeating: 0, count: count)
    private var windowSum: Float = 0
    private var loudness = SpectrumLoudness()

    init() {
        vDSP_hann_window(&window, vDSP_Length(Self.count), Int32(vDSP_HANN_NORM))
        vDSP_sve(window, 1, &windowSum, vDSP_Length(Self.count))
    }

    deinit { vDSP_DFT_DestroySetup(transform) }

    func append(
        left inputLeft: UnsafePointer<Float>,
        right inputRight: UnsafePointer<Float>,
        frames: Int,
        stride: Int,
        sampleRate: Double
    ) -> [Float]? {
        for index in 0 ..< frames {
            left[cursor] = inputLeft[index * stride]
            right[cursor] = inputRight[index * stride]
            cursor = (cursor + 1) % Self.count
        }
        filled = min(Self.count, filled + frames)
        sinceLastOutput += frames
        guard filled == Self.count, sinceLastOutput >= Int(sampleRate / 30) else { return nil }
        let elapsed = Float(Double(sinceLastOutput) / sampleRate)
        sinceLastOutput %= Int(sampleRate / 30)
        return loudness.process(
            bands(left, sampleRate: sampleRate) + bands(right, sampleRate: sampleRate),
            elapsed: elapsed
        )
    }

    private func bands(_ samples: [Float], sampleRate: Double) -> [Float] {
        for index in 0 ..< Self
            .count
        {
            real[index] = samples[(cursor + index) % Self.count] * window[index]
        }
        vDSP_DFT_Execute(transform, real, imaginary, &outputReal, &outputImaginary)
        var result = [Float](repeating: 0, count: 64)
        let upper = min(20000, sampleRate / 2)
        let normalization = 2 / windowSum
        for band in 0 ..< 64 {
            // Beat-driven packages often average the first three bands; a mel scale
            // keeps common kick-drum frequencies inside that low-frequency region.
            let low = 700 * (pow(1 + upper / 700, Double(band) / 64) - 1)
            let high = 700 * (pow(1 + upper / 700, Double(band + 1) / 64) - 1)
            let start = max(1, Int((low * Double(Self.count) / sampleRate).rounded()))
            let end = min(
                Self.count / 2,
                max(start + 1, Int((high * Double(Self.count) / sampleRate).rounded()))
            )
            var energy: Float = 0
            for bin in start ..< end {
                energy += outputReal[bin] * outputReal[bin] + outputImaginary[bin] *
                    outputImaginary[bin]
            }
            result[band] = sqrt(energy) * normalization
        }
        return result
    }
}

/// Wallpaper Engine's per-group auto gain and smoothing, read from its executable.
/// Each channel's 64 bands are split into groups of 8; every group is divided by its own
/// slowly tracked peak, so a quiet passage still moves the bars. Output is not clamped
/// to 1: the original leaves that to the shader.
struct SpectrumLoudness {
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
        // Without this floor a group with no energy would be amplified to full height by
        // its own tiny peak.
        for group in 0 ..< 16 { groupMax[group] = max(groupMax[group], loudest * 0.333) }

        if peaks[0] <= Self.silence, !isSilent {
            peaks = [Float](repeating: 1, count: 16)
        }
        for group in 0 ..< 16 {
            let difference = groupMax[group] - peaks[group]
            if abs(difference) <= Self.silence {
                peaks[group] = groupMax[group]
            } else {
                // Rises by at most 1 per second and falls by at most 0.5 per second.
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

final class WebSystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "LiveWallpaper.webSpectrum", qos: .userInitiated)
    @MainActor private var stream: SCStream?
    private let spectrum = WebAudioSpectrum()
    let onSpectrum: @Sendable ([Float]) -> Void
    let onFailure: @Sendable (Error) -> Void

    init(
        onSpectrum: @escaping @Sendable ([Float]) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        self.onSpectrum = onSpectrum
        self.onFailure = onFailure
    }

    @MainActor func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else { throw CocoaError(.featureUnsupported) }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 2
        // ScreenCaptureKit needs a display filter even for an audio-only output.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }

    @MainActor func stop() async throws {
        guard let stream else { return }
        self.stream = nil
        try await stream.stopCapture()
    }

    func stream(_: SCStream, didStopWithError error: Error) {
        onFailure(error)
    }

    func stream(
        _: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid,
              let format = sampleBuffer.formatDescription,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)
        else { return }
        do {
            try sampleBuffer.withAudioBufferList { list, _ in
                let buffers = UnsafeMutableAudioBufferListPointer(list.unsafeMutablePointer)
                guard let first = buffers.first, let data = first.mData,
                      description.pointee.mFormatID == kAudioFormatLinearPCM,
                      description.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                      description.pointee.mBitsPerChannel == 32
                else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                let nonInterleaved = description.pointee
                    .mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
                let channels = Int(description.pointee.mChannelsPerFrame)
                let stride = nonInterleaved ? 1 : channels
                let left = data.assumingMemoryBound(to: Float.self)
                let right = channels < 2 ? left : nonInterleaved
                    ? buffers[1].mData!.assumingMemoryBound(to: Float.self) : left.advanced(by: 1)
                if let values = spectrum.append(
                    left: left,
                    right: right,
                    frames: sampleBuffer.numSamples,
                    stride: stride,
                    sampleRate: description.pointee.mSampleRate
                ) {
                    onSpectrum(values)
                }
            }
        } catch { onFailure(error) }
    }
}

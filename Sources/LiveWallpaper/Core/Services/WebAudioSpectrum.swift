import Accelerate
import AVFoundation
import CoreMedia
import ScreenCaptureKit

final class WebAudioSpectrum {
    static let maxHistory = 32
    private var left = [Float](repeating: 0, count: maxHistory)
    private var right = [Float](repeating: 0, count: maxHistory)
    private var cursor = 0
    private var filled = 0
    private var sinceLastOutput = 0
    private var loudness = SpectrumLoudness()

    func append(
        left inputLeft: UnsafePointer<Float>,
        right inputRight: UnsafePointer<Float>,
        frames: Int,
        stride: Int,
        sampleRate: Double
    ) -> [Float]? {
        let count = max(16, Int((max(sampleRate / 44100.0, 1.0) * 16.0).rounded(.towardZero)))
        for index in 0 ..< frames {
            left[cursor] = inputLeft[index * stride]
            right[cursor] = inputRight[index * stride]
            cursor = (cursor + 1) % count
        }
        filled = min(count, filled + frames)
        sinceLastOutput += frames
        guard filled == count, sinceLastOutput >= Int(sampleRate / 30) else { return nil }
        let elapsed = Float(Double(sinceLastOutput) / sampleRate)
        sinceLastOutput %= Int(sampleRate / 30)
        return loudness.process(
            bands(left, count: count) + bands(right, count: count),
            elapsed: elapsed
        )
    }

    private func bands(_ samples: [Float], count: Int) -> [Float] {
        var result = [Float](repeating: 0, count: 64)
        var prevBand = 0
        let scale: Float = 0.001 * (64.0 / Float(count))
        for bin in 1 ..< 32 {
            var real: Float = 0
            var imaginary: Float = 0
            if bin < count {
                let angleStep = -2.0 * Float.pi * Float(bin) / Float(count)
                for index in 0 ..< count {
                    let sample = samples[(cursor + index) % count]
                    let angle = angleStep * Float(index)
                    real += sample * cos(angle)
                    imaginary += sample * sin(angle)
                }
            }
            let energy = real * real + imaginary * imaginary
            let theta = Float(bin - 1) * Float.pi / 31.0
            let windowFactor = 0.501 - 0.499 * cos(theta)
            let value = sqrt(max(0, energy * windowFactor)) * scale

            let norm = Float(bin - 1) / 31.0
            let targetBand = Int(pow(norm, 0.25) * 64.0) & 0x3F
            // Clamps each bin's target band to at most prevBand + 1,
            // leaving bands 31..<64 permanently empty.
            let band = min(targetBand, prevBand + 1)
            prevBand = band
            result[band] = max(result[band], value)
        }
        return result
    }
}

/// Per-group auto gain and smoothing, matching native behavior.
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

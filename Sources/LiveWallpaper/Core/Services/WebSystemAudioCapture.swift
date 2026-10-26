import Accelerate
import AVFoundation
import CoreMedia
import ScreenCaptureKit

final class WebSystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "LiveWallpaper.webSpectrum", qos: .userInitiated)
    @MainActor private var stream: SCStream?
    /// Created for the stream's sample rate, which sizes its transform.
    private var analyzer: SceneAudioAnalyzer?
    let onSpectrum: @Sendable ([Float]) -> Void
    let onSceneSpectrum: @Sendable ([Float]) -> Void
    let onFailure: @Sendable (Error) -> Void

    init(
        onSpectrum: @escaping @Sendable ([Float]) -> Void,
        onSceneSpectrum: @escaping @Sendable ([Float]) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        self.onSpectrum = onSpectrum
        self.onSceneSpectrum = onSceneSpectrum
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
                let sampleRate = description.pointee.mSampleRate
                if analyzer?.sampleRate != sampleRate {
                    analyzer = SceneAudioAnalyzer(sampleRate: sampleRate)
                }
                if let output = analyzer!.append(left: left, right: right, frames: sampleBuffer.numSamples, stride: stride) {
                    onSpectrum(output.web)
                    onSceneSpectrum(output.scene)
                }
            }
        } catch { onFailure(error) }
    }
}

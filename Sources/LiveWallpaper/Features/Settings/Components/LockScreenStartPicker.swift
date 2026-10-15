import AVFoundation
import SwiftUI

/// Picks the frame the lock screen video begins at. That frame is also what the
/// desktop shows after the app quits, so the slider shows it as it moves. Saving
/// re-encodes the video, which takes minutes, so it waits for the Save button.
struct LockScreenStartPicker: View {
    @ObservedObject var model: WallpaperModel
    let videoPath: String
    let isDisabled: Bool

    @State private var isManual = false
    @State private var seconds: Double = 0
    @State private var duration: Double?
    @State private var frame: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(selection: manualBinding) {
                Text(model.localizedString("自動")).tag(false)
                Text(model.localizedString("指定")).tag(true)
            } label: {
                Text(model.localizedString("開始位置"))
            }
            .pickerStyle(.menu)
            .fixedSize()

            if isManual, let duration {
                HStack(alignment: .center, spacing: 10) {
                    framePreview
                    VStack(alignment: .leading, spacing: 2) {
                        Slider(value: $seconds, in: 0 ... duration)
                        HStack {
                            Text(Self.timeText(seconds))
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                            Spacer(minLength: 8)
                            Button(model.localizedString("保存")) {
                                model.setLockScreenStartSeconds(seconds)
                            }
                            .controlSize(.regular)
                            .disabled(model.lockScreenStartSeconds == seconds)
                        }
                    }
                }
            }

            Text(model.localizedString(
                isManual
                    ? "ロック画面と、アプリを終了している間のデスクトップは、このコマから始まります。それより前の部分は最後に回ります。保存すると変換し直します(数分かかることがあります)。"
                    : "先頭が暗い動画は、明るくなったコマから始めます。ロック画面と、アプリを終了している間のデスクトップに使われます。"
            ))
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(isDisabled)
        .task(id: videoPath) {
            isManual = model.lockScreenStartSeconds != nil
            seconds = model.lockScreenStartSeconds ?? 0
            duration = nil
            let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
            do {
                let loaded = try await asset.load(.duration).seconds
                guard loaded.isFinite, loaded > 0 else {
                    return
                }
                duration = loaded
            } catch {
                AppLog.lockScreenSync.error(
                    "lock screen start picker: duration unreadable: \(error.localizedDescription, privacy: .public)"
                )
                return
            }
            seconds = min(seconds, duration ?? seconds)
        }
        .task(id: FrameRequest(path: videoPath, seconds: seconds, isShown: isManual)) {
            guard isManual else {
                return
            }
            // Coalesces a fast drag into the frames it settles on.
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else {
                return
            }
            if let image = await Self.frame(of: videoPath, at: seconds), !Task.isCancelled {
                frame = image
            }
        }
    }

    private var manualBinding: Binding<Bool> {
        Binding(
            get: { isManual },
            set: { manual in
                isManual = manual
                // Choosing "specify" waits for a frame to be picked; until then the
                // video keeps its automatic start.
                if !manual {
                    model.setLockScreenStartSeconds(nil)
                }
            }
        )
    }

    private var framePreview: some View {
        ZStack {
            Color.black
            if let frame {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: 128, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private struct FrameRequest: Equatable {
        let path: String
        let seconds: Double
        let isShown: Bool
    }

    private static func frame(of path: String, at seconds: Double) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 256, height: 144)
        let tolerance = CMTime(value: 1, timescale: 20)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        do {
            return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        } catch {
            // A drag moving on cancels the request; only a real failure is worth a log.
            guard !Task.isCancelled else {
                return nil
            }
            AppLog.lockScreenSync.error(
                "lock screen start picker: frame unreadable at \(seconds, privacy: .public)s: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    static func timeText(_ seconds: Double) -> String {
        let tenths = Int((seconds * 10).rounded(.down))
        return String(format: "%d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
    }
}

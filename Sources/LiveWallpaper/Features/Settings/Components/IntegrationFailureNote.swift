import AppKit
import SwiftUI

/// Why a system integration (sound, media) is not working, with the way to fix it.
struct IntegrationFailureNote: View {
    @ObservedObject var model: WallpaperModel
    let message: String
    /// The Privacy & Security pane anchor, e.g. "Privacy_ScreenCapture".
    let privacy: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.localizedString("連携を利用できません") + ": " + message).font(.caption).foregroundColor(.red)
            HStack {
                Button(model.localizedString("システム設定を開く")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(privacy)")!)
                }
                Button(model.localizedString("再試行")) { LocalWebIntegration.shared.retry() }
            }
        }
    }
}

/// Lets a scene whose effects react to sound listen to the system audio.
struct SceneSoundReactionToggle: View {
    @ObservedObject var model: WallpaperModel
    let path: String
    @ObservedObject private var integration = LocalWebIntegration.shared
    @State private var isEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(model.localizedString("システム音に反応"), isOn: $isEnabled)
            Text(model.localizedString("システム音の取得には、画面収録の許可が必要です。音声は保存しません。"))
                .font(.caption).foregroundColor(.secondary)
            if isEnabled, let error = integration.audioError {
                IntegrationFailureNote(model: model, message: error, privacy: "Privacy_ScreenCapture")
            }
        }
        .onAppear { isEnabled = SceneSoundReaction.isEnabled(videoPath: path) }
        .onChange(of: path) { path in isEnabled = SceneSoundReaction.isEnabled(videoPath: path) }
        .onChange(of: isEnabled) { enabled in
            guard enabled != SceneSoundReaction.isEnabled(videoPath: path) else { return }
            SceneSoundReaction.setEnabled(enabled, videoPath: path)
        }
    }
}

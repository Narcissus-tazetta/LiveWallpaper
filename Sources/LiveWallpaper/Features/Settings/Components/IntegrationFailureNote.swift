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
            // The Automation pane has no "−" to remove an entry, so the steps only fit the others.
            if privacy != "Privacy_Automation" {
                PermissionRepairHelp(model: model)
            }
        }
    }
}

/// How to recreate a privacy entry that is switched on but refused.
///
/// An update that changes the app's code signature leaves the old entry in System Settings
/// still on, while macOS treats the new build as a different app.
struct PermissionRepairHelp: View {
    @ObservedObject var model: WallpaperModel
    @State private var isExpanded = false

    private static let steps = [
        "システム設定の「プライバシーとセキュリティ」で、この項目を開く",
        "一覧の LiveWallpaper のスイッチをオフにする",
        "LiveWallpaper を選び、一覧の下の「−」を押して削除する(パスワードか Touch ID が必要)",
        "「+」を押し、アプリケーションから LiveWallpaper を選んで追加し、スイッチをオンにする",
        "LiveWallpaper を再起動する",
    ]

    var body: some View {
        DisclosureGroup(model.localizedString("許可しても動かない場合"), isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.localizedString("更新のあとなどに、許可がオンのままでも効かなくなることがあります。次の手順で許可を作り直してください。"))
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). " + model.localizedString(step))
                }
                Button(model.localizedString("アプリを再起動")) { AppRelaunch.perform() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
        .font(.caption)
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

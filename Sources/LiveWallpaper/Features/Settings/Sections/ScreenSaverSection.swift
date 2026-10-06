import AppKit
import SwiftUI

extension SettingsView {
    static let screenSaverSearchKeywords: [String] = [
        "スクリーンセーバー",
        "スクリーンセーバーとして使う",
        "インストール",
        "アンインストール",
    ]

    @ViewBuilder
    var screenSaverSettingsSection: some View {
        Section(
            header: Label(model.localizedString("スクリーンセーバー"), systemImage: "moon.zzz")
        ) {
            settingsFootnote(
                model.localizedString(
                    "今デスクトップに表示している動画の壁紙を、macOS のスクリーンセーバーとして再生します。画面ごとの壁紙・トリム・配置もそのまま反映されます。"
                )
            )

            switch model.screenSaverInstallState {
            case .unavailable:
                settingsFootnote(
                    model.localizedString("このビルドにはスクリーンセーバーが含まれていません。"),
                    color: .orange
                )
            case .notInstalled:
                Button(model.localizedString("スクリーンセーバーとして使う")) {
                    model.installScreenSaver()
                }
            case .installed, .updateAvailable:
                HStack(spacing: 8) {
                    Label(model.localizedString("インストール済み"), systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Spacer(minLength: 12)
                    if model.screenSaverInstallState == .updateAvailable {
                        Button(model.localizedString("更新")) {
                            model.installScreenSaver()
                        }
                    }
                    Button(model.localizedString("システム設定で選ぶ")) {
                        openScreenSaverSettings()
                    }
                    Button(model.localizedString("アンインストール")) {
                        model.uninstallScreenSaver()
                    }
                }
                settingsFootnote(
                    model.localizedString(
                        "システム設定のスクリーンセーバーの一覧で、一番下の「その他」にある「LiveWallpaper」を選ぶと使えます。新しい macOS では「壁紙」設定の「スクリーンセーバー…」ボタンから一覧を開けます。"
                    )
                )
                if model.isWebWallpaperActive {
                    settingsFootnote(
                        model.localizedString(
                            "Web壁紙はスクリーンセーバーでは再生できません。動画の壁紙を選ぶと反映されます。"
                        ),
                        color: .orange
                    )
                }
            }

            if let message = model.screenSaverErrorMessage {
                settingsFootnote(message, color: .red)
            }
        }
        .onAppear {
            model.refreshScreenSaverInstallState()
        }
    }

    /// Recent macOS (27 confirmed) has no Screen Saver settings pane; .saver bundles
    /// are listed under Wallpaper there. Open whichever pane this system has.
    private func openScreenSaverSettings() {
        let paneID = Self.systemHasSettingsPane("com.apple.ScreenSaver-Settings.extension")
            ? "com.apple.ScreenSaver-Settings.extension"
            : "com.apple.Wallpaper-Settings.extension"
        if let url = URL(string: "x-apple.systempreferences:\(paneID)") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func systemHasSettingsPane(_ bundleID: String) -> Bool {
        let directory = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions", isDirectory: true)
        let extensions = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return extensions.contains { url in
            let plist = url.appendingPathComponent("Contents/Info.plist")
            return (NSDictionary(contentsOf: plist)?["CFBundleIdentifier"] as? String) == bundleID
        }
    }
}

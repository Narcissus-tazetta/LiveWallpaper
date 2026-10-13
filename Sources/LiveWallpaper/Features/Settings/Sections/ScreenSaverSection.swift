import AppKit
import SwiftUI

extension SettingsView {
    static let screenSaverSearchKeywords: [String] = [
        "スクリーンセーバー",
        "スクリーンセーバーとして使う",
        "インストール",
        "アンインストール",
        "アプリを終了してもロック画面とスクリーンセーバーを残す",
    ]

    /// Shared by the screen saver section and the lock screen controls: one setting
    /// covers both.
    @ViewBuilder
    var keepAfterQuitControls: some View {
        Toggle(
            model.localizedString("アプリを終了してもロック画面とスクリーンセーバーを残す"),
            isOn: Binding(
                get: { model.keepLockScreenAndScreenSaverAfterQuit },
                set: { model.setKeepLockScreenAndScreenSaverAfterQuit($0) }
            )
        )
        settingsFootnote(
            model.localizedString(
                "オンにすると、壁紙がシステムに登録されたまま残り、アプリを終了しても再起動しても、アプリより先に表示されます。ロック画面とスクリーンセーバーは動きますが、デスクトップは macOS が動かさないため、アプリが起動するまでは止まった 1 コマになります。終了している間はスケジュールや自動切り替えも動きません。オンのままアプリを削除すると差し替えが残るため、削除する前にオフにしてからアプリを終了してください。"
            )
        )
        if model.keepLockScreenAndScreenSaverAfterQuit, !model.launchAtLoginEnabled {
            HStack(spacing: 8) {
                Text(model.localizedString("デスクトップもすぐに動かすには、ログイン時に自動起動もオンにしてください。"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(model.localizedString("ログイン時に自動起動をオンにする")) {
                    NotificationCenter.default.post(name: .toggleLaunchAtLogin, object: true)
                }
            }
        }
    }

    @ViewBuilder
    var screenSaverSettingsSection: some View {
        Section(
            header: SettingsSectionHeader(title: model.localizedString("スクリーンセーバー"))
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
                        model.keepLockScreenAndScreenSaverAfterQuit
                            ? "LiveWallpaper の起動中は、スクリーンセーバーに LiveWallpaper が自動で選ばれます。アンインストールすると、元のスクリーンセーバーに戻ります。"
                            : "LiveWallpaper の起動中は、スクリーンセーバーに LiveWallpaper が自動で選ばれます。アプリを終了するかアンインストールすると、元のスクリーンセーバーに戻ります。"
                    )
                )
                keepAfterQuitControls
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

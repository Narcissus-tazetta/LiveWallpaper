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

    /// One setting covers the lock screen and the screen saver, so both of their panels
    /// show it; each says whether the other one will stay too.
    @ViewBuilder
    func keepAfterQuitControls(in target: WallpaperAssignmentTarget) -> some View {
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
        if model.keepLockScreenAndScreenSaverAfterQuit {
            if target != .lockScreen {
                lockScreenKeptAfterQuitStatus
            }
            if target != .screenSaver {
                screenSaverKeptAfterQuitStatus
            }
            if !model.launchAtLoginEnabled {
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
    }

    /// The lock screen and the desktop stay only through the lock screen setting: says
    /// whether they will, and why not.
    @ViewBuilder
    private var lockScreenKeptAfterQuitStatus: some View {
        if model.lockScreenSyncEnabled {
            Label(lockScreenSyncStatusText(), systemImage: lockScreenSyncStatusIconName())
                .font(.caption)
                .foregroundColor(lockScreenSyncStatusColor())
                .lineLimit(2)
        } else {
            HStack(spacing: 8) {
                Text(model.localizedString("ロック画面とデスクトップは、システム壁紙に設定していないため残りません。"))
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(model.localizedString("システム壁紙に設定する")) {
                    model.setLockScreenSyncEnabled(true)
                }
            }
        }
    }

    @ViewBuilder
    private var screenSaverKeptAfterQuitStatus: some View {
        if model.screenSaverInstallState == .notInstalled {
            HStack(spacing: 8) {
                Text(model.localizedString("スクリーンセーバーは、インストールしていないため残りません。"))
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(model.localizedString("スクリーンセーバーとして使う")) {
                    model.installScreenSaver()
                }
            }
        }
    }

    /// The wallpaper tab's panel for the screen saver: installing it and what it plays.
    var screenSaverControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsFootnote(
                model.localizedString(
                    "下の一覧で選んだ動画を、macOS のスクリーンセーバーとして再生します。選んでいないときは、デスクトップと同じ動画を、画面ごとの壁紙・トリム・配置も含めて再生します。"
                )
            )
            if let path = model.screenSaverVideoPath {
                HStack(spacing: 8) {
                    Text(model.registeredVideoDisplayName(for: path))
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button {
                        model.useDesktopVideoForScreenSaver()
                    } label: {
                        Label(model.localizedString("デスクトップと同じにする"), systemImage: "display")
                    }
                }
            }

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
                if model.isWebWallpaperActive, model.screenSaverVideoPath == nil {
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

            if model.screenSaverInstallState != .unavailable {
                Divider()
                keepAfterQuitControls(in: .screenSaver)
            }
        }
        .onAppear {
            model.refreshScreenSaverInstallState()
        }
    }

    /// Search finds the screen saver here, but it lives on the wallpaper tab now.
    var screenSaverSearchRedirectSection: some View {
        Section {
            Button {
                selectedAssignmentTarget = .screenSaver
                selectedTab = .wallpaper
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "moon.stars")
                        .foregroundColor(.secondary)
                    Text(model.localizedString("スクリーンセーバーは「壁紙」タブに移動しました"))
                        .font(.caption)
                    Spacer()
                    Text(model.localizedString("開く"))
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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

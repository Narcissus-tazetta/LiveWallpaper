import SwiftUI

extension SettingsView {
  var lockScreenSyncControls: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Kept after quitting, the setting is no longer temporary, and the desktop
      // shows the same system wallpaper while the app is not running.
      Toggle(
        model.localizedString(
          model.keepLockScreenAndScreenSaverAfterQuit
            ? "ロック画面とデスクトップにシステム壁紙として設定" : "ロック画面用にシステム壁紙を一時設定"
        ),
        isOn: lockScreenSyncBinding
      )
        .disabled(lockScreenSyncActionInProgress)

      Label(lockScreenSyncStatusText(), systemImage: lockScreenSyncStatusIconName())
        .font(.caption)
        .foregroundColor(lockScreenSyncStatusColor())
        .lineLimit(2)

      HStack(spacing: 8) {
        Button {
          model.applyLockScreenVideoSameAsDesktop()
        } label: {
          Label(model.localizedString("デスクトップと同じにする"), systemImage: "display")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(model.currentVideoPath == nil || lockScreenSyncActionInProgress)

        Button(model.localizedString("今すぐ設定")) {
          if model.lockScreenSyncEnabled {
            model.syncCurrentVideoToLockScreen()
          } else {
            model.setLockScreenSyncEnabled(true)
          }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .disabled(
          model.effectiveLockScreenVideoPath == nil
            || lockScreenSyncActionInProgress
            || model.lockScreenSyncStatus == .unsupported
        )

        if model.lockScreenSyncStatus == .noAerialDownloaded {
          Button(model.localizedString("System Settings を開く")) {
            model.openLockScreenWallpaperSettings()
          }
          .buttonStyle(.bordered)
          .controlSize(.regular)
        }

        Menu {
          Button(model.localizedString("System Settings を開く")) {
            model.openLockScreenWallpaperSettings()
          }
          Divider()
          Button(model.localizedString("元のAerialに戻す"), role: .destructive) {
            model.removeLockScreenSync()
          }
          Button(model.localizedString("壊れた設定を復元")) {
            model.restoreLockScreenWallpaperSettings()
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .controlSize(.regular)
        .menuStyle(.borderlessButton)
        .iconHelp(model.localizedString("その他の操作"))
        .disabled(lockScreenSyncActionInProgress)
      }

      Text(lockScreenSyncHelpText())
        .font(.caption)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)

      Divider()
      keepAfterQuitControls(in: .lockScreen)
    }
  }

  var lockScreenSyncActionInProgress: Bool {
    model.lockScreenSyncStatus == .syncing
      || model.lockScreenSyncStatus == .recovering
      || model.lockScreenSyncStatus == .removing
      || model.lockScreenSyncStatus == .restoring
  }

  func lockScreenSyncStatusText() -> String {
    switch model.lockScreenSyncStatus {
    case .disabled:
      return model.localizedString("ロック画面同期はオフです")
    case .unsupported:
      return model.localizedString("macOS 26 以降で利用できます")
    case .idle:
      return model.localizedString("同期待機中")
    case .syncing:
      guard let progress = model.lockScreenEncodeProgress else {
        return model.localizedString("同期中")
      }
      let percent = Int((progress.fraction * 100).rounded(.down))
      guard let remaining = progress.remainingSeconds.flatMap(lockScreenRemainingText) else {
        return String(format: model.localizedString("ロック画面用に変換中… %d%%"), locale: model.appLocale, percent)
      }
      return String(
        format: model.localizedString("ロック画面用に変換中… %d%%(あと %@)"), locale: model.appLocale, percent, remaining
      )
    case let .borrowed(name):
      return String(format: model.localizedString("%@: %@"), model.localizedString("借用中"), name)
    case .recovering:
      return model.localizedString("前回のロック画面設定を復元中")
    case .removing:
      return model.localizedString("元のAerialに戻しています")
    case .restoring:
      return model.localizedString("復元中")
    case .restored:
      return model.localizedString("復元済み")
    case .recovered:
      return model.localizedString("前回のロック画面設定を復元しました")
    case .noAerialDownloaded:
      return model.localizedString("Aerial動画が未ダウンロードです")
    case let .failed(message):
      return String(format: model.localizedString("%@: %@"), model.localizedString("同期に失敗しました"), message)
    }
  }

  /// e.g. "3分12秒" / "3m 12s" in the app's language.
  private func lockScreenRemainingText(_ seconds: Double) -> String? {
    let formatter = DateComponentsFormatter()
    var calendar = Calendar.current
    calendar.locale = model.appLocale
    formatter.calendar = calendar
    formatter.unitsStyle = .abbreviated
    formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
    return formatter.string(from: seconds.rounded(.up))
  }

  func lockScreenSyncStatusIconName() -> String {
    switch model.lockScreenSyncStatus {
    case .disabled, .idle:
      return "circle"
    case .unsupported, .failed, .noAerialDownloaded:
      return "exclamationmark.triangle"
    case .syncing, .recovering, .removing, .restoring:
      return "arrow.triangle.2.circlepath"
    case .borrowed, .restored, .recovered:
      return "checkmark.circle"
    }
  }

  func lockScreenSyncStatusColor() -> Color {
    switch model.lockScreenSyncStatus {
    case .failed, .unsupported, .noAerialDownloaded:
      return .orange
    case .borrowed, .restored, .recovered:
      return .green
    default:
      return .secondary
    }
  }

  func lockScreenSyncHelpText() -> String {
    switch model.lockScreenSyncStatus {
    case .noAerialDownloaded:
      return model.localizedString("System Settings でダイナミック壁紙を1つダウンロードしてから、もう一度設定してください。")
    case .failed:
      return model.localizedString("うまく反映されない時は、右のメニューから復元できます。System Settings は閉じてから実行してください。")
    case .recovered:
      return model.localizedString("前回終了時に残ったロック画面設定を自動で元に戻しました。")
    default:
      return model.keepLockScreenAndScreenSaverAfterQuit
        ? model.localizedString("オンにすると選択中のロック画面動画をシステムのAerial壁紙として設定します。アプリを終了しても、そのまま残ります。")
        : model.localizedString("オンにすると選択中のロック画面動画をシステムのAerial壁紙として一時設定します。アプリ終了時に元の壁紙へ戻ります。")
    }
  }
}

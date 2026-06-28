import SwiftUI

extension SettingsView {
  var videoSettingsSection: some View {
    Section(header: Label(model.localizedString("動画"), systemImage: "film")) {
      Toggle(model.localizedString("クリック貫通を有効にする"), isOn: clickThroughBinding)
      Toggle(model.localizedString("ログイン時に自動起動する"), isOn: launchAtLoginBinding)
      Toggle(model.localizedString("音声を再生する"), isOn: audioEnabledBinding)
      lockScreenSyncControls

      HStack(spacing: 10) {
        Text(model.localizedString("音量"))
          .frame(width: 150, alignment: .leading)

        Slider(value: audioVolumeBinding, in: 0...1)
          .disabled(!model.audioEnabled)
          .frame(minWidth: 180, maxWidth: .infinity)

        HStack(alignment: .firstTextBaseline, spacing: 6) {
          TextField("", text: $volumeInput)
            .frame(width: 48)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .multilineTextAlignment(.trailing)
            .disabled(!model.audioEnabled)
            .focused($isVolumeInputFocused)
            .onSubmit { commitVolumeInput() }
            .onChange(of: volumeInput) { newValue in
              let filtered = String(newValue.filter(\.isNumber).prefix(3))
              if filtered != newValue {
                volumeInput = filtered
              }
            }

          Text(model.localizedString("%"))
            .foregroundColor(.secondary)
            .font(.system(size: 13))
        }
      }
    }
  }

  var lockScreenSyncControls: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle(model.localizedString("ロック画面用にシステム壁紙を一時設定"), isOn: lockScreenSyncBinding)
        .disabled(lockScreenSyncActionInProgress)

      HStack(spacing: 10) {
        Label(lockScreenSyncStatusText(), systemImage: lockScreenSyncStatusIconName())
          .font(.caption)
          .foregroundColor(lockScreenSyncStatusColor())
          .lineLimit(1)

        Spacer(minLength: 0)

        if model.lockScreenSyncStatus == .noAerialDownloaded {
          Button(model.localizedString("System Settings を開く")) {
            model.openLockScreenWallpaperSettings()
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }

        Button(model.localizedString("今すぐ設定")) {
          if model.lockScreenSyncEnabled {
            model.syncCurrentVideoToLockScreen()
          } else {
            model.setLockScreenSyncEnabled(true)
          }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(
          model.currentVideoPath == nil
            || lockScreenSyncActionInProgress
            || model.lockScreenSyncStatus == .unsupported
        )

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
        .controlSize(.small)
        .menuStyle(.borderlessButton)
        .disabled(lockScreenSyncActionInProgress)
      }

      Text(lockScreenSyncHelpText())
        .font(.caption)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 4)
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
      return model.localizedString("同期中")
    case let .borrowed(name):
      return "\(model.localizedString("借用中")): \(name)"
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
      return "\(model.localizedString("同期に失敗しました")): \(message)"
    }
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
      return model.localizedString("オンにすると現在の動画をシステムのAerial壁紙として一時設定します。アプリ終了時に元の壁紙へ戻ります。")
    }
  }
}

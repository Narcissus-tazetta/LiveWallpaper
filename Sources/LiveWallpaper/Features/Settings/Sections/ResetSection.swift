import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
  var resetSettingsSection: some View {
    Section(
      header: Label(
        model.localizedString("設定の管理"),
        systemImage: "arrow.counterclockwise"
      )
    ) {
      HStack(spacing: 10) {
        Button(model.localizedString("再生をリフレッシュ")) {
          NotificationCenter.default.post(name: .refreshPlayback, object: nil)
        }
        .buttonStyle(.bordered)

        Button(model.localizedString("設定をリセット"), role: .destructive) {
          isResetSettingsDialogPresented = true
        }
        .buttonStyle(.bordered)
        Spacer()
      }

      Text(model.localizedString("再生表示が崩れたときはリフレッシュを使って再初期化できます。設定リセットは表示・再生設定を初期値に戻します"))
        .font(.caption)
        .foregroundColor(.secondary)

      HStack(spacing: 10) {
        Button(model.localizedString("設定を書き出す…")) {
          exportSettingsViaPanel()
        }
        .buttonStyle(.bordered)

        Button(model.localizedString("設定を読み込む…")) {
          importSettingsViaPanel()
        }
        .buttonStyle(.bordered)
        Spacer()
      }

      Text(model.localizedString("表示・再生などの設定をJSONファイルとして保存・復元できます。壁紙の動画ファイル自体は含まれません"))
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }

  func exportSettingsViaPanel() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "LiveWallpaper-Settings.json"
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }
    do {
      try SettingsTransfer.export(from: model, to: url)
    } catch {
      showSettingsTransferAlert(
        message: model.localizedString("設定の書き出しに失敗しました"),
        informative: error.localizedDescription
      )
    }
  }

  func importSettingsViaPanel() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }
    do {
      try SettingsTransfer.importSettings(from: url, into: model)
      syncVolumeInputWithModel()
      showSettingsTransferAlert(
        message: model.localizedString("設定を読み込みました"),
        informative: nil,
        style: .informational
      )
    } catch {
      showSettingsTransferAlert(
        message: model.localizedString("設定の読み込みに失敗しました"),
        informative: error.localizedDescription
      )
    }
  }

  private func showSettingsTransferAlert(
    message: String,
    informative: String?,
    style: NSAlert.Style = .warning
  ) {
    let alert = NSAlert()
    alert.messageText = message
    if let informative {
      alert.informativeText = informative
    }
    alert.alertStyle = style
    alert.runModal()
  }
}

import AppKit
import SwiftUI

extension SettingsView {
  static let supportSearchKeywords: [String] = [
    "サポート",
    "診断情報を書き出す…",
    "不具合を報告…",
    "ログ",
  ]

  static let issueReportURL = URL(
    string: "https://github.com/Narcissus-tazetta/LiveWallpaper/issues/new/choose"
  )!

  var supportSettingsSection: some View {
    Section(
      header: SettingsSectionHeader(title: model.localizedString("サポート"))
    ) {
      HStack(spacing: 10) {
        Button(model.localizedString("診断情報を書き出す…")) {
          exportDiagnosticsViaPanel()
        }
        .buttonStyle(.bordered)

        Button(model.localizedString("不具合を報告…")) {
          NSWorkspace.shared.open(Self.issueReportURL)
        }
        .buttonStyle(.bordered)
        Spacer()
      }

      Text(model.localizedString("アプリ・macOS・ディスプレイの情報、設定、直近のログを1つのzipにまとめます。不具合を報告するときに添付してください。動画ファイルや Web 壁紙の URL は含まれません"))
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }

  func exportDiagnosticsViaPanel() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.zip]
    panel.nameFieldStringValue = DiagnosticsExporter.defaultFileName()
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }
    Task { @MainActor in
      do {
        try await DiagnosticsExporter.export(from: model, to: url)
        NSWorkspace.shared.activateFileViewerSelecting([url])
      } catch {
        let alert = NSAlert()
        alert.messageText = model.localizedString("診断情報の書き出しに失敗しました")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
      }
    }
  }
}

import SwiftUI

extension SettingsView {
    static let reconversionSearchKeywords = ["壁紙の再変換", "壁紙をすべて再変換", "外部アプリ"]

    var reconversionSettingsSection: some View {
        Section(header: SettingsSectionHeader(title: model.localizedString("壁紙の再変換"))) {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.localizedString("外部アプリから取り込んだ壁紙をすべて更新します。編集した内容は元作品の内容に置き換わり、更新前のデータはバックアップに保存されます。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(model.localizedString("壁紙をすべて再変換")) {
                    // Deleting a wallpaper removes its file but leaves the import record behind, so the
                    // record alone does not mean there is a file to replace.
                    reconversionController.start(itemIDs: model.importedExternalWallpaperPaths.compactMap { id, path in
                        id.hasPrefix("we-import.json/") && FileManager.default.fileExists(atPath: path)
                            ? String(id.dropFirst("we-import.json/".count)) : nil
                    }) { status in
                        await model.refreshReconvertedWallpapers(itemIDs: status.updatedIDs, backupPath: status.backupPath)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(reconversionController.isRunning)
                if reconversionController.isRunning {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(model.localizedString("再変換中…"))
                    }
                }
                if let status = reconversionController.status {
                    Text(String(format: model.localizedString("%d / %d 件"), locale: model.appLocale, status.completed, status.total))
                    if !status.currentTitle.isEmpty { Text(status.currentTitle).font(.caption) }
                    if status.isFinished, !reconversionController.isRunning {
                        Text(String(format: model.localizedString("%d 件を再変換しました"), locale: model.appLocale, status.updatedIDs.count - reconversionController.copyFailures.count))
                        if !status.updatedIDs.isEmpty {
                            Button(model.localizedString("バックアップを開く")) {
                                NSWorkspace.shared.open(URL(fileURLWithPath: status.backupPath))
                            }
                        }
                    }
                    let failures = status.failures + reconversionController.copyFailures
                    if !failures.isEmpty {
                        DisclosureGroup(model.localizedString("更新できなかった壁紙")) {
                            ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                                Text(failure.replacingOccurrences(of: "we-import", with: model.localizedString("取り込み元アプリ")))
                                    .font(.caption).textSelection(.enabled)
                            }
                        }
                        .foregroundStyle(.red)
                    }
                }
                if let key = reconversionController.errorKey {
                    Text(model.localizedString(key)).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

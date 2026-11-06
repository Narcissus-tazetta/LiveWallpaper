import AppKit
import SwiftUI

/// Shared by the menu command, window drops, Finder "open" events and Store downloads so
/// every entry point shows the same duplicate prompt.
@MainActor
enum PackageImportFlow {
    static let fileExtension = "lwpkg"

    enum Outcome: Equatable {
        case imported
        case cancelled
        case failed(String)
    }

    static func isPackage(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == fileExtension
    }

    /// Imports one at a time: each import may stop on a modal alert, and two alerts
    /// racing for the same window would hide the earlier result.
    static func run(urls: [URL], model: WallpaperModel) {
        Task { @MainActor in
            for url in urls {
                switch await importPackage(at: url, model: model, confirmsContents: true) {
                case .imported:
                    showAlert(
                        model: model,
                        title: "インポート完了",
                        message: model.localizedString("パッケージが正常にインポートされました。"),
                        style: .informational
                    )
                case .cancelled:
                    break
                case let .failed(message):
                    showAlert(
                        model: model,
                        title: "インポートに失敗",
                        message: message,
                        style: .critical
                    )
                }
            }
        }
    }

    /// - Parameter confirmsContents: shows what the package holds and waits for the user
    ///   to accept. Store downloads skip it: the user saw the entry before choosing it.
    static func importPackage(
        at url: URL,
        model: WallpaperModel,
        importer: PackageImporter = PackageImporter(),
        confirmsContents: Bool
    ) async -> Outcome {
        if confirmsContents {
            do {
                let preview = try await importer.preview(of: url)
                guard confirmImport(preview, model: model) else { return .cancelled }
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        var resolution = PackageImporter.DuplicateResolution.abort
        while true {
            do {
                try await importer.importPackage(
                    from: url,
                    into: model,
                    duplicateResolution: resolution
                )
                return .imported
            } catch let PackageImporter.ImportError.duplicateVideo(name) {
                guard resolution == .abort, confirmReplace(name: name, model: model) else {
                    return .cancelled
                }
                resolution = .replace
            } catch {
                AppLog.persistence.error(
                    "package import failed: \(error.localizedDescription, privacy: .public)"
                )
                return .failed(error.localizedDescription)
            }
        }
    }

    private static func confirmImport(_ preview: PackageImporter.Preview, model: WallpaperModel)
        -> Bool
    {
        let alert = NSAlert()
        alert.messageText = String(
            format: model.localizedString("「%@」を追加しますか？"),
            preview.manifest.manifest.name
        )
        alert.informativeText = model.localizedString("内容を確認してから追加してください。")
        let summary = PackagePreviewSummary(preview: preview, model: model)
        let hosting = NSHostingView(rootView: summary)
        hosting.frame.size = hosting.fittingSize
        alert.accessoryView = hosting
        alert.addButton(withTitle: model.localizedString("追加"))
        alert.addButton(withTitle: model.localizedString("キャンセル"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func confirmReplace(name: String, model: WallpaperModel) -> Bool {
        let alert = NSAlert()
        alert.messageText = model.localizedString("重複するビデオが見つかりました")
        alert.informativeText = String(
            format: model.localizedString("%@ は既に存在します。置き換えますか？"),
            name
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: model.localizedString("中止"))
        alert.addButton(withTitle: model.localizedString("置き換える"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    private static func showAlert(
        model: WallpaperModel,
        title: String,
        message: String,
        style: NSAlert.Style
    ) {
        let alert = NSAlert()
        alert.messageText = model.localizedString(title)
        alert.informativeText = message
        alert.alertStyle = style
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// Label/value rows rather than sentences, so counts need no plural forms per language.
struct PackagePreviewSummary: View {
    let preview: PackageImporter.Preview
    let model: WallpaperModel

    private var manifest: PackageManifest {
        preview.manifest
    }

    private var rows: [(String, String)] {
        var rows: [(String, String)] = []
        let author = manifest.manifest.author.trimmingCharacters(in: .whitespaces)
        if !author.isEmpty {
            rows.append((model.localizedString("作者"), author))
        }
        let counts: [(String, Int)] = [
            ("動画", manifest.videos.count),
            ("Web壁紙", manifest.webWallpapers?.count ?? 0),
            ("シーンのプリセット", manifest.scenePresets?.count ?? 0),
            ("プレイリスト", manifest.playlists.count)
        ]
        for (key, count) in counts where count > 0 {
            rows.append((model.localizedString(key), "\(count)"))
        }
        rows.append((
            model.localizedString("サイズ"),
            ByteCountFormatter.string(fromByteCount: preview.packageBytes, countStyle: .file)
        ))
        if let license = manifest.manifest.license?.trimmingCharacters(in: .whitespaces),
           !license.isEmpty
        {
            rows.append((model.localizedString("ライセンス"), license))
        }
        return rows
    }

    private var hasScripts: Bool {
        manifest.videos.contains { $0.scriptScene != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let thumbnail = preview.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 256, maxHeight: 144)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(rows, id: \.0) { label, value in
                    GridRow {
                        Text(label).foregroundColor(.secondary)
                        Text(value).textSelection(.enabled)
                    }
                }
            }
            .font(.callout)
            if hasScripts {
                Label(
                    model.localizedString("スクリプト付きのシーンが含まれます。スクリプトは許可するまで動きません。"),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 280, alignment: .leading)
    }
}

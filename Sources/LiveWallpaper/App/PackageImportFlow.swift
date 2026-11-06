import AppKit

/// Shared by the menu command, window drops and Finder "open" events so every entry point
/// shows the same duplicate prompt and result alerts.
@MainActor
enum PackageImportFlow {
    static let fileExtension = "lwpkg"

    static func isPackage(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == fileExtension
    }

    /// Imports one at a time: each import may stop on a modal alert, and two alerts
    /// racing for the same window would hide the earlier result.
    static func run(urls: [URL], model: WallpaperModel) {
        Task { @MainActor in
            for url in urls {
                await importPackage(at: url, model: model)
            }
        }
    }

    private static func importPackage(at url: URL, model: WallpaperModel) async {
        let importer = PackageImporter()
        var resolution = PackageImporter.DuplicateResolution.abort
        while true {
            do {
                try await importer.importPackage(
                    from: url,
                    into: model,
                    duplicateResolution: resolution
                )
                showAlert(
                    model: model,
                    title: "インポート完了",
                    message: model.localizedString("パッケージが正常にインポートされました。"),
                    style: .informational
                )
                return
            } catch let PackageImporter.ImportError.duplicateVideo(name) {
                guard resolution == .abort, confirmReplace(name: name, model: model) else {
                    return
                }
                resolution = .replace
            } catch {
                showAlert(
                    model: model,
                    title: "インポートに失敗",
                    message: error.localizedDescription,
                    style: .critical
                )
                return
            }
        }
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

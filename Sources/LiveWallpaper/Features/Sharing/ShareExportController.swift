import AppKit
import SwiftUI

/// Runs a share or export in the background and shows a small panel with its progress and
/// a Cancel button while it runs. One at a time: a second request while one runs is refused
/// with a beep, since both would race for the share sheet.
@MainActor
final class ShareExportController: ObservableObject {
    static let shared = ShareExportController()

    @Published private(set) var title = ""
    @Published private(set) var progress = 0.0

    private var task: Task<Void, Never>?
    private var panel: NSPanel?

    var isRunning: Bool {
        task != nil
    }

    /// Writes into a fresh folder of its own, then opens the macOS share sheet on the files
    /// `work` returns.
    func share(
        title: String,
        model: WallpaperModel,
        work: @escaping @MainActor (URL, @escaping PackageExporter.Progress) async throws -> [URL]
    ) {
        let anchorWindow = NSApp.keyWindow ?? NSApp.mainWindow
        start(title: title, model: model) { progress in
            let folder = try Self.makeShareFolder()
            do {
                let urls = try await work(folder, progress)
                try Task.checkCancellation()
                Self.presentSharePicker(for: urls, in: anchorWindow, model: model)
            } catch {
                BlockingWork.removeInBackground(folder)
                throw error
            }
        }
    }

    func sharePackage(_ selection: PackageSelection, model: WallpaperModel) {
        share(title: selection.name, model: model) { folder, progress in
            let url = folder.appendingPathComponent(
                ExportFileNameSanitizer.sanitizedExportFileName(selection.name) + "."
                    + PackageImportFlow.fileExtension
            )
            try await PackageExporter().exportPackage(
                model: model,
                selection: selection,
                outputURL: url,
                progress: progress
            )
            return [url]
        }
    }

    /// Asks where to save the package, then writes it there and shows it in Finder.
    func savePackage(selection: PackageSelection, model: WallpaperModel) {
        guard !isRunning else {
            NSSound.beep()
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: PackageImportFlow.fileExtension)]
            .compactMap { $0 }
        panel.nameFieldStringValue = ExportFileNameSanitizer
            .sanitizedExportFileName(selection.name) + "." + PackageImportFlow.fileExtension
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        start(title: selection.name, model: model) { progress in
            // Written beside the destination first, so a cancelled or failed export never
            // leaves a broken package under the name the user chose.
            let partial = url.deletingLastPathComponent()
                .appendingPathComponent(".\(UUID().uuidString).lwpkg")
            do {
                try await PackageExporter().exportPackage(
                    model: model,
                    selection: selection,
                    outputURL: partial,
                    progress: progress
                )
                try Task.checkCancellation()
                if FileManager.default.fileExists(atPath: url.path) {
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: partial)
                } else {
                    try FileManager.default.moveItem(at: partial, to: url)
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                if FileManager.default.fileExists(atPath: partial.path) {
                    BlockingWork.removeInBackground(partial)
                }
                throw error
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func start(
        title: String,
        model: WallpaperModel,
        work: @escaping @MainActor (@escaping PackageExporter.Progress) async throws -> Void
    ) {
        guard !isRunning else {
            NSSound.beep()
            return
        }
        self.title = title
        progress = 0
        let report: PackageExporter.Progress = { [weak self] value in
            Task { @MainActor in self?.progress = value }
        }
        task = Task { @MainActor [weak self] in
            // Most shares of a plain video finish at once; the panel would only flash.
            let showPanel = Task { @MainActor [weak self] in
                try await Task.sleep(nanoseconds: 400_000_000)
                self?.showPanel(model: model)
            }
            defer {
                showPanel.cancel()
                self?.closePanel()
                self?.task = nil
            }
            do {
                try await work(report)
            } catch {
                // Cancelling surfaces as whatever the interrupted step throws (a writer
                // error from a bake, not only CancellationError).
                guard !Task.isCancelled else {
                    AppLog.events.notice("share export cancelled")
                    return
                }
                AppLog.events.error(
                    "share export failed: \(error.localizedDescription, privacy: .public)"
                )
                Self.showFailure(error.localizedDescription, model: model)
            }
        }
    }

    // MARK: - Panel

    private func showPanel(model: WallpaperModel) {
        guard isRunning, panel == nil else { return }
        let hosting = NSHostingView(rootView: ShareExportProgressView(
            controller: self,
            model: model
        ))
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = model.localizedString("書き出し中…")
        panel.contentView = hosting
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.center()
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func closePanel() {
        panel?.close()
        panel = nil
    }

    // MARK: - Share folder

    private static var shareRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveWallpaperShares", isDirectory: true)
    }

    /// A share service may still be reading the files (an AirDrop in flight, a mail being
    /// written), so only folders older than this are removed.
    private static let shareFolderLifetime: TimeInterval = 60 * 60

    private static func makeShareFolder() throws -> URL {
        try FileManager.default.createDirectory(at: shareRoot, withIntermediateDirectories: true)
        removeExpiredShareFolders()
        let folder = shareRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Also run at launch: shared files can be gigabytes, and without it they stayed in
    /// the temporary folder until the next share.
    static func removeExpiredShareFolders() {
        let folders: [URL]
        do {
            folders = try FileManager.default.contentsOfDirectory(
                at: shareRoot,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch CocoaError.fileReadNoSuchFile {
            return
        } catch {
            AppLog.events.error(
                "share folders unreadable: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        let expiration = Date().addingTimeInterval(-shareFolderLifetime)
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?
                .creationDate ?? .distantPast
            if created < expiration {
                BlockingWork.removeInBackground(folder)
            }
        }
    }

    // MARK: - Share sheet

    private static func presentSharePicker(
        for urls: [URL],
        in window: NSWindow?,
        model: WallpaperModel
    ) {
        guard let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow,
              let view = window.contentView
        else {
            showFailure(model.localizedString("共有シートを開けませんでした"), model: model)
            return
        }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let viewPoint = view.convert(windowPoint, from: nil)
        let anchor = view.bounds.contains(viewPoint)
            ? viewPoint
            : NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        NSSharingServicePicker(items: urls).show(
            relativeTo: NSRect(origin: anchor, size: NSSize(width: 1, height: 1)),
            of: view,
            preferredEdge: .maxY
        )
    }

    private static func showFailure(_ message: String, model: WallpaperModel) {
        let alert = NSAlert()
        alert.messageText = model.localizedString("共有に失敗しました")
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

struct ShareExportProgressView: View {
    @ObservedObject var controller: ShareExportController
    let model: WallpaperModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(controller.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            ProgressView(value: controller.progress)
            Text(model.localizedString("シーンは最新の編集を反映した動画を作るため、時間がかかることがあります。"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(model.localizedString("キャンセル")) {
                    controller.cancel()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

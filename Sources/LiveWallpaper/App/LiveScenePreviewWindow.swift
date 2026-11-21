import AppKit
import SwiftUI

@MainActor
final class LiveScenePreviewWindow: NSWindowController, NSWindowDelegate {
    private final class PreviewWindow: NSWindow {
        override var canBecomeKey: Bool {
            true
        }

        override var canBecomeMain: Bool {
            true
        }
    }

    private struct Content: View {
        let document: SceneDocument
        let path: String
        let closeTitle: String
        let menuBarInset: CGFloat
        let close: () -> Void
        @StateObject private var controller = ScenePreviewController()
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            ZStack(alignment: .topLeading) {
                Color.black
                ScenePreviewView(
                    document: document, videoPath: path, controller: controller,
                    fixedTime: reduceMotion ? 0 : nil
                )
                .aspectRatio(document.aspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Button(closeTitle, action: close)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderedProminent)
                    .padding(20)
                    .padding(.top, menuBarInset)
            }
        }
    }

    private var onClose: (() -> Void)?
    private var keyMonitor: Any?
    private var lockObserver: NSObjectProtocol?
    private var sessionObserver: NSObjectProtocol?

    init(
        document: SceneDocument, path: String, screen: NSScreen, title: String, closeTitle: String,
        onClose: @escaping () -> Void
    ) {
        let window = PreviewWindow(
            contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        super.init(window: window)
        self.onClose = onClose
        window.delegate = self
        window.title = title
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.fullScreenAuxiliary, .transient]
        let hosting = NSHostingController(rootView: Content(
            document: document, path: path, closeTitle: closeTitle,
            menuBarInset: max(
                screen.safeAreaInsets.top,
                screen.frame.maxY - screen.visibleFrame.maxY
            ),
            close: { [weak self] in self?.close() }
        ))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setFrame(screen.frame, display: false)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, event.keyCode == 53 else { return event }
            close()
            return nil
        }
        lockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.close() } }
        sessionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.close() } }
    }

    required init?(coder _: NSCoder) {
        nil
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let lockObserver {
            DistributedNotificationCenter.default().removeObserver(lockObserver)
            self.lockObserver = nil
        }
        if let sessionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sessionObserver)
            self.sessionObserver = nil
        }
        (notification.object as? NSWindow)?.contentViewController = nil
        let closed = onClose
        onClose = nil
        closed?()
    }
}

extension AppDelegate {
    func refreshLiveScenePreviewMenu() {
        let canOpen = !wallpaperModel.isWebWallpaperActive
            && wallpaperModel.currentVideoPath
            .map { wallpaperModel.sceneDocumentsByPath[$0] != nil } == true
        statusItem?.menu?.item(withTag: MenuTag.liveScenePreview)?
            .isEnabled = liveScenePreview != nil || canOpen
    }

    @objc func openLiveScenePreview() {
        if let liveScenePreview {
            liveScenePreview.close()
            return
        }
        guard !wallpaperModel.isWebWallpaperActive,
              let path = wallpaperModel.currentVideoPath,
              let document = wallpaperModel.sceneDocumentsByPath[path],
              let screen = NSScreen.main else { return }
        let window = LiveScenePreviewWindow(
            document: document, path: path, screen: screen,
            title: localized("シーンを全画面プレビュー"), closeTitle: localized("閉じる"),
            onClose: { [weak self] in
                self?.liveScenePreview = nil
                self?.refreshLiveScenePreviewMenu()
            }
        )
        liveScenePreview = window
        refreshLiveScenePreviewMenu()
        NSApp.activate(ignoringOtherApps: true)
        window.showWindow(nil)
        window.window?.makeKeyAndOrderFront(nil)
    }
}

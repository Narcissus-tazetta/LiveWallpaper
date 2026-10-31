import AppKit
import SwiftUI

extension AppDelegate {
    private static let sceneEditorFrameAutosaveName = "SceneEditorWindow"

    func setupSceneEditorWindow() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(showSceneEditorWindow), name: .openSceneEditor, object: nil
        )
    }

    @objc func showSceneEditorWindow() {
        let window = sceneEditorWindowController?.window ?? makeSceneEditorWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeSceneEditorWindow() -> NSWindow {
        let session = SceneEditorSession.shared
        let hosting = NSHostingController(rootView: SceneEditorRootView(
            model: wallpaperModel,
            session: session
        ))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask.insert(.resizable)
        if #available(macOS 14.0, *) {
            // The editor's `.toolbar` and `.navigationTitle` become the window's own.
            hosting.sceneBridgingOptions = .all
            window.toolbarStyle = .unified
        }
        window.minSize = NSSize(width: 1000, height: 640)
        window.setContentSize(NSSize(width: 1280, height: 800))
        if !window.setFrameUsingName(Self.sceneEditorFrameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.sceneEditorFrameAutosaveName)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Emptying the window lets the editor's onDisappear end tools and trials.
                SceneEditorSession.shared.close()
                self?.wallpaperModel.flushAllSceneSaves()
                self?.wallpaperModel.bakeAllScenesNowIfPending()
            }
        }
        // A bridged `.navigationTitle` does not reach a window made by AppKit; the subtitle does.
        session.$path
            .receive(on: DispatchQueue.main)
            .sink { [weak window, weak self] path in
                guard let window, let self, let path else {
                    return
                }
                window.title = wallpaperModel.registeredVideoDisplayName(for: path)
            }
            .store(in: &cancellables)
        sceneEditorWindowController = NSWindowController(window: window)
        return window
    }
}

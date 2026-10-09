import AppKit
import AVFoundation
import SwiftUI

/// Muted, looping, aspect-filled video for thumbnails (card hover, the current-wallpaper tab).
/// The layer has a clear background so whatever sits underneath (the still thumbnail) stays
/// visible until the first frame arrives.
struct LoopingVideoView: NSViewRepresentable {
    let path: String

    func makeNSView(context _: Context) -> LoopingVideoNSView {
        let view = LoopingVideoNSView()
        view.load(path: path)
        return view
    }

    func updateNSView(_ nsView: LoopingVideoNSView, context _: Context) {
        nsView.load(path: path)
    }

    static func dismantleNSView(_ nsView: LoopingVideoNSView, coordinator _: ()) {
        nsView.unload()
    }
}

final class LoopingVideoNSView: NSView {
    private let playerLayer = AVPlayerLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var loadedPath: String?
    private var occlusionObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func load(path: String) {
        guard loadedPath != path else {
            return
        }
        unload()
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.allowsExternalPlayback = false
        queue.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(
            player: queue,
            templateItem: AVPlayerItem(url: URL(fileURLWithPath: path))
        )
        player = queue
        loadedPath = path
        playerLayer.player = queue
        updatePlayback()
    }

    func unload() {
        player?.pause()
        player?.removeAllItems()
        playerLayer.player = nil
        looper = nil
        player = nil
        loadedPath = nil
    }

    // The settings window is hidden, not released, when closed, so SwiftUI keeps this view
    // alive. Follow the window's visibility or it would keep decoding in the background.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updatePlayback()
                }
            }
        }
        updatePlayback()
    }

    private func updatePlayback() {
        guard let player else {
            return
        }
        if let window, window.occlusionState.contains(.visible) {
            player.play()
        } else {
            player.pause()
        }
    }

    deinit {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
    }
}

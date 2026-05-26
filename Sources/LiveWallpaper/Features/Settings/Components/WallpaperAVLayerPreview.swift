import AppKit
import AVFoundation
import SwiftUI

struct WallpaperAVLayerPreview: NSViewRepresentable {
    let videoPath: String
    let fitMode: VideoFitMode
    let renderedSize: CGSize
    let translation: CGSize

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PreviewPlayerView {
        let view = PreviewPlayerView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.playerLayer.backgroundColor = NSColor.black.cgColor
        view.playerLayer.needsDisplayOnBoundsChange = true
        context.coordinator.attachPlayer(to: view.playerLayer, path: videoPath)
        context.coordinator.applyPresentation(fitMode: fitMode, on: view.playerLayer)
        view.updateContentLayout(renderedSize: renderedSize, translation: translation)
        return view
    }

    func updateNSView(_ nsView: PreviewPlayerView, context: Context) {
        context.coordinator.attachPlayer(to: nsView.playerLayer, path: videoPath)
        context.coordinator.applyPresentation(fitMode: fitMode, on: nsView.playerLayer)
        nsView.updateContentLayout(renderedSize: renderedSize, translation: translation)
    }

    static func dismantleNSView(_ nsView: PreviewPlayerView, coordinator: Coordinator) {
        nsView.playerLayer.player = nil
        coordinator.stop()
    }

    final class Coordinator {
        private var currentPath: String?
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?

        func attachPlayer(to layer: AVPlayerLayer, path: String) {
            if currentPath == path, let player {
                if layer.player !== player {
                    layer.player = player
                }
                return
            }

            stop()

            let url = URL(fileURLWithPath: path)
            let asset = AVURLAsset(url: url)
            let item = AVPlayerItem(asset: asset)
            let queue = AVQueuePlayer()
            queue.isMuted = true
            queue.volume = 0
            queue.allowsExternalPlayback = false
            queue.preventsDisplaySleepDuringVideoPlayback = false
            queue.automaticallyWaitsToMinimizeStalling = true
            queue.actionAtItemEnd = .none
            looper = AVPlayerLooper(player: queue, templateItem: item)
            queue.play()

            currentPath = path
            player = queue
            layer.player = queue
        }

        func applyPresentation(fitMode: VideoFitMode, on layer: AVPlayerLayer) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.videoGravity = fitMode == .fit ? .resizeAspect : .resizeAspectFill
            layer.setAffineTransform(.identity)
            CATransaction.commit()
        }

        func stop() {
            player?.pause()
            player?.removeAllItems()
            looper = nil
            player = nil
            currentPath = nil
        }
    }
}

final class PreviewPlayerView: NSView {
    let playerLayer: AVPlayerLayer = .init()
    private var renderedSize: CGSize = .zero
    private var translation: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    override func makeBackingLayer() -> CALayer {
        CALayer()
    }

    override func layout() {
        super.layout()
        layer?.frame = bounds
        let originX = (bounds.width - renderedSize.width) * 0.5 + translation.width
        let originY = (bounds.height - renderedSize.height) * 0.5 + translation.height
        playerLayer.frame = CGRect(origin: CGPoint(x: originX, y: originY), size: renderedSize)
    }

    override var isFlipped: Bool {
        true
    }

    func updateContentLayout(renderedSize: CGSize, translation: CGSize) {
        self.renderedSize = renderedSize
        self.translation = translation
        needsLayout = true
    }

    private func setupLayers() {
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.needsDisplayOnBoundsChange = true
        if playerLayer.superlayer == nil {
            layer?.addSublayer(playerLayer)
        }
    }
}

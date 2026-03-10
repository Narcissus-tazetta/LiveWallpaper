import AppKit
import AVFoundation

final class PlayerView: NSView {
    let playerLayer: AVPlayerLayer = .init()

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

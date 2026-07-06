import AppKit
import AVFoundation

final class PlayerView: NSView {
    let playerLayer: AVPlayerLayer = .init()

    private lazy var menuBarMaskView: NSVisualEffectView = {
        let view = NSVisualEffectView()
        view.material = .titlebar
        view.blendingMode = .withinWindow
        view.state = .active
        view.isHidden = true
        return view
    }()

    var menuBarMaskHeight: CGFloat = 0 {
        didSet {
            guard menuBarMaskHeight != oldValue else {
                return
            }
            menuBarMaskView.isHidden = menuBarMaskHeight <= 0
            layoutMenuBarMask()
        }
    }

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
        layoutMenuBarMask()
    }

    private func setupLayers() {
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        playerLayer.backgroundColor = NSColor.clear.cgColor
        playerLayer.needsDisplayOnBoundsChange = true
        if playerLayer.superlayer == nil {
            layer?.addSublayer(playerLayer)
        }
        addSubview(menuBarMaskView, positioned: .above, relativeTo: nil)
    }

    private func layoutMenuBarMask() {
        menuBarMaskView.frame = CGRect(
            x: 0,
            y: bounds.height - menuBarMaskHeight,
            width: bounds.width,
            height: menuBarMaskHeight
        )
    }
}

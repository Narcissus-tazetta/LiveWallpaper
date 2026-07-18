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

    private lazy var readabilityDimOverlayView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
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

    var readabilityDimOpacity: CGFloat = 0 {
        didSet {
            guard readabilityDimOpacity != oldValue else {
                return
            }
            readabilityDimOverlayView.alphaValue = readabilityDimOpacity
            readabilityDimOverlayView.isHidden = readabilityDimOpacity <= 0
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
        readabilityDimOverlayView.frame = bounds
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
        // 減光オーバーレイはメニューバーマスクより上に載せる。マスク
        // (NSVisualEffectView, .withinWindow)は下のコンテンツをサンプルするため、
        // マスクを上にすると減光済みの黒を拾ってメニューバー帯だけ色味が変わる。
        // 上下逆にして、壁紙全体に均一な減光がかかるようにする。
        addSubview(menuBarMaskView, positioned: .above, relativeTo: nil)
        addSubview(readabilityDimOverlayView, positioned: .above, relativeTo: nil)
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

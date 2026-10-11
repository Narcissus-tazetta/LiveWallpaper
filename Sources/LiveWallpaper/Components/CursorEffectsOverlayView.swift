import AppKit

/// Spotlight and cursor trail, drawn above the wallpaper and its dimming.
/// Coordinates are this view's own (origin bottom-left, same as the screen).
final class CursorEffectsOverlayView: NSView {
    private let spotlightLayer = CALayer()
    private let spotlightMask = CALayer()
    private var spotlightRadius: CGFloat?
    private var spotlightMaskSize: CGSize = .zero

    private let emitterLayer = CAEmitterLayer()
    private let emitterCell = CAEmitterCell()
    private var isEmitting = false
    private var trailConfiguration: (color: CursorTrailColor, customColor: NSColor, birthRate: Float)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func makeBackingLayer() -> CALayer {
        CALayer()
    }

    // Clicks belong to the desktop below.
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    private func setup() {
        wantsLayer = true
        spotlightLayer.backgroundColor = NSColor.black.cgColor
        spotlightLayer.mask = spotlightMask
        spotlightLayer.opacity = 0
        spotlightLayer.isHidden = true
        layer?.addSublayer(spotlightLayer)

        emitterCell.contents = Self.particleImage
        emitterCell.lifetime = 0.7
        emitterCell.lifetimeRange = 0.3
        emitterCell.velocity = 25
        emitterCell.velocityRange = 20
        emitterCell.emissionRange = .pi * 2
        emitterCell.scale = 0.55
        emitterCell.scaleRange = 0.2
        emitterCell.scaleSpeed = -0.4
        emitterCell.alphaSpeed = -1.4
        emitterLayer.emitterShape = .point
        emitterLayer.renderMode = .additive
        emitterLayer.emitterCells = [emitterCell]
        emitterLayer.birthRate = 0
        layer?.addSublayer(emitterLayer)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spotlightLayer.frame = bounds
        emitterLayer.frame = bounds
        CATransaction.commit()
        rebuildSpotlightMaskIfNeeded()
    }

    // MARK: - Spotlight

    /// nil radius turns the spotlight off; nil center hides it (cursor on another screen).
    func setSpotlight(radius: CGFloat?, opacity: CGFloat, center: CGPoint?) {
        if spotlightRadius != radius {
            spotlightRadius = radius
            spotlightMaskSize = .zero
            rebuildSpotlightMaskIfNeeded()
        }
        let visible = radius != nil && center != nil
        let targetOpacity = Float(visible ? opacity : 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let center {
            spotlightMask.position = center
        }
        if visible {
            spotlightLayer.isHidden = false
        }
        CATransaction.commit()
        guard spotlightLayer.opacity != targetOpacity else {
            return
        }
        // Fade in/out when the cursor enters or leaves this screen; following the
        // cursor itself is instant (actions disabled above).
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        spotlightLayer.opacity = targetOpacity
        CATransaction.commit()
    }

    /// The mask is twice the view in each direction, so moving it with the cursor
    /// always covers the whole screen; only its centre has the clear hole. Drawn at
    /// a quarter resolution since the edge is a soft gradient anyway.
    private func rebuildSpotlightMaskIfNeeded() {
        guard let radius = spotlightRadius, bounds.width > 0, bounds.height > 0 else {
            return
        }
        let size = CGSize(width: bounds.width * 2, height: bounds.height * 2)
        guard size != spotlightMaskSize else {
            return
        }
        spotlightMaskSize = size
        let scale: CGFloat = 4
        let width = Int(size.width / scale)
        let height = Int(size.height / scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            AppLog.windowRefresh.error("spotlight mask context unavailable width=\(width) height=\(height)")
            return
        }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor.black.cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!
        let center = CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.setBlendMode(.copy)
        context.drawRadialGradient(
            gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius / scale,
            options: []
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spotlightMask.contents = context.makeImage()
        spotlightMask.bounds = CGRect(origin: .zero, size: size)
        CATransaction.commit()
    }

    // MARK: - Trail

    func configureTrail(color: CursorTrailColor, customColor: NSColor, birthRate: Float) {
        // Reassigning the cells restarts the emitter, and this is called on every
        // coverage change, so skip it when nothing changed.
        if let current = trailConfiguration, current.color == color, current.customColor == customColor,
           current.birthRate == birthRate
        {
            return
        }
        trailConfiguration = (color, customColor, birthRate)
        emitterCell.birthRate = birthRate
        emitterCell.redRange = 0
        emitterCell.greenRange = 0
        emitterCell.blueRange = 0
        switch color {
        case .white:
            emitterCell.color = NSColor.white.cgColor
        case .accent:
            emitterCell.color = NSColor.controlAccentColor.usingColorSpace(.sRGB)?.cgColor ?? NSColor.white.cgColor
        case .rainbow:
            emitterCell.color = NSColor(srgbRed: 0.6, green: 0.6, blue: 0.6, alpha: 1).cgColor
            emitterCell.redRange = 0.4
            emitterCell.greenRange = 0.4
            emitterCell.blueRange = 0.4
        case .custom:
            emitterCell.color = customColor.cgColor
        }
        // Cell properties are copied when the cells are assigned.
        emitterLayer.emitterCells = [emitterCell]
    }

    func setTrail(position: CGPoint?, emitting: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let position {
            emitterLayer.emitterPosition = position
        }
        let shouldEmit = emitting && position != nil
        if shouldEmit != isEmitting {
            isEmitting = shouldEmit
            if shouldEmit {
                // Without a fresh beginTime the emitter "catches up" on the time it
                // was idle and bursts a clump of particles.
                emitterLayer.beginTime = CACurrentMediaTime()
            }
            emitterLayer.birthRate = shouldEmit ? 1 : 0
        }
        CATransaction.commit()
    }

    private static let particleImage: CGImage? = {
        let size = 32
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        let colors = [NSColor.white.cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        let center = CGPoint(x: size / 2, y: size / 2)
        context.drawRadialGradient(
            gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: CGFloat(size) / 2,
            options: []
        )
        return context.makeImage()
    }()
}

import AppKit

/// Spotlight and cursor trail, drawn above the wallpaper and its dimming.
/// Coordinates are this view's own (origin bottom-left, same as the screen).
final class CursorEffectsOverlayView: NSView {
    private let spotlightLayer = CALayer()
    private let spotlightMask = CALayer()
    private var spotlightRadius: CGFloat?
    private var spotlightMaskSize: CGSize = .zero

    private let emitterLayer = CAEmitterLayer()
    private var isEmitting = false
    private var trailAppearance: CursorTrailAppearance?

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

        emitterLayer.emitterShape = .point
        emitterLayer.renderMode = .additive
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

    func configureTrail(_ appearance: CursorTrailAppearance) {
        // Replacing the cells restarts the emitter, and this is called on every
        // coverage change, so skip it when nothing changed.
        guard appearance != trailAppearance else {
            return
        }
        trailAppearance = appearance
        let cell = Self.trailCell(shape: appearance.shape)
        cell.birthRate = appearance.birthRate
        Self.applyColor(appearance.color, custom: appearance.customColor, to: cell)
        emitterLayer.emitterCells = [cell]
    }

    /// Layer y points up here, so positive yAcceleration rises.
    private static func trailCell(shape: CursorTrailShape) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.emissionRange = .pi * 2
        switch shape {
        case .glow:
            cell.contents = softDotImage
            cell.lifetime = 0.7
            cell.lifetimeRange = 0.3
            cell.velocity = 25
            cell.velocityRange = 20
            cell.scale = 0.55
            cell.scaleRange = 0.2
            cell.scaleSpeed = -0.4
            cell.alphaSpeed = -1.4
        case .sparkle:
            cell.contents = sparkleImage
            cell.lifetime = 0.8
            cell.lifetimeRange = 0.3
            cell.velocity = 20
            cell.velocityRange = 15
            cell.scale = 0.5
            cell.scaleRange = 0.25
            cell.scaleSpeed = -0.35
            cell.spin = 2
            cell.spinRange = 3
            cell.alphaSpeed = -1.2
        case .bubble:
            cell.contents = bubbleImage
            cell.lifetime = 1.3
            cell.lifetimeRange = 0.4
            cell.velocity = 12
            cell.velocityRange = 10
            cell.yAcceleration = 60
            cell.xAcceleration = 0
            cell.scale = 0.45
            cell.scaleRange = 0.25
            cell.alphaSpeed = -0.7
        case .snow:
            cell.contents = softDotImage
            cell.lifetime = 1.6
            cell.lifetimeRange = 0.4
            cell.velocity = 10
            cell.velocityRange = 8
            cell.yAcceleration = -45
            cell.scale = 0.35
            cell.scaleRange = 0.15
            cell.alphaSpeed = -0.6
        }
        return cell
    }

    static func applyColor(_ color: CursorEffectColor, custom: RGBAColor, to cell: CAEmitterCell) {
        switch color {
        case .white:
            cell.color = NSColor.white.cgColor
        case .accent:
            cell.color = NSColor.controlAccentColor.usingColorSpace(.sRGB)?.cgColor ?? NSColor.white.cgColor
        case .rainbow:
            cell.color = NSColor(srgbRed: 0.6, green: 0.6, blue: 0.6, alpha: 1).cgColor
            cell.redRange = 0.4
            cell.greenRange = 0.4
            cell.blueRange = 0.4
        case .custom:
            cell.color = custom.nsColor.cgColor
        }
    }

    // MARK: - Click

    func showClick(at point: CGPoint, style: CursorClickStyle, color: CursorEffectColor, customColor: RGBAColor) {
        switch style {
        case .ripple:
            showRipple(at: point, color: Self.resolvedColor(color, custom: customColor))
        case .burst:
            showBurst(at: point, color: color, customColor: customColor)
        }
    }

    /// Rainbow has no single colour, so a ripple picks a random hue each click.
    private static func resolvedColor(_ color: CursorEffectColor, custom: RGBAColor) -> CGColor {
        switch color {
        case .white:
            NSColor.white.cgColor
        case .accent:
            NSColor.controlAccentColor.usingColorSpace(.sRGB)?.cgColor ?? NSColor.white.cgColor
        case .rainbow:
            NSColor(hue: .random(in: 0 ... 1), saturation: 0.6, brightness: 1, alpha: 1).cgColor
        case .custom:
            custom.nsColor.cgColor
        }
    }

    private func showRipple(at point: CGPoint, color: CGColor) {
        let radius: CGFloat = 60
        let ring = CAShapeLayer()
        ring.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        ring.position = point
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 2, dy: 2), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = color
        ring.lineWidth = 3
        ring.opacity = 0
        layer?.addSublayer(ring)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.15
        grow.toValue = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.6
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "ripple")
        CATransaction.commit()
    }

    private func showBurst(at point: CGPoint, color: CursorEffectColor, customColor: RGBAColor) {
        let cell = CAEmitterCell()
        cell.contents = Self.softDotImage
        cell.birthRate = 600
        cell.lifetime = 0.55
        cell.lifetimeRange = 0.2
        cell.velocity = 140
        cell.velocityRange = 60
        cell.emissionRange = .pi * 2
        cell.scale = 0.5
        cell.scaleRange = 0.2
        cell.scaleSpeed = -0.6
        cell.alphaSpeed = -1.6
        Self.applyColor(color, custom: customColor, to: cell)

        // Its own emitter so a burst never disturbs the trail. It emits for one
        // short moment and removes itself once the particles are gone.
        let burst = CAEmitterLayer()
        burst.frame = bounds
        burst.emitterShape = .point
        burst.emitterPosition = point
        burst.renderMode = .additive
        burst.beginTime = CACurrentMediaTime()
        burst.emitterCells = [cell]
        layer?.addSublayer(burst)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            burst.birthRate = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            burst.removeFromSuperlayer()
        }
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

    private static let softDotImage: CGImage? = {
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

    private static func particleContext(size: Int) -> CGContext? {
        CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    /// Four-pointed star with a soft glow behind it.
    private static let sparkleImage: CGImage? = {
        let size = 32
        guard let context = particleContext(size: size) else {
            return nil
        }
        let c = CGFloat(size) / 2
        let colors = [NSColor.white.withAlphaComponent(0.5).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray
        let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        context.drawRadialGradient(
            glow, startCenter: CGPoint(x: c, y: c), startRadius: 0, endCenter: CGPoint(x: c, y: c), endRadius: c * 0.6,
            options: []
        )
        let outer = c * 0.95
        let inner = c * 0.18
        context.move(to: CGPoint(x: c, y: c + outer))
        for index in 1 ..< 8 {
            let angle = CGFloat(index) * .pi / 4 + .pi / 2
            let radius = index.isMultiple(of: 2) ? outer : inner
            context.addLine(to: CGPoint(x: c + cos(angle) * radius, y: c + sin(angle) * radius))
        }
        context.closePath()
        context.setFillColor(NSColor.white.cgColor)
        context.fillPath()
        return context.makeImage()
    }()

    /// Hollow ring with a small highlight, so it reads as a bubble.
    private static let bubbleImage: CGImage? = {
        let size = 32
        guard let context = particleContext(size: size) else {
            return nil
        }
        let rect = CGRect(x: 3, y: 3, width: size - 6, height: size - 6)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(2)
        context.strokeEllipse(in: rect)
        context.setFillColor(NSColor.white.withAlphaComponent(0.15).cgColor)
        context.fillEllipse(in: rect)
        context.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        context.fillEllipse(in: CGRect(x: CGFloat(size) * 0.58, y: CGFloat(size) * 0.58, width: 5, height: 5))
        return context.makeImage()
    }()
}

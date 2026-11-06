import SwiftUI

/// Shared timings for the settings window so hover, press, disclosure and list changes feel
/// like one system. Springs rather than `.snappy`/`.smooth`, which need macOS 14.
enum Motion {
    static let quick = Animation.easeOut(duration: 0.18)
    static let hover = Animation.spring(response: 0.25, dampingFraction: 0.8)
    static let standard = Animation.spring(response: 0.3, dampingFraction: 0.88)

    /// Disclosed content fades in while sliding a few points down from its header.
    static let reveal = AnyTransition.opacity.combined(with: .offset(y: -6))
    static let pop = AnyTransition.opacity.combined(with: .scale(scale: 0.9))
    /// Fades the incoming view while removing the outgoing one immediately so the two never
    /// share layout size or keep two heavy subtrees alive at once.
    static let crossfade = AnyTransition.asymmetric(insertion: .opacity, removal: .identity)
}

private struct MotionAnimation<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// `.animation(_:value:)` that is skipped under Reduce Motion.
    func motionAnimation(
        _ animation: Animation = Motion.standard,
        value: some Equatable
    ) -> some View {
        modifier(MotionAnimation(animation: animation, value: value))
    }
}

extension SettingsView {
    @discardableResult
    func withMotion<Result>(
        _ animation: Animation = Motion.standard,
        _ body: () throws -> Result
    ) rethrows -> Result {
        try withAnimation(reduceMotion ? nil : animation, body)
    }
}

/// Plain-button replacement that dips slightly while pressed.
struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : Motion.quick, value: configuration.isPressed)
    }
}

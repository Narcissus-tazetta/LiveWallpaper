import Foundation

/// AVPlayer のビットレート/バッファ長を決める純粋な計算ロジック。
/// `WallpaperModel` の再生設定・実行環境から導ける値のみを入力に取り、
/// NSScreen/AVFoundation など実行時の副作用には触れない。
enum PlaybackProfileResolver {
    struct Inputs {
        var workProfile: WorkProfile
        var lightweightMode: Bool
        var targetMaxPixelWidth: Double
        var qualityPreset: QualityPreset
        var decodeMode: DecodeMode
        var chipClass: WallpaperModel.ChipClass
        var logicalCores: Int
        var frameRateLimit: FrameRateLimit
        var autoFrameRateBitRateFactor: Double
        var autoFrameRateBufferAdjustment: TimeInterval
    }

    static func resolve(
        _ inputs: Inputs,
        role: WallpaperModel.DedicatedPlayerRole = .active
    ) -> (bitRate: Double, buffer: TimeInterval) {
        let base = resolveActive(inputs)
        guard role == .warmStandby else {
            return base
        }
        // 一時停止中で画面に出ていないアイテムは、即座に昇格できる最小限の準備
        // だけで足りる(Apple推奨: preferredForwardBufferDuration を絞る)。
        // ビットレートは維持し、昇格直後の初期画質が落ちないようにする。
        return (bitRate: base.bitRate, buffer: min(base.buffer, 0.2))
    }

    static func resolveActive(_ inputs: Inputs) -> (bitRate: Double, buffer: TimeInterval) {
        switch resolvedWorkProfile(inputs) {
        case .ultraLight:
            return (bitRate: 900_000, buffer: 0.08)
        case .lowPower:
            return (bitRate: 1_350_000, buffer: 0.15)
        case .normal:
            break
        }

        let baseRate = baseBitRate(for: inputs.targetMaxPixelWidth, preset: inputs.qualityPreset)
        var bitRate =
            baseRate * decodeBitRateFactor(inputs) * frameRateBitRateFactor(inputs.frameRateLimit)
                * inputs.autoFrameRateBitRateFactor
        var buffer = qualityAdjustedBuffer(baseBufferDuration(inputs), preset: inputs.qualityPreset)
        buffer += inputs.autoFrameRateBufferAdjustment

        if inputs.lightweightMode {
            bitRate = min(bitRate, 1_500_000)
            buffer = min(buffer, 0.25)
        }

        return (bitRate: max(bitRate, 500_000), buffer: max(buffer, 0))
    }

    static func resolvedWorkProfile(_ inputs: Inputs) -> WorkProfile {
        if inputs.lightweightMode {
            return .ultraLight
        }
        if inputs.workProfile != .normal {
            return inputs.workProfile
        }
        if inputs.targetMaxPixelWidth <= 1920, inputs.qualityPreset != .quality,
           inputs.frameRateLimit != .fps60
        {
            return .lowPower
        }
        return .normal
    }

    static func resolvedDecodeMode(_ inputs: Inputs) -> DecodeMode {
        switch inputs.decodeMode {
        case .automatic, .gpuAdaptive:
            switch inputs.chipClass {
            case .appleSilicon:
                return .balanced
            case .intel:
                return inputs.logicalCores >= 8 ? .balanced : .efficiency
            }
        default:
            return inputs.decodeMode
        }
    }

    private static func baseBitRate(for width: Double, preset: QualityPreset) -> Double {
        if width < 2560 {
            switch preset {
            case .auto:
                return 2_200_000
            case .efficiency:
                return 1_500_000
            case .quality:
                return 3_000_000
            }
        }

        if width < 3840 {
            switch preset {
            case .auto:
                return 6_000_000
            case .efficiency:
                return 4_000_000
            case .quality:
                return 8_000_000
            }
        }

        switch preset {
        case .auto:
            return 12_000_000
        case .efficiency:
            return 8_000_000
        case .quality:
            return 16_000_000
        }
    }

    private static func frameRateBitRateFactor(_ frameRateLimit: FrameRateLimit) -> Double {
        switch frameRateLimit {
        case .off:
            return 1.0
        case .fps30:
            return 0.85
        case .fps60:
            return 1.3
        }
    }

    private static func decodeBitRateFactor(_ inputs: Inputs) -> Double {
        switch resolvedDecodeMode(inputs) {
        case .automatic, .gpuAdaptive:
            return 1.0
        case .balanced:
            return 1.05
        case .efficiency:
            return 0.75
        }
    }

    private static func baseBufferDuration(_ inputs: Inputs) -> TimeInterval {
        switch resolvedDecodeMode(inputs) {
        case .automatic, .gpuAdaptive:
            return 1.0
        case .balanced:
            return 1.5
        case .efficiency:
            return 0.25
        }
    }

    private static func qualityAdjustedBuffer(_ base: TimeInterval, preset: QualityPreset) -> TimeInterval {
        switch preset {
        case .auto:
            return base
        case .efficiency:
            return max(0, base - 0.5)
        case .quality:
            return base + 0.5
        }
    }
}

/// サーマル/バッテリー状態から自動フレームレート調整係数を導く純粋な計算ロジック。
enum AutoFrameRatePolicy {
    struct Inputs {
        var autoFrameRateEnabled: Bool
        var batteryAwareQualityEnabled: Bool
        var thermalState: ProcessInfo.ThermalState
        var isLowPowerModeEnabled: Bool
        var displayCount: Int
        var batteryInfo: (percentage: Int, onBatteryPower: Bool)?
    }

    /// - Returns: nil なら factor=1.0/adjustment=0(通常状態)からの変化なし。
    static func resolve(_ inputs: Inputs) -> (bitRateFactor: Double, bufferAdjustment: TimeInterval) {
        var nextBitRateFactor = 1.0
        var nextBufferAdjustment: TimeInterval = 0

        if inputs.autoFrameRateEnabled {
            if inputs.isLowPowerModeEnabled {
                nextBitRateFactor *= 0.82
                nextBufferAdjustment -= 0.25
            }

            if inputs.displayCount >= 2 {
                nextBitRateFactor *= 0.88
                nextBufferAdjustment -= 0.15
            }

            switch inputs.thermalState {
            case .serious:
                nextBitRateFactor *= 0.8
                nextBufferAdjustment -= 0.2
            case .critical:
                nextBitRateFactor *= 0.65
                nextBufferAdjustment -= 0.3
            default:
                break
            }
        }

        if inputs.batteryAwareQualityEnabled,
           let battery = inputs.batteryInfo, battery.onBatteryPower, battery.percentage <= 10
        {
            nextBitRateFactor *= 0.6
            nextBufferAdjustment -= 0.3
        }

        nextBitRateFactor = min(max(nextBitRateFactor, 0.55), 1.0)
        nextBufferAdjustment = min(max(nextBufferAdjustment, -0.5), 0)

        return (nextBitRateFactor, nextBufferAdjustment)
    }
}

import SwiftUI

extension SettingsView {
    /// model の値を読み、設定メソッドへ書き込む Binding の共通形。
    private func modelBinding<T>(
        _ get: @escaping @autoclosure () -> T,
        _ set: @escaping (T) -> Void
    ) -> Binding<T> {
        Binding(get: get, set: set)
    }

    var clickThroughBinding: Binding<Bool> {
        modelBinding(model.clickThrough) { model.setClickThrough($0) }
    }

    var launchAtLoginBinding: Binding<Bool> {
        modelBinding(model.launchAtLoginEnabled) {
            NotificationCenter.default.post(name: .toggleLaunchAtLogin, object: $0)
        }
    }

    var audioEnabledBinding: Binding<Bool> {
        modelBinding(model.audioEnabled) { value in
            withAnimation { model.setAudioEnabled(value) }
        }
    }

    var audioVolumeBinding: Binding<Double> {
        modelBinding(Double(model.audioVolume)) { model.setAudioVolume(Float($0)) }
    }

    var displayModeBinding: Binding<DisplayMode> {
        modelBinding(model.displayMode) { model.setDisplayMode($0) }
    }

    var globalFitModeBinding: Binding<VideoFitMode> {
        modelBinding(model.fitMode) { model.setFitMode($0) }
    }

    var lightweightModeBinding: Binding<Bool> {
        modelBinding(model.lightweightMode) { model.setLightweightMode($0) }
    }

    var suspendWhenFullScreenBinding: Binding<Bool> {
        modelBinding(model.suspendWhenOtherAppFullScreen) {
            _ = model.setSuspendWhenOtherAppFullScreen($0)
        }
    }

    var suspendHighSensitivityBinding: Binding<Bool> {
        modelBinding(model.suspendHighSensitivityEnabled) {
            _ = model.setSuspendHighSensitivityEnabled($0)
        }
    }

    var suspendFrontmostOnlyBinding: Binding<Bool> {
        modelBinding(model.suspendWhenOtherAppFrontmost) {
            _ = model.setSuspendWhenOtherAppFrontmost($0)
        }
    }

    var qualityPresetBinding: Binding<QualityPreset> {
        modelBinding(model.qualityPreset) { model.setQualityPreset($0) }
    }

    var workProfileBinding: Binding<WorkProfile> {
        modelBinding(model.workProfile) { model.setWorkProfile($0) }
    }

    var frameRateLimitBinding: Binding<FrameRateLimit> {
        modelBinding(model.frameRateLimit) { model.setFrameRateLimit($0) }
    }

    var decodeModeBinding: Binding<DecodeMode> {
        modelBinding(model.decodeMode) { model.setDecodeMode($0) }
    }

    var desktopLevelOffsetBinding: Binding<DesktopLevelOffset> {
        modelBinding(model.desktopLevelOffset) { model.setDesktopLevelOffset($0) }
    }

    var fullScreenAuxiliaryBinding: Binding<Bool> {
        modelBinding(model.useFullScreenAuxiliary) { model.setFullScreenAuxiliary($0) }
    }

    var menuBarOpaqueBinding: Binding<Bool> {
        modelBinding(model.menuBarOpaqueEnabled) { model.setMenuBarOpaqueEnabled($0) }
    }

    var autoFrameRateBinding: Binding<Bool> {
        modelBinding(model.autoFrameRateEnabled) { model.setAutoFrameRateEnabled($0) }
    }

    var batteryAwareQualityBinding: Binding<Bool> {
        modelBinding(model.batteryAwareQualityEnabled) { model.setBatteryAwareQualityEnabled($0) }
    }

    var autoUpdateBinding: Binding<Bool> {
        // 実体は AppDelegate が持つため書き込みは通知経由。表示は model に同期された
        // 観測可能な値を読む(UserDefaults 直読みだと外部変更でトグルが更新されない)。
        modelBinding(model.autoUpdateEnabled) {
            NotificationCenter.default.post(name: .toggleAutoUpdate, object: $0)
        }
    }

    var webWallpaperFeatureBinding: Binding<Bool> {
        modelBinding(model.webWallpaperFeatureEnabled) { model.setWebWallpaperFeatureEnabled($0) }
    }

    var spaceWallpaperFeatureBinding: Binding<Bool> {
        modelBinding(model.spaceWallpaperFeatureEnabled) {
            model.setSpaceWallpaperFeatureEnabled($0)
        }
    }

    var menuBarSpaceNumberBinding: Binding<Bool> {
        modelBinding(model.menuBarSpaceNumberEnabled) {
            model.setMenuBarSpaceNumberEnabled($0)
        }
    }

    var dedicatedPlaybackContinuityBinding: Binding<Bool> {
        modelBinding(model.dedicatedPlaybackContinuityEnabled) {
            model.setDedicatedPlaybackContinuityEnabled($0)
        }
    }

    var advancedSharingBinding: Binding<Bool> {
        modelBinding(model.advancedSharingEnabled) { model.setAdvancedSharingEnabled($0) }
    }

    var lockScreenSyncBinding: Binding<Bool> {
        modelBinding(model.lockScreenSyncEnabled) { model.setLockScreenSyncEnabled($0) }
    }

    var desktopIconsVisibleBinding: Binding<Bool> {
        modelBinding(model.desktopIconsVisible) { model.setDesktopIconsVisible($0) }
    }
}

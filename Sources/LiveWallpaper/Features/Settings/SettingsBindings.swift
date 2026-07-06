import SwiftUI

extension SettingsView {
  var clickThroughBinding: Binding<Bool> {
    Binding(
      get: { model.clickThrough },
      set: { model.setClickThrough($0) }
    )
  }

  var launchAtLoginBinding: Binding<Bool> {
    Binding(
      get: { model.launchAtLoginEnabled },
      set: { NotificationCenter.default.post(name: .toggleLaunchAtLogin, object: $0) }
    )
  }

  var audioEnabledBinding: Binding<Bool> {
    Binding(
      get: { model.audioEnabled },
      set: { value in withAnimation { model.setAudioEnabled(value) } }
    )
  }

  var audioVolumeBinding: Binding<Double> {
    Binding(
      get: { Double(model.audioVolume) },
      set: { model.setAudioVolume(Float($0)) }
    )
  }

  var displayModeBinding: Binding<DisplayMode> {
    Binding(
      get: { model.displayMode },
      set: { model.setDisplayMode($0) }
    )
  }

  var globalFitModeBinding: Binding<VideoFitMode> {
    Binding(
      get: { model.fitMode },
      set: { model.setFitMode($0) }
    )
  }

  var lightweightModeBinding: Binding<Bool> {
    Binding(
      get: { model.lightweightMode },
      set: { model.setLightweightMode($0) }
    )
  }

  var suspendWhenFullScreenBinding: Binding<Bool> {
    Binding(
      get: { model.suspendWhenOtherAppFullScreen },
      set: { _ = model.setSuspendWhenOtherAppFullScreen($0) }
    )
  }

  var suspendDetectionModeBinding: Binding<SuspendDetectionMode> {
    Binding(
      get: { model.suspendDetectionMode },
      set: { model.setSuspendDetectionMode($0) }
    )
  }

  var qualityPresetBinding: Binding<QualityPreset> {
    Binding(
      get: { model.qualityPreset },
      set: { model.setQualityPreset($0) }
    )
  }

  var workProfileBinding: Binding<WorkProfile> {
    Binding(
      get: { model.workProfile },
      set: { model.setWorkProfile($0) }
    )
  }

  var frameRateLimitBinding: Binding<FrameRateLimit> {
    Binding(
      get: { model.frameRateLimit },
      set: { model.setFrameRateLimit($0) }
    )
  }

  var decodeModeBinding: Binding<DecodeMode> {
    Binding(
      get: { model.decodeMode },
      set: { model.setDecodeMode($0) }
    )
  }

  var desktopLevelOffsetBinding: Binding<DesktopLevelOffset> {
    Binding(
      get: { model.desktopLevelOffset },
      set: { model.setDesktopLevelOffset($0) }
    )
  }

  var fullScreenAuxiliaryBinding: Binding<Bool> {
    Binding(
      get: { model.useFullScreenAuxiliary },
      set: { model.setFullScreenAuxiliary($0) }
    )
  }

  var menuBarOpaqueBinding: Binding<Bool> {
    Binding(
      get: { model.menuBarOpaqueEnabled },
      set: { model.setMenuBarOpaqueEnabled($0) }
    )
  }

  var autoFrameRateBinding: Binding<Bool> {
    Binding(
      get: { model.autoFrameRateEnabled },
      set: { model.setAutoFrameRateEnabled($0) }
    )
  }

  var autoUpdateBinding: Binding<Bool> {
    Binding(
      get: { UserDefaults.standard.bool(forKey: "autoUpdateEnabled") },
      set: { NotificationCenter.default.post(name: .toggleAutoUpdate, object: $0) }
    )
  }

  var advancedSharingBinding: Binding<Bool> {
    Binding(
      get: { model.advancedSharingEnabled },
      set: { model.setAdvancedSharingEnabled($0) }
    )
  }

  var lockScreenSyncBinding: Binding<Bool> {
    Binding(
      get: { model.lockScreenSyncEnabled },
      set: { model.setLockScreenSyncEnabled($0) }
    )
  }

  var desktopIconsVisibleBinding: Binding<Bool> {
    Binding(
      get: { model.desktopIconsVisible },
      set: { model.setDesktopIconsVisible($0) }
    )
  }
}

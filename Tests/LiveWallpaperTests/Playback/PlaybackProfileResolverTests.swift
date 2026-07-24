import XCTest
@testable import LiveWallpaper

final class PlaybackProfileResolverTests: XCTestCase {
    private func makeInputs(
        workProfile: WorkProfile = .normal,
        lightweightMode: Bool = false,
        targetMaxPixelWidth: Double = 1920,
        qualityPreset: QualityPreset = .auto,
        decodeMode: DecodeMode = .automatic,
        chipClass: WallpaperModel.ChipClass = .appleSilicon,
        logicalCores: Int = 8,
        frameRateLimit: FrameRateLimit = .off,
        autoFrameRateBitRateFactor: Double = 1.0,
        autoFrameRateBufferAdjustment: TimeInterval = 0
    ) -> PlaybackProfileResolver.Inputs {
        PlaybackProfileResolver.Inputs(
            workProfile: workProfile,
            lightweightMode: lightweightMode,
            targetMaxPixelWidth: targetMaxPixelWidth,
            qualityPreset: qualityPreset,
            decodeMode: decodeMode,
            chipClass: chipClass,
            logicalCores: logicalCores,
            frameRateLimit: frameRateLimit,
            autoFrameRateBitRateFactor: autoFrameRateBitRateFactor,
            autoFrameRateBufferAdjustment: autoFrameRateBufferAdjustment
        )
    }

    func testLightweightModeForcesUltraLightProfile() {
        let inputs = makeInputs(lightweightMode: true, targetMaxPixelWidth: 3840, qualityPreset: .quality)
        let profile = PlaybackProfileResolver.resolve(inputs)
        XCTAssertEqual(profile.bitRate, 900_000)
        XCTAssertEqual(profile.buffer, 0.08)
    }

    func testExplicitWorkProfileOverridesLowPowerHeuristic() {
        let inputs = makeInputs(workProfile: .lowPower, targetMaxPixelWidth: 3840)
        let profile = PlaybackProfileResolver.resolve(inputs)
        XCTAssertEqual(profile.bitRate, 1_350_000)
        XCTAssertEqual(profile.buffer, 0.15)
    }

    func testSmallScreenAutoQualityFallsBackToLowPowerProfile() {
        // width <= 1920, preset != .quality, frameRate != .fps60 => resolvedWorkProfile == .lowPower
        let inputs = makeInputs(targetMaxPixelWidth: 1920, qualityPreset: .auto, frameRateLimit: .off)
        let profile = PlaybackProfileResolver.resolve(inputs)
        XCTAssertEqual(profile.bitRate, 1_350_000)
        XCTAssertEqual(profile.buffer, 0.15)
    }

    func testQualityPresetKeepsNormalProfileEvenOnSmallScreen() {
        // The low-power screen-size heuristic only kicks in when preset != .quality;
        // .quality should always resolve to the .normal work profile regardless of width.
        let inputs = makeInputs(targetMaxPixelWidth: 1920, qualityPreset: .quality)
        XCTAssertEqual(PlaybackProfileResolver.resolvedWorkProfile(inputs), .normal)

        let lowPowerInputs = makeInputs(targetMaxPixelWidth: 1920, qualityPreset: .auto)
        XCTAssertEqual(PlaybackProfileResolver.resolvedWorkProfile(lowPowerInputs), .lowPower)
    }

    func testHigherFrameRateLimitIncreasesBitRate() {
        let base = makeInputs(targetMaxPixelWidth: 1920, qualityPreset: .quality, frameRateLimit: .off)
        let fast = makeInputs(targetMaxPixelWidth: 1920, qualityPreset: .quality, frameRateLimit: .fps60)
        let baseProfile = PlaybackProfileResolver.resolve(base)
        let fastProfile = PlaybackProfileResolver.resolve(fast)
        XCTAssertGreaterThan(fastProfile.bitRate, baseProfile.bitRate)
    }

    func testIntelWithFewCoresResolvesToEfficiencyDecode() {
        let inputs = makeInputs(decodeMode: .automatic, chipClass: .intel, logicalCores: 4)
        XCTAssertEqual(PlaybackProfileResolver.resolvedDecodeMode(inputs), .efficiency)
    }

    func testIntelWithManyCoresResolvesToBalancedDecode() {
        let inputs = makeInputs(decodeMode: .automatic, chipClass: .intel, logicalCores: 8)
        XCTAssertEqual(PlaybackProfileResolver.resolvedDecodeMode(inputs), .balanced)
    }

    func testAppleSiliconAlwaysResolvesToBalancedDecode() {
        let inputs = makeInputs(decodeMode: .automatic, chipClass: .appleSilicon, logicalCores: 2)
        XCTAssertEqual(PlaybackProfileResolver.resolvedDecodeMode(inputs), .balanced)
    }

    func testExplicitDecodeModePassesThrough() {
        let inputs = makeInputs(decodeMode: .efficiency, chipClass: .appleSilicon)
        XCTAssertEqual(PlaybackProfileResolver.resolvedDecodeMode(inputs), .efficiency)
    }

    func testWarmStandbyRoleCapsBufferButKeepsBitRate() {
        let inputs = makeInputs(targetMaxPixelWidth: 3840, qualityPreset: .quality)
        let active = PlaybackProfileResolver.resolve(inputs, role: .active)
        let warm = PlaybackProfileResolver.resolve(inputs, role: .warmStandby)
        XCTAssertEqual(warm.bitRate, active.bitRate)
        XCTAssertLessThanOrEqual(warm.buffer, 0.2)
    }

    func testBitRateNeverDropsBelowFloor() {
        // width > 1920 keeps this in the .normal branch (not the fixed .lowPower profile),
        // so the tiny autoFrameRateBitRateFactor actually exercises the floor clamp below.
        let inputs = makeInputs(
            targetMaxPixelWidth: 3000,
            qualityPreset: .efficiency,
            frameRateLimit: .fps30,
            autoFrameRateBitRateFactor: 0.1
        )
        XCTAssertEqual(PlaybackProfileResolver.resolvedWorkProfile(inputs), .normal)
        let profile = PlaybackProfileResolver.resolve(inputs)
        XCTAssertEqual(profile.bitRate, 500_000)
    }
}

final class AutoFrameRatePolicyTests: XCTestCase {
    private func makeInputs(
        autoFrameRateEnabled: Bool = true,
        batteryAwareQualityEnabled: Bool = true,
        thermalState: ProcessInfo.ThermalState = .nominal,
        isLowPowerModeEnabled: Bool = false,
        displayCount: Int = 1,
        batteryInfo: (percentage: Int, onBatteryPower: Bool)? = nil
    ) -> AutoFrameRatePolicy.Inputs {
        AutoFrameRatePolicy.Inputs(
            autoFrameRateEnabled: autoFrameRateEnabled,
            batteryAwareQualityEnabled: batteryAwareQualityEnabled,
            thermalState: thermalState,
            isLowPowerModeEnabled: isLowPowerModeEnabled,
            displayCount: displayCount,
            batteryInfo: batteryInfo
        )
    }

    func testNominalStateKeepsFactorsUnchanged() {
        let result = AutoFrameRatePolicy.resolve(makeInputs())
        XCTAssertEqual(result.bitRateFactor, 1.0)
        XCTAssertEqual(result.bufferAdjustment, 0)
    }

    func testDisabledAutoFrameRateIgnoresThermalAndPowerSignals() {
        let result = AutoFrameRatePolicy.resolve(
            makeInputs(autoFrameRateEnabled: false, thermalState: .critical, isLowPowerModeEnabled: true)
        )
        XCTAssertEqual(result.bitRateFactor, 1.0)
        XCTAssertEqual(result.bufferAdjustment, 0)
    }

    func testCriticalThermalStateReducesBitRateFactor() {
        let result = AutoFrameRatePolicy.resolve(makeInputs(thermalState: .critical))
        XCTAssertEqual(result.bitRateFactor, 0.65, accuracy: 0.0001)
        XCTAssertEqual(result.bufferAdjustment, -0.3, accuracy: 0.0001)
    }

    func testMultipleDisplaysAndLowPowerModeCompound() {
        let result = AutoFrameRatePolicy.resolve(
            makeInputs(isLowPowerModeEnabled: true, displayCount: 2)
        )
        XCTAssertEqual(result.bitRateFactor, 0.82 * 0.88, accuracy: 0.0001)
    }

    func testFactorsAreClampedToFloor() {
        let result = AutoFrameRatePolicy.resolve(
            makeInputs(
                thermalState: .critical,
                isLowPowerModeEnabled: true,
                displayCount: 3,
                batteryInfo: (percentage: 5, onBatteryPower: true)
            )
        )
        XCTAssertGreaterThanOrEqual(result.bitRateFactor, 0.55)
        XCTAssertGreaterThanOrEqual(result.bufferAdjustment, -0.5)
    }

    func testLowBatteryOnBatteryPowerReducesFactor() {
        let result = AutoFrameRatePolicy.resolve(
            makeInputs(batteryInfo: (percentage: 8, onBatteryPower: true))
        )
        XCTAssertEqual(result.bitRateFactor, 0.6, accuracy: 0.0001)
    }

    func testHighBatteryDoesNotTriggerReduction() {
        let result = AutoFrameRatePolicy.resolve(
            makeInputs(batteryInfo: (percentage: 80, onBatteryPower: true))
        )
        XCTAssertEqual(result.bitRateFactor, 1.0)
    }

    func testDisabledBatteryAwareQualityIgnoresLowBattery() {
        let result = AutoFrameRatePolicy.resolve(
            makeInputs(
                batteryAwareQualityEnabled: false,
                batteryInfo: (percentage: 5, onBatteryPower: true)
            )
        )
        XCTAssertEqual(result.bitRateFactor, 1.0)
    }
}

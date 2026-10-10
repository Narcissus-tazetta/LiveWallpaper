import AVFoundation

enum HDRVideo {
    static func containsHDR(_ asset: AVAsset) async throws -> Bool {
        try await !asset.loadTracks(withMediaCharacteristic: .containsHDRVideo).isEmpty
    }

    /// The H.264 presets (Medium/HighestQuality) convert PQ and HLG sources to 8-bit
    /// BT.709, so a re-encoded HDR wallpaper would lose its highlights. The HEVC preset
    /// keeps the transfer function and 10-bit depth, including through a scaling
    /// video composition.
    static func reEncodePreset(for asset: AVAsset, sdrPreset: String) async throws -> String {
        try await containsHDR(asset) ? AVAssetExportPresetHEVCHighestQuality : sdrPreset
    }
}

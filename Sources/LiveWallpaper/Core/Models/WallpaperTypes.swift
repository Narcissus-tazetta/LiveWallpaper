import Foundation

enum WallpaperKind: String, Codable {
    case video
    case web
}

/// 次へ/前へ送りの再生キューに乗る1エントリ。動画・Web壁紙どちらも表す。
enum WallpaperPlaybackEntry: Equatable {
    case video(String)
    case web(UUID)
}

enum DisplayMode: String {
    case mainOnly
    case allScreens
}

enum VideoFitMode: String, Codable {
    case fill
    case fit
}

enum FrameRateLimit: String {
    case off
    case fps30
    case fps60
}

enum DecodeMode: String {
    case automatic
    case gpuAdaptive
    case balanced
    case efficiency
}

enum WorkProfile: String {
    case normal
    case lowPower
    case ultraLight
}

enum QualityPreset: String {
    case auto
    case efficiency
    case quality
}

enum BakeQuality: String, CaseIterable, Identifiable {
    case standard
    case high
    case maximum

    var id: String {
        rawValue
    }

    var compressionQuality: Double {
        switch self {
        case .standard: return 0.8
        case .high: return 0.9
        case .maximum: return 1.0
        }
    }

    var bytesPerPixelSecond: Double {
        switch self {
        case .standard: return 0.57
        case .high: return 1.78
        case .maximum: return 9.05
        }
    }
}

enum DesktopLevelOffset: Int {
    case minusOne = -1
    case zero = 0
    case plusOne = 1
}

enum WallpaperTransitionStyle: String, CaseIterable {
    case crossfade
    case dipToBlack
}

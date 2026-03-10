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

enum DesktopLevelOffset: Int {
    case minusOne = -1
    case zero = 0
    case plusOne = 1
}

enum DisplayMode: String {
  case mainOnly
  case allScreens
}

enum VideoFitMode: String {
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
  case balanced
  case efficiency
}

enum DesktopLevelOffset: Int {
  case minusOne = -1
  case zero = 0
  case plusOne = 1
}

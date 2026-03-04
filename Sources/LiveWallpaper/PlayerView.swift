import AVFoundation
import AppKit

final class PlayerView: NSView {
  override func makeBackingLayer() -> CALayer {
    AVPlayerLayer()
  }

  var playerLayer: AVPlayerLayer {
    layer as! AVPlayerLayer
  }
}

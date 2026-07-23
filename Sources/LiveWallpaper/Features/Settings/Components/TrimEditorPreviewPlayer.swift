import AppKit
import AVFoundation
import SwiftUI

/// トリム編集用のプレビュー。本番再生(WallpaperModel+Playback.swift)と同じ
/// AVPlayerLooper(timeRange:) を使い、編集中のドラフト範囲をそのままループ試聴できる
/// ようにする(WYSIWYG)。Fit編集の WallpaperAVLayerPreview とは用途が異なる
/// (ジオメトリのpan/zoomではなく時間範囲のスクラブ/ループが主眼)ため別コンポーネントにする。
struct TrimEditorPreviewPlayer: NSViewRepresentable {
    let videoPath: String
    let loopRange: ClosedRange<Double>
    let isPlaying: Bool
    @Binding var currentTime: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(currentTime: $currentTime)
    }

    func makeNSView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.wantsLayer = true
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.backgroundColor = NSColor.black.cgColor
        context.coordinator.attach(to: view.playerLayer, path: videoPath, range: loopRange)
        context.coordinator.setPlaying(isPlaying)
        return view
    }

    func updateNSView(_ nsView: PreviewContainerView, context: Context) {
        context.coordinator.attach(to: nsView.playerLayer, path: videoPath, range: loopRange)
        context.coordinator.setPlaying(isPlaying)
    }

    static func dismantleNSView(_ nsView: PreviewContainerView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        private var currentPath: String?
        private var currentRange: ClosedRange<Double>?
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var timeObserver: Any?
        private let currentTimeBinding: Binding<Double>
        private var pendingRangeUpdate: Task<Void, Never>?
        private var desiredPlaying = true

        init(currentTime: Binding<Double>) {
            currentTimeBinding = currentTime
        }

        /// トリムハンドルのドラッグ中、範囲だけが変わる呼び出しをこの間隔だけ
        /// まとめる。ドラッグは1ピクセルごとに呼ばれるが、毎回 AVQueuePlayer
        /// 一式を作り直すとプレビューがカクつくため、動きが落ち着くまで
        /// 実際の再構築を遅らせる(パスが変わったとき=別の動画を選んだときは
        /// 即座に反映する)。
        private static let rangeUpdateDebounce: UInt64 = 150_000_000

        func attach(to layer: AVPlayerLayer, path: String, range: ClosedRange<Double>) {
            if currentPath == path, currentRange == range, let player {
                if layer.player !== player {
                    layer.player = player
                }
                return
            }

            guard currentPath == path else {
                pendingRangeUpdate?.cancel()
                pendingRangeUpdate = nil
                performAttach(to: layer, path: path, range: range)
                return
            }

            pendingRangeUpdate?.cancel()
            pendingRangeUpdate = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.rangeUpdateDebounce)
                guard !Task.isCancelled else {
                    return
                }
                self?.performAttach(to: layer, path: path, range: range)
            }
        }

        private func performAttach(to layer: AVPlayerLayer, path: String, range: ClosedRange<Double>) {
            stop()

            let url = URL(fileURLWithPath: path)
            let asset = AVURLAsset(url: url)
            let item = AVPlayerItem(asset: asset)
            let queue = AVQueuePlayer()
            queue.isMuted = true
            queue.volume = 0

            let timeRange = CMTimeRange(
                start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                end: CMTime(seconds: range.upperBound, preferredTimescale: 600)
            )
            looper = AVPlayerLooper(player: queue, templateItem: item, timeRange: timeRange)

            let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
            timeObserver = queue.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
                [weak self] time in
                self?.currentTimeBinding.wrappedValue = time.seconds
            }

            currentPath = path
            currentRange = range
            player = queue
            layer.player = queue
            if desiredPlaying {
                queue.play()
            }
        }

        func setPlaying(_ playing: Bool) {
            desiredPlaying = playing
            guard let player else {
                return
            }
            if playing {
                player.play()
            } else {
                player.pause()
            }
        }

        func stop() {
            pendingRangeUpdate?.cancel()
            pendingRangeUpdate = nil
            if let timeObserver, let player {
                player.removeTimeObserver(timeObserver)
            }
            timeObserver = nil
            player?.pause()
            player?.removeAllItems()
            looper = nil
            player = nil
            currentPath = nil
            currentRange = nil
        }
    }
}

final class PreviewContainerView: NSView {
    let playerLayer: AVPlayerLayer = .init()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    override func makeBackingLayer() -> CALayer {
        CALayer()
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    private func setupLayers() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        if playerLayer.superlayer == nil {
            layer?.addSublayer(playerLayer)
        }
    }
}

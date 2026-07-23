import AppKit
import AVFoundation
import SwiftUI

/// トリム編集用のプレビュー。本番再生(WallpaperModel+Playback.swift)と同じ
/// AVPlayerLooper(timeRange:) を使い、編集中のドラフト範囲をそのままループ試聴できる
/// ようにする(WYSIWYG)。Fit編集の WallpaperAVLayerPreview とは用途が異なる
/// (ジオメトリのpan/zoomではなく時間範囲のスクラブ/ループが主眼)ため別コンポーネントにする。
struct TrimEditorPreviewPlayer: NSViewRepresentable {
    let videoPath: String
    let trimStart: Double
    let trimEnd: Double?
    let loopStart: Double?
    let isPlaying: Bool
    let seekRequest: SeekToken?
    @Binding var currentTime: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(currentTime: $currentTime)
    }

    func makeNSView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.wantsLayer = true
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.backgroundColor = NSColor.black.cgColor
        context.coordinator.attach(
            to: view.playerLayer, path: videoPath,
            spec: .init(trimStart: trimStart, trimEnd: trimEnd, loopStart: loopStart)
        )
        context.coordinator.setPlaying(isPlaying)
        context.coordinator.applySeekIfNeeded(seekRequest)
        return view
    }

    func updateNSView(_ nsView: PreviewContainerView, context: Context) {
        context.coordinator.attach(
            to: nsView.playerLayer, path: videoPath,
            spec: .init(trimStart: trimStart, trimEnd: trimEnd, loopStart: loopStart)
        )
        context.coordinator.setPlaying(isPlaying)
        context.coordinator.applySeekIfNeeded(seekRequest)
    }

    static func dismantleNSView(_: PreviewContainerView, coordinator: Coordinator) {
        coordinator.stop()
    }

    /// `WallpaperLoopBuilder` に渡すループ条件。`ClosedRange<Double>` ではなく
    /// trimStart/trimEnd/loopStartをそのまま保持するのは、trimEndがnilの場合
    /// (ファイル終端まで再生)や「初回だけカット開始位置から」の情報を1本のrangeへ
    /// 潰さずに本番と同じ形で渡すため。
    struct LoopSpec: Equatable {
        let trimStart: Double
        let trimEnd: Double?
        let loopStart: Double?
    }

    final class Coordinator {
        private var currentPath: String?
        private var currentSpec: LoopSpec?
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var timeObserver: Any?
        private let currentTimeBinding: Binding<Double>
        private var pendingRangeUpdate: DispatchWorkItem?
        private var desiredPlaying = true
        private var lastAppliedSeekID: UUID?
        /// 直近に要求されたシーク先。デバウンス中や player 再構築の直後でも、
        /// 再構築が終わり次第この時刻へ飛べるよう保持しておく(でないと
        /// trimStart/trimEnd のドラッグ中に毎回 range 先頭へ戻ってしまう)。
        private var lastSeekTime: Double?

        init(currentTime: Binding<Double>) {
            currentTimeBinding = currentTime
        }

        /// トリムハンドルのドラッグ中、範囲だけが変わる呼び出しをこの間隔だけ
        /// まとめる。ドラッグは1ピクセルごとに呼ばれるが、毎回 AVQueuePlayer
        /// 一式を作り直すとプレビューがカクつくため、動きが落ち着くまで
        /// 実際の再構築を遅らせる(パスが変わったとき=別の動画を選んだときは
        /// 即座に反映する)。
        ///
        /// - Important: `DispatchQueue.main.asyncAfter` で必ずメインスレッドで
        ///   実行すること。`Coordinator` は `@MainActor` ではないため、以前ここを
        ///   `Task { try? await Task.sleep(...) }` にしていたときはバックグラウンド
        ///   スレッドで `layer.player` 代入や `queue.play()` を呼んでしまい、
        ///   AVPlayerLayer が描画されない(プレビューが黒画面のまま)不具合になった。
        private static let rangeUpdateDebounce: DispatchTimeInterval = .milliseconds(150)

        func attach(to layer: AVPlayerLayer, path: String, spec: LoopSpec) {
            if currentPath == path, currentSpec == spec, let player {
                if layer.player !== player {
                    layer.player = player
                }
                return
            }

            guard currentPath == path else {
                pendingRangeUpdate?.cancel()
                pendingRangeUpdate = nil
                // 別の動画に切り替わった場合、前の動画向けのシーク先を引き継がない。
                lastSeekTime = nil
                performAttach(to: layer, path: path, spec: spec)
                return
            }

            pendingRangeUpdate?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.performAttach(to: layer, path: path, spec: spec)
            }
            pendingRangeUpdate = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.rangeUpdateDebounce,
                execute: workItem
            )
        }

        private func performAttach(
            to layer: AVPlayerLayer,
            path: String,
            spec: LoopSpec
        ) {
            stop()

            let url = URL(fileURLWithPath: path)
            let asset = AVURLAsset(url: url)
            let item = AVPlayerItem(asset: asset)
            let queue = AVQueuePlayer()
            queue.isMuted = true
            queue.volume = 0

            looper = WallpaperLoopBuilder.makeLooper(
                player: queue,
                templateItem: item,
                trimStart: spec.trimStart,
                trimEnd: spec.trimEnd,
                loopStart: spec.loopStart,
                context: "preview"
            )

            let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
            timeObserver = queue.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
                [weak self] time in
                self?.currentTimeBinding.wrappedValue = time.seconds
            }

            currentPath = path
            currentSpec = spec
            player = queue
            layer.player = queue
            if let lastSeekTime {
                let upperBound = spec.trimEnd ?? lastSeekTime
                let clamped = min(max(lastSeekTime, spec.trimStart), upperBound)
                queue.seek(
                    to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
            }
            if desiredPlaying {
                queue.play()
            }
        }

        /// ハンドル/トラック操作による明示的なシーク要求を反映する。同じトークンを
        /// 二重適用しないよう id で去重し、再生中の currentTime レポート(一方向)とは
        /// 独立させる。
        func applySeekIfNeeded(_ token: SeekToken?) {
            guard let token, token.id != lastAppliedSeekID else {
                return
            }
            lastAppliedSeekID = token.id
            lastSeekTime = token.time
            guard let player else {
                return
            }
            player.seek(
                to: CMTime(seconds: token.time, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
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
            looper?.disableLooping()
            looper = nil
            player?.pause()
            player?.removeAllItems()
            player = nil
            currentPath = nil
            currentSpec = nil
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

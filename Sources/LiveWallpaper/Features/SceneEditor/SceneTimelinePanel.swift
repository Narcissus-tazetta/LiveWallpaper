import SwiftUI

extension SceneEditorView {
    // MARK: - Toolbar above the preview

    /// Viewing controls; none of them changes the wallpaper.
    func sceneZoomControls() -> some View {
        HStack(spacing: 10) {
            Button {
                scenePreviewController.zoom(to: scenePreviewController.zoom / 1.5)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(scenePreviewController.zoom <= ScenePreviewController.zoomRange.lowerBound)
            .help(model.localizedString("縮小表示"))
            .accessibilityLabel(model.localizedString("縮小表示"))

            Menu {
                ForEach([0.5, 1, 2, 4, 8], id: \.self) { zoom in
                    Button("\(Int(zoom * 100))%") {
                        scenePreviewController.zoom(to: zoom)
                    }
                }
                Divider()
                Button(model.localizedString("全体を表示")) {
                    scenePreviewController.resetView()
                }
            } label: {
                Text("\(Int((scenePreviewController.zoom * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    // Wide enough for "800%", so the controls do not shift as the zoom changes.
                    .frame(minWidth: 40)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(model.localizedString("表示の拡大率。ピンチ、または ⌘ を押しながらスクロールでも変えられます。"))

            Button {
                scenePreviewController.zoom(to: scenePreviewController.zoom * 1.5)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(scenePreviewController.zoom >= ScenePreviewController.zoomRange.upperBound)
            .help(model.localizedString("拡大表示"))
            .accessibilityLabel(model.localizedString("拡大表示"))

            if case .paint = sceneEditorTool {
                Toggle(model.localizedString("塗った範囲を表示"), isOn: $sceneMaskPainter.showsOverlay)
                    .toggleStyle(.checkbox)
                    .padding(.leading, 8)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
    }

    func sceneComparisonControls(path: String) -> some View {
        HStack(spacing: 12) {
            Button(model.localizedString("比較用に記録")) {
                model.recordSceneComparison(path: path)
            }
            .help(model.localizedString("いまの状態を、あとで見比べるために記録します。保存や取り消しの履歴には影響しません。"))

            Toggle(isOn: Binding(
                get: { scenePreviewController.isComparing },
                set: { comparing in
                    if comparing {
                        endSceneEditorTool()
                        model.endScenePresetTrial()
                    }
                    scenePreviewController.isComparing = comparing
                }
            )) {
                Label(model.localizedString("記録と比べる"), systemImage: "rectangle.split.2x1")
            }
            .toggleStyle(.button)
            .disabled(model.sceneComparisonSnapshots[path] == nil)
            .help(model.localizedString("オンの間、記録した状態をプレビューに表示します。"))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
    }

    // MARK: - Playback bar under the preview

    func scenePlaybackBar(path: String, document: SceneDocument, selectedID: UUID?, fixedTime: Double?) -> some View {
        let loop = Double(document.loopSeconds)
        let layer = selectedID.flatMap { id in document.layers.first { $0.id == id } }
        let keyframes = layer.map { $0.isKeyframed ? $0.keyframes : [] } ?? []
        let isPlaying = scenePreviewController.isPlaying && fixedTime == nil

        return HStack(spacing: 8) {
            Button {
                selectedSceneKeyframeID = nil
                scenePreviewController.play(from: 0)
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .help(model.localizedString("先頭から再生"))
            .accessibilityLabel(model.localizedString("先頭から再生"))

            Button {
                if isPlaying {
                    scenePreviewController.pause()
                } else {
                    let start = fixedTime ?? scenePreviewController.time
                    selectedSceneKeyframeID = nil
                    scenePreviewController.play(from: start)
                }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 14)
            }
            .help(model.localizedString(isPlaying ? "一時停止" : "再生"))
            .accessibilityLabel(model.localizedString(isPlaying ? "一時停止" : "再生"))

            Button {
                selectedSceneKeyframeID = nil
                scenePreviewController.play(from: max(loop - 2, 0))
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .help(model.localizedString("ループの終わりの 2 秒前から再生して、先頭へのつながりを確かめます"))
            .accessibilityLabel(model.localizedString("つなぎ目を確かめる"))

            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !isPlaying || !scenePreviewController.isWindowVisible)) { _ in
                let raw = fixedTime ?? scenePreviewController.time
                let time = (raw.truncatingRemainder(dividingBy: loop) + loop).truncatingRemainder(dividingBy: loop)
                HStack(spacing: 8) {
                    SceneTimelineTrack(
                        loopSeconds: loop,
                        time: time,
                        keyframes: keyframes,
                        selectedKeyframeID: selectedSceneKeyframeID,
                        isEnabled: !(layer?.isLocked ?? false),
                        onSeek: { seconds in
                            selectedSceneKeyframeID = nil
                            scenePreviewController.seek(to: seconds)
                        },
                        onSelectKeyframe: { id in
                            selectedSceneKeyframeID = id
                        },
                        onMoveKeyframe: { id, phase in
                            guard let layerID = layer?.id else {
                                return
                            }
                            setSceneKeyframeTime(phase, keyframeID: id, path: path, layerID: layerID)
                        }
                    )
                    .frame(height: 22)
                    Text(String(format: "%.1f / %d s", time, document.loopSeconds))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 76, alignment: .trailing)
                }
            }
        }
        .buttonStyle(.borderless)
        .disabled(!document.isAnimated)
        .onChange(of: selectedSceneKeyframeID) { id in
            // A chosen keyframe holds the preview at its time; the playhead stays
            // there when it is let go.
            if let id, let frame = keyframes.first(where: { $0.id == id }) {
                scenePreviewController.seek(to: frame.time * loop)
            }
        }
    }
}

/// The loop as a bar: the playhead, and the selected layer's keyframes as diamonds
/// that can be picked and dragged in time.
struct SceneTimelineTrack: View {
    let loopSeconds: Double
    let time: Double
    let keyframes: [SceneKeyframe]
    let selectedKeyframeID: UUID?
    let isEnabled: Bool
    let onSeek: (Double) -> Void
    let onSelectKeyframe: (UUID) -> Void
    let onMoveKeyframe: (UUID, Double) -> Void

    private static let diamondSize: CGFloat = 10
    private static let maxPhase = 0.999

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width - Self.diamondSize, 1)
            let inset = Self.diamondSize / 2
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 4)
                    .padding(.horizontal, inset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        let phase = min(max((value.location.x - inset) / width, 0), Self.maxPhase)
                        onSeek(phase * loopSeconds)
                    })

                ForEach(keyframes) { frame in
                    let isSelected = frame.id == selectedKeyframeID
                    Rectangle()
                        .fill(isSelected ? Color.accentColor : Color.secondary)
                        .frame(width: Self.diamondSize, height: Self.diamondSize)
                        .rotationEffect(.degrees(45))
                        .scaleEffect(isSelected ? 1.2 : 1)
                        .contentShape(Rectangle().size(width: 16, height: 22))
                        .offset(x: CGFloat(frame.time) * width)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("track")).onChanged { value in
                            onSelectKeyframe(frame.id)
                            guard isEnabled, abs(value.translation.width) > 2 else {
                                return
                            }
                            let phase = min(max((value.location.x - inset) / width, 0), Self.maxPhase)
                            onMoveKeyframe(frame.id, phase)
                        })
                        .accessibilityElement()
                        .accessibilityLabel(String(format: "%.1f s", frame.time * loopSeconds))
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                }

                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2, height: proxy.size.height)
                    .offset(x: inset - 1 + CGFloat(time / max(loopSeconds, 0.001)) * width)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(name: "track")
        }
        .accessibilityElement(children: .contain)
    }
}

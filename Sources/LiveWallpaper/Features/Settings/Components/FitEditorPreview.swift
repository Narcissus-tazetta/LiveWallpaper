import AppKit
import SwiftUI

/// 矢印キーの keyCode(HIToolbox の kVK_* 相当)。
private enum FitArrowKeyCode {
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126
}

extension SettingsView {
    static var fitPreviewPathExistsCache: [String: Bool] = [:]

    func fitPreviewPathExists(_ path: String) -> Bool {
        // 欠損も含めてキャッシュする。プレビュー本体は毎ドラッグフレームで再評価される
        // ため、ここで毎回 stat を叩くと欠損ファイル表示中の負荷が跳ね上がる。
        if let cached = Self.fitPreviewPathExistsCache[path] {
            return cached
        }
        let exists = FileManager.default.fileExists(atPath: path)
        Self.fitPreviewPathExistsCache[path] = exists
        return exists
    }

    /// 欠損キャッシュはファイル復活(復元・差し替え)を検出できないため、
    /// 動画の選択時とタブ表示時に該当エントリを破棄して再確認させる。
    func invalidateFitPreviewPathExistsCache(path: String?) {
        guard let path else {
            return
        }
        if Self.fitPreviewPathExistsCache[path] == false {
            Self.fitPreviewPathExistsCache.removeValue(forKey: path)
        }
    }

    func wallpaperFitPreview(path: String, screenID: String) -> some View {
        GeometryReader { geo in
            let canvasSize = geo.size
            let frameSize = centeredPreviewFrameSize(canvasSize: canvasSize, screenID: screenID)
            let fitMode = fitEditorFitMode(path: path, screenID: screenID)
            let zoom = fitEditorZoom(path: path, screenID: screenID)
            let offsetX = fitEditorOffsetX(path: path, screenID: screenID)
            let offsetY = fitEditorOffsetY(path: path, screenID: screenID)
            let frameGeometry = model.wallpaperRenderGeometry(
                path: path,
                screenID: screenID,
                containerSize: frameSize,
                fitMode: fitMode,
                zoom: zoom,
                offsetX: offsetX,
                offsetY: offsetY
            )

            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black.opacity(0.72))

                if fitPreviewPathExists(path) {
                    if fitPreviewMode == .video {
                        WallpaperAVLayerPreview(
                            videoPath: path,
                            fitMode: fitMode,
                            renderedSize: frameGeometry.renderedSize,
                            translation: frameGeometry.translation
                        )
                        .id(path)
                        .frame(width: canvasSize.width, height: canvasSize.height)
                    } else {
                        if let image = fitPreviewStillImages[path] {
                            Image(nsImage: image)
                                .resizable()
                                .frame(
                                    width: frameGeometry.renderedSize.width,
                                    height: frameGeometry.renderedSize.height
                                )
                                .offset(
                                    x: frameGeometry.translation.width,
                                    y: frameGeometry.translation.height
                                )
                        } else {
                            ProgressView()
                                .controlSize(.small)
                                .onAppear {
                                    requestFitPreviewStillImage(path: path)
                                }
                        }
                    }
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: frameSize.width, height: frameSize.height)
                    Image(systemName: "film")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                }

                LeftDragCaptureView(
                    isEnabled: isFitEditorInteractionEnabled,
                    onActivate: {
                        isFitEditorInteractionEnabled = true
                    },
                    onDelta: { delta in
                        let normalizedDX = Double(delta.width / max(frameSize.width, 1)) * 2
                        let normalizedDY = Double(delta.height / max(frameSize.height, 1)) * 2
                        moveFitEditorDraftOffset(
                            dx: normalizedDX,
                            dy: normalizedDY,
                            path: path,
                            screenID: screenID
                        )
                    },
                    onScrollDelta: { delta in
                        let normalizedDX = Double(delta.width / max(frameSize.width, 1)) * 2
                        let normalizedDY = Double(delta.height / max(frameSize.height, 1)) * 2
                        moveFitEditorDraftOffset(
                            dx: normalizedDX,
                            dy: normalizedDY,
                            path: path,
                            screenID: screenID
                        )
                    },
                    currentZoom: {
                        fitEditorZoom(path: path, screenID: screenID)
                    },
                    onZoomChange: { zoom, anchor in
                        setFitEditorDraftZoom(
                            zoom,
                            anchor: anchor,
                            path: path,
                            screenID: screenID
                        )
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(isFitEditorInteractionEnabled)

                if !isFitEditorInteractionEnabled {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.clear)
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                        .onTapGesture {
                            isFitEditorInteractionEnabled = true
                        }

                    VStack {
                        Spacer(minLength: 0)
                        Label(
                            model.localizedString("クリックして編集を開始"),
                            systemImage: "cursorarrow.rays"
                        )
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.92))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.5)))
                        .padding(.bottom, 14)
                    }
                    .allowsHitTesting(false)
                }
            }
            .compositingGroup()
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .clipped()
            .overlay(alignment: .center) {
                fitEditorCenterFrameOverlay(frameSize: frameSize)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onAppear {
                DispatchQueue.main.async {
                    updateFitEditorPreviewFrameSize(frameSize, path: path, screenID: screenID)
                }
            }
            .onChange(of: frameSize) { newSize in
                DispatchQueue.main.async {
                    updateFitEditorPreviewFrameSize(newSize, path: path, screenID: screenID)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 320, maxHeight: 460)
    }

    var fitEditorScreens: [WallpaperModel.DisplayScreenInfo] {
        model.availableDisplayScreens()
    }

    func screenAspect(for screenID: String) -> CGFloat {
        if let screen = fitEditorScreens.first(where: { $0.id == screenID }) {
            let width = max(screen.frame.width, 1)
            let height = max(screen.frame.height, 1)
            return width / height
        }
        return 16.0 / 9.0
    }

    func ensureFitEditorScreenSelection() {
        let screens = fitEditorScreens
        if screens.isEmpty {
            selectedFitScreenID = ""
            return
        }
        if screens.contains(where: { $0.id == selectedFitScreenID }) {
            return
        }
        selectedFitScreenID = screens[0].id
    }

    func resolvedFitScreenID() -> String {
        if fitEditorScreens.contains(where: { $0.id == selectedFitScreenID }) {
            return selectedFitScreenID
        }
        return fitEditorScreens.first?.id ?? "main"
    }

    func fitModeBinding(path: String, screenID: String) -> Binding<VideoFitMode> {
        Binding(
            get: { fitEditorFitMode(path: path, screenID: screenID) },
            set: { setFitEditorDraftFitMode($0, path: path, screenID: screenID) }
        )
    }

    func zoomBinding(path: String, screenID: String) -> Binding<Double> {
        Binding(
            get: { fitEditorZoom(path: path, screenID: screenID) },
            set: { setFitEditorDraftZoom($0, path: path, screenID: screenID) }
        )
    }

    func offsetXBinding(path: String, screenID: String) -> Binding<Double> {
        Binding(
            get: { fitEditorOffsetX(path: path, screenID: screenID) },
            set: { setFitEditorDraftOffsetX($0, path: path, screenID: screenID) }
        )
    }

    func offsetYBinding(path: String, screenID: String) -> Binding<Double> {
        Binding(
            get: { fitEditorOffsetY(path: path, screenID: screenID) },
            set: { setFitEditorDraftOffsetY($0, path: path, screenID: screenID) }
        )
    }

    func centeredPreviewFrameSize(canvasSize: CGSize, screenID: String) -> CGSize {
        let maxWidth = max(canvasSize.width * 0.94, 1)
        let maxHeight = max(canvasSize.height * 0.94, 1)
        let aspect = max(screenAspect(for: screenID), 0.2)

        var width = maxWidth
        var height = width / aspect
        if height > maxHeight {
            height = maxHeight
            width = height * aspect
        }
        return CGSize(width: width, height: height)
    }

    func fitEditorCenterFrameOverlay(frameSize: CGSize) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.92), lineWidth: 2.5)
                .frame(width: frameSize.width, height: frameSize.height)

            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.78), lineWidth: 1)
                .frame(width: frameSize.width + 6, height: frameSize.height + 6)

            Rectangle()
                .stroke(
                    Color.white.opacity(0.42),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )
                .frame(width: frameSize.width * 0.7, height: 1)

            Rectangle()
                .stroke(
                    Color.white.opacity(0.42),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )
                .frame(width: 1, height: frameSize.height * 0.7)
        }
        .allowsHitTesting(false)
    }

    func installFitKeyMonitorIfNeeded() {
        guard keyEventMonitor == nil else {
            return
        }

        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard selectedTab == .wallpaperFit else {
                return event
            }
            // A text field (name edit, search, ...) is being edited: let the
            // arrow keys move the caret/selection instead of panning the
            // preview. The field editor backing any focused NSTextField or
            // SwiftUI TextField is an NSTextView, a subclass of NSText.
            if (event.window ?? NSApp.keyWindow)?.firstResponder is NSText {
                return event
            }
            guard let path = resolvedFitEditorVideoPath(), !path.isEmpty else {
                return event
            }

            let step = event.modifierFlags.contains(.shift) ? 0.01 : 0.002
            let screenID = resolvedFitScreenID()

            switch event.keyCode {
            case FitArrowKeyCode.left:
                moveFitEditorDraftOffset(dx: -step, dy: 0, path: path, screenID: screenID)
                return nil
            case FitArrowKeyCode.right:
                moveFitEditorDraftOffset(dx: step, dy: 0, path: path, screenID: screenID)
                return nil
            case FitArrowKeyCode.down:
                moveFitEditorDraftOffset(dx: 0, dy: step, path: path, screenID: screenID)
                return nil
            case FitArrowKeyCode.up:
                moveFitEditorDraftOffset(dx: 0, dy: -step, path: path, screenID: screenID)
                return nil
            default:
                return event
            }
        }
    }

    func removeFitKeyMonitor() {
        guard let monitor = keyEventMonitor else {
            return
        }
        NSEvent.removeMonitor(monitor)
        keyEventMonitor = nil
    }
}

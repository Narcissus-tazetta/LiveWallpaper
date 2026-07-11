import AppKit
import SwiftUI

extension SettingsView {
    func wallpaperFitPreview(path: String, screenID: String) -> some View {
        GeometryReader { geo in
            let canvasSize = geo.size
            let frameSize = centeredPreviewFrameSize(canvasSize: canvasSize, screenID: screenID)
            let fitMode = fitEditor.fitMode(path: path, screenID: screenID)
            let zoom = fitEditor.zoom(path: path, screenID: screenID)
            let offsetX = fitEditor.offsetX(path: path, screenID: screenID)
            let offsetY = fitEditor.offsetY(path: path, screenID: screenID)
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

                if fitEditor.pathExists(path) {
                    if fitEditor.previewMode == .video {
                        WallpaperAVLayerPreview(
                            videoPath: path,
                            fitMode: fitMode,
                            renderedSize: frameGeometry.renderedSize,
                            translation: frameGeometry.translation
                        )
                        .id(path)
                        .frame(width: canvasSize.width, height: canvasSize.height)
                    } else {
                        if let image = fitEditor.stillImages[path] {
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
                                .frame(width: canvasSize.width, height: canvasSize.height)
                                .clipped()
                        } else {
                            ProgressView()
                                .controlSize(.small)
                                .onAppear {
                                    fitEditor.requestStillImage(path: path)
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
                    isEnabled: fitEditor.isInteractionEnabled,
                    onActivate: {
                        fitEditor.isInteractionEnabled = true
                    },
                    onDelta: { delta in
                        let normalizedDX = Double(delta.width / max(frameSize.width, 1)) * 2
                        let normalizedDY = Double(delta.height / max(frameSize.height, 1)) * 2
                        fitEditor.moveDraftOffset(
                            dx: normalizedDX,
                            dy: normalizedDY,
                            path: path,
                            screenID: screenID
                        )
                    },
                    onScrollDelta: { delta in
                        let normalizedDX = Double(delta.width / max(frameSize.width, 1)) * 2
                        let normalizedDY = Double(delta.height / max(frameSize.height, 1)) * 2
                        fitEditor.moveDraftOffset(
                            dx: normalizedDX,
                            dy: normalizedDY,
                            path: path,
                            screenID: screenID
                        )
                    },
                    currentZoom: {
                        fitEditor.zoom(path: path, screenID: screenID)
                    },
                    onZoomChange: { zoom, anchor in
                        fitEditor.setDraftZoom(
                            zoom,
                            anchor: anchor,
                            path: path,
                            screenID: screenID
                        )
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(fitEditor.isInteractionEnabled)

                if !fitEditor.isInteractionEnabled {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.clear)
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                        .onTapGesture {
                            fitEditor.isInteractionEnabled = true
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
            .frame(width: canvasSize.width, height: canvasSize.height)
            .compositingGroup()
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .clipped()
            .overlay(alignment: .center) {
                fitEditorCenterFrameOverlay(frameSize: frameSize)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onAppear {
                DispatchQueue.main.async {
                    fitEditor.updatePreviewFrameSize(frameSize, path: path, screenID: screenID)
                }
            }
            .onChange(of: frameSize) { newSize in
                DispatchQueue.main.async {
                    fitEditor.updatePreviewFrameSize(newSize, path: path, screenID: screenID)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 320, maxHeight: 460)
    }

    func centeredPreviewFrameSize(canvasSize: CGSize, screenID: String) -> CGSize {
        let maxWidth = max(canvasSize.width * 0.94, 1)
        let maxHeight = max(canvasSize.height * 0.94, 1)
        let aspect = max(fitEditor.screenAspect(for: screenID), 0.2)

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
}

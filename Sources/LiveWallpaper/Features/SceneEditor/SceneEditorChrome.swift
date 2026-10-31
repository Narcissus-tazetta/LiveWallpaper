import AppKit
import ImageIO
import SwiftUI

private struct SceneShowsHintsKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether the editor shows the explanations under its controls; the toolbar's
    /// info button turns them off for those who know the controls.
    var sceneShowsHints: Bool {
        get { self[SceneShowsHintsKey.self] }
        set { self[SceneShowsHintsKey.self] = newValue }
    }
}

/// An explanation under a control, hidden while hints are off.
struct SceneHintText: View {
    let text: String
    @Environment(\.sceneShowsHints) private var showsHints

    var body: some View {
        if showsHints {
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension View {
    /// A clicked borderless menu keeps the key focus, and its ring then sits on the
    /// button for good; the ring cannot be turned off before macOS 14.
    @ViewBuilder
    func sceneFocusRingHidden() -> some View {
        if #available(macOS 14.0, *) {
            focusEffectDisabled()
        } else {
            self
        }
    }
}

/// A layer's picture at row size, or its kind's symbol when it has none.
struct SceneLayerThumbnail: View {
    let url: URL?
    let symbol: String
    var isVideo = false

    @State private var image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(0.08))
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .scaledToFit()
                    .padding(1)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: 36, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if isVideo {
                Image(systemName: "film")
                    .font(.system(size: 7, weight: .semibold))
                    .padding(2)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 2))
                    .padding(1)
            }
        }
        .accessibilityHidden(true)
        .task(id: url) {
            image = nil
            guard let url else {
                return
            }
            let loaded = await SceneLayerThumbnailCache.shared.image(for: url)
            // The actor call runs on after a cancel; a slow load must not cover a newer layer's
            // picture.
            if !Task.isCancelled {
                image = loaded
            }
        }
    }
}

/// Small pictures of layer images. ImageIO scales while decoding, so a large texture
/// is never decoded whole for a row.
actor SceneLayerThumbnailCache {
    static let shared = SceneLayerThumbnailCache()

    private struct Key: Hashable {
        let path: String
        let modified: Date?
    }

    private var images: [Key: CGImage] = [:]

    func image(for url: URL) async -> CGImage? {
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        let key = Key(path: url.path, modified: modified)
        if let image = images[key] {
            return image
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 96
              ] as CFDictionary)
        else {
            return nil
        }
        images[key] = image
        return image
    }
}

/// A switch at the trailing edge with its label taking the rest of the row, so that
/// switches line up with the sliders and menus around them and long labels wrap.
struct SceneInspectorSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: configuration.$isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }
}

enum SceneInspectorMetrics {
    /// Leaves the controls room in the narrowest inspector; longer labels wrap.
    static let labelWidth: CGFloat = 112
    /// Menus shrink with the inspector and truncate rather than push it wider.
    static let menuMaxWidth: CGFloat = 200
}

import AppKit
import SwiftUI

extension SettingsView {
    /// Search and Add sit at the trailing end of the titlebar tab strip on the Wallpaper tab,
    /// where Finder and Photos keep them.
    var libraryToolbarItems: some View {
        HStack(spacing: 8) {
            SearchField(
                placeholder: model.localizedString("壁紙を検索"),
                text: $librarySearchText,
                isFocused: $isLibrarySearchFocused
            )
            .frame(width: 150)

            Button {
                NotificationCenter.default.post(name: .chooseVideo, object: nil)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.gradient, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(model.isImportingMedia)
            .help(model.localizedString("メディアを追加"))
            .accessibilityLabel(model.localizedString("メディアを追加"))
        }
    }

    var dropTargetOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    Color.accentColor.opacity(0.85),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )

            VStack(spacing: 12) {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(
                        Color.accentColor.gradient,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .shadow(color: Color.accentColor.opacity(0.45), radius: 14, y: 6)
                Text(model.localizedString("ドロップして壁紙に追加"))
                    .font(.title3.weight(.semibold))
                Text(model.localizedString("動画・GIF・画像をまとめて追加できます"))
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
        .padding(6)
        .allowsHitTesting(false)
    }

    /// A faint wash of the current wallpaper's average colour behind the window content. The
    /// settings tab's grouped form is opaque and would leave it showing only behind the tab strip.
    @ViewBuilder
    var ambientBackground: some View {
        if selectedTab != .settings,
           let path = model.currentVideoPath, !model.isWebWallpaperActive,
           let image = thumbnailCache.image(for: path),
           let color = AmbientColorCache.color(for: path, image: image)
        {
            RadialGradient(
                colors: [Color(nsColor: color).opacity(0.34), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 720
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.6), value: path)
        }
    }

    var wallpaperEmptyState: some View {
        VStack(spacing: 14) {
            Text(model.localizedString("好きな動画を壁紙にしましょう"))
                .font(.title3.weight(.semibold))
            Text(model.localizedString("動画・GIF・画像をここへドラッグするか、下のボタンから選んでください。追加した壁紙はすぐにデスクトップで再生されます。"))
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    NotificationCenter.default.post(name: .chooseVideo, object: nil)
                } label: {
                    Label(model.localizedString("メディアを選ぶ"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    selectedTab = .store
                } label: {
                    Label(model.localizedString("Storeで探す"), systemImage: "bag")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            if model.webWallpaperFeatureEnabled {
                Text(model.localizedString("Webサイトを壁紙にするときは「Web壁紙を追加」からURLを入力します"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(0.14),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                )
        )
    }
}

/// Average colour of each wallpaper's thumbnail, computed once per path.
@MainActor
enum AmbientColorCache {
    private static var colors: [String: NSColor] = [:]

    static func color(for path: String, image: NSImage) -> NSColor? {
        if let cached = colors[path] {
            return cached
        }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        // Lift dark averages so a mostly black video still tints the window a little.
        let raw = NSColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )
        let color = NSColor(
            hue: raw.hueComponent,
            saturation: min(raw.saturationComponent * 1.3, 1),
            brightness: max(raw.brightnessComponent, 0.55),
            alpha: 1
        )
        colors[path] = color
        return color
    }
}

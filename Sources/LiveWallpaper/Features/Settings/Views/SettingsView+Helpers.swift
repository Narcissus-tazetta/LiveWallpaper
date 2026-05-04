import AppKit
import SwiftUI

extension SettingsView {
    func tabButton(_ tab: SettingsTab, title: String, systemImage: String) -> some View {
        Button {
            selectedTab = tab
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .frame(minWidth: 130)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(selectedTab == tab ? Color.accentColor : Color.clear)
                )
                .foregroundColor(selectedTab == tab ? Color.white : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func compactToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .fixedSize()
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    func syncVolumeInputWithModel() {
        let percent = Int((model.audioVolume * 100).rounded())
        volumeInput = String(percent)
    }

    func commitVolumeInput() {
        guard !volumeInput.isEmpty else {
            syncVolumeInputWithModel()
            return
        }
        let percent = min(max(Int(volumeInput) ?? 0, 0), 100)
        model.setAudioVolume(Float(percent) / 100)
        volumeInput = String(percent)
    }

    func currentWallpaperSummaryText() -> String {
        guard let currentPath = model.currentVideoPath else {
            return model.allRegisteredVideoPaths.isEmpty ? "未登録" : "未再生"
        }
        return model.registeredVideoDisplayName(for: currentPath)
    }

    func currentPlaylistSummaryText() -> String {
        guard !model.playlists.isEmpty else {
            return "未作成"
        }
        return model.selectedPlaylistName
    }

    func currentDisplayModeSummaryText() -> String {
        switch model.displayMode {
        case .mainOnly:
            return "メインのみ"
        case .allScreens:
            return "全ディスプレイ"
        }
    }

    func currentWallpaperPreviewImage() -> NSImage? {
        guard let currentPath = model.currentVideoPath else {
            return nil
        }
        return thumbnailCache.image(for: currentPath)
    }

    func requestCurrentWallpaperThumbnailIfNeeded() {
        guard let currentPath = model.currentVideoPath else {
            return
        }
        requestWallpaperThumbnail(path: currentPath)
    }

    @ViewBuilder
    var currentWallpaperPreview: some View {
        let image = currentWallpaperPreviewImage()

        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 122, height: 70)
                    .clipped()
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "photo")
                        .font(.system(size: 18, weight: .medium))
                    Text("No Preview")
                        .font(.caption2)
                }
                .foregroundColor(.secondary)
            }
        }
        .frame(width: 122, height: 70)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
        .accessibilityLabel("現在の壁紙プレビュー")
    }

    func toggleHelp(_ topic: HelpTopic) {
        if expandedHelpTopics.contains(topic) {
            expandedHelpTopics.remove(topic)
        } else {
            expandedHelpTopics.insert(topic)
        }
    }

    func selectAppForSuspendExclusion() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [.applicationBundle]
        } else {
            panel.allowedFileTypes = ["app"]
        }
        panel.allowsOtherFileTypes = false
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "追加"

        if panel.runModal() == .OK,
           let url = panel.url
        {
            _ = model.addSuspendExclusionFromAppURL(url)
        }
    }
}

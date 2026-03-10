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

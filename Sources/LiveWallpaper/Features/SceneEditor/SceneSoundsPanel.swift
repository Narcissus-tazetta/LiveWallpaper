import SwiftUI
import UniformTypeIdentifiers

/// Sounds the scene plays on its own. They follow the app's audio setting and stay silent on the lock screen and screen saver.
struct SceneSoundsPanel: View {
    @ObservedObject var model: WallpaperModel
    let path: String

    var body: some View {
        if let document = model.sceneDocumentsByPath[path] {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button(model.localizedString("効果音を追加…")) { choose() }
                            .disabled(document.sounds.count >= SceneSound.maximumCount)
                        Spacer()
                    }
                    if document.sounds.isEmpty {
                        Text(model.localizedString("音声ファイルを追加すると、デスクトップで鳴らせます。鳴るのは、アプリの設定で壁紙の音を出す場合だけです。"))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    ForEach(document.sounds) { sound in
                        row(sound)
                        Divider()
                    }
                }
                .padding(.top, 8)
            } label: {
                Text(model.localizedString("効果音")).font(.headline)
            }
        }
    }

    private func row(_ sound: SceneSound) -> some View {
        let id = sound.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField(model.localizedString("名前"), text: Binding(
                    get: { sound.name }, set: { value in update(id) { $0.name = value } }
                ))
                Picker(model.localizedString("鳴らし方"), selection: Binding(
                    get: { sound.mode == .single ? SceneSound.Mode.loop : sound.mode },
                    set: { value in update(id) { $0.mode = value } }
                )) {
                    Text(model.localizedString("繰り返す")).tag(SceneSound.Mode.loop)
                    Text(model.localizedString("ときどき鳴らす")).tag(SceneSound.Mode.random)
                }
                .labelsHidden()
                .fixedSize()
                Button(role: .destructive) {
                    model.updateSceneSounds(path: path) { $0.removeAll { $0.id == id } }
                } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(model.localizedString("効果音を削除"))
            }
            HStack(spacing: 12) {
                Text(model.localizedString("音量")).frame(width: SceneInspectorMetrics.labelWidth, alignment: .leading)
                Slider(value: Binding(get: { sound.volume }, set: { value in update(id) { $0.volume = value } }), in: 0 ... 1)
                Text("\(Int((sound.volume * 100).rounded()))%")
                    .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            if sound.mode == .random {
                HStack {
                    // The player draws each pause from minimum...maximum, a range that must not run backward.
                    pause(model.localizedString("間隔の最短(秒)"), sound.minimumPause) { value in
                        update(id) { $0.minimumPause = value; $0.maximumPause = max($0.maximumPause, value) }
                    }
                    pause(model.localizedString("間隔の最長(秒)"), sound.maximumPause) { value in
                        update(id) { $0.maximumPause = value; $0.minimumPause = min($0.minimumPause, value) }
                    }
                }
            }
            Text(sound.files.joined(separator: ", "))
                .font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }

    private func pause(_ title: String, _ value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            TextField("", value: Binding(get: { value }, set: { set(max($0, 0)) }), format: .number)
                .frame(width: 56)
        }
    }

    private func update(_ id: UUID, _ change: @escaping (inout SceneSound) -> Void) {
        model.updateSceneSounds(path: path) { sounds in
            if let index = sounds.firstIndex(where: { $0.id == id }) { change(&sounds[index]) }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK else { return }
        model.addSceneSounds(from: panel.urls, path: path)
    }
}

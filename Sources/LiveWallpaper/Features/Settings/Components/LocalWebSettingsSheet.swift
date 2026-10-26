import AppKit
import SwiftUI

struct LocalWebSettingsSheet: View {
    @ObservedObject var model: WallpaperModel
    let context: WallpaperAuthorSettingsContext
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var integration = LocalWebIntegration.shared
    @State private var settings = LocalWebSettings()
    @State private var error: String?
    @State private var search = ""
    @State private var importingFile = false
    @State private var savedSettings = LocalWebSettings()
    @State private var isApplying = false

    init(model: WallpaperModel, context: WallpaperAuthorSettingsContext) {
        self.model = model
        self.context = context
    }

    private func localized(_ key: String) -> String {
        model.localizedString(key)
    }

    private var values: [String: WebPropertyValue] {
        var values = Dictionary(context.properties.map { ($0.id, $0.value) }, uniquingKeysWith: { _, last in last })
        values.merge(settings.values) { _, new in new }
        return values
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(context.title).font(.headline).lineLimit(1)
                Spacer()
                if context.applySettings != nil {
                    Button(localized("キャンセル")) { dismiss() }.disabled(isApplying)
                }
                Button(localized("完了")) {
                    if context.applySettings != nil, settings != savedSettings {
                        apply(dismissAfterward: true)
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isApplying || importingFile)
            }
            if context.applySettings != nil {
                Text(localized("設定を適用すると、元作品から作り直します。シーン編集での変更は置き換えられます。"))
                    .font(.caption).foregroundColor(.secondary)
            }
            Group {
                if context.supportsSpectrum || context.supportsMedia {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            if context.supportsSpectrum {
                                Toggle(localized("システム音に反応"), isOn: toggle(\.audioReactiveEnabled))
                                Text(localized("システム音の取得には、画面収録の許可が必要です。音声は保存しません。"))
                                    .font(.caption).foregroundColor(.secondary)
                                if settings.audioReactiveEnabled,
                                   let error = integration.audioError
                                {
                                    IntegrationFailureNote(model: model, message: error, privacy: "Privacy_ScreenCapture")
                                }
                            }
                            if context.supportsMedia {
                                Toggle(localized("Music／Spotifyの曲情報"), isOn: toggle(\.mediaEnabled))
                                Text(localized("起動中のアプリから曲名・ジャケット・再生状態を取得します。初回はオートメーションの許可が必要です。"))
                                    .font(.caption).foregroundColor(.secondary)
                                if settings.mediaEnabled, let error = integration.mediaError {
                                    IntegrationFailureNote(model: model, message: error, privacy: "Privacy_Automation")
                                }
                            }
                        }.padding(4)
                    }
                }
                if !context.properties.isEmpty {
                    TextField(localized("検索"), text: $search).textFieldStyle(.roundedBorder)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(context.properties) { property in
                                let label = LocalWebProperty.text(
                                    property.label,
                                    locale: model.appLocale
                                )
                                let condition = property.condition
                                    .flatMap { LocalWebPropertyCondition.evaluate(
                                        $0,
                                        values: values
                                    ) }
                                if condition != false,
                                   search.isEmpty || label.localizedCaseInsensitiveContains(search)
                                {
                                    propertyRow(property, label: label)
                                    if property.condition != nil, condition == nil {
                                        Text(localized("この項目の表示条件には未対応です。常に表示します。"))
                                            .font(.caption).foregroundColor(.secondary)
                                    }
                                }
                            }
                        }.padding(4)
                    }
                    HStack {
                        Button(localized("既定値に戻す")) {
                            settings.values = [:]
                            save()
                        }
                        Spacer()
                        if importingFile { ProgressView().controlSize(.small) }
                        if context.applySettings != nil {
                            if isApplying {
                                ProgressView().controlSize(.small)
                                Text(localized("準備中…")).foregroundColor(.secondary)
                            }
                            Button(localized("適用")) { apply() }
                                .disabled(isApplying || importingFile || settings == savedSettings)
                        }
                    }
                }
            }
            .disabled(isApplying)
            if let error { Text(error).font(.caption).foregroundColor(.red).textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 560, height: context.properties.isEmpty ? nil : 620)
        .interactiveDismissDisabled(isApplying)
        .task {
            do {
                settings = try context.loadSettings()
                savedSettings = settings
            } catch { self.error = error.localizedDescription }
        }
    }

    private func toggle(_ key: WritableKeyPath<LocalWebSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: key] }, set: { settings[keyPath: key] = $0; save() })
    }

    private func binding<T>(
        _ property: LocalWebProperty,
        read: @escaping (WebPropertyValue) -> T,
        write: @escaping (T) -> WebPropertyValue
    ) -> Binding<T> {
        Binding(get: { read(values[property.id] ?? property.value) }, set: {
            settings.values[property.id] = write($0)
            save()
        })
    }

    @ViewBuilder
    private func propertyRow(_ property: LocalWebProperty, label: String) -> some View {
        switch property.kind {
        case "bool":
            Toggle(label, isOn: binding(property, read: { $0.bool }, write: WebPropertyValue.bool))
        case "slider":
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(label)
                    Spacer()
                    Text(
                        (values[property.id] ?? property.value).number,
                        format: .number.precision(.fractionLength(0 ... 3))
                    )
                    .monospacedDigit().foregroundColor(.secondary)
                }
                let minimum = property.minimum ?? 0
                let maximum = property.maximum ?? 100
                if maximum > minimum {
                    if let step = property.step, step > 0 {
                        Slider(
                            value: binding(
                                property,
                                read: { min(max($0.number, minimum), maximum) },
                                write: WebPropertyValue.number
                            ),
                            in: minimum ... maximum,
                            step: step
                        )
                    } else {
                        Slider(
                            value: binding(
                                property,
                                read: { min(max($0.number, minimum), maximum) },
                                write: WebPropertyValue.number
                            ),
                            in: minimum ... maximum
                        )
                    }
                }
            }
        case "combo":
            Picker(label, selection: binding(property, read: { $0 }, write: { $0 })) {
                ForEach(Array((property.options ?? []).enumerated()), id: \.offset) { _, option in
                    Text(LocalWebProperty.text(option.label, locale: model.appLocale))
                        .tag(option.value)
                }
            }
        case "color":
            ColorPicker(label, selection: binding(property, read: { value in
                let components = value.string.split(separator: " ").compactMap { Double($0) }
                return components.count >= 3 ? Color(
                    .sRGB,
                    red: components[0],
                    green: components[1],
                    blue: components[2]
                ) : .black
            }, write: { color in
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else {
                    return .string("0 0 0")
                }
                return .string("\(rgb.redComponent) \(rgb.greenComponent) \(rgb.blueComponent)")
            }), supportsOpacity: false)
        case "textinput":
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                TextField(
                    "",
                    text: binding(property, read: { $0.string }, write: WebPropertyValue.string)
                ).textFieldStyle(.roundedBorder)
            }
        case "file":
            HStack {
                Text(label)
                Spacer()
                if !(values[property.id] ?? property.value).string.isEmpty {
                    Image(systemName: "checkmark.circle").foregroundColor(.secondary)
                    Button(localized("リセット")) {
                        settings.values[property.id] = property.value; save()
                    }
                }
                Button(localized("ファイルを選択")) { selectFile(property) }.disabled(importingFile || context.importFile == nil)
            }
        case "group":
            Divider()
            Text(label).font(.headline)
        case "text":
            Text(label).font(.caption).foregroundColor(.secondary)
        default: EmptyView()
        }
    }

    private func selectFile(_ property: LocalWebProperty) {
        guard let importFile = context.importFile else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            importingFile = true
            Task { @MainActor in
                defer { importingFile = false }
                do {
                    settings
                        .values[property.id] = try await .string(importFile(url))
                    save()
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    private func save() {
        guard context.applySettings == nil else { return }
        do {
            try context.saveSettings(settings)
            savedSettings = settings
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func apply(dismissAfterward: Bool = false) {
        guard let applySettings = context.applySettings else { return }
        isApplying = true
        error = nil
        let snapshot = settings
        Task { @MainActor in
            defer { isApplying = false }
            do {
                try await applySettings(snapshot)
                savedSettings = snapshot
                if dismissAfterward { dismiss() }
            } catch { self.error = localized(error.localizedDescription) }
        }
    }
}

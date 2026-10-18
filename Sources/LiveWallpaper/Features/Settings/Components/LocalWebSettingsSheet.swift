import AppKit
import SwiftUI

struct LocalWebSettingsSheet: View {
    @ObservedObject var model: WallpaperModel
    let source: WebWallpaperSource
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var integration = LocalWebIntegration.shared
    @State private var package: LocalWebWallpaperPackage?
    @State private var settings = LocalWebSettings()
    @State private var error: String?
    @State private var search = ""
    @State private var importingFile = false

    private func localized(_ key: String) -> String {
        model.localizedString(key)
    }

    private var values: [String: WebPropertyValue] {
        var values = Dictionary(uniqueKeysWithValues: (package?.properties ?? []).map { (
            $0.id,
            $0.value
        ) })
        values.merge(settings.values) { _, new in new }
        return values
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(source.displayName).font(.headline).lineLimit(1)
                Spacer()
                Button(localized("完了")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            if let package {
                if package.supportsSpectrum == true || package.supportsMedia == true {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            if package.supportsSpectrum == true {
                                Toggle(localized("システム音に反応"), isOn: toggle(\.audioReactiveEnabled))
                                Text(localized("システム音の取得には、画面収録の許可が必要です。音声は保存しません。"))
                                    .font(.caption).foregroundColor(.secondary)
                                if settings.audioReactiveEnabled,
                                   let error = integration.audioError
                                {
                                    IntegrationFailureNote(model: model, message: error, privacy: "Privacy_ScreenCapture")
                                }
                            }
                            if package.supportsMedia == true {
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
                TextField(localized("検索"), text: $search).textFieldStyle(.roundedBorder)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(package.properties ?? []) { property in
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
                }
            }
            if let error { Text(error).font(.caption).foregroundColor(.red).textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 560, height: 620)
        .task {
            do {
                (package, settings) = try model.localWebConfiguration(for: source)
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
                                read: { $0.number },
                                write: WebPropertyValue.number
                            ),
                            in: minimum ... maximum,
                            step: step
                        )
                    } else {
                        Slider(
                            value: binding(
                                property,
                                read: { $0.number },
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
                let rgb = NSColor(color).usingColorSpace(.sRGB)!
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
                Button(localized("ファイルを選択")) { selectFile(property) }.disabled(importingFile)
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
                        .values[property.id] = try await .string(model.importLocalWebPropertyFile(
                            url,
                            source: source
                        ))
                    save()
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    private func save() {
        do {
            try model.saveLocalWebSettings(settings, source: source)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

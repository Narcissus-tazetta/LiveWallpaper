import SwiftUI

/// The settings a viewer can change in "作品の設定", which scripts read as `ctx.userProperties`.
struct SceneUserPropertiesPanel: View {
    @ObservedObject var model: WallpaperModel
    let path: String
    @State private var selectedID: String?

    private static let kinds = ["slider", "bool", "combo", "textinput", "color"]

    var body: some View {
        if let document = model.sceneDocumentsByPath[path] {
            let properties = document.properties ?? []
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Menu(model.localizedString("設定項目を追加")) {
                            ForEach(Self.kinds, id: \.self) { kind in
                                Button(kindName(kind)) { add(kind: kind, existing: properties) }
                            }
                        }
                        Spacer()
                    }
                    if properties.isEmpty {
                        Text(model.localizedString("項目を追加すると、利用者が「作品の設定」で値を変えられます。スクリプトでは ctx.userProperties.<ID> で読めます。"))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    ForEach(properties) { property in
                        row(property, all: properties)
                        Divider()
                    }
                }
                .padding(.top, 8)
            } label: {
                Text(model.localizedString("ユーザー設定項目")).font(.headline)
            }
        }
    }

    private func kindName(_ kind: String) -> String {
        switch kind {
        case "slider": model.localizedString("スライダー")
        case "bool": model.localizedString("オン／オフ")
        case "combo": model.localizedString("選択肢")
        case "textinput": model.localizedString("文字入力")
        default: model.localizedString("色")
        }
    }

    private func add(kind: String, existing: [LocalWebProperty]) {
        var number = existing.count + 1
        while existing.contains(where: { $0.id == "property\(number)" }) { number += 1 }
        var property = LocalWebProperty(
            id: "property\(number)", kind: kind, label: ["default": kindName(kind)], value: .null
        )
        switch kind {
        case "slider":
            property.value = .number(0.5)
            property.minimum = 0
            property.maximum = 1
            property.step = 0.01
        case "bool": property.value = .bool(false)
        case "combo":
            let options = ["A", "B"]
            property.options = options.map { .init(label: ["default": $0], value: .string($0)) }
            property.value = .string(options[0])
        case "textinput": property.value = .string("")
        default: property.value = .string("1 1 1")
        }
        model.updateSceneProperties(path: path) { $0.append(property) }
    }

    private func update(_ id: String, _ change: @escaping (inout LocalWebProperty) -> Void) {
        model.updateSceneProperties(path: path) { properties in
            if let index = properties.firstIndex(where: { $0.id == id }) { change(&properties[index]) }
        }
    }

    @ViewBuilder
    private func row(_ property: LocalWebProperty, all: [LocalWebProperty]) -> some View {
        let id = property.id
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField(model.localizedString("表示名"), text: Binding(
                    get: { property.label["default"] ?? "" },
                    set: { value in update(id) { $0.label = ["default": value] } }
                ))
                TextField(model.localizedString("ID"), text: Binding(
                    get: { property.id },
                    set: { value in
                        // Scripts name the property by this ID, so it must stay unique and non-empty.
                        let clean = value.filter { $0.isLetter || $0.isNumber || $0 == "_" }
                        guard !clean.isEmpty, !all.contains(where: { $0.id == clean && $0.id != id }) else { return }
                        update(id) { $0.id = clean }
                    }
                ))
                .frame(width: 120)
                Text(kindName(property.kind)).font(.caption).foregroundColor(.secondary)
                Button(role: .destructive) {
                    model.updateSceneProperties(path: path) { $0.removeAll { $0.id == id } }
                } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(model.localizedString("設定項目を削除"))
            }
            switch property.kind {
            case "slider":
                HStack {
                    numberField(model.localizedString("最小値"), property.minimum ?? 0) { value in update(id) { $0.minimum = value } }
                    numberField(model.localizedString("最大値"), property.maximum ?? 1) { value in update(id) { $0.maximum = value } }
                    numberField(model.localizedString("初期値"), property.value.number) { value in update(id) { $0.value = .number(value) } }
                }
            case "bool":
                Toggle(model.localizedString("初期値"), isOn: Binding(
                    get: { property.value.bool }, set: { value in update(id) { $0.value = .bool(value) } }
                )).toggleStyle(.checkbox)
            case "combo":
                TextField(model.localizedString("選択肢（カンマ区切り）"), text: Binding(
                    get: { (property.options ?? []).map { $0.value.string }.joined(separator: ", ") },
                    set: { text in
                        let values = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        update(id) { property in
                            property.options = values.map { .init(label: ["default": $0], value: .string($0)) }
                            if !values.contains(property.value.string), let first = values.first { property.value = .string(first) }
                        }
                    }
                ))
            case "textinput":
                TextField(model.localizedString("初期値"), text: Binding(
                    get: { property.value.string }, set: { value in update(id) { $0.value = .string(value) } }
                ))
            default:
                ColorPicker(model.localizedString("初期値"), selection: Binding(
                    get: {
                        let c = property.value.string.split(separator: " ").compactMap { Double($0) }
                        return c.count >= 3 ? Color(.sRGB, red: c[0], green: c[1], blue: c[2]) : .white
                    },
                    set: { color in
                        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                        update(id) { $0.value = .string("\(rgb.redComponent) \(rgb.greenComponent) \(rgb.blueComponent)") }
                    }
                ), supportsOpacity: false)
            }
        }
    }

    private func numberField(_ title: String, _ value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            TextField("", value: Binding(get: { value }, set: set), format: .number)
                .frame(width: 64)
        }
    }
}

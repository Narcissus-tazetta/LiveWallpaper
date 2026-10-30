import SwiftUI

struct SceneScriptPanel: View {
    @ObservedObject var model: WallpaperModel
    @ObservedObject var editor: SceneScriptEditorController
    @ObservedObject var preview: ScenePreviewController
    let path: String
    let selectedLayerID: UUID?
    @State private var selectedID: UUID?

    var body: some View {
        if let document = model.sceneDocumentsByPath[path] {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Menu(model.localizedString("スクリプトを追加")) {
                            ForEach(SceneScriptSample.allCases) { sample in
                                Button(model.localizedString(sample.title)) {
                                    selectedID = model.addSceneScript(sample, path: path, layerID: selectedLayerID)
                                }
                            }
                        }
                        .disabled(document.scripts.count >= SceneScript.maximumCount)
                        Text("\(document.scripts.count) / \(SceneScript.maximumCount)")
                            .font(.caption).foregroundColor(.secondary)
                        if !document.scripts.isEmpty {
                            Picker(model.localizedString("スクリプト"), selection: Binding(
                                get: { selectedScript(in: document)?.id }, set: { selectedID = $0 }
                            )) {
                                ForEach(document.scripts) { Text($0.name).tag(Optional($0.id)) }
                            }
                            .labelsHidden()
                        }
                        Spacer()
                    }
                    if document.hasUnapprovedScripts {
                        Label(model.localizedString("この壁紙には未許可のスクリプトがあります。「実行して適用」で有効にするか、停止して使えます。"), systemImage: "pause.circle")
                            .font(.caption).foregroundColor(.orange)
                    }
                    if let script = selectedScript(in: document) {
                        controls(script, document: document)
                    } else {
                        Text(model.localizedString("サンプルを追加して、レイヤーの動き・色・エフェクトをJavaScriptで設定できます。"))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(.top, 8)
            } label: {
                Text(model.localizedString("スクリプト(JavaScript)"))
                    .font(.headline)
            }
            .disclosureGroupStyle(ScriptDisclosureStyle())
        }
    }

    private func selectedScript(in document: SceneDocument) -> SceneScript? {
        document.scripts.first { $0.id == selectedID } ?? document.scripts.first
    }

    @ViewBuilder
    private func controls(_ script: SceneScript, document: SceneDocument) -> some View {
        let draft = editor.draft(for: script, path: path)
        HStack {
            TextField(model.localizedString("名前"), text: textBinding(script, \.name))
            Text(!editor.isDirty(script, path: path)
                 ? model.localizedString("適用済み") : model.localizedString("未適用の変更"))
                .font(.caption).foregroundColor(.secondary)
            if draft.isValidating { ProgressView().controlSize(.small) }
        }
        let issue = model.sceneScriptIssues[path]?.first { $0.scriptID == script.id }
        let failed = issue != nil
        Text(model.localizedString(
            issue?.isTemporary == true ? "一時停止中(処理が重いため、自動で再開します)"
                : issue?.isPartial == true ? "一部がエラーで停止(他は実行中)"
                : failed ? "エラーで停止" : script.canRun ? "実行中" : script.isEnabled ? "未許可" : "停止中"
        ))
            .font(.caption).foregroundColor(failed ? .orange : script.canRun ? .green : .secondary)
        HStack(spacing: 16) {
            Toggle(model.localizedString("ループ時刻"), isOn: boolBinding(script, \.usesTime))
            Toggle(model.localizedString("時間帯"), isOn: boolBinding(script, \.usesTimeOfDay))
            Toggle(model.localizedString("カーソル"), isOn: boolBinding(script, \.usesCursor))
            Toggle(model.localizedString("曲情報"), isOn: boolBinding(script, \.usesMedia))
                .help(model.localizedString("起動中のアプリから曲名・ジャケット・再生状態を取得します。初回はオートメーションの許可が必要です。"))
            Toggle(model.localizedString("システム音"), isOn: boolBinding(script, \.readsAudio))
                .help(model.localizedString("システム音の周波数帯の強さを ctx.audio で読めます。作品ごとの「システム音に反応」を許可したときだけ値が入ります。"))
        }.toggleStyle(.checkbox)
        Toggle(model.localizedString("全レイヤーを管理（追加したレイヤーも含む）"), isOn: boolBinding(script, \.targetsAllLayers))
            .toggleStyle(.checkbox)
        if draft.script.targetsAllLayers {
            Text(model.localizedString("1本で全レイヤーの動き・色・表示・エフェクト・粒子を制御できます。ctx.targetsに全レイヤーが入ります。"))
                .font(.caption).foregroundColor(.secondary)
        }
        FlowLayoutTargets(layers: document.layers, selected: draft.script.targetLayerIDs(in: document.layers), title: model.localizedString("対象レイヤー")) { id in
            editor.edit(script, path: path) { value in
                if value.script.layerIDs.contains(id) { value.script.layerIDs.removeAll { $0 == id } }
                else { value.script.layerIDs.append(id) }
            }
        }.disabled(draft.script.targetsAllLayers)
        ScriptCodeEditor(text: textBinding(script, \.source))
            .frame(height: 260)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            .accessibilityLabel(model.localizedString("JavaScriptコード"))
        DisclosureGroup(model.localizedString("パラメーター(JSONの数値)")) {
            TextEditor(text: Binding(get: { editor.draft(for: script, path: path).paramsText }, set: { text in
                editor.edit(script, path: path) { $0.paramsText = text }
            }))
            .font(.system(.caption, design: .monospaced)).frame(height: 100)
        }
        .disclosureGroupStyle(ScriptDisclosureStyle())
        HStack {
            Button(model.localizedString("実行して適用")) {
                Task {
                    let cursor = preview.simulatedCursor ?? .zero
                    await editor.run(script, path: path, model: model,
                                     input: SceneFrameInput(parallax: cursor, cursor: preview.simulatedCursor.map { ($0 + 1) / 2 }, time: preview.time),
                                     timeOfDay: preview.simulatedTimeOfDay ?? document.timeOfDay(at: Date()))
                }
            }.buttonStyle(.borderedProminent).disabled(draft.isValidating)
            Button(model.localizedString("停止")) { model.stopSceneScript(script.id, path: path) }
                .disabled(!script.isEnabled)
            Button(model.localizedString("下書きを破棄")) { editor.discard(script, path: path) }
                .disabled(draft.isValidating)
            Spacer()
            Button(role: .destructive) { model.removeSceneScript(script.id, path: path) } label: {
                Image(systemName: "trash")
            }.help(model.localizedString("スクリプトを削除"))
        }
        if let error = draft.error ?? model.sceneScriptIssues[path]?.first(where: { $0.scriptID == script.id })?.errorDescription {
            Text(error).font(.system(.caption, design: .monospaced)).foregroundColor(.orange).textSelection(.enabled)
        }
        if draft.baseline != script {
            Text(model.localizedString("適用済みの設定が変更されています。下書きを破棄すると最新の設定を読み込めます。"))
                .font(.caption).foregroundColor(.secondary)
        }
        if let logs = model.sceneScriptLogs[path]?[script.id], !logs.isEmpty {
            DisclosureGroup("console.log") {
                ScrollView {
                    Text(logs).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 120)
            }
            .disclosureGroupStyle(ScriptDisclosureStyle())
        }
        Text(model.localizedString("ファイル・通信・外部コマンドは使えません。実行制限を超えたスクリプトは停止し、理由を表示します。"))
            .font(.caption).foregroundColor(.secondary)
        DisclosureGroup(model.localizedString("APIの使い方")) {
            Text("""
            function update(ctx) {
              return ctx.targets.map(layer => ({
                id: layer.id,
                values: { offsetY: wave(ctx.phase) * 0.05 }
              }));
            }

            ctx: targets, params, canvas, loopSeconds
            inputs: time, phase, timeOfDay, cursor, cursorActive
            values: offsetX, offsetY, rotation, scale, opacity,
                    brightness, saturation, warmth
            appearance: isVisible, blendMode, parallaxDepth,
                        depthStrength, depthAutoMotion, cursorMask
            helpers: wave, clamp, lerp, smoothstep, random, hash,
                     noise, noise2, fbm2, hsv, ease, curve,
                     fract, mod, mapRange, pingPong, triangle, pulse
            namespaces: vec, path, color
            """)
            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
        .disclosureGroupStyle(ScriptDisclosureStyle())
    }

    private func textBinding(_ script: SceneScript, _ key: WritableKeyPath<SceneScript, String>) -> Binding<String> {
        Binding(get: { editor.draft(for: script, path: path).script[keyPath: key] }, set: { text in
            editor.edit(script, path: path) { $0.script[keyPath: key] = text }
        })
    }

    private func boolBinding(_ script: SceneScript, _ key: WritableKeyPath<SceneScript, Bool>) -> Binding<Bool> {
        Binding(get: { editor.draft(for: script, path: path).script[keyPath: key] }, set: { value in
            editor.edit(script, path: path) { $0.script[keyPath: key] = value }
        })
    }
}

private struct ScriptDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

private struct FlowLayoutTargets: View {
    let layers: [SceneLayer]
    let selected: [UUID]
    let title: String
    let toggle: (UUID) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), alignment: .leading)], alignment: .leading) {
                ForEach(layers) { layer in
                    Toggle(layer.name, isOn: Binding(get: { selected.contains(layer.id) }, set: { _ in toggle(layer.id) }))
                        .toggleStyle(.checkbox)
                }
            }
        }
    }
}

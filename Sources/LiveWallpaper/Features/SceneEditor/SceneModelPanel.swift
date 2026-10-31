import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension SceneEditorView {
    func chooseSceneLayerModel(path: String) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = ["gltf", "glb"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        Task {
            guard let id = await model.addSceneModelLayer(from: url, path: path),
                  isStillEditing
            else {
                return
            }
            selectSceneLayer(id)
        }
    }

    /// The turn, lean and depth of an imported model, its shadow and its animation.
    @ViewBuilder
    func sceneModelControls(path: String, layer: SceneLayer, placement: SceneModelPlacement) -> some View {
        let rig = layer.model?.skeleton.flatMap { model.sceneDocumentsByPath[path]?.rigs[$0] }
        VStack(alignment: .leading, spacing: 8) {
            sceneModelSlider(model.localizedString("向き"), value: placement.turn, range: -180 ... 180, unit: "°") { value in
                updateSceneModelLayer(path: path, layerID: layer.id) { $0.modelPlacement?.turn = value }
            }
            sceneModelSlider(model.localizedString("傾き"), value: placement.tilt, range: -90 ... 90, unit: "°") { value in
                updateSceneModelLayer(path: path, layerID: layer.id) { $0.modelPlacement?.tilt = value }
            }
            sceneModelSlider(model.localizedString("手前へ"), value: placement.depth, range: -1000 ... 1000, unit: "px") { value in
                updateSceneModelLayer(path: path, layerID: layer.id) { $0.modelPlacement?.depth = value }
            }
            HStack(spacing: 12) {
                Text(model.localizedString("影を落とす"))
                    .frame(width: SceneInspectorMetrics.labelWidth, alignment: .leading)
                Spacer(minLength: 0)
                Toggle(model.localizedString("影を落とす"), isOn: Binding(
                    get: { layer.castsShadow ?? true },
                    set: { on in updateSceneModelLayer(path: path, layerID: layer.id) { $0.castsShadow = on } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            if let rig, let rigID = layer.model?.skeleton, !rig.clips.isEmpty {
                HStack(spacing: 12) {
                    Text(model.localizedString("アニメーション"))
                        .frame(width: SceneInspectorMetrics.labelWidth, alignment: .leading)
                    Spacer(minLength: 0)
                    Picker(model.localizedString("アニメーション"), selection: Binding<Int?>(
                        get: { rig.playback.first?.clip },
                        set: { clip in
                            updateSceneRig(path: path, rigID: rigID) { rig in
                                let rate = rig.playback.first?.rate ?? 1
                                rig.playback = clip.map { [SceneSkeleton.Playback(clip: $0, rate: rate)] } ?? []
                            }
                        }
                    )) {
                        Text(model.localizedString("止める")).tag(Int?.none)
                        ForEach(rig.clips.indices, id: \.self) { index in
                            Text(rig.clips[index].name).tag(Int?.some(index))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: SceneInspectorMetrics.menuMaxWidth)
                }
                if let playback = rig.playback.first {
                    sceneModelSlider(model.localizedString("再生の速さ"), value: playback.rate, range: 0.1 ... 3, unit: "×", digits: 2) { value in
                        updateSceneRig(path: path, rigID: rigID) { $0.playback[0].rate = value }
                    }
                    let clip = rig.clips[playback.clip]
                    let seconds = Double(clip.frameCount) / clip.framesPerSecond / playback.rate
                    settingsFootnote(String(
                        format: model.localizedString("1回 %.1f 秒。ループの長さで割り切れないと、ロック画面などの書き出しでつなぎ目がずれます。"),
                        locale: model.appLocale, seconds
                    ))
                }
            }
        }
    }

    private func sceneModelSlider(
        _ title: String, value: Double, range: ClosedRange<Double>, unit: String, digits: Int = 0,
        set: @escaping (Double) -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: SceneInspectorMetrics.labelWidth, alignment: .leading)
            Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) }, set: set), in: range)
                .accessibilityLabel(title)
            SceneNumberField(title: title, value: value, factor: 1, unit: unit, range: range, fractionDigits: digits, onCommit: set)
        }
    }

    private func updateSceneModelLayer(path: String, layerID: UUID, _ change: (inout SceneLayer) -> Void) {
        guard var document = model.sceneDocumentsByPath[path],
              let index = document.layers.firstIndex(where: { $0.id == layerID }),
              !document.layers[index].isLocked
        else {
            return
        }
        change(&document.layers[index])
        model.updateScene(document, path: path)
    }

    private func updateSceneRig(path: String, rigID: UUID, _ change: (inout SceneSkeleton) -> Void) {
        guard var document = model.sceneDocumentsByPath[path], var rig = document.rigs[rigID] else {
            return
        }
        change(&rig)
        document.rigs[rigID] = rig
        model.updateScene(document, path: path, coalescing: false)
    }
}

/// How the scene's imported models are seen and lit: the view, light from all round,
/// up to four lights and a floor for their shadows.
struct SceneModelStagePanel: View {
    @ObservedObject var model: WallpaperModel
    let path: String

    var body: some View {
        if let document = model.sceneDocumentsByPath[path], let stage = document.modelStage {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    slider("画角", stage.fieldOfView, 0 ... 90, unit: "°") { value in update { $0.fieldOfView = value } }
                    note(stage.fieldOfView < 0.5
                        ? "0° では遠近なし(平行投影)で表示します。"
                        : "大きいほど遠近が強くなります。画像レイヤーの見え方は変わりません。")
                    slider("視点の左右", stage.orbitAzimuth, -90 ... 90, unit: "°") { value in update { $0.orbitAzimuth = value } }
                    slider("視点の上下", stage.orbitElevation, -60 ... 60, unit: "°") { value in update { $0.orbitElevation = value } }
                    colorRow("空からの光", stage.skyColor) { color in update { $0.skyColor = color } }
                    colorRow("地面からの照り返し", stage.groundColor) { color in update { $0.groundColor = color } }
                    Divider()
                    ForEach(Array(stage.lights.enumerated()), id: \.element.id) { index, light in
                        lightEditor(index: index, light: light)
                        Divider()
                    }
                    Button(model.localizedString("光を追加")) {
                        update { $0.lights.append(SceneModelStage.Light(azimuth: 45, elevation: 30)) }
                    }
                    .disabled(stage.lights.count >= SceneModelStage.maximumLights)
                    Divider()
                    floor(stage: stage, document: document)
                }
                .padding(.top, 8)
            } label: {
                Text(model.localizedString("3Dモデルの見え方")).font(.headline)
            }
        }
    }

    @ViewBuilder
    private func lightEditor(index: Int, light: SceneModelStage.Light) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Picker(model.localizedString("光の種類"), selection: Binding(
                    get: { light.kind },
                    set: { kind in setLight(index) { $0.kind = kind } }
                )) {
                    Text(model.localizedString("平行光(太陽)")).tag(SceneModelStage.Light.Kind.directional)
                    Text(model.localizedString("点光源")).tag(SceneModelStage.Light.Kind.point)
                    Text(model.localizedString("スポットライト")).tag(SceneModelStage.Light.Kind.spot)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: SceneInspectorMetrics.menuMaxWidth)
                ColorPicker(model.localizedString("光の色"), selection: colorBinding(light.color) { color in
                    setLight(index) { $0.color = color }
                }, supportsOpacity: false)
                .labelsHidden()
                Spacer(minLength: 0)
                Button {
                    update { $0.lights.remove(at: index) }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help(model.localizedString("この光を削除"))
                .accessibilityLabel(model.localizedString("この光を削除"))
            }
            slider("強さ", light.intensity, 0 ... 10, unit: "", digits: 1) { value in setLight(index) { $0.intensity = value } }
            if light.kind != .point {
                slider("光の向き(左右)", light.azimuth, -180 ... 180, unit: "°") { value in setLight(index) { $0.azimuth = value } }
                slider("光の向き(高さ)", light.elevation, -90 ... 90, unit: "°") { value in setLight(index) { $0.elevation = value } }
            }
            if light.kind != .directional {
                slider("位置(左右)", light.position[0] * 100, -50 ... 150, unit: "%") { value in setLight(index) { $0.position[0] = value / 100 } }
                slider("位置(上下)", light.position[1] * 100, -50 ... 150, unit: "%") { value in setLight(index) { $0.position[1] = value / 100 } }
                slider("位置(手前)", light.position[2], -2000 ... 4000, unit: "px") { value in setLight(index) { $0.position[2] = value } }
                slider("届く距離", light.range, 0.1 ... 5, unit: "", digits: 2) { value in setLight(index) { $0.range = value } }
            }
            if light.kind == .spot {
                slider("広がり", light.coneAngle, 1 ... 89, unit: "°") { value in setLight(index) { $0.coneAngle = value } }
            }
            if light.kind == .point {
                note("点光源は影を落としません。")
            } else {
                Toggle(model.localizedString("影を落とす"), isOn: Binding(
                    get: { light.castsShadow }, set: { on in setLight(index) { $0.castsShadow = on } }
                ))
            }
        }
    }

    @ViewBuilder
    private func floor(stage: SceneModelStage, document: SceneDocument) -> some View {
        Toggle(model.localizedString("影を受ける床"), isOn: Binding(
            get: { stage.floor != nil },
            set: { on in
                update { stage in
                    stage.floor = on ? SceneModelStage.Floor(height: Self.footHeight(document) ?? 0.85) : nil
                }
            }
        ))
        note("見えない床で、モデルの影だけを下の絵に落とします。")
        if let floor = stage.floor {
            slider("床の高さ", floor.height * 100, 0 ... 100, unit: "%") { value in update { $0.floor?.height = value / 100 } }
            slider("影の濃さ", floor.opacity * 100, 0 ... 100, unit: "%") { value in update { $0.floor?.opacity = value / 100 } }
        }
    }

    /// The lowest imported model's lowest point, as a canvas fraction from the top, so the
    /// floor starts under its feet.
    private static func footHeight(_ document: SceneDocument) -> Double? {
        document.layers.compactMap { layer -> Double? in
            guard layer.isVisible, let placement = layer.modelPlacement else { return nil }
            let scale = layer.transform.scaleY ?? layer.transform.scale
            return 0.5 + layer.transform.offsetY + placement.size[1] * scale / 2 / Double(document.canvasHeight)
        }.max().map { min(max($0, 0), 1) }
    }

    private func colorRow(_ key: String, _ color: [Double], set: @escaping ([Double]) -> Void) -> some View {
        HStack(spacing: 12) {
            Text(model.localizedString(key)).frame(width: SceneInspectorMetrics.labelWidth, alignment: .leading)
            Spacer(minLength: 0)
            ColorPicker(model.localizedString(key), selection: colorBinding(color, set: set), supportsOpacity: false)
                .labelsHidden()
        }
    }

    /// The stage keeps linear colour; the picker shows sRGB.
    private func colorBinding(_ color: [Double], set: @escaping ([Double]) -> Void) -> Binding<Color> {
        Binding(
            get: {
                let c = color.map(Self.encode)
                return Color(.sRGB, red: c[0], green: c[1], blue: c[2])
            },
            set: { picked in
                guard let rgb = NSColor(picked).usingColorSpace(.sRGB) else { return }
                set([rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Self.decode(Double($0)) })
            }
        )
    }

    private static func decode(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func encode(_ c: Double) -> Double {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(max(c, 0), 1 / 2.4) - 0.055
    }

    private func note(_ key: String) -> some View {
        SceneHintText(text: model.localizedString(key))
    }

    private func slider(
        _ key: String, _ value: Double, _ range: ClosedRange<Double>, unit: String, digits: Int = 0,
        set: @escaping (Double) -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Text(model.localizedString(key)).frame(width: SceneInspectorMetrics.labelWidth, alignment: .leading)
            Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) }, set: set), in: range)
                .accessibilityLabel(model.localizedString(key))
            SceneNumberField(
                title: model.localizedString(key), value: value, factor: 1, unit: unit, range: range, fractionDigits: digits, onCommit: set
            )
        }
    }

    private func setLight(_ index: Int, _ change: (inout SceneModelStage.Light) -> Void) {
        update { stage in
            guard stage.lights.indices.contains(index) else { return }
            change(&stage.lights[index])
        }
    }

    private func update(_ change: (inout SceneModelStage) -> Void) {
        guard var document = model.sceneDocumentsByPath[path], var stage = document.modelStage else { return }
        change(&stage)
        document.modelStage = stage
        model.updateScene(document, path: path)
    }
}

import SwiftUI

extension SettingsView {
    func sceneParticleName(_ preset: SceneParticlePreset) -> String {
        switch preset {
        case .snow: model.localizedString("雪")
        case .rain: model.localizedString("雨")
        case .petals: model.localizedString("花びら")
        case .fireflies: model.localizedString("ホタル")
        case .dust: model.localizedString("舞う塵")
        case .embers: model.localizedString("火の粉")
        case .bubbles: model.localizedString("泡")
        case .stars: model.localizedString("星のまたたき")
        }
    }

    /// The "+" under the layer list: an image file, or particles of a kind.
    func sceneAddLayerMenu(path: String) -> some View {
        Menu {
            Button(model.localizedString("画像…")) {
                chooseSceneLayerImage(path: path)
            }
            Section(model.localizedString("粒子")) {
                ForEach(SceneParticlePreset.allCases, id: \.self) { preset in
                    Button(sceneParticleName(preset)) {
                        if let id = model.addSceneParticleLayer(preset, name: sceneParticleName(preset), path: path) {
                            selectSceneLayer(id)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(model.localizedString("レイヤーを追加"))
        .accessibilityLabel(model.localizedString("レイヤーを追加"))
    }

    @ViewBuilder
    func sceneParticleControls(path: String, layer: SceneLayer, particles: SceneParticles) -> some View {
        let labelWidth: CGFloat = 132
        let loopSeconds = model.sceneDocumentsByPath[path]?.loopSeconds ?? 20

        HStack(spacing: 12) {
            Text(model.localizedString("種類"))
                .frame(width: labelWidth, alignment: .leading)
            Spacer(minLength: 0)
            Picker(
                model.localizedString("種類"),
                selection: Binding(
                    get: { particles.preset },
                    set: { preset in
                        guard var document = model.sceneDocumentsByPath[path],
                              let index = document.layers.firstIndex(where: { $0.id == layer.id })
                        else {
                            return
                        }
                        // A new kind takes that kind's look; the area and pattern stay.
                        var fresh = SceneParticles(preset: preset)
                        fresh.maskFile = particles.maskFile
                        fresh.seed = particles.seed
                        fresh.cursorMode = particles.cursorMode
                        document.layers[index].particles = fresh
                        document.layers[index].blendMode = preset.isAdditive ? .add : .normal
                        model.updateScene(document, path: path)
                    }
                )
            ) {
                ForEach(SceneParticlePreset.allCases, id: \.self) { preset in
                    Text(sceneParticleName(preset)).tag(preset)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }

        sceneParticleSlider(
            title: model.localizedString("数"),
            value: Binding(
                get: { Double(particles.count) },
                set: { value in updateSceneParticles(path: path, layerID: layer.id) { $0.count = Int(value.rounded()) } }
            ),
            range: Double(SceneParticles.countRange.lowerBound) ... Double(SceneParticles.countRange.upperBound),
            valueText: "\(particles.count)",
            labelWidth: labelWidth
        )
        sceneParticleSlider(
            title: model.localizedString("大きさ"),
            value: sceneParticleBinding(path: path, layerID: layer.id, particles: particles, \.size),
            range: 0 ... 1,
            valueText: "\(Int((particles.size * 100).rounded()))%",
            labelWidth: labelWidth
        )

        if particles.preset.travels {
            HStack(spacing: 12) {
                Text(model.localizedString("速さ"))
                    .frame(width: labelWidth, alignment: .leading)
                Stepper(
                    value: sceneParticleBinding(path: path, layerID: layer.id, particles: particles, \.cycles),
                    in: SceneEffect.cyclesRange
                ) {
                    Text(String(
                        format: model.localizedString("ループ %1$d 秒の間に %2$d 回"), locale: model.appLocale,
                        loopSeconds, particles.cycles
                    ))
                    .font(.caption.monospacedDigit())
                }
                .accessibilityLabel(model.localizedString("速さ"))
            }
            HStack(spacing: 12) {
                Text(model.localizedString("向き"))
                    .frame(width: labelWidth, alignment: .leading)
                Slider(
                    value: sceneParticleBinding(path: path, layerID: layer.id, particles: particles, \.direction),
                    in: 0 ... 359
                )
                .accessibilityLabel(model.localizedString("向き"))
                Text("\(Int(particles.direction))°")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
            sceneParticleSlider(
                title: model.localizedString("揺れ幅"),
                value: sceneParticleBinding(path: path, layerID: layer.id, particles: particles, \.sway),
                range: 0 ... 1,
                valueText: "\(Int((particles.sway * 100).rounded()))%",
                labelWidth: labelWidth
            )
        }

        HStack(spacing: 12) {
            Text(model.localizedString("色"))
                .frame(width: labelWidth, alignment: .leading)
            Spacer(minLength: 0)
            ColorPicker(
                model.localizedString("色"),
                selection: Binding(
                    get: { Color(nsColor: particles.color.nsColor) },
                    set: { color in
                        updateSceneParticles(path: path, layerID: layer.id) { $0.color = RGBAColor(NSColor(color)) }
                    }
                ),
                supportsOpacity: true
            )
            .labelsHidden()
        }

        HStack(spacing: 12) {
            Text(model.localizedString("カーソル"))
                .frame(width: labelWidth, alignment: .leading)
            Spacer(minLength: 0)
            Picker(
                model.localizedString("カーソル"),
                selection: sceneParticleBinding(path: path, layerID: layer.id, particles: particles, \.cursorMode)
            ) {
                Text(model.localizedString("反応しない")).tag(SceneParticleCursorMode.none)
                Text(model.localizedString("カーソルを避ける")).tag(SceneParticleCursorMode.repel)
                Text(model.localizedString("カーソルに寄ってくる")).tag(SceneParticleCursorMode.attract)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }

        HStack(spacing: 12) {
            Text(model.localizedString("範囲"))
                .frame(width: labelWidth, alignment: .leading)
            Text(model.localizedString(particles.maskFile == nil ? "画面全体" : "塗った範囲だけ"))
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
        HStack(spacing: 8) {
            Button(model.localizedString(particles.maskFile == nil ? "範囲を塗る" : "塗り直す")) {
                beginSceneParticlePainting(path: path, layer: layer, particles: particles)
            }
            if particles.maskFile != nil {
                Button(model.localizedString("全体に戻す")) {
                    endSceneEditorTool()
                    model.setScenePaintFile(nil, kind: .mask, effectID: layer.id, layerID: layer.id, path: path)
                }
            }
        }
        .padding(.leading, labelWidth + 12)

        Divider()
    }

    private func sceneParticleSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        valueText: String,
        labelWidth: CGFloat
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: labelWidth, alignment: .leading)
            Slider(value: value, in: range)
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
            Text(valueText)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
    }

    private func beginSceneParticlePainting(path: String, layer: SceneLayer, particles: SceneParticles) {
        guard let document = model.sceneDocumentsByPath[path] else {
            return
        }
        sceneMaskPainter.onCommit = { [model] target, fileName, _ in
            model.setScenePaintFile(
                fileName, kind: target.kind, effectID: target.effectID, layerID: target.layerID, path: target.path
            )
        }
        sceneMaskPainter.onError = { [model] error in
            model.sceneErrorMessage = error.localizedDescription
        }
        sceneMaskPainter.tool = .paint
        sceneMaskPainter.begin(
            SceneMaskPainter.Target(path: path, layerID: layer.id, effectID: layer.id, kind: .mask),
            existingFile: particles.maskFile,
            layerPixelSize: CGSize(width: document.canvasWidth, height: document.canvasHeight)
        )
        sceneEditorTool = .paint(effectID: layer.id, kind: .mask)
    }

    private func sceneParticleBinding<Value>(
        path: String,
        layerID: UUID,
        particles: SceneParticles,
        _ keyPath: WritableKeyPath<SceneParticles, Value>
    ) -> Binding<Value> {
        Binding(
            get: { particles[keyPath: keyPath] },
            set: { newValue in
                updateSceneParticles(path: path, layerID: layerID) { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    private func updateSceneParticles(path: String, layerID: UUID, _ change: (inout SceneParticles) -> Void) {
        guard var document = model.sceneDocumentsByPath[path],
              let index = document.layers.firstIndex(where: { $0.id == layerID }),
              var particles = document.layers[index].particles
        else {
            return
        }
        change(&particles)
        document.layers[index].particles = particles
        model.updateScene(document, path: path)
    }
}

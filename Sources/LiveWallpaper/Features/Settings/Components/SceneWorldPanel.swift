import SwiftUI

/// Settings of the whole scene rather than a layer: background, dynamic range, glow, camera shake and parallax.
struct SceneWorldPanel: View {
    @ObservedObject var model: WallpaperModel
    let path: String

    var body: some View {
        if let document = model.sceneDocumentsByPath[path] {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    ColorPicker(model.localizedString("背景色"), selection: Binding(
                        get: {
                            let c = document.backgroundColor ?? [0, 0, 0]
                            return Color(.sRGB, red: c[0], green: c[1], blue: c[2])
                        },
                        set: { color in
                            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                            update { $0.backgroundColor = [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)] }
                        }
                    ), supportsOpacity: false)
                    Toggle(model.localizedString("明るさの幅を広げる(HDR)"), isOn: Binding(
                        get: { document.highDynamicRange }, set: { on in update { $0.highDynamicRange = on } }
                    ))
                    note("白より明るい色を最後まで保ちます。使う作品は、描画の負荷が少し上がります。")
                    bloom(document)
                    shake(document)
                    parallax(document)
                }
                .padding(.top, 8)
            } label: {
                Text(model.localizedString("シーン全体")).font(.headline)
            }
        }
    }

    private func bloom(_ document: SceneDocument) -> some View {
        // A glow imported with the scene is not this one's to replace.
        let importedFinishing = document.finishing != nil && document.bloom == nil
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(model.localizedString("グロー(光のにじみ)"), isOn: Binding(
                get: { document.bloom != nil },
                set: { on in
                    update {
                        $0.bloom = on ? SceneBloom() : nil
                        $0.finishing = $0.bloom?.graph
                    }
                }
            ))
            .disabled(importedFinishing)
            if importedFinishing {
                note("この作品は、取り込み時の仕上げ処理を使っています。")
            }
            if let bloom = document.bloom {
                slider("強さ", bloom.strength, SceneBloom.strengthRange) { value in setBloom { $0.strength = value } }
                slider("しきい値", bloom.threshold, SceneBloom.thresholdRange) { value in setBloom { $0.threshold = value } }
                slider("広がり", bloom.radius, SceneBloom.radiusRange) { value in setBloom { $0.radius = value } }
            }
        }
    }

    private func shake(_ document: SceneDocument) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(model.localizedString("カメラの揺れ"), isOn: Binding(
                get: { document.cameraShake != nil },
                set: { on in update { $0.cameraShake = on ? SceneCameraShake(speed: 1, amplitude: 0.5, roughness: 1) : nil } }
            ))
            if let shake = document.cameraShake {
                slider("揺れの速さ", shake.speed, 0 ... 5) { value in update { $0.cameraShake?.speed = value } }
                slider("揺れの大きさ", shake.amplitude, 0 ... 5) { value in update { $0.cameraShake?.amplitude = value } }
                slider("揺れの荒さ", shake.roughness, 0 ... 3) { value in update { $0.cameraShake?.roughness = value } }
            }
        }
    }

    private func parallax(_ document: SceneDocument) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(model.localizedString("視差の動きを細かく決める"), isOn: Binding(
                get: { document.parallaxTravel != nil || document.parallaxResponse != nil },
                set: { on in
                    update {
                        $0.parallaxTravel = on ? 0.05 : nil
                        $0.parallaxResponse = on ? 8.3 : nil
                    }
                }
            ))
            if document.parallaxTravel != nil || document.parallaxResponse != nil {
                slider("視差の移動量", document.parallaxTravel ?? 0.05, 0 ... 0.3) { value in update { $0.parallaxTravel = value } }
                slider("視差の追従の速さ", document.parallaxResponse ?? 8.3, 0.5 ... 30) { value in update { $0.parallaxResponse = value } }
            }
        }
    }

    private func note(_ key: String) -> some View {
        Text(model.localizedString(key)).font(.caption).foregroundColor(.secondary)
    }

    private func slider(_ key: String, _ value: Double, _ range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 12) {
            Text(model.localizedString(key)).frame(width: 132, alignment: .leading)
            Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) }, set: set), in: range)
                .accessibilityLabel(model.localizedString(key))
            Text(String(format: "%.2f", locale: model.appLocale, value))
                .font(.caption.monospacedDigit()).foregroundColor(.secondary).frame(width: 44, alignment: .trailing)
        }
    }

    private func setBloom(_ change: (inout SceneBloom) -> Void) {
        update { document in
            guard var bloom = document.bloom else { return }
            change(&bloom)
            document.bloom = bloom
            document.finishing = bloom.graph
        }
    }

    private func update(_ change: (inout SceneDocument) -> Void) {
        guard var document = model.sceneDocumentsByPath[path] else { return }
        change(&document)
        model.updateScene(document, path: path)
    }
}

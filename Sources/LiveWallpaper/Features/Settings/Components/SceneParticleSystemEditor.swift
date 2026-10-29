import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Every setting of a simulated particle layer. A child system opens in place of
/// its parent, with a trail back up.
struct SceneParticleSystemEditor: View {
    let model: WallpaperModel
    let path: String
    @Binding var system: SceneParticleSystem
    @State private var childPath: [Int] = []

    var body: some View {
        // Undo can take away a child that is open; show the deepest one still there.
        let openPath = validPrefix(childPath)
        VStack(alignment: .leading, spacing: 8) {
            if !openPath.isEmpty {
                breadcrumb(openPath)
            }
            ParticleSystemForm(
                model: model,
                path: path,
                system: binding(at: openPath),
                isRoot: openPath.isEmpty,
                openChild: { childPath = openPath + [$0] }
            )
            .id(openPath)
        }
    }

    private func breadcrumb(_ openPath: [Int]) -> some View {
        HStack(spacing: 4) {
            Button {
                childPath = Array(openPath.dropLast())
            } label: {
                Image(systemName: "chevron.backward")
            }
            .buttonStyle(.borderless)
            .help(model.localizedString("親の粒子に戻る"))
            .accessibilityLabel(model.localizedString("親の粒子に戻る"))

            Button(model.localizedString("粒子")) {
                childPath = []
            }
            .buttonStyle(.link)
            ForEach(Array(openPath.enumerated()), id: \.offset) { depth, index in
                Image(systemName: "chevron.forward")
                    .font(.caption)
                    .foregroundColor(.secondary)
                let title = String(
                    format: model.localizedString("子粒子 %d"), locale: model.appLocale, index + 1
                )
                if depth == openPath.count - 1 {
                    Text(title)
                } else {
                    Button(title) {
                        childPath = Array(openPath.prefix(depth + 1))
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private func validPrefix(_ path: [Int]) -> [Int] {
        var current = system
        var valid: [Int] = []
        for index in path {
            guard current.children.indices.contains(index) else {
                break
            }
            current = current.children[index].system.value
            valid.append(index)
        }
        return valid
    }

    private func binding(at path: [Int]) -> Binding<SceneParticleSystem> {
        path.reduce($system) { parent, index in
            let fallback = parent.wrappedValue.children[index].system.value
            return Binding(
                get: {
                    let children = parent.wrappedValue.children
                    return children.indices.contains(index) ? children[index].system.value : fallback
                },
                set: { newValue in
                    guard parent.wrappedValue.children.indices.contains(index) else {
                        return
                    }
                    parent.wrappedValue.children[index].system = .init(newValue)
                }
            )
        }
    }
}

// MARK: - One system

private typealias PSystem = SceneParticleSystem

private struct ParticleSystemForm: View {
    let model: WallpaperModel
    let path: String
    @Binding var system: SceneParticleSystem
    let isRoot: Bool
    let openChild: (Int) -> Void

    private func t(_ key: String) -> String {
        model.localizedString(key)
    }

    private func numbered(_ key: String, _ index: Int) -> String {
        String(format: t(key), locale: model.appLocale, index + 1)
    }

    private var locale: Locale {
        model.appLocale
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup(t("全体")) {
                generalSection.padding(.top, 6).frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup(String(format: t("発生源(%d)"), locale: locale, system.emitters.count)) {
                emittersSection.padding(.top, 6).frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup(t("生まれたときの値")) {
                initialSection.padding(.top, 6).frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup(String(format: t("動き(%d)"), locale: locale, system.behaviors.count)) {
                behaviorsSection.padding(.top, 6).frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup(t("描き方")) {
                rendererSection.padding(.top, 6).frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup(String(format: t("制御点(%d)"), locale: locale, system.controlPoints.count)) {
                controlPointsSection.padding(.top, 6).frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup(String(format: t("子粒子(%d)"), locale: locale, system.children.count)) {
                childrenSection.padding(.top, 6).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: General

    @ViewBuilder
    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ParticleRow(t("同時に出せる数の上限")) {
                IntField(title: t("同時に出せる数の上限"), value: $system.maxCount, locale: locale)
            }
            ParticleRow(t("最初に進めておく秒数")) {
                NumberField(title: t("最初に進めておく秒数"), value: $system.startTime, locale: locale)
            }
            ParticleRow(t("画像")) {
                imagePicker(file: $system.textureFile, emptyText: t("なし(白い四角)")) {
                    system.sheet = nil
                }
            }
            optionalGroup(t("コマ割り"), $system.sheet, make: PSystem.Sheet(columns: 1, rows: 1, frameCount: 1)) { sheet in
                ParticleRow(t("列")) { IntField(title: t("列"), value: sheet.columns, locale: locale) }
                ParticleRow(t("行")) { IntField(title: t("行"), value: sheet.rows, locale: locale) }
                ParticleRow(t("コマ数")) { IntField(title: t("コマ数"), value: sheet.frameCount, locale: locale) }
                ParticleRow(t("コマの選び方")) {
                    Picker(t("コマの選び方"), selection: sheet.mode) {
                        Text(t("生まれたときに1つ選ぶ")).tag(PSystem.Sheet.Mode.random)
                        Text(t("寿命に合わせて順に流す")).tag(PSystem.Sheet.Mode.sequence)
                    }
                    .labelsHidden().fixedSize()
                }
                ParticleRow(t("一生で流す回数")) { NumberField(title: t("一生で流す回数"), value: sheet.speed, locale: locale) }
            }
            ParticleRow(t("合成")) {
                Picker(t("合成"), selection: $system.blend) {
                    Text(t("不透明")).tag(PSystem.Blend.opaque)
                    Text(t("透明度を使う")).tag(PSystem.Blend.alpha)
                    Text(t("加算")).tag(PSystem.Blend.add)
                }
                .labelsHidden().fixedSize()
            }
            ParticleRow(t("明るさ")) {
                NumberField(title: t("明るさ"), value: $system.brightness, locale: locale)
            }
            optionalGroup(t("背景を歪ませる"), $system.refraction, make: PSystem.Refraction()) { refraction in
                ParticleRow(t("法線画像")) {
                    imagePicker(file: refraction.normalFile, emptyText: t("なし")) {}
                }
                ParticleRow(t("歪みの量")) { NumberField(title: t("歪みの量"), value: refraction.amount, locale: locale) }
            }
            optionalGroup(t("輪郭をくっきりさせる"), $system.cutout, make: PSystem.Cutout()) { cutout in
                ParticleRow(t("透明度の下端")) { NumberField(title: t("透明度の下端"), value: cutout.start, locale: locale) }
                ParticleRow(t("透明度の上端")) { NumberField(title: t("透明度の上端"), value: cutout.end, locale: locale) }
                ParticleRow(t("不透明度")) { NumberField(title: t("不透明度"), value: cutout.opacity, locale: locale) }
            }
        }
    }

    // MARK: Emitters

    @ViewBuilder
    private var emittersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(system.emitters.indices, id: \.self) { index in
                let emitter = element($system.emitters, index)
                ListItemHeader(
                    title: numbered("発生源 %d", index),
                    model: model,
                    onRemove: { remove(index, from: $system.emitters) }
                )
                VStack(alignment: .leading, spacing: 6) {
                    emitterEditor(emitter)
                }
                .padding(.leading, 12)
            }
            Menu(t("発生源を追加")) {
                Button(t("箱")) {
                    system.emitters.append(PSystem.Emitter(shape: .box, distanceMax: [256, 256, 0], directions: [1, 1, 0], rate: 10))
                }
                Button(t("球")) {
                    system.emitters.append(PSystem.Emitter(shape: .sphere, distanceMax: [256, 0, 0], directions: [1, 1, 0], rate: 10))
                }
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private func emitterEditor(_ emitter: Binding<PSystem.Emitter>) -> some View {
        ParticleRow(t("形")) {
            Picker(t("形"), selection: emitter.shape) {
                Text(t("箱")).tag(PSystem.Emitter.Shape.box)
                Text(t("球")).tag(PSystem.Emitter.Shape.sphere)
            }
            .labelsHidden().fixedSize()
        }
        vectorRow(t("中心"), emitter.origin)
        if emitter.wrappedValue.shape == .box {
            vectorRow(t("中心からの距離(最小)"), emitter.distanceMin)
            vectorRow(t("中心からの距離(最大)"), emitter.distanceMax)
        } else {
            ParticleRow(t("内側の半径")) {
                NumberField(title: t("内側の半径"), value: component(emitter.distanceMin, 0), locale: locale)
            }
            ParticleRow(t("外側の半径")) {
                NumberField(title: t("外側の半径"), value: component(emitter.distanceMax, 0), locale: locale)
            }
        }
        vectorRow(t("軸ごとの伸ばし"), emitter.directions)
        vectorRow(t("向きの制限"), emitter.sign, help: t("0 は両側、正の値は正の側だけ、負の値は負の側だけに出します。"))
        ParticleRow(t("1秒に出す数")) { NumberField(title: t("1秒に出す数"), value: emitter.rate, locale: locale) }
        ParticleRow(t("始めに一度に出す数")) { IntField(title: t("始めに一度に出す数"), value: emitter.burst, locale: locale) }
        rangeRow(t("中心から離れる速さ"), emitter.speed)
        ParticleRow(t("始めるまでの秒数")) { NumberField(title: t("始めるまでの秒数"), value: emitter.delay, locale: locale) }
        optionalGroup(t("決まった秒数で止める"), emitter.duration, make: 5) { duration in
            ParticleRow(t("出し続ける秒数")) { NumberField(title: t("出し続ける秒数"), value: duration, locale: locale) }
        }
        optionalGroup(t("休みを挟んで出す"), emitter.periodic, make: PSystem.Periodic()) { periodic in
            rangeRow(t("出す秒数"), periodic.duration)
            rangeRow(t("休む秒数"), periodic.pause)
            optionalGroup(t("1回に出す数を制限"), periodic.maxPerBurst, make: 10) { limit in
                ParticleRow(t("1回に出す数")) { IntField(title: t("1回に出す数"), value: limit, locale: locale) }
            }
        }
    }

    // MARK: Initial values

    @ViewBuilder
    private var initialSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            let initial = $system.initial
            rangeRow(t("寿命(秒)"), initial.lifetime)
            rangeRow(t("大きさ"), initial.size)
            rangeRow(t("不透明度"), initial.alpha)
            ParticleRow(t("色の選び方")) {
                Picker(
                    t("色の選び方"),
                    selection: Binding(
                        get: { !system.initial.colorChoices.isEmpty },
                        set: { usesChoices in
                            system.initial.colorChoices = usesChoices ? [system.initial.colorMin, system.initial.colorMax] : []
                        }
                    )
                ) {
                    Text(t("2色の間から選ぶ")).tag(false)
                    Text(t("候補から1つ選ぶ")).tag(true)
                }
                .labelsHidden().fixedSize()
            }
            if system.initial.colorChoices.isEmpty {
                ParticleRow(t("色の範囲")) {
                    ParticleColorWell(title: t("色の範囲"), rgb: initial.colorMin)
                    Text("〜").foregroundColor(.secondary)
                    ParticleColorWell(title: t("色の範囲"), rgb: initial.colorMax)
                }
            } else {
                ParticleRow(t("色の候補")) {
                    ForEach(system.initial.colorChoices.indices, id: \.self) { index in
                        ParticleColorWell(title: numbered("色 %d", index), rgb: element(initial.colorChoices, index))
                            .contextMenu {
                                Button(t("削除")) { remove(index, from: initial.colorChoices) }
                                    .disabled(system.initial.colorChoices.count <= 1)
                            }
                    }
                    Button {
                        system.initial.colorChoices.append([1, 1, 1])
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help(t("色を追加"))
                    .accessibilityLabel(t("色を追加"))
                }
                settingsNote(t("色を右クリックすると削除できます。"))
            }
            vectorRangeRow(t("速度"), initial.velocity)
            vectorRangeRow(t("回転(ラジアン)"), initial.rotation)
            vectorRangeRow(t("回転の速さ"), initial.angularVelocity)
            settingsNote(t("回転の速さは「回転の動き」があるときだけ効きます。"))

            optionalGroup(t("揺らぎながら進む速さを足す"), initial.turbulentVelocity, make: PSystem.TurbulentVelocity()) { value in
                rangeRow(t("速さ"), value.speed)
                rangeRow(t("位相"), value.phase)
                ParticleRow(t("変化の速さ")) { NumberField(title: t("変化の速さ"), value: value.timeScale, locale: locale) }
                ParticleRow(t("向きの振れ幅")) { NumberField(title: t("向きの振れ幅"), value: value.scale, locale: locale) }
                ParticleRow(t("向きのずらし")) { NumberField(title: t("向きのずらし"), value: value.offset, locale: locale) }
                vectorRow(t("基準の向き"), value.forward)
                vectorRow(t("回す軸"), value.axis)
            }
            optionalGroup(t("生まれる位置を揺らぎでずらす"), initial.positionOffset, make: PSystem.PositionOffset()) { value in
                ParticleRow(t("距離")) { NumberField(title: t("距離"), value: value.distance, locale: locale) }
                ParticleRow(t("場所による変化の細かさ")) {
                    NumberField(title: t("場所による変化の細かさ"), value: value.scale, locale: locale)
                }
                ParticleRow(t("変化の速さ")) { NumberField(title: t("変化の速さ"), value: value.timeScale, locale: locale) }
                vectorRow(t("軸ごとの伸ばし"), value.directions)
                vectorRow(t("向きの制限"), value.sign, help: t("0 は両側、正の値は正の側だけ、負の値は負の側だけに出します。"))
            }
            optionalGroup(
                t("制御点に沿って順に生まれる"),
                initial.sequence,
                make: PSystem.Sequence(path: .between(start: 0, end: 1, arc: 0.3, arcDirection: [0, 1, 0]))
            ) { value in
                sequenceEditor(value)
            }

            Text(t("生まれたときに値を写す"))
                .font(.subheadline)
                .padding(.top, 4)
            ForEach(system.initial.remaps.indices, id: \.self) { index in
                ListItemHeader(
                    title: numbered("写像 %d", index),
                    model: model,
                    onRemove: { remove(index, from: initial.remaps) }
                )
                VStack(alignment: .leading, spacing: 6) {
                    remapEditor(element(initial.remaps, index), showsRamp: false)
                }
                .padding(.leading, 12)
            }
            Button(t("写像を追加")) {
                system.initial.remaps.append(PSystem.Remap())
            }
        }
    }

    @ViewBuilder
    private func sequenceEditor(_ sequence: Binding<PSystem.Sequence>) -> some View {
        ParticleRow(t("道すじ")) {
            Picker(
                t("道すじ"),
                selection: Binding(
                    get: {
                        if case .between = sequence.wrappedValue.path { return 0 }
                        return 1
                    },
                    set: { kind in
                        sequence.wrappedValue.path = kind == 0
                            ? .between(start: 0, end: 1, arc: 0.3, arcDirection: [0, 1, 0])
                            : .around(controlPoint: 0, axis: [0, 0, 1], speedMin: [0, 0, 0], speedMax: [0, 0, 0])
                    }
                )
            ) {
                Text(t("2つの制御点の間")).tag(0)
                Text(t("制御点のまわり")).tag(1)
            }
            .labelsHidden().fixedSize()
        }
        let pathBinding = sequence.path
        switch sequence.wrappedValue.path {
        case .between: betweenEditor(pathBinding)
        case .around: aroundEditor(pathBinding)
        }
        ParticleRow(t("一巡で生まれる数")) { NumberField(title: t("一巡で生まれる数"), value: sequence.count, locale: locale) }
        ParticleRow(t("使う区間")) {
            NumberField(title: t("使う区間"), value: sequence.boundsMin, locale: locale)
            Text("〜").foregroundColor(.secondary)
            NumberField(title: t("使う区間"), value: sequence.boundsMax, locale: locale)
        }
        ParticleRow(t("折り返す")) {
            Toggle(t("折り返す"), isOn: sequence.mirrors).labelsHidden()
        }
    }

    @ViewBuilder
    private func betweenEditor(_ pathBinding: Binding<PSystem.Sequence.Path>) -> some View {
        ParticleRow(t("始点の制御点")) {
            IntField(title: t("始点の制御点"), value: part(pathBinding, {
                if case let .between(start, _, _, _) = $0 { return start }
                return nil
            }, { path, value in
                if case let .between(_, end, arc, direction) = path { return .between(start: value, end: end, arc: arc, arcDirection: direction) }
                return nil
            }), locale: locale)
        }
        ParticleRow(t("終点の制御点")) {
            IntField(title: t("終点の制御点"), value: part(pathBinding, {
                if case let .between(_, end, _, _) = $0 { return end }
                return nil
            }, { path, value in
                if case let .between(start, _, arc, direction) = path { return .between(start: start, end: value, arc: arc, arcDirection: direction) }
                return nil
            }), locale: locale)
        }
        ParticleRow(t("曲げ")) {
            NumberField(title: t("曲げ"), value: part(pathBinding, {
                if case let .between(_, _, arc, _) = $0 { return arc }
                return nil
            }, { path, value in
                if case let .between(start, end, _, direction) = path { return .between(start: start, end: end, arc: value, arcDirection: direction) }
                return nil
            }), locale: locale)
        }
        vectorRow(t("曲げる向き"), part(pathBinding, {
            if case let .between(_, _, _, direction) = $0 { return direction }
            return nil
        }, { path, value in
            if case let .between(start, end, arc, _) = path { return .between(start: start, end: end, arc: arc, arcDirection: value) }
            return nil
        }))
    }

    @ViewBuilder
    private func aroundEditor(_ pathBinding: Binding<PSystem.Sequence.Path>) -> some View {
        ParticleRow(t("制御点")) {
            IntField(title: t("制御点"), value: part(pathBinding, {
                if case let .around(point, _, _, _) = $0 { return point }
                return nil
            }, { path, value in
                if case let .around(_, axis, low, high) = path { return .around(controlPoint: value, axis: axis, speedMin: low, speedMax: high) }
                return nil
            }), locale: locale)
        }
        vectorRow(t("回す軸"), part(pathBinding, {
            if case let .around(_, axis, _, _) = $0 { return axis }
            return nil
        }, { path, value in
            if case let .around(point, _, low, high) = path { return .around(controlPoint: point, axis: value, speedMin: low, speedMax: high) }
            return nil
        }))
        vectorRow(t("速さ(最小)"), part(pathBinding, {
            if case let .around(_, _, low, _) = $0 { return low }
            return nil
        }, { path, value in
            if case let .around(point, axis, _, high) = path { return .around(controlPoint: point, axis: axis, speedMin: value, speedMax: high) }
            return nil
        }))
        vectorRow(t("速さ(最大)"), part(pathBinding, {
            if case let .around(_, _, _, high) = $0 { return high }
            return nil
        }, { path, value in
            if case let .around(point, axis, low, _) = path { return .around(controlPoint: point, axis: axis, speedMin: low, speedMax: value) }
            return nil
        }))
    }

    @ViewBuilder
    private func remapEditor(_ remap: Binding<PSystem.Remap>, showsRamp: Bool) -> some View {
        ParticleRow(t("元にする値")) {
            Picker(t("元にする値"), selection: remap.input) {
                Text(t("寿命の経過")).tag(PSystem.Remap.Input.lifetimeFraction)
                Text(t("粒子の経過時間")).tag(PSystem.Remap.Input.particleSystemTime)
                Text(t("再生時間")).tag(PSystem.Remap.Input.runtime)
                Text(t("時刻")).tag(PSystem.Remap.Input.timeOfDay)
                Text(t("速さ")).tag(PSystem.Remap.Input.speed)
                Text(t("制御点までの距離")).tag(PSystem.Remap.Input.distanceToControlPoint)
            }
            .labelsHidden().fixedSize()
        }
        if remap.wrappedValue.input == .distanceToControlPoint {
            ParticleRow(t("制御点")) { IntField(title: t("制御点"), value: remap.controlPoint, locale: locale) }
        }
        ParticleRow(t("元の値の範囲")) {
            NumberField(title: t("元の値の範囲"), value: remap.inputMin, locale: locale)
            Text("〜").foregroundColor(.secondary)
            NumberField(title: t("元の値の範囲"), value: remap.inputMax, locale: locale)
            Toggle(t("範囲の外は端に揃える"), isOn: remap.clampsInput)
        }
        ParticleRow(t("変形")) {
            Picker(t("変形"), selection: remap.transform) {
                Text(t("なし")).tag(PSystem.Remap.Transform.none)
                Text(t("正弦波")).tag(PSystem.Remap.Transform.sine)
                Text(t("矩形波")).tag(PSystem.Remap.Transform.square)
                Text(t("のこぎり波")).tag(PSystem.Remap.Transform.saw)
                Text(t("三角波")).tag(PSystem.Remap.Transform.triangle)
                Text(t("ノイズ")).tag(PSystem.Remap.Transform.noise)
                Text(t("フラクタルノイズ")).tag(PSystem.Remap.Transform.fractalNoise)
            }
            .labelsHidden().fixedSize()
            if remap.wrappedValue.transform != .none {
                Text(t("倍率")).foregroundColor(.secondary)
                NumberField(title: t("倍率"), value: remap.transformScale, locale: locale)
            }
        }
        ParticleRow(t("変える値")) {
            Picker(t("変える値"), selection: remap.output) {
                Text(t("大きさ")).tag(PSystem.Remap.Output.size)
                Text(t("不透明度")).tag(PSystem.Remap.Output.opacity)
                Text(t("色")).tag(PSystem.Remap.Output.color)
                Text(t("速度")).tag(PSystem.Remap.Output.velocity)
                Text(t("速さ")).tag(PSystem.Remap.Output.speed)
                Text(t("回転")).tag(PSystem.Remap.Output.rotation)
                Text(t("回転の速さ")).tag(PSystem.Remap.Output.angularVelocity)
            }
            .labelsHidden().fixedSize()
            Picker(t("変え方"), selection: remap.operation) {
                Text(t("置き換える")).tag(PSystem.Remap.Operation.assign)
                Text(t("掛ける")).tag(PSystem.Remap.Operation.multiply)
                Text(t("足す")).tag(PSystem.Remap.Operation.add)
                Text(t("引く")).tag(PSystem.Remap.Operation.subtract)
            }
            .labelsHidden().fixedSize()
        }
        vectorRow(t("写した先の値(最小)"), remap.outputMin)
        vectorRow(t("写した先の値(最大)"), remap.outputMax)
        if showsRamp {
            rampEditor(remap.ramp)
        }
    }

    // MARK: Behaviours

    @ViewBuilder
    private var behaviorsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingsNote(t("上から順に毎フレーム適用します。"))
            ForEach(system.behaviors.indices, id: \.self) { index in
                let behavior = element($system.behaviors, index)
                ListItemHeader(
                    title: "\(index + 1). \(behaviorName(behavior.wrappedValue))",
                    model: model,
                    onMoveUp: index > 0 ? { system.behaviors.swapAt(index, index - 1) } : nil,
                    onMoveDown: index < system.behaviors.count - 1 ? { system.behaviors.swapAt(index, index + 1) } : nil,
                    onRemove: { remove(index, from: $system.behaviors) }
                )
                VStack(alignment: .leading, spacing: 6) {
                    behaviorEditor(behavior)
                }
                .padding(.leading, 12)
            }
            Menu(t("動きを追加")) {
                ForEach(Self.newBehaviors.indices, id: \.self) { index in
                    Button(behaviorName(Self.newBehaviors[index])) {
                        system.behaviors.append(Self.newBehaviors[index])
                    }
                }
            }
            .fixedSize()
        }
    }

    /// What each kind starts at when added: the values a scene file leaves out.
    private static let newBehaviors: [PSystem.Behavior] = [
        .movement(gravity: [0, 0, 0], drag: 0),
        .angularMovement(force: [0, 0, 0], drag: 0),
        .alphaFade(fadeIn: 0.5, fadeOut: 0.5),
        .sizeChange(PSystem.Change(startValue: 1, endValue: 0)),
        .alphaChange(PSystem.Change(startValue: 1, endValue: 0)),
        .colorChange(PSystem.ColorChange(startValue: [1, 1, 1], endValue: [0, 0, 0])),
        .oscillatePosition(PSystem.Oscillation(frequency: PSystem.Range(1, 5), amplitude: PSystem.Range(0, 10), phase: PSystem.Range(0, 2 * .pi))),
        .oscillateAlpha(PSystem.Oscillation(frequency: PSystem.Range(1, 10), amplitude: PSystem.Range(0, 1))),
        .oscillateSize(PSystem.Oscillation(frequency: PSystem.Range(1, 10), amplitude: PSystem.Range(0.8, 1.2))),
        .attract(controlPoint: 0, scale: 100, threshold: 300),
        .turbulence(PSystem.Turbulence()),
        .vortex(PSystem.Vortex()),
        .capVelocity(maxSpeed: 100, ramp: nil),
        .reduceMovement(PSystem.ReduceMovement()),
        .flock(PSystem.Flock()),
        .remap(PSystem.Remap())
    ]

    private func behaviorName(_ behavior: PSystem.Behavior) -> String {
        switch behavior {
        case .movement: t("移動(重力・抵抗)")
        case .angularMovement: t("回転の動き")
        case .alphaFade: t("フェードイン・アウト")
        case .sizeChange: t("大きさの変化")
        case .alphaChange: t("不透明度の変化")
        case .colorChange: t("色の変化")
        case .oscillatePosition: t("位置の揺れ")
        case .attract: t("制御点への引き寄せ")
        case .maintainDistance: t("制御点間の距離を保つ")
        case .oscillateAlpha: t("不透明度の揺れ")
        case .oscillateSize: t("大きさの揺れ")
        case .turbulence: t("乱流")
        case .vortex: t("渦")
        case .capVelocity: t("速さの上限")
        case .reduceMovement: t("制御点の近くで減速")
        case .flock: t("群れ")
        case .remap: t("値の写像")
        }
    }

    @ViewBuilder
    private func behaviorEditor(_ behavior: Binding<PSystem.Behavior>) -> some View {
        switch behavior.wrappedValue {
        case .movement: movementEditor(behavior)
        case .angularMovement: angularMovementEditor(behavior)
        case .attract: attractEditor(behavior)
        case .turbulence: turbulenceEditor(behavior)
        case .vortex: vortexEditor(behavior)
        case .capVelocity: capVelocityEditor(behavior)
        case .reduceMovement: reduceMovementEditor(behavior)
        case .flock: flockEditor(behavior)
        default: lookBehaviorEditor(behavior)
        }
    }

    @ViewBuilder
    private func lookBehaviorEditor(_ behavior: Binding<PSystem.Behavior>) -> some View {
        switch behavior.wrappedValue {
        case .alphaFade: alphaFadeEditor(behavior)
        case .sizeChange: sizeChangeEditor(behavior)
        case .alphaChange: alphaChangeEditor(behavior)
        case .colorChange: colorChangeEditor(behavior)
        case .oscillatePosition: oscillatePositionEditor(behavior)
        case .oscillateAlpha: oscillateAlphaEditor(behavior)
        case .oscillateSize: oscillateSizeEditor(behavior)
        case .remap: remapBehaviorEditor(behavior)
        default: EmptyView()
        }
    }

    @ViewBuilder
    private func movementEditor(_ behavior: Binding<PSystem.Behavior>) -> some View {
        vectorRow(t("重力"), part(behavior, {
            if case let .movement(gravity, _) = $0 { return gravity }
            return nil
        }, { current, value in
            if case let .movement(_, drag) = current { return .movement(gravity: value, drag: drag) }
            return nil
        }))
        ParticleRow(t("抵抗")) {
            NumberField(title: t("抵抗"), value: part(behavior, {
                if case let .movement(_, drag) = $0 { return drag }
                return nil
            }, { current, value in
                if case let .movement(gravity, _) = current { return .movement(gravity: gravity, drag: value) }
                return nil
            }), locale: locale)
        }
    }

    @ViewBuilder
    private func angularMovementEditor(_ behavior: Binding<PSystem.Behavior>) -> some View {
        vectorRow(t("回転の加速"), part(behavior, {
            if case let .angularMovement(force, _) = $0 { return force }
            return nil
        }, { current, value in
            if case let .angularMovement(_, drag) = current { return .angularMovement(force: value, drag: drag) }
            return nil
        }))
        ParticleRow(t("抵抗")) {
            NumberField(title: t("抵抗"), value: part(behavior, {
                if case let .angularMovement(_, drag) = $0 { return drag }
                return nil
            }, { current, value in
                if case let .angularMovement(force, _) = current { return .angularMovement(force: force, drag: value) }
                return nil
            }), locale: locale)
        }
    }

    @ViewBuilder
    private func alphaFadeEditor(_ behavior: Binding<PSystem.Behavior>) -> some View {
        ParticleRow(t("フェードインの終わり")) {
            NumberField(title: t("フェードインの終わり"), value: part(behavior, {
                if case let .alphaFade(fadeIn, _) = $0 { return fadeIn }
                return nil
            }, { current, value in
                if case let .alphaFade(_, fadeOut) = current { return .alphaFade(fadeIn: value, fadeOut: fadeOut) }
                return nil
            }), locale: locale)
        }
        ParticleRow(t("フェードアウトの始め")) {
            NumberField(title: t("フェードアウトの始め"), value: part(behavior, {
                if case let .alphaFade(_, fadeOut) = $0 { return fadeOut }
                return nil
            }, { current, value in
                if case let .alphaFade(fadeIn, _) = current { return .alphaFade(fadeIn: fadeIn, fadeOut: value) }
                return nil
            }), locale: locale)
        }
        settingsNote(t("寿命を 0〜1 とした割合です。"))
    }

    @ViewBuilder
    private func sizeChangeEditor(_ behavior: Binding<PSystem.Behavior>) -> some View {
        changeEditor(part(behavior, {
            if case let .sizeChange(change) = $0 { return change }
            return nil
        }, { _, value in .sizeChange(value) }))
    }

    @ViewBuilder
    private func alphaChangeEditor(_ behavior: Binding<PSystem.Behavior>) -> some View {
        changeEditor(part(behavior, {
            if case let .alphaChange(change) = $0 { return change }
            return nil
        }, { _, value in .alphaChange(value) }))
    }

    @ViewBuilder
    private func colorChangeEditor(_ behavior: Binding<PSystem.Behavior>) -> some View {
        let change = part(behavior, {
            if case let .colorChange(change) = $0 { return change }
            return nil
        }, { _, value in PSystem.Behavior.colorChange(value) })
        lifeSpanRow(start: change.startTime, end: change.endTime)
        ParticleRow(t("始めの色と終わりの色")) {
            ParticleColorWell(title: t("始めの色"), rgb: change.startValue)
            Text("→").foregroundColor(.secondary)
            ParticleColorWell(title: t("終わりの色"), rgb: change.endValue)
        }
    }

    @ViewBuilder
    private func oscillatePositionEditor(_ behavior: Binding<PSystem.Behavior>) -> some View {
        oscillationEditor(part(behavior, {
            if case let .oscillatePosition(value) = $0 { return value }
            return nil
        }, { _, value in .oscillatePosition(value) }), showsMask: true)
    }

    @ViewBuilder
    private func oscillateAlphaEditor(_ behavior: Binding<PSystem.Behavior>) -> some View {
        oscillationEditor(part(behavior, {
            if case let .oscillateAlpha(value) = $0 { return value }
            return nil
        }, { _, value in .oscillateAlpha(value) }), showsMask: false)
    }

    @ViewBuilder
    private func oscillateSizeEditor(_ behavior: Binding<PSystem.Behavior>) -> some View {
        oscillationEditor(part(behavior, {
            if case let .oscillateSize(value) = $0 { return value }
            return nil
        }, { _, value in .oscillateSize(value) }), showsMask: false)
    }

    @ViewBuilder
    private func attractEditor(_ behavior: Binding<PSystem.Behavior>) -> some View {
        ParticleRow(t("制御点")) {
            IntField(title: t("制御点"), value: part(behavior, {
                if case let .attract(point, _, _) = $0 { return point }
                return nil
            }, { current, value in
                if case let .attract(_, scale, threshold) = current { return .attract(controlPoint: value, scale: scale, threshold: threshold) }
                return nil
            }), locale: locale)
        }
        ParticleRow(t("強さ")) {
            NumberField(title: t("強さ"), value: part(behavior, {
                if case let .attract(_, scale, _) = $0 { return scale }
                return nil
            }, { current, value in
                if case let .attract(point, _, threshold) = current { return .attract(controlPoint: point, scale: value, threshold: threshold) }
                return nil
            }), locale: locale)
        }
        ParticleRow(t("届く距離")) {
            NumberField(title: t("届く距離"), value: part(behavior, {
                if case let .attract(_, _, threshold) = $0 { return threshold }
                return nil
            }, { current, value in
                if case let .attract(point, scale, _) = current { return .attract(controlPoint: point, scale: scale, threshold: value) }
                return nil
            }), locale: locale)
        }
        settingsNote(t("強さを負にすると遠ざけます。"))
    }

    @ViewBuilder
    private func turbulenceEditor(_ behavior: Binding<PSystem.Behavior>) -> some View {
        let value = part(behavior, {
            if case let .turbulence(value) = $0 { return value }
            return nil
        }, { _, value in PSystem.Behavior.turbulence(value) })
        rangeRow(t("速さ"), value.speed)
        ParticleRow(t("変化の速さ")) { NumberField(title: t("変化の速さ"), value: value.timeScale, locale: locale) }
        ParticleRow(t("場所による変化の細かさ")) {
            NumberField(title: t("場所による変化の細かさ"), value: value.scale, locale: locale)
        }
        vectorRow(t("効かせる軸"), value.mask)
        rangeRow(t("位相"), value.phase)
        rampEditor(value.ramp)
    }

    @ViewBuilder
    private func vortexEditor(_ behavior: Binding<PSystem.Behavior>) -> some View {
        let value = part(behavior, {
            if case let .vortex(value) = $0 { return value }
            return nil
        }, { _, value in PSystem.Behavior.vortex(value) })
        ParticleRow(t("制御点")) { IntField(title: t("制御点"), value: value.controlPoint, locale: locale) }
        vectorRow(t("中心のずらし"), value.offset)
        vectorRow(t("回す軸"), value.axis)
        ParticleRow(t("内側の距離と速さ")) {
            NumberField(title: t("内側の距離"), value: value.distanceInner, locale: locale)
            NumberField(title: t("内側の速さ"), value: value.speedInner, locale: locale)
        }
        ParticleRow(t("外側の距離と速さ")) {
            NumberField(title: t("外側の距離"), value: value.distanceOuter, locale: locale)
            NumberField(title: t("外側の速さ"), value: value.speedOuter, locale: locale)
        }
        rampEditor(value.ramp)
    }

    @ViewBuilder
    private func capVelocityEditor(_ behavior: Binding<PSystem.Behavior>) -> some View {
        ParticleRow(t("最大の速さ")) {
            NumberField(title: t("最大の速さ"), value: part(behavior, {
                if case let .capVelocity(speed, _) = $0 { return speed }
                return nil
            }, { current, value in
                if case let .capVelocity(_, ramp) = current { return .capVelocity(maxSpeed: value, ramp: ramp) }
                return nil
            }), locale: locale)
        }
        rampEditor(part(behavior, {
            if case let .capVelocity(_, ramp) = $0 { return ramp }
            return nil
        }, { current, value in
            if case let .capVelocity(speed, _) = current { return .capVelocity(maxSpeed: speed, ramp: value) }
            return nil
        }))
    }

    @ViewBuilder
    private func reduceMovementEditor(_ behavior: Binding<PSystem.Behavior>) -> some View {
        let value = part(behavior, {
            if case let .reduceMovement(value) = $0 { return value }
            return nil
        }, { _, value in PSystem.Behavior.reduceMovement(value) })
        ParticleRow(t("制御点")) { IntField(title: t("制御点"), value: value.controlPoint, locale: locale) }
        ParticleRow(t("内側の距離と減速")) {
            NumberField(title: t("内側の距離"), value: value.distanceInner, locale: locale)
            NumberField(title: t("内側の減速"), value: value.reductionInner, locale: locale)
        }
        ParticleRow(t("外側の距離と減速")) {
            NumberField(title: t("外側の距離"), value: value.distanceOuter, locale: locale)
            NumberField(title: t("外側の減速"), value: value.reductionOuter, locale: locale)
        }
    }

    @ViewBuilder
    private func flockEditor(_ behavior: Binding<PSystem.Behavior>) -> some View {
        let value = part(behavior, {
            if case let .flock(value) = $0 { return value }
            return nil
        }, { _, value in PSystem.Behavior.flock(value) })
        ParticleRow(t("仲間とみなす距離")) {
            NumberField(title: t("仲間とみなす距離"), value: value.neighborThreshold, locale: locale)
        }
        ParticleRow(t("離れようとする距離")) {
            NumberField(title: t("離れようとする距離"), value: value.separationThreshold, locale: locale)
        }
        ParticleRow(t("離れる強さ")) { NumberField(title: t("離れる強さ"), value: value.separationFactor, locale: locale) }
        ParticleRow(t("集まる強さ")) { NumberField(title: t("集まる強さ"), value: value.cohesionFactor, locale: locale) }
        ParticleRow(t("向きを揃える強さ")) { NumberField(title: t("向きを揃える強さ"), value: value.alignmentFactor, locale: locale) }
        optionalGroup(t("速さを制限"), value.maxSpeed, make: 100) { speed in
            ParticleRow(t("最大の速さ")) { NumberField(title: t("最大の速さ"), value: speed, locale: locale) }
        }
    }

    @ViewBuilder
    private func remapBehaviorEditor(_ behavior: Binding<PSystem.Behavior>) -> some View {
        remapEditor(part(behavior, {
            if case let .remap(value) = $0 { return value }
            return nil
        }, { _, value in .remap(value) }), showsRamp: true)
    }

    @ViewBuilder
    private func changeEditor(_ change: Binding<PSystem.Change>) -> some View {
        lifeSpanRow(start: change.startTime, end: change.endTime)
        ParticleRow(t("始めの倍率と終わりの倍率")) {
            NumberField(title: t("始めの倍率"), value: change.startValue, locale: locale)
            Text("→").foregroundColor(.secondary)
            NumberField(title: t("終わりの倍率"), value: change.endValue, locale: locale)
        }
    }

    private func lifeSpanRow(start: Binding<Double>, end: Binding<Double>) -> some View {
        ParticleRow(t("変化する区間(寿命の割合)")) {
            NumberField(title: t("変化の始め"), value: start, locale: locale)
            Text("〜").foregroundColor(.secondary)
            NumberField(title: t("変化の終わり"), value: end, locale: locale)
        }
    }

    @ViewBuilder
    private func oscillationEditor(_ oscillation: Binding<PSystem.Oscillation>, showsMask: Bool) -> some View {
        rangeRow(t("周波数(ラジアン/秒)"), oscillation.frequency)
        rangeRow(showsMask ? t("振れ幅") : t("倍率の範囲"), oscillation.amplitude)
        rangeRow(t("位相"), oscillation.phase)
        if showsMask {
            vectorRow(t("効かせる軸"), oscillation.mask)
        }
        rampEditor(oscillation.ramp)
    }

    private func rampEditor(_ ramp: Binding<PSystem.Ramp?>) -> some View {
        optionalGroup(t("寿命の途中で効き始め・効き終わる"), ramp, make: PSystem.Ramp(inStart: 0, inEnd: 0.1, outStart: 0.9, outEnd: 1)) { ramp in
            ParticleRow(t("効き始め")) {
                NumberField(title: t("効き始め"), value: ramp.inStart, locale: locale)
                Text("〜").foregroundColor(.secondary)
                NumberField(title: t("効き始め"), value: ramp.inEnd, locale: locale)
            }
            ParticleRow(t("効き終わり")) {
                NumberField(title: t("効き終わり"), value: ramp.outStart, locale: locale)
                Text("〜").foregroundColor(.secondary)
                NumberField(title: t("効き終わり"), value: ramp.outEnd, locale: locale)
            }
        }
    }

    // MARK: Renderer

    @ViewBuilder
    private var rendererSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ParticleRow(t("形")) {
                Picker(
                    t("形"),
                    selection: Binding(
                        get: {
                            switch system.renderer {
                            case .sprite: 0
                            case .trail: 1
                            case .rope: 2
                            case .ropeTrail: 3
                            }
                        },
                        set: { kind in
                            system.renderer = switch kind {
                            case 1: .trail(length: 0.05, minLength: 0, maxLength: 10)
                            case 2: .rope
                            case 3: .ropeTrail(length: 1, segments: 16, fadesAlpha: false)
                            default: .sprite
                            }
                        }
                    )
                ) {
                    Text(t("点")).tag(0)
                    Text(t("進む向きに伸ばす")).tag(1)
                    Text(t("生まれた順につなぐ帯")).tag(2)
                    Text(t("通った跡の帯")).tag(3)
                }
                .labelsHidden().fixedSize()
            }
            let renderer = $system.renderer
            switch system.renderer {
            case .sprite, .rope:
                EmptyView()
            case .trail:
                ParticleRow(t("速さに掛ける長さ")) {
                    NumberField(title: t("速さに掛ける長さ"), value: part(renderer, {
                        if case let .trail(length, _, _) = $0 { return length }
                        return nil
                    }, { current, value in
                        if case let .trail(_, low, high) = current { return .trail(length: value, minLength: low, maxLength: high) }
                        return nil
                    }), locale: locale)
                }
                ParticleRow(t("長さの範囲(大きさの倍数)")) {
                    NumberField(title: t("最短"), value: part(renderer, {
                        if case let .trail(_, low, _) = $0 { return low }
                        return nil
                    }, { current, value in
                        if case let .trail(length, _, high) = current { return .trail(length: length, minLength: value, maxLength: high) }
                        return nil
                    }), locale: locale)
                    Text("〜").foregroundColor(.secondary)
                    NumberField(title: t("最長"), value: part(renderer, {
                        if case let .trail(_, _, high) = $0 { return high }
                        return nil
                    }, { current, value in
                        if case let .trail(length, low, _) = current { return .trail(length: length, minLength: low, maxLength: value) }
                        return nil
                    }), locale: locale)
                }
            case .ropeTrail:
                ParticleRow(t("跡を残す秒数")) {
                    NumberField(title: t("跡を残す秒数"), value: part(renderer, {
                        if case let .ropeTrail(length, _, _) = $0 { return length }
                        return nil
                    }, { current, value in
                        if case let .ropeTrail(_, segments, fades) = current { return .ropeTrail(length: value, segments: segments, fadesAlpha: fades) }
                        return nil
                    }), locale: locale)
                }
                ParticleRow(t("区切りの数")) {
                    IntField(title: t("区切りの数"), value: part(renderer, {
                        if case let .ropeTrail(_, segments, _) = $0 { return segments }
                        return nil
                    }, { current, value in
                        if case let .ropeTrail(length, _, fades) = current { return .ropeTrail(length: length, segments: value, fadesAlpha: fades) }
                        return nil
                    }), locale: locale)
                }
                ParticleRow(t("後ろほど薄くする")) {
                    Toggle(t("後ろほど薄くする"), isOn: part(renderer, {
                        if case let .ropeTrail(_, _, fades) = $0 { return fades }
                        return nil
                    }, { current, value in
                        if case let .ropeTrail(length, segments, _) = current { return .ropeTrail(length: length, segments: segments, fadesAlpha: value) }
                        return nil
                    }))
                    .labelsHidden()
                }
            }
        }
    }

    // MARK: Control points

    @ViewBuilder
    private var controlPointsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingsNote(t("引き寄せ・渦などの動きは、ここで置いた点を番号で指します。"))
            ForEach(system.controlPoints.indices, id: \.self) { index in
                let point = element($system.controlPoints, index)
                ListItemHeader(
                    title: String(format: t("制御点 %d"), locale: locale, point.wrappedValue.index),
                    model: model,
                    onRemove: { remove(index, from: $system.controlPoints) }
                )
                VStack(alignment: .leading, spacing: 6) {
                    ParticleRow(t("番号")) { IntField(title: t("番号"), value: point.index, locale: locale) }
                    ParticleRow(t("位置の基準")) {
                        Picker(t("位置の基準"), selection: point.anchor) {
                            Text(t("レイヤーの中心")).tag(PSystem.ControlPoint.Anchor.layer)
                            Text(t("カーソル")).tag(PSystem.ControlPoint.Anchor.pointer)
                            Text(t("画面の左下")).tag(PSystem.ControlPoint.Anchor.canvasCorner)
                            Text(t("使わない")).tag(PSystem.ControlPoint.Anchor.none)
                        }
                        .labelsHidden().fixedSize()
                    }
                    if point.wrappedValue.anchor != .pointer {
                        vectorRow(t("基準からの位置"), point.offset)
                    }
                }
                .padding(.leading, 12)
            }
            Button(t("制御点を追加")) {
                let next = (system.controlPoints.map(\.index).max() ?? -1) + 1
                system.controlPoints.append(PSystem.ControlPoint(index: next))
            }
        }
    }

    // MARK: Children

    @ViewBuilder
    private var childrenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(system.children.indices, id: \.self) { index in
                let child = element($system.children, index)
                ListItemHeader(
                    title: numbered("子粒子 %d", index),
                    model: model,
                    onRemove: { remove(index, from: $system.children) }
                )
                VStack(alignment: .leading, spacing: 6) {
                    ParticleRow(t("出すきっかけ")) {
                        Picker(t("出すきっかけ"), selection: child.trigger) {
                            Text(t("最初から")).tag(PSystem.Child.Trigger.start)
                            Text(t("親が生まれたとき")).tag(PSystem.Child.Trigger.birth)
                            Text(t("親についていく")).tag(PSystem.Child.Trigger.follow)
                            Text(t("親が消えたとき")).tag(PSystem.Child.Trigger.death)
                        }
                        .labelsHidden().fixedSize()
                    }
                    vectorRow(t("位置のずらし"), child.origin)
                    vectorRow(t("倍率(位置・大きさ・速さ)"), child.scale)
                    ParticleRow(t("出す確率")) { NumberField(title: t("出す確率"), value: child.probability, locale: locale) }
                    Button(t("中身を編集…")) {
                        openChild(index)
                    }
                    .padding(.leading, ParticleRow<EmptyView>.labelWidth + 12)
                }
                .padding(.leading, 12)
            }
            Button(t("子粒子を追加")) {
                system.children.append(PSystem.Child(trigger: .death, system: .init(Self.newChild(textureFile: system.textureFile))))
            }
        }
    }

    /// A small puff, so a new child shows at once where its parent dies.
    private static func newChild(textureFile: String?) -> PSystem {
        var child = PSystem()
        child.maxCount = 200
        child.textureFile = textureFile
        child.emitters = [PSystem.Emitter(shape: .sphere, distanceMax: [8, 0, 0], directions: [1, 1, 0], burst: 8, speed: PSystem.Range(20, 60))]
        child.initial.lifetime = PSystem.Range(0.4, 0.8)
        child.initial.size = PSystem.Range(4, 10)
        child.behaviors = [.movement(gravity: [0, 0, 0], drag: 1), .alphaFade(fadeIn: 0, fadeOut: 0.3)]
        return child
    }

    // MARK: Building blocks

    private func settingsNote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func vectorRow(_ title: String, _ values: Binding<[Double]>, help: String? = nil) -> some View {
        ParticleRow(title) {
            VectorFields(title: title, values: values, locale: locale)
        }
        .help(help ?? "")
    }

    private func rangeRow(_ title: String, _ range: Binding<PSystem.Range>) -> some View {
        ParticleRow(title) {
            NumberField(title: title, value: range.min, locale: locale)
            Text("〜").foregroundColor(.secondary)
            NumberField(title: title, value: range.max, locale: locale)
            exponentField(title: title, value: range.exponent)
        }
    }

    private func vectorRangeRow(_ title: String, _ range: Binding<PSystem.VectorRange>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ParticleRow(title) {
                Text(t("最小値")).foregroundColor(.secondary).lineLimit(1).frame(width: 64, alignment: .leading)
                VectorFields(title: title, values: range.min, locale: locale)
            }
            ParticleRow("") {
                Text(t("最大値")).foregroundColor(.secondary).lineLimit(1).frame(width: 64, alignment: .leading)
                VectorFields(title: title, values: range.max, locale: locale)
                exponentField(title: title, value: range.exponent)
            }
        }
    }

    private func exponentField(title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(t("偏り")).foregroundColor(.secondary)
            NumberField(title: "\(title) \(t("偏り"))", value: value, locale: locale, width: 44)
        }
        .help(t("1 で均等。大きいほど最小の側に寄り、1 より小さいと最大の側に寄ります。"))
    }

    private func imagePicker(file: Binding<String?>, emptyText: String, onReplace: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(file.wrappedValue == nil ? emptyText : t("あり"))
                .foregroundColor(.secondary)
            Button(t("選ぶ…")) {
                chooseImage { name in
                    file.wrappedValue = name
                    onReplace()
                }
            }
            if file.wrappedValue != nil {
                Button(t("外す")) {
                    file.wrappedValue = nil
                    onReplace()
                }
            }
        }
    }

    private func chooseImage(_ apply: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        Task {
            await model.importSceneParticleImage(from: url, path: path, apply: apply)
        }
    }

    /// A Toggle that adds or removes an optional part, and the part's fields while it is on.
    private func optionalGroup<Value, Content: View>(
        _ title: String,
        _ value: Binding<Value?>,
        make: Value,
        @ViewBuilder content: @escaping (Binding<Value>) -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ParticleRow(title) {
                Toggle(title, isOn: Binding(
                    get: { value.wrappedValue != nil },
                    set: { value.wrappedValue = $0 ? make : nil }
                ))
                .labelsHidden()
            }
            if let current = value.wrappedValue {
                VStack(alignment: .leading, spacing: 6) {
                    content(Binding(
                        get: { value.wrappedValue ?? current },
                        set: { value.wrappedValue = $0 }
                    ))
                }
                .padding(.leading, 12)
            }
        }
    }
}

/// A binding to one associated value of an enum case. Only made while `whole` is
/// that case; afterwards the getter keeps the last value and the setter does nothing.
private func part<Whole, Value>(
    _ whole: Binding<Whole>,
    _ get: @escaping (Whole) -> Value?,
    _ set: @escaping (Whole, Value) -> Whole?
) -> Binding<Value> {
    let initial = get(whole.wrappedValue)!
    return Binding(
        get: { get(whole.wrappedValue) ?? initial },
        set: { newValue in
            if let updated = set(whole.wrappedValue, newValue) {
                whole.wrappedValue = updated
            }
        }
    )
}

/// SwiftUI may still read a row's binding after its element was removed.
private func element<Element>(_ array: Binding<[Element]>, _ index: Int) -> Binding<Element> {
    let initial = array.wrappedValue[index]
    return Binding(
        get: { array.wrappedValue.indices.contains(index) ? array.wrappedValue[index] : initial },
        set: { newValue in
            if array.wrappedValue.indices.contains(index) {
                array.wrappedValue[index] = newValue
            }
        }
    )
}

private func remove<Element>(_ index: Int, from array: Binding<[Element]>) {
    if array.wrappedValue.indices.contains(index) {
        array.wrappedValue.remove(at: index)
    }
}

/// Scene files may store fewer than three components; editing one fills the rest with 0.
private func component(_ values: Binding<[Double]>, _ index: Int) -> Binding<Double> {
    Binding(
        get: { values.wrappedValue.indices.contains(index) ? values.wrappedValue[index] : 0 },
        set: { newValue in
            var updated = values.wrappedValue
            while updated.count <= index {
                updated.append(0)
            }
            updated[index] = newValue
            values.wrappedValue = updated
        }
    )
}

// MARK: - Controls

private struct ParticleRow<Content: View>: View {
    static var labelWidth: CGFloat {
        170
    }

    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: Self.labelWidth, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                content
            }
            Spacer(minLength: 0)
        }
    }
}

private struct NumberField: View {
    let title: String
    @Binding var value: Double
    let locale: Locale
    var width: CGFloat = 72

    var body: some View {
        TextField(
            title,
            value: $value,
            format: .number.precision(.fractionLength(0 ... 6)).grouping(.never).locale(locale)
        )
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .multilineTextAlignment(.trailing)
        .font(.caption.monospacedDigit())
        .frame(width: width)
    }
}

private struct IntField: View {
    let title: String
    @Binding var value: Int
    let locale: Locale

    var body: some View {
        TextField(title, value: $value, format: IntegerFormatStyle<Int>.number.grouping(.never).locale(locale))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .multilineTextAlignment(.trailing)
            .font(.caption.monospacedDigit())
            .frame(width: 72)
    }
}

private struct VectorFields: View {
    let title: String
    @Binding var values: [Double]
    let locale: Locale

    var body: some View {
        ForEach(0 ..< 3, id: \.self) { axis in
            let name = ["x", "y", "z"][axis]
            Text(name)
                .font(.caption)
                .foregroundColor(.secondary)
            NumberField(title: "\(title) \(name)", value: component($values, axis), locale: locale, width: 64)
        }
    }
}

/// RGB 0...1 in sRGB; a value past 1 shows as white and stays until the colour is picked.
private struct ParticleColorWell: View {
    let title: String
    @Binding var rgb: [Double]

    var body: some View {
        ColorPicker(
            title,
            selection: Binding(
                get: {
                    let value = rgb + Array(repeating: 1, count: max(0, 3 - rgb.count))
                    return Color(.sRGB, red: value[0], green: value[1], blue: value[2])
                },
                set: { color in
                    guard let srgb = NSColor(color).usingColorSpace(.sRGB) else {
                        return
                    }
                    rgb = [Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent)]
                }
            ),
            supportsOpacity: false
        )
        .labelsHidden()
    }
}

private struct ListItemHeader: View {
    let title: String
    let model: WallpaperModel
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .fontWeight(.medium)
            Spacer(minLength: 0)
            if onMoveUp != nil || onMoveDown != nil {
                Button {
                    onMoveUp?()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(onMoveUp == nil)
                .help(model.localizedString("上へ"))
                .accessibilityLabel(model.localizedString("上へ"))
                Button {
                    onMoveDown?()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(onMoveDown == nil)
                .help(model.localizedString("下へ"))
                .accessibilityLabel(model.localizedString("下へ"))
            }
            Button {
                onRemove()
            } label: {
                Image(systemName: "minus.circle")
            }
            .help(model.localizedString("削除"))
            .accessibilityLabel(model.localizedString("削除"))
            .accessibilityValue(title)
        }
        .buttonStyle(.borderless)
        .padding(.top, 4)
    }
}

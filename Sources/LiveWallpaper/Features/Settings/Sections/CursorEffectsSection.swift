import SwiftUI

extension SettingsView {
  var cursorEffectsSection: some View {
    Section(header: SettingsSectionHeader(title: model.localizedString("カーソルのエフェクト"))) {
      settingsFootnote(
        model.localizedString("動画の壁紙に、マウスカーソルの動きに合わせたエフェクトを重ねます。Web壁紙では使えません。")
      )

      toggleWithHelp(
        model.localizedString("マウスに合わせて動かす（視差効果）"),
        isOn: cursorEffectBinding(\.parallaxEnabled),
        helpTopic: .cursorParallax,
        helpText: model.localizedString(
          "マウスカーソルと逆の方向へ壁紙を少しずらして、奥行きがあるように見せます。ずらしても端が見えないよう、オンの間は壁紙を少し拡大して表示します。"
        )
      )
      if model.cursorEffects.parallaxEnabled {
        cursorEffectSubRows {
          cursorLevelRow(title: model.localizedString("強さ"), keyPath: \.parallaxStrength, labels: ("弱", "中", "強"))
          cursorEffectBlockedNote(model.cursorMotionBlockReason)
        }
      }

      toggleWithHelp(
        model.localizedString("スポットライト"),
        isOn: cursorEffectBinding(\.spotlightEnabled),
        helpTopic: .cursorSpotlight,
        helpText: model.localizedString(
          "カーソルの周りだけを元の明るさで表示し、それ以外を暗くします。カーソルがない画面は暗くしません。"
        )
      )
      if model.cursorEffects.spotlightEnabled {
        cursorEffectSubRows {
          cursorLevelRow(title: model.localizedString("大きさ"), keyPath: \.spotlightSize, labels: ("小", "中", "大"))
          cursorLevelRow(title: model.localizedString("暗さ"), keyPath: \.spotlightDarkness, labels: ("弱", "中", "強"))
          cursorEffectBlockedNote(model.cursorSpotlightBlockReason)
        }
      }

      toggleWithHelp(
        model.localizedString("カーソルの軌跡"),
        isOn: cursorEffectBinding(\.trailEnabled),
        helpTopic: .cursorTrail,
        helpText: model.localizedString(
          "カーソルを動かすと、その後ろに光の粒が流れて消えます。デスクトップが見えている場所でだけ表示されます。"
        )
      )
      if model.cursorEffects.trailEnabled {
        cursorEffectSubRows {
          Picker(model.localizedString("形"), selection: cursorEffectBinding(\.trailShape)) {
            Text(model.localizedString("光")).tag(CursorTrailShape.glow)
            Text(model.localizedString("キラキラ")).tag(CursorTrailShape.sparkle)
            Text(model.localizedString("泡")).tag(CursorTrailShape.bubble)
            Text(model.localizedString("雪")).tag(CursorTrailShape.snow)
          }
          .pickerStyle(.menu)
          cursorColorRows(color: \.trailColor, custom: \.trailCustomColor)
          cursorLevelRow(title: model.localizedString("量"), keyPath: \.trailAmount, labels: ("少", "中", "多"))
          cursorEffectBlockedNote(model.cursorMotionBlockReason)
        }
      }

      toggleWithHelp(
        model.localizedString("クリックの演出"),
        isOn: cursorEffectBinding(\.clickEnabled),
        helpTopic: .cursorClick,
        helpText: model.localizedString(
          "デスクトップをクリックした場所に、波紋が広がるか光の粒がはじけます。ほかのアプリやメニューバーでのクリックには反応しません。"
        )
      )
      if model.cursorEffects.clickEnabled {
        cursorEffectSubRows {
          Picker(model.localizedString("種類"), selection: cursorEffectBinding(\.clickStyle)) {
            Text(model.localizedString("波紋")).tag(CursorClickStyle.ripple)
            Text(model.localizedString("はじける")).tag(CursorClickStyle.burst)
          }
          .pickerStyle(.menu)
          cursorColorRows(color: \.clickColor, custom: \.clickCustomColor)
          cursorEffectBlockedNote(model.cursorMotionBlockReason)
        }
      }

      if model.cursorEffects.anyEnabled {
        toggleWithHelp(
          model.localizedString("デスクトップを使っているときだけ動かす"),
          isOn: cursorEffectBinding(\.onlyWhileDesktopActive),
          helpTopic: .cursorOnlyOnDesktop,
          helpText: model.localizedString(
            "ほかのアプリを使っている間は、マウスの監視ごとエフェクトを止めて負荷をなくします。デスクトップ（Finder）かこのアプリが前面にあるときだけ動きます。"
          )
        )
      }
    }
  }

  private func cursorEffectSubRows<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      content()
    }
    .padding(.leading, 20)
  }

  private func cursorLevelRow(
    title: String,
    keyPath: WritableKeyPath<CursorEffectsSettings, CursorEffectLevel>,
    labels: (String, String, String)
  ) -> some View {
    settingsMenuRow(
      title: title,
      options: [
        (model.localizedString(labels.0), CursorEffectLevel.low),
        (model.localizedString(labels.1), CursorEffectLevel.medium),
        (model.localizedString(labels.2), CursorEffectLevel.high)
      ],
      selection: cursorEffectBinding(keyPath)
    )
  }

  @ViewBuilder
  private func cursorEffectBlockedNote(_ reason: CursorEffectBlockReason?) -> some View {
    switch reason {
    case .webWallpaper:
      settingsFootnote(model.localizedString("Web壁紙の表示中は使えません。"), color: .orange)
    case .reduceMotion:
      settingsFootnote(
        model.localizedString("システムの「視差効果を減らす」が有効なため、オフになっています。"), color: .orange
      )
    case .battery:
      settingsFootnote(
        model.localizedString("バッテリー駆動中で再生の負荷を下げているため、オフになっています。"), color: .orange
      )
    case .lowPowerMode:
      settingsFootnote(model.localizedString("低電力モードのため、オフになっています。"), color: .orange)
    case .thermal:
      settingsFootnote(model.localizedString("Macの温度が高いため、オフになっています。"), color: .orange)
    case nil:
      EmptyView()
    }
  }

  private func cursorEffectBinding<T>(_ keyPath: WritableKeyPath<CursorEffectsSettings, T>) -> Binding<T> {
    Binding(
      get: { model.cursorEffects[keyPath: keyPath] },
      set: { newValue in
        var settings = model.cursorEffects
        settings[keyPath: keyPath] = newValue
        model.setCursorEffects(settings)
      }
    )
  }

  @ViewBuilder
  private func cursorColorRows(
    color: WritableKeyPath<CursorEffectsSettings, CursorEffectColor>,
    custom: WritableKeyPath<CursorEffectsSettings, RGBAColor>
  ) -> some View {
    Picker(model.localizedString("色"), selection: cursorEffectBinding(color)) {
      Text(model.localizedString("白")).tag(CursorEffectColor.white)
      Text(model.localizedString("アクセントカラー")).tag(CursorEffectColor.accent)
      Text(model.localizedString("虹色")).tag(CursorEffectColor.rainbow)
      Text(model.localizedString("カスタム")).tag(CursorEffectColor.custom)
    }
    .pickerStyle(.menu)
    if model.cursorEffects[keyPath: color] == .custom {
      ColorPicker(
        model.localizedString("カスタムの色"),
        selection: Binding(
          get: { Color(nsColor: model.cursorEffects[keyPath: custom].nsColor) },
          set: { newValue in
            var settings = model.cursorEffects
            settings[keyPath: custom] = RGBAColor(NSColor(newValue))
            model.setCursorEffects(settings)
          }
        ),
        supportsOpacity: false
      )
    }
  }
}

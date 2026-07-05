import AppKit
import SwiftUI

extension SettingsView {
  var displaySettingsSection: some View {
    Section(header: Label(model.localizedString("表示"), systemImage: "display.2")) {
      settingsInsetCard {
        VStack(alignment: .leading, spacing: 16) {
          displayChoicePicker(
            title: model.localizedString("壁紙の表示先"),
            options: [
              (model.localizedString("メインのみ"), DisplayMode.mainOnly),
              (model.localizedString("全ディスプレイ"), DisplayMode.allScreens)
            ],
            selection: displayModeBinding
          )

          displayChoicePicker(
            title: model.localizedString("動画のフィット"),
            options: [
              (model.localizedString("拡大"), VideoFitMode.fill),
              (model.localizedString("全体"), VideoFitMode.fit)
            ],
            selection: globalFitModeBinding
          )
        }
      }

      Toggle(isOn: desktopIconsVisibleBinding) {
        HStack(spacing: 6) {
          Text(model.localizedString("デスクトップのアイコンを表示"))
          helpIconButton(for: .desktopIcons)
        }
      }
      if expandedHelpTopics.contains(.desktopIcons) {
        settingsFootnote(
          model.localizedString(
            "System Settings の「デスクトップに項目を表示」と同じ設定です。OFF にすると Finder が再起動し、デスクトップ上のファイルとフォルダが非表示になります。"
          )
        )
      }
      if let message = model.desktopIconsFailureMessage {
        settingsFootnote(message, color: .orange)
      }

      settingsCalloutNote(
        systemImage: "info.circle",
        text: spaceSwitchingLimitationText()
      )

      Toggle(model.localizedString("再生の軽量モード（省電力）"), isOn: lightweightModeBinding)
      Toggle(model.localizedString("作業中は壁紙の再生を自動停止"), isOn: suspendWhenFullScreenBinding)

      if model.suspendWhenOtherAppFullScreen {
        suspendDetectionModeSection
      }

      advancedSettingsSection
    }
    .onAppear {
      model.refreshDesktopIconsVisibility()
    }
  }

  func spaceSwitchingLimitationText() -> String {
    model.localizedString(
      "macOS の Space（Mission Control）切り替え時、まれに隣接する Space に移動することがあります。アプリを開いている Space から何もない Space へ移る操作で発生しやすいです。同じ Space へ戻ると安定することがあります。"
    )
  }

  var suspendDetectionModeSection: some View {
    settingsInsetCard {
      VStack(alignment: .leading, spacing: 12) {
        displayChoicePicker(
          title: model.localizedString("停止判定"),
          options: [
            (model.localizedString("前面アプリ"), SuspendDetectionMode.frontmostAppPresence),
            (model.localizedString("画面を覆う時"), SuspendDetectionMode.preciseWindowCoverage)
          ],
          selection: suspendDetectionModeBinding,
          titleFont: .caption,
          titleColor: .secondary
        )

        settingsFootnote(suspendDetectionModeDescription())

        if shouldShowAccessibilityCoverageWarning {
          VStack(alignment: .leading, spacing: 6) {
            settingsFootnote(accessibilityCoverageWarningText(), color: .red)
            Button(model.localizedString("アクセシビリティ許可を開く")) {
              model.requestAccessibilityPermissionForCoverage()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
          }
        }

        Divider().opacity(0.35)

        suspendExclusionContent
      }
    }
  }

  func suspendDetectionModeDescription() -> String {
    switch model.suspendDetectionMode {
    case .frontmostAppPresence:
      return model.localizedString(
        "前面アプリのウィンドウが画面を覆う時に停止します。Screen Recording 権限がない場合は保守的な判定になります。"
      )
    case .preciseWindowCoverage:
      return model.localizedString("アクセシビリティ権限がある場合、前面ウィンドウが画面を大きく覆う時だけ停止します。判定できない時は安全側として停止します。")
    }
  }

  var shouldShowAccessibilityCoverageWarning: Bool {
    model.suspendWhenOtherAppFullScreen
      && model.suspendDetectionMode == .preciseWindowCoverage
      && !model.accessibilityTrustedForCoverage
  }

  func accessibilityCoverageWarningText() -> String {
    model.localizedString("精密な停止判定にはアクセシビリティ権限が必要です。許可されるまでは安全側として前面アプリがある画面を停止します。")
  }

  var suspendExclusionContent: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .center) {
        Text(model.localizedString("停止対象から除外するアプリ"))
          .font(.caption)
          .foregroundColor(.secondary)
        Spacer()
        Button(model.localizedString("アプリを選択して追加")) {
          selectAppForSuspendExclusion()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }

      if model.suspendExclusionBundleIDs.isEmpty {
        settingsFootnote(model.localizedString("除外アプリは未設定です"))
      } else {
        ScrollView(.vertical, showsIndicators: true) {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(model.suspendExclusionBundleIDs, id: \.self) { bundleID in
              suspendExclusionRow(for: bundleID)
            }
          }
        }
        .frame(maxHeight: 140)
      }
    }
  }

  func suspendExclusionRow(for bundleID: String) -> some View {
    let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    let appName = appURL.map { $0.deletingPathExtension().lastPathComponent } ?? bundleID
    let appIcon = appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }

    return HStack(spacing: 10) {
      if let icon = appIcon {
        Image(nsImage: icon)
          .resizable()
          .frame(width: 24, height: 24)
      }
      VStack(alignment: .leading, spacing: 1) {
        Text(appName)
          .lineLimit(1)
          .truncationMode(.tail)
        if appURL != nil {
          Text(bundleID)
            .font(.caption2)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Button(model.localizedString("削除"), role: .destructive) {
        model.removeSuspendExclusionBundleID(bundleID)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .tint(.red)
    }
    .padding(.vertical, 2)
  }

  func settingsInsetCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 10)
          .fill(Color.secondary.opacity(0.08))
      )
  }

  func settingsFootnote(_ text: String, color: Color = .secondary) -> some View {
    Text(text)
      .font(.caption)
      .foregroundColor(color)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  func settingsCalloutNote(systemImage: String, text: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: systemImage)
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.top, 1)
      Text(text)
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color.secondary.opacity(0.06))
    )
  }

  func displayChoicePicker<T: Hashable>(
    title: String,
    options: [(String, T)],
    selection: Binding<T>,
    titleFont: Font = .body,
    titleColor: Color = .primary
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(titleFont)
        .foregroundColor(titleColor)

      EqualSegmentedControl(
        options: options,
        selection: selection,
        distribution: .fillProportionally
      )
      .frame(height: 24)
      .fixedSize(horizontal: true, vertical: false)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  var advancedSettingsSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button(action: { isAdvancedExpanded.toggle() }) {
        HStack(spacing: 8) {
          Image(systemName: isAdvancedExpanded ? "chevron.down" : "chevron.right")
            .font(.caption.weight(.semibold))
          Text(model.localizedString("詳細設定"))
          Text(advancedSettingsSummaryText())
            .font(.caption)
            .foregroundColor(.secondary)
          Spacer()
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.leading, 10)

      if isAdvancedExpanded {
        advancedSettingsContent
      }
    }
  }

  func advancedSettingsSummaryText() -> String {
    let qualityText =
      switch model.qualityPreset {
      case .auto:
        model.localizedString("自動")
      case .efficiency:
        model.localizedString("省電力")
      case .quality:
        model.localizedString("高画質")
      }

    let workProfileText =
      switch model.workProfile {
      case .normal:
        model.localizedString("通常")
      case .lowPower:
        model.localizedString("低負荷")
      case .ultraLight:
        model.localizedString("最小")
      }

    let frameRateText =
      switch model.frameRateLimit {
      case .off:
        model.localizedString("制限なし")
      case .fps30:
        model.localizedString("軽量")
      case .fps60:
        model.localizedString("高負荷")
      }

    return "\(qualityText)・\(workProfileText)・\(frameRateText)"
  }

  var advancedSettingsContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      advancedQualityRow
      advancedWorkProfileRow
      advancedFrameRateRow
      advancedDecodeRow
      advancedDesktopLevelRow

      Toggle(isOn: autoFrameRateBinding) {
        Text(model.localizedString("環境に応じて再生負荷を自動調整"))
      }

      Toggle(isOn: fullScreenAuxiliaryBinding) {
        HStack(spacing: 6) {
          Text(model.localizedString("fullScreenAuxiliary を有効化"))
          helpIconButton(for: .fullScreenAuxiliary)
        }
      }
      if expandedHelpTopics.contains(.fullScreenAuxiliary) {
        settingsFootnote(
          model.localizedString("フルスクリーン空間でも壁紙を維持しやすくします。環境によっては表示が不安定になる場合があります。")
        )
      }
    }
    .padding(.top, 6)
    .padding(.leading, 20)
  }

  var advancedQualityRow: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 24) {
        HStack {
          Text(model.localizedString("画質"))
            .lineLimit(1)
          Spacer(minLength: 8)
          helpIconButton(for: .qualityPreset)
        }
        .frame(width: 150, alignment: .leading)

        Picker("", selection: qualityPresetBinding) {
          Text(model.localizedString("自動")).tag(QualityPreset.auto)
          Text(model.localizedString("省電力")).tag(QualityPreset.efficiency)
          Text(model.localizedString("高画質")).tag(QualityPreset.quality)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 240, alignment: .leading)
      }

      if expandedHelpTopics.contains(.qualityPreset) {
        settingsFootnote(
          model
            .localizedString(
              "画質と消費電力のバランスを選択します。自動は環境に応じて最適化、省電力はバッテリーと発熱を抑え、高画質は見た目を優先します。"
            )
        )
      }
    }
  }

  var advancedWorkProfileRow: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 24) {
        HStack {
          Text(model.localizedString("動作プロファイル"))
            .lineLimit(1)
          Spacer(minLength: 8)
          helpIconButton(for: .workProfile)
        }
        .frame(width: 150, alignment: .leading)

        Picker("", selection: workProfileBinding) {
          Text(model.localizedString("通常")).tag(WorkProfile.normal)
          Text(model.localizedString("低負荷")).tag(WorkProfile.lowPower)
          Text(model.localizedString("最小")).tag(WorkProfile.ultraLight)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 240, alignment: .leading)
      }

      if expandedHelpTopics.contains(.workProfile) {
        settingsFootnote(
          model
            .localizedString("全体の再生負荷を切り替えます。通常は品質優先、低負荷は安定と省電力を重視、最小は負荷を最小限にして作業優先にします。")
        )
      }
    }
  }

  var advancedFrameRateRow: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 24) {
        HStack {
          Text(model.localizedString("再生負荷"))
            .lineLimit(1)
          Spacer(minLength: 8)
          helpIconButton(for: .frameRate)
        }
        .frame(width: 150, alignment: .leading)

        Picker("", selection: frameRateLimitBinding) {
          Text(model.localizedString("制限なし")).tag(FrameRateLimit.off)
          Text(model.localizedString("軽量")).tag(FrameRateLimit.fps30)
          Text(model.localizedString("高負荷")).tag(FrameRateLimit.fps60)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 240, alignment: .leading)
      }

      if expandedHelpTopics.contains(.frameRate) {
        settingsFootnote(
          model.localizedString(
            "再生負荷の目安を選びます。数値は内部のビットレート調整に使われ、表示解像度は変わりません。"
          )
        )
      }
    }
  }

  var advancedDecodeRow: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 24) {
        HStack {
          Text(model.localizedString("デコード"))
            .lineLimit(1)
          Spacer(minLength: 8)
          helpIconButton(for: .decode)
        }
        .frame(width: 150, alignment: .leading)

        EqualSegmentedControl(
          options: [
            (model.localizedString("自動"), DecodeMode.automatic),
            (model.localizedString("標準"), DecodeMode.balanced),
            (model.localizedString("省電"), DecodeMode.efficiency)
          ],
          selection: decodeModeBinding
        )
        .frame(width: 240, height: 24, alignment: .leading)
      }

      if expandedHelpTopics.contains(.decode) {
        settingsFootnote(
          model
            .localizedString(
              "動画データのデコード方法を切り替えます。自動は環境に応じて選び、標準は滑らかさ優先、省電はCPU負荷と消費電力を抑えます。"
            )
        )
      }
    }
  }

  var advancedDesktopLevelRow: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 24) {
        HStack {
          Text(model.localizedString("デスクトップレベル"))
            .lineLimit(1)
          Spacer(minLength: 8)
          helpIconButton(for: .desktopLevel)
        }
        .frame(width: 150, alignment: .leading)

        Picker("", selection: desktopLevelOffsetBinding) {
          Text("-1").tag(DesktopLevelOffset.minusOne)
          Text("0").tag(DesktopLevelOffset.zero)
          Text("+1").tag(DesktopLevelOffset.plusOne)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 240, alignment: .leading)
      }

      if expandedHelpTopics.contains(.desktopLevel) {
        settingsFootnote(
          model
            .localizedString(
              "壁紙用のウィンドウがデスクトップのどの層に置かれるかを切り替えます。-1だとほかのアプリのウィンドウより後ろ、0は一般的なデスクトップレベル、+1だとほかのウィンドウより前面に表示されます。前面にするとアイコンを隠しやすいですが、背面にするとほかのウィンドウ操作が妨げられにくくなります。"
            )
        )
      }
    }
  }

  func helpIconButton(for topic: HelpTopic) -> some View {
    Button(action: { toggleHelp(topic) }) {
      Image(
        systemName: expandedHelpTopics.contains(topic) || hoveredHelpTopic == topic
          ? "questionmark.circle.fill"
          : "questionmark.circle"
      )
    }
    .buttonStyle(.plain)
    .onHover { over in
      hoveredHelpTopic = over ? topic : nil
    }
  }
}

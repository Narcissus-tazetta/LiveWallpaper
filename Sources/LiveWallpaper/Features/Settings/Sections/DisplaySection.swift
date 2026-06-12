import AppKit
import SwiftUI

extension SettingsView {
  var displaySettingsSection: some View {
    Section(header: Label(model.localizedString("表示"), systemImage: "display.2")) {
      HStack(spacing: 16) {
        Text(model.localizedString("壁紙の表示先"))
          .frame(width: 130, alignment: .leading)
        Picker("", selection: displayModeBinding) {
          Text(model.localizedString("メインのみ")).tag(DisplayMode.mainOnly)
          Text(model.localizedString("全ディスプレイ")).tag(DisplayMode.allScreens)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 240, alignment: .leading)
      }

      HStack(spacing: 16) {
        Text(model.localizedString("動画のフィット"))
          .frame(width: 130, alignment: .leading)
        Picker("", selection: globalFitModeBinding) {
          Text(model.localizedString("拡大")).tag(VideoFitMode.fill)
          Text(model.localizedString("全体")).tag(VideoFitMode.fit)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 240, alignment: .leading)
      }

      Toggle(model.localizedString("再生の軽量モード（省電力）"), isOn: lightweightModeBinding)
      Toggle(model.localizedString("他のアプリが前面にあるとき再生を停止"), isOn: suspendWhenFullScreenBinding)

      if let statusMessage = model.suspendWhenOtherAppStatusMessage {
        Text(statusMessage)
          .font(.caption)
          .foregroundColor(.secondary)
      }

      if model.suspendWhenOtherAppFullScreen {
        suspendExclusionSection
      }

      advancedSettingsSection
    }
  }

  var suspendExclusionSection: some View {
    VStack(alignment: .leading, spacing: 12) {
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
      .padding(.vertical, 2)

      if model.suspendExclusionBundleIDs.isEmpty {
        Text(model.localizedString("除外アプリは未設定です"))
          .font(.caption)
          .foregroundColor(.secondary)
      } else {
        ScrollView(.vertical, showsIndicators: true) {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(model.suspendExclusionBundleIDs, id: \.self) { bundleID in
              suspendExclusionRow(for: bundleID)
            }
          }
        }
        .frame(maxHeight: 140)
        .padding(.top, 4)
      }
    }
    .padding(.vertical, 6)
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
        Text(model.localizedString("フルスクリーン空間でも壁紙を維持しやすくします。環境によっては表示が不安定になる場合があります。"))
          .font(.caption)
          .foregroundColor(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
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
        Text(
          model
            .localizedString(
              "画質と消費電力のバランスを選択します。自動は環境に応じて最適化、省電力はバッテリーと発熱を抑え、高画質は見た目を優先します。"
            )
        )
        .font(.caption)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        Text(
          model
            .localizedString("全体の再生負荷を切り替えます。通常は品質優先、低負荷は安定と省電力を重視、最小は負荷を最小限にして作業優先にします。")
        )
        .font(.caption)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        Text(
          model.localizedString(
            "再生負荷の目安を選びます。数値は内部のビットレート調整に使われ、表示解像度は変わりません。"
          )
        )
          .font(.caption)
          .foregroundColor(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
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
        Text(
          model
            .localizedString(
              "動画データのデコード方法を切り替えます。自動は環境に応じて選び、標準は滑らかさ優先、省電はCPU負荷と消費電力を抑えます。"
            )
        )
        .font(.caption)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        Text(
          model
            .localizedString(
              "壁紙用のウィンドウがデスクトップのどの層に置かれるかを切り替えます。-1だとほかのアプリのウィンドウより後ろ、0は一般的なデスクトップレベル、+1だとほかのウィンドウより前面に表示されます。前面にするとアイコンを隠しやすいですが、背面にするとほかのウィンドウ操作が妨げられにくくなります。"
            )
        )
        .font(.caption)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
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

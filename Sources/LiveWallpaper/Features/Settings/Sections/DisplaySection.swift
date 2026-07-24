import AppKit
import SwiftUI

extension SettingsView {
  static let displaySearchKeywords: [String] = [
    "表示",
    "デスクトップ切り替え",
    "パフォーマンス・省電力",
    "メニューバー",
    "壁紙の表示先",
    "メインのみ",
    "全ディスプレイ",
    "動画のフィット",
    "デスクトップの見やすさ",
    "デスクトップのアイコンを表示",
    "再生の軽量モード（省電力）",
    "視差効果を減らす設定に合わせて壁紙を静止",
    "作業中は壁紙の再生を自動停止",
    "ほかのアプリを使っている間は再生を停止",
    "画面がほぼ隠れたら停止（高精度）",
    "再生を止めないアプリ",
    "自動停止しないディスプレイ",
    "デスクトップ（Space）ごとに壁紙を切り替える",
    "メニューバーにデスクトップ番号を表示",
    "デスクトップ・画面切替時に再生位置を記憶する",
    "Space",
    "Mission Control",
    "メニューバーを不透明にする",
    "詳細設定",
    "画質",
    "動作プロファイル",
    "再生負荷",
    "デコード",
    "デスクトップレベル",
    "環境に応じて再生負荷を自動調整",
    "バッテリー残量に応じて画質を自動調整",
    "fullScreenAuxiliary を有効化",
  ]

  @ViewBuilder
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
            selection: globalFitModeBinding,
            helpTopic: .globalFitMode,
            helpText: model.localizedString(
              "この動画ごとに配置タブで上書きしていない場合に使われる既定の表示方法です"
            )
          )

          desktopReadabilityDimSection
        }
      }

      toggleWithHelp(
        model.localizedString("デスクトップのアイコンを表示"),
        isOn: desktopIconsVisibleBinding,
        helpTopic: .desktopIcons,
        helpText: model.localizedString(
          "System Settings の「デスクトップに項目を表示」と同じ設定です。OFF にすると Finder が再起動し、デスクトップ上のファイルとフォルダが非表示になります。"
        )
      )
      if let message = model.desktopIconsFailureMessage {
        settingsFootnote(message, color: .orange)
      }
    }
    .onAppear {
      model.refreshDesktopIconsVisibility()
      model.refreshMenuBarAutoHideState()
    }

    Section(
      header: Label(model.localizedString("デスクトップ切り替え"), systemImage: "square.stack.3d.up")
    ) {
      settingsCalloutNote(
        systemImage: "info.circle",
        text: spaceSwitchingLimitationText()
      )

      toggleWithHelp(
        model.localizedString("デスクトップ（Space）ごとに壁紙を切り替える"),
        isOn: spaceWallpaperFeatureBinding,
        helpTopic: .spaceWallpaper,
        helpText: model.localizedString(
          "Mission Control のデスクトップごとに別の壁紙を割り当てられます。割り当ては壁紙タブのデスクトップタブ横のメニュー、または壁紙カードの右クリックから行えます。割り当てのないデスクトップは通常の壁紙を表示します。割り当てた壁紙の音声は再生されません。デスクトップ切り替え直後、壁紙の切り替わりが数百ミリ秒ほど遅れることがあります。これはmacOS側のデスクトップ切替通知が遅れて届くことによるもので、アプリの不具合ではありません。"
        ),
        disabled: !model.isSpaceWallpaperAvailable
      )
      if !model.isSpaceWallpaperAvailable {
        settingsFootnote(
          model.localizedString("この機能はご利用のmacOSでは利用できません。"),
          color: .orange
        )
      }
      if model.spaceWallpaperFeatureEnabled, model.isSpaceWallpaperAvailable {
        Toggle(
          model.localizedString("メニューバーにデスクトップ番号を表示"),
          isOn: menuBarSpaceNumberBinding
        )
        .padding(.leading, 20)
      }

      Toggle(
        model.localizedString("デスクトップ・画面切替時に再生位置を記憶する"),
        isOn: dedicatedPlaybackContinuityBinding
      )
      settingsFootnote(
        model.localizedString(
          "OFFにすると、切替のたびに動画は常に最初から再生されます。ONでも負荷が高いときは自動的に控えめな動作に切り替わります。"
        )
      )
    }

    Section(
      header: Label(model.localizedString("パフォーマンス・省電力"), systemImage: "bolt.fill")
    ) {
      Toggle(model.localizedString("再生の軽量モード（省電力）"), isOn: lightweightModeBinding)
      if model.lightweightProxyState == .generating {
        settingsFootnote(model.localizedString("軽量版を生成中..."))
      }
      if model.lightweightProxyState == .failed {
        settingsFootnote(
          model.localizedString("軽量版の生成に失敗しました。元の画質で再生しています。"),
          color: .orange
        )
      }
      toggleWithHelp(
        model.localizedString("視差効果を減らす設定に合わせて壁紙を静止"),
        isOn: respectReduceMotionBinding,
        helpTopic: .reduceMotion,
        helpText: model.localizedString(
          "システム設定の「アクセシビリティ > 表示 > 視差効果を減らす」がオンのとき、壁紙の再生を静止フレームで止めます。オフにするとこの設定に関わらず常に再生します。"
        )
      )
      if model.respectReduceMotionEnabled, model.systemReduceMotionEnabled {
        settingsFootnote(
          model.localizedString("システムの「視差効果を減らす」が有効なため、壁紙を静止しています。")
        )
      }

      Toggle(model.localizedString("作業中は壁紙の再生を自動停止"), isOn: suspendWhenFullScreenBinding)

      if model.suspendWhenOtherAppFullScreen {
        suspendExclusionSection
      }

      advancedSettingsSection
    }

    Section(header: Label(model.localizedString("メニューバー"), systemImage: "menubar.rectangle")) {
      toggleWithHelp(
        model.localizedString("メニューバーを不透明にする"),
        isOn: menuBarOpaqueBinding,
        helpTopic: .menuBarOpaque,
        helpText: model.localizedString(
          "メニューバーの裏側に不透明な帯を重ねて、壁紙が透けて見えないようにします。システムのメニューバー自体を直接変更するものではないため、環境によっては完全に一致した見た目にならない場合があります。"
        ),
        disabled: model.menuBarAutoHideDetected
      )
      if model.menuBarAutoHideDetected {
        settingsFootnote(
          model.localizedString("メニューバーの自動的に表示/非表示がONのため、この設定は使用できません。"),
          color: .orange
        )
      }
    }
  }

  var desktopReadabilityDimSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 4) {
        Text(model.localizedString("デスクトップの見やすさ"))
        helpIconButton(for: .desktopReadabilityDim)
      }

      HStack(spacing: 10) {
        Slider(value: desktopReadabilityDimOpacityBinding, in: 0...1)
          .frame(minWidth: 180, maxWidth: .infinity)
        Text("\(Int((model.desktopReadabilityDimOpacity * 100).rounded()))%")
          .foregroundColor(.secondary)
          .frame(width: 44, alignment: .trailing)
      }

      helpFootnote(
        for: .desktopReadabilityDim,
        text: model.localizedString(
          "壁紙全体を暗くして、デスクトップのアイコンやファイル名を読みやすくします。0%でオフになります。"
        )
      )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  func spaceSwitchingLimitationText() -> String {
    model.localizedString(
      "macOS の Space（Mission Control）切り替え時、まれに隣接する Space に移動することがあります。アプリを開いている Space から何もない Space へ移る操作で発生しやすいです。同じ Space へ戻ると安定することがあります。"
    )
  }

  var suspendExclusionSection: some View {
    settingsInsetCard {
      VStack(alignment: .leading, spacing: 12) {
        settingsFootnote(
          model.localizedString(
            "壁紙がほかのアプリのウィンドウで完全に隠れている間は、再生を止めて消費電力を抑えます。権限の許可は不要です。"
          )
        )

        toggleWithHelp(
          model.localizedString("ほかのアプリを使っている間は再生を停止"),
          isOn: suspendFrontmostOnlyBinding,
          helpTopic: .suspendFrontmostOnly,
          helpText: model.localizedString(
            "壁紙が見えているかどうかに関係なく、ほかのアプリが前面にある間は再生を停止します。"
          )
        )

        toggleWithHelp(
          model.localizedString("画面がほぼ隠れたら停止（高精度）"),
          isOn: suspendHighSensitivityBinding,
          helpTopic: .suspendHighSensitivity,
          helpText: model.localizedString(
            "壁紙がわずかに見えていても、画面の大部分がウィンドウで覆われていれば停止します。この検出には画面収録の許可が必要です。"
          )
        )
        if shouldShowScreenRecordingCoverageWarning {
          VStack(alignment: .leading, spacing: 6) {
            settingsFootnote(screenRecordingCoverageWarningText(), color: .red)
            Button(model.localizedString("画面収録の許可を開く")) {
              model.requestScreenRecordingPermissionForCoverage()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
          }
        }

        if model.availableDisplayScreens().count > 1 {
          Divider().opacity(0.35)
          displaySuspendExclusionContent
        }

        Divider().opacity(0.35)

        suspendExclusionContent
      }
    }
  }

  /// 接続中の画面ごとに、自動停止の対象にするかどうかを切り替えるリスト。
  var displaySuspendExclusionContent: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(model.localizedString("自動停止しないディスプレイ"))
        .font(.caption)
        .foregroundColor(.secondary)

      VStack(alignment: .leading, spacing: 4) {
        ForEach(model.availableDisplayScreens(), id: \.id) { screen in
          displaySuspendToggleRow(for: screen)
        }
      }
    }
  }

  func displaySuspendToggleRow(for screen: WallpaperModel.DisplayScreenInfo) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Toggle(isOn: suspendDisabledBinding(forScreenID: screen.id)) {
        Text(screen.name)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .toggleStyle(.checkbox)
      .controlSize(.small)
      .help(model.localizedString("オンにすると、この画面はメイン画面での作業やウィンドウの被覆に関わらず再生を続けます"))

      if model.isSuspendDisabled(forScreenID: screen.id),
        model.respectReduceMotionEnabled, model.systemReduceMotionEnabled
      {
        settingsFootnote(
          model.localizedString("視差効果を減らす設定が有効な間は、この画面も静止します。")
        )
      }
    }
  }

  func suspendDisabledBinding(forScreenID screenID: String) -> Binding<Bool> {
    Binding(
      get: { model.isSuspendDisabled(forScreenID: screenID) },
      set: { model.setSuspendDisabled($0, forScreenID: screenID) }
    )
  }

  var shouldShowScreenRecordingCoverageWarning: Bool {
    model.suspendWhenOtherAppFullScreen
      && model.suspendHighSensitivityEnabled
      && !model.screenRecordingTrustedForCoverage
  }

  func screenRecordingCoverageWarningText() -> String {
    model.localizedString("高精度な検出には画面収録の許可が必要です。許可されるまでは通常の方法で判定します。")
  }

  var suspendExclusionContent: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .center) {
        Text(model.localizedString("再生を止めないアプリ"))
          .font(.caption)
          .foregroundColor(.secondary)
        Spacer()
        Button(model.localizedString("アプリを追加")) {
          suspendExclusionAppPickerSearchText = ""
          isSuspendExclusionAppPickerPresented = true
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .popover(isPresented: $isSuspendExclusionAppPickerPresented, arrowEdge: .bottom) {
          suspendExclusionAppPickerPopover
        }
      }

      if model.suspendExclusionBundleIDs.isEmpty {
        settingsFootnote(model.localizedString("再生を止めないアプリはまだ登録されていません"))
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

  private static var suspendExclusionAppMetadataCache: [String: (name: String, icon: NSImage?, isResolved: Bool)] = [:]

  func suspendExclusionAppMetadata(for bundleID: String) -> (name: String, icon: NSImage?, isResolved: Bool) {
    if let cached = Self.suspendExclusionAppMetadataCache[bundleID] {
      return cached
    }
    let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    let appName = appURL.map { $0.deletingPathExtension().lastPathComponent } ?? bundleID
    let appIcon = appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
    let metadata = (name: appName, icon: appIcon, isResolved: appURL != nil)
    // Only cache resolved hits. An unresolved bundle ID may become resolvable
    // later (the app gets installed after being excluded), so caching a miss
    // would permanently freeze the row on the bundle-ID fallback.
    if metadata.isResolved {
      Self.suspendExclusionAppMetadataCache[bundleID] = metadata
    }
    return metadata
  }

  func suspendExclusionRow(for bundleID: String) -> some View {
    let metadata = suspendExclusionAppMetadata(for: bundleID)
    let appName = metadata.name
    let appIcon = metadata.icon
    let isResolved = metadata.isResolved

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
        if isResolved {
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

  var runningAppExclusionCandidates: [NSRunningApplication] {
    let excluded = Set(model.suspendExclusionBundleIDs)
    return NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular }
      .filter { app in
        guard let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier else {
          return false
        }
        return !excluded.contains(model.normalizeBundleID(bundleID))
      }
      .filter { app in
        suspendExclusionAppPickerSearchText.isEmpty
          || (app.localizedName ?? "").localizedCaseInsensitiveContains(
            suspendExclusionAppPickerSearchText)
      }
      .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
  }

  var suspendExclusionAppPickerPopover: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(model.localizedString("起動中のアプリから選択"))
        .font(.caption)
        .foregroundColor(.secondary)

      SearchField(
        placeholder: model.localizedString("アプリ名で検索"),
        text: $suspendExclusionAppPickerSearchText,
        isFocused: $isSuspendExclusionSearchFocused
      )
      .background(
        Button("") { isSuspendExclusionSearchFocused = true }
          .keyboardShortcut("f", modifiers: .command)
          .hidden()
      )

      let candidates = runningAppExclusionCandidates
      if candidates.isEmpty {
        SearchEmptyState(
          isSearchActive: !suspendExclusionAppPickerSearchText.isEmpty,
          noContentText: model.localizedString("除外できるアプリがありません"),
          noMatchText: model.localizedString("一致するアプリがありません"),
          clearButtonTitle: model.localizedString("検索をクリア"),
          onClearSearch: { suspendExclusionAppPickerSearchText = ""; isSuspendExclusionSearchFocused = true }
        )
        .frame(width: 260)
      } else {
        ScrollView(.vertical, showsIndicators: true) {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(candidates, id: \.processIdentifier) { app in
              Button {
                if let bundleID = app.bundleIdentifier {
                  model.addSuspendExclusionBundleID(bundleID)
                }
              } label: {
                HStack(spacing: 8) {
                  if let icon = app.icon {
                    Image(nsImage: icon)
                      .resizable()
                      .frame(width: 20, height: 20)
                  }
                  Text(app.localizedName ?? app.bundleIdentifier ?? "")
                    .lineLimit(1)
                  Spacer()
                }
                .contentShape(Rectangle())
                .padding(.vertical, 3)
                .padding(.horizontal, 4)
              }
              .buttonStyle(.plain)
            }
          }
        }
        .frame(maxHeight: 220)
        .frame(width: 260)
      }

      Divider()

      Button(model.localizedString("Finderから他のアプリを選択…")) {
        isSuspendExclusionAppPickerPresented = false
        selectAppForSuspendExclusion()
      }
      .buttonStyle(.link)
      .controlSize(.small)
    }
    .padding(12)
    .onAppear { isSuspendExclusionSearchFocused = true }
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
    titleColor: Color = .primary,
    helpTopic: HelpTopic? = nil,
    helpText: String? = nil
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 4) {
        Text(title)
          .font(titleFont)
          .foregroundColor(titleColor)
        if let helpTopic {
          helpIconButton(for: helpTopic)
        }
      }

      EqualSegmentedControl(
        options: options,
        selection: selection,
        distribution: .fillProportionally
      )
      .frame(height: 24)
      .fixedSize(horizontal: true, vertical: false)

      if let helpTopic, let helpText {
        helpFootnote(for: helpTopic, text: helpText)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// トグル本体とヘルプアイコン、展開時の説明文をまとめた行。
  /// 「Toggle + はてなアイコン + 折りたたみ説明」が表示セクション全体で
  /// 繰り返し登場するため、ここに集約している。
  func toggleWithHelp(
    _ title: String,
    isOn: Binding<Bool>,
    helpTopic: HelpTopic,
    helpText: String,
    disabled: Bool = false
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Toggle(isOn: isOn) {
        HStack(spacing: 6) {
          Text(title)
          helpIconButton(for: helpTopic)
        }
      }
      .disabled(disabled)

      helpFootnote(for: helpTopic, text: helpText)
    }
  }

  @ViewBuilder
  func helpFootnote(for topic: HelpTopic, text: String) -> some View {
    if expandedHelpTopics.contains(topic) {
      settingsFootnote(text)
    }
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
    settingsInsetCard {
      VStack(alignment: .leading, spacing: 14) {
        advancedSettingRow(
          title: model.localizedString("画質"),
          helpTopic: .qualityPreset,
          helpText: model.localizedString(
            "画質と消費電力のバランスを選択します。自動は環境に応じて最適化、省電力はバッテリーと発熱を抑え、高画質は見た目を優先します。"
          )
        ) {
          EqualSegmentedControl(
            options: [
              (model.localizedString("自動"), QualityPreset.auto),
              (model.localizedString("省電力"), QualityPreset.efficiency),
              (model.localizedString("高画質"), QualityPreset.quality)
            ],
            selection: qualityPresetBinding
          )
        }

        Divider().opacity(0.3)

        advancedSettingRow(
          title: model.localizedString("動作プロファイル"),
          helpTopic: .workProfile,
          helpText: model.localizedString(
            "全体の再生負荷を切り替えます。通常は品質優先、低負荷は安定と省電力を重視、最小は負荷を最小限にして作業優先にします。"
          )
        ) {
          EqualSegmentedControl(
            options: [
              (model.localizedString("通常"), WorkProfile.normal),
              (model.localizedString("低負荷"), WorkProfile.lowPower),
              (model.localizedString("最小"), WorkProfile.ultraLight)
            ],
            selection: workProfileBinding
          )
        }

        Divider().opacity(0.3)

        advancedSettingRow(
          title: model.localizedString("再生負荷"),
          helpTopic: .frameRate,
          helpText: model.localizedString(
            "再生負荷の目安を選びます。数値は内部のビットレート調整に使われ、表示解像度は変わりません。"
          )
        ) {
          EqualSegmentedControl(
            options: [
              (model.localizedString("制限なし"), FrameRateLimit.off),
              (model.localizedString("軽量"), FrameRateLimit.fps30),
              (model.localizedString("高負荷"), FrameRateLimit.fps60)
            ],
            selection: frameRateLimitBinding
          )
        }

        Divider().opacity(0.3)

        advancedSettingRow(
          title: model.localizedString("デコード"),
          helpTopic: .decode,
          helpText: model.localizedString(
            "動画データのデコード方法を切り替えます。自動は環境に応じて選び、標準は滑らかさ優先、省電はCPU負荷と消費電力を抑えます。"
          )
        ) {
          EqualSegmentedControl(
            options: [
              (model.localizedString("自動"), DecodeMode.automatic),
              (model.localizedString("標準"), DecodeMode.balanced),
              (model.localizedString("省電"), DecodeMode.efficiency)
            ],
            selection: decodeModeBinding
          )
        }

        Divider().opacity(0.3)

        advancedSettingRow(
          title: model.localizedString("デスクトップレベル"),
          helpTopic: .desktopLevel,
          helpText: model.localizedString(
            "壁紙用のウィンドウがデスクトップのどの層に置かれるかを切り替えます。-1だとほかのアプリのウィンドウより後ろ、0は一般的なデスクトップレベル、+1だとほかのウィンドウより前面に表示されます。前面にするとアイコンを隠しやすいですが、背面にするとほかのウィンドウ操作が妨げられにくくなります。"
          )
        ) {
          EqualSegmentedControl(
            options: [
              ("-1", DesktopLevelOffset.minusOne),
              ("0", DesktopLevelOffset.zero),
              ("+1", DesktopLevelOffset.plusOne)
            ],
            selection: desktopLevelOffsetBinding
          )
        }

        Divider().opacity(0.3)

        VStack(alignment: .leading, spacing: 10) {
          Toggle(isOn: autoFrameRateBinding) {
            Text(model.localizedString("環境に応じて再生負荷を自動調整"))
          }

          toggleWithHelp(
            model.localizedString("バッテリー残量に応じて画質を自動調整"),
            isOn: batteryAwareQualityBinding,
            helpTopic: .batteryAwareQuality,
            helpText: model.localizedString("バッテリー駆動中に残量が10%以下になると、再生の負荷を自動的に下げて消費電力を抑えます。")
          )

          toggleWithHelp(
            model.localizedString("fullScreenAuxiliary を有効化"),
            isOn: fullScreenAuxiliaryBinding,
            helpTopic: .fullScreenAuxiliary,
            helpText: model.localizedString("フルスクリーン空間でも壁紙を維持しやすくします。環境によっては表示が不安定になる場合があります。")
          )
        }
      }
    }
    .padding(.top, 6)
    .padding(.leading, 10)
  }

  func advancedSettingRow<Content: View>(
    title: String,
    helpTopic: HelpTopic,
    helpText: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 16) {
        HStack(spacing: 4) {
          Text(title)
            .lineLimit(1)
          helpIconButton(for: helpTopic)
        }
        .frame(width: 140, alignment: .leading)

        content()
          .frame(height: 24)

        Spacer(minLength: 0)
      }

      helpFootnote(for: helpTopic, text: helpText)
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

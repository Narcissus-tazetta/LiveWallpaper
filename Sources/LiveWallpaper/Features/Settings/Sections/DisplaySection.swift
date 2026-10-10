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
    "HDR 動画を HDR で表示",
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
    "切り替えエフェクト",
    "エフェクトの長さ",
    "クロスフェード",
    "黒を挟む",
    "フェード",
    "バッテリー駆動中",
    "負荷を下げる",
    "静止画にする",
    "デコード",
    "デスクトップレベル",
    "環境に応じて再生負荷を自動調整",
    "バッテリー残量に応じて画質を自動調整",
    "fullScreenAuxiliary を有効化",
  ]

  @ViewBuilder
  var displaySettingsSection: some View {
    Section(header: SettingsSectionHeader(title: model.localizedString("表示"))) {
      settingsMenuRow(
        title: model.localizedString("壁紙の表示先"),
        options: [
          (model.localizedString("メインのみ"), DisplayMode.mainOnly),
          (model.localizedString("全ディスプレイ"), DisplayMode.allScreens)
        ],
        selection: displayModeBinding
      )

      settingsMenuRow(
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

      settingsMenuRow(
        title: model.localizedString("切り替えエフェクト"),
        options: [
          (model.localizedString("オフ"), WallpaperTransitionChoice.off),
          (model.localizedString("クロスフェード"), WallpaperTransitionChoice.style(.crossfade)),
          (model.localizedString("黒を挟む"), WallpaperTransitionChoice.style(.dipToBlack))
        ],
        selection: wallpaperTransitionChoiceBinding,
        helpTopic: .wallpaperTransition,
        helpText: model.localizedString(
          "壁紙が切り替わるときに前の壁紙からなめらかに移り変わります。デスクトップ（Space）の切り替えと、視差効果を減らす設定がオンのときはフェードしません。"
        )
      )

      if model.wallpaperTransitionDuration > 0 {
        settingsMenuRow(
          title: model.localizedString("エフェクトの長さ"),
          options: [
            (model.localizedString("0.5秒"), 0.5),
            (model.localizedString("1秒"), 1.0),
            (model.localizedString("2秒"), 2.0)
          ],
          selection: wallpaperTransitionDurationBinding
        )
      }

      desktopReadabilityDimSection

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
      header: SettingsSectionHeader(title: model.localizedString("デスクトップ切り替え"))
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
      header: SettingsSectionHeader(title: model.localizedString("パフォーマンス・省電力"))
    ) {
      Toggle(model.localizedString("再生の軽量モード（省電力）"), isOn: lightweightModeBinding)
      batteryPlaybackPolicyRow
      if #available(macOS 26, *) {
        hdrDisplayRow
      }
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

    Section(header: SettingsSectionHeader(title: model.localizedString("メニューバー"))) {
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
    VStack(alignment: .leading, spacing: 4) {
      LabeledContent {
        HStack(spacing: 8) {
          Slider(value: desktopReadabilityDimOpacityBinding, in: 0...1)
            .frame(maxWidth: 220)
            .accessibilityLabel(model.localizedString("デスクトップの見やすさ"))
            .accessibilityValue("\(Int((model.desktopReadabilityDimOpacity * 100).rounded()))%")
          Text("\(Int((model.desktopReadabilityDimOpacity * 100).rounded()))%")
            .monospacedDigit()
            .foregroundColor(.secondary)
            .frame(width: 40, alignment: .trailing)
            .accessibilityHidden(true)
        }
      } label: {
        HStack(spacing: 4) {
          Text(model.localizedString("デスクトップの見やすさ"))
          helpIconButton(for: .desktopReadabilityDim)
        }
      }

      helpFootnote(
        for: .desktopReadabilityDim,
        text: model.localizedString(
          "壁紙全体を暗くして、デスクトップのアイコンやファイル名を読みやすくします。0%でオフになります。"
        )
      )
    }
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
        isFocused: $isSuspendExclusionSearchFocused,
        clearButtonLabel: model.localizedString("検索をクリア")
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

  /// grouped Form のセクション自体が背景を持つため、ここでは枠を重ねず余白だけ揃える。
  func settingsInsetCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
      .padding(.vertical, 4)
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

  /// A label on the left and a pop-up menu on the right, the row System Settings uses for
  /// choosing one of a few options.
  func settingsMenuRow<T: Hashable>(
    title: String,
    options: [(String, T)],
    selection: Binding<T>,
    helpTopic: HelpTopic? = nil,
    helpText: String? = nil
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Picker(selection: selection) {
        ForEach(options.indices, id: \.self) { index in
          Text(options[index].0).tag(options[index].1)
        }
      } label: {
        HStack(spacing: 4) {
          Text(title)
          if let helpTopic {
            helpIconButton(for: helpTopic)
          }
        }
      }
      .pickerStyle(.menu)

      if let helpTopic, let helpText {
        helpFootnote(for: helpTopic, text: helpText)
      }
    }
  }

  static let advancedSettingsSearchKeywords: [String] = [
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

  /// A search hit inside the sheet would otherwise show only the "Details…" button.
  private var advancedSettingsMatchSearch: Bool {
    let query = settingsSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      return false
    }
    return Self.advancedSettingsSearchKeywords.contains { keyword in
      keyword.localizedCaseInsensitiveContains(query)
        || model.localizedString(keyword).localizedCaseInsensitiveContains(query)
    }
  }

  /// Advanced options open in a sheet, as System Settings does with its "Details…" buttons,
  /// so the main list stays short.
  @ViewBuilder
  var advancedSettingsSection: some View {
    if advancedSettingsMatchSearch {
      advancedSettingsContent
    } else {
      advancedSettingsButtonRow
    }
  }

  private var advancedSettingsButtonRow: some View {
    LabeledContent {
      Button(model.localizedString("詳細…")) {
        isAdvancedSettingsPresented = true
      }
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(model.localizedString("詳細設定"))
        Text(advancedSettingsSummaryText())
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
    .sheet(isPresented: $isAdvancedSettingsPresented) {
      VStack(spacing: 0) {
        Form {
          Section(header: Text(model.localizedString("詳細設定"))) {
            advancedSettingsContent
          }
        }
        .formStyle(.grouped)

        HStack {
          Spacer()
          Button(model.localizedString("完了")) {
            isAdvancedSettingsPresented = false
          }
          .keyboardShortcut(.defaultAction)
        }
        .padding(16)
      }
      .frame(width: 540, height: 460)
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
    Group {
        settingsMenuRow(
          title: model.localizedString("画質"),
          options: [
              (model.localizedString("自動"), QualityPreset.auto),
              (model.localizedString("省電力"), QualityPreset.efficiency),
              (model.localizedString("高画質"), QualityPreset.quality)
            ],
          selection: qualityPresetBinding,
          helpTopic: .qualityPreset,
          helpText: model.localizedString(
            "画質と消費電力のバランスを選択します。自動は環境に応じて最適化、省電力はバッテリーと発熱を抑え、高画質は見た目を優先します。"
          )
        )

        settingsMenuRow(
          title: model.localizedString("動作プロファイル"),
          options: [
              (model.localizedString("通常"), WorkProfile.normal),
              (model.localizedString("低負荷"), WorkProfile.lowPower),
              (model.localizedString("最小"), WorkProfile.ultraLight)
            ],
          selection: workProfileBinding,
          helpTopic: .workProfile,
          helpText: model.localizedString(
            "全体の再生負荷を切り替えます。通常は品質優先、低負荷は安定と省電力を重視、最小は負荷を最小限にして作業優先にします。"
          )
        )

        settingsMenuRow(
          title: model.localizedString("再生負荷"),
          options: [
              (model.localizedString("制限なし"), FrameRateLimit.off),
              (model.localizedString("軽量"), FrameRateLimit.fps30),
              (model.localizedString("高負荷"), FrameRateLimit.fps60)
            ],
          selection: frameRateLimitBinding,
          helpTopic: .frameRate,
          helpText: model.localizedString(
            "再生負荷の目安を選びます。数値は内部のビットレート調整に使われ、表示解像度は変わりません。"
          )
        )

        settingsMenuRow(
          title: model.localizedString("デコード"),
          options: [
              (model.localizedString("自動"), DecodeMode.automatic),
              (model.localizedString("標準"), DecodeMode.balanced),
              (model.localizedString("省電"), DecodeMode.efficiency)
            ],
          selection: decodeModeBinding,
          helpTopic: .decode,
          helpText: model.localizedString(
            "動画データのデコード方法を切り替えます。自動は環境に応じて選び、標準は滑らかさ優先、省電はCPU負荷と消費電力を抑えます。"
          )
        )

        settingsMenuRow(
          title: model.localizedString("デスクトップレベル"),
          options: [
              ("-1", DesktopLevelOffset.minusOne),
              ("0", DesktopLevelOffset.zero),
              ("+1", DesktopLevelOffset.plusOne)
            ],
          selection: desktopLevelOffsetBinding,
          helpTopic: .desktopLevel,
          helpText: model.localizedString(
            "壁紙用のウィンドウがデスクトップのどの層に置かれるかを切り替えます。-1だとほかのアプリのウィンドウより後ろ、0は一般的なデスクトップレベル、+1だとほかのウィンドウより前面に表示されます。前面にするとアイコンを隠しやすいですが、背面にするとほかのウィンドウ操作が妨げられにくくなります。"
          )
        )

        Group {
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

  var hdrDisplayRow: some View {
    VStack(alignment: .leading, spacing: 4) {
      toggleWithHelp(
        model.localizedString("HDR 動画を HDR で表示"),
        isOn: hdrDisplayEnabledBinding,
        helpTopic: .hdrDisplay,
        helpText: model.localizedString(
          "HDR 対応のディスプレイで、HDR 動画の明るい部分を本来の明るさで表示します。ほかのウィンドウと並んでも眩しくなりすぎないよう、明るさは控えめに調整されます。オフにすると SDR で表示します。"
        )
      )
      if model.hdrDisplayEnabled, model.batteryReduceLoadActive {
        settingsFootnote(model.localizedString("バッテリー駆動中のため、HDR 動画を SDR で表示しています。"))
      }
    }
  }

  var batteryPlaybackPolicyRow: some View {
    VStack(alignment: .leading, spacing: 4) {
      settingsMenuRow(
        title: model.localizedString("バッテリー駆動中"),
        options: [
          (model.localizedString("通常どおり"), BatteryPlaybackPolicy.normal),
          (model.localizedString("負荷を下げる"), BatteryPlaybackPolicy.reduceLoad),
          (model.localizedString("静止画にする"), BatteryPlaybackPolicy.freeze)
        ],
        selection: batteryPlaybackPolicyBinding,
        helpTopic: .batteryPlaybackPolicy,
        helpText: model.localizedString(
          "電源アダプタを外している間の動作を選びます。負荷を下げるは軽量モードと同じ縮小版の動画で再生し、静止画にするは壁紙を止めます。電源につなぐとすぐに元へ戻ります。"
        )
      )
      if model.batteryFreezeActive {
        settingsFootnote(model.localizedString("バッテリー駆動中のため、壁紙を静止しています。"))
      } else if model.batteryReduceLoadActive, !model.lightweightMode {
        settingsFootnote(model.localizedString("バッテリー駆動中のため、軽量モードで再生しています。"))
      }
    }
  }

}

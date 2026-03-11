import SwiftUI

extension SettingsView {
    private var clickThroughBinding: Binding<Bool> {
        Binding(
            get: { model.clickThrough },
            set: { model.setClickThrough($0) }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: "launchAtLogin") },
            set: { NotificationCenter.default.post(name: .toggleLaunchAtLogin, object: $0) }
        )
    }

    private var audioEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.audioEnabled },
            set: { value in withAnimation { model.setAudioEnabled(value) } }
        )
    }

    private var audioVolumeBinding: Binding<Double> {
        Binding(
            get: { Double(model.audioVolume) },
            set: { model.setAudioVolume(Float($0)) }
        )
    }

    private var displayModeBinding: Binding<DisplayMode> {
        Binding(
            get: { model.displayMode },
            set: { model.setDisplayMode($0) }
        )
    }

    private var globalFitModeBinding: Binding<VideoFitMode> {
        Binding(
            get: { model.fitMode },
            set: { model.setFitMode($0) }
        )
    }

    private var lightweightModeBinding: Binding<Bool> {
        Binding(
            get: { model.lightweightMode },
            set: { model.setLightweightMode($0) }
        )
    }

    private var suspendWhenFullScreenBinding: Binding<Bool> {
        Binding(
            get: { model.suspendWhenOtherAppFullScreen },
            set: { _ = model.setSuspendWhenOtherAppFullScreen($0) }
        )
    }

    private var qualityPresetBinding: Binding<QualityPreset> {
        Binding(
            get: { model.qualityPreset },
            set: { model.setQualityPreset($0) }
        )
    }

    private var workProfileBinding: Binding<WorkProfile> {
        Binding(
            get: { model.workProfile },
            set: { model.setWorkProfile($0) }
        )
    }

    private var frameRateLimitBinding: Binding<FrameRateLimit> {
        Binding(
            get: { model.frameRateLimit },
            set: { model.setFrameRateLimit($0) }
        )
    }

    private var decodeModeBinding: Binding<DecodeMode> {
        Binding(
            get: { model.decodeMode },
            set: { model.setDecodeMode($0) }
        )
    }

    private var desktopLevelOffsetBinding: Binding<DesktopLevelOffset> {
        Binding(
            get: { model.desktopLevelOffset },
            set: { model.setDesktopLevelOffset($0) }
        )
    }

    private var fullScreenAuxiliaryBinding: Binding<Bool> {
        Binding(
            get: { model.useFullScreenAuxiliary },
            set: { model.setFullScreenAuxiliary($0) }
        )
    }

    private var autoUpdateBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: "autoUpdateEnabled") },
            set: { NotificationCenter.default.post(name: .toggleAutoUpdate, object: $0) }
        )
    }

    var videoSettingsSection: some View {
        Section(header: Label("動画", systemImage: "film")) {
            Toggle("クリック貫通を有効にする", isOn: clickThroughBinding)
            Toggle("ログイン時に自動起動する", isOn: launchAtLoginBinding)
            Toggle("音声を再生する", isOn: audioEnabledBinding)

            HStack(spacing: 10) {
                Text("音量")
                    .frame(width: 150, alignment: .leading)

                Slider(value: audioVolumeBinding, in: 0 ... 1)
                    .disabled(!model.audioEnabled)
                    .frame(minWidth: 180, maxWidth: .infinity)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    TextField("", text: $volumeInput)
                        .frame(width: 48)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .multilineTextAlignment(.trailing)
                        .disabled(!model.audioEnabled)
                        .focused($isVolumeInputFocused)
                        .onSubmit { commitVolumeInput() }
                        .onChange(of: volumeInput) { newValue in
                            let filtered = String(newValue.filter(\.isNumber).prefix(3))
                            if filtered != newValue {
                                volumeInput = filtered
                            }
                        }

                    Text("%")
                        .foregroundColor(.secondary)
                        .font(.system(size: 13))
                }
            }
        }
    }

    var displaySettingsSection: some View {
        Section(header: Label("表示", systemImage: "display.2")) {
            HStack(spacing: 16) {
                Text("壁紙の表示先")
                    .frame(width: 130, alignment: .leading)
                Picker("", selection: displayModeBinding) {
                    Text("メインのみ").tag(DisplayMode.mainOnly)
                    Text("全ディスプレイ").tag(DisplayMode.allScreens)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240, alignment: .leading)
            }

            HStack(spacing: 16) {
                Text("動画のフィット")
                    .frame(width: 130, alignment: .leading)
                Picker("", selection: globalFitModeBinding) {
                    Text("拡大").tag(VideoFitMode.fill)
                    Text("全体").tag(VideoFitMode.fit)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240, alignment: .leading)
            }

            Toggle("再生の軽量モード（省電力）", isOn: lightweightModeBinding)
            Toggle("他のアプリが前面にあるとき再生を停止", isOn: suspendWhenFullScreenBinding)

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

    private var suspendExclusionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text("停止対象から除外するアプリ")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("アプリを選択して追加") {
                    selectAppForSuspendExclusion()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.vertical, 2)

            if model.suspendExclusionBundleIDs.isEmpty {
                Text("除外アプリは未設定です")
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

    private func suspendExclusionRow(for bundleID: String) -> some View {
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

            Button("削除", role: .destructive) {
                model.removeSuspendExclusionBundleID(bundleID)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
        }
        .padding(.vertical, 2)
    }

    private var advancedSettingsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { isAdvancedExpanded.toggle() }) {
                HStack(spacing: 8) {
                    Image(systemName: isAdvancedExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                    Text("詳細設定")
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

    private var advancedSettingsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            advancedQualityRow
            advancedWorkProfileRow
            advancedFrameRateRow
            advancedDecodeRow
            advancedDesktopLevelRow

            Toggle(isOn: fullScreenAuxiliaryBinding) {
                HStack(spacing: 6) {
                    Text("fullScreenAuxiliary を有効化")
                    helpIconButton(for: .fullScreenAuxiliary)
                }
            }
            if expandedHelpTopics.contains(.fullScreenAuxiliary) {
                Text("フルスクリーン空間でも壁紙を維持しやすくします。環境によっては表示が不安定になる場合があります。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 6)
        .padding(.leading, 20)
    }

    private var advancedQualityRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 24) {
                HStack {
                    Text("画質")
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    helpIconButton(for: .qualityPreset)
                }
                .frame(width: 150, alignment: .leading)

                Picker("", selection: qualityPresetBinding) {
                    Text("自動").tag(QualityPreset.auto)
                    Text("省電力").tag(QualityPreset.efficiency)
                    Text("高画質").tag(QualityPreset.quality)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240, alignment: .leading)
            }

            if expandedHelpTopics.contains(.qualityPreset) {
                Text("画質と消費電力のバランスを選択します。自動は環境に応じて最適化、省電力はバッテリーと発熱を抑え、高画質は見た目を優先します。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var advancedWorkProfileRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 24) {
                HStack {
                    Text("動作プロファイル")
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    helpIconButton(for: .workProfile)
                }
                .frame(width: 150, alignment: .leading)

                Picker("", selection: workProfileBinding) {
                    Text("通常").tag(WorkProfile.normal)
                    Text("低負荷").tag(WorkProfile.lowPower)
                    Text("最小").tag(WorkProfile.ultraLight)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240, alignment: .leading)
            }

            if expandedHelpTopics.contains(.workProfile) {
                Text("全体の再生負荷を切り替えます。通常は品質優先、低負荷は安定と省電力を重視、最小は負荷を最小限にして作業優先にします。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var advancedFrameRateRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 24) {
                HStack {
                    Text("フレームレート")
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    helpIconButton(for: .frameRate)
                }
                .frame(width: 150, alignment: .leading)

                Picker("", selection: frameRateLimitBinding) {
                    Text("制限なし").tag(FrameRateLimit.off)
                    Text("30").tag(FrameRateLimit.fps30)
                    Text("60").tag(FrameRateLimit.fps60)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240, alignment: .leading)
            }

            if expandedHelpTopics.contains(.frameRate) {
                Text("動画の再生上限を選べます。制限なしは滑らかさ優先、30/60 はCPUと電力を抑えやすくなります。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var advancedDecodeRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 24) {
                HStack {
                    Text("デコード")
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    helpIconButton(for: .decode)
                }
                .frame(width: 150, alignment: .leading)

                EqualSegmentedControl(
                    options: [
                        ("自動", DecodeMode.automatic),
                        ("GPU", DecodeMode.gpuAdaptive),
                        ("標準", DecodeMode.balanced),
                        ("省電", DecodeMode.efficiency)
                    ],
                    selection: decodeModeBinding
                )
                .frame(width: 280, height: 24, alignment: .leading)
            }

            if expandedHelpTopics.contains(.decode) {
                Text("動画データのデコード方法を切り替えます。自動はハードウェア/ソフトウェアを状況に応じて選び、標準はGPUハードウェア優先で滑らかさを保ちます。省電力はソフトウェア再生を多用し、CPU負荷と消費電力を低く抑えますが再生品質が落ちる場合があります。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var advancedDesktopLevelRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 24) {
                HStack {
                    Text("デスクトップレベル")
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
                Text("壁紙用のウィンドウがデスクトップのどの層に置かれるかを切り替えます。-1だとほかのアプリのウィンドウより後ろ、0は一般的なデスクトップレベル、+1だとほかのウィンドウより前面に表示されます。前面にするとアイコンを隠しやすいですが、背面にするとほかのウィンドウ操作が妨げられにくくなります。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func helpIconButton(for topic: HelpTopic) -> some View {
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

    var cacheSettingsSection: some View {
        Section(header: Label("キャッシュ", systemImage: "externaldrive")) {
            HStack(spacing: 10) {
                Button("保存先を開く") {
                    NotificationCenter.default.post(name: .openCacheFolder, object: nil)
                }
                .buttonStyle(.bordered)

                Button("キャッシュ削除") {
                    NotificationCenter.default.post(name: .clearCache, object: nil)
                }
                .buttonStyle(.bordered)

                Spacer()
            }
        }
    }

    var resetSettingsSection: some View {
        Section(header: Label("設定", systemImage: "arrow.counterclockwise")) {
            HStack(spacing: 10) {
                Button("再生をリフレッシュ") {
                    NotificationCenter.default.post(name: .refreshPlayback, object: nil)
                }
                .buttonStyle(.bordered)

                Button("設定をリセット", role: .destructive) {
                    isResetSettingsDialogPresented = true
                }
                .buttonStyle(.bordered)
                Spacer()
            }

            Text("再生表示が崩れたときはリフレッシュを使って再初期化できます。設定リセットは表示・再生設定を初期値に戻します")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    var updateSettingsSection: some View {
        Section(header: Label("アップデート", systemImage: "arrow.triangle.2.circlepath")) {
            Toggle("アップデートを自動で確認する（起動時にも通知）", isOn: autoUpdateBinding)

            HStack {
                Button("今すぐ確認") {
                    NotificationCenter.default.post(name: .checkUpdatesNow, object: nil)
                }
                .buttonStyle(.bordered)
                Spacer()
            }
        }
    }
}

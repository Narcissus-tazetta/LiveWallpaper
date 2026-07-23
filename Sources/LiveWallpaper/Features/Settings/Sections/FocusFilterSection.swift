import AppKit
import SwiftUI

extension SettingsView {
    static let focusFilterSearchKeywords: [String] = [
        "集中モード",
        "集中モードで壁紙を切り替える",
        "集中モードごとに表示する壁紙を選べます。",
        "フルディスクアクセス",
        "おやすみモード",
        "Focus",
    ]

    /// 壁紙タブの一覧ペインの下・スケジュールカードの上に置く、集中モード連携カード。
    ///
    /// このMacの集中モード一覧(FocusModeMonitor がDoNotDisturb DBから読む)を表示し、
    /// モードごとに壁紙を割り当てる。macOSは集中モード情報をアプリへ公開しないため
    /// フルディスクアクセスが必要で、未許可の間は許可への導線を出す。
    /// 適用の仕組みは WallpaperModel+FocusModes.swift のコメント参照。
    var wallpaperFocusFilterCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            focusCardHeader
            if isFocusCardExpanded {
                if !model.focusFilterIntegrationEnabled {
                    Text(model.localizedString("オフの間は、集中モードによる壁紙の切り替えを行いません。"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if model.focusModes.isEmpty {
                    focusModeAccessGuidance
                } else {
                    focusModeAssignmentList
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    /// スケジュールカード(scheduleCardHeader)と同じ折りたたみヘッダー。マスター
    /// スイッチだけは閉じたまま操作したいので、シェブロンの左に常時出す。Toggleが
    /// 自前でタップを消費するため、行全体のonTapGestureとは競合しない。
    private var focusCardHeader: some View {
        HStack(spacing: 8) {
            Label(model.localizedString("集中モード"), systemImage: "moon.circle")
                .font(.system(size: 12, weight: .semibold))
            Text(focusCardSummary)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Toggle(
                model.localizedString("集中モードで壁紙を切り替える"),
                isOn: Binding(
                    get: { model.focusFilterIntegrationEnabled },
                    set: { model.setFocusFilterIntegrationEnabled($0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(isFocusCardExpanded ? 90 : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                isFocusCardExpanded.toggle()
            }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(model.localizedString("集中モード"))
        .accessibilityValue(focusCardSummary)
    }

    /// 閉じたまま状態が分かる1行サマリー。スケジュールカードと同じ思想で、
    /// 最も情報量の多い状態を1つだけ見せる。
    private var focusCardSummary: String {
        guard model.focusFilterIntegrationEnabled else {
            return model.localizedString("オフ")
        }
        guard !model.focusModes.isEmpty else {
            return model.localizedString("フルディスクアクセスが必要")
        }
        if let activeID = model.activeFocusModeID,
           model.focusModeAssignments[activeID] != nil,
           let mode = model.focusModes.first(where: { $0.id == activeID })
        {
            return String(
                format: model.localizedString("適用中: %@"), model.focusModeDisplayName(mode)
            )
        }
        let count = model.focusModeAssignments.count
        guard count > 0 else {
            return model.localizedString("未設定")
        }
        return String(format: model.localizedString("%d件の割り当て"), count)
    }

    /// フルディスクアクセス未許可(またはまだ読めていない)ときの案内。
    private var focusModeAccessGuidance: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.localizedString(
                "集中モードごとに表示する壁紙を選べます。macOSは集中モードの情報をアプリに公開しないため、この機能には「フルディスクアクセス」の許可が必要です。"
            ))
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.localizedString("1. 下のボタンからフルディスクアクセスの設定を開く"))
                Text(model.localizedString("2. 一覧にこのAppを追加してスイッチをオンにする"))
                Text(model.localizedString("3. このAppを再起動する"))
            }
            .font(.caption2)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Button(model.localizedString("フルディスクアクセスの設定を開く")) {
                openFullDiskAccessSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var focusModeAssignmentList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.localizedString("集中モードごとに表示する壁紙を選べます。"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.focusModes) { mode in
                focusModeRow(mode)
            }
        }
    }

    /// DBのsymbolImageNameはSF Symbolsに存在しない名前のことがある(存在しないと
    /// Image(systemName:)は何も描画せず行のアイコンだけ欠ける)ため、実在確認して
    /// フォールバックする。
    private func focusModeSymbol(_ mode: FocusMode) -> String {
        if let name = mode.symbolName,
           NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        {
            return name
        }
        return "moon.fill"
    }

    private func focusModeRow(_ mode: FocusMode) -> some View {
        HStack(spacing: 6) {
            Image(systemName: focusModeSymbol(mode))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 16)
            Text(model.focusModeDisplayName(mode))
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            if model.activeFocusModeID == mode.id {
                Text(model.localizedString("適用中"))
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    .foregroundColor(.accentColor)
            }
            Spacer(minLength: 8)
            focusModeTargetPickerButton(mode)
        }
    }

    // MARK: - 割り当て壁紙ピッカー

    private func focusModeTargetLabel(_ modeID: String) -> String {
        guard let target = model.focusModeAssignments[modeID] else {
            return model.localizedString("変更しない")
        }
        switch target.kind {
        case .video:
            guard let path = target.videoPath, !path.isEmpty else {
                return model.localizedString("変更しない")
            }
            return model.registeredVideoDisplayNames[path] ?? (path as NSString).lastPathComponent
        case .web:
            guard let id = target.webWallpaperID,
                  let source = model.webWallpaperSources.first(where: { $0.id == id })
            else {
                return model.localizedString("変更しない")
            }
            return source.displayName
        }
    }

    private func focusModeTargetPickerButton(_ mode: FocusMode) -> some View {
        Button {
            scheduleTargetPickerContext = .focusMode(mode.id)
        } label: {
            Text(focusModeTargetLabel(mode.id))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .popover(
            isPresented: focusModeTargetPickerBinding(for: mode.id), arrowEdge: .bottom
        ) {
            focusModeTargetPickerPopover(modeID: mode.id)
        }
    }

    private func focusModeTargetPickerBinding(for modeID: String) -> Binding<Bool> {
        Binding<Bool>(
            get: { scheduleTargetPickerContext == .focusMode(modeID) },
            set: { isPresented in
                scheduleTargetPickerContext = isPresented ? .focusMode(modeID) : nil
            }
        )
    }

    @ViewBuilder
    private func focusModeTargetPickerPopover(modeID: String) -> some View {
        let cardWidth: CGFloat = 120
        let assignment = model.focusModeAssignments[modeID]
        VStack(spacing: 0) {
            // 「変更しない」= 割り当て解除。スケジュールルールと違い、集中モードには
            // 「そのモード中は何もしない」という選択肢が要る。
            Button {
                model.setFocusModeAssignment(nil, forModeID: modeID)
                scheduleTargetPickerContext = nil
            } label: {
                HStack {
                    Image(systemName: assignment == nil ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(assignment == nil ? .accentColor : .secondary)
                    Text(model.localizedString("変更しない"))
                        .font(.caption)
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            Divider()
            if model.libraryVideoPaths.isEmpty, model.webWallpaperSources.isEmpty {
                Text(model.localizedString("先に上の一覧から動画を追加してください"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(width: 280)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: cardWidth), spacing: 8)], spacing: 12
                    ) {
                        ForEach(model.libraryVideoPaths, id: \.self) { path in
                            wallpaperCard(
                                path: path,
                                cardWidth: cardWidth,
                                switchToWallpaperTabOnSelect: false,
                                isSelected: assignment?.kind == .video
                                    && assignment?.videoPath == path,
                                onSelect: {
                                    model.setFocusModeAssignment(.video(path), forModeID: modeID)
                                    scheduleTargetPickerContext = nil
                                }
                            )
                        }
                        ForEach(model.webWallpaperSources) { source in
                            focusModeWebTargetButton(
                                source: source, modeID: modeID, assignment: assignment,
                                cardWidth: cardWidth
                            )
                        }
                    }
                    .padding(12)
                }
                .frame(width: 360, height: 300)
            }
        }
    }

    private func focusModeWebTargetButton(
        source: WebWallpaperSource, modeID: String, assignment: ScheduleTarget?,
        cardWidth: CGFloat
    ) -> some View {
        let isSelected = assignment?.kind == .web && assignment?.webWallpaperID == source.id
        return Button {
            model.setFocusModeAssignment(.web(source.id), forModeID: modeID)
            scheduleTargetPickerContext = nil
        } label: {
            VStack(spacing: 4) {
                WebWallpaperThumbnailView(
                    source: source,
                    isActive: isSelected,
                    thumbnailStore: webThumbnailStore,
                    width: cardWidth,
                    height: (cardWidth * 9 / 16).rounded()
                )
                Text(source.displayName)
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    /// 設定タブの検索で集中モード関連のキーワードにヒットしたときの案内行。
    /// 本体は壁紙タブにあるため、ワンクリックでそのタブへ飛ぶ。
    var focusFilterSearchRedirectSection: some View {
        Section {
            Button {
                selectedAssignmentTarget = .desktop
                isFocusCardExpanded = true
                selectedTab = .wallpaper
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "moon.circle")
                        .foregroundColor(.secondary)
                    Text(model.localizedString("集中モードとの連携は「壁紙」タブにあります"))
                        .font(.caption)
                    Spacer()
                    Text(model.localizedString("開く"))
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func openFullDiskAccessSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

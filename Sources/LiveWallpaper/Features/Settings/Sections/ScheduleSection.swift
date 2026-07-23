import SwiftUI

extension SettingsView {
    static let scheduleSearchKeywords: [String] = [
        "スケジュール",
        "システムの外観設定に従う",
        "ライトモード用の壁紙",
        "ダークモード用の壁紙",
        "曜日スケジュール",
        "ルールを追加",
        "終日",
        "毎日",
        "適用中",
        "複製",
    ]

    /// 壁紙タブの一覧ペインの下に置く折りたたみカード。スケジュールはルール自身が
    /// スコープ(共有/画面別/Space別)を持つため、スコープでフィルタされる一覧
    /// ペインのカードには入れず、独立したカードとして「全体に効くもの」に見せる。
    /// 閉じた状態でも現在の状態が分かるよう、ヘッダーに1行サマリーを出す。
    var wallpaperScheduleCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            scheduleCardHeader
            if isScheduleCardExpanded {
                scheduleFollowAppearanceContent
                Divider().opacity(0.35)
                scheduleAdvancedRulesContent
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var scheduleCardHeader: some View {
        HStack(spacing: 8) {
            Label(model.localizedString("スケジュール"), systemImage: "clock.badge")
                .font(.system(size: 12, weight: .semibold))
            Text(scheduleCardSummary)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(isScheduleCardExpanded ? 90 : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                isScheduleCardExpanded.toggle()
            }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(model.localizedString("スケジュール"))
        .accessibilityValue(scheduleCardSummary)
    }

    /// 「適用中: 夜用」>「2件のルールが有効」>「オフ」の順で最も情報量の多い
    /// 状態を1つだけ見せる(閉じたまま展開する理由を減らすのが目的)。
    private var scheduleCardSummary: String {
        let enabledRules = model.scheduleRules.filter(\.isEnabled)
        guard !enabledRules.isEmpty else {
            return model.localizedString("オフ")
        }
        if let active = enabledRules.first(where: { model.isScheduleRuleCurrentlyActive($0.id) }) {
            let name = model.scheduleRuleDisplayName(active.name)
            return String(format: model.localizedString("適用中: %@"), name)
        }
        return String(format: model.localizedString("%d件のルールが有効"), enabledRules.count)
    }

    /// 設定タブの検索でスケジュール関連のキーワードにヒットしたときの案内行。
    /// 本体は壁紙タブへ移動したため、ワンクリックで移動先のカードを展開して開く。
    var scheduleSearchRedirectSection: some View {
        Section {
            Button {
                selectedAssignmentTarget = .desktop
                isScheduleCardExpanded = true
                selectedTab = .wallpaper
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "clock.badge")
                        .foregroundColor(.secondary)
                    Text(model.localizedString("スケジュールは「壁紙」タブに移動しました"))
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

    // MARK: - 簡易UI: システムの外観設定に従う

    private var scheduleFollowAppearanceContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            toggleWithHelp(
                model.localizedString("システムの外観設定に従う"),
                isOn: followSystemAppearanceBinding,
                helpTopic: .scheduleFollowAppearance,
                helpText: model.localizedString(
                    "macOSのダークモードの切り替えに合わせて、共有壁紙をライト用/ダーク用の指定に自動で切り替えます。"
                )
            )
            if model.followSystemAppearanceEnabled {
                scheduleSimpleTargetRow(
                    title: model.localizedString("ライトモード用の壁紙"),
                    ruleID: appearanceRuleID(for: .light)
                )
                scheduleSimpleTargetRow(
                    title: model.localizedString("ダークモード用の壁紙"),
                    ruleID: appearanceRuleID(for: .dark)
                )
            }
        }
    }

    private func scheduleSimpleTargetRow(title: String, ruleID: UUID?) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 150, alignment: .leading)
            if let ruleID {
                scheduleTargetPickerButton(ruleID: ruleID, target: scheduleTargetForRule(ruleID))
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 20)
    }

    /// 簡易UIが作るシステム管理ルールは固定IDで特定する(ユーザーが時刻を編集しても
    /// 昼/夜の対応がずれない。ヒューリスティックな絞り込みはしない)。
    private func appearanceRuleID(for appearance: ScheduleAppearanceCondition) -> UUID? {
        let id = appearance == .dark
            ? WallpaperModel.simpleAppearanceDarkRuleID
            : WallpaperModel.simpleAppearanceLightRuleID
        return model.scheduleRules.contains { $0.id == id } ? id : nil
    }

    private func scheduleTargetForRule(_ ruleID: UUID) -> ScheduleTarget {
        model.scheduleRules.first(where: { $0.id == ruleID })?.target ?? .video("")
    }

    // MARK: - 高度ルールビルダー(曜日スケジュール)

    private var scheduleAdvancedRulesContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                HStack(spacing: 4) {
                    Text(model.localizedString("曜日スケジュール"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    helpIconButton(for: .scheduleAdvancedRules)
                }
                Spacer()
                Button(model.localizedString("ルールを追加")) {
                    let newID = model.addScheduleRule()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        expandedScheduleRuleID = newID
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            helpFootnote(
                for: .scheduleAdvancedRules,
                text: model.localizedString(
                    "曜日・時間帯・外観条件を組み合わせて壁紙の自動切り替えルールを作れます。上にあるルールほど優先され、最初に条件が一致したルールが適用されます。ルールが有効な時間帯中に手動で壁紙を選び直しても、次の時間帯の境界が来るまではその選択が維持されます。"
                )
            )

            let advancedRules = model.scheduleRules.filter { $0.origin == .advanced }
            if advancedRules.isEmpty {
                settingsFootnote(model.localizedString("曜日スケジュールのルールはまだありません"))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(advancedRules.enumerated()), id: \.element.id) { index, rule in
                        scheduleRuleRow(
                            id: rule.id,
                            priority: index + 1,
                            canMoveUp: index > 0,
                            canMoveDown: index < advancedRules.count - 1
                        )
                    }
                }
            }
        }
    }

    /// コンパクトな1行サマリー(優先順位・トグル・名前・条件の要約・適用中バッジ)。
    /// タップで展開してフルエディタを表示する。ルールが増えても一覧性が保てるようにする。
    private func scheduleRuleRow(
        id: UUID, priority: Int, canMoveUp: Bool, canMoveDown: Bool
    ) -> some View {
        let ruleBinding = scheduleRuleBinding(id: id)
        let rule = ruleBinding.wrappedValue
        let isExpanded = expandedScheduleRuleID == id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                scheduleRulePriorityBadge(priority)
                Toggle("", isOn: ruleBinding.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.scheduleRuleDisplayName(rule.name))
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        if rule.isEnabled, model.isScheduleRuleCurrentlyActive(id) {
                            activeScheduleRuleBadge
                        }
                    }
                    Text(scheduleRuleSummary(rule))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expandedScheduleRuleID = isExpanded ? nil : id
                }
            }

            if isExpanded {
                scheduleRuleEditor(
                    ruleBinding: ruleBinding,
                    canMoveUp: canMoveUp,
                    canMoveDown: canMoveDown
                )
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06))
        )
    }

    /// 「上のルールほど優先」というテキスト説明を、一覧を畳んだままでも
    /// 数字で裏付けるためのバッジ。上下移動ボタンだけでは順序が伝わりにくかった。
    private func scheduleRulePriorityBadge(_ priority: Int) -> some View {
        Text("\(priority)")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundColor(.secondary)
            .frame(width: 16, height: 16)
            .background(Circle().fill(Color.secondary.opacity(0.12)))
            .accessibilityLabel(String(format: model.localizedString("優先度 %d"), priority))
    }

    private var activeScheduleRuleBadge: some View {
        Text(model.localizedString("適用中"))
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
            .foregroundColor(.accentColor)
    }

    @ViewBuilder
    private func scheduleRuleEditor(
        ruleBinding: Binding<ScheduleRule>, canMoveUp: Bool, canMoveDown: Bool
    ) -> some View {
        let rule = ruleBinding.wrappedValue
        let id = rule.id
        VStack(alignment: .leading, spacing: 8) {
            // 旧既定名(昼の壁紙など)は編集欄にも訳語で見せる。編集して確定した
            // 時点でその表記が保存され、以降は通常のユーザー命名として扱われる。
            ScheduleRuleNameField(
                ruleID: id,
                initialValue: rule.name.isEmpty ? "" : model.scheduleRuleDisplayName(rule.name),
                placeholder: model.localizedString("ルール名"),
                commit: { ruleBinding.wrappedValue.name = $0 }
            )

            WeekdaySelector(selection: ruleBinding.weekdays, locale: model.appLocale)

            HStack(spacing: 10) {
                Toggle(model.localizedString("終日"), isOn: scheduleAllDayBinding(ruleBinding))
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                if let range = rule.timeRange {
                    DatePicker(
                        "", selection: scheduleTimeBinding(ruleBinding, isStart: true),
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    Text("–")
                    DatePicker(
                        "", selection: scheduleTimeBinding(ruleBinding, isStart: false),
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    if range.start.minutesFromMidnight > range.end.minutesFromMidnight {
                        Text(model.localizedString("(翌日)"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            EqualSegmentedControl(
                options: [
                    (label: model.localizedString("常に"), value: ScheduleAppearanceCondition.any),
                    (label: model.localizedString("ライト"), value: ScheduleAppearanceCondition.light),
                    (label: model.localizedString("ダーク"), value: ScheduleAppearanceCondition.dark)
                ],
                selection: ruleBinding.appearance
            )
            .frame(height: 22)
            .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: 8) {
                scheduleRuleScopePicker(ruleBinding: ruleBinding)
                scheduleTargetPickerButton(ruleID: id, target: rule.target)
            }

            if rule.scope != .shared, rule.target.kind == .web {
                settingsFootnote(
                    model.localizedString("Web壁紙は共有スコープのみで選択できます"), color: .orange
                )
            }

            HStack(spacing: 8) {
                Button {
                    model.moveScheduleRule(id: id, direction: .up)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(!canMoveUp)
                Button {
                    model.moveScheduleRule(id: id, direction: .down)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(!canMoveDown)
                Button {
                    if let newID = model.duplicateScheduleRule(id: id) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            expandedScheduleRuleID = newID
                        }
                    }
                } label: {
                    Label(model.localizedString("複製"), systemImage: "plus.square.on.square")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                Spacer()
                Button(role: .destructive) {
                    scheduleRulePendingDeletionID = id
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .tint(.red)
                .confirmationDialog(
                    model.localizedString("このルールを削除しますか？"),
                    isPresented: scheduleDeleteConfirmationBinding(for: id),
                    titleVisibility: .visible
                ) {
                    Button(model.localizedString("削除"), role: .destructive) {
                        if expandedScheduleRuleID == id {
                            expandedScheduleRuleID = nil
                        }
                        model.removeScheduleRule(id: id)
                    }
                    Button(model.localizedString("キャンセル"), role: .cancel) {}
                } message: {
                    Text(model.scheduleRuleDisplayName(rule.name))
                }
            }
        }
    }

    private func scheduleDeleteConfirmationBinding(for ruleID: UUID) -> Binding<Bool> {
        Binding<Bool>(
            get: { scheduleRulePendingDeletionID == ruleID },
            set: { isPresented in
                scheduleRulePendingDeletionID = isPresented ? ruleID : nil
            }
        )
    }

    // MARK: - サマリー表示

    private func scheduleRuleSummary(_ rule: ScheduleRule) -> String {
        var parts: [String] = [weekdaySummary(rule.weekdays)]
        if let range = rule.timeRange {
            parts.append(timeRangeSummary(range))
        } else {
            parts.append(model.localizedString("終日"))
        }
        if rule.appearance != .any {
            parts.append(model.localizedString(rule.appearance == .dark ? "ダーク" : "ライト"))
        }
        if rule.scope != .shared {
            parts.append(scheduleScopeLabel(rule.scope))
        }
        return parts.joined(separator: " · ") + " → " + scheduleTargetLabel(rule.target)
    }

    /// 連続する曜日を「月–金」のように圧縮する。区切りはWeekdaySelectorと同じ
    /// veryShortWeekdaySymbols を使い、チップ表示と表記を揃える。
    private func weekdaySummary(_ weekdays: Set<Int>) -> String {
        let effective = weekdays.isEmpty ? Set(1 ... 7) : weekdays
        if effective.count == 7 {
            return model.localizedString("毎日")
        }
        let symbols = WeekdaySelector.symbols(for: model.appLocale)
        var runs: [(start: Int, end: Int)] = []
        for day in effective.sorted() {
            if let last = runs.last, day == last.end + 1 {
                runs[runs.count - 1].end = day
            } else {
                runs.append((day, day))
            }
        }
        return runs.map { run in
            if run.start == run.end {
                return symbols[run.start - 1]
            }
            if run.end == run.start + 1 {
                return symbols[run.start - 1] + "・" + symbols[run.end - 1]
            }
            return symbols[run.start - 1] + "–" + symbols[run.end - 1]
        }.joined(separator: "・")
    }

    private func timeRangeSummary(_ range: ScheduleTimeRange) -> String {
        let base = String(
            format: "%d:%02d–%d:%02d",
            range.start.hour, range.start.minute, range.end.hour, range.end.minute
        )
        guard range.start.minutesFromMidnight > range.end.minutesFromMidnight else {
            return base
        }
        return base + " " + model.localizedString("(翌日)")
    }

    // MARK: - スコープピッカー

    private func scheduleRuleScopePicker(ruleBinding: Binding<ScheduleRule>) -> some View {
        // スコープ変更を Picker の onChange ではなく Binding の set 側で処理することで、
        // macOS 13 でも動くようにする(onChange(of:_:) の2引数版は macOS 14+)。
        let scopeBinding = Binding<ScheduleScope>(
            get: { ruleBinding.wrappedValue.scope },
            set: { newScope in
                var rule = ruleBinding.wrappedValue
                rule.scope = newScope
                // Web壁紙には共有スコープ以外の割り当て機構が存在しないため、
                // スコープを共有以外に変えたらターゲットを一旦動画へ戻す。
                if newScope != .shared, rule.target.kind == .web {
                    rule.target = .video(model.libraryVideoPaths.first ?? "")
                }
                model.updateScheduleRule(rule)
            }
        )
        return Menu {
            Picker("", selection: scopeBinding) {
                Label(model.localizedString("共有"), systemImage: "infinity")
                    .tag(ScheduleScope.shared)

                let screens = model.availableDisplayScreens()
                if !screens.isEmpty {
                    Section(model.localizedString("画面")) {
                        ForEach(screens) { screen in
                            Label(screen.name, systemImage: "display")
                                .tag(ScheduleScope.display(screen.id))
                        }
                    }
                }
                if showsSpaceScopeOptions {
                    Section(model.localizedString("仮想デスクトップ")) {
                        ForEach(model.knownDesktopSpaces) { space in
                            Label(desktopSpaceDisplayName(for: space), systemImage: "macwindow")
                                .tag(ScheduleScope.space(space.uuid))
                        }
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "target")
                Text(scheduleScopeLabel(ruleBinding.wrappedValue.scope))
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
    }

    private func scheduleScopeLabel(_ scope: ScheduleScope) -> String {
        switch scope.kind {
        case .shared:
            return model.localizedString("共有")
        case .display:
            guard let screenID = scope.identifier,
                  let screen = model.availableDisplayScreens().first(where: { $0.id == screenID })
            else {
                return model.localizedString("画面")
            }
            return screen.name
        case .space:
            guard let uuid = scope.identifier,
                  let space = model.knownDesktopSpaces.first(where: { $0.uuid == uuid })
            else {
                return model.localizedString("仮想デスクトップ")
            }
            return desktopSpaceDisplayName(for: space)
        }
    }

    // MARK: - ターゲット壁紙ピッカー

    private func scheduleTargetLabel(_ target: ScheduleTarget) -> String {
        switch target.kind {
        case .video:
            guard let path = target.videoPath, !path.isEmpty else {
                return model.localizedString("壁紙を選択")
            }
            return model.registeredVideoDisplayNames[path] ?? (path as NSString).lastPathComponent
        case .web:
            guard let id = target.webWallpaperID,
                  let source = model.webWallpaperSources.first(where: { $0.id == id })
            else {
                return model.localizedString("壁紙を選択")
            }
            return source.displayName
        }
    }

    private func scheduleTargetPickerButton(ruleID: UUID, target: ScheduleTarget) -> some View {
        Button {
            scheduleTargetPickerContext = .rule(ruleID)
        } label: {
            HStack(spacing: 5) {
                scheduleTargetThumbnail(target)
                Text(scheduleTargetLabel(target))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 160)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .popover(isPresented: scheduleTargetPickerBinding(for: ruleID), arrowEdge: .bottom) {
            scheduleTargetPickerPopover(ruleID: ruleID)
        }
    }

    /// ターゲットボタンにファイル名だけでなく見た目のヒントを添える。ファイル名の
    /// 判読だけでどの動画か思い出すのが難しかったため、サムネイルで視覚的に判断できるようにする。
    @ViewBuilder
    private func scheduleTargetThumbnail(_ target: ScheduleTarget) -> some View {
        let size = CGSize(width: 22, height: 14)
        switch target.kind {
        case .video:
            if let path = target.videoPath, !path.isEmpty {
                Group {
                    if let image = thumbnailCache.image(for: path) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: size.width, height: size.height)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    } else {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.15))
                            .frame(width: size.width, height: size.height)
                            .overlay(Image(systemName: "film").font(.system(size: 8)))
                    }
                }
                .onAppear { requestWallpaperThumbnail(path: path) }
            } else {
                Image(systemName: "film")
            }
        case .web:
            if let id = target.webWallpaperID,
               let source = model.webWallpaperSources.first(where: { $0.id == id })
            {
                WebWallpaperThumbnailView(
                    source: source,
                    isActive: false,
                    thumbnailStore: webThumbnailStore,
                    width: size.width,
                    height: size.height
                )
            } else {
                Image(systemName: "globe")
            }
        }
    }

    private func scheduleTargetPickerBinding(for ruleID: UUID) -> Binding<Bool> {
        Binding<Bool>(
            get: { scheduleTargetPickerContext == .rule(ruleID) },
            set: { isPresented in
                scheduleTargetPickerContext = isPresented ? .rule(ruleID) : nil
            }
        )
    }

    @ViewBuilder
    private func scheduleTargetPickerPopover(ruleID: UUID) -> some View {
        if let rule = model.scheduleRules.first(where: { $0.id == ruleID }) {
            let allowsWeb = rule.scope == .shared
            let cardWidth: CGFloat = 120
            if model.libraryVideoPaths.isEmpty, !allowsWeb || model.webWallpaperSources.isEmpty {
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
                                isSelected: rule.target.kind == .video && rule.target
                                    .videoPath == path,
                                onSelect: {
                                    model.updateScheduleRule(scheduleRule(
                                        rule,
                                        withTarget: .video(path)
                                    ))
                                    scheduleTargetPickerContext = nil
                                }
                            )
                        }
                        if allowsWeb {
                            ForEach(model.webWallpaperSources) { source in
                                scheduleWebTargetButton(
                                    source: source,
                                    rule: rule,
                                    cardWidth: cardWidth
                                )
                            }
                        }
                    }
                    .padding(12)
                }
                .frame(width: 360, height: 320)
            }
        } else {
            EmptyView()
        }
    }

    private func scheduleWebTargetButton(
        source: WebWallpaperSource, rule: ScheduleRule, cardWidth: CGFloat
    ) -> some View {
        let isSelected = rule.target.kind == .web && rule.target.webWallpaperID == source.id
        return Button {
            model.updateScheduleRule(scheduleRule(rule, withTarget: .web(source.id)))
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

    private func scheduleRule(
        _ rule: ScheduleRule,
        withTarget target: ScheduleTarget
    ) -> ScheduleRule {
        var copy = rule
        copy.target = target
        return copy
    }

    // MARK: - Binding ヘルパー

    private func scheduleRuleBinding(id: UUID) -> Binding<ScheduleRule> {
        Binding<ScheduleRule>(
            get: {
                model.scheduleRules.first(where: { $0.id == id })
                    ?? ScheduleRule(id: id, name: "", target: .video(""))
            },
            set: { model.updateScheduleRule($0) }
        )
    }

    private func scheduleAllDayBinding(_ ruleBinding: Binding<ScheduleRule>) -> Binding<Bool> {
        Binding<Bool>(
            get: { ruleBinding.wrappedValue.timeRange == nil },
            set: { isAllDay in
                if isAllDay {
                    ruleBinding.wrappedValue.timeRange = nil
                } else {
                    ruleBinding.wrappedValue.timeRange = ScheduleTimeRange(
                        start: ScheduleTimeOfDay(hour: 9, minute: 0),
                        end: ScheduleTimeOfDay(hour: 18, minute: 0)
                    )
                }
            }
        )
    }

    /// ScheduleTimeOfDay(時・分のみ)⇄Date の変換。DatePicker(.hourAndMinute)は
    /// Date を要求するため、日付部分は無視できる固定の変換で往復させる。
    private func scheduleDateBinding(
        get: @escaping () -> ScheduleTimeOfDay,
        set: @escaping (ScheduleTimeOfDay) -> Void
    ) -> Binding<Date> {
        Binding<Date>(
            get: {
                let time = get()
                var components = DateComponents()
                components.hour = time.hour
                components.minute = time.minute
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { newDate in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                set(ScheduleTimeOfDay(hour: components.hour ?? 0, minute: components.minute ?? 0))
            }
        )
    }

    private func scheduleTimeBinding(
        _ ruleBinding: Binding<ScheduleRule>,
        isStart: Bool
    ) -> Binding<Date> {
        scheduleDateBinding(
            get: {
                let time = isStart
                    ? ruleBinding.wrappedValue.timeRange?.start
                    : ruleBinding.wrappedValue.timeRange?.end
                return time ?? ScheduleTimeOfDay(hour: 0, minute: 0)
            },
            set: { newTime in
                var range = ruleBinding.wrappedValue.timeRange
                    ?? ScheduleTimeRange(start: newTime, end: newTime)
                if isStart {
                    range.start = newTime
                } else {
                    range.end = newTime
                }
                ruleBinding.wrappedValue.timeRange = range
            }
        )
    }
}

/// ルール名の入力欄。ruleBinding.name に直結させると、1打鍵ごとに
/// model.scheduleRules 全体を書き換えて再描画が走り、日本語入力(IME)の
/// 変換中の文字列が壊れて入力が崩れる不具合があった。ローカルの @State を
/// 唯一の描画ソースにし、確定した値だけを commit で親へ伝えることで
/// TextField 自体の再生成を防ぐ。
private struct ScheduleRuleNameField: View {
    let ruleID: UUID
    let placeholder: String
    let commit: (String) -> Void
    @State private var text: String

    init(
        ruleID: UUID, initialValue: String, placeholder: String,
        commit: @escaping (String) -> Void
    ) {
        self.ruleID = ruleID
        self.placeholder = placeholder
        self.commit = commit
        _text = State(initialValue: initialValue)
    }

    var body: some View {
        // grouped Form 配下ではタイトル付き TextField が「左ラベル+中央寄せ値」の
        // フォーム行スタイルになるため、labelsHidden でそれを外して通常の左寄せ
        // 入力欄に戻す。ラベルを隠すとタイトルはプレースホルダにならないので
        // prompt で明示する。
        TextField(placeholder, text: Binding(
            get: { text },
            set: { newValue in
                text = newValue
                commit(newValue)
            }
        ), prompt: Text(placeholder))
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .multilineTextAlignment(.leading)
        .labelsHidden()
        .frame(maxWidth: 220)
        .id(ruleID)
    }
}

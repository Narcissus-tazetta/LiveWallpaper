import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var model: WallpaperModel
    @State var selectedTab: SettingsTab = .wallpaper
    @State var isAdvancedSettingsPresented: Bool = false
    @State var expandedHelpTopics: Set<HelpTopic> = []
    @State var hoveredHelpTopic: HelpTopic?
    @StateObject var thumbnailCache: DiskThumbnailCache
    @StateObject var webThumbnailStore: WebWallpaperThumbnailStore
    /// プレイリスト/動画/Web壁紙の名前編集は同じ形の状態(識別子+入力文字列)を
    /// 3箇所で使うため、`InlineNameEdit<ID>`(Support/InlineNameEdit.swift)へ
    /// 共通化してある。
    @State var playlistNameEdit: InlineNameEdit<UUID>?
    @State var wallpaperNameEdit: InlineNameEdit<String>?
    @State var isDropTargeted: Bool = false
    @State var selectedAssignmentTarget: WallpaperAssignmentTarget = .desktop
    /// 「デスクトップ」タブが今見せているスコープ(共有 / 画面別 / Space別)。
    /// 画面が外れた・Space機能がOFFになったなど、選択中のスコープが消えたときは
    /// 読み取り側で無視するのではなく pruneStaleScope() が .shared を書き戻す。
    /// 無視するだけだと選択が残り、機能を戻した瞬間に古いスコープへ復帰する。
    @State var selectedScope: WallpaperScope = .shared
    @StateObject var fitEditor: FitEditorController
    @StateObject var wallpaperEditor: WallpaperEditorController
    @StateObject var storeCatalog: StoreCatalogController
    @StateObject var storeMySubmissions: StoreMySubmissionsController
    @StateObject var remoteThumbnailCache: RemoteThumbnailCache
    @State var editorSubMode: EditorSubMode = .fit
    /// 「他の壁紙へコピー」ピッカーの状態。
    @State var isTrimCopyPickerPresented: Bool = false
    @State var trimCopySelection: Set<String> = []
    @State var trimCopySearchText: String = ""
    @State var isResetSettingsDialogPresented: Bool = false
    @State var librarySearchText: String = ""
    @State var isWallpaperShareSheetPresented: Bool = false
    @State var isStoreSharePickerPresented: Bool = false
    @State var isStoreShareSheetPresented: Bool = false
    @State var storeTabMode: StoreTabMode = .browse
    /// Storeへの共有シートが対象にしている動画。共有シートはトリム編集タブの選択状態
    /// (wallpaperEditor.selectedVideoPath)には依存しない — 右クリックメニューや
    /// Storeタブのピッカーなど、編集タブを開かずに共有を始めた場合でも、選んだ動画を
    /// 誤りなく送るため専用の状態として保持する。
    @State var storeShareTargetPath: String?
    @State var storeShareTitle: String = ""
    @State var storeShareAuthor: String = ""
    @State var storeShareLicense: String = ""
    @State var storeShareStatus: StoreShareStatus = .idle
    @State var isSuspendExclusionAppPickerPresented: Bool = false
    @State var suspendExclusionAppPickerSearchText: String = ""
    @State var storeReportTargetEntry: StoreEntry?
    /// 取り下げ確認ダイアログを出している「自分の投稿」。誤タップでの即時取り下げを
    /// 防ぐため、ゴミ箱ボタンでは即実行せずここに立ててからダイアログで確定させる。
    @State var storeWithdrawTargetSubmission: StoreMySubmission?
    @State var currentWallpaperPreviewThumbnailPath: String?
    @State var currentLockScreenPreviewThumbnailPath: String?
    @State var webURLInput: String = ""
    @State var isWebWallpaperURLPopoverPresented: Bool = false
    @State var isEmptyStateWebPopoverPresented: Bool = false
    @State var webWallpaperNameEdit: InlineNameEdit<UUID>?
    @FocusState var focusedPlaylistID: UUID?
    @FocusState var focusedWallpaperPath: String?
    @FocusState var focusedWebWallpaperID: UUID?
    @FocusState var isLibrarySearchFocused: Bool
    @State var settingsSearchText: String = ""
    @FocusState var isSettingsSearchFocused: Bool
    @FocusState var isStoreSearchFocused: Bool
    @FocusState var isSuspendExclusionSearchFocused: Bool
    @FocusState var isTrimCopySearchFocused: Bool
    /// スケジュールのターゲット壁紙ピッカーを開いている対象(ルールIDまたは簡易UIの
    /// 固定キー)。nil ならどのポップオーバーも表示しない。
    @State var scheduleTargetPickerContext: ScheduleTargetPickerContext?
    /// 曜日スケジュールで編集用に展開中のルール。nil なら全行がコンパクト表示。
    @State var expandedScheduleRuleID: UUID?
    /// 削除確認ダイアログを出しているルール。誤タップでのルール消失を防ぐため、
    /// ゴミ箱ボタンでは即削除せずここに立ててからダイアログで確定させる。
    @State var scheduleRulePendingDeletionID: UUID?
    /// 壁紙タブのスケジュールカードの開閉。既定は閉(1行サマリーのみ)で、
    /// 設定検索の案内行から飛んできたときは開いた状態にする。
    @State var isScheduleCardExpanded: Bool = false
    @State var isFocusCardExpanded: Bool = false
    @State var hoveredTab: SettingsTab?
    @State var hoveredWallpaperPath: String?
    /// Card whose video is playing on hover. Separate from hoveredWallpaperPath so a quick
    /// pass of the pointer across the grid doesn't spin up a player for every card.
    @State var hoverPreviewPath: String?
    @State var settingsCategory: SettingsCategory = .general
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    @Environment(\.colorSchemeContrast) var colorSchemeContrast
    @Namespace var tabSelectionNamespace
    let wallpaperCardMinimumWidth: CGFloat = 140
    let wallpaperCardMaximumWidth: CGFloat = 220
    let wallpaperGridColumnSpacing: CGFloat = 6
    let wallpaperGridRowSpacing: CGFloat = 12

    init(model: WallpaperModel) {
        self.model = model
        _thumbnailCache = StateObject(wrappedValue: DiskThumbnailCache())
        _webThumbnailStore = StateObject(wrappedValue: WebWallpaperThumbnailStore())
        _fitEditor = StateObject(wrappedValue: FitEditorController(model: model))
        _wallpaperEditor = StateObject(wrappedValue: WallpaperEditorController(model: model))
        _storeCatalog = StateObject(wrappedValue: StoreCatalogController())
        _storeMySubmissions = StateObject(wrappedValue: StoreMySubmissionsController())
        _remoteThumbnailCache = StateObject(wrappedValue: RemoteThumbnailCache())
    }

    func wallpaperGridLayout(for availableWidth: CGFloat) -> ([GridItem], CGFloat) {
        let width = max(availableWidth, wallpaperCardMinimumWidth)
        let rawCount = Int(
            (width + wallpaperGridColumnSpacing)
                / (wallpaperCardMinimumWidth + wallpaperGridColumnSpacing)
        )
        let columnCount = max(rawCount, 1)
        let totalSpacing = wallpaperGridColumnSpacing * CGFloat(columnCount - 1)
        let computedWidth = floor((width - totalSpacing) / CGFloat(columnCount))
        let cardWidth = min(
            max(computedWidth, wallpaperCardMinimumWidth),
            wallpaperCardMaximumWidth
        )
        let columns = Array(
            repeating: GridItem(.fixed(cardWidth), spacing: wallpaperGridColumnSpacing),
            count: columnCount
        )
        return (columns, cardWidth)
    }

    var body: some View {
        let content = VStack(spacing: 0) {
            tabBar
            Divider()
            tabContent
        }
        .background(ambientBackground)

        let modified1 = applyMainModifiers(content)
        let modified2 = applyNotificationAndChangeModifiers(modified1)
        let modified3 = applyLifecycleModifiers(modified2)
        return applyDialogAndSheetModifiers(modified3)
    }

    private func applyMainModifiers<V: View>(_ view: V) -> some View {
        view
            .frame(
                minWidth: 780, idealWidth: 780, maxWidth: .infinity,
                minHeight: 540, idealHeight: 540, maxHeight: .infinity
            )
            .overlay {
                if isDropTargeted {
                    dropTargetOverlay
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isDropTargeted)
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDroppedVideoProviders(providers)
            }
            .background(InitialFocusSink().frame(width: 0, height: 0))
    }

    private func applyNotificationAndChangeModifiers<V: View>(_ view: V) -> some View {
        view
            .onChange(of: model.webWallpaperSources) { sources in
                webThumbnailStore.prune(validSourceIDs: Set(sources.map(\.id)))
                if let editingID = webWallpaperNameEdit?.id,
                   !sources.contains(where: { $0.id == editingID })
                {
                    cancelWebWallpaperNameEdit()
                }
            }
            .onChange(of: model.registeredVideoPaths) { _ in
                pruneMissingWallpaperThumbnails()
            }
            .onChange(of: model.playlists) { _ in
                pruneMissingWallpaperThumbnails()
                guard let editingID = playlistNameEdit?.id else {
                    return
                }
                if !model.playlists.contains(where: { $0.id == editingID }) {
                    cancelPlaylistNameEdit()
                }
            }
            .onChange(of: model.selectedPlaylistID) { _ in
                resetLibrarySearchState()
            }
            // スコープの土台が動いたら選択を畳む。画面を外す・Space機能をOFFにする
            // ・Space を消す、のどれでも「消えたスコープを選んだまま」にしない。
            .onChange(of: model.displayScreens) { _ in
                pruneStaleScope()
                fitEditor.ensureScreenSelection()
            }
            .onChange(of: model.knownDesktopSpaces) { _ in
                pruneStaleScope()
            }
            .onChange(of: model.spaceWallpaperFeatureEnabled) { _ in
                pruneStaleScope()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openWallpaperTab)) { _ in
                selectedTab = .wallpaper
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsTab)) { _ in
                selectedTab = .settings
            }
            .onReceive(NotificationCenter.default.publisher(for: .openWallpaperFitTab)) { _ in
                selectedTab = .wallpaperFit
            }
            .onReceive(NotificationCenter.default.publisher(for: .openWallpaperShareSheet)) { _ in
                selectedTab = .wallpaper
                isWallpaperShareSheetPresented = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .thumbnailCacheDidClear)) { _ in
                thumbnailCache.clear()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.refreshDesktopIconsVisibility()
                model.refreshScreenRecordingTrustForCoverage()
            }
            .onChange(of: selectedTab) { tab in
                resetLibrarySearchState()
                settingsSearchText = ""
                isSettingsSearchFocused = false
                if tab == .settings {
                    model.refreshDesktopIconsVisibility()
                }
                if tab == .wallpaperFit {
                    fitEditor.activate()
                    wallpaperEditor.activate()
                    syncEditorSubMode()
                } else {
                    fitEditor.deactivate()
                    wallpaperEditor.deactivate()
                }
            }
            // キーボード操作(矢印キー)はフィット編集とトリム編集の両方が使う。
            // 両者とも「編集」タブで同時に activate されるため、前面にいる方だけが
            // キーを拾うようサブモードを伝える。
            .onChange(of: editorSubMode) { _ in
                syncEditorSubMode()
            }
            .onChange(of: model.lockScreenVideoPath) { _ in
                requestLockScreenWallpaperThumbnailIfNeeded()
            }
            .onChange(of: model.currentVideoPath) { _ in
                requestCurrentWallpaperThumbnailIfNeeded()
                fitEditor.handleCurrentVideoPathChange()
                wallpaperEditor.handleCurrentVideoPathChange()
            }
            .onChange(of: model.currentWebWallpaperID) { _ in
                if let source = model.activeWebWallpaperSource {
                    webThumbnailStore.loadIfNeeded(for: source)
                }
            }
    }

    /// 「編集」タブの前面がフィットかトリムかを両コントローラへ伝える。
    func syncEditorSubMode() {
        fitEditor.setSubModeActive(editorSubMode == .fit)
        wallpaperEditor.setSubModeActive(editorSubMode == .trim)
    }

    private func applyLifecycleModifiers<V: View>(_ view: V) -> some View {
        view
            .onAppear {
                pruneMissingWallpaperThumbnails()
                requestCurrentWallpaperThumbnailIfNeeded()
                requestLockScreenWallpaperThumbnailIfNeeded()
                model.refreshScreenRecordingTrustForCoverage()
                thumbnailCache.prewarm(paths: Array(model.allRegisteredVideoPaths.prefix(10)))
                processThumbnailQueue()
                if selectedTab == .wallpaperFit {
                    fitEditor.activate()
                    wallpaperEditor.activate()
                    syncEditorSubMode()
                }
            }
            .onDisappear {
                releaseCurrentWallpaperThumbnailVisibility()
                releaseLockScreenWallpaperThumbnailVisibility()
                fitEditor.deactivate()
                wallpaperEditor.deactivate()
            }
    }

    private func applyDialogAndSheetModifiers<V: View>(_ view: V) -> some View {
        view
            .sheet(isPresented: $isWallpaperShareSheetPresented) {
                shareWallpaperPickerSheet
            }
            .sheet(isPresented: $isStoreSharePickerPresented) {
                storeSharePickerSheet
            }
            .sheet(isPresented: $isStoreShareSheetPresented) {
                storeShareSheet
            }
            .confirmationDialog(
                model.localizedString("設定を初期化"),
                isPresented: $isResetSettingsDialogPresented,
                titleVisibility: .visible
            ) {
                Button(model.localizedString("リセット"), role: .destructive) {
                    model.resetSettingsToDefaults()
                }
                Button(model.localizedString("キャンセル"), role: .cancel) {}
            } message: {
                Text(model.localizedString("表示・再生に関する設定を初期値へ戻します"))
            }
            .confirmationDialog(
                model.localizedString("この動画を通報"),
                isPresented: Binding(
                    get: { storeReportTargetEntry != nil },
                    set: { if !$0 { storeReportTargetEntry = nil } }
                ),
                titleVisibility: .visible
            ) {
                ForEach(StoreReportReason.allCases) { reason in
                    Button(model.localizedString(reason.localizationKey)) {
                        if let entry = storeReportTargetEntry {
                            Task {
                                await storeCatalog.report(entry: entry, reason: reason.localizationKey)
                            }
                        }
                        storeReportTargetEntry = nil
                    }
                }
                Button(model.localizedString("キャンセル"), role: .cancel) {
                    storeReportTargetEntry = nil
                }
            } message: {
                if let entry = storeReportTargetEntry {
                    Text(entry.title)
                } else {
                    Text(model.localizedString("通報の理由を選択してください"))
                }
            }
            .confirmationDialog(
                model.localizedString("投稿を取り下げますか?"),
                isPresented: Binding(
                    get: { storeWithdrawTargetSubmission != nil },
                    set: { if !$0 { storeWithdrawTargetSubmission = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(model.localizedString("取り下げる"), role: .destructive) {
                    if let submission = storeWithdrawTargetSubmission {
                        Task {
                            await storeMySubmissions.withdraw(id: submission.id)
                        }
                    }
                    storeWithdrawTargetSubmission = nil
                }
                Button(model.localizedString("キャンセル"), role: .cancel) {
                    storeWithdrawTargetSubmission = nil
                }
            } message: {
                if let submission = storeWithdrawTargetSubmission {
                    Text(submission.title)
                } else {
                    Text(model.localizedString("この操作は取り消せません"))
                }
            }
            // トリム編集の未保存確認は、フィット編集サブモード表示中でも
            // ライブラリからの動画選択で発生しうる(`FitLibraryPanel.selectEditorVideo`)。
            // `wallpaperTrimEditorPanel` はトリムサブモードのときしかツリーに乗らないため、
            // そこに付けるとフィット編集中は確認ダイアログが一切出ず、選択が
            // 無反応に見えてしまう。常にマウントされるこの階層へ置く。
            .confirmationDialog(
                model.localizedString("未保存のトリム編集があります"),
                isPresented: Binding(
                    get: { wallpaperEditor.pendingSelectionPath != nil },
                    set: { presented in
                        if !presented {
                            wallpaperEditor.cancelPendingSelection()
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button(model.localizedString("保存して切り替える")) {
                    confirmTrimEditorSelectionChange(savingFirst: true)
                }
                Button(model.localizedString("破棄して切り替える"), role: .destructive) {
                    confirmTrimEditorSelectionChange(savingFirst: false)
                }
                Button(model.localizedString("キャンセル"), role: .cancel) {
                    wallpaperEditor.cancelPendingSelection()
                }
            } message: {
                Text(model.localizedString("別の壁紙に切り替えると、編集中の内容は失われます"))
            }
    }

    /// 確認ダイアログで切り替えを確定したとき。トリム側の選択が動いた後、
    /// 保留していたフィット編集の選択も追従させる(`selectEditorVideo` は
    /// 確認待ちの間フィット側を止めている)。
    private func confirmTrimEditorSelectionChange(savingFirst: Bool) {
        let pending = wallpaperEditor.pendingSelectionPath
        wallpaperEditor.confirmPendingSelection(savingFirst: savingFirst)
        if let pending {
            fitEditor.selectVideo(path: pending)
        }
    }

    /// macOS の設定ウィンドウと同じ、アイコンの下にラベルを置くツールバー型のタブ。
    private var tabBar: some View {
        HStack(spacing: 4) {
            tabButton(
                .wallpaper,
                title: model.localizedString("壁紙"),
                systemImage: "photo.on.rectangle.angled"
            )
            tabButton(
                .wallpaperFit,
                title: model.localizedString("編集"),
                systemImage: "crop"
            )
            tabButton(
                .store,
                title: model.localizedString("Store"),
                systemImage: "bag"
            )
            tabButton(
                .settings,
                title: model.localizedString("設定"),
                systemImage: "gearshape"
            )
        }
        .padding(.top, 2)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .trailing) {
            if selectedTab == .wallpaper {
                libraryToolbarItems
                    .padding(.trailing, 14)
                    .padding(.bottom, 6)
            }
        }
        // Animate only the highlight; wrapping the tab switch in withAnimation would
        // also animate the whole incoming tab (video previews, the wallpaper grid).
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selectedTab)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .wallpaper:
            tabScrollPane {
                wallpaperTargetTabBar
                wallpaperContentPane

                // 集中モード連携・スケジュールのターゲットはデスクトップ壁紙のみの
                // ため、ロック画面タブでは出さない。
                if selectedAssignmentTarget == .desktop {
                    wallpaperFocusFilterCard
                    wallpaperScheduleCard
                }
            }
            .background(
                Button("") { isLibrarySearchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .hidden()
            )
        case .wallpaperFit:
            tabScrollPane {
                Picker(model.localizedString("編集"), selection: $editorSubMode) {
                    Text(model.localizedString("フィット編集")).tag(EditorSubMode.fit)
                    Text(model.localizedString("トリム編集")).tag(EditorSubMode.trim)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
                .frame(maxWidth: .infinity)

                switch editorSubMode {
                case .fit:
                    wallpaperFitEditorPanel
                case .trim:
                    wallpaperTrimEditorPanel
                }
                wallpaperFitLibraryPanel
            }
        case .store:
            tabScrollPane {
                storeTabContent
            }
        case .settings:
            HStack(spacing: 0) {
                settingsSidebar
                    .frame(width: 210)
                Divider()
                settingsForm
            }
        }
    }

    private var settingsForm: some View {
        Form {
            if !isSettingsSearchActive {
                settingsPaneHeader
            }
            Group {
                if let message = model.persistenceFailureMessage {
                    Section {
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if settingsSectionVisible(.video) {
                    videoSettingsSection
                    settingsSectionMatchHint(.video)
                }
                if settingsSectionVisible(.share) {
                    shareSettingsSection
                    settingsSectionMatchHint(.share)
                }
                if settingsSectionVisible(.webWallpaper) {
                    webWallpaperSettingsSection
                    settingsSectionMatchHint(.webWallpaper)
                }
                if settingsSectionVisible(.display) {
                    displaySettingsSection
                    settingsSectionMatchHint(.display)
                }
                if settingsSectionVisible(.hotKeys) {
                    hotKeysSettingsSection
                    settingsSectionMatchHint(.hotKeys)
                }
                // スケジュール本体は壁紙タブへ移動済み。検索でヒットしたとき
                // だけ案内行を出す(非検索時は何も出さない)。
                if isSettingsSearchActive, settingsSectionMatches(.schedule) {
                    scheduleSearchRedirectSection
                }
                if isSettingsSearchActive, settingsSectionMatches(.focusFilter) {
                    focusFilterSearchRedirectSection
                }
                if settingsSectionVisible(.language) {
                    languageSettingsSection
                    settingsSectionMatchHint(.language)
                }
                if settingsSectionVisible(.cache) {
                    cacheSettingsSection
                    settingsSectionMatchHint(.cache)
                }
            }
            Group {
                if settingsSectionVisible(.screenSaver) {
                    screenSaverSettingsSection
                    settingsSectionMatchHint(.screenSaver)
                }
                if settingsSectionVisible(.reset) {
                    resetSettingsSection
                    settingsSectionMatchHint(.reset)
                }
                if settingsSectionVisible(.support) {
                    supportSettingsSection
                    settingsSectionMatchHint(.support)
                }
                if settingsSectionVisible(.update) {
                    updateSettingsSection
                    settingsSectionMatchHint(.update)
                }
                if isSettingsSearchActive, !anySettingsSectionMatches {
                    Section {
                        SearchEmptyState(
                            isSearchActive: true,
                            noContentText: "",
                            noMatchText: model.localizedString("該当する設定がありません"),
                            clearButtonTitle: model.localizedString("検索をクリア"),
                            onClearSearch: { settingsSearchText = ""; isSettingsSearchFocused = true }
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            footerSection
        }
        .formStyle(.grouped)
        .environment(
            \.settingsPaneTitle,
            isSettingsSearchActive ? nil : model.localizedString(settingsCategory.titleKey)
        )
        #if DEBUG
        .onAppear { SettingsView.assertAllSettingsSectionsHaveSearchKeywords() }
        #endif
    }

    /// 壁紙・編集・Store は各パネルが自前のカードで区切られているため、grouped Form の
    /// セクションに入れず直接並べる(Form に入れるとカードが二重の箱になる)。
    private func tabScrollPane<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content()
                footerCreditText
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private var footerSection: some View {
        Section {
            footerCreditText
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var footerCreditText: Text {
        var authorName = AttributedString("Narcissus-tazetta")
        authorName.link = URL(string: "https://github.com/Narcissus-tazetta/LiveWallpaper")
        authorName.foregroundColor = .secondary
        let year = String(Calendar.current.component(.year, from: Date()))
        return Text("©︎") + Text(authorName) + Text(" \(year)  •  v\(model.currentAppVersion())")
    }
}

import AppKit
import Carbon.HIToolbox
import SwiftUI

extension SettingsView {
    static let hotKeysSearchKeywords: [String] = [
        "グローバルショートカット",
        "グローバルショートカットを有効にする",
        "ショートカット",
        "ホットキー",
        "キーボードショートカット",
        "次の壁紙に切り替え",
        "前の壁紙に切り替え",
        "音声のオン/オフ",
        "デスクトップアイコンの表示/非表示",
    ]

    @ViewBuilder
    var hotKeysSettingsSection: some View {
        Section(
            header: Label(model.localizedString("グローバルショートカット"), systemImage: "keyboard")
        ) {
            Toggle(
                model.localizedString("グローバルショートカットを有効にする"),
                isOn: hotKeysEnabledBinding
            )
            settingsFootnote(
                model.localizedString(
                    "アプリが前面になくても、システム全体でキー操作を受け付けます。既存のショートカットと重複しない組み合わせを割り当ててください。"
                )
            )

            if model.hotKeysEnabled {
                settingsInsetCard {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(HotKeyAction.allCases, id: \.self) { action in
                            hotKeyRow(for: action)
                            if action != HotKeyAction.allCases.last {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func hotKeyRow(for action: HotKeyAction) -> some View {
        HStack(spacing: 12) {
            Text(model.localizedString(action.localizationKey))
                .frame(maxWidth: .infinity, alignment: .leading)

            HotKeyRecorderField(
                combo: model.hotKeyCombo(for: action),
                emptyPlaceholder: model.localizedString("未設定"),
                recordingPlaceholder: model.localizedString("キーを入力…"),
                onChange: { newCombo in
                    model.setHotKeyCombo(newCombo, for: action)
                }
            )
            .frame(width: 170)

            Button {
                model.resetHotKeyCombo(for: action)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .help(model.localizedString("既定に戻す"))
        }
        if model.hotKeyRegistrationFailures.contains(action) {
            settingsFootnote(
                model.localizedString("このショートカットは他のアプリまたはシステムと重複しているため無効です。"),
                color: .orange
            )
        }
    }
}

/// キーコンビネーションを録音する SwiftUI フィールド。クリックで録音を開始し、
/// 次に押された「修飾キー + キー」を割り当てる。Esc でキャンセル、Delete で消去。
struct HotKeyRecorderField: NSViewRepresentable {
    var combo: HotKeyCombo?
    var emptyPlaceholder: String
    var recordingPlaceholder: String
    var onChange: (HotKeyCombo?) -> Void

    func makeNSView(context _: Context) -> HotKeyRecorderButton {
        let button = HotKeyRecorderButton()
        button.emptyPlaceholder = emptyPlaceholder
        button.recordingPlaceholder = recordingPlaceholder
        button.onChange = onChange
        button.currentCombo = combo
        button.refreshTitle()
        return button
    }

    func updateNSView(_ button: HotKeyRecorderButton, context _: Context) {
        button.emptyPlaceholder = emptyPlaceholder
        button.recordingPlaceholder = recordingPlaceholder
        button.onChange = onChange
        // 録音中はユーザー入力を優先し、外側の値で上書きしない。
        if !button.isRecordingActive {
            button.currentCombo = combo
            button.refreshTitle()
        }
    }
}

@MainActor
final class HotKeyRecorderButton: NSButton {
    /// 現在録音中の行(常に高々1つ)。設定ウィンドウの既存キー監視
    /// (settingsKeyMonitor、Cmd+W/Cmd+Q をウィンドウを閉じる操作として横取りする)
    /// が、録音中はそれらのキーを素通りさせられるようにするための公開状態でもある。
    static private(set) weak var activeRecorder: HotKeyRecorderButton?

    var currentCombo: HotKeyCombo?
    var onChange: ((HotKeyCombo?) -> Void)?
    var emptyPlaceholder = "未設定"
    var recordingPlaceholder = "キーを入力…"
    private(set) var isRecordingActive = false
    private var monitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func configure() {
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        alignment = .center
        target = self
        action = #selector(toggleRecording)
        refreshTitle()
    }

    func refreshTitle() {
        if isRecordingActive {
            title = recordingPlaceholder
        } else if let currentCombo {
            title = currentCombo.displayString
        } else {
            title = emptyPlaceholder
        }
    }

    @objc private func toggleRecording() {
        if isRecordingActive {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard monitor == nil else {
            return
        }
        // 同時に録音できるのは1行だけ。別の行が録音中なら先にそちらを止め、
        // 2つのローカルモニタが同じキー入力を奪い合わないようにする。
        Self.activeRecorder?.stopRecording()
        Self.activeRecorder = self
        isRecordingActive = true
        refreshTitle()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isRecordingActive else {
                return event
            }
            return self.handleRecordingEvent(event)
        }
    }

    private func stopRecording() {
        isRecordingActive = false
        if Self.activeRecorder === self {
            Self.activeRecorder = nil
        }
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        refreshTitle()
    }

    private func handleRecordingEvent(_ event: NSEvent) -> NSEvent? {
        switch Int(event.keyCode) {
        case kVK_Escape:
            stopRecording()
            return nil
        case kVK_Delete, kVK_ForwardDelete:
            currentCombo = nil
            onChange?(nil)
            stopRecording()
            return nil
        default:
            break
        }

        let carbon = event.modifierFlags.carbonFlags
        // 修飾キーを1つも伴わないキーは、グローバルホットキーとして不適切なので拒否。
        guard carbon != 0 else {
            NSSound.beep()
            return nil
        }
        let combo = HotKeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: carbon)
        currentCombo = combo
        onChange?(combo)
        stopRecording()
        return nil
    }
}

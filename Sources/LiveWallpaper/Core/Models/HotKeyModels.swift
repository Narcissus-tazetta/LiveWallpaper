import AppKit
import Carbon.HIToolbox

/// グローバルホットキーで実行できる操作。rawValue は永続化キー・辞書キーに使う。
enum HotKeyAction: String, CaseIterable, Codable {
    case nextWallpaper
    case previousWallpaper
    case toggleAudio
    case toggleDesktopIcons

    /// 設定UIに出す表示名(ローカライズキー=日本語)。
    var localizationKey: String {
        switch self {
        case .nextWallpaper: return "次の壁紙に切り替え"
        case .previousWallpaper: return "前の壁紙に切り替え"
        case .toggleAudio: return "音声のオン/オフ"
        case .toggleDesktopIcons: return "デスクトップアイコンの表示/非表示"
        }
    }

    /// 有効化時に初期設定として入れる既定の組み合わせ。いずれも ⌃⌥⌘ +
    /// 記号/英字で、システムやアプリの一般的なショートカットと衝突しにくい。
    var defaultCombo: HotKeyCombo {
        // controlKey | optionKey | cmdKey
        let mods = UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey)
        switch self {
        case .nextWallpaper: return HotKeyCombo(keyCode: UInt32(kVK_ANSI_RightBracket), carbonModifiers: mods)
        case .previousWallpaper: return HotKeyCombo(keyCode: UInt32(kVK_ANSI_LeftBracket), carbonModifiers: mods)
        case .toggleAudio: return HotKeyCombo(keyCode: UInt32(kVK_ANSI_M), carbonModifiers: mods)
        case .toggleDesktopIcons: return HotKeyCombo(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: mods)
        }
    }
}

/// キーコード + Carbon 修飾キーマスクの組み合わせ。Carbon の RegisterEventHotKey
/// にそのまま渡せる形で保持する。
struct HotKeyCombo: Equatable, Codable {
    /// 仮想キーコード(NSEvent.keyCode と同値)。
    var keyCode: UInt32
    /// Carbon 修飾キーマスク(cmdKey / optionKey / controlKey / shiftKey の OR)。
    var carbonModifiers: UInt32

    /// 少なくとも1つの修飾キーを含むか。グローバルホットキーとして成立する最低条件。
    var hasModifier: Bool {
        carbonModifiers & (UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey) | UInt32(shiftKey)) != 0
    }

    /// 「⌃⌥⇧⌘N」のような表示文字列。修飾キーは Apple 標準の並び順。
    var displayString: String {
        var result = ""
        if carbonModifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        result += Self.keyName(for: keyCode)
        return result
    }
}

extension HotKeyCombo {
    /// 仮想キーコードを表示用の文字へ。ANSI 配列の主要キーを網羅し、未知の
    /// キーは "?" にフォールバックする。
    static func keyName(for keyCode: UInt32) -> String {
        if let special = specialKeyNames[Int(keyCode)] {
            return special
        }
        if let ansi = ansiKeyNames[Int(keyCode)] {
            return ansi
        }
        return "?"
    }

    private static let ansiKeyNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
    ]

    private static let specialKeyNames: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "␣",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]
}

extension NSEvent.ModifierFlags {
    /// AppKit 修飾フラグを Carbon 修飾マスクへ変換する。
    var carbonFlags: UInt32 {
        var carbon: UInt32 = 0
        if contains(.command) { carbon |= UInt32(cmdKey) }
        if contains(.option) { carbon |= UInt32(optionKey) }
        if contains(.control) { carbon |= UInt32(controlKey) }
        if contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }
}

import CoreFoundation
import Darwin
import Foundation

/// Mission Control の Space(仮想デスクトップ)一覧を取得する非公開APIブリッジ。
///
/// macOS には「今どの Space が表示されているか」を返す公開APIが存在しないため、
/// WhichSpace / yabai / Hammerspoon などが長年使っている
/// `CGSCopyManagedDisplaySpaces` を利用する。ただし将来の macOS でシンボルが
/// 消えてもアプリが起動不能にならないよう、extern 直リンクは行わず
/// dlopen/dlsym で動的解決し、失敗時は `isAvailable = false` に落として
/// 呼び出し側が機能ごと無効化できるようにする。
final class CGSSpacesBridge: @unchecked Sendable {
    private typealias MainConnectionFunction = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpacesFunction =
        @convention(c) (Int32) -> Unmanaged<CFArray>?

    private let mainConnection: MainConnectionFunction?
    private let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFunction?

    /// シンボル解決に成功したかどうか。false のときは全メソッドが nil を返す。
    let isAvailable: Bool

    init() {
        // SkyLight は AppKit 経由でロード済みのことが多いので、まずプロセス全体
        // (RTLD_DEFAULT 相当)から探し、見つからない場合のみ明示的に dlopen する。
        // ハンドルはプロセス生存中保持するので dlclose はしない。
        var handle: UnsafeMutableRawPointer? = dlopen(nil, RTLD_LAZY)
        func resolve(_ symbol: String) -> UnsafeMutableRawPointer? {
            guard let handle else { return nil }
            return dlsym(handle, symbol)
        }

        var connectionSymbol =
            resolve("CGSMainConnectionID") ?? resolve("_CGSDefaultConnection")
        var copySymbol = resolve("CGSCopyManagedDisplaySpaces")

        if connectionSymbol == nil || copySymbol == nil {
            handle = dlopen(
                "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                RTLD_LAZY
            )
            connectionSymbol =
                connectionSymbol ?? resolve("CGSMainConnectionID")
                ?? resolve("_CGSDefaultConnection")
            copySymbol = copySymbol ?? resolve("CGSCopyManagedDisplaySpaces")
        }

        if let connectionSymbol, let copySymbol {
            mainConnection = unsafeBitCast(
                connectionSymbol, to: MainConnectionFunction.self
            )
            copyManagedDisplaySpaces = unsafeBitCast(
                copySymbol, to: CopyManagedDisplaySpacesFunction.self
            )
            isAvailable = true
        } else {
            mainConnection = nil
            copyManagedDisplaySpaces = nil
            isAvailable = false
        }
    }

    /// ディスプレイごとの Space 情報辞書の生配列。取得・キャスト失敗時は nil。
    func rawManagedDisplaySpaces() -> [[String: Any]]? {
        guard let mainConnection, let copyManagedDisplaySpaces else {
            return nil
        }
        guard let unmanaged = copyManagedDisplaySpaces(mainConnection()) else {
            return nil
        }
        // "Copy" 規約なので takeRetainedValue で所有権を引き取る。
        return unmanaged.takeRetainedValue() as? [[String: Any]]
    }
}

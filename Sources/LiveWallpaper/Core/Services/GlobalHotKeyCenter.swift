import AppKit
import Carbon.HIToolbox

/// Carbon の RegisterEventHotKey を薄くラップしたグローバルホットキー管理。
///
/// Carbon 方式を採るのは、アクセシビリティ権限なしでシステム全体のホットキーを
/// 登録でき、押下イベントをメインスレッド(アプリのイベントターゲット)で受け取れる
/// ため。NSEvent のグローバルモニタは Accessibility 権限が必要で用途に合わない。
@MainActor
final class GlobalHotKeyCenter {
    /// 登録済みホットキーの識別に使う4文字シグネチャ('LWhk')。
    private static let signature: OSType = {
        let chars = Array("LWhk".utf8)
        return (OSType(chars[0]) << 24) | (OSType(chars[1]) << 16)
            | (OSType(chars[2]) << 8) | OSType(chars[3])
    }()

    private struct Registration {
        let ref: EventHotKeyRef
        let handler: () -> Void
    }

    private var registrations: [UInt32: Registration] = [:]
    private var eventHandler: EventHandlerRef?

    init() {
        installEventHandlerIfNeeded()
    }

    deinit {
        // MainActor 隔離のメソッドは deinit から呼べないため、ここで直接解放する。
        for registration in registrations.values {
            UnregisterEventHotKey(registration.ref)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    /// 指定IDのホットキーを(再)登録する。既存の同ID登録は置き換える。
    /// combo に修飾キーが無い場合は登録しない(無効扱い)。戻り値は登録の成否
    /// (他アプリ/システムに既に取られている場合などは false)。
    @discardableResult
    func register(id: UInt32, combo: HotKeyCombo, handler: @escaping () -> Void) -> Bool {
        unregister(id: id)
        guard combo.hasModifier else {
            return false
        }
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            return false
        }
        registrations[id] = Registration(ref: ref, handler: handler)
        return true
    }

    /// 指定IDのホットキーを解除する。未登録なら何もしない。
    func unregister(id: UInt32) {
        guard let registration = registrations.removeValue(forKey: id) else {
            return
        }
        UnregisterEventHotKey(registration.ref)
    }

    /// すべてのホットキーを解除する。
    func unregisterAll() {
        for id in Array(registrations.keys) {
            unregister(id: id)
        }
    }

    private func handle(id: UInt32) {
        registrations[id]?.handler()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else {
            return
        }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else {
                return OSStatus(eventNotHandledErr)
            }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == GlobalHotKeyCenter.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let center = Unmanaged<GlobalHotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            let id = hotKeyID.id
            // Carbon のイベントディスパッチはメインスレッドで走るため、この時点で
            // メインアクター上にいる。同期的に処理して問題ない。
            MainActor.assumeIsolated {
                center.handle(id: id)
            }
            return noErr
        }
        InstallEventHandler(
            GetEventDispatcherTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }
}

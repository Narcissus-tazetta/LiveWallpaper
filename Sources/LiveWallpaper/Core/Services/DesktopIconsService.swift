import Foundation

enum DesktopIconsError: LocalizedError, Equatable {
    case preferencesWriteFailed
    case finderRestartFailed

    var errorDescription: String? {
        switch self {
        case .preferencesWriteFailed:
            return "Failed to update Finder desktop icon settings."
        case .finderRestartFailed:
            return "Failed to restart Finder."
        }
    }
}

final class DesktopIconsService {
    static let finderDomain = "com.apple.finder" as CFString
    static let createDesktopKey = "CreateDesktop" as CFString

    private let readPreference: (_ domain: String, _ key: String) -> Bool?
    private let writePreference: (_ visible: Bool) -> Bool
    private let restartFinder: () throws -> Void

    init(
        readPreference: @escaping (_ domain: String, _ key: String) -> Bool? = DesktopIconsService
            .defaultReadPreference,
        writePreference: @escaping (_ visible: Bool) -> Bool = DesktopIconsService.defaultWritePreference,
        restartFinder: @escaping () throws -> Void = DesktopIconsService.killFinder
    ) {
        self.readPreference = readPreference
        self.writePreference = writePreference
        self.restartFinder = restartFinder
    }

    func isDesktopIconsVisible() -> Bool {
        readPreference(Self.finderDomain as String, Self.createDesktopKey as String) ?? true
    }

    func setDesktopIconsVisible(_ visible: Bool) throws {
        guard isDesktopIconsVisible() != visible else {
            return
        }
        let previousVisible = isDesktopIconsVisible()
        guard writePreference(visible) else {
            throw DesktopIconsError.preferencesWriteFailed
        }
        do {
            try restartFinder()
        } catch {
            _ = writePreference(previousVisible)
            throw error is DesktopIconsError ? error : DesktopIconsError.finderRestartFailed
        }
    }

    static func defaultReadPreference(domain: String, key: String) -> Bool? {
        guard let value = CFPreferencesCopyValue(
            key as CFString,
            domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) else {
            return nil
        }
        return boolFromPreferenceValue(value)
    }

    static func defaultWritePreference(visible: Bool) -> Bool {
        CFPreferencesSetValue(
            createDesktopKey,
            visible ? kCFBooleanTrue : kCFBooleanFalse,
            finderDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        return CFPreferencesSynchronize(
            finderDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
    }

    static func boolFromPreferenceValue(_ value: CFPropertyList) -> Bool? {
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    static func killFinder() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Finder"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DesktopIconsError.finderRestartFailed
        }
    }
}

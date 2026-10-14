import Foundation

/// macOS の壁紙設定 plist(`com.apple.wallpaper` の Store/Index.plist)へ、
/// 借用した Aerial アセットへのリンクを書き込み/検証する。ファイル I/O は
/// 一切行わない純粋関数の集まりで、呼び出し元([[LockScreenSyncService]])が
/// 読み込み・バックアップ・書き込みを担う。
enum WallpaperStorePatcher {
    static func applySelection(assetID: String, to store: inout [String: Any]) throws {
        let choice = try aerialChoice(assetID: assetID, template: findAerialChoice(in: store))
        applyLinkedWallpaperChoice(choice, to: &store)
    }

    static func verifySelection(assetID: String, in store: [String: Any]) -> Bool {
        var verifiedStateCount = 0
        if !verifyState(store["AllSpacesAndDisplays"], assetID: assetID, count: &verifiedStateCount) {
            return false
        }
        if !verifyState(store["SystemDefault"], assetID: assetID, count: &verifiedStateCount) {
            return false
        }
        if let displays = store["Displays"] as? [String: Any] {
            for state in displays.values where !verifyState(state, assetID: assetID, count: &verifiedStateCount) {
                return false
            }
        }
        if let spaces = store["Spaces"] as? [String: Any] {
            for spaceValue in spaces.values {
                guard let space = spaceValue as? [String: Any] else {
                    continue
                }
                if !verifyState(space["Default"], assetID: assetID, count: &verifiedStateCount) {
                    return false
                }
                if let displays = space["Displays"] as? [String: Any] {
                    for state in displays.values
                        where !verifyState(state, assetID: assetID, count: &verifiedStateCount)
                    {
                        return false
                    }
                }
            }
        }

        return verifiedStateCount > 0
    }

    private static func aerialChoice(assetID: String, template: [String: Any]?) throws -> [String: Any] {
        var choice = template ?? [
            "Provider": "com.apple.wallpaper.choice.aerials",
            "Files": [],
            "Configuration": Data()
        ]
        choice["Provider"] = "com.apple.wallpaper.choice.aerials"
        if choice["Files"] == nil {
            choice["Files"] = []
        }
        choice["Configuration"] = try PropertyListSerialization.data(
            fromPropertyList: ["assetID": assetID],
            format: .binary,
            options: 0
        )
        return choice
    }

    private static func findAerialChoice(in object: Any) -> [String: Any]? {
        if let dictionary = object as? [String: Any] {
            if dictionary["Provider"] as? String == "com.apple.wallpaper.choice.aerials" {
                return dictionary
            }
            for value in dictionary.values {
                if let choice = findAerialChoice(in: value) {
                    return choice
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let choice = findAerialChoice(in: value) {
                    return choice
                }
            }
        }
        return nil
    }

    private static func applyLinkedWallpaperChoice(_ choice: [String: Any], to store: inout [String: Any]) {
        if var allSpacesAndDisplays = store["AllSpacesAndDisplays"] as? [String: Any] {
            patchState(&allSpacesAndDisplays, choice: choice)
            store["AllSpacesAndDisplays"] = allSpacesAndDisplays
        }
        if var systemDefault = store["SystemDefault"] as? [String: Any] {
            patchState(&systemDefault, choice: choice)
            store["SystemDefault"] = systemDefault
        }
        if var displays = store["Displays"] as? [String: Any] {
            for key in displays.keys {
                guard var state = displays[key] as? [String: Any] else {
                    continue
                }
                patchState(&state, choice: choice)
                displays[key] = state
            }
            store["Displays"] = displays
        }
        if var spaces = store["Spaces"] as? [String: Any] {
            updateSpaces(&spaces, choice: choice)
            store["Spaces"] = spaces
        }
    }

    private static func updateSpaces(_ spaces: inout [String: Any], choice: [String: Any]) {
        for spaceKey in spaces.keys {
            guard var space = spaces[spaceKey] as? [String: Any] else {
                continue
            }
            if var defaultState = space["Default"] as? [String: Any] {
                patchState(&defaultState, choice: choice)
                space["Default"] = defaultState
            }
            if var displays = space["Displays"] as? [String: Any] {
                for displayKey in displays.keys {
                    guard var state = displays[displayKey] as? [String: Any] else {
                        continue
                    }
                    patchState(&state, choice: choice)
                    displays[displayKey] = state
                }
                space["Displays"] = displays
            }
            spaces[spaceKey] = space
        }
    }

    /// A state either shows one `Linked` surface everywhere, or (`individual`) a
    /// `Desktop` surface, which the lock screen shows too, and an `Idle` one for the
    /// screen saver. The screen saver is left as it is, so ScreenSaverSelection's
    /// choice survives a sync.
    private static func patchState(_ state: inout [String: Any], choice: [String: Any]) {
        if state["Idle"] != nil {
            var desktop = state["Desktop"] as? [String: Any] ?? state["Linked"] as? [String: Any] ?? [:]
            patchSurface(&desktop, choice: choice)
            state["Type"] = "individual"
            state["Desktop"] = desktop
            state.removeValue(forKey: "Linked")
            return
        }
        var linkedSurface = state["Linked"] as? [String: Any]
            ?? state["Desktop"] as? [String: Any]
            ?? [:]
        patchSurface(&linkedSurface, choice: choice)
        state["Type"] = "linked"
        state["Linked"] = linkedSurface
        state.removeValue(forKey: "Desktop")
    }

    private static func patchSurface(_ surface: inout [String: Any], choice: [String: Any]) {
        var content = surface["Content"] as? [String: Any] ?? [:]
        var choices = content["Choices"] as? [[String: Any]] ?? []
        if choices.isEmpty {
            choices = [choice]
        } else {
            choices[0] = choice
        }
        content["Choices"] = choices
        surface["Content"] = content
        surface["LastSet"] = Date()
        surface["LastUse"] = Date()
    }

    private static func verifyState(_ value: Any?, assetID: String, count: inout Int) -> Bool {
        guard let state = value as? [String: Any] else {
            return true
        }
        let surface: [String: Any]?
        switch state["Type"] as? String {
        case "linked":
            surface = state["Idle"] == nil && state["Desktop"] == nil ? state["Linked"] as? [String: Any] : nil
        case "individual":
            surface = state["Linked"] == nil ? state["Desktop"] as? [String: Any] : nil
        default:
            surface = nil
        }
        guard let surface, linkedChoiceAssetID(surface) == assetID else {
            return false
        }
        count += 1
        return true
    }

    private static func linkedChoiceAssetID(_ surface: [String: Any]) -> String? {
        guard let content = surface["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]],
              let choice = choices.first,
              choice["Provider"] as? String == "com.apple.wallpaper.choice.aerials",
              let configuration = choice["Configuration"] as? Data,
              let configurationPlist = try? PropertyListSerialization.propertyList(
                from: configuration,
                options: [],
                format: nil
              ) as? [String: Any]
        else {
            return nil
        }
        return configurationPlist["assetID"] as? String
    }
}

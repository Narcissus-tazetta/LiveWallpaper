import Foundation

/// Selects LiveWallpaper.saver as the macOS screen saver by editing the `Idle` surfaces
/// of the wallpaper Store/Index.plist, and puts back what was there before. Pure
/// functions; [[ScreenSaverInstaller]] does the file I/O.
///
/// The Store keeps one state per Space/display (plus system-wide ones), so every state
/// that has an `Idle` surface is switched; otherwise the saver would only apply to
/// whichever Space happened to be active in System Settings.
enum ScreenSaverSelection {
    struct SavedIdle {
        let path: [String]
        let idle: [String: Any]
    }

    static let provider = "com.apple.wallpaper.choice.screen-saver"

    /// Points every Idle surface at the saver and returns the surfaces it replaced.
    /// Surfaces already showing the saver are not returned, so a re-select never
    /// records the saver as the "original".
    static func select(saverURL: URL, in store: inout [String: Any]) -> [SavedIdle] {
        var replaced: [SavedIdle] = []
        for path in statePaths(in: store) {
            guard var state = value(at: path, in: store) as? [String: Any],
                  let idle = state["Idle"] as? [String: Any]
            else {
                continue
            }
            if !isSaver(idle, saverURL: saverURL) {
                replaced.append(SavedIdle(path: path, idle: idle))
            }
            state["Idle"] = surface(
                choice: saverChoice(saverURL: saverURL),
                options: emptyOptions,
                base: idle
            )
            setValue(state, at: path, in: &store)
        }
        return replaced
    }

    /// Puts the saved surfaces back where the saver is still selected. Surfaces the user
    /// changed to something else in the meantime are left alone. A surface showing the
    /// saver with nothing saved (selected by hand, or a Space created while the app ran)
    /// goes to the system default so it never points at a removed bundle.
    /// Returns whether anything changed.
    static func restore(
        _ saved: [SavedIdle],
        saverURL: URL,
        in store: inout [String: Any]
    ) -> Bool {
        let savedByPath = Dictionary(
            saved.map { ($0.path, $0.idle) },
            uniquingKeysWith: { first, _ in first }
        )
        var changed = false
        for path in statePaths(in: store) {
            guard var state = value(at: path, in: store) as? [String: Any],
                  let idle = state["Idle"] as? [String: Any],
                  isSaver(idle, saverURL: saverURL)
            else {
                continue
            }
            state["Idle"] = savedByPath[path] ?? surface(
                choice: defaultChoice,
                options: "$null",
                base: idle
            )
            setValue(state, at: path, in: &store)
            changed = true
        }
        return changed
    }

    static func selectedCount(saverURL: URL, in store: [String: Any]) -> Int {
        statePaths(in: store).filter { path in
            guard let idle =
                (value(at: path, in: store) as? [String: Any])?["Idle"] as? [String: Any]
            else {
                return false
            }
            return isSaver(idle, saverURL: saverURL)
        }.count
    }

    static func encode(_ saved: [SavedIdle]) throws -> Data {
        let list: [[String: Any]] = saved.map { ["path": $0.path, "idle": $0.idle] }
        return try PropertyListSerialization.data(
            fromPropertyList: list,
            format: .binary,
            options: 0
        )
    }

    static func decode(_ data: Data) throws -> [SavedIdle] {
        guard let list = try PropertyListSerialization
            .propertyList(from: data, format: nil) as? [[String: Any]]
        else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return try list.map { entry in
            guard let path = entry["path"] as? [String],
                  let idle = entry["idle"] as? [String: Any]
            else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            return SavedIdle(path: path, idle: idle)
        }
    }

    // MARK: - Store layout

    private static func statePaths(in store: [String: Any]) -> [[String]] {
        var paths: [[String]] = [["AllSpacesAndDisplays"], ["SystemDefault"]]
        for key in (store["Displays"] as? [String: Any] ?? [:]).keys {
            paths.append(["Displays", key])
        }
        for (spaceKey, space) in store["Spaces"] as? [String: Any] ?? [:] {
            paths.append(["Spaces", spaceKey, "Default"])
            let displays = (space as? [String: Any])?["Displays"] as? [String: Any] ?? [:]
            for key in displays.keys {
                paths.append(["Spaces", spaceKey, "Displays", key])
            }
        }
        return paths
    }

    private static func value(at path: [String], in dictionary: [String: Any]) -> Any? {
        guard let first = path.first else {
            return dictionary
        }
        let child = dictionary[first]
        if path.count == 1 {
            return child
        }
        return (child as? [String: Any]).flatMap { value(at: Array(path.dropFirst()), in: $0) }
    }

    private static func setValue(
        _ newValue: Any,
        at path: [String],
        in dictionary: inout [String: Any]
    ) {
        guard let first = path.first else {
            return
        }
        if path.count == 1 {
            dictionary[first] = newValue
            return
        }
        var child = dictionary[first] as? [String: Any] ?? [:]
        setValue(newValue, at: Array(path.dropFirst()), in: &child)
        dictionary[first] = child
    }

    // MARK: - Choices

    private static func surface(
        choice: [String: Any],
        options: Any,
        base: [String: Any]
    ) -> [String: Any] {
        var surface = base
        var content = base["Content"] as? [String: Any] ?? [:]
        content["Choices"] = [choice]
        content["EncodedOptionValues"] = options
        content["Shuffle"] = "$null"
        surface["Content"] = content
        surface["LastSet"] = Date()
        return surface
    }

    private static var defaultChoice: [String: Any] {
        ["Provider": "default", "Files": [Any](), "Configuration": Data()]
    }

    /// Same shape System Settings writes when a .saver is picked from the list.
    private static func saverChoice(saverURL: URL) -> [String: Any] {
        [
            "Provider": provider,
            "Files": [Any](),
            "Configuration": plistData(["module": ["relative": moduleString(saverURL)]])
        ]
    }

    private static var emptyOptions: Data {
        plistData(["values": [String: Any]()])
    }

    private static func isSaver(_ idle: [String: Any], saverURL: URL) -> Bool {
        guard let content = idle["Content"] as? [String: Any],
              let choice = (content["Choices"] as? [[String: Any]])?.first,
              choice["Provider"] as? String == provider,
              let data = choice["Configuration"] as? Data,
              let configuration = try? PropertyListSerialization.propertyList(
                  from: data,
                  format: nil
              )
              as? [String: Any],
              let module = configuration["module"] as? [String: Any],
              let relative = module["relative"] as? String
        else {
            return false
        }
        return trimmingTrailingSlash(relative) == moduleString(saverURL)
    }

    /// System Settings stores the bundle URL without the trailing slash a directory
    /// URL gets.
    private static func moduleString(_ url: URL) -> String {
        trimmingTrailingSlash(url.absoluteString)
    }

    private static func trimmingTrailingSlash(_ string: String) -> String {
        string.hasSuffix("/") ? String(string.dropLast()) : string
    }

    private static func plistData(_ object: [String: Any]) -> Data {
        (try? PropertyListSerialization.data(
            fromPropertyList: object,
            format: .binary,
            options: 0
        )) ?? Data()
    }
}

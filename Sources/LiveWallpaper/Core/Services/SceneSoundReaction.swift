import Foundation

/// Which scenes may listen to the system audio. Kept outside scene.json so a package
/// cannot turn it on itself: listening needs the screen recording permission.
enum SceneSoundReaction {
    private static let key = "sceneSoundReaction.v1"
    static let didChange = Notification.Name("SceneSoundReaction.didChange")

    static func isEnabled(videoPath: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(identity(videoPath))
    }

    static func setEnabled(_ enabled: Bool, videoPath: String) {
        var paths = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        if enabled { paths.insert(identity(videoPath)) } else { paths.remove(identity(videoPath)) }
        UserDefaults.standard.set(paths.sorted(), forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    private static func identity(_ videoPath: String) -> String {
        URL(fileURLWithPath: videoPath).standardizedFileURL.path
    }
}

extension SceneDocument {
    var usesAudio: Bool {
        layers.contains { layer in
            layer.renderGraph?.usesAudio == true || layer.effects.contains { $0.renderGraph?.usesAudio == true }
        } || scripts.contains(where: \.usesAudio)
    }
}

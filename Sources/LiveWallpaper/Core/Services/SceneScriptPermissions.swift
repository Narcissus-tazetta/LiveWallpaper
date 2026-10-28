import CryptoKit
import Foundation

enum SceneScriptPermissions {
    private static let key = "sceneScriptPermissions.v1"

    static func fingerprint(_ script: SceneScript, path: String) -> String {
        var source = "\(URL(fileURLWithPath: path).standardizedFileURL.path)\n\(script.version)\n\(script.source)"
        if let modules = script.modules {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let bundle = try! encoder.encode(modules)
            source = "module-script-v1\n\(source.utf8.count):\(source)" + String(decoding: bundle, as: UTF8.self)
        }
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func authorize(_ script: SceneScript, path: String) {
        var permissions = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        permissions.insert(fingerprint(script, path: path))
        UserDefaults.standard.set(permissions.sorted(), forKey: key)
    }

    static func authorizeAll(_ document: SceneDocument, path: String) {
        for script in document.scripts { authorize(script, path: path) }
    }

    /// Scripts allowed at `source` stay allowed in the copy at `destination`.
    static func carry(_ document: SceneDocument, from source: String, to destination: String) {
        let permissions = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        for script in document.scripts where permissions.contains(fingerprint(script, path: source)) {
            authorize(script, path: destination)
        }
    }

    /// A reconversion regenerates the scripts (new bindings, a newer runtime bridge), so
    /// their code differs even when the wallpaper's own did not. `scriptOrigin` hashes
    /// what they were made from; the same origin keeps what the user allowed.
    static func carry(_ document: SceneDocument, replacing previous: SceneDocument?, path: String) {
        guard let previous, let origin = document.scriptOrigin, origin == previous.scriptOrigin,
              !previous.scripts.isEmpty, previous.scripts.allSatisfy(\.isAuthorized)
        else { return }
        authorizeAll(document, path: path)
    }

    static func revoke(_ document: SceneDocument, path: String) {
        var permissions = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        for script in document.scripts { permissions.remove(fingerprint(script, path: path)) }
        UserDefaults.standard.set(permissions.sorted(), forKey: key)
    }

    static func restored(_ document: SceneDocument, path: String) -> SceneDocument {
        let permissions = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        var document = document
        for index in document.scripts.indices {
            document.scripts[index].isAuthorized = permissions.contains(fingerprint(document.scripts[index], path: path))
        }
        return document
    }
}

import CryptoKit
import Foundation

enum SceneScriptPermissions {
    private static let key = "sceneScriptPermissions.v1"

    static func fingerprint(_ script: SceneScript, path: String) -> String {
        let source = "\(URL(fileURLWithPath: path).standardizedFileURL.path)\n\(script.version)\n\(script.source)"
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func authorize(_ script: SceneScript, path: String) {
        var permissions = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        permissions.insert(fingerprint(script, path: path))
        UserDefaults.standard.set(permissions.sorted(), forKey: key)
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

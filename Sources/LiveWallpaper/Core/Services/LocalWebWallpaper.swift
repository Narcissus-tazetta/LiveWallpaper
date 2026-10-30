import CryptoKit
import Foundation
import Network
import OSLog
import UniformTypeIdentifiers

struct LocalWebWallpaperPackage: Codable, Equatable {
    var entryPoint: String
    var warnings: [String] = []
    var preview: String?
    var properties: [LocalWebProperty]?
    var supportsSpectrum: Bool?
    var supportsMedia: Bool?
    /// Property ids that drive the page's `WebDisplayAdjustment`.
    var displayAdjustment: [String: String]?

    static let fileName = "web-wallpaper.json"

    static func load(folder: URL) throws -> Self {
        let package = try JSONDecoder().decode(
            Self.self,
            from: Data(contentsOf: folder.appendingPathComponent(fileName))
        )
        if let properties = package.properties {
            guard Set(properties.map(\.id)).count == properties.count,
                  properties.allSatisfy({ !$0.id.isEmpty && [
                      "bool",
                      "slider",
                      "combo",
                      "color",
                      "textinput",
                      "file",
                      "directory",
                      "group",
                      "text"
                  ].contains($0.kind) })
            else { throw CocoaError(.fileReadCorruptFile) }
        }
        _ = try file(package.entryPoint, inside: folder)
        if let preview = package.preview { _ = try file(preview, inside: folder) }
        return package
    }

    static func file(_ name: String, inside folder: URL) throws -> URL {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        let url = root.appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
        guard !name.isEmpty, !name.hasPrefix("/"), url.path.hasPrefix(root.path + "/"),
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: name])
        }
        return url
    }

    static var libraryDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveWallpaper/WebWallpapers", isDirectory: true)
    }

    static func owns(_ folder: URL) -> Bool {
        folder.standardizedFileURL.deletingLastPathComponent() == libraryDirectory
            .standardizedFileURL
            && UUID(uuidString: folder.lastPathComponent) != nil
    }

    static func copy(from folder: URL, to destination: URL) throws {
        _ = try load(folder: folder)
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey]
        ) else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: root.path])
        }
        for case let file as URL in enumerator {
            if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: file.path])
            }
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: root, to: destination)
    }
}

@MainActor
final class LocalWebWallpaperServer {
    private let persistPorts: Bool
    private var engines: [String: Engine] = [:]
    private var startups: [String: Task<UInt16, Error>] = [:]
    private var userFolders: [String: [URL]] = [:]
    private static let portsKey = "localWebWallpaperPorts"

    init(persistPorts: Bool = false) {
        self.persistPorts = persistPorts
    }

    func url(folder: URL) async throws -> URL {
        let package = try LocalWebWallpaperPackage.load(folder: folder)
        let path = folder.standardizedFileURL.path
        let key = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        let engine = engines[path] ?? Engine()
        engines[path] = engine
        if startups[path] == nil {
            let stored = persistPorts ? UserDefaults.standard
                .dictionary(forKey: Self.portsKey)?[key] as? [String: Any] : nil
            let port = (stored?["port"] as? Int).flatMap(UInt16.init(exactly:)) ?? 0
            startups[path] = Task { try await engine.start(port: port) }
        }
        let port: UInt16
        do { port = try await startups[path]!.value }
        catch { startups[path] = nil; engines[path] = nil; throw error }
        let stored = persistPorts ? UserDefaults.standard
            .dictionary(forKey: Self.portsKey)?[key] as? [String: Any] : nil
        let previousToken = (stored?["token"] as? String).flatMap(UUID.init(uuidString:))?
            .uuidString
        let token = await engine.register(folder: folder, token: previousToken)
        engine.setUserFolders(userFolders[path] ?? [], folder: folder)
        if persistPorts {
            var ports = UserDefaults.standard.dictionary(forKey: Self.portsKey) ?? [:]
            ports[key] = ["port": Int(port), "token": token]
            UserDefaults.standard.set(ports, forKey: Self.portsKey)
        }
        // Pages written for a site layout reference siblings of their folder as `../assets/…`; the
        // extra segment lets that resolve inside the token instead of escaping to the server root.
        return URL(string: "http://127.0.0.1:\(port)/\(token)/\(Client.entryDirectory)/")!
            .appendingPathComponent(package.entryPoint)
    }

    /// The folders the package's directory properties point at, which its page may read.
    func setUserFolders(_ folders: [URL], folder: URL) {
        let path = folder.standardizedFileURL.path
        userFolders[path] = folders
        engines[path]?.setUserFolders(folders, folder: folder)
    }

    func remove(folder: URL) {
        let path = folder.standardizedFileURL.path
        startups.removeValue(forKey: path)?.cancel()
        engines.removeValue(forKey: path)
    }

    private final class Engine: @unchecked Sendable {
        private let queue = DispatchQueue(label: "LiveWallpaper.localWeb")
        private var listener: NWListener?
        private var roots: [String: URL] = [:]
        private var tokens: [String: String] = [:]
        private var userFolders: [String: [URL]] = [:]

        deinit { listener?.cancel() }

        func start(port: UInt16) async throws -> UInt16 {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        let parameters = NWParameters.tcp
                        parameters.requiredLocalEndpoint = .hostPort(
                            host: .ipv4(.loopback),
                            port: NWEndpoint.Port(rawValue: port)!
                        )
                        let listener = try NWListener(using: parameters)
                        self.listener = listener
                        var pending: CheckedContinuation<UInt16, Error>? = continuation
                        listener.stateUpdateHandler = { [weak listener] state in
                            switch state {
                            case .ready:
                                pending?.resume(returning: listener!.port!.rawValue)
                                pending = nil
                            case let .failed(error), let .waiting(error):
                                if let waiting = pending {
                                    waiting.resume(throwing: error)
                                    pending = nil
                                } else {
                                    AppLog.externalWallpapers
                                        .error(
                                            "local web listener failed: \(error.localizedDescription, privacy: .public)"
                                        )
                                }
                                listener?.cancel()
                            case .cancelled:
                                pending?.resume(throwing: CancellationError())
                                pending = nil
                            default: break
                            }
                        }
                        listener.newConnectionHandler = { [weak self] connection in
                            guard let self else { connection.cancel(); return }
                            let client = Client(connection: connection, roots: roots, userFolders: userFolders)
                            client.start(on: queue)
                        }
                        listener.start(queue: queue)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        func register(folder: URL, token requested: String?) async -> String {
            await withCheckedContinuation { continuation in
                queue.async {
                    let path = folder.standardizedFileURL.path
                    let token = self.tokens[path] ?? requested ?? UUID().uuidString
                    self.tokens[path] = token
                    self.roots[token] = folder
                    continuation.resume(returning: token)
                }
            }
        }

        func setUserFolders(_ folders: [URL], folder: URL) {
            queue.async {
                guard let token = self.tokens[folder.standardizedFileURL.path] else { return }
                self.userFolders[token] = folders
            }
        }
    }

    /// Network callbacks and the timeout mutate client state only on Engine.queue.
    private final class Client: @unchecked Sendable {
        static let entryDirectory = "_entry"

        private let connection: NWConnection
        private let roots: [String: URL]
        private let userFolders: [String: [URL]]
        private var request = Data()
        private var file: FileHandle?
        private var remaining = 0
        private var timeout: DispatchWorkItem?

        init(connection: NWConnection, roots: [String: URL], userFolders: [String: [URL]]) {
            self.connection = connection
            self.roots = roots
            self.userFolders = userFolders
        }

        func start(on queue: DispatchQueue) {
            let timeout = DispatchWorkItem { [weak self] in self?.finish() }
            self.timeout = timeout
            queue.asyncAfter(deadline: .now() + 15, execute: timeout)
            connection.start(queue: queue)
            receive()
        }

        private func receive() {
            connection
                .receive(
                    minimumIncompleteLength: 1,
                    maximumLength: 16384
                ) { data, _, ended, error in
                    if let data { self.request.append(data) }
                    if let end = self.request.range(of: Data("\r\n\r\n".utf8)) {
                        self.timeout?.cancel()
                        self.respond(to: self.request[..<end.lowerBound])
                    } else if error != nil || ended {
                        self.finish()
                    } else if self.request.count > 32768 {
                        self.send(status: "431 Request Header Fields Too Large")
                    } else {
                        self.receive()
                    }
                }
        }

        private func respond(to data: Data) {
            guard let header = String(data: data, encoding: .utf8) else {
                send(status: "400 Bad Request"); return
            }
            let lines = header.components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ")
            guard first.count == 3, ["GET", "HEAD"].contains(first[0]) else {
                send(status: "405 Method Not Allowed"); return
            }
            guard first[1].hasPrefix("/"),
                  let path = String(first[1].split(separator: "?", maxSplits: 1)[0])
                  .removingPercentEncoding
            else {
                send(status: "400 Bad Request"); return
            }
            let components = path.split(separator: "/", maxSplits: 1).map(String.init)
            guard components.count == 2, let root = roots[components[0]] else {
                send(status: "404 Not Found"); return
            }
            let prefix = Self.entryDirectory + "/"
            let relative = components[1].hasPrefix(prefix)
                ? String(components[1].dropFirst(prefix.count)) : components[1]
            let served = LocalWebUserDirectory.servedPrefix + "/"
            do {
                let url: URL
                if relative.hasPrefix(served) {
                    guard let file = LocalWebUserDirectory.file(
                        "/" + relative.dropFirst(served.count), inside: userFolders[components[0]] ?? []
                    ) else { send(status: "404 Not Found"); return }
                    url = file
                } else {
                    url = try LocalWebWallpaperPackage.file(relative, inside: root)
                }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize!
                let rangeHeader = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }
                let range = Self.byteRange(
                    rangeHeader
                        .map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) },
                    size: size
                )
                guard let range else {
                    send(
                        status: "416 Range Not Satisfiable",
                        fields: "Content-Range: bytes */\(size)\r\n"
                    ); return
                }
                let partial = rangeHeader != nil
                let mime = Self.mimeType(url.pathExtension)
                let fields = "Content-Type: \(mime)\r\nAccept-Ranges: bytes\r\n"
                    +
                    (partial ?
                        "Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(size)\r\n" :
                        "")
                remaining = range.count
                if first[0] == "GET", remaining > 0 {
                    file = try FileHandle(forReadingFrom: url)
                    try file!.seek(toOffset: UInt64(range.lowerBound))
                }
                send(
                    status: partial ? "206 Partial Content" : "200 OK",
                    fields: fields,
                    length: remaining,
                    body: first[0] == "GET"
                )
            } catch let error as CocoaError
                where [.fileReadNoSuchFile, .fileReadNoPermission].contains(error.code)
            {
                send(status: "404 Not Found")
            } catch {
                AppLog.externalWallpapers
                    .error("local web file failed: \(error.localizedDescription, privacy: .public)")
                send(status: "500 Internal Server Error")
            }
        }

        static func byteRange(_ header: String?, size: Int) -> Range<Int>? {
            guard let header else { return 0 ..< size }
            guard size > 0, header.hasPrefix("bytes=") else { return nil }
            let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            if parts[0].isEmpty {
                guard let suffix = Int(parts[1]), suffix > 0 else { return nil }
                return max(0, size - suffix) ..< size
            }
            guard let start = Int(parts[0]), start >= 0, start < size else { return nil }
            if parts[1].isEmpty { return start ..< size }
            guard let end = Int(parts[1]), end >= start else { return nil }
            return start ..< (end >= size - 1 ? size : end + 1)
        }

        static func mimeType(_ ext: String) -> String {
            switch ext.lowercased() {
            case "js", "mjs": return "text/javascript"
            case "wasm": return "application/wasm"
            case "glsl", "vert", "frag": return "text/plain"
            default: return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
            }
        }

        private func send(
            status: String,
            fields: String = "",
            length: Int = 0,
            body: Bool = false
        ) {
            let header = "HTTP/1.1 \(status)\r\nContent-Length: \(length)\r\n\(fields)Cache-Control: no-cache\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { error in
                if error == nil, body { self.sendChunk() } else { self.finish() }
            })
        }

        private func sendChunk() {
            guard remaining > 0, let file else { finish(); return }
            do {
                let data = try file.read(upToCount: min(remaining, 262_144)) ?? Data()
                guard !data.isEmpty else { finish(); return }
                remaining -= data.count
                connection.send(content: data, completion: .contentProcessed { error in
                    if error == nil { self.sendChunk() } else { self.finish() }
                })
            } catch {
                AppLog.externalWallpapers
                    .error("local web read failed: \(error.localizedDescription, privacy: .public)")
                finish()
            }
        }

        private func finish() {
            timeout?.cancel()
            if let file {
                do { try file.close() }
                catch {
                    AppLog.externalWallpapers
                        .error(
                            "local web close failed: \(error.localizedDescription, privacy: .public)"
                        )
                }
                self.file = nil
            }
            connection.cancel()
        }
    }
}

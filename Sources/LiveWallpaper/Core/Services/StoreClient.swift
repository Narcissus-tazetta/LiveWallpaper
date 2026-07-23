import AVFoundation
import CryptoKit
import Foundation

struct StoreSubmissionResult: Equatable {
    let id: String
    let createdAt: String
    /// サーバー側の審査状態("requested"は審査待ち、"published"は公開済み)。
    let status: String
    /// 自己サービスの取り下げ(DELETE /entries/:id/withdraw)に必要な秘密トークン。
    /// サーバーはハッシュのみ保存し生の値は二度と返さないため、ローカルに保存し
    /// 損ねるとその投稿は二度と自己サービスでは取り下げられなくなる。
    let withdrawToken: String
    /// status == "published" の場合のみ取得できる実際のダウンロードURL。
    /// requested の間はまだ非公開(サーバーの /download は status='published' の
    /// エントリしか返さない)ため、誤って使われないよう nil にしておく。
    let downloadURL: URL?
}

enum StoreClientError: LocalizedError {
    case serverError(status: Int, message: String?)
    case invalidResponse
    case fileTooLarge(sizeBytes: Int, maxBytes: Int)
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case let .serverError(status, message):
            let detailTemplate = Self.localized("(詳細: %@)")
            let detail = String(format: detailTemplate, message ?? "status \(status)")
            return "\(Self.friendlyStatusMessage(status))\(detail)"
        case .invalidResponse:
            return Self.localized("Storeサーバーから不正な応答が返されました。しばらくしてから再度お試しください")
        case let .fileTooLarge(sizeBytes, maxBytes):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let sizeText = formatter.string(fromByteCount: Int64(sizeBytes))
            let maxText = formatter.string(fromByteCount: Int64(maxBytes))
            let template = Self.localized("ファイルサイズが大きすぎます(%@ / 上限%@)")
            return String(format: template, sizeText, maxText)
        case .checksumMismatch:
            return Self.localized("ダウンロードしたファイルの検証に失敗しました。もう一度お試しください")
        }
    }

    private static func localized(_ key: String) -> String {
        let raw = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.automatic.rawValue
        let language = AppLanguage(rawValue: raw) ?? .automatic
        return AppLocalization.localizedString(key, languageCode: language.effectiveLanguageCode)
    }

    private static func friendlyStatusMessage(_ status: Int) -> String {
        switch status {
        case 400:
            return Self.localized("入力内容に問題があります。タイトルや作者名を確認してください")
        case 404:
            return Self.localized("アップロードした動画がStore上で見つかりませんでした。もう一度お試しください")
        case 409:
            return Self.localized("アップロード中にデータの不整合が起きました。もう一度お試しください")
        case 411:
            return Self.localized("アップロードデータの送信に失敗しました。もう一度お試しください")
        case 429:
            return Self.localized("アクセスが集中しています。しばらく待ってから再度お試しください")
        case 500..<600:
            return Self.localized("Storeサーバーで問題が発生しています。しばらくしてから再度お試しください")
        default:
            return Self.localized("Storeへのリクエストに失敗しました")
        }
    }
}

/// issue #20 のStore共有(アップロード)フロー。既存の PackageExporter/PackageManifestBuilder
/// をそのまま流用して単体動画の .lwpkg を組み立て、Cloudflare Worker
/// (store-worker/, https://livewallpaper-store.ibaragiakira2007.workers.dev) へ
/// アップロードする。ダウンロード/カタログ閲覧側は StoreCatalogController が担当する。
@MainActor
final class StoreClient {
    static let baseURL = URL(string: "https://livewallpaper-store.ibaragiakira2007.workers.dev")!
    /// store-worker/src/index.ts の MAX_UPLOAD_BYTES と一致させること
    static let maxUploadBytes = 500 * 1024 * 1024

    private let packageExporter: PackageExporter
    private let session: URLSession
    private let fileManager: FileManager

    init(
        packageExporter: PackageExporter,
        session: URLSession = .shared,
        fileManager: FileManager = .default
    ) {
        self.packageExporter = packageExporter
        self.session = session
        self.fileManager = fileManager
    }

    func submit(
        model: WallpaperModel,
        videoPath: String,
        title: String,
        author: String,
        license: String?,
        thumbnailCache: DiskThumbnailCache
    ) async throws -> StoreSubmissionResult {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        let baseFileName = ExportFileNameSanitizer.sanitizedExportFileName(title)
        let packageURL = try await packageExporter.exportSingleWallpaperPackage(
            model: model,
            videoPath: videoPath,
            outputFolderURL: tempDir,
            baseFileName: baseFileName,
            license: license
        )

        let packageData = try Data(contentsOf: packageURL)
        let sizeBytes = packageData.count
        guard sizeBytes <= Self.maxUploadBytes else {
            throw StoreClientError.fileTooLarge(sizeBytes: sizeBytes, maxBytes: Self.maxUploadBytes)
        }
        let sha256 = SHA256.hash(data: packageData).map { String(format: "%02x", $0) }.joined()

        let uploadSlot = try await requestUploadURL(
            contentType: "application/octet-stream",
            sizeBytes: sizeBytes
        )

        // 動画本体アップロードとサムネイル生成/アップロードは互いに独立しているため
        // 並行実行し、投稿全体の体感速度を落とさない。サムネイル側はベストエフォート
        // (失敗しても投稿自体は失敗させない)。
        async let packageUpload: Void = uploadData(
            packageData,
            to: uploadSlot.uploadURL,
            contentType: "application/octet-stream"
        )
        async let thumbnailUpload = generateAndUploadThumbnailBestEffort(
            thumbnailCache: thumbnailCache,
            videoPath: videoPath,
            relatedId: uploadSlot.id
        )

        let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
        let duration = try? await asset.load(.duration).seconds
        let audioTracks = try? await asset.loadTracks(withMediaType: .audio)
        let hasAudio = audioTracks.map { !$0.isEmpty }

        try await packageUpload
        let thumbnailInfo = await thumbnailUpload

        let response = try await submitMetadata(
            id: uploadSlot.id,
            title: title,
            author: author,
            sha256: sha256,
            sizeBytes: sizeBytes,
            objectKey: uploadSlot.objectKey,
            durationSeconds: duration,
            hasAudio: hasAudio,
            license: license,
            thumbnailKey: thumbnailInfo?.objectKey,
            thumbnailSha256: thumbnailInfo?.sha256,
            thumbnailSizeBytes: thumbnailInfo?.sizeBytes
        )
        let entry = response.entry

        return StoreSubmissionResult(
            id: entry.id,
            createdAt: entry.createdAt,
            status: entry.status,
            withdrawToken: response.withdrawToken,
            downloadURL: entry.status == "published"
                ? Self.baseURL.appendingPathComponent("download/\(entry.id)")
                : nil
        )
    }

    // MARK: - Thumbnail (best-effort)

    private enum UploadKind: String {
        case package
        case thumbnail
    }

    /// 投稿する動画のサムネイルを生成しアップロードする。既に`thumbnailCache`に
    /// (共有シート選択時点で)生成済みならそれを再利用し、CPU処理の二重実行を避ける。
    /// 生成・アップロードのいずれかの段階で失敗しても`nil`を返すのみで、投稿自体は
    /// 失敗させない(サーバー側も同様にベストエフォート扱い)。
    ///
    /// `relatedId`には動画パッケージ側で払い出された`uploadSlot.id`をそのまま渡す。
    /// サーバー側がこれをサムネイルのオブジェクトキーに使うことで、
    /// このサムネイルが「どのパッケージ用に発行されたものか」をsubmit時に
    /// 検証できるようにしている(store-worker/src/index.ts の resolveThumbnailKey)。
    private func generateAndUploadThumbnailBestEffort(
        thumbnailCache: DiskThumbnailCache,
        videoPath: String,
        relatedId: String
    ) async -> (objectKey: String, sha256: String, sizeBytes: Int)? {
        var image = thumbnailCache.image(for: videoPath)
        if image == nil {
            image = await VideoThumbnailGenerator.generateBestThumbnail(path: videoPath)
        }
        guard let image, let jpegData = VideoThumbnailGenerator.jpegData(image) else {
            return nil
        }
        do {
            let sha256 = SHA256.hash(data: jpegData).map { String(format: "%02x", $0) }.joined()
            let uploadSlot = try await requestUploadURL(
                contentType: "image/jpeg",
                sizeBytes: jpegData.count,
                kind: .thumbnail,
                relatedId: relatedId
            )
            try await uploadData(jpegData, to: uploadSlot.uploadURL, contentType: "image/jpeg")
            return (objectKey: uploadSlot.objectKey, sha256: sha256, sizeBytes: jpegData.count)
        } catch {
            return nil
        }
    }

    // MARK: - Requests

    private struct UploadURLRequestBody: Encodable {
        let contentType: String
        let sizeBytes: Int
        let kind: String?
        let relatedId: String?
    }

    private struct UploadURLResponse: Decodable {
        let id: String
        let objectKey: String
        let uploadURL: String
        let expiresIn: Int
    }

    private func requestUploadURL(
        contentType: String,
        sizeBytes: Int,
        kind: UploadKind = .package,
        relatedId: String? = nil
    ) async throws -> UploadURLResponse {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("upload-url"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(
            UploadURLRequestBody(
                contentType: contentType,
                sizeBytes: sizeBytes,
                kind: kind == .package ? nil : kind.rawValue,
                relatedId: relatedId
            )
        )
        let (data, response) = try await session.data(for: request)
        do {
            try Self.checkOK(response, data: data)
        } catch StoreClientError.serverError(413, _) where kind == .package {
            throw StoreClientError.fileTooLarge(sizeBytes: sizeBytes, maxBytes: Self.maxUploadBytes)
        }
        do {
            return try JSONDecoder().decode(UploadURLResponse.self, from: data)
        } catch {
            AppLog.store.error(
                "upload-url decode failed: \(error, privacy: .public) body=\(String(decoding: data, as: UTF8.self), privacy: .public)"
            )
            throw error
        }
    }

    private func uploadData(_ data: Data, to urlString: String, contentType: String) async throws {
        guard let url = URL(string: urlString) else {
            throw StoreClientError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "content-type")
        request.setValue("\(data.count)", forHTTPHeaderField: "content-length")
        let (responseData, response) = try await session.upload(for: request, from: data)
        try Self.checkOK(response, data: responseData)
    }

    private struct SubmitRequestBody: Encodable {
        let id: String
        let title: String
        let author: String
        let sha256: String
        let sizeBytes: Int
        let objectKey: String
        let durationSeconds: Double?
        let hasAudio: Bool?
        let license: String?
        let thumbnailKey: String?
        let thumbnailSha256: String?
        let thumbnailSizeBytes: Int?
    }

    private struct SubmitResponse: Decodable {
        struct Entry: Decodable {
            let id: String
            let title: String
            let author: String
            let createdAt: String
            let status: String
        }
        let ok: Bool
        let entry: Entry
        let withdrawToken: String
    }

    private func submitMetadata(
        id: String,
        title: String,
        author: String,
        sha256: String,
        sizeBytes: Int,
        objectKey: String,
        durationSeconds: Double?,
        hasAudio: Bool?,
        license: String?,
        thumbnailKey: String?,
        thumbnailSha256: String?,
        thumbnailSizeBytes: Int?
    ) async throws -> SubmitResponse {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("submit"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(
            SubmitRequestBody(
                id: id,
                title: title,
                author: author,
                sha256: sha256,
                sizeBytes: sizeBytes,
                objectKey: objectKey,
                durationSeconds: durationSeconds,
                hasAudio: hasAudio,
                license: license,
                thumbnailKey: thumbnailKey,
                thumbnailSha256: thumbnailSha256,
                thumbnailSizeBytes: thumbnailSizeBytes
            )
        )
        let (data, response) = try await session.data(for: request)
        try Self.checkOK(response, data: data)
        do {
            return try JSONDecoder().decode(SubmitResponse.self, from: data)
        } catch {
            AppLog.store.error(
                "submit decode failed: \(error, privacy: .public) body=\(String(decoding: data, as: UTF8.self), privacy: .public)"
            )
            throw error
        }
    }

    private static func checkOK(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw StoreClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw StoreClientError.serverError(status: http.statusCode, message: message)
        }
    }
}

import CryptoKit
import Foundation

/// `DiskThumbnailCache`・`LightweightProxyCache`・`RemoteThumbnailCache` が共通で
/// 使う、状態を持たない純粋なヘルパー。3つとも Application Support 配下の専用
/// サブフォルダへ `metadata.json` + ハッシュ化ファイル名のデータを保存する、という
/// 同じディスクレイアウトを使うため、そのレイアウト計算とキーのハッシュ化だけを
/// ここへ集約する。
///
/// メタデータの永続化(debounceされたflush)やLRU退避は各キャッシュの状態
/// (`ioQueue`・`metadataDirty`・在メモリキャッシュ辞書など)に密結合しており、
/// キャッシュごとに追加のクリーンアップ(在メモリ画像の破棄、passthroughエントリの
/// 扱い等)も異なるため、あえて統合していない。

enum CacheKeyHashing {
    /// キャッシュファイル名に使う、ソースパス/IDの短いcontent-addressedハッシュ。
    static func hashed(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// 実ソースファイルのサイズ・更新日時をキャッシュエントリと突き合わせて検証できる
/// ことを示すプロトコル。適合には既存プロパティの型・名前が一致していれば十分で、
/// 追加の実装は不要。
protocol SourceTrackedCacheEntry {
    var sourceSize: UInt64 { get }
    var sourceModifiedAt: TimeInterval { get }
}

enum SourceValidityCheck {
    /// エントリ記録時点と実ファイルのサイズ・更新日時が一致するか。不一致なら
    /// ソースが差し替えられている(= キャッシュは無効)とみなす。
    static func isValid<Entry: SourceTrackedCacheEntry>(path: String, entry: Entry) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = attributes[.size] as? NSNumber,
              let modifiedDate = attributes[.modificationDate] as? Date
        else {
            return false
        }
        let sizeMatches = fileSize.uint64Value == entry.sourceSize
        let mtimeMatches = abs(modifiedDate.timeIntervalSince1970 - entry.sourceModifiedAt) < 0.001
        return sizeMatches && mtimeMatches
    }
}

/// `~/Library/Application Support/LiveWallpaper/<subfolder>/` を土台にした、
/// ディスクキャッシュ共通のディレクトリレイアウト(データ用の `data/` サブフォルダ +
/// metadata.json)。
enum DiskCacheLayout {
    static func rootDirectoryURL(subfolder: String) -> URL? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return support
            .appendingPathComponent("LiveWallpaper", isDirectory: true)
            .appendingPathComponent(subfolder, isDirectory: true)
    }

    static func dataDirectoryURL(subfolder: String) -> URL? {
        rootDirectoryURL(subfolder: subfolder)?.appendingPathComponent("data", isDirectory: true)
    }

    static func metadataFileURL(subfolder: String, metadataFileName: String) -> URL? {
        rootDirectoryURL(subfolder: subfolder)?.appendingPathComponent(metadataFileName)
    }
}

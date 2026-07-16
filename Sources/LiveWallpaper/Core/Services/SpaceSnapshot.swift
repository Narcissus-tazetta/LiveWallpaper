import Foundation

/// Mission Control 上の 1 つの Space(仮想デスクトップ)。
struct SpaceInfo: Equatable, Identifiable {
    /// 正規化済み UUID。プライマリ Space は空文字で返ることがあるため
    /// `SpaceSnapshotParser.primaryUUID` に正規化される。
    let uuid: String
    /// フルスクリーンアプリの Space かどうか("TileLayoutManager" キーの有無)。
    let isFullscreen: Bool
    /// Mission Control の「デスクトップ N」に対応する 1 始まりの通し番号。
    /// フルスクリーン Space は番号を持たないため nil。
    let ordinal: Int?

    var id: String { uuid }
}

/// 1 ディスプレイぶんの Space 一覧と現在の Space。
struct DisplaySpacesSnapshot: Equatable {
    /// CGS が返すディスプレイ識別子。ディスプレイ UUID 文字列、または
    /// 「ディスプレイごとに個別のSpace」OFF のとき "Main"。
    let cgsDisplayIdentifier: String
    let spaces: [SpaceInfo]
    /// 正規化済みの現在 Space UUID。
    let currentSpaceUUID: String
    let currentSpaceIsFullscreen: Bool
}

/// `CGSCopyManagedDisplaySpaces` の生辞書をアプリのモデルに変換する純粋関数群。
/// 非公開APIの返却形式は将来変わりうるため、必須キーの欠落・型不一致は
/// nil を返して呼び出し側が機能を無効化できるようにする(部分的な結果で
/// 誤った壁紙を出すより、機能ごと安全に止める方を選ぶ)。
enum SpaceSnapshotParser {
    /// プライマリ Space の uuid が空文字で返る環境向けの正規化値。
    static let primaryUUID = "primary"

    private enum Key {
        static let displayIdentifier = "Display Identifier"
        static let spaces = "Spaces"
        static let currentSpace = "Current Space"
        static let uuid = "uuid"
        static let tileLayoutManager = "TileLayoutManager"
    }

    /// 「ディスプレイごとに個別のSpace」OFF のときの識別子。
    static let mainDisplayIdentifier = "Main"

    static func normalizeUUID(_ uuid: String?) -> String {
        guard let uuid, !uuid.isEmpty else {
            return primaryUUID
        }
        return uuid
    }

    static func parse(_ raw: [[String: Any]]) -> [DisplaySpacesSnapshot]? {
        guard !raw.isEmpty else {
            return nil
        }
        var snapshots: [DisplaySpacesSnapshot] = []
        snapshots.reserveCapacity(raw.count)
        // 「デスクトップ N」は Mission Control と同じく全ディスプレイ通しで
        // フルスクリーン Space を除いて数える(WhichSpace と同方式)。
        var desktopOrdinal = 0

        for displayEntry in raw {
            guard
                let identifier = displayEntry[Key.displayIdentifier] as? String,
                let rawSpaces = displayEntry[Key.spaces] as? [[String: Any]],
                let currentSpace = displayEntry[Key.currentSpace] as? [String: Any]
            else {
                return nil
            }

            var spaces: [SpaceInfo] = []
            spaces.reserveCapacity(rawSpaces.count)
            for rawSpace in rawSpaces {
                let isFullscreen = rawSpace[Key.tileLayoutManager] is [String: Any]
                let ordinal: Int?
                if isFullscreen {
                    ordinal = nil
                } else {
                    desktopOrdinal += 1
                    ordinal = desktopOrdinal
                }
                spaces.append(
                    SpaceInfo(
                        uuid: normalizeUUID(rawSpace[Key.uuid] as? String),
                        isFullscreen: isFullscreen,
                        ordinal: ordinal
                    )
                )
            }

            snapshots.append(
                DisplaySpacesSnapshot(
                    cgsDisplayIdentifier: identifier,
                    spaces: spaces,
                    currentSpaceUUID: normalizeUUID(
                        currentSpace[Key.uuid] as? String
                    ),
                    currentSpaceIsFullscreen:
                        currentSpace[Key.tileLayoutManager] is [String: Any]
                )
            )
        }
        return snapshots
    }
}

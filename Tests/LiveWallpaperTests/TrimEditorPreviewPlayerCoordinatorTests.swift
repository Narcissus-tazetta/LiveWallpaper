import AVFoundation
@testable import LiveWallpaper
import SwiftUI
import XCTest

/// `TrimEditorPreviewPlayer.Coordinator` の実際の再生を検証する。特にデバウンス
/// 経路(同一パスへ短時間に複数回 attach したときの再構築)を実測する。
///
/// 過去、このデバウンスは `Task { try? await Task.sleep(...) }` で実装されており、
/// `Coordinator` が `@MainActor` でないためバックグラウンドスレッドで
/// `layer.player` 代入や `queue.play()` を呼んでしまい、プレビューが黒画面のまま
/// 更新されない不具合になった。`DispatchQueue.main.asyncAfter` への変更自体が
/// 「メインスレッドで実行される」ことをAPIの保証として担保する(libdispatchの
/// `DispatchQueue.main` へ投入した作業は必ずメインスレッドで実行される)。
/// このテストは、その再構築が実際に機能する(playerが再割り当てされ、再生位置が
/// 進む=途中でフリーズしない)ことを実測で確認する。
/// 画面に実際にピクセルが描画されるか(見た目の黒画面)まではユニットテストの
/// 範囲外で、実機のプレビューでの目視確認が必要。
@MainActor
final class TrimEditorPreviewPlayerCoordinatorTests: XCTestCase {
    private func sampleVideoURL() -> URL? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LiveWallpaper/Videos")
        let files =
            (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
                ?? []
        return files.first { ["mp4", "mov"].contains($0.pathExtension.lowercased()) }
    }

    func testDebouncedAttachRebuildsPlayerAndPlaybackAdvances() throws {
        guard let url = sampleVideoURL() else {
            throw XCTSkip("no sample video available in Videos dir")
        }
        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        try XCTSkipIf(duration < 2.0, "sample video is too short for this timing test")

        var observedTime: Double = 0
        let binding = Binding<Double>(get: { observedTime }, set: { observedTime = $0 })
        let coordinator = TrimEditorPreviewPlayer.Coordinator(currentTime: binding)
        let layer = AVPlayerLayer()

        // 初回 attach はパスが未設定から変わるので即時経路(この経路は元々バグって
        // いなかった)。
        coordinator.attach(
            to: layer, path: url.path,
            spec: .init(trimStart: 0, trimEnd: 1.5, loopStart: nil)
        )
        coordinator.setPlaying(true)
        XCTAssertNotNil(layer.player, "immediate attach must assign the player")
        let playerBeforeRebuild = layer.player

        // 同一パスのまま spec だけ変える2回目の呼び出しがデバウンス経路(バグの現場)。
        // spec が前回と完全に同じだと attach は早期 return するため、必ず値を変える。
        coordinator.attach(
            to: layer, path: url.path,
            spec: .init(trimStart: 0, trimEnd: 1.2, loopStart: nil)
        )

        let rebuilt = expectation(description: "debounced rebuild completed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { rebuilt.fulfill() }
        wait(for: [rebuilt], timeout: 2)

        XCTAssertNotNil(layer.player, "debounced rebuild must still assign the player")
        XCTAssertNotIdentical(
            layer.player, playerBeforeRebuild,
            "the debounced rebuild must actually run and replace the player " +
                "(if it silently never executed off-thread, the old player would linger unchanged)"
        )

        let played = expectation(description: "playback advances after rebuild")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { played.fulfill() }
        wait(for: [played], timeout: 2)

        XCTAssertGreaterThan(
            observedTime, 0,
            "playback must actually advance after the debounced rebuild, not freeze/stay black"
        )

        coordinator.stop()
    }
}

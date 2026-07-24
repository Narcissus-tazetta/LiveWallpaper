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

    /// デバウンス待ちの再構築は、要求が元の構成へ戻った時点で捨てなければ
    /// ならない。捨て忘れると、ドラッグで A→B→A と戻した150ms後に B の
    /// 範囲で再構築が走り、UIはAなのにプレビューだけBをループし続ける
    /// (次に値を変えるまで直らない)。
    func testReturningToTheAppliedSpecCancelsThePendingRebuild() throws {
        guard let url = sampleVideoURL() else {
            throw XCTSkip("no sample video available in Videos dir")
        }
        let asset = AVURLAsset(url: url)
        try XCTSkipIf(CMTimeGetSeconds(asset.duration) < 2.0, "sample video is too short")

        var observedTime: Double = 0
        let binding = Binding<Double>(get: { observedTime }, set: { observedTime = $0 })
        let coordinator = TrimEditorPreviewPlayer.Coordinator(currentTime: binding)
        let layer = AVPlayerLayer()

        let applied = TrimEditorPreviewPlayer.LoopSpec(
            trimStart: 0, trimEnd: 1.5, loopStart: nil
        )
        coordinator.attach(to: layer, path: url.path, spec: applied)
        let playerAfterFirstAttach = layer.player

        // ドラッグ中の中間値 → デバウンス待ちに入る
        coordinator.attach(
            to: layer, path: url.path,
            spec: .init(trimStart: 0, trimEnd: 1.2, loopStart: nil)
        )
        // デバウンスが切れる前に元の値へ戻す
        coordinator.attach(to: layer, path: url.path, spec: applied)

        let settled = expectation(description: "debounce window elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertIdentical(
            layer.player, playerAfterFirstAttach,
            "元の構成へ戻ったのに再構築が走ったということは、古い中間 spec が適用されている"
        )

        coordinator.stop()
    }

    /// 再構築後の再生が、シークが着地する前の位置(=新しいレンジの先頭付近、
    /// 実質トリム開始位置)から一瞬始まってはいけない。これが起きると、UI上は
    /// 「ハンドルを動かした先に一瞬戻ってから目的の位置へ飛ぶ」ように見える
    /// (実際にユーザーが「開始にする」を押した直後にこの見え方を報告した)。
    func testRebuildDoesNotFlashTheOldPositionBeforeTheSeekLands() throws {
        guard let url = sampleVideoURL() else {
            throw XCTSkip("no sample video available in Videos dir")
        }
        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        try XCTSkipIf(duration < 6.0, "sample video is too short for this timing test")

        var observedTime: Double = 0
        let binding = Binding<Double>(get: { observedTime }, set: { observedTime = $0 })
        let coordinator = TrimEditorPreviewPlayer.Coordinator(currentTime: binding)
        let layer = AVPlayerLayer()

        // 頭出し: 4秒地点にいる状態を作る。
        coordinator.attach(
            to: layer, path: url.path,
            spec: .init(trimStart: 0, trimEnd: nil, loopStart: nil)
        )
        coordinator.applySeekIfNeeded(SeekToken(time: 4))
        coordinator.setPlaying(true)

        // 「カット開始位置を今の再生位置にします」相当: trimStart を 4 へ
        // 動かす。同一パスなのでデバウンス経路に入る。
        coordinator.attach(
            to: layer, path: url.path,
            spec: .init(trimStart: 4, trimEnd: nil, loopStart: nil)
        )
        coordinator.applySeekIfNeeded(SeekToken(time: 4))

        // デバウンス(150ms)が解けて再構築・シーク・再生が始まる区間を、
        // 細かく連続サンプリングする。新しいプレイヤーは生成直後・シーク
        // 着地前は 0 付近を指すのが正常(まだ再生していないので実害はない)。
        // バグがあるとそこから **前進し続ける**(= シークの着地を待たずに
        // 0 から再生してしまっている)ため、「0付近から連続して増え続ける
        // 区間」の有無で判定する。単発の 0 読み取りは初期化の副作用として
        // 許容する。
        var samples: [Double] = []
        for _ in 0 ..< 25 {
            let tick = expectation(description: "tick")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { tick.fulfill() }
            wait(for: [tick], timeout: 1)
            samples.append(observedTime)
        }

        var creepingFromNearZero = false
        for index in 1 ..< samples.count {
            let previous = samples[index - 1]
            let current = samples[index]
            if previous < 1.0, current > previous + 0.05, current < 3.0 {
                creepingFromNearZero = true
                break
            }
        }

        XCTAssertFalse(
            creepingFromNearZero,
            """
            0秒付近から前進し続ける区間が観測された(\(samples))。これは \
            シークの着地を待たずに0秒から再生を始めてしまい、着地するまで \
            の間そのまま動画が進んでいることを意味する
            """
        )

        coordinator.stop()
    }
}

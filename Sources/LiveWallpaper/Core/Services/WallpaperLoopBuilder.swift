import AVFoundation

/// トリム編集を適用した継ぎ目なしループを組み立てる、本番の壁紙再生
/// (`WallpaperModel+Edit.swift`)とトリム編集画面のWYSIWYGプレビュー
/// (`TrimEditorPreviewPlayer.swift`)で共有する唯一の実装。同じ挙動を二箇所に
/// 書くと片方だけ直し忘れて挙動が食い違う(実際に一度そうなった)ため、ここへ
/// 一本化してある。
///
/// ループ区間は「ループ開始位置 ... カット終了位置」(ループ開始位置が未指定なら
/// カット開始位置から)。ループ開始位置を別に指定できるとき、初回だけは
/// カット開始位置から通しで再生する(= イントロ)。
///
/// この2段階演出は過去2回、`forwardPlaybackEndTime` + 終了通知で
/// 「一旦停止して再seek・再play」する作りで実装して2回とも再生が止まったまま
/// 復帰しない不具合を出している。今の実装はその方式を採らない:
///
/// - 停止も終了通知も使わない。`AVPlayerLooper` が張ったキューには一切触らず、
///   **最初のコピーを1回だけ後ろ(カット開始位置)へシークする**だけ。
///   コピーには `forwardPlaybackEndTime`(= カット終了位置)が乗っているので、
///   そのまま再生するとカット終了位置でキューが次のコピーへ進み、2周目以降は
///   `AVPlayerLooper` が自前でループ開始位置から回す。周回の面倒はApple側の
///   実装に任せたまま、初回だけ手前から流せる。
/// - シークが間に合わない/弾かれた場合の最悪ケースは「イントロが無い」だけで、
///   ループ自体は影響を受けない(`beginIntroPass` 参照)。
/// - それでも再生が止まった場合に備え、進行を実測して復帰させる番犬を付けてある
///   (`watchIntroProgress` 参照)。壁紙は何時間も回り続けるので、静かに固まる
///   ことだけは許容できない。
enum WallpaperLoopBuilder {
    /// 編集内容どおりのループを作る。ループ開始位置があれば初回だけカット開始
    /// 位置から流し、2周目以降は `loopStart ... trimEnd` を継ぎ目なく繰り返す。
    ///
    /// - Important: `timeRange` は **必ずアイテムの実尺の内側**でなければならない。
    ///   はみ出すと `AVPlayerLooper` は即座に `.failed`
    ///   (`AVFoundationErrorDomain -11838 "Loop range must be within [0, item
    ///   duration]"`)になり、**キューに1つもアイテムを入れない**。その結果
    ///   「再生が始まらず、直前のフレームが貼り付いたまま止まる」という症状になる
    ///   (実測で確認済み)。
    ///
    ///   以前はtrimEnd未設定時に `duration: .positiveInfinity` を渡し、
    ///   「AVPlayerLooperが自然な終端へクランプしてくれる」と想定していたが、
    ///   これは誤りで上記の失敗を起こしていた。尺が分からない場合は
    ///   `timeRange` を渡さない(= 全体ループ)方へフォールバックする。
    ///   trimEnd を実尺の内側へ収める責務は保存側
    ///   (`WallpaperEditorController.commit`)にある。
    static func makeLooper(
        player: AVQueuePlayer,
        templateItem item: AVPlayerItem,
        trimStart: Double,
        trimEnd: Double?,
        loopStart: Double? = nil,
        playsIntro: Bool = true,
        context: String = "wallpaper"
    ) -> AVPlayerLooper {
        guard let range = loopTimeRange(
            trimStart: trimStart,
            trimEnd: trimEnd,
            loopStart: loopStart
        ) else {
            return AVPlayerLooper(player: player, templateItem: item)
        }
        let looper = AVPlayerLooper(player: player, templateItem: item, timeRange: range)
        if playsIntro, let introStart = introSeekSeconds(
            trimStart: trimStart,
            trimEnd: trimEnd,
            loopStart: loopStart
        ) {
            beginIntroPass(
                looper: looper,
                player: player,
                introStart: introStart,
                loopStart: range.start,
                context: context
            )
        }
        reportStallIfNeeded(looper: looper, player: player, range: range, context: context)
        return looper
    }

    // MARK: - イントロ(初回だけカット開始位置から)

    /// イントロ判定に使う最小の前置き。ループ開始位置がカット開始位置とこの秒数も
    /// 離れていなければ、シークする意味がないので何もしない。
    static let introMinimumLeadIn: Double = 0.1

    /// 初回再生の開始位置。イントロが成立しない条件(ループ開始位置が無い/
    /// カット開始位置と実質同じ/そもそも区間が作れない)ではnilを返す。
    ///
    /// `AVPlayerLooper` の外側から手を入れる唯一の箇所なので、条件判定だけを
    /// 純関数として切り出し単体テストできるようにしてある。
    static func introSeekSeconds(
        trimStart: Double,
        trimEnd: Double?,
        loopStart: Double?
    ) -> Double? {
        guard let range = loopTimeRange(
            trimStart: trimStart,
            trimEnd: trimEnd,
            loopStart: loopStart
        ) else {
            return nil
        }
        guard range.start.seconds > trimStart + introMinimumLeadIn else {
            return nil
        }
        return trimStart
    }

    /// 最初のコピーが再生可能になり次第、1回だけカット開始位置へ戻す。
    ///
    /// 見送る条件(いずれも「イントロが無い」だけで済み、ループは壊れない):
    /// - `AVPlayerLooper` が `.failed` / アイテムが用意できない
    /// - 既に2周目に入っている(`loopCount > 0`)
    /// - 既にループ開始位置からかなり進んでいる(戻すと巻き戻って見えるため)
    /// - 待っても `readyToPlay` にならない(壊れたファイルなど)
    private static func beginIntroPass(
        looper: AVPlayerLooper,
        player: AVQueuePlayer,
        introStart: Double,
        loopStart: CMTime,
        context: String,
        elapsed: TimeInterval = 0
    ) {
        let pollInterval: TimeInterval = 0.05
        let giveUpAfter: TimeInterval = 5
        /// ループ開始位置からこれ以上進んでいたら、もう巻き戻さない。
        let maxRewind: Double = 0.5

        func retry() {
            guard elapsed + pollInterval < giveUpAfter else {
                AppLog.continuity.debug(
                    "intro skipped (never became ready) context=\(context, privacy: .public)"
                )
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
                [weak looper, weak player] in
                guard let looper, let player else {
                    return
                }
                beginIntroPass(
                    looper: looper,
                    player: player,
                    introStart: introStart,
                    loopStart: loopStart,
                    context: context,
                    elapsed: elapsed + pollInterval
                )
            }
        }

        guard looper.status != .failed else {
            return
        }
        guard let item = player.currentItem, item.status != .failed else {
            retry()
            return
        }
        guard item.status == .readyToPlay else {
            retry()
            return
        }
        guard looper.loopCount == 0 else {
            AppLog.continuity.debug(
                "intro skipped (already looping) context=\(context, privacy: .public)"
            )
            return
        }
        let now = player.currentTime()
        guard now.isNumeric, now.seconds <= loopStart.seconds + maxRewind else {
            AppLog.continuity.debug(
                "intro skipped (already past the loop start) context=\(context, privacy: .public)"
            )
            return
        }

        player.seek(
            to: CMTime(seconds: introStart, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak player] finished in
            guard finished, let player else {
                return
            }
            watchIntroProgress(
                player: player,
                recoverTo: loopStart,
                context: context
            )
        }
    }

    /// イントロシークの後、再生が実際に進んでいるかを実測する番犬。
    ///
    /// ループ区間の手前(= `AVPlayerLooper` に申告した範囲の外)へ戻す操作なので、
    /// 万一これで再生が止まるOS/コーデックがあっても、壁紙が静かに固まったまま
    /// 何時間も放置されることだけは避ける。止まっていたらループ区間の先頭へ戻して
    /// 再生し直す(= イントロを諦めて確実に動く状態へ落とす)。
    ///
    /// 一時停止中(被覆でpause済みなど)は判定せず、次のtickへ送る。
    private static func watchIntroProgress(
        player: AVQueuePlayer,
        recoverTo loopStart: CMTime,
        context: String,
        previousSeconds: Double? = nil,
        ticksRemaining: Int = 4
    ) {
        guard ticksRemaining > 0 else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak player] in
            guard let player else {
                return
            }
            let time = player.currentTime()
            guard player.rate > 0, time.isNumeric else {
                // 再生していない間は判定材料にならない(前回値も持ち越さない)。
                watchIntroProgress(
                    player: player,
                    recoverTo: loopStart,
                    context: context,
                    previousSeconds: nil,
                    ticksRemaining: ticksRemaining - 1
                )
                return
            }
            let seconds = time.seconds
            if let previousSeconds, abs(seconds - previousSeconds) < 0.05,
               player.currentItem?.isPlaybackBufferEmpty != true
            {
                AppLog.continuity.error(
                    """
                    intro stalled context=\(context, privacy: .public) at=\(seconds) — \
                    recovering to the loop start
                    """
                )
                player.seek(to: loopStart, toleranceBefore: .zero, toleranceAfter: .zero)
                player.play()
                return
            }
            watchIntroProgress(
                player: player,
                recoverTo: loopStart,
                context: context,
                previousSeconds: seconds,
                ticksRemaining: ticksRemaining - 1
            )
        }
    }

    /// ループが立ち上がらなかった場合に **Errorレベルで**記録する。この失敗は画面上
    /// 「動画が最後のフレームで止まっている」だけに見え、原因がまったく分からない
    /// (実際に一度そうなった)。`.debug` は unified log に永続化されず後から
    /// `log show` で追えないため、ここだけは意図的に `.error` を使う。
    private static func reportStallIfNeeded(
        looper: AVPlayerLooper,
        player: AVQueuePlayer,
        range: CMTimeRange,
        context: String
    ) {
        // 生成直後は .unknown / キュー未投入のことがあるため、落ち着くまで待って見る。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak looper, weak player] in
            guard let looper, let player else {
                return
            }
            let rangeText = "[\(range.start.seconds)..\(range.end.seconds)]"
            if looper.status == .failed {
                let reason = looper.error?.localizedDescription ?? "unknown"
                AppLog.continuity.error(
                    """
                    loop failed context=\(context, privacy: .public) range=\(rangeText) \
                    reason=\(reason, privacy: .public) — nothing will play; \
                    the wallpaper freezes on its last frame
                    """
                )
                return
            }
            guard let item = player.currentItem else {
                AppLog.continuity.error(
                    """
                    loop has no current item context=\(context, privacy: .public) \
                    range=\(rangeText) status=\(looper.status.rawValue)
                    """
                )
                return
            }
            if item.status == .failed {
                let reason = item.error?.localizedDescription ?? "unknown"
                AppLog.continuity.error(
                    """
                    loop item failed context=\(context, privacy: .public) \
                    range=\(rangeText) reason=\(reason, privacy: .public)
                    """
                )
            }
        }
    }

    /// ループ区間の算出。`AVPlayerLooper` は組み立てた `timeRange` を外部から
    /// 検査できないため、この部分だけを単体テスト可能な純関数として切り出してある。
    ///
    /// 起点は `loopStart`(未指定・範囲外なら `trimStart`)。範囲外の loopStart を
    /// 黙って trimStart へ落とすのは、保存データが壊れていても「ループしない」
    /// より「イントロが無いだけ」の方が遥かにマシなため。
    ///
    /// - Returns: 区間。trimEnd が未設定で終端を確定できない場合は nil
    ///   (呼び出し側は `timeRange` 無しの全体ループにフォールバックする)。
    static func loopTimeRange(
        trimStart: Double,
        trimEnd: Double?,
        loopStart: Double? = nil
    ) -> CMTimeRange? {
        guard let trimEnd, trimEnd > trimStart else {
            return nil
        }
        let requestedStart = loopStart ?? trimStart
        let startSeconds = (requestedStart >= trimStart && requestedStart < trimEnd)
            ? requestedStart
            : trimStart
        let start = CMTime(seconds: startSeconds, preferredTimescale: 600)
        let end = CMTime(seconds: trimEnd, preferredTimescale: 600)
        return CMTimeRange(start: start, duration: end - start)
    }

    /// trimEnd はアセットの実尺から必ずこの秒数ぶん内側へ収める。CMTime(timescale
    /// 600)への丸めや、尺の取得元の食い違い(元ファイルと軽量プロキシなど)で
    /// 1ティックでもはみ出すと `AVPlayerLooper` が `.failed` になり再生が始まらない
    /// (`makeLooper` 参照)ため、1フレーム弱の余裕を必ず残す。
    static let loopEndGuard: Double = 0.05

    /// ループ末尾のこの秒数ぶん手前より後ろへは復元シークしない。継ぎ目の直前に
    /// 戻しても一瞬でループしてしまい、復元の意味がないため。
    static let resumeEndGuard: Double = 0.05

    /// 記憶していた再生位置(アセット先頭からの絶対秒)を、実際にループしている
    /// 区間へ収める。
    ///
    /// 専用プレイヤーのスロット復元・deep suspend からの復帰・軽量プロキシ差し替えは
    /// いずれも「元の位置へ seek し直す」で継続性を出しているが、その位置は
    /// トリム編集を知らずに記録される。カットで捨てた領域(ループ区間の外)へ
    /// seek すると `AVPlayerLooper` が張った `forwardPlaybackEndTime` の先へ
    /// 飛んでしまい、ループに戻れずそのフレームで止まる。区間外だった場合は
    /// nil を返し、呼び出し側には復元シークごと諦めさせる(= カット開始位置から
    /// 素直に再生させる)。
    ///
    /// 下限は `loopStart` ではなく `trimStart`。イントロ区間
    /// (`trimStart ..< loopStart`)も再生される領域であり、そこへ戻しても
    /// カット終了位置まで進めば `AVPlayerLooper` が通常どおりループへ入るため。
    ///
    /// - Parameter itemDurationSeconds: 判明していれば `AVPlayerItem.duration`。
    ///   trimEnd 未設定のときの上限として使う。
    static func clampedResumeSeconds(
        _ requested: Double,
        trimStart: Double,
        trimEnd: Double?,
        itemDurationSeconds: Double?
    ) -> Double? {
        guard requested.isFinite else {
            return nil
        }
        var end = trimEnd ?? .infinity
        if let itemDurationSeconds, itemDurationSeconds.isFinite, itemDurationSeconds > 0 {
            end = min(end, itemDurationSeconds)
        }
        guard requested >= trimStart, requested <= end - resumeEndGuard else {
            return nil
        }
        return requested
    }
}

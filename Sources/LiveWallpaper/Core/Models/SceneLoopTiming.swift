import Foundation

/// How a baked loop times a steady motion so the loop closes.
enum SceneLoopTiming {
    /// How far a motion at `rate` per second has gone at `time`, wrapped to one `cycle`
    /// (the distance after which it looks the same); `loop` is the baked loop's length,
    /// nil on real time. A baked loop keeps the rate through its first half, then eases
    /// onto a whole number of cycles by the end, so the loop closes with no jump in place
    /// or speed. Rounding the rates themselves instead changed every speed for the whole
    /// loop and stopped the sines of a sway slower than half a turn per loop. A motion
    /// that `keepsDirection` (a scroll, a travelling wave, an animation clip) eases onto
    /// at least one cycle its own way rather than winding back; a swing eases onto the
    /// nearest count, which may be none.
    static func phase(rate: Double, cycle: Double, keepsDirection: Bool, time: Double, loop: Double?) -> Double {
        guard let loop else {
            return (rate * time).truncatingRemainder(dividingBy: cycle)
        }
        let time = timeInLoop(time, loop: loop)
        let late = max(0, time / loop * 2 - 1)
        let ease = late * late * (3 - 2 * late)
        let cycles = rate * loop / cycle
        var whole = cycles.rounded()
        if keepsDirection, rate != 0, abs(whole) < 1 { whole = rate < 0 ? -1 : 1 }
        return (rate * time - ease * (cycles - whole) * cycle).truncatingRemainder(dividingBy: cycle)
    }

    static func timeInLoop(_ time: Double, loop: Double) -> Double {
        let wrapped = time.truncatingRemainder(dividingBy: loop)
        return wrapped < 0 ? wrapped + loop : wrapped
    }
}

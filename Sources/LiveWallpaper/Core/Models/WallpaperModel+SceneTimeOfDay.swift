import AppKit
import Foundation

/// Scenes whose links follow the time of day are baked again when a part of the day
/// starts, so the lock screen, the screen saver and the desktop's video all show it.
/// Until the new video is ready the desktop draws the scene live (its video is stale).
/// Nothing changes while the app is not running.
@MainActor
extension WallpaperModel {
    func startSceneTimeOfDayUpdates() {
        if sceneTimeOfDayObservers.isEmpty {
            let workspace = NSWorkspace.shared.notificationCenter
            let center = NotificationCenter.default
            let handler: @Sendable (Notification) -> Void = { [weak self] _ in
                Task { @MainActor in
                    self?.updateSceneTimesOfDay()
                }
            }
            sceneTimeOfDayObservers = [
                workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: handler),
                center.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main, using: handler),
                center.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main, using: handler)
            ]
        }
        updateSceneTimesOfDay()
    }

    /// Rebakes the scenes whose video shows another part of the day than now, and sets
    /// the timer for the next time a part starts.
    func updateSceneTimesOfDay() {
        let now = Date()
        var changed = false
        for (path, document) in sceneDocumentsByPath where document.usesTimeOfDay {
            let current = document.timeOfDay(at: now)
            let baked = bakedTimeOfDay(path: path, document: document)
            guard baked != current else {
                continue
            }
            if let baked, document.looksSame(at: baked, as: current) {
                sceneBakedTimesOfDay[path] = current
                continue
            }
            AppLog.windowRefresh.info(
                "scene time of day path=\(path, privacy: .public) now=\(current.rawValue, privacy: .public)"
            )
            // A bake already writing this part of the day is left to finish.
            if scenesBakeRunning.contains(path), sceneBakingTimesOfDay[path] == current {
                continue
            }
            scheduleSceneBake(path: path)
            bakeSceneNowIfPending(path: path)
            changed = true
        }
        if changed {
            // Shows the scene live in the new part of the day until its video is ready.
            refreshCursorEffects()
        }
        scheduleNextSceneTimeOfDayUpdate(after: now)
    }

    func scheduleNextSceneTimeOfDayUpdate(after date: Date) {
        sceneTimeOfDayTimer?.invalidate()
        sceneTimeOfDayTimer = nil
        let next = sceneDocumentsByPath.values
            .filter(\.usesTimeOfDay)
            .compactMap { $0.nextTimeOfDayChange(after: date) }
            .min()
        guard let next else {
            return
        }
        let timer = Timer(fire: next.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.updateSceneTimesOfDay()
            }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        sceneTimeOfDayTimer = timer
    }

    /// What the video at `path` was baked with: recorded by this run's bakes, or the
    /// part of the day when the file was last written.
    private func bakedTimeOfDay(path: String, document: SceneDocument) -> SceneTimeOfDay? {
        if let recorded = sceneBakedTimesOfDay[path] {
            return recorded
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            return (attributes[.modificationDate] as? Date).map { document.timeOfDay(at: $0) }
        } catch {
            AppLog.windowRefresh.error("scene video date unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

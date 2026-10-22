import AppKit
import Combine

@MainActor
final class LocalWebIntegration: ObservableObject {
    static let shared = LocalWebIntegration()
    @Published private(set) var audioError: String?
    @Published private(set) var mediaError: String?
    @Published private(set) var audioRunning = false

    struct Subscription {
        var spectrum: Bool
        var media: Bool
        var receiveSpectrum: ([Float]) -> Void
        var receiveMedia: (WebNowPlaying, Bool) -> Void
    }

    private var subscriptions: [UUID: Subscription] = [:]
    private var capture: WebSystemAudioCapture?
    private var audioTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private var lastSpectrumAt = Date.distantPast
    private var sentSilence = true
    private var mediaTask: Task<Void, Never>?
    private var lastMedia = WebNowPlaying()
    private let reader = WebNowPlayingReader()

    func update(id: UUID, subscription: Subscription?) {
        let isNew = subscriptions[id] == nil
        subscriptions[id] = subscription
        if isNew, let subscription { subscription.receiveMedia(
            lastMedia,
            subscription.media && mediaError == nil
        ) }
        reconcile()
    }

    func retry() {
        audioError = nil
        mediaError = nil
        reconcile()
    }

    private func reconcile() {
        reconcileAudio()
        reconcileMedia()
    }

    private func reconcileAudio() {
        let needsAudio = subscriptions.values.contains { $0.spectrum }
        if needsAudio, capture == nil, audioTask == nil, audioError == nil {
            let capture = WebSystemAudioCapture(onSpectrum: { [weak self] values in
                Task { @MainActor in self?.deliverSpectrum(values) }
            }, onFailure: { [weak self] error in
                Task { @MainActor in self?.audioFailed(error) }
            })
            self.capture = capture
            audioTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await capture.start()
                    if Task.isCancelled {
                        try await capture.stop()
                    } else {
                        audioRunning = true
                        startSilenceTimer()
                    }
                } catch {
                    if !Task.isCancelled { audioFailed(error) }
                }
                audioTask = nil
                reconcile()
            }
        } else if !needsAudio, let capture {
            self.capture = nil
            audioRunning = false
            silenceTask?.cancel()
            silenceTask = nil
            if let starting = audioTask {
                starting.cancel()
            } else {
                audioTask = Task { [weak self] in
                    do {
                        try await capture.stop()
                    } catch {
                        AppLog.externalWallpapers
                            .error(
                                "system audio stop failed: \(error.localizedDescription, privacy: .public)"
                            )
                    }
                    self?.audioTask = nil
                    self?.reconcile()
                }
            }
        }
    }

    /// Reading every running app's bundle identifier blocks the caller for a while;
    /// a nonisolated async function runs off the main actor.
    private nonisolated static func runningBundleIdentifiers() async -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    private func reconcileMedia() {
        let needsMedia = subscriptions.values.contains { $0.media }
        if needsMedia, mediaTask == nil, mediaError == nil {
            mediaTask = Task { [weak self] in
                guard let self else { return }
                do {
                    while !Task.isCancelled {
                        let running = await Self.runningBundleIdentifiers()
                        let snapshot = try await reader.read(runningIDs: running)
                        try Task.checkCancellation()
                        lastMedia = snapshot
                        for item in subscriptions.values where item.media {
                            item.receiveMedia(
                                snapshot,
                                true
                            )
                        }
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    mediaTask = nil
                    mediaError = error.localizedDescription
                    AppLog.externalWallpapers
                        .error(
                            "media automation failed: \(error.localizedDescription, privacy: .public)"
                        )
                    for item in subscriptions.values where item.media {
                        item.receiveMedia(
                            WebNowPlaying(),
                            false
                        )
                    }
                }
            }
        } else if !needsMedia {
            mediaTask?.cancel()
            mediaTask = nil
            lastMedia = WebNowPlaying()
        }
    }

    private func startSilenceTimer() {
        silenceTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 200_000_000)
                    guard let self else { return }
                    if !sentSilence,
                       Date().timeIntervalSince(lastSpectrumAt) > 0.2
                    {
                        sentSilence = true
                        for item in subscriptions.values
                            where item.spectrum
                        {
                            item.receiveSpectrum([Float](
                                repeating: 0,
                                count: 128
                            ))
                        }
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                AppLog.externalWallpapers
                    .error(
                        "spectrum silence timer failed: \(error.localizedDescription, privacy: .public)"
                    )
            }
        }
    }

    private func audioFailed(_ error: Error) {
        audioError = error.localizedDescription
        audioRunning = false
        silenceTask?.cancel()
        silenceTask = nil
        AppLog.externalWallpapers
            .error("system audio capture failed: \(error.localizedDescription, privacy: .public)")
        for item in subscriptions.values where item.spectrum {
            item.receiveSpectrum([Float](
                repeating: 0,
                count: 128
            ))
        }
        if let capture {
            self.capture = nil
            Task {
                do {
                    try await capture.stop()
                } catch {
                    AppLog.externalWallpapers
                        .error(
                            "system audio cleanup failed: \(error.localizedDescription, privacy: .public)"
                        )
                }
            }
        }
    }

    private func deliverSpectrum(_ values: [Float]) {
        lastSpectrumAt = Date()
        sentSilence = false
        for item in subscriptions.values where item.spectrum {
            item.receiveSpectrum(values)
        }
    }
}

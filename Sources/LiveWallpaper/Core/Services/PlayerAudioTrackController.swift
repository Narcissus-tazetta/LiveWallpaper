import AVFoundation

@MainActor
final class PlayerAudioTrackController {
    private weak var player: AVPlayer?
    private var observedItem: AVPlayerItem?
    private var itemObservation: NSKeyValueObservation?
    private var tracksObservation: NSKeyValueObservation?
    /// Looper reuses items with our muted flag. Preserve their original state
    /// across passes without keeping retired tracks and media resources alive.
    private let originalAudioStates = NSMapTable<AVPlayerItemTrack, NSNumber>(
        keyOptions: .weakMemory, valueOptions: .strongMemory
    )

    var isAudioEnabled: Bool {
        didSet { updateTracks() }
    }

    init(player: AVPlayer, isAudioEnabled: Bool) {
        self.player = player
        self.isAudioEnabled = isAudioEnabled
        // Looper inserts copies of its template; configuring only the template
        // leaves audio processing enabled again at the next loop boundary.
        itemObservation = player.observe(\.currentItem, options: [
            .initial,
            .new
        ]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.observeCurrentItem() }
        }
    }

    private func observeCurrentItem() {
        let item = player?.currentItem
        guard observedItem !== item else { return }
        tracksObservation = nil
        observedItem = item
        // tracks is empty until AVFoundation finishes loading the item.
        tracksObservation = item?.observe(\.tracks, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateTracks() }
        }
    }

    private func updateTracks() {
        guard observedItem === player?.currentItem else {
            observeCurrentItem()
            return
        }
        for track in observedItem?.tracks ?? [] where track.assetTrack?.mediaType == .audio {
            if originalAudioStates.object(forKey: track) == nil {
                originalAudioStates.setObject(NSNumber(value: track.isEnabled), forKey: track)
            }
            // Muting the player alone keeps audio processing running. Preserve
            // the original selection so alternate audio tracks stay disabled.
            track.isEnabled = isAudioEnabled && originalAudioStates.object(forKey: track)!.boolValue
        }
    }
}

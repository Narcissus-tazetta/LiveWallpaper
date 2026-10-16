import AVFoundation
@testable import LiveWallpaper
import XCTest

@MainActor
final class PlayerAudioTrackControllerTests: XCTestCase {
    private func fixture(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("audio.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
        buffer.frameLength = buffer.frameCapacity
        for index in 0 ..< Int(buffer.frameLength) {
            buffer
                .floatChannelData![0][index] = Float(sin(Double(index) * 440 * 2 * .pi / 44100)) *
                0.1
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "AVFoundation did not reach the expected state")
    }

    func testMutedAudioStaysDisabledAcrossLoopsAndCanBeRestored() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioTracks-\(UUID())")
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = try fixture(in: directory)
        let player = AVQueuePlayer()
        player.isMuted = true
        let controller = PlayerAudioTrackController(player: player, isAudioEnabled: false)
        let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        defer {
            player.pause()
            looper.disableLooping()
            player.removeAllItems()
        }
        player.play()
        try await waitUntil {
            player.currentItem?.tracks
                .contains { $0.assetTrack?.mediaType == .audio && !$0.isEnabled } == true
        }
        let firstItem = try XCTUnwrap(player.currentItem)
        let replicaCount = looper.loopingPlayerItems.count
        try await waitUntil(timeout: Double(replicaCount) + 5) {
            looper.loopCount > replicaCount && player.currentItem !== firstItem
        }
        try await waitUntil { player.currentItem?.tracks.first?.isEnabled == false }
        XCTAssertGreaterThan(player.rate, 0)
        controller.isAudioEnabled = true
        XCTAssertEqual(player.currentItem?.tracks.first?.isEnabled, true)
        let restoredAtLoop = looper.loopCount
        try await waitUntil { looper.loopCount > restoredAtLoop }
        try await waitUntil { player.currentItem?.tracks.first?.isEnabled == true }
        controller.isAudioEnabled = false
        XCTAssertEqual(player.currentItem?.tracks.first?.isEnabled, false)

        looper.disableLooping()
        player.removeAllItems()
        player.insert(AVPlayerItem(url: url), after: nil)
        player.play()
        try await waitUntil { player.currentItem?.tracks.first?.isEnabled == false }
        controller.isAudioEnabled = true
        XCTAssertEqual(player.currentItem?.tracks.first?.isEnabled, true)

        weak var retiredItem = player.currentItem
        player.removeAllItems()
        try await waitUntil { retiredItem == nil }
        XCTAssertTrue(controller.isAudioEnabled)
    }

    func testEnablingAudioPreservesOriginallyDisabledTracks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioSelection-\(UUID())")
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = try fixture(in: directory)
        let composition = AVMutableComposition()
        let asset = AVURLAsset(url: url)
        let sourceTracks = try await asset.loadTracks(withMediaType: .audio)
        let source = try XCTUnwrap(sourceTracks.first)
        for _ in 0 ..< 2 {
            let track = try XCTUnwrap(composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ))
            try track.insertTimeRange(
                CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)),
                of: source,
                at: .zero
            )
        }
        let item = AVPlayerItem(asset: composition)
        let player = AVQueuePlayer(playerItem: item)
        player.isMuted = true
        defer { player.pause(); player.removeAllItems() }
        player.play()
        try await waitUntil { item.tracks.count == 2 }
        item.tracks[0].isEnabled = true
        item.tracks[1].isEnabled = false
        let controller = PlayerAudioTrackController(player: player, isAudioEnabled: false)
        try await waitUntil { item.tracks.allSatisfy { !$0.isEnabled } }
        controller.isAudioEnabled = true
        XCTAssertTrue(item.tracks[0].isEnabled)
        XCTAssertFalse(item.tracks[1].isEnabled)
    }
}

import AppKit
import Carbon
import ImageIO

struct WebNowPlaying: Codable, Equatable {
    var title = ""
    var artist = ""
    var album = ""
    var duration: Double = 0
    var position: Double = 0
    var state = "stopped"
    var artwork = ""
    var source = ""
    var trackID = ""
    var primaryColor = "#202020"
    var textColor = "#ffffff"
}

final class WebNowPlayingReader: @unchecked Sendable {
    private let artwork = WebMediaArtwork()
    private let queue = DispatchQueue(label: "LiveWallpaper.webNowPlaying", qos: .utility)
    private var artworkCache: [String: String] = [:]
    private var previouslyPlaying: Set<String> = []
    private var preferredSource: String?

    func read(runningIDs: Set<String>) async throws -> WebNowPlaying {
        let value: WebNowPlaying = try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try continuation.resume(returning: readSynchronously(runningIDs: runningIDs))
                } catch { continuation.resume(throwing: error) }
            }
        }
        return try await artwork.decorate(value)
    }

    private func readSynchronously(runningIDs: Set<String>) throws -> WebNowPlaying {
        var snapshots: [WebNowPlaying] = []
        for id in ["com.apple.Music", "com.spotify.client"] where runningIDs.contains(id) {
            let spotify = id == "com.spotify.client"
            let target = NSAppleEventDescriptor(bundleIdentifier: id)
            let playback = try get(property("pPlS"), target: target).enumCodeValue
            guard playback != code("kPSS") else { continue }
            let track = property("pTrk")
            var value = WebNowPlaying()
            value.state = playback == code("kPSp") ? "paused" : "playing"
            value.title = try get(property("pnam", inside: track), target: target).stringValue ?? ""
            value.artist = try get(property(
                "pArt",
                inside: track
            ), target: target).stringValue ?? ""
            value.album = try get(property("pAlb", inside: track), target: target).stringValue ?? ""
            value.duration = try get(property("pDur", inside: track), target: target).doubleValue
            // Spotify's Apple event duration uses milliseconds; Music uses seconds.
            if spotify { value.duration /= 1000 }
            value.position = try get(property("pPos"), target: target).doubleValue
            value.trackID = try get(
                property(spotify ? "ID  " : "pPIS", inside: track),
                target: target
            ).stringValue ?? ""
            value.source = id
            if spotify {
                value.artwork = try get(property("aUrl", inside: track), target: target)
                    .stringValue ?? ""
            } else {
                let key = id + ":" + value.trackID
                if let cached = artworkCache[key] {
                    value.artwork = cached
                } else {
                    let artwork = NSAppleEventDescriptor.record()
                    artwork.setDescriptor(
                        NSAppleEventDescriptor(typeCode: code("cArt")),
                        forKeyword: UInt32(keyAEDesiredClass)
                    )
                    artwork.setDescriptor(track, forKeyword: UInt32(keyAEContainer))
                    artwork.setDescriptor(
                        NSAppleEventDescriptor(enumCode: UInt32(formAbsolutePosition)),
                        forKeyword: UInt32(keyAEKeyForm)
                    )
                    artwork.setDescriptor(
                        NSAppleEventDescriptor(int32: 1),
                        forKeyword: UInt32(keyAEKeyData)
                    )
                    let firstArtwork = artwork
                        .coerce(toDescriptorType: UInt32(typeObjectSpecifier))!
                    do {
                        let raw = try get(property("pRaw", inside: firstArtwork), target: target)
                        if let source = CGImageSourceCreateWithData(raw.data as CFData, nil),
                           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                               kCGImageSourceCreateThumbnailFromImageAlways: true,
                               kCGImageSourceThumbnailMaxPixelSize: 512
                           ] as CFDictionary),
                           let png = NSBitmapImageRep(cgImage: image).representation(
                               using: .png,
                               properties: [:]
                           )
                        {
                            value.artwork = "data:image/png;base64," + png.base64EncodedString()
                        }
                    } catch let error as NSError where error.code == errAENoSuchObject {
                        value.artwork = ""
                    }
                    artworkCache = [key: value.artwork]
                }
            }
            snapshots.append(value)
        }
        let playing = Set(snapshots.filter { $0.state == "playing" }.map(\.source))
        if let newlyPlaying = playing.subtracting(previouslyPlaying).sorted()
            .first { preferredSource = newlyPlaying }
        previouslyPlaying = playing
        return snapshots.first { $0.source == preferredSource && $0.state == "playing" }
            ?? snapshots.first { $0.state == "playing" }
            ?? snapshots.first { $0.source == preferredSource } ?? snapshots
            .first ?? WebNowPlaying()
    }

    private func code(_ value: String) -> OSType {
        value.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }

    private func property(
        _ code: String,
        inside container: NSAppleEventDescriptor = NSAppleEventDescriptor.null()
    ) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(
            NSAppleEventDescriptor(typeCode: UInt32(typeProperty)),
            forKeyword: UInt32(keyAEDesiredClass)
        )
        record.setDescriptor(container, forKeyword: UInt32(keyAEContainer))
        record.setDescriptor(
            NSAppleEventDescriptor(enumCode: UInt32(formPropertyID)),
            forKeyword: UInt32(keyAEKeyForm)
        )
        record.setDescriptor(
            NSAppleEventDescriptor(typeCode: self.code(code)),
            forKeyword: UInt32(keyAEKeyData)
        )
        return record.coerce(toDescriptorType: UInt32(typeObjectSpecifier))!
    }

    private func get(
        _ object: NSAppleEventDescriptor,
        target: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: kAECoreSuite,
            eventID: kAEGetData,
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(object, forKeyword: keyDirectObject)
        let reply = try event.sendEvent(options: [.waitForReply], timeout: 2)
        if let number = reply.paramDescriptor(forKeyword: keyErrorNumber), number.int32Value != 0 {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(number.int32Value), userInfo: [
                NSLocalizedDescriptionKey: reply.paramDescriptor(forKeyword: keyErrorString)?
                    .stringValue ?? "Apple event error \(number.int32Value)"
            ])
        }
        guard let value = reply.paramDescriptor(forKeyword: keyDirectObject)
        else { throw CocoaError(.coderReadCorrupt) }
        return value
    }
}

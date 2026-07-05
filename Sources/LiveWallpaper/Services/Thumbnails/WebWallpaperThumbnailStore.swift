import AppKit
import Foundation

@MainActor
final class WebWallpaperThumbnailStore: ObservableObject {
    @Published private(set) var imagesBySourceID: [UUID: NSImage] = [:]

    private var inFlight: Set<UUID> = []
    private var attempted: Set<UUID> = []

    func image(for sourceID: UUID) -> NSImage? {
        imagesBySourceID[sourceID]
    }

    func loadIfNeeded(for source: WebWallpaperSource) {
        guard imagesBySourceID[source.id] == nil else {
            return
        }
        guard !inFlight.contains(source.id), !attempted.contains(source.id) else {
            return
        }

        if let directURL = WebWallpaperThumbnailProvider.directThumbnailURL(for: source.url) {
            fetchImage(from: directURL, sourceID: source.id)
            return
        }

        attempted.insert(source.id)
        inFlight.insert(source.id)
        let sourceID = source.id
        let pageURL = source.url
        Task {
            let image = await WebWallpaperThumbnailProvider.fetchResolvedThumbnail(for: pageURL)
            if let image {
                imagesBySourceID[sourceID] = image
            }
            inFlight.remove(sourceID)
        }
    }

    func remove(sourceID: UUID) {
        imagesBySourceID.removeValue(forKey: sourceID)
        inFlight.remove(sourceID)
        attempted.remove(sourceID)
    }

    func prune(validSourceIDs: Set<UUID>) {
        imagesBySourceID = imagesBySourceID.filter { validSourceIDs.contains($0.key) }
        inFlight = inFlight.intersection(validSourceIDs)
        attempted = attempted.intersection(validSourceIDs)
    }

    private func fetchImage(from url: URL, sourceID: UUID) {
        inFlight.insert(sourceID)
        Task {
            let image = await WebWallpaperThumbnailProvider.downloadImage(from: url)
            if let image {
                imagesBySourceID[sourceID] = image
            } else {
                attempted.insert(sourceID)
            }
            inFlight.remove(sourceID)
        }
    }
}

enum WebWallpaperThumbnailProvider {
    static func directThumbnailURL(for url: URL) -> URL? {
        guard let videoID = WebWallpaperURLResolver.youtubeVideoID(from: url) else {
            return nil
        }
        return URL(string: "https://img.youtube.com/vi/\(videoID)/mqdefault.jpg")
    }

    static func fetchResolvedThumbnail(for url: URL) async -> NSImage? {
        if WebWallpaperURLResolver.vimeoVideoID(from: url) != nil {
            if let image = await fetchVimeoThumbnail(pageURL: url) {
                return image
            }
        }
        guard let host = url.host else {
            return nil
        }
        for candidate in [
            URL(string: "https://\(host)/favicon.ico"),
            URL(string: "https://\(host)/apple-touch-icon.png"),
        ].compactMap({ $0 }) {
            if let image = await downloadImage(from: candidate) {
                return image
            }
        }
        return nil
    }

    static func downloadImage(from url: URL) async -> NSImage? {
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) LiveWallpaper/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                return nil
            }
            return NSImage(data: data)
        } catch {
            return nil
        }
    }

    private static func fetchVimeoThumbnail(pageURL: URL) async -> NSImage? {
        var components = URLComponents(string: "https://vimeo.com/api/oembed.json")!
        components.queryItems = [URLQueryItem(name: "url", value: pageURL.absoluteString)]
        guard let oembedURL = components.url else {
            return nil
        }

        var request = URLRequest(url: oembedURL, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) LiveWallpaper/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                return nil
            }
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let thumbnailURLString = json["thumbnail_url"] as? String,
                let thumbnailURL = URL(string: thumbnailURLString)
            else {
                return nil
            }
            return await downloadImage(from: thumbnailURL)
        } catch {
            return nil
        }
    }
}

import AppKit
import ImageIO

actor WebMediaArtwork {
    private var cachedURL = ""
    private struct CachedArtwork {
        var data: String
        var background: String
        var text: String
    }

    private var cached: CachedArtwork?

    func decorate(_ input: WebNowPlaying) async throws -> WebNowPlaying {
        var result = input
        guard !input.artwork.isEmpty else { return result }
        if cachedURL == input.artwork, let cached {
            result.artwork = cached.data
            result.primaryColor = cached.background
            result.textColor = cached.text
            return result
        }
        let imageData: Data
        if input.artwork.hasPrefix("https://"), let url = URL(string: input.artwork) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count <= 8 * 1024 * 1024
            else {
                throw CocoaError(.fileReadCorruptFile)
            }
            imageData = data
        } else if input.artwork.hasPrefix("data:image/"),
                  let separator = input.artwork.firstIndex(of: ","),
                  let data =
                  Data(base64Encoded: String(input
                          .artwork[input.artwork.index(after: separator)...]))
        {
            imageData = data
        } else { throw CocoaError(.fileReadCorruptFile) }
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 512
              ] as CFDictionary),
              let png = NSBitmapImageRep(cgImage: image).representation(
                  using: .png,
                  properties: [:]
              )
        else { throw CocoaError(.fileReadCorruptFile) }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            let context = CGContext(
                data: bytes.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        result.artwork = "data:image/png;base64," + png.base64EncodedString()
        result.primaryColor = String(format: "#%02x%02x%02x", pixel[0], pixel[1], pixel[2])
        func linear(_ byte: UInt8) -> Double {
            let value = Double(byte) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(pixel[0]) + 0.7152 * linear(pixel[1]) + 0.0722 *
            linear(pixel[2])
        result.textColor = luminance > 0.179 ? "#000000" : "#ffffff"
        cachedURL = input.artwork
        cached = CachedArtwork(
            data: result.artwork,
            background: result.primaryColor,
            text: result.textColor
        )
        return result
    }
}

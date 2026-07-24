import AVFoundation
import AppKit

extension LightweightProxyCache {
    private enum TranscodeEligibility {
        case passthrough
        case needsTranscode(AVMutableVideoComposition)
    }

    private final class ExportSessionBox: @unchecked Sendable {
        let session: AVAssetExportSession

        init(_ session: AVAssetExportSession) {
            self.session = session
        }
    }

    func performGeneration(path: String, activeGeneration: ActiveGeneration) async -> GenerationResult {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSizeNumber = attributes[.size] as? NSNumber,
              let modifiedDate = attributes[.modificationDate] as? Date
        else {
            return .failed
        }
        let fileSize = fileSizeNumber.uint64Value

        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let eligibility: TranscodeEligibility
        do {
            eligibility = try await evaluateEligibility(asset: asset)
        } catch {
            return .failed
        }

        guard case .needsTranscode(let composition) = eligibility else {
            recordEntry(
                path: path,
                fileName: nil,
                isPassthrough: true,
                fileSize: fileSize,
                modifiedDate: modifiedDate
            )
            return .passthrough
        }

        guard Task.isCancelled == false else {
            return .cancelled
        }

        guard let dataURL = Self.dataDirectoryURL() else {
            return .failed
        }
        try? FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true)

        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetMediumQuality
        ) else {
            return .failed
        }

        let outputFileType: AVFileType = exportSession.supportedFileTypes.contains(.mp4) ? .mp4 : .mov
        let fileExtension = outputFileType == .mp4 ? "mp4" : "mov"
        let fileName = "\(CacheKeyHashing.hashed(path)).\(fileExtension)"
        let finalURL = dataURL.appendingPathComponent(fileName)
        let tmpURL = dataURL.appendingPathComponent("\(fileName).tmp")
        try? FileManager.default.removeItem(at: tmpURL)

        exportSession.outputURL = tmpURL
        exportSession.outputFileType = outputFileType
        exportSession.videoComposition = composition
        exportSession.shouldOptimizeForNetworkUse = true

        activeGeneration.session = exportSession

        let exportSessionBox = ExportSessionBox(exportSession)
        let status: AVAssetExportSession.Status = await withCheckedContinuation { continuation in
            exportSessionBox.session.exportAsynchronously {
                continuation.resume(returning: exportSessionBox.session.status)
            }
        }

        switch status {
        case .completed:
            do {
                if FileManager.default.fileExists(atPath: finalURL.path) {
                    _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: tmpURL)
                } else {
                    try FileManager.default.moveItem(at: tmpURL, to: finalURL)
                }
            } catch {
                try? FileManager.default.removeItem(at: tmpURL)
                return .failed
            }
            recordEntry(
                path: path,
                fileName: fileName,
                isPassthrough: false,
                fileSize: fileSize,
                modifiedDate: modifiedDate
            )
            trimDiskIfNeeded()
            return .ready(finalURL)
        case .cancelled:
            try? FileManager.default.removeItem(at: tmpURL)
            return .cancelled
        default:
            try? FileManager.default.removeItem(at: tmpURL)
            return .failed
        }
    }

    private func evaluateEligibility(asset: AVURLAsset) async throws -> TranscodeEligibility {
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds >= 1.0 else {
            return .passthrough
        }

        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            return .passthrough
        }

        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        let transformed = naturalSize.applying(preferredTransform)
        let width = abs(transformed.width)
        let height = abs(transformed.height)
        let longEdge = max(width, height)

        let targetLongEdge = Self.targetLongEdge
        let targetFrameRate = Self.targetFrameRate
        if longEdge <= targetLongEdge * 1.1, nominalFrameRate <= targetFrameRate * 1.1 {
            return .passthrough
        }

        let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        let scale = min(1.0, longEdge > 0 ? targetLongEdge / longEdge : 1.0)
        let newWidth = max((width * scale).rounded(), 2)
        let newHeight = max((height * scale).rounded(), 2)

        // videoComposition(withPropertiesOf:) already computes a correct transform
        // (orientation + any translation needed for preferredTransform) sized for
        // its *original* renderSize. Shrinking renderSize alone, without scaling
        // that same transform, leaves the layer instructions positioning/sizing
        // the frame as if the canvas were still the original (larger) size —
        // which crops into the frame instead of scaling it down, appearing as an
        // unwanted zoom. Scale each layer instruction's existing transform by the
        // same factor as renderSize so the whole frame shrinks uniformly.
        let scaleTransform = CGAffineTransform(scaleX: scale, y: scale)
        for instruction in composition.instructions {
            guard let mutableInstruction = instruction as? AVMutableVideoCompositionInstruction else {
                continue
            }
            for layerInstruction in mutableInstruction.layerInstructions {
                guard let mutableLayerInstruction = layerInstruction as? AVMutableVideoCompositionLayerInstruction
                else {
                    continue
                }
                var existingTransform = CGAffineTransform.identity
                _ = mutableLayerInstruction.getTransformRamp(
                    for: .zero,
                    start: &existingTransform,
                    end: nil,
                    timeRange: nil
                )
                mutableLayerInstruction.setTransform(
                    existingTransform.concatenating(scaleTransform),
                    at: .zero
                )
            }
        }
        composition.renderSize = CGSize(width: newWidth, height: newHeight)

        let minFrameDuration = CMTime(value: 1, timescale: Int32(targetFrameRate))
        if composition.frameDuration < minFrameDuration {
            composition.frameDuration = minFrameDuration
        }
        return .needsTranscode(composition)
    }
}

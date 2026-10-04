@preconcurrency import AVFoundation
import UtsushieCore

struct VideoStillArtifact: Sendable {
    let artifact: SharedArtifact
    let data: Data
    let image: CGImage
    var clipboardEntry: ClipboardEntry { ClipboardEntry(artifact: artifact, data: data) }
}

enum VideoStillExporter {
    static func frame(source: URL, time: Double, maximumSize: CGSize = .zero) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true; generator.maximumSize = maximumSize
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let result = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60000))
        guard abs(result.actualTime.seconds - time) <= 1 / 60000.0 else {
            throw CaptureError.unavailable("指定したコマを正確に取り出せませんでした")
        }
        return result.image
    }
    static func save(source: URL, marks: [VideoStillMark], directory: URL, quality: Double, lossless: Bool) async throws -> [VideoStillArtifact] {
        var result: [VideoStillArtifact] = []
        do {
            let date = Date()
            for mark in marks {
                try Task.checkCancellation()
                let image = try await frame(source: source, time: mark.time)
                let data = try WebPEncoder.encode(image, quality: quality, lossless: lossless)
                let url = try ArtifactStore.save(data: data, kind: .webP, directory: directory, date: date)
                result.append(VideoStillArtifact(artifact: SharedArtifact(url: url, kind: .webP, width: image.width,
                    height: image.height, byteCount: data.count), data: data, image: image))
            }
            return result
        } catch {
            remove(result); throw error
        }
    }
    static func remove(_ stills: [VideoStillArtifact]) {
        for still in stills { try? FileManager.default.removeItem(at: still.artifact.url) }
    }
}

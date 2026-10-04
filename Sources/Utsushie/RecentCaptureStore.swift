import AppKit
import ImageIO
@preconcurrency import AVFoundation
import UtsushieCore

struct LoadedCapture: Sendable {
    let artifact: SharedArtifact
    let image: CGImage
}

enum RecentCaptureStore {
    static func files(in directory: URL) throws -> [RecentCaptureFile] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isHiddenKey, .contentModificationDateKey]
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
        return RecentCaptures.newest(files.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return RecentCaptureFile(url: url.standardizedFileURL, date: values.contentModificationDate ?? .distantPast,
                isRegularFile: values.isRegularFile == true, isHidden: values.isHidden == true)
        })
    }
    /// メニューは小さい絵だけを読む。再表示時に記憶が無い画像だけ全ピクセルをデコードする。
    static func load(_ file: RecentCaptureFile, maximumPixelSize: Int? = nil) async throws -> LoadedCapture {
        guard let kind = file.kind else { throw CaptureError.unavailable("この形式は開けません") }
        let bytes = try FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? NSNumber
        if kind == .webP {
            return try await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int else {
                    throw CaptureError.unavailable("保存したWebPを読めませんでした")
                }
                let image: CGImage?
                if let maximumPixelSize {
                    image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                        kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
                } else { image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) }
                guard let image else { throw CaptureError.unavailable("保存したWebPを読めませんでした") }
                return LoadedCapture(artifact: SharedArtifact(url: file.url, kind: .webP, width: width, height: height,
                    byteCount: bytes?.intValue ?? 0), image: image)
            }.value
        }
        let asset = AVURLAsset(url: file.url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CaptureError.unavailable("保存したMP4を読めませんでした")
        }
        let size = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw CaptureError.unavailable("動画の長さを読めませんでした") }
        let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
        if let maximumPixelSize { generator.maximumSize = CGSize(width: maximumPixelSize, height: maximumPixelSize) }
        let image = try await generator.image(at: .zero).image
        return LoadedCapture(artifact: SharedArtifact(url: file.url, kind: .mp4, width: Int(size.width), height: Int(size.height),
            byteCount: bytes?.intValue ?? 0, duration: duration), image: image)
    }
}

@MainActor
final class ImageEditState {
    let original: CGImage
    var history: AnnotationHistory
    init(original: CGImage, history: AnnotationHistory = AnnotationHistory()) {
        self.original = original; self.history = history
    }
}

@MainActor
final class RecentImageMemory {
    private var states: [URL: ImageEditState] = [:]
    var count: Int { states.count }
    func state(for url: URL) -> ImageEditState? { states[url.standardizedFileURL] }
    func remember(_ state: ImageEditState, at url: URL, among files: [RecentCaptureFile]) {
        retain(files)
        let url = url.standardizedFileURL
        guard RecentCaptures.newest(files).contains(where: { $0.url.standardizedFileURL == url }) else { return }
        states[url] = state
    }
    func retain(_ files: [RecentCaptureFile]) {
        let urls = Set(RecentCaptures.newest(files).map { $0.url.standardizedFileURL })
        states = states.filter { urls.contains($0.key) }
    }
}

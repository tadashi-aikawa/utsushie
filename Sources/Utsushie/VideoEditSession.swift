import AppKit
import UtsushieCore

@MainActor
final class VideoEditSession {
    private(set) var originalURL: URL?
    var document: VideoEditDocument
    private var savedDocument: VideoEditDocument
    var needsExport: Bool { document.kept != savedDocument.kept || document.transitions != savedDocument.transitions }
    private let url: URL
    private let fps: Int
    private let rememberDirectory: @MainActor (URL) -> Void
    var sourceURL: URL { originalURL ?? url }
    init(artifact: SharedArtifact, fps: Int, rememberDirectory: @escaping @MainActor (URL) -> Void = VideoEditStore.rememberDirectory) {
        url = artifact.url; self.fps = artifact.videoFPS ?? fps
        self.rememberDirectory = rememberDirectory
        document = VideoEditDocument(duration: artifact.duration ?? 0)
        savedDocument = document
    }
    func save(artifact: SharedArtifact, copy: (SharedArtifact) -> Bool) async throws -> (SharedArtifact, CGImage) {
        let temporary = VideoEditStore.temporaryURL(for: url)
        let rollback = VideoEditStore.temporaryURL(for: url)
        defer {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: rollback)
        }
        rememberDirectory(url.deletingLastPathComponent())
        let result = try await VideoEditExporter.export(source: sourceURL, destination: temporary, document: document, fps: fps)
        let bytes = try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber
        var updated = artifact
        updated.duration = document.outputDuration; updated.byteCount = bytes?.intValue ?? 0
        updated.width = result.width; updated.height = result.height
        // コピー失敗でも公開中の動画を以前のバイトへ戻せる。動画全体をメモリに載せない。
        try FileManager.default.copyItem(at: url, to: rollback)
        originalURL = try VideoEditStore.replace(temporary: temporary, target: url, original: originalURL)
        guard copy(updated) else {
            _ = try VideoEditStore.replace(temporary: rollback, target: url, original: originalURL)
            throw CaptureError.unavailable("クリップボードへコピーできませんでした。動画は変更前に戻しました")
        }
        savedDocument = document
        return (updated, result.image)
    }
    func close() { VideoEditStore.removeOriginal(originalURL); originalURL = nil }
    struct Result {
        var video: SharedArtifact
        var image: CGImage?
        var stills: [VideoStillArtifact]
    }
    /// 静止画を先に用意し、動画とコピーまで成功した後だけカードへ公開する。
    func finish(artifact: SharedArtifact, config: UtsushieConfig, copy: ([ClipboardEntry]) -> Bool) async throws -> Result {
        let stills = try await VideoStillExporter.save(source: sourceURL, marks: document.stills,
            directory: url.deletingLastPathComponent(), quality: config.quality, lossless: config.lossless)
        do {
            if needsExport {
                let (video, image) = try await save(artifact: artifact) { updated in
                    copy(stills.isEmpty ? [ClipboardEntry(artifact: updated)] : stills.map(\.clipboardEntry))
                }
                return Result(video: video, image: image, stills: stills)
            }
            guard copy(stills.isEmpty ? [ClipboardEntry(artifact: artifact)] : stills.map(\.clipboardEntry)) else {
                throw CaptureError.unavailable("クリップボードへコピーできませんでした")
            }
            return Result(video: artifact, image: nil, stills: stills)
        } catch {
            VideoStillExporter.remove(stills); throw error
        }
    }
}

import AppKit
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import AVFoundation
import UtsushieCore

/// 保存フォルダへ写したファイル。以後は撮影したものと同じカード・編集の流れに乗せる。
struct ImportedCapture: Sendable {
    let artifact: SharedArtifact
    let image: CGImage
    /// 書式の展開結果が使えず、既定の名前で保存した。呼び出し側がメニューの警告へ出す。
    let usedDefaultName: Bool
}

/// Finderの右クリックから渡された画像・動画を、元を変えずに保存フォルダへ写す。
enum CaptureImporter {
    static func media(of url: URL) -> CaptureImportMedia? {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return nil }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        return nil
    }
    static func importFile(_ url: URL, media: CaptureImportMedia, action: CaptureImportAction, config: UtsushieConfig,
                           date: Date = Date()) async throws -> ImportedCapture {
        switch action {
        case .copyWebP, .encodeImage:
            return try await Task.detached(priority: .userInitiated) {
                try importImage(url, copiesBytes: action == .copyWebP, config: config, date: date)
            }.value
        case .copyMP4, .convertVideo:
            return try await importVideo(url, config: config, date: date)
        case .editInPlace:
            throw CaptureError.unavailable("保存フォルダのファイルは写さずに編集します")
        }
    }

    // MARK: 画像

    static func importImage(_ url: URL, copiesBytes: Bool, config: UtsushieConfig, date: Date) throws -> ImportedCapture {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let image = decode(source, properties: properties) else { throw CaptureError.unavailable("画像を読めませんでした") }
        guard CaptureImport.fitsWebP(width: image.width, height: image.height) else {
            throw CaptureError.unavailable(CaptureImport.tooLargeMessage(width: image.width, height: image.height))
        }
        // WebPは再圧縮で劣化させないよう、読めることを確かめたうえでバイト列をそのまま写す。
        let data = copiesBytes ? try Data(contentsOf: url)
            : try WebPEncoder.encode(image, quality: config.quality, lossless: config.lossless)
        let saved = try ArtifactStore.save(data: data, kind: .webP, directory: config.outputURL(), date: date, pattern: config.fileName)
        let scale = CaptureImport.pixelScale(dpiWidth: (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue,
                                             dpiHeight: (properties[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue)
        let artifact = SharedArtifact(url: saved.url, kind: .webP, width: image.width, height: image.height,
                                      byteCount: data.count, pixelScale: scale)
        return ImportedCapture(artifact: artifact, image: image, usedDefaultName: saved.usedDefaultName)
    }
    /// 最初の1枚だけを全画素で読む。EXIFの向きがあれば回してから渡す。
    private static func decode(_ source: CGImageSource, properties: [CFString: Any]) -> CGImage? {
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard orientation != 1, let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    // MARK: 動画

    private static func importVideo(_ url: URL, config: UtsushieConfig, date: Date) async throws -> ImportedCapture {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CaptureError.unavailable("映像の入った動画ではありません")
        }
        let (transform, nominal) = try await track.load(.preferredTransform, .nominalFrameRate)
        let directory = config.outputURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 録画と同じく隠し一時ファイルへ書き、完成してから衝突しない名前へ改名する。
        var temporary: URL? = directory.appendingPathComponent(".utsushie-import-\(UUID().uuidString).mp4")
        var published: URL?
        defer {
            if let temporary { try? FileManager.default.removeItem(at: temporary) }
        }
        do {
            let target = temporary!
            if url.pathExtension.lowercased() == "mp4" && transform.isIdentity {
                try FileManager.default.copyItem(at: url, to: target)
            } else {
                try await convert(asset, to: target, transform: transform)
            }
            let saved = try ArtifactStore.publishVideo(from: target, date: date, pattern: config.fileName)
            temporary = nil; published = saved.url
            let loaded = try await RecentCaptureStore.load(RecentCaptureFile(url: saved.url, date: date), maximumPixelSize: 320)
            var artifact = loaded.artifact
            artifact.videoFPS = CaptureImport.frameRate(nominal: nominal)
            return ImportedCapture(artifact: artifact, image: loaded.image, usedDefaultName: saved.usedDefaultName)
        } catch {
            // 公開した後で読めなかった動画は、保存フォルダに残さない。
            if let published { try? FileManager.default.removeItem(at: published) }
            throw error
        }
    }
    /// MP4へ入れ替えられれば中身はそのまま。向きの指定は再エンコードで焼き込む。
    /// 理由: 編集のズームの矩形と早送りの印は回す前の画素の向きで計算するので、向きの指定が残ると見た位置とずれる。
    private static func convert(_ asset: AVURLAsset, to target: URL, transform: CGAffineTransform) async throws {
        let passthrough = transform.isIdentity
            ? await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: .mp4)
            : false
        let preset = passthrough ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw CaptureError.unavailable("この動画はMP4へ書き出せません")
        }
        if !transform.isIdentity { session.videoComposition = try await AVVideoComposition.videoComposition(withPropertiesOf: asset) }
        try await session.export(to: target, as: .mp4)
    }
}

import AppKit
import UtsushieCore

enum ArtifactKind: Sendable {
    case webP, mp4
    var fileExtension: String { self == .webP ? "webp" : "mp4" }
    var pasteboardType: NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType(self == .webP ? "org.webmproject.webp" : "public.mpeg-4")
    }
    var label: String { self == .webP ? "WebP" : "MP4" }
}
struct SharedArtifact: Sendable {
    var url: URL
    var kind: ArtifactKind
    var width: Int
    var height: Int
    var byteCount: Int
    var duration: Double? = nil
}

enum ArtifactStore {
    /// 完成したMP4だけを公開する。移動は同一フォルダ内なので原子的。既存名は上書きしない。
    static func publishVideo(from temporary: URL, date: Date) throws -> URL {
        var sequence = 0
        while true {
            let target = temporary.deletingLastPathComponent().appendingPathComponent(CaptureFileNaming.name(date: date, sequence: sequence, extension: "mp4"))
            do { try FileManager.default.moveItem(at: temporary, to: target); return target }
            catch let error as CocoaError where error.code == .fileWriteFileExists { sequence += 1 }
        }
    }
    /// 同秒と再起動後の既存ファイルを保護。存在確認だけでは競合するので排他作成する。
    static func save(data: Data, kind: ArtifactKind, directory: URL, date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var sequence = 0
        while true {
            let url = directory.appendingPathComponent(CaptureFileNaming.name(date: date, sequence: sequence, extension: kind.fileExtension))
            do { try data.write(to: url, options: .withoutOverwriting); return url }
            catch let error as CocoaError where error.code == .fileWriteFileExists { sequence += 1 }
        }
    }
}

@MainActor
enum ClipboardWriter {
    /// NSPasteboardItemだけを書き、NSImage由来のTIFF/PNG表現を載せない。
    static func item(for artifact: SharedArtifact, data: Data? = nil, mode: ClipboardMode) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        // 動画はmodeによらずファイルURLのみ。MP4全体をメモリへ読み込まない。
        if artifact.kind == .mp4 || mode == .both || mode == .file { item.setString(artifact.url.absoluteString, forType: .fileURL) }
        if artifact.kind == .webP, mode == .both || mode == .data, let data { item.setData(data, forType: artifact.kind.pasteboardType) }
        return item
    }
    static func copy(_ artifact: SharedArtifact, data: Data? = nil, mode: ClipboardMode) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([item(for: artifact, data: data, mode: mode)])
    }
}

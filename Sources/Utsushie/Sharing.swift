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
}

enum ArtifactStore {
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
    static func item(for artifact: SharedArtifact, data: Data, mode: ClipboardMode) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        if mode == .both || mode == .file { item.setString(artifact.url.absoluteString, forType: .fileURL) }
        if mode == .both || mode == .data { item.setData(data, forType: artifact.kind.pasteboardType) }
        return item
    }
    static func copy(_ artifact: SharedArtifact, data: Data, mode: ClipboardMode) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([item(for: artifact, data: data, mode: mode)])
    }
}

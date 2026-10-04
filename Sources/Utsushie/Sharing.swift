import AppKit
import UtsushieCore
import Darwin

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
    var videoFPS: Int? = nil
}

enum ArtifactStore {
    /// 同じフォルダの隠し一時ファイルへ書き、renameで同名のファイルを原子的に差し替える。
    static func replace(data: Data, at url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".utsushie-annotation-\(UUID().uuidString).webp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        let result = temporary.withUnsafeFileSystemRepresentation { source in
            url.withUnsafeFileSystemRepresentation { target in rename(source!, target!) }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
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
        copy(artifact, data: data, mode: mode, to: .general)
    }
    static func copy(_ artifact: SharedArtifact, data: Data? = nil, mode: ClipboardMode, to pasteboard: NSPasteboard, preservingOnFailure: Bool = false) -> Bool {
        // clearContents後の書き込み失敗に備え、元の全形式を値として退避する。
        // 退避は注釈の確定だけで行い、通常撮影で他アプリの遅延データを読み出さない。
        let previous = (preservingOnFailure ? pasteboard.pasteboardItems ?? [] : []).map { original in
            let saved = NSPasteboardItem()
            for type in original.types { if let bytes = original.data(forType: type) { saved.setData(bytes, forType: type) } }
            return saved
        }
        pasteboard.clearContents()
        if pasteboard.writeObjects([item(for: artifact, data: data, mode: mode)]) { return true }
        pasteboard.clearContents()
        if !previous.isEmpty { _ = pasteboard.writeObjects(previous) }
        return false
    }
}

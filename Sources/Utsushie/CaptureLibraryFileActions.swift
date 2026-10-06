import Foundation
import UtsushieCore

struct CaptureLibraryTrashResult: Sendable {
    var removed: Set<URL> = []
    var failed: Set<URL> = []
}

enum CaptureLibraryFileActions {
    /// 各ファイルを独立にゴミ箱へ移す。失敗しても完全削除へ切り替えない。
    static func trash(_ urls: [URL], move: (URL) throws -> Void = {
        try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    }) -> CaptureLibraryTrashResult {
        var result = CaptureLibraryTrashResult()
        for url in urls {
            do { try move(url); result.removed.insert(url) }
            catch { result.failed.insert(url) }
        }
        return result
    }
    static func clipboardEntries(_ urls: [URL], mode: ClipboardMode) throws -> [ClipboardEntry] {
        try urls.map { url in
            let kind: ArtifactKind = url.pathExtension.lowercased() == "webp" ? .webP : .mp4
            let data = kind == .webP && mode != .file ? try Data(contentsOf: url) : nil
            return ClipboardEntry(artifact: SharedArtifact(url: url, kind: kind, width: 0, height: 0,
                byteCount: data?.count ?? 0), data: data)
        }
    }
}

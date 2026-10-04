import AppKit
import UtsushieCore

enum AnnotationSaveError: LocalizedError {
    case clipboard
    var errorDescription: String? { "クリップボードへコピーできませんでした" }
}

@MainActor
enum AnnotationSave {
    /// 合成・エンコードが済むまで公開状態に触れない。コピー失敗時は元のバイトへ戻す。
    static func commit(data: Data, artifact: SharedArtifact, mode: ClipboardMode,
                       copy: (SharedArtifact, Data, ClipboardMode) -> Bool = { ClipboardWriter.copy($0, data: $1, mode: $2, to: .general, preservingOnFailure: true) }) throws -> SharedArtifact {
        let original = try Data(contentsOf: artifact.url)
        var updated = artifact; updated.byteCount = data.count
        try ArtifactStore.replace(data: data, at: artifact.url)
        guard copy(updated, data, mode) else {
            try ArtifactStore.replace(data: original, at: artifact.url)
            throw AnnotationSaveError.clipboard
        }
        return updated
    }
}

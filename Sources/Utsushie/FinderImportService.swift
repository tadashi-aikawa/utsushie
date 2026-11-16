import AppKit
import OSLog

let importLog = Logger(subsystem: "com.tadashi-aikawa.utsushie", category: "Import")

/// Finderの右クリックの「UTSUSHIEで編集」を受ける。Info.plistの`NSServices`の`NSMessage`と名前を合わせる。
@MainActor
final class FinderImportService: NSObject {
    var onFiles: (([URL]) -> Void)?

    @objc(editInUtsushie:userData:error:)
    func editInUtsushie(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = Self.fileURLs(in: pasteboard)
        importLog.debug("service received: files=\(urls.count, privacy: .public) types=\((pasteboard.types ?? []).map(\.rawValue).joined(separator: ","), privacy: .public) items=\(pasteboard.pasteboardItems?.count ?? -1, privacy: .public)")
        guard !urls.isEmpty else {
            error.pointee = "UTSUSHIEへ渡せるファイルがありません" as NSString
            return
        }
        onFiles?(urls)
    }
    nonisolated static func fileURLs(in pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}

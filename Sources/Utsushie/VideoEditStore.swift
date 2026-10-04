import Foundation
import Darwin

enum VideoEditStore {
    static let originalPrefix = ".utsushie-video-original-"
    static func temporaryURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".utsushie-video-edit-\(UUID().uuidString).mp4")
    }
    /// 初回だけ元を改名する。以降は同じ元から再エンコードし、公開済みの動画だけを置換する。
    static func replace(temporary: URL, target: URL, original: URL?) throws -> URL {
        let backup = original ?? target.deletingLastPathComponent().appendingPathComponent("\(originalPrefix)\(UUID().uuidString)--\(target.lastPathComponent)")
        if original == nil { try FileManager.default.moveItem(at: target, to: backup) }
        let status = temporary.withUnsafeFileSystemRepresentation { source in
            target.withUnsafeFileSystemRepresentation { destination in rename(source!, destination!) }
        }
        guard status == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            if original == nil { try FileManager.default.moveItem(at: backup, to: target) }
            throw error
        }
        return backup
    }
    static func removeOriginal(_ original: URL?) {
        if let original { try? FileManager.default.removeItem(at: original) }
    }
    static func cleanup(directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard url.lastPathComponent.hasPrefix(originalPrefix), url.pathExtension == "mp4",
                  let separator = url.lastPathComponent.range(of: "--") else { continue }
            let target = directory.appendingPathComponent(String(url.lastPathComponent[separator.upperBound...]))
            // 初回の改名直後に終了した場合は、公開先が欠けている元だけ復旧する。
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: url) }
            else { try FileManager.default.moveItem(at: url, to: target) }
        }
    }
    @MainActor static func rememberDirectory(_ directory: URL) {
        let key = "videoEditDirectories"
        let old = UserDefaults.standard.stringArray(forKey: key) ?? []
        UserDefaults.standard.set(Array(Set(old + [directory.path])), forKey: key)
    }
    @MainActor static func cleanupAtLaunch(directory: URL) -> [String] {
        let paths = Set((UserDefaults.standard.stringArray(forKey: "videoEditDirectories") ?? []) + [directory.path])
        var errors: [String] = []
        for path in paths {
            do { try cleanup(directory: URL(fileURLWithPath: path, isDirectory: true)) }
            catch { errors.append("元の動画の後片付けに失敗しました: \(path)") }
        }
        return errors
    }
}

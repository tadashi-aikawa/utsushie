import Foundation
import Darwin

enum VideoEditStore {
    static let originalPrefix = ".utsushie-video-original-"
    static func temporaryURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".utsushie-video-edit-\(UUID().uuidString).mp4")
    }
    /// 公開名は退避名に入れず、拡張属性で持つ。
    /// 理由: 退避名へ公開名を足すと、長い`[file] name`で255バイトを超えて編集を完了できないためです。
    static let originalNameAttribute = "io.github.tadashi-aikawa.utsushie.original-name"
    static func originalName(of url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }
            let size = getxattr(path, originalNameAttribute, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var bytes = [UInt8](repeating: 0, count: size)
            guard getxattr(path, originalNameAttribute, &bytes, size, 0, 0) == size else { return nil }
            return String(bytes: bytes, encoding: .utf8)
        }
    }
    private static func setOriginalName(_ name: String, on url: URL) throws {
        let bytes = Array(name.utf8)
        let status = url.withUnsafeFileSystemRepresentation { path in setxattr(path!, originalNameAttribute, bytes, bytes.count, 0, 0) }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    private static func removeOriginalName(from url: URL) {
        _ = url.withUnsafeFileSystemRepresentation { path in removexattr(path!, originalNameAttribute, 0) }
    }
    /// 初回だけ元を改名する。以降は同じ元から再エンコードし、公開済みの動画だけを置換する。
    static func replace(temporary: URL, target: URL, original: URL?) throws -> URL {
        let backup = original ?? target.deletingLastPathComponent().appendingPathComponent("\(originalPrefix)\(UUID().uuidString).mp4")
        if original == nil {
            // 改名前に付け、改名直後に終了しても公開名へ戻せるようにする。
            try setOriginalName(target.lastPathComponent, on: target)
            do { try FileManager.default.moveItem(at: target, to: backup) }
            catch { removeOriginalName(from: target); throw error }
        }
        let status = temporary.withUnsafeFileSystemRepresentation { source in
            target.withUnsafeFileSystemRepresentation { destination in rename(source!, destination!) }
        }
        guard status == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            if original == nil { try FileManager.default.moveItem(at: backup, to: target); removeOriginalName(from: target) }
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
            guard url.lastPathComponent.hasPrefix(originalPrefix), url.pathExtension == "mp4" else { continue }
            // 旧版の退避名`<UUID>--<元名>`も読む。公開名が分からない元は消さずに残す。
            let legacy = url.lastPathComponent.range(of: "--").map { String(url.lastPathComponent[$0.upperBound...]) }
            guard let name = originalName(of: url) ?? legacy, !name.isEmpty, !name.contains("/") else { continue }
            let target = directory.appendingPathComponent(name)
            // 初回の改名直後に終了した場合は、公開先が欠けている元だけ復旧する。
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: url) }
            else { try FileManager.default.moveItem(at: url, to: target); removeOriginalName(from: target) }
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

import Foundation
import TOMLKit

public enum ClipboardMode: String, Sendable, CaseIterable { case both, file, data }
public struct Hotkey: Equatable, Sendable {
    public var keyCode: UInt32
    /// Carbonの修飾ビット。CoreにAppKit/Carbonを入れない。
    public var modifiers: UInt32
    public init(keyCode: UInt32 = 19, modifiers: UInt32 = 256 | 512) {
        self.keyCode = keyCode; self.modifiers = modifiers
    }
}
public struct UtsushieConfig: Equatable, Sendable {
    public var hotkey = Hotkey()
    public var outputDir = "~/Pictures/UTSUSHIE"
    public var downscale = true
    public var quality: Double = 80
    public var lossless = false
    public var clipboard: ClipboardMode = .both
    public var thumbnailSeconds: Double = 5
    public init() {}
    public func outputURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        outputDir.hasPrefix("~/") ? home.appendingPathComponent(String(outputDir.dropFirst(2))) : URL(fileURLWithPath: outputDir)
    }
}
public struct ConfigResult: Sendable {
    public var config: UtsushieConfig
    public var warnings: [String]
}
public enum ConfigLoader {
    public static func directory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".config/utsushie", isDirectory: true)
    }
    public static func defaultPath() -> URL { directory().appendingPathComponent("config.toml") }
    public static func load(from url: URL = defaultPath()) -> ConfigResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return ConfigResult(config: .init(), warnings: []) }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ConfigResult(config: .init(), warnings: ["設定ファイルを読めません: \(url.path)"])
        }
        return parse(toml: text)
    }
    /// フィールドごとに型も検証。不正な1キーのために正常な他キーを捨てない。
    public static func parse(toml: String) -> ConfigResult {
        var config = UtsushieConfig()
        var warnings: [String] = []
        let root: TOMLTable
        do { root = try TOMLTable(string: toml) }
        catch { return ConfigResult(config: config, warnings: ["TOML構文エラー: \(error)"] ) }
        func value(_ section: String?, _ key: String) -> TOMLValue? {
            if let section { return root[section]?.tomlValue.table?[key]?.tomlValue }
            return root[key]?.tomlValue
        }
        func warn(_ name: String) { warnings.append("\(name) が不正なため既定値を使います") }
        for section in ["hotkey", "webp", "clipboard", "thumbnail"] {
            if let item = root[section], item.tomlValue.table == nil { warn(section) }
        }
        if let item = value(nil, "outputDir") {
            if let path = item.string, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               path.hasPrefix("/") || path.hasPrefix("~/") { config.outputDir = path }
            else { warn("outputDir") }
        }
        for (key, assign) in [("downscale", { (v: Bool) in config.downscale = v }), ("lossless", { (v: Bool) in config.lossless = v })] {
            if let item = value("webp", key) {
                if let bool = item.bool { assign(bool) } else { warn("webp.\(key)") }
            }
        }
        if let item = value("webp", "quality") {
            if let number = item.double ?? item.int.map(Double.init), number.isFinite, (0...100).contains(number) { config.quality = number }
            else { warn("webp.quality") }
        }
        if let item = value("clipboard", "mode") {
            if let string = item.string, let mode = ClipboardMode(rawValue: string) { config.clipboard = mode }
            else { warn("clipboard.mode") }
        }
        if let item = value("thumbnail", "seconds") {
            if let number = item.double ?? item.int.map(Double.init), number.isFinite, (0.1...300).contains(number) { config.thumbnailSeconds = number }
            else { warn("thumbnail.seconds") }
        }
        var hotkeyValid = true
        if let item = value("hotkey", "keyCode") {
            if let code = item.int, (0...127).contains(code) { config.hotkey.keyCode = UInt32(code) }
            else { hotkeyValid = false }
        }
        if let item = value("hotkey", "modifiers") {
            let bits: [String: UInt32] = ["command": 256, "shift": 512, "option": 2048, "control": 4096]
            if let array = item.array, !array.isEmpty {
                var flags: UInt32 = 0
                for element in array {
                    if let name = element.tomlValue.string, let bit = bits[name] { flags |= bit }
                    else { hotkeyValid = false }
                }
                // 無修飾/Shiftだけのグローバルキーは普通の入力を奪うため受け付けない。
                if flags & (256 | 2048 | 4096) == 0 { hotkeyValid = false }
                config.hotkey.modifiers = flags
            } else { hotkeyValid = false }
        }
        if !hotkeyValid { config.hotkey = Hotkey(); warn("hotkey") }
        return ConfigResult(config: config, warnings: warnings)
    }
    public static let template = """
    # UTSUSHIE。変更は次の撮影開始時に反映します。
    outputDir = "~/Pictures/UTSUSHIE"

    [hotkey]
    keyCode = 19 # 物理キー2。⌘⇧2
    modifiers = ["command", "shift"]

    [webp]
    downscale = true # 見た目の1xへ縮小
    quality = 80 # 0〜100
    lossless = false

    [clipboard]
    mode = "both" # both / file / data

    [thumbnail]
    seconds = 5 # 0.1〜300。ホバー中は停止
    """ + "\n"
}

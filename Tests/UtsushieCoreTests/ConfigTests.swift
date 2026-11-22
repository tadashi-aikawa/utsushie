import Foundation
import Testing
@testable import UtsushieCore

@Test func defaults() {
    let result = ConfigLoader.parse(toml: "")
    #expect(result.warnings.isEmpty)
    #expect(result.config == UtsushieConfig())
    #expect(result.config.outputURL(home: URL(fileURLWithPath: "/tmp/home")).path == "/tmp/home/Pictures/UTSUSHIE")
}
@Test func documentedTemplate() {
    let result = ConfigLoader.parse(toml: ConfigLoader.template)
    #expect(result.warnings.isEmpty)
    #expect(result.config == UtsushieConfig())
}
@Test func ensureFileWritesTemplateOnlyWhenMissing() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("utsushie-config-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("nested/config.toml")
    try ConfigLoader.ensureFileExists(at: url)
    #expect(try String(contentsOf: url, encoding: .utf8) == ConfigLoader.template)
    // 書き出した雛形を読むと、ファイルが無いときと同じ既定になる。
    #expect(ConfigLoader.load(from: url).config == ConfigLoader.load(from: dir.appendingPathComponent("missing.toml")).config)
    try "outputDir = \"/tmp/x\"\n".write(to: url, atomically: true, encoding: .utf8)
    try ConfigLoader.ensureFileExists(at: url)
    #expect(try String(contentsOf: url, encoding: .utf8) == "outputDir = \"/tmp/x\"\n")
}
@Test func ensureFileRejectsBrokenSymlinkWithoutReplacingIt() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("utsushie-config-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("config.toml")
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: dir.appendingPathComponent("dotfiles/config.toml"))
    #expect(ConfigLoader.isBrokenSymlink(url))
    #expect(throws: ConfigFileError("設定ファイルのシンボリックリンクのリンク先がありません: \(url.path)")) { try ConfigLoader.ensureFileExists(at: url) }
    #expect(ConfigLoader.isBrokenSymlink(url))
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("dotfiles").path))
}
@Test func templateWriteKeepsFileMadeAfterTheCheck() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("utsushie-config-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // 存在を確かめた後に別のプロセスが作った、という場面を直接書き込みで作る。
    let file = dir.appendingPathComponent("config.toml")
    try "outputDir = \"/tmp/x\"\n".write(to: file, atomically: true, encoding: .utf8)
    try ConfigLoader.writeTemplate(to: file)
    #expect(try String(contentsOf: file, encoding: .utf8) == "outputDir = \"/tmp/x\"\n")
    let link = dir.appendingPathComponent("linked.toml")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir.appendingPathComponent("missing/config.toml"))
    #expect(throws: ConfigFileError("設定ファイルのシンボリックリンクのリンク先がありません: \(link.path)")) { try ConfigLoader.writeTemplate(to: link) }
    #expect(ConfigLoader.isBrokenSymlink(link))
    // 置けなかった一時ファイルは残さない。
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["config.toml", "linked.toml"])
}
@Test func templateWriteLeavesNoTemporaryFileWhenPlacementFails() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("utsushie-config-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // 一時ファイルは書けるが、最終のパスは名前が長すぎて置けない。
    let url = dir.appendingPathComponent(String(repeating: "a", count: 300) + ".toml")
    #expect(throws: POSIXError(.ENAMETOOLONG)) { try ConfigLoader.writeTemplate(to: url) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
}
@Test func templateWritePlacesCompleteTemplate() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("utsushie-config-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("config.toml")
    try ConfigLoader.writeTemplate(to: url)
    #expect(try String(contentsOf: url, encoding: .utf8) == ConfigLoader.template)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["config.toml"])
}
@Test func customizedSettings() {
    let result = ConfigLoader.parse(toml: """
    outputDir = "/tmp/captures"
    [hotkey]
    keyCode = 20
    modifiers = ["control", "option"]
    [webp]
    downscale = false
    quality = 92.5
    lossless = true
    [clipboard]
    mode = "data"
    [thumbnail]
    seconds = 12
    """)
    #expect(result.warnings.isEmpty)
    #expect(result.config.hotkey == Hotkey(keyCode: 20, modifiers: 4096 | 2048))
    #expect(result.config.outputDir == "/tmp/captures")
    #expect(!result.config.downscale)
    #expect(result.config.lossless)
    #expect(result.config.quality == 92.5)
    #expect(result.config.clipboard == .data)
    #expect(result.config.thumbnailSeconds == 12)
}
@Test func invalidValuesFallBackIndividually() {
    let result = ConfigLoader.parse(toml: """
    outputDir = "relative"
    [webp]
    downscale = "no"
    lossless = true
    quality = 101
    [clipboard]
    mode = "png"
    [thumbnail]
    seconds = -1
    """)
    #expect(result.warnings.count == 5)
    #expect(result.config.outputDir == UtsushieConfig().outputDir)
    #expect(result.config.downscale)
    #expect(result.config.lossless)
    #expect(result.config.quality == 80)
    #expect(result.config.clipboard == .both)
    #expect(result.config.thumbnailSeconds == 5)
}
@Test(arguments: ["quality = nan", "quality = inf", "quality = -1", "quality = false"])
func badQuality(_ setting: String) {
    let result = ConfigLoader.parse(toml: "[webp]\n\(setting)")
    #expect(result.config.quality == 80)
    #expect(result.warnings.count == 1)
}
@Test(arguments: ["keyCode = 999", "modifiers = []", "modifiers = [\"shift\"]", "modifiers = [\"meta\"]", "keyCode = \"2\""])
func invalidHotkey(_ setting: String) {
    let result = ConfigLoader.parse(toml: "[hotkey]\n\(setting)")
    #expect(result.config.hotkey == Hotkey())
    #expect(result.warnings.count == 1)
}
@Test func malformedTOML() {
    let result = ConfigLoader.parse(toml: "[webp\nquality = 90")
    #expect(result.config == UtsushieConfig())
    #expect(result.warnings.count == 1)
}
@Test func invalidSectionType() {
    let result = ConfigLoader.parse(toml: "webp = true\nclipboard = 12")
    #expect(result.warnings.count == 2)
    #expect(result.config == UtsushieConfig())
}
@Test(arguments: ["both", "file", "data", "none"])
func clipboardModes(_ mode: String) {
    let result = ConfigLoader.parse(toml: "[clipboard]\nmode = \"\(mode)\"")
    #expect(result.config.clipboard.rawValue == mode)
    #expect(result.warnings.isEmpty)
}
@Test(arguments: CardCorner.allCases)
func thumbnailCorners(_ corner: CardCorner) {
    let result = ConfigLoader.parse(toml: "[thumbnail]\ncorner = \"\(corner.rawValue)\"")
    #expect(result.config.thumbnailCorner == corner)
    #expect(result.warnings.isEmpty)
}
@Test(arguments: ["\"bottom-right\"", "\"BottomRight\"", "\"\"", "1"])
func invalidThumbnailCornerFallsBackToBottomRight(_ value: String) {
    let result = ConfigLoader.parse(toml: "[thumbnail]\nseconds = 8\ncorner = \(value)")
    #expect(UtsushieConfig().thumbnailCorner == .bottomRight)
    #expect(result.config.thumbnailCorner == .bottomRight)
    #expect(result.config.thumbnailSeconds == 8)
    #expect(result.warnings == ["thumbnail.corner が不正なため既定値を使います"])
}
@Test func clipboardNoneSkipsAutomaticCopyButKeepsManualFormat() {
    #expect(UtsushieConfig().clipboard == .both)
    #expect(!ClipboardMode.none.copiesAutomatically)
    #expect(ClipboardMode.none.format == .both)
    for mode in [ClipboardMode.both, .file, .data] {
        #expect(mode.copiesAutomatically)
        #expect(mode.format == mode)
    }
    let result = ConfigLoader.parse(toml: "[clipboard]\nmode = \"off\"")
    #expect(result.config.clipboard == .both)
    #expect(result.warnings == ["clipboard.mode が不正なため既定値を使います"])
}

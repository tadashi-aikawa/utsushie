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
@Test(arguments: ["both", "file", "data"])
func clipboardModes(_ mode: String) {
    let result = ConfigLoader.parse(toml: "[clipboard]\nmode = \"\(mode)\"")
    #expect(result.config.clipboard.rawValue == mode)
    #expect(result.warnings.isEmpty)
}

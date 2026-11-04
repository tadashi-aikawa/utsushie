import Foundation
import Testing
@testable import UtsushieCore

private let jst = TimeZone(secondsFromGMT: 9 * 3600)!
/// 2026-11-04T10:15:43+09:00
private let sample = Date(timeIntervalSince1970: 1_793_754_943)

@Test func fileNamePatternDefaultMatchesLegacyName() {
    #expect(UtsushieConfig().fileName == "utsushie-{yyyyMMdd}-{HHmmss}")
    #expect(CaptureFileNaming.name(date: sample, timeZone: jst, pattern: CaptureFileNaming.defaultPattern)
        == CaptureFileNaming.name(date: sample, timeZone: jst))
    #expect(CaptureFileNaming.name(date: sample, timeZone: jst) == "utsushie-20261104-101543.webp")
}
@Test func fileNamePatternExpandsOnlyInsideBraces() {
    let pattern = "{yyyyMMdd}-{HHmmss}-utsushie"
    #expect(CaptureFileNaming.isValid(pattern: pattern))
    #expect(CaptureFileNaming.name(date: sample, timeZone: jst, pattern: pattern) == "20261104-101543-utsushie.webp")
    #expect(CaptureFileNaming.name(date: sample, sequence: 1, extension: "mp4", timeZone: jst, pattern: pattern)
        == "20261104-101543-utsushie-1.mp4")
    // 外の英字は日付の書式として扱わない。中は en_US_POSIX のグレゴリオ暦で展開する。
    #expect(CaptureFileNaming.name(date: sample, timeZone: jst, pattern: "shot yyyy {MMM d} ({EEE})") == "shot yyyy Nov 4 (Wed).webp")
    #expect(CaptureFileNaming.name(date: sample, timeZone: TimeZone(secondsFromGMT: 0)!, pattern: "{HH}") == "01.webp")
    #expect(CaptureFileNaming.name(date: sample, timeZone: jst, pattern: "写絵") == "写絵.webp")
}
@Test(arguments: [
    "", "   ", "a/b", "a:b", "a\u{0}b", "a\nb", "{yyyy/MM/dd}", "{'/'}",
    "{", "}", "a{yyyy", "a}yyyy{", "{}", "{yy{MM}}", "{' '}",".hidden-{HHmmss}", "{HHmmss}.recording",
    String(repeating: "a", count: 250),
])
func invalidFileNamePatterns(_ pattern: String) {
    #expect(!CaptureFileNaming.isValid(pattern: pattern))
    // NULはTOMLKitが構文エラーにするので、設定ファイル経由では項目の検証まで届かない。
    if !pattern.contains("\u{0}") {
        let escaped = pattern.unicodeScalars.map { $0.value < 0x20 ? String(format: "\\u%04X", $0.value) : String($0) }.joined()
        let result = ConfigLoader.parse(toml: "[file]\nname = \"\(escaped)\"")
        #expect(result.config.fileName == CaptureFileNaming.defaultPattern)
        #expect(result.warnings == ["file.name が不正なため既定値を使います"])
    }
    // 呼び出し側の誤りで不正な書式が渡っても、既定の名前で保存できる。
    #expect(CaptureFileNaming.name(date: sample, timeZone: jst, pattern: pattern) == "utsushie-20261104-101543.webp")
}
@Test func fileNameSettingReadsValidPatternAndRejectsWrongType() {
    let valid = ConfigLoader.parse(toml: "[file]\nname = \"{yyyyMMdd}-{HHmmss}-utsushie\"")
    #expect(valid.warnings.isEmpty)
    #expect(valid.config.fileName == "{yyyyMMdd}-{HHmmss}-utsushie")
    let number = ConfigLoader.parse(toml: "[file]\nname = 12")
    #expect(number.config.fileName == CaptureFileNaming.defaultPattern)
    #expect(number.warnings == ["file.name が不正なため既定値を使います"])
    let section = ConfigLoader.parse(toml: "file = \"x\"")
    #expect(section.warnings == ["file が不正なため既定値を使います"])
}

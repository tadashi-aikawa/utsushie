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
    // 250文字は連番の余裕が無いので設定では弾くが、最終名が255バイトに収まる回はそのまま使う。
    if pattern.count < 250 {
        #expect(CaptureFileNaming.resolve(date: sample, timeZone: jst, pattern: pattern) == .init(name: "utsushie-20261104-101543.webp", usedDefault: true))
    }
}
@Test func fileNameResolveChecksFinalNameWithActualDateAndTimeZone() throws {
    let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
    let september = Date(timeIntervalSince1970: 1_790_763_343) // 2026-09-30T19:15:43+09:00
    let fallback = "utsushie-20260930-191543"
    // タイムゾーン名・オフセットはUTCの見本では通っても、東京で`/`・`:`が出る。
    for pattern in ["{VV}", "x{ZZZZZ}"] {
        #expect(!CaptureFileNaming.isValid(pattern: pattern, timeZone: tokyo))
        let resolved = CaptureFileNaming.resolve(date: september, timeZone: tokyo, pattern: pattern)
        #expect(resolved == .init(name: "\(fallback).webp", usedDefault: true))
    }
    // 月名で長さが変わる。設定時は最長の9月で測り、保存時は連番と拡張子を含めて255バイトで切る。
    let months = String(repeating: "{MMMM}", count: 30)
    #expect(!CaptureFileNaming.isValid(pattern: months, timeZone: tokyo))
    #expect(CaptureFileNaming.resolve(date: september, timeZone: tokyo, pattern: months).usedDefault)
    let may = Date(timeIntervalSince1970: 1_779_000_000) // 2026-05
    #expect(CaptureFileNaming.resolve(date: may, timeZone: tokyo, pattern: months).name == String(repeating: "May", count: 30) + ".webp")
    let edge = String(repeating: "a", count: 250)
    #expect(CaptureFileNaming.resolve(date: may, extension: "mp4", timeZone: tokyo, pattern: edge) == .init(name: edge + ".mp4", usedDefault: false))
    #expect(CaptureFileNaming.resolve(date: may, sequence: 1, extension: "mp4", timeZone: tokyo, pattern: edge).usedDefault)
    // 既定の書式はそのまま使い、警告の対象にしない。
    #expect(CaptureFileNaming.resolve(date: september, timeZone: tokyo) == .init(name: "\(fallback).webp", usedDefault: false))
    #expect(CaptureFileNaming.resolve(date: september, sequence: 2, extension: "mp4", timeZone: tokyo, pattern: "{VV}").name == "\(fallback)-2.mp4")
}
@Test func fileNameFallbackWarningSurvivesConfigurationReload() throws {
    let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
    // 「in the morning」などは14バイト、「in the afternoon」は16バイト。設定時の見本では収まり、午後の保存で255バイトを超える。
    let pattern = String(repeating: "{BBBB}", count: 17)
    let toml = "[file]\nname = \"\(pattern)\""
    #expect(CaptureFileNaming.isValid(pattern: pattern, timeZone: tokyo))
    let afternoon = Date(timeIntervalSince1970: 1_793_772_943) // 2026-11-04T15:15:43+09:00
    #expect(CaptureFileNaming.resolve(date: afternoon, timeZone: tokyo, pattern: pattern).usedDefault)
    var warnings = AppWarnings()
    warnings.replaceConfiguration(ConfigLoader.parse(toml: toml).warnings)
    #expect(warnings.menuTitle == nil)
    // 既定名での保存 → メニューを開いて設定を読み直す。
    warnings.add(CaptureFileNaming.fallbackWarning)
    warnings.replaceConfiguration(ConfigLoader.parse(toml: toml).warnings)
    #expect(warnings.all == [CaptureFileNaming.fallbackWarning])
    #expect(warnings.menuTitle == "設定の警告 1件…")
    // 設定の警告と合わせて出し、同じ文は重ねない。
    warnings.add(CaptureFileNaming.fallbackWarning)
    warnings.replaceConfiguration(["thumbnail.corner が不正なため既定値を使います"])
    #expect(warnings.all == ["thumbnail.corner が不正なため既定値を使います", CaptureFileNaming.fallbackWarning])
    warnings.replaceConfiguration([])
    #expect(warnings.all == [CaptureFileNaming.fallbackWarning])
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

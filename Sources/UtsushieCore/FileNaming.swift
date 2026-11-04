import Foundation

/// `[file] name`の書式。波括弧の中だけDateFormatterの書式で、外は文字どおり。拡張子と衝突時の`-N`は後ろへ足す。
public enum CaptureFileNaming {
    public static let defaultPattern = "utsushie-{yyyyMMdd}-{HHmmss}"
    private enum Token { case literal(String), date(String) }

    /// 波括弧が対応しない・空の`{}`・入れ子ならnil。
    private static func tokens(_ pattern: String) -> [Token]? {
        var tokens: [Token] = [], current = "", inside = false
        for character in pattern {
            switch (character, inside) {
            case ("{", false):
                if !current.isEmpty { tokens.append(.literal(current)) }
                current = ""; inside = true
            case ("}", true):
                guard !current.isEmpty else { return nil }
                tokens.append(.date(current)); current = ""; inside = false
            case ("{", true), ("}", false): return nil
            default: current.append(character)
            }
        }
        guard !inside else { return nil }
        if !current.isEmpty { tokens.append(.literal(current)) }
        return tokens
    }
    private static func expand(_ tokens: [Token], date: Date, timeZone: TimeZone) -> String {
        tokens.map { token in
            switch token {
            case .literal(let text): return text
            case .date(let format):
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = timeZone
                formatter.dateFormat = format
                return formatter.string(from: date)
            }
        }.joined()
    }
    /// `:`はFinderで`/`と表示されるので外す。
    private static let forbidden = CharacterSet(charactersIn: "/:").union(.controlCharacters)
    /// 書式と、固定の日時で展開した結果の両方を確かめる。`{'/'}`のような書式内の文字も展開結果で外す。
    public static func isValid(pattern: String) -> Bool {
        guard pattern.rangeOfCharacter(from: forbidden) == nil, let tokens = tokens(pattern), !tokens.isEmpty else { return false }
        let sample = Date(timeIntervalSince1970: 1_793_787_343) // 2026-11-04T10:15:43Z
        let base = expand(tokens, date: sample, timeZone: TimeZone(secondsFromGMT: 0)!)
        return !base.trimmingCharacters(in: .whitespaces).isEmpty
            && base.rangeOfCharacter(from: forbidden) == nil
            // 隠しファイルと録画中の`.recording.mp4`は一覧から外れるため使わせない。
            && !base.hasPrefix(".") && !base.lowercased().hasSuffix(".recording")
            // 連番と拡張子を足してもAPFSの255バイトに収める。
            && base.utf8.count <= 255 - "-9999.webp".utf8.count
    }
    /// 不正な書式は既定の名前にする。設定の読み取りで弾くので、ここへ来るのは呼び出し側の誤りだけ。
    public static func name(date: Date, sequence: Int = 0, extension suffix: String = "webp", timeZone: TimeZone = .current,
                            pattern: String = defaultPattern) -> String {
        let tokens = isValid(pattern: pattern) ? tokens(pattern)! : tokens(defaultPattern)!
        let serial = sequence == 0 ? "" : "-\(sequence)"
        return "\(expand(tokens, date: date, timeZone: timeZone))\(serial).\(suffix)"
    }
}
public struct LastArea: Codable, Equatable, Sendable {
    public var rect: CGRect
    public init(rect: CGRect) { self.rect = rect }
    public static func load(from url: URL) -> LastArea? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

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
    /// APFSのファイル名の上限。
    private static let maximumBytes = 255
    private static func tokens(validating pattern: String) -> [Token]? {
        guard pattern.rangeOfCharacter(from: forbidden) == nil, let tokens = tokens(pattern), !tokens.isEmpty else { return nil }
        return tokens
    }
    /// 拡張子と連番を除いた名前の字を確かめる。長さは呼び出し側で測る。
    private static func isUsable(base: String) -> Bool {
        !base.trimmingCharacters(in: .whitespaces).isEmpty
            && base.rangeOfCharacter(from: forbidden) == nil
            // 隠しファイルと録画中の`.recording.mp4`は一覧から外れるため使わせない。
            && !base.hasPrefix(".") && !base.lowercased().hasSuffix(".recording")
    }
    /// 設定の読み取りで早めに知らせる検証。保存時は`resolve`が実際の日時で最終名を確かめ直す。
    /// 月名・曜日名が最長の2026-09-30(水)を、UTCと指定のタイムゾーンの両方で展開する。
    /// `{'/'}`や`{VV}`のように、書式から使えない字が出るものも展開結果で外す。
    public static func isValid(pattern: String, timeZone: TimeZone = .current) -> Bool {
        guard let tokens = tokens(validating: pattern) else { return false }
        let sample = Date(timeIntervalSince1970: 1_790_763_343) // 2026-09-30T10:15:43Z
        return [TimeZone(secondsFromGMT: 0)!, timeZone].allSatisfy { zone in
            let base = expand(tokens, date: sample, timeZone: zone)
            // 連番と拡張子を足しても上限に収める。
            return isUsable(base: base) && base.utf8.count <= maximumBytes - "-9999.webp".utf8.count
        }
    }
    public struct Resolved: Equatable, Sendable {
        public var name: String
        /// 書式の展開結果が使えず、既定の名前にした。
        public var usedDefault: Bool
    }
    public static let fallbackWarning = "file.name を展開した名前がファイル名に使えないため、既定の名前で保存しました"
    /// 実際の日時・タイムゾーン・連番・拡張子を含む最終名を確かめ、使えなければ既定の書式で作り直す。
    /// 理由: 設定時の検証は見本の日時だけなので、月名の長さやタイムゾーン名で結果が変わる書式を防ぎきれない。
    public static func resolve(date: Date, sequence: Int = 0, extension suffix: String = "webp", timeZone: TimeZone = .current,
                               pattern: String = defaultPattern) -> Resolved {
        let serial = sequence == 0 ? "" : "-\(sequence)"
        if let tokens = tokens(validating: pattern) {
            let base = expand(tokens, date: date, timeZone: timeZone)
            let name = "\(base)\(serial).\(suffix)"
            if isUsable(base: base), name.utf8.count <= maximumBytes { return Resolved(name: name, usedDefault: false) }
        }
        let name = "\(expand(tokens(defaultPattern)!, date: date, timeZone: timeZone))\(serial).\(suffix)"
        return Resolved(name: name, usedDefault: pattern != defaultPattern)
    }
    public static func name(date: Date, sequence: Int = 0, extension suffix: String = "webp", timeZone: TimeZone = .current,
                            pattern: String = defaultPattern) -> String {
        resolve(date: date, sequence: sequence, extension: suffix, timeZone: timeZone, pattern: pattern).name
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

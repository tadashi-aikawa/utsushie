import Foundation

public struct CaptureDaySection: Equatable, Sendable {
    public let day: Date
    public let title: String
    public var files: [RecentCaptureFile]
}

public enum CaptureLibrary {
    /// 閉じるキーは手前のプレビューを優先する。一覧を閉じるにはもう一度押す。
    public static func closeTarget(previewVisible: Bool) -> CaptureLibraryCloseTarget {
        previewVisible ? .preview : .library
    }
    public static func sections(_ files: [RecentCaptureFile], now: Date = Date(), calendar: Calendar = .current) -> [CaptureDaySection] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "ja_JP"); formatter.dateFormat = "M月d日(E)"
        var sections: [CaptureDaySection] = []
        for file in RecentCaptures.all(files) {
            let day = calendar.startOfDay(for: file.date)
            if sections.last?.day == day { sections[sections.count - 1].files.append(file); continue }
            let title = day == today ? "今日" : day == yesterday ? "昨日" : formatter.string(from: day)
            sections.append(CaptureDaySection(day: day, title: title, files: [file]))
        }
        return sections
    }
    public static func metadata(file: RecentCaptureFile, width: Int, height: Int, bytes: Int, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timeZone; formatter.dateFormat = "HH:mm"
        let capacity = bytes <= 0 ? "—" : bytes >= 1_048_576 ? String(format: "%.1f MB", Double(bytes) / 1_048_576)
            : "\(max(1, Int((Double(bytes) / 1024).rounded()))) KB"
        return "\(formatter.string(from: file.date))  \(width)×\(height)  \(capacity)"
    }
    public static func videoBadge(_ seconds: Double) -> String {
        "▶ \(MediaFormatting.elapsed(seconds.isFinite ? max(0, seconds) : 0))"
    }
    public static func columns(for width: Double) -> Int { max(1, Int((max(0, width - 48) + 16) / 262)) }
}

public enum CaptureLibraryCloseTarget: Equatable, Sendable { case preview, library }

public enum CaptureGridDirection: Sendable { case left, right, up, down }

public struct CaptureGridPosition: Equatable, Sendable {
    public var section: Int
    public var item: Int
    public init(section: Int, item: Int) { self.section = section; self.item = item }
    public func moved(_ direction: CaptureGridDirection, counts: [Int], columns: Int) -> Self {
        let columns = max(1, columns)
        guard counts.indices.contains(section), (0..<counts[section]).contains(item) else { return self }
        switch direction {
        case .left:
            if item > 0 { return Self(section: section, item: item - 1) }
            if let previous = counts.indices.reversed().first(where: { $0 < section && counts[$0] > 0 }) {
                return Self(section: previous, item: counts[previous] - 1)
            }
        case .right:
            if item + 1 < counts[section] { return Self(section: section, item: item + 1) }
            if let next = counts.indices.first(where: { $0 > section && counts[$0] > 0 }) { return Self(section: next, item: 0) }
        case .up:
            if item >= columns { return Self(section: section, item: item - columns) }
            if let previous = counts.indices.reversed().first(where: { $0 < section && counts[$0] > 0 }) {
                let lastRow = (counts[previous] - 1) / columns * columns
                return Self(section: previous, item: min(lastRow + item % columns, counts[previous] - 1))
            }
        case .down:
            let nextRow = (item / columns + 1) * columns
            if nextRow < counts[section] { return Self(section: section, item: min(item + columns, counts[section] - 1)) }
            if let next = counts.indices.first(where: { $0 > section && counts[$0] > 0 }) {
                return Self(section: next, item: min(item % columns, counts[next] - 1))
            }
        }
        return self
    }
}

/// URLを保持するため、並べ替えと複数選択への拡張で選択の意味が変わらない。
public struct CaptureLibrarySelection: Equatable, Sendable {
    public private(set) var urls: Set<URL> = []
    public private(set) var focusedURL: URL?
    public init() {}
    public mutating func select(_ url: URL?) { focusedURL = url; urls = Set(url.map { [$0] } ?? []) }
    public mutating func reconcile(_ files: [RecentCaptureFile]) {
        let available = Set(files.map(\.url))
        urls.formIntersection(available)
        if let focusedURL, available.contains(focusedURL) { return }
        select(files.first?.url)
    }
}

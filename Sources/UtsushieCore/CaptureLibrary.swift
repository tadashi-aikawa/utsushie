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
    public static func gridLayout(for width: Double) -> CaptureGridLayout {
        let width = width.isFinite ? max(0, width) : 0
        // 左右18pt、間隔16pt、列の目安246ptを寸法の計算と共有する。
        let count = floor((max(0, width - 36) + 16) / 262)
        let columns = Int(max(1, min(count, Double(Int32.max))))
        // 絵の外に左右6ptを置く。未配置の幅でも絵の幅を最低1pt残す。
        let itemWidth = max(13, floor((width - 36 - Double(columns - 1) * 16) / Double(columns)))
        return CaptureGridLayout(columns: columns, itemWidth: itemWidth, itemHeight: (itemWidth - 12) * (10.0 / 16.0) + 36)
    }
    public static func columns(for width: Double) -> Int { gridLayout(for: width).columns }
}

public struct CaptureGridLayout: Equatable, Sendable {
    public let columns: Int
    public let itemWidth: Double
    public let itemHeight: Double
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

/// URLを保持し、並べ替えや読み直しでも選択とアンカーを同じファイルへ結び付ける。
public struct CaptureLibrarySelection: Equatable, Sendable {
    public private(set) var urls: Set<URL> = []
    public private(set) var focusedURL: URL?
    public private(set) var anchorURL: URL?
    public init() {}
    public mutating func select(_ url: URL?) {
        focusedURL = url; anchorURL = url; urls = Set(url.map { [$0] } ?? [])
    }
    public mutating func select(_ url: URL, mode: CaptureLibrarySelectionMode, orderedURLs: [URL]) {
        guard let target = orderedURLs.firstIndex(of: url) else { return }
        switch mode {
        case .single: select(url)
        case .toggle:
            if !urls.insert(url).inserted { urls.remove(url) }
            focusedURL = url; anchorURL = url
        case .range:
            let anchor = anchorURL ?? focusedURL ?? url
            let start = orderedURLs.firstIndex(of: anchor) ?? target
            anchorURL = orderedURLs[start]; focusedURL = url
            urls = Set(orderedURLs[min(start, target)...max(start, target)])
        }
    }
    public mutating func selectAll(_ orderedURLs: [URL]) {
        urls = Set(orderedURLs)
        if focusedURL == nil || !urls.contains(focusedURL!) { focusedURL = orderedURLs.first }
        if anchorURL == nil || !urls.contains(anchorURL!) { anchorURL = focusedURL }
    }
    public mutating func prepareDrag(from url: URL) {
        if !urls.contains(url) { select(url) }
    }
    public mutating func reconcile(_ files: [RecentCaptureFile]) {
        let available = Set(files.map(\.url))
        urls.formIntersection(available)
        if let anchorURL, !available.contains(anchorURL) { self.anchorURL = nil }
        if let focusedURL, available.contains(focusedURL) {
            if anchorURL == nil { anchorURL = focusedURL }
            return
        }
        if let survivor = files.first(where: { urls.contains($0.url) }) {
            focusedURL = survivor.url
            if anchorURL == nil { anchorURL = survivor.url }
        } else { select(files.first?.url) }
    }
    /// 失敗したファイルを優先。成功時は最初に消えた位置から後ろ、なければ前へ進む。
    public mutating func didRemove(_ removed: Set<URL>, failed: Set<URL> = [], orderedURLs: [URL]) {
        let remaining = orderedURLs.filter { !removed.contains($0) }
        let failures = failed.intersection(Set(remaining))
        if !failures.isEmpty {
            urls = failures; focusedURL = remaining.first { failures.contains($0) }; anchorURL = focusedURL
            return
        }
        guard let index = orderedURLs.firstIndex(where: { removed.contains($0) }) else { return }
        let next = orderedURLs.dropFirst(index + 1).first { !removed.contains($0) }
            ?? orderedURLs.prefix(index).last { !removed.contains($0) }
        select(next)
    }
}

public enum CaptureLibrarySelectionMode: Sendable { case single, toggle, range }

public enum CaptureLibraryDeleteInterruption: CaseIterable, Sendable {
    case escape, selectionChange, otherKey, click, resignKey
}
public enum CaptureLibraryDeleteAction: Equatable, Sendable { case ignored, armed, trash }

public struct CaptureLibraryDeleteConfirmation: Equatable, Sendable {
    public private(set) var urls: Set<URL> = []
    public var isArmed: Bool { !urls.isEmpty }
    public init() {}
    public mutating func press(selected: Set<URL>, isRepeat: Bool) -> CaptureLibraryDeleteAction {
        guard !isRepeat, !selected.isEmpty else { return .ignored }
        if urls == selected { urls = []; return .trash }
        urls = selected; return .armed
    }
    @discardableResult
    public mutating func interrupt(_ reason: CaptureLibraryDeleteInterruption) -> Bool {
        let armed = isArmed; urls = []; return armed
    }
}

public enum CaptureLibraryDragOperation: Equatable, Sendable {
    case copy, move
    public static func allowed(commandPressed: Bool) -> Self { commandPressed ? .move : .copy }
}

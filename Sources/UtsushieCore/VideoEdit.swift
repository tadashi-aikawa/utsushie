import Foundation

/// 元録画の秒数。半開区間で扱い、表示と書き出しで同じ境界を使う。
public struct VideoRange: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public init(_ start: Double, _ end: Double) { self.start = start; self.end = end }
    public var duration: Double { end - start }
    public func contains(_ time: Double) -> Bool { start <= time && time < end }
    public static func merged(_ ranges: [Self], duration: Double) -> [Self] {
        var result: [Self] = []
        for range in ranges.filter({ $0.start.isFinite && $0.end.isFinite })
            .map({ Self(max(0, $0.start), min(duration, $0.end)) })
            .filter({ $0.end > $0.start }).sorted(by: { $0.start < $1.start }) {
            if let last = result.last, range.start <= last.end {
                result[result.count - 1].end = max(last.end, range.end)
            } else { result.append(range) }
        }
        return result
    }
}

public struct VideoStillMark: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let time: Double
    public init(time: Double, id: UUID = UUID()) { self.time = time; self.id = id }
}

public struct VideoEditDocument: Equatable, Sendable {
    public let duration: Double
    public private(set) var kept: [VideoRange]
    public private(set) var stills: [VideoStillMark]
    public init(duration: Double, kept: [VideoRange]? = nil, stills: [VideoStillMark] = []) {
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.kept = VideoRange.merged(kept ?? [VideoRange(0, self.duration)], duration: self.duration)
        let limit = self.duration
        self.stills = stills.filter { $0.time.isFinite && $0.time >= 0 && $0.time < limit }
    }
    @discardableResult public mutating func addStill(at time: Double) -> UUID? {
        guard time.isFinite, time >= 0, time < duration,
              !stills.contains(where: { abs($0.time - time) < 1 / 120000.0 }) else { return nil }
        let mark = VideoStillMark(time: time); stills.append(mark); return mark.id
    }
    public mutating func removeStill(_ id: UUID) { stills.removeAll { $0.id == id } }
    public var outputDuration: Double { kept.reduce(0) { $0 + $1.duration } }
    public var isTrimmed: Bool { kept != [VideoRange(0, duration)] }
    public var cuts: [VideoRange] {
        var result: [VideoRange] = []; var cursor = 0.0
        for range in kept {
            if cursor < range.start { result.append(VideoRange(cursor, range.start)) }
            cursor = range.end
        }
        if cursor < duration { result.append(VideoRange(cursor, duration)) }
        return result
    }
    @discardableResult public mutating func cut(_ selection: VideoRange) -> Bool {
        let a = max(0, min(selection.start, selection.end)), b = min(duration, max(selection.start, selection.end))
        let next = kept.flatMap { range -> [VideoRange] in
            guard a < range.end, b > range.start else { return [range] }
            return [VideoRange(range.start, min(a, range.end)), VideoRange(max(b, range.start), range.end)].filter { $0.duration > 0 }
        }
        // 動画を空にする編集は確定しない。
        guard !next.isEmpty, next != kept else { return false }
        kept = next; return true
    }
    public mutating func restore(_ range: VideoRange) {
        kept = VideoRange.merged(kept + [range], duration: duration)
    }
    public mutating func moveBoundary(segment: Int, start: Bool, to time: Double) {
        guard kept.indices.contains(segment), time.isFinite else { return }
        let minimum = min(1 / 60000.0, kept[segment].duration)
        if start {
            let limit = segment == 0 ? 0 : kept[segment - 1].end
            kept[segment].start = min(kept[segment].end - minimum, max(limit, time))
        } else {
            let limit = segment == kept.count - 1 ? duration : kept[segment + 1].start
            kept[segment].end = max(kept[segment].start + minimum, min(limit, time))
        }
        kept = VideoRange.merged(kept, duration: duration)
    }
    /// I/Oは外側の両端。指定点が切った範囲の中なら、その点まで境界を戻す。
    public mutating func setStart(_ time: Double) {
        guard let end = kept.last?.end, time.isFinite else { return }
        let start = min(end - min(end, 1 / 60000.0), max(0, time))
        kept = kept.filter { $0.end > start }.map { VideoRange(max(start, $0.start), $0.end) }
        kept[0].start = start
    }
    public mutating func setEnd(_ time: Double) {
        guard let start = kept.first?.start, time.isFinite else { return }
        let end = max(start + min(duration - start, 1 / 60000.0), min(duration, time))
        kept = kept.filter { $0.start < end }.map { VideoRange($0.start, min(end, $0.end)) }
        kept[kept.count - 1].end = end
    }
    public func outputTime(forSource time: Double) -> Double? {
        var offset = 0.0
        for range in kept {
            if range.contains(time) { return offset + time - range.start }
            offset += range.duration
        }
        return time == kept.last?.end ? offset : nil
    }
    /// 再生だけに適用。nilは残す範囲の終端。クリックとコマ送りには使わない。
    public func playbackTime(at time: Double) -> Double? {
        for range in kept {
            if time < range.start { return range.start }
            if range.contains(time) { return time }
        }
        return nil
    }
    public var completionText: String {
        let trim = isTrimmed ? String(format: "%.1f秒に切る", outputDuration) : nil
        let images = stills.isEmpty ? nil : "静止画\(stills.count)枚をコピー"
        let actions = [trim, images].compactMap { $0 }
        return actions.isEmpty ? "ドラッグで切る範囲を選ぶ ・ ⏎でこのコマを撮る" : "完了で " + actions.joined(separator: " ・ ")
    }
}

/// 残す区間とつなぎ目は別々に持つ。後でつなぎ目へ演出用区間を差し込める。
public struct VideoExportPlan: Sendable {
    public struct Segment: Sendable {
        public var source: VideoRange
        public var outputStart: Double
    }
    public struct Junction: Sendable {
        public var precedingSegment: Int
        public var outputTime: Double
    }
    public var segments: [Segment]
    public var junctions: [Junction]
    public var duration: Double
    public init(document: VideoEditDocument) {
        var offset = 0.0; segments = []; junctions = []
        for (index, range) in document.kept.enumerated() {
            if index > 0 { junctions.append(Junction(precedingSegment: index - 1, outputTime: offset)) }
            segments.append(Segment(source: range, outputStart: offset)); offset += range.duration
        }
        duration = offset
    }
}

public enum VideoTimelineHit: Equatable, Sendable {
    case boundary(segment: Int, start: Bool)
    case strip
    case outside
}
public enum VideoTimelineGesture {
    public static func hit(x: Double, y: Double, width: Double, document: VideoEditDocument) -> VideoTimelineHit {
        guard width > 0, document.duration > 0, (0...56).contains(y) else { return .outside }
        // 端が接近しているときも、最も近い境界をつかむ。
        var best: (Double, VideoTimelineHit)?
        for (index, range) in document.kept.enumerated() {
            for (time, start) in [(range.start, true), (range.end, false)] {
                let distance = abs(x - time / document.duration * width)
                if distance <= 9, best == nil || distance < best!.0 { best = (distance, .boundary(segment: index, start: start)) }
            }
        }
        if let best { return best.1 }
        return (0...width).contains(x) ? .strip : .outside
    }
    public static func selection(from a: Double, to b: Double, width: Double, duration: Double) -> VideoRange? {
        guard width > 0, abs(b - a) > 4 else { return nil }
        return VideoRange(max(0, min(width, min(a, b))) / width * duration,
                          max(0, min(width, max(a, b))) / width * duration)
    }
}

public struct VideoEditHistory: Sendable {
    public private(set) var document: VideoEditDocument
    private var undoStack: [VideoEditDocument] = []
    private var redoStack: [VideoEditDocument] = []
    public init(_ document: VideoEditDocument) { self.document = document }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public mutating func commit(_ next: VideoEditDocument) {
        guard document != next else { return }
        undoStack.append(document); document = next; redoStack = []
    }
    public mutating func undo() {
        guard let next = undoStack.popLast() else { return }
        redoStack.append(document); document = next
    }
    public mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document); document = next
    }
}

public enum VideoFrameNavigation {
    public static func frame(times: [Double], at position: Double) -> Double? {
        var low = 0, high = times.count
        while low < high {
            let middle = (low + high) / 2
            if times[middle] <= position + 1 / 120000.0 { low = middle + 1 } else { high = middle }
        }
        return low > 0 ? times[low - 1] : times.first
    }
    public static func step(times: [Double], from position: Double, forward: Bool) -> Double {
        // CMTimeの丸めによる同じコマへの足踏みを避ける。
        if forward { return times.first { $0 > position + 1 / 120000.0 } ?? times.last ?? position }
        return times.last { $0 < position - 1 / 120000.0 } ?? times.first ?? position
    }
}

public enum VideoEditFormatting {
    public static func time(_ seconds: Double) -> String {
        let value = seconds.isFinite ? max(0, seconds) : 0
        let hundredths = Int((value * 100).rounded(.down))
        return String(format: "%d:%02d.%02d", hundredths / 6000, hundredths / 100 % 60, hundredths % 100)
    }
}

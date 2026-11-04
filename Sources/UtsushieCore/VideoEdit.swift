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

public enum VideoTransitionKind: String, CaseIterable, Sendable {
    case none, fastForward, fade, dissolve
    public var title: String {
        switch self { case .none: "そのまま"; case .fastForward: "早送り"; case .fade: "暗転"; case .dissolve: "ディゾルブ" }
    }
}

/// 倍率は演出を切り替えても保持する。nilだけが初回の自動倍率を表す。
public struct VideoCutTransition: Equatable, Sendable {
    public var range: VideoRange
    public var kind: VideoTransitionKind
    public private(set) var speed: Int?
    public init(range: VideoRange, kind: VideoTransitionKind = .none, speed: Int? = nil) {
        self.range = range; self.kind = kind; self.speed = speed.map { Self.clampedSpeed($0) }
        if kind == .fastForward, self.speed == nil { self.speed = Self.initialSpeed(duration: range.duration) }
    }
    public static func clampedSpeed(_ speed: Int) -> Int { min(100, max(2, speed)) }
    public static func initialSpeed(duration: Double) -> Int {
        guard duration.isFinite else { return 4 }
        return Int(min(100, max(4, duration.rounded())))
    }
    public var multiplier: Int { speed ?? Self.initialSpeed(duration: range.duration) }
    public var outputDuration: Double {
        switch kind { case .none: 0; case .fastForward: range.duration / Double(multiplier); case .fade, .dissolve: 0.5 }
    }
    public var text: String {
        switch kind {
        case .fastForward: String(format: "▶▶ ×%d ・ %.1f秒で見せる", multiplier, outputDuration)
        case .none: String(format: "%.1f秒を切る", range.duration)
        case .fade: String(format: "暗転 ・ %.1f秒を切る", range.duration)
        case .dissolve: String(format: "ディゾルブ ・ %.1f秒を切る", range.duration)
        }
    }
}

public struct VideoEditDocument: Equatable, Sendable {
    public let duration: Double
    public private(set) var kept: [VideoRange]
    public private(set) var stills: [VideoStillMark]
    public private(set) var transitions: [VideoCutTransition]
    /// 開始の昇順で、重ならない。切った範囲とは独立に元録画の秒数で持つ。
    public private(set) var zooms: [VideoZoom]
    public init(duration: Double, kept: [VideoRange]? = nil, stills: [VideoStillMark] = [], transitions: [VideoCutTransition] = [],
                zooms: [VideoZoom] = []) {
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.kept = VideoRange.merged(kept ?? [VideoRange(0, self.duration)], duration: self.duration)
        let limit = self.duration
        self.stills = stills.filter { $0.time.isFinite && $0.time >= 0 && $0.time < limit }
        self.transitions = []
        var accepted: [VideoZoom] = []
        for zoom in zooms.sorted(by: { $0.range.start < $1.range.start })
        where zoom.range.start >= 0 && zoom.range.end <= limit && zoom.range.duration > 0
            && accepted.last.map({ $0.range.end <= zoom.range.start }) ?? true { accepted.append(zoom) }
        self.zooms = accepted
        reconcileTransitions(from: transitions)
    }
    /// 再生位置が既存の区間の中なら、その区間の矩形を描き直す。外なら位置を中心に、残す範囲と前後の区間の間へ収めて置く。
    @discardableResult public mutating func addZoom(drag: CGRect, size: CGSize, at time: Double) -> UUID? {
        guard time.isFinite, let rect = VideoZoom.fitted(drag, size: size) else { return nil }
        if let index = zooms.firstIndex(where: { $0.range.contains(time) }) {
            zooms[index].rect = rect; return zooms[index].id
        }
        guard let segment = kept.first(where: { $0.contains(time) })
                ?? kept.min(by: { distance($0, time) < distance($1, time) }) else { return nil }
        let t = min(segment.end, max(segment.start, time))
        // 切った範囲から寄せた位置が既存の区間の中なら、見えていない区間を描き直さずに置かない。
        guard !zooms.contains(where: { $0.range.contains(t) }) else { return nil }
        let lower = max(segment.start, zooms.last { $0.range.end <= t }?.range.end ?? 0)
        let upper = min(segment.end, zooms.first { $0.range.start > t }?.range.start ?? duration)
        guard upper - lower >= VideoZoom.minimumDuration else { return nil }
        let length = min(VideoZoom.initialDuration, upper - lower)
        let start = min(upper - length, max(lower, t - length / 2))
        let zoom = VideoZoom(range: VideoRange(start, start + length), rect: rect)
        guard !zooms.contains(where: { $0.range.start < zoom.range.end && zoom.range.start < $0.range.end }) else { return nil }
        zooms.append(zoom); zooms.sort { $0.range.start < $1.range.start }
        return zoom.id
    }
    private func distance(_ range: VideoRange, _ time: Double) -> Double {
        time < range.start ? range.start - time : max(0, time - range.end)
    }
    public mutating func removeZoom(_ id: UUID) { zooms.removeAll { $0.id == id } }
    /// 寸法を保って矩形を動かす。元録画の端で止める。
    public mutating func moveZoom(_ id: UUID, by delta: CGPoint, size: CGSize) {
        guard let index = zooms.firstIndex(where: { $0.id == id }) else { return }
        zooms[index].rect = VideoZoom.moved(zooms[index].rect, by: delta, size: size)
    }
    /// つかんだ辺を動かし、縦横比を保ってリサイズする。edgesは元録画の左上原点の向き。
    public mutating func resizeZoom(_ id: UUID, edges: LastFrameEdges, by delta: CGPoint, size: CGSize) {
        guard let index = zooms.firstIndex(where: { $0.id == id }) else { return }
        zooms[index].rect = VideoZoom.resized(zooms[index].rect, edges: edges, by: delta, size: size)
    }
    /// イン・アウトの補間の秒数を区間ごとに変える。
    public mutating func setZoomEase(_ id: UUID, seconds: Double) {
        guard let index = zooms.firstIndex(where: { $0.id == id }) else { return }
        zooms[index].setEase(seconds)
    }
    /// 前後の区間と録画の両端で止め、最短の長さより縮めない。制限後の端の時刻を返す。
    @discardableResult public mutating func moveZoomBoundary(index: Int, start: Bool, to time: Double) -> Double? {
        guard zooms.indices.contains(index), time.isFinite else { return nil }
        let range = zooms[index].range
        let minimum = min(VideoZoom.minimumDuration, range.duration)
        if start {
            let limit = index == 0 ? 0 : zooms[index - 1].range.end
            zooms[index].range.start = min(range.end - minimum, max(limit, time))
            return zooms[index].range.start
        }
        let limit = index == zooms.count - 1 ? duration : zooms[index + 1].range.start
        zooms[index].range.end = max(range.start + minimum, min(limit, time))
        return zooms[index].range.end
    }
    /// 長さを保って区間を動かす。前後の区間と録画の両端で止める。制限後の始まりの時刻を返す。
    @discardableResult public mutating func moveZoomRange(index: Int, by delta: Double) -> Double? {
        guard zooms.indices.contains(index), delta.isFinite else { return nil }
        let range = zooms[index].range
        let lower = index == 0 ? 0 : zooms[index - 1].range.end
        let upper = index == zooms.count - 1 ? duration : zooms[index + 1].range.start
        let start = min(upper - range.duration, max(lower, range.start + delta))
        zooms[index].range = VideoRange(start, start + range.duration)
        return start
    }
    /// 時間軸で選んだ範囲にズームを置く。録画の中へ切り詰め、ほかの区間と重なるか最短の長さに足りなければ置かない。
    @discardableResult public mutating func addZoom(drag: CGRect, size: CGSize, range: VideoRange) -> UUID? {
        guard let rect = VideoZoom.fitted(drag, size: size) else { return nil }
        let clipped = VideoRange(max(0, range.start), min(duration, range.end))
        guard clipped.duration >= VideoZoom.minimumDuration,
              !zooms.contains(where: { $0.range.start < clipped.end && clipped.start < $0.range.end }) else { return nil }
        let zoom = VideoZoom(range: clipped, rect: rect)
        zooms.append(zoom); zooms.sort { $0.range.start < $1.range.start }
        return zoom.id
    }
    public var interiorCuts: [VideoRange] { cuts.filter { $0.start > 0 && $0.end < duration } }
    public func transition(for range: VideoRange) -> VideoCutTransition {
        transitions.first { $0.range == range } ?? VideoCutTransition(range: range)
    }
    public mutating func setTransition(for range: VideoRange, kind: VideoTransitionKind, speed: Int? = nil) {
        guard let index = transitions.firstIndex(where: { $0.range == range }) else { return }
        let old = transitions[index]
        transitions[index] = VideoCutTransition(range: range, kind: kind, speed: speed ?? old.speed)
    }
    /// 結合時は変更前の長さで勝者を決める。同じ長さなら前の範囲を優先する。
    private mutating func reconcileTransitions(from old: [VideoCutTransition]) {
        transitions = interiorCuts.map { range in
            let inherited = old.filter { $0.range.start < range.end && $0.range.end > range.start }
                .sorted { $0.range.duration == $1.range.duration ? $0.range.start < $1.range.start : $0.range.duration > $1.range.duration }.first
            return VideoCutTransition(range: range, kind: inherited?.kind ?? .none, speed: inherited?.speed)
        }
    }
    @discardableResult public mutating func addStill(at time: Double) -> UUID? {
        guard time.isFinite, time >= 0, time < duration,
              !stills.contains(where: { abs($0.time - time) < 1 / 120000.0 }) else { return nil }
        let mark = VideoStillMark(time: time); stills.append(mark); return mark.id
    }
    public mutating func removeStill(_ id: UUID) { stills.removeAll { $0.id == id } }
    public var keptDuration: Double { kept.reduce(0) { $0 + $1.duration } }
    public var transitionDuration: Double { transitions.reduce(0) { $0 + $1.outputDuration } }
    public var outputDuration: Double { keptDuration + transitionDuration }
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
        let old = transitions; kept = next; reconcileTransitions(from: old); return true
    }
    public mutating func restore(_ range: VideoRange) {
        let old = transitions
        kept = VideoRange.merged(kept + [range], duration: duration)
        reconcileTransitions(from: old)
    }
    /// 正規化で区間が結合・消滅しても、制限後のドラッグ端の時刻を返す。
    @discardableResult public mutating func moveBoundary(segment: Int, start: Bool, to time: Double) -> Double? {
        guard kept.indices.contains(segment), time.isFinite else { return nil }
        let old = transitions
        let minimum = min(1 / 60000.0, kept[segment].duration)
        let boundary: Double
        if kept.count > 1, (start && time >= kept[segment].end || !start && time <= kept[segment].start) {
            // 隣り合う切り口の間の残す区間をなくしたときは、切り口を1つへ結合する。
            boundary = start ? kept[segment].end : kept[segment].start
            kept.remove(at: segment)
        } else if start {
            let limit = segment == 0 ? 0 : kept[segment - 1].end
            kept[segment].start = min(kept[segment].end - minimum, max(limit, time))
            boundary = kept[segment].start
        } else {
            let limit = segment == kept.count - 1 ? duration : kept[segment + 1].start
            kept[segment].end = max(kept[segment].start + minimum, min(limit, time))
            boundary = kept[segment].end
        }
        kept = VideoRange.merged(kept, duration: duration)
        reconcileTransitions(from: old)
        return boundary
    }
    /// I/Oは外側の両端。指定点が切った範囲の中なら、その点まで境界を戻す。
    public mutating func setStart(_ time: Double) {
        guard let end = kept.last?.end, time.isFinite else { return }
        let old = transitions
        let start = min(end - min(end, 1 / 60000.0), max(0, time))
        kept = kept.filter { $0.end > start }.map { VideoRange(max(start, $0.start), $0.end) }
        kept[0].start = start
        reconcileTransitions(from: old)
    }
    public mutating func setEnd(_ time: Double) {
        guard let start = kept.first?.start, time.isFinite else { return }
        let old = transitions
        let end = max(start + min(duration - start, 1 / 60000.0), min(duration, time))
        kept = kept.filter { $0.start < end }.map { VideoRange($0.start, min(end, $0.end)) }
        kept[kept.count - 1].end = end
        reconcileTransitions(from: old)
    }
    public func outputTime(forSource time: Double) -> Double? {
        let plan = VideoExportPlan(document: self)
        for segment in plan.segments {
            if segment.source.contains(time) { return segment.outputTime(forSource: time) }
        }
        return time == kept.last?.end ? plan.duration : nil
    }
    /// 再生だけに適用。nilは残す範囲の終端。クリックとコマ送りには使わない。
    public func playbackTime(at time: Double) -> Double? {
        for range in VideoExportPlan(document: self).segments.map(\.source) {
            if time < range.start { return range.start }
            if range.contains(time) { return time }
        }
        return nil
    }
    /// 再生で切った範囲の頭を前から越えたときだけ、暗転・ディゾルブを見せる。
    /// 演出の後に本体が末尾の手前を再生していても、同じ演出を繰り返さない。
    public func transitionCrossed(from previous: Double, to time: Double) -> VideoCutTransition? {
        transitions.first { ($0.kind == .fade || $0.kind == .dissolve) && previous < $0.range.start && time >= $0.range.start }
    }
    public var completionText: String { completionText(copiesStills: true) }
    /// `[clipboard] mode = "none"`では静止画を載せないので「保存」と書く。
    public func completionText(copiesStills: Bool) -> String {
        let trim = isTrimmed ? (transitionDuration > 0
            ? String(format: "残す %.1f秒 + つなぎ %.1f秒", keptDuration, transitionDuration)
            : String(format: "%.1f秒に切る", outputDuration)) : nil
        let images = stills.isEmpty ? nil : "静止画\(stills.count)枚を" + (copiesStills ? "コピー" : "保存")
        let zoom = zooms.isEmpty ? nil : "ズーム\(zooms.count)区間を付ける"
        let actions = [trim, zoom, images].compactMap { $0 }
        return actions.isEmpty ? "ドラッグで切る範囲を選ぶ ・ ⏎でこのコマを撮る" : "完了で " + actions.joined(separator: " ・ ")
    }
}

/// 元録画の順に残す区間・早送り区間を並べ、静止コマの演出をつなぎ目へ差し込む。
public struct VideoExportPlan: Sendable {
    public struct Segment: Sendable {
        public var source: VideoRange
        public var outputStart: Double
        public var speed: Int = 1
        public var outputDuration: Double { source.duration / Double(speed) }
        public func outputTime(forSource time: Double) -> Double { outputStart + (time - source.start) / Double(speed) }
    }
    public struct Junction: Sendable {
        public var precedingSegment: Int
        public var outputTime: Double
        public var transition: VideoCutTransition
        public var followingSegment: Int
    }
    public var segments: [Segment]
    public var junctions: [Junction]
    public var duration: Double
    /// 元録画の秒数で寄り方を決める。早送りは間引き後のコマ、暗転・ディゾルブは合成後のコマへ掛ける。
    public var zooms: [VideoZoom]
    public func zoomCrop(atSource time: Double, size: CGSize) -> CGRect? { zooms.crop(at: time, size: size) }
    public func zoomPieces(source: VideoRange, fps: Int, size: CGSize) -> [VideoZoomPiece] {
        zooms.pieces(source: source, fps: fps, size: size)
    }
    /// 書き出しの時間単位。コマ・トラック・MP4全体をこの単位へ揃える。
    public static let timescale: Int64 = 60000
    public static func tick(_ seconds: Double) -> Int64 { Int64((seconds * Double(timescale)).rounded()) }
    /// 残す区間のコマを寄り方ごとに分け、出力の時刻を時間単位へ丸めてから並べる。
    /// 丸めで長さが0になる区間は捨て、長さは終了と開始の差で求める。同じPTSのコマを2枚渡さないため。
    public func zoomOutputPieces(segment: Segment, source: VideoRange, fps: Int, size: CGSize) -> [VideoZoomOutputPiece] {
        var result: [VideoZoomOutputPiece] = []
        for piece in zoomPieces(source: source, fps: fps, size: size) {
            let start = Self.tick(segment.outputTime(forSource: piece.source.start))
            let end = Self.tick(segment.outputTime(forSource: piece.source.end))
            guard end > start else { continue }
            if let last = result.last, last.crop == piece.crop, last.end == start {
                result[result.count - 1].end = end
            } else { result.append(VideoZoomOutputPiece(start: start, end: end, crop: piece.crop)) }
        }
        return result
    }
    /// 演出の前は切った範囲の頭、後ろは末尾の寄り方で、その間を進み具合で補間する。
    public func transitionCrop(_ junction: Junction, progress: Double, size: CGSize) -> CGRect? {
        let before = zoomCrop(atSource: segments[junction.precedingSegment].source.end, size: size)
        let after = zoomCrop(atSource: segments[junction.followingSegment].source.start, size: size)
        if before == nil, after == nil { return nil }
        let full = CGRect(origin: .zero, size: size)
        return VideoZoom.interpolated(from: before ?? full, to: after ?? full, min(1, max(0, progress)))
    }
    public init(document: VideoEditDocument) {
        var offset = 0.0; segments = []; junctions = []; zooms = document.zooms
        for (index, range) in document.kept.enumerated() {
            if index > 0 {
                let cut = VideoRange(document.kept[index - 1].end, range.start)
                let transition = document.transition(for: cut)
                let preceding = segments.count - 1
                if transition.kind == .fastForward {
                    segments.append(Segment(source: cut, outputStart: offset, speed: transition.multiplier))
                }
                junctions.append(Junction(precedingSegment: preceding, outputTime: offset, transition: transition, followingSegment: segments.count))
                offset += transition.outputDuration
            }
            segments.append(Segment(source: range, outputStart: offset)); offset += range.duration
        }
        duration = offset
    }
}

/// 残す区間の音を元録画から並べる。早送りは無音、暗転・ディゾルブは切った範囲の音で絞り・重ねる。
public struct VideoAudioPlan: Equatable, Sendable {
    public struct Clip: Equatable, Sendable {
        public var source: VideoRange
        public var outputStart: Double
        public var fadeIn: Double
        public var fadeOut: Double
        /// 重なる前後の音を別トラックへ置くため、0と1を交互に使う。
        public var track: Int
        public var outputEnd: Double { outputStart + source.duration }
    }
    /// 切り口のプツッという音を防ぐ短い絞り。
    public static let seam = 0.01
    public var clips: [Clip]
    public init(plan: VideoExportPlan, sourceDuration: Double) {
        let kept = plan.segments.indices.filter { plan.segments[$0].speed == 1 }
        clips = kept.enumerated().map { order, index in
            let segment = plan.segments[index]
            return Clip(source: segment.source, outputStart: segment.outputStart,
                        fadeIn: segment.source.start > 0 ? Self.seam : 0,
                        fadeOut: segment.source.end < sourceDuration ? Self.seam : 0, track: order % 2)
        }
        for junction in plan.junctions {
            guard let before = kept.firstIndex(of: junction.precedingSegment),
                  let after = kept.firstIndex(of: junction.followingSegment) else { continue }
            let cut = VideoRange(plan.segments[junction.precedingSegment].source.end, plan.segments[junction.followingSegment].source.start)
            // 演出の0.5秒は残した範囲を削らずに差し込むため、切った範囲の音を延ばして埋める。
            let length = junction.transition.kind.audioOverlap(cut: cut)
            guard length > 0 else { continue }
            clips[before].source = VideoRange(clips[before].source.start, clips[before].source.end + length)
            clips[before].fadeOut = length
            clips[after].source = VideoRange(clips[after].source.start - length, clips[after].source.end)
            clips[after].outputStart -= length
            clips[after].fadeIn = length
        }
        // 短い区間でも絞りの範囲を重ねない。
        for index in clips.indices {
            let total = clips[index].fadeIn + clips[index].fadeOut, duration = clips[index].source.duration
            guard total > duration, total > 0 else { continue }
            clips[index].fadeIn *= duration / total; clips[index].fadeOut *= duration / total
        }
    }
}

extension VideoTransitionKind {
    /// 演出の間に鳴らす、切った範囲の頭と末尾の音の長さ。暗転は0.25秒ずつ絞って戻し、ディゾルブは0.5秒重ねる。
    public func audioOverlap(cut: VideoRange) -> Double {
        switch self {
        case .fade: min(0.25, max(0, cut.duration))
        case .dissolve: min(0.5, max(0, cut.duration))
        case .none, .fastForward: 0
        }
    }
}

/// 編集画面の演出0.5秒で、書き出しと同じ音の絞りを再生する。経過秒から前後の音量を返す。
public struct VideoTransitionAudioPreview: Equatable, Sendable {
    public static let duration = 0.5
    /// 切った範囲の頭から鳴らし、0へ絞る長さ。
    public let outgoing: Double
    /// 切った範囲の末尾の手前から鳴らし、1へ戻す長さ。
    public let incoming: Double
    public init(kind: VideoTransitionKind, cut: VideoRange) {
        outgoing = kind.audioOverlap(cut: cut); incoming = outgoing
    }
    public var incomingStart: Double { Self.duration - incoming }
    public func outgoingVolume(at elapsed: Double) -> Float {
        guard outgoing > 0, elapsed < outgoing else { return 0 }
        return Float(1 - max(0, elapsed) / outgoing)
    }
    public func incomingVolume(at elapsed: Double) -> Float {
        guard incoming > 0, elapsed > incomingStart else { return 0 }
        return Float(min(1, (elapsed - incomingStart) / incoming))
    }
}

public enum VideoTimelineHit: Equatable, Sendable {
    case boundary(segment: Int, start: Bool)
    case zoomBoundary(index: Int, start: Bool)
    case zoom(index: Int)
    case strip
    case outside
}
public enum VideoTimelineGesture {
    /// 時間軸のバーの下側に重ねるズーム区間のレーン。バーの上端からのpt。
    public static let zoomLane: ClosedRange<Double> = 38...54
    public static func hit(x: Double, y: Double, width: Double, document: VideoEditDocument) -> VideoTimelineHit {
        guard width > 0, document.duration > 0, (0...56).contains(y) else { return .outside }
        // ズームのレーンでは、残す範囲のつまみよりズーム区間を優先する。
        if zoomLane.contains(y) {
            var best: (Double, VideoTimelineHit)?
            for (index, zoom) in document.zooms.enumerated() {
                for (time, start) in [(zoom.range.start, true), (zoom.range.end, false)] {
                    let distance = abs(x - time / document.duration * width)
                    if distance <= 7, best == nil || distance < best!.0 { best = (distance, .zoomBoundary(index: index, start: start)) }
                }
            }
            if let best { return best.1 }
            if let index = document.zooms.firstIndex(where: {
                $0.range.start / document.duration * width <= x && x < $0.range.end / document.duration * width
            }) { return .zoom(index: index) }
        }
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

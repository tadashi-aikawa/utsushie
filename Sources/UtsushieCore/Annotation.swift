import Foundation
import CoreGraphics

public enum AnnotationTool: String, CaseIterable, Sendable {
    /// cropは注釈を作らず、ドラッグした範囲を新しい画像にする。
    case selection, crop, rectangle, spotlight, text, number, arrow, line, freehand, highlighter, mosaic
    public var label: String {
        switch self {
        case .selection: "選択"
        case .crop: "トリミング"
        case .rectangle: "枠"
        case .spotlight: "スポット"
        case .text: "文字"
        case .number: "番号"
        case .arrow: "矢印"
        case .line: "直線"
        case .freehand: "手書き"
        case .highlighter: "蛍光ペン"
        case .mosaic: "モザイク"
        }
    }
    public var key: String {
        switch self {
        case .selection: "v"
        // プレビューのトリミング⌘Kと同じ刻印。Cは色の順送りに使う。
        case .crop: "k"
        case .rectangle: "r"
        case .spotlight: "s"
        case .text: "t"
        case .number: "n"
        case .arrow: "a"
        case .line: "l"
        // Pは蛍光ペン。名前を「ペン」にせず、Freehandの頭文字にする。
        case .freehand: "f"
        case .highlighter: "p"
        case .mosaic: "m"
        }
    }
    public var keyCode: UInt16 {
        switch self {
        case .selection: 9
        case .crop: 40
        case .rectangle: 15
        case .spotlight: 1
        case .text: 17
        case .number: 45
        case .arrow: 0
        case .line: 37
        case .freehand: 3
        case .highlighter: 35
        case .mosaic: 46
        }
    }
    public var layer: Int {
        switch self {
        case .selection, .crop: -1
        case .mosaic: 0
        case .spotlight: 1
        case .highlighter: 2
        case .rectangle, .arrow, .line, .freehand: 3
        case .text: 4
        case .number: 5
        }
    }
    public var allowsMargin: Bool { [.text, .number, .arrow, .line, .freehand, .rectangle].contains(self) }
    public var usesInkColor: Bool { [.rectangle, .spotlight, .arrow, .line, .freehand, .text, .number].contains(self) }
    /// 引いた点列を持つ。startとendは最初と最後の点。
    public var usesPoints: Bool { self == .highlighter || self == .freehand }
    public var usesSize: Bool { ![.selection, .crop, .mosaic].contains(self) }
    /// 注釈を作るツール。選択とトリミングは作らない。
    public var createsAnnotation: Bool { self != .selection && self != .crop }
    /// 置かれる注釈の見本をカーソルにする。始点を合わせて引く枠・矢印などは十字のまま。
    /// 文字は引き出し線の起点を押した点に合わせるため十字。ラベルの見本はドラッグでラベルの位置とずれる。
    public var usesSampleCursor: Bool { [.freehand, .highlighter, .number].contains(self) }
    /// 縁・角・端点・指す点で変形できる注釈の種類。選択ツールはすべて、作成ツールは同じ種類だけ。
    /// 別の種類の注釈の縁では、その上へ番号や矢印を置くことを優先する。同じ種類を重ねることは少ないため。
    public func reshapes(_ kind: AnnotationTool) -> Bool { self == .selection || self == kind }
}

public enum ColorCycleDirection: Int, Sendable {
    case next = 1, previous = -1

    public init?(keyCode: UInt16, shift: Bool = false, modified: Bool = false, editingText: Bool = false) {
        guard keyCode == 8, !modified, !editingText else { return nil }
        self = shift ? .previous : .next
    }
}

public enum InkColor: String, CaseIterable, Sendable {
    case red, orange, green, indigo, purple, pink, black, white

    public var label: String {
        switch self {
        case .red: "朱"
        case .orange: "橙"
        case .green: "緑"
        case .indigo: "藍"
        case .purple: "紫"
        case .pink: "桃"
        case .black: "墨"
        case .white: "白"
        }
    }
    public var key: String {
        switch self {
        case .red: "1"
        case .orange: "2"
        case .green: "3"
        case .indigo: "4"
        case .purple: "5"
        case .pink: "6"
        case .black: "7"
        case .white: "8"
        }
    }
    public init?(keyCode: UInt16, modified: Bool = false, editingText: Bool = false) {
        guard !modified, !editingText else { return nil }
        switch keyCode {
        case 18: self = .red
        case 19: self = .orange
        case 20: self = .green
        case 21: self = .indigo
        case 23: self = .purple
        case 22: self = .pink
        case 26: self = .black
        case 28: self = .white
        default: return nil
        }
    }
    public func cycled(_ direction: ColorCycleDirection) -> InkColor {
        let colors = Self.allCases
        let index = colors.firstIndex(of: self)!
        return colors[(index + direction.rawValue + colors.count) % colors.count]
    }
}

public enum HighlighterColor: String, CaseIterable, Sendable {
    case yellow, cyan, pink, green

    public var label: String {
        switch self {
        case .yellow: "黄"
        case .cyan: "水色"
        case .pink: "桃"
        case .green: "緑"
        }
    }
    public var key: String {
        switch self {
        case .yellow: "1"
        case .cyan: "2"
        case .pink: "3"
        case .green: "4"
        }
    }
    public func cycled(_ direction: ColorCycleDirection) -> HighlighterColor {
        let colors = Self.allCases
        let index = colors.firstIndex(of: self)!
        return colors[(index + direction.rawValue + colors.count) % colors.count]
    }
}

public enum HighlighterAction: Equatable, Sendable {
    case color(HighlighterColor)
    case cycleColor(ColorCycleDirection)
    case toggleDarkBackground

    public init?(keyCode: UInt16, shift: Bool = false, modified: Bool = false, editingText: Bool = false) {
        if let direction = ColorCycleDirection(keyCode: keyCode, shift: shift, modified: modified, editingText: editingText) {
            self = .cycleColor(direction)
            return
        }
        guard !modified, !shift, !editingText else { return nil }
        switch keyCode {
        case 18: self = .color(.yellow)
        case 19: self = .color(.cyan)
        case 20: self = .color(.pink)
        case 21: self = .color(.green)
        case 2: self = .toggleDarkBackground
        default: return nil
        }
    }
}

/// 注釈だけは画像の左上原点・ピクセル座標。画面座標モデルとは混ぜない。
public struct Annotation: Equatable, Sendable, Identifiable {
    public let id: UUID
    public var tool: AnnotationTool
    public var start: CGPoint
    public var end: CGPoint
    public var text: String
    public var leaderTarget: CGPoint?
    public var points: [CGPoint]
    public var highlighterColor: HighlighterColor
    public var darkBackground: Bool
    public var inkColor: InkColor
    public var size: AnnotationSize
    public init(id: UUID = UUID(), tool: AnnotationTool, start: CGPoint, end: CGPoint? = nil, text: String = "", leaderTarget: CGPoint? = nil, points: [CGPoint] = [],
                highlighterColor: HighlighterColor = .yellow, darkBackground: Bool = false, inkColor: InkColor = .red, size: AnnotationSize = .normal) {
        self.id = id; self.tool = tool; self.start = start; self.end = end ?? start; self.text = text
        self.leaderTarget = [.text, .number].contains(tool) ? leaderTarget : nil
        self.points = tool.usesPoints ? (points.isEmpty ? [start, end ?? start] : points) : []
        self.highlighterColor = tool == .highlighter ? highlighterColor : .yellow
        self.darkBackground = tool == .highlighter && darkBackground
        self.inkColor = tool.usesInkColor ? inkColor : .red
        self.size = tool.usesSize ? size : .normal
    }
    public var rect: CGRect {
        let vertices = tool.usesPoints ? points : [start, end]
        let xs = vertices.map(\.x), ys = vertices.map(\.y)
        return CGRect(x: xs.min() ?? start.x, y: ys.min() ?? start.y,
                      width: (xs.max() ?? start.x) - (xs.min() ?? start.x),
                      height: (ys.max() ?? start.y) - (ys.min() ?? start.y))
    }
    /// ラベルだけの移動では指す点を残す。線や複数選択で動かすときだけ指す点も動かす。
    public func translated(by delta: CGPoint, movingLeader: Bool = false) -> Annotation {
        var result = self
        result.start.x += delta.x; result.start.y += delta.y
        result.end.x += delta.x; result.end.y += delta.y
        result.points = points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
        if movingLeader { result.leaderTarget = leaderTarget.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) } }
        return result
    }
}

/// 画像の寸法によらず、撮影時の1ptあたりの画素数だけで決める。中の文字に対して同じ見た目にする。
public struct AnnotationStyle: Equatable, Sendable {
    public let fontSize: Double
    public let lineWidth: Double
    public let numberDiameter: Double
    public let blockSize: Int
    public let edge: Double
    public let radius: Double
    public let horizontalPadding: Double
    public let verticalPadding: Double
    public let marginPadding: Double
    public let leaderDotDiameter: Double
    /// 複製・貼り付けで右下へずらす量。
    public let pasteOffset: Double
    /// 撮影時の1ptあたりの画素数。Rで2xにした画像は2。
    public let scale: Double
    /// 1xの×1で22.5px。文字の行を1本で覆える高さにする。
    public var highlighterWidth: Double { lineWidth * 7.5 }
    public init(size: AnnotationSize = .normal, scale: Double = 1) {
        self.scale = scale
        fontSize = 18 * scale * size.multiplier
        lineWidth = 3 * scale * size.multiplier
        numberDiameter = fontSize * 1.5
        blockSize = Int((15 * scale).rounded())
        let factor = lineWidth / 3
        edge = 2 * factor; radius = 6 * factor
        horizontalPadding = 11 * factor; verticalPadding = 6 * factor
        marginPadding = 24 * scale
        leaderDotDiameter = 9 * scale * size.multiplier
        pasteOffset = 18 * scale
    }
    /// すでに倍率付きのスタイルを渡しても二重に拡大しない。
    public func forAnnotation(_ annotation: Annotation) -> AnnotationStyle {
        AnnotationStyle(size: annotation.size, scale: scale)
    }
    public func numberRect(at point: CGPoint, number: Int) -> CGRect {
        let width = numberDiameter + Double(max(0, String(number).count - 1)) * fontSize * 0.6
        return CGRect(x: point.x - width / 2, y: point.y - numberDiameter / 2, width: width, height: numberDiameter)
    }
}

public struct AnnotationDocument: Equatable, Sendable {
    public var annotations: [Annotation]
    /// 元画像のどこを今の画像にしているか。注釈の座標は今の画像の左上が原点。
    public var crop: AnnotationCrop?
    /// 撮影時の1ptあたりの画素数。分からない画像は1。トリミングしても変えない。
    public var scale: Double
    public init(annotations: [Annotation] = [], crop: AnnotationCrop? = nil, scale: Double = 1) {
        self.annotations = annotations; self.crop = crop; self.scale = scale
    }
    public func style(size: AnnotationSize = .normal) -> AnnotationStyle {
        AnnotationStyle(size: size, scale: scale)
    }
    public var nextNumber: Int { annotations.filter { $0.tool == .number }.count + 1 }
    public func number(for id: UUID) -> Int? {
        let numbers = annotations.filter { $0.tool == .number }
        return numbers.firstIndex { $0.id == id }.map { $0 + 1 }
    }
    public var ordered: [Annotation] {
        annotations.enumerated().sorted {
            $0.element.tool.layer == $1.element.tool.layer ? $0.offset < $1.offset : $0.element.tool.layer < $1.element.tool.layer
        }.map(\.element)
    }
    public mutating func replace(_ annotation: Annotation) {
        if let index = annotations.firstIndex(where: { $0.id == annotation.id }) { annotations[index] = annotation }
        else { annotations.append(annotation) }
    }
    public mutating func remove(_ id: UUID) { annotations.removeAll { $0.id == id } }
    public func bounds(of annotation: Annotation, style: AnnotationStyle) -> CGRect {
        let style = style.forAnnotation(annotation)
        return annotation.tool == .number ? style.numberRect(at: annotation.start, number: number(for: annotation.id) ?? nextNumber) : annotation.rect
    }
    public func leaderSegment(for annotation: Annotation, style: AnnotationStyle) -> (target: CGPoint, labelEdge: CGPoint)? {
        let style = style.forAnnotation(annotation)
        let rect = bounds(of: annotation, style: style)
        return AnnotationGeometry.leaderSegment(for: annotation, radius: annotation.tool == .number ? rect.height / 2 : style.radius, bounds: rect)
    }
    /// ラベルの上はラベルとして扱う。線の途中だけを、指す点ごと動かす場所にする。
    public func hitsLeaderLine(_ annotation: Annotation, at point: CGPoint, style: AnnotationStyle, tolerance: Double) -> Bool {
        let style = style.forAnnotation(annotation)
        guard let segment = leaderSegment(for: annotation, style: style),
              !bounds(of: annotation, style: style).insetBy(dx: -style.edge, dy: -style.edge).contains(point) else { return false }
        return AnnotationGeometry.distance(point, toSegmentFrom: segment.target, to: segment.labelEdge) <= max(tolerance, style.lineWidth / 2 + style.edge)
    }
    /// kindを渡すと、その種類の注釈だけを同じ優先順で判定する。
    public func hit(at point: CGPoint, style: AnnotationStyle, tolerance: Double, includeAreaInterior: Bool = false, kind: AnnotationTool? = nil) -> UUID? {
        let ordered = kind.map { kind in self.ordered.filter { $0.tool == kind } } ?? self.ordered
        // ラベルを線より先に判定する。別のラベルの上を通る線が入力を奪わない。
        if let label = ordered.reversed().first(where: { labelContains($0, point, style: style) }) { return label.id }
        if let leader = ordered.reversed().first(where: { annotation in
            let style = style.forAnnotation(annotation)
            guard let segment = leaderSegment(for: annotation, style: style) else { return false }
            return hitsLeaderLine(annotation, at: point, style: style, tolerance: tolerance)
                || hypot(point.x - segment.target.x, point.y - segment.target.y) <= max(tolerance, style.leaderDotDiameter / 2 + style.edge)
        }) { return leader.id }
        return ordered.reversed().first { annotation in
            let style = style.forAnnotation(annotation)
            if [.arrow, .line].contains(annotation.tool) {
                return AnnotationGeometry.distance(point, toSegmentFrom: annotation.start, to: annotation.end) <= max(tolerance, style.lineWidth * 0.75 + style.edge)
            }
            if annotation.tool == .highlighter {
                return AnnotationGeometry.highlighterContains(point, annotation: annotation, style: style, tolerance: tolerance)
            }
            if annotation.tool.usesPoints {
                let radius = style.lineWidth * 0.75 + style.edge
                return zip(annotation.points, annotation.points.dropFirst()).contains {
                    AnnotationGeometry.distance(point, toSegmentFrom: $0, to: $1) <= max(tolerance, radius)
                }
            }
            let rect = bounds(of: annotation, style: style)
            if [.rectangle, .spotlight, .mosaic].contains(annotation.tool) {
                let inset = max(tolerance, style.lineWidth / 2 + style.edge)
                let outer = annotation.tool == .spotlight ? max(tolerance, style.lineWidth + style.edge * 2) : inset
                return rect.insetBy(dx: -outer, dy: -outer).contains(point) && (includeAreaInterior || !rect.insetBy(dx: inset, dy: inset).contains(point))
            }
            return rect.contains(point)
        }?.id
    }
    /// grabsLabelは⌥を押していること。文字・番号のツールでは、同じ種類のラベルを指す点を残して動かす。
    public func interaction(at point: CGPoint, selected: Set<UUID>, tool: AnnotationTool, style: AnnotationStyle, tolerance: Double,
                            grabsLabel: Bool = false) -> AnnotationInteraction {
        // 修飾なしのドラッグは、既存のラベルの中からでも新しい引き出し線を引くために残す。
        // ⌥は引き出し線の操作を変えない。線の上は次の注釈を置く場所のままで、⇧や複数選択では従来どおり移動する。
        if grabsLabel, let id = grabbedLabel(at: point, tool: tool, style: style) {
            return .move(id, leader: false)
        }
        if selected.count == 1, let annotation = annotations.first(where: { selected.contains($0.id) }), tool.reshapes(annotation.tool),
           let handle = AnnotationGeometry.resizeHandle(at: point, annotation: annotation, tolerance: tolerance) {
            return .resize(annotation.id, handle)
        }
        // 作成ツールは同じ種類の注釈だけで当たりを取る。上に別の種類の注釈が重なっていても、その縁を直せるようにする。
        // 当たりの幅とラベル優先の順はhitに任せ、同じ種類の中で手前のラベルが下の指す点を覆う場合も変えない。
        if tool != .selection, selected.count <= 1,
           let id = hit(at: point, style: style, tolerance: tolerance, kind: tool),
           let annotation = annotations.first(where: { $0.id == id }),
           let handle = reshapeHandle(of: annotation, at: point, selected: selected, style: style, tolerance: tolerance) {
            return .resize(id, handle)
        }
        if let id = hit(at: point, style: style, tolerance: tolerance, includeAreaInterior: tool == .selection || selected.count > 1),
           let annotation = annotations.first(where: { $0.id == id }) {
            if tool == .selection, selected.count <= 1,
               let handle = reshapeHandle(of: annotation, at: point, selected: selected, style: style, tolerance: tolerance) {
                return .resize(id, handle)
            }
            guard tool == .selection || selected.count > 1 else { return .create }
            return .move(id, leader: hitsLeaderLine(annotation, at: point, style: style, tolerance: tolerance))
        }
        return tool == .selection ? .none : .create
    }
    /// 文字・番号のツールで⌥を押したときにつかむラベル。描いた形で手前のラベルを決め、その種類がツールと同じときだけ返す。
    /// 外接矩形で測ると、円の番号の角に入る斜めの引き出し線までつかむため。手前の別の種類の下にあるラベルもつかまない。
    public func grabbedLabel(at point: CGPoint, tool: AnnotationTool, style: AnnotationStyle) -> UUID? {
        guard [.text, .number].contains(tool),
              let label = ordered.reversed().first(where: { annotation in
                  guard [.text, .number].contains(annotation.tool) else { return false }
                  let style = style.forAnnotation(annotation)
                  let rect = bounds(of: annotation, style: style).insetBy(dx: -style.edge, dy: -style.edge)
                  let radius = annotation.tool == .number ? rect.height / 2 : style.radius + style.edge
                  let corner = min(radius, rect.width / 2, rect.height / 2)
                  return CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil).contains(point)
              }), label.tool == tool else { return nil }
        return label.id
    }
    /// 文字・番号のラベルの面と縁。引き出し線は含めない。
    private func labelContains(_ annotation: Annotation, _ point: CGPoint, style: AnnotationStyle) -> Bool {
        let style = style.forAnnotation(annotation)
        return [.text, .number].contains(annotation.tool) && bounds(of: annotation, style: style).insetBy(dx: -style.edge, dy: -style.edge).contains(point)
    }
    /// 縁の帯・四隅・端点・指す点のうち、押した点にあるもの。
    private func reshapeHandle(of annotation: Annotation, at point: CGPoint, selected: Set<UUID>, style: AnnotationStyle, tolerance: Double) -> AnnotationResizeHandle? {
        let style = style.forAnnotation(annotation)
        let band: Double
        if annotation.tool == .spotlight { band = max(tolerance, style.lineWidth + style.edge * 2) }
        else if [.rectangle, .mosaic].contains(annotation.tool) { band = max(tolerance, style.lineWidth / 2 + style.edge) }
        else { band = tolerance }
        guard let handle = AnnotationGeometry.resizeHandle(at: point, annotation: annotation, tolerance: tolerance, edgeTolerance: band) else { return nil }
        // ラベルに隠れた指す点は、選択してつまみが見えるまではラベルの移動を奪わない。
        guard handle != .leaderTarget || selected.contains(annotation.id) || leaderSegment(for: annotation, style: style) != nil else { return nil }
        return handle
    }
    /// 余白は保存せず、外に中心があるラベル・枠と、外に端点がある矢印・外に点がある手書きから毎回求める。
    public func exportLayout(imageSize: CGSize) -> AnnotationExportLayout {
        let image = CGRect(origin: .zero, size: imageSize)
        var minX = image.minX, minY = image.minY, maxX = image.maxX, maxY = image.maxY
        for annotation in annotations where annotation.tool.allowsMargin {
            let style = self.style(size: annotation.size)
            let rect = bounds(of: annotation, style: style)
            let isOutside: Bool
            switch annotation.tool {
            case .arrow, .line: isOutside = !AnnotationGeometry.contains(annotation.start, in: image) || !AnnotationGeometry.contains(annotation.end, in: image)
            case .freehand: isOutside = annotation.points.contains { !AnnotationGeometry.contains($0, in: image) }
            default: isOutside = !AnnotationGeometry.containsCenter(of: rect, in: image)
            }
            guard isOutside else { continue }
            let ink = AnnotationGeometry.inkBounds(of: annotation, bounds: rect, style: style)
            if ink.minX < image.minX { minX = min(minX, floor(ink.minX - style.marginPadding)) }
            if ink.minY < image.minY { minY = min(minY, floor(ink.minY - style.marginPadding)) }
            if ink.maxX > image.maxX { maxX = max(maxX, ceil(ink.maxX + style.marginPadding)) }
            if ink.maxY > image.maxY { maxY = max(maxY, ceil(ink.maxY + style.marginPadding)) }
        }
        return AnnotationExportLayout(bounds: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), imageSize: imageSize)
    }
}

public struct AnnotationExportLayout: Equatable, Sendable {
    public let bounds: CGRect
    public let imageSize: CGSize
    public var left: Int { Int(-bounds.minX) }
    public var top: Int { Int(-bounds.minY) }
    public var right: Int { Int(bounds.maxX - imageSize.width) }
    public var bottom: Int { Int(bounds.maxY - imageSize.height) }
    public var summary: String {
        var result = "書き出し \(Int(bounds.width)) × \(Int(bounds.height))"
        for (name, amount) in [("左", left), ("上", top), ("右", right), ("下", bottom)] where amount > 0 {
            result += " \(name)に余白 \(amount)"
        }
        return result
    }
}

public enum AnnotationResizeHandle: Equatable, Sendable {
    case topLeft, topRight, bottomRight, bottomLeft, top, right, bottom, left, arrowStart, arrowEnd, leaderTarget
}
public enum AnnotationInteraction: Equatable, Sendable {
    /// leaderは引き出し線の途中をつかんだこと。ラベルと指す点をまとめて動かす。
    case none, create, move(UUID, leader: Bool = false), resize(UUID, AnnotationResizeHandle)
    public func cursor(tool: AnnotationTool) -> AnnotationCursor {
        switch self {
        case .none: return .arrow
        case .create: return tool == .selection ? .arrow : tool.usesSampleCursor ? .sample : .crosshair
        case .move: return .move
        case .resize(_, let handle):
            switch handle {
            case .topLeft, .bottomRight: return .diagonalDown
            case .topRight, .bottomLeft: return .diagonalUp
            case .top, .bottom: return .vertical
            case .left, .right: return .horizontal
            case .arrowStart, .arrowEnd, .leaderTarget: return .crosshair
            }
        }
    }
}
public enum AnnotationCursor: Equatable, Sendable {
    case arrow, crosshair, move, horizontal, vertical, diagonalDown, diagonalUp
    /// ツールの見本。手書きはインクの点、蛍光ペンは縦の帯、番号は半透明のラベル。
    case sample
}

public enum AnnotationGeometry {
    /// 判定は表示上のpt。縮小時も小さな誤ドラッグを注釈にしない。
    public static func isValidDrag(tool: AnnotationTool, from a: CGPoint, to b: CGPoint, displayScale: Double) -> Bool {
        if [.arrow, .line, .freehand, .highlighter, .text, .number].contains(tool) { return hypot(b.x - a.x, b.y - a.y) * displayScale > 4 }
        return abs(b.x - a.x) * displayScale > 4 && abs(b.y - a.y) * displayScale > 4
    }
    public static func handles(for annotation: Annotation) -> [CGPoint] {
        switch annotation.tool {
        case .rectangle, .spotlight, .mosaic:
            let r = annotation.rect
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        case .arrow, .line: return [annotation.start, annotation.end]
        case .text, .number: return annotation.leaderTarget.map { [$0] } ?? []
        case .selection, .crop, .freehand, .highlighter: return []
        }
    }
    public static func resizeHandle(at point: CGPoint, annotation: Annotation, tolerance: Double, edgeTolerance: Double? = nil) -> AnnotationResizeHandle? {
        let points = handles(for: annotation)
        if [.text, .number].contains(annotation.tool), let target = annotation.leaderTarget,
           hypot(point.x - target.x, point.y - target.y) <= tolerance { return .leaderTarget }
        if [.arrow, .line].contains(annotation.tool) {
            if hypot(point.x - annotation.start.x, point.y - annotation.start.y) <= tolerance { return .arrowStart }
            if hypot(point.x - annotation.end.x, point.y - annotation.end.y) <= tolerance { return .arrowEnd }
            return nil
        }
        guard [.rectangle, .spotlight, .mosaic].contains(annotation.tool) else { return nil }
        let corners: [AnnotationResizeHandle] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
        if let index = points.firstIndex(where: { hypot(point.x - $0.x, point.y - $0.y) <= tolerance }) { return corners[index] }
        let r = annotation.rect
        let edge = edgeTolerance ?? tolerance
        if point.x >= r.minX - edge, point.x <= r.maxX + edge {
            if abs(point.y - r.minY) <= edge { return .top }
            if abs(point.y - r.maxY) <= edge { return .bottom }
        }
        if point.y >= r.minY - edge, point.y <= r.maxY + edge {
            if abs(point.x - r.minX) <= edge { return .left }
            if abs(point.x - r.maxX) <= edge { return .right }
        }
        return nil
    }
    public static func resized(_ annotation: Annotation, handle: AnnotationResizeHandle, to point: CGPoint) -> Annotation {
        var result = annotation
        let r = annotation.rect
        switch handle {
        case .leaderTarget: result.leaderTarget = point
        case .arrowStart: result.start = point
        case .arrowEnd: result.end = point
        case .topLeft: result.start = CGPoint(x: r.maxX, y: r.maxY); result.end = point
        case .topRight: result.start = CGPoint(x: r.minX, y: r.maxY); result.end = point
        case .bottomRight: result.start = CGPoint(x: r.minX, y: r.minY); result.end = point
        case .bottomLeft: result.start = CGPoint(x: r.maxX, y: r.minY); result.end = point
        case .top: result.start = CGPoint(x: r.minX, y: point.y); result.end = CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: result.start = CGPoint(x: r.minX, y: r.minY); result.end = CGPoint(x: r.maxX, y: point.y)
        case .left: result.start = CGPoint(x: point.x, y: r.minY); result.end = CGPoint(x: r.maxX, y: r.maxY)
        case .right: result.start = CGPoint(x: r.minX, y: r.minY); result.end = CGPoint(x: point.x, y: r.maxY)
        }
        return result
    }
    public static func containsCenter(of rect: CGRect, in image: CGRect) -> Bool {
        contains(CGPoint(x: rect.midX, y: rect.midY), in: image)
    }
    public static func contains(_ point: CGPoint, in rect: CGRect) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }
    public static func clamped(_ point: CGPoint, to imageSize: CGSize) -> CGPoint {
        CGPoint(x: max(0, min(imageSize.width, point.x)), y: max(0, min(imageSize.height, point.y)))
    }
    /// 制限前の中心で外への配置を判定する。ラベルの移動で指す点は変えない。
    public static func placed(_ annotation: Annotation, bounds: CGRect, imageSize: CGSize, scale: Double = 1) -> Annotation {
        let image = CGRect(origin: .zero, size: imageSize)
        var result = annotation
        if keepsAreaInside(annotation, imageSize: imageSize) {
            result = placingArea(annotation, imageSize: imageSize, scale: scale)
        } else if ![.arrow, .line, .freehand].contains(annotation.tool), !annotation.tool.allowsMargin || containsCenter(of: bounds, in: image) {
            func offset(_ minimum: CGFloat, length: CGFloat, limit: CGFloat) -> CGFloat {
                // トリミングで画像より大きくなった蛍光ペンは押し戻さず、画像から完全には出さない。
                if annotation.tool == .highlighter, length > limit { return min(max(minimum, 1 - length), limit - 1) - minimum }
                return max(0, min(max(0, limit - length), minimum)) - minimum
            }
            let x = offset(bounds.minX, length: bounds.width, limit: imageSize.width)
            let y = offset(bounds.minY, length: bounds.height, limit: imageSize.height)
            result = result.translated(by: CGPoint(x: x, y: y))
            if [.rectangle, .spotlight, .mosaic].contains(annotation.tool), bounds.width > imageSize.width || bounds.height > imageSize.height {
                result.start = clamped(result.start, to: imageSize)
                result.end = clamped(result.end, to: imageSize)
            }
        }
        // 外に点を持つ蛍光ペンは描画で画像の中へ切る。点を縁へ寄せると線の形が変わる。
        if annotation.tool == .highlighter, bounds.width <= imageSize.width, bounds.height <= imageSize.height {
            result.points = result.points.map { clamped($0, to: imageSize) }
        }
        if let target = result.leaderTarget { result.leaderTarget = clamped(target, to: imageSize) }
        return result
    }
    public static func inkBounds(of annotation: Annotation, bounds: CGRect, style: AnnotationStyle) -> CGRect {
        let style = style.forAnnotation(annotation)
        switch annotation.tool {
        case .rectangle: return bounds.insetBy(dx: -style.lineWidth / 2 - style.edge, dy: -style.lineWidth / 2 - style.edge)
        case .spotlight: return bounds.insetBy(dx: -style.lineWidth - style.edge * 2, dy: -style.lineWidth - style.edge * 2)
        case .text: return bounds.insetBy(dx: -style.edge, dy: -style.edge)
        case .number: return bounds.insetBy(dx: -style.edge - 3, dy: -style.edge - 3).offsetBy(dx: 0, dy: 1).union(bounds)
        case .line, .freehand: return bounds.insetBy(dx: -style.lineWidth * 0.75 - style.edge, dy: -style.lineWidth * 0.75 - style.edge)
        case .highlighter: return bounds.insetBy(dx: -style.highlighterTip.width / 2, dy: -style.highlighterTip.height / 2)
        case .arrow:
            let a = annotation.start, b = annotation.end
            let angle = atan2(b.y - a.y, b.x - a.x)
            let line = style.lineWidth * 1.5
            let length = max(line * 4, style.fontSize * 0.9)
            let back = CGPoint(x: b.x - cos(angle) * length, y: b.y - sin(angle) * length)
            let p = CGPoint(x: back.x - sin(angle) * length * 0.45, y: back.y + cos(angle) * length * 0.45)
            let q = CGPoint(x: back.x + sin(angle) * length * 0.45, y: back.y - cos(angle) * length * 0.45)
            let head = CGRect(x: min(b.x, p.x, q.x), y: min(b.y, p.y, q.y), width: max(b.x, p.x, q.x) - min(b.x, p.x, q.x), height: max(b.y, p.y, q.y) - min(b.y, p.y, q.y))
            return bounds.insetBy(dx: -line / 2 - style.edge, dy: -line / 2 - style.edge).union(head.insetBy(dx: -style.edge, dy: -style.edge))
        case .selection, .crop, .mosaic: return bounds
        }
    }
    /// 中心に向かう直線と角丸ラベルの交点。ラベルの中に指す点があれば描かない。
    public static func leaderSegment(for annotation: Annotation, radius: Double, bounds: CGRect? = nil) -> (target: CGPoint, labelEdge: CGPoint)? {
        guard [.text, .number].contains(annotation.tool), let target = annotation.leaderTarget else { return nil }
        let rect = bounds ?? annotation.rect
        guard !rect.isEmpty else { return nil }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        guard !path.contains(target) else { return nil }
        var low = 0.0, high = 1.0
        // 角丸も含めて求める。32回で元画像座標のサブピクセル以下になる。
        for _ in 0..<32 {
            let t = (low + high) / 2
            let p = CGPoint(x: target.x + (center.x - target.x) * t, y: target.y + (center.y - target.y) * t)
            if path.contains(p) { high = t } else { low = t }
        }
        return (target, CGPoint(x: target.x + (center.x - target.x) * high, y: target.y + (center.y - target.y) * high))
    }
    public static func distance(_ point: CGPoint, toSegmentFrom a: CGPoint, to b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        let t = length > 0 ? max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length)) : 0
        return hypot(point.x - a.x - t * dx, point.y - a.y - t * dy)
    }
}

public struct AnnotationHistory: Sendable {
    public private(set) var document: AnnotationDocument
    private var past: [AnnotationDocument] = []
    private var future: [AnnotationDocument] = []
    public init(_ document: AnnotationDocument = AnnotationDocument()) { self.document = document }
    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    public mutating func commit(_ next: AnnotationDocument) {
        guard next != document else { return }
        past.append(document); document = next; future.removeAll()
    }
    public mutating func undo() {
        guard let previous = past.popLast() else { return }
        future.append(document); document = previous
    }
    public mutating func redo() {
        guard let next = future.popLast() else { return }
        past.append(document); document = next
    }
}

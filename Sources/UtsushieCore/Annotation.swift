import Foundation
import CoreGraphics

public enum AnnotationTool: String, CaseIterable, Sendable {
    case selection, rectangle, spotlight, text, number, arrow, mosaic
    public var label: String {
        switch self {
        case .selection: "選択"
        case .rectangle: "枠"
        case .spotlight: "スポット"
        case .text: "文字"
        case .number: "番号"
        case .arrow: "矢印"
        case .mosaic: "モザイク"
        }
    }
    public var key: String {
        switch self {
        case .selection: "esc"
        case .rectangle: "r"
        case .spotlight: "s"
        case .text: "t"
        case .number: "n"
        case .arrow: "a"
        case .mosaic: "m"
        }
    }
    public var keyCode: UInt16 {
        switch self {
        case .selection: 53
        case .rectangle: 15
        case .spotlight: 1
        case .text: 17
        case .number: 45
        case .arrow: 0
        case .mosaic: 46
        }
    }
    public var layer: Int {
        switch self {
        case .selection: -1
        case .mosaic: 0
        case .spotlight: 1
        case .rectangle, .arrow: 2
        case .text: 3
        case .number: 4
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
    public init(id: UUID = UUID(), tool: AnnotationTool, start: CGPoint, end: CGPoint? = nil, text: String = "") {
        self.id = id; self.tool = tool; self.start = start; self.end = end ?? start; self.text = text
    }
    public var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
    public func translated(by delta: CGPoint) -> Annotation {
        var result = self
        result.start.x += delta.x; result.start.y += delta.y
        result.end.x += delta.x; result.end.y += delta.y
        return result
    }
}

public struct AnnotationStyle: Equatable, Sendable {
    public let fontSize: Double
    public let lineWidth: Double
    public let numberDiameter: Double
    public let blockSize: Int
    public let edge: Double
    public let radius: Double
    public let horizontalPadding: Double
    public let verticalPadding: Double
    public init(imageSize: CGSize) {
        let length = max(imageSize.width, imageSize.height)
        fontSize = max(16, length / 50)
        lineWidth = max(3, length / 400)
        numberDiameter = fontSize * 1.5
        blockSize = max(8, Int((length / 60).rounded()))
        let factor = lineWidth / 3
        edge = 2 * factor; radius = 6 * factor
        horizontalPadding = 11 * factor; verticalPadding = 6 * factor
    }
    public func numberRect(at point: CGPoint, number: Int) -> CGRect {
        let width = numberDiameter + Double(max(0, String(number).count - 1)) * fontSize * 0.6
        return CGRect(x: point.x - width / 2, y: point.y - numberDiameter / 2, width: width, height: numberDiameter)
    }
}

public struct AnnotationDocument: Equatable, Sendable {
    public var annotations: [Annotation]
    public init(annotations: [Annotation] = []) { self.annotations = annotations }
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
        annotation.tool == .number ? style.numberRect(at: annotation.start, number: number(for: annotation.id) ?? nextNumber) : annotation.rect
    }
    public func hit(at point: CGPoint, style: AnnotationStyle, tolerance: Double, includeAreaInterior: Bool = false) -> UUID? {
        ordered.reversed().first { annotation in
            if annotation.tool == .arrow {
                return AnnotationGeometry.distance(point, toSegmentFrom: annotation.start, to: annotation.end) <= max(tolerance, style.lineWidth * 0.75 + style.edge)
            }
            let rect = bounds(of: annotation, style: style)
            if [.rectangle, .spotlight, .mosaic].contains(annotation.tool) {
                let inset = max(tolerance, style.lineWidth / 2 + style.edge)
                return rect.insetBy(dx: -inset, dy: -inset).contains(point) && (includeAreaInterior || !rect.insetBy(dx: inset, dy: inset).contains(point))
            }
            return rect.contains(point)
        }?.id
    }
    public func interaction(at point: CGPoint, selected: UUID?, tool: AnnotationTool, style: AnnotationStyle, tolerance: Double) -> AnnotationInteraction {
        if let annotation = annotations.first(where: { $0.id == selected }),
           let handle = AnnotationGeometry.resizeHandle(at: point, annotation: annotation, tolerance: tolerance) {
            return .resize(annotation.id, handle)
        }
        if let id = hit(at: point, style: style, tolerance: tolerance, includeAreaInterior: tool == .selection) { return .move(id) }
        return tool == .selection ? .none : .create
    }
}

public enum AnnotationResizeHandle: Equatable, Sendable {
    case topLeft, topRight, bottomRight, bottomLeft, top, right, bottom, left, arrowStart, arrowEnd
}
public enum AnnotationInteraction: Equatable, Sendable {
    case none, create, move(UUID), resize(UUID, AnnotationResizeHandle)
    public func cursor(tool: AnnotationTool) -> AnnotationCursor {
        switch self {
        case .none: return .arrow
        case .create: return tool == .selection ? .arrow : .crosshair
        case .move: return .move
        case .resize(_, let handle):
            switch handle {
            case .topLeft, .bottomRight: return .diagonalDown
            case .topRight, .bottomLeft: return .diagonalUp
            case .top, .bottom: return .vertical
            case .left, .right: return .horizontal
            case .arrowStart, .arrowEnd: return .crosshair
            }
        }
    }
}
public enum AnnotationCursor: Equatable, Sendable {
    case arrow, crosshair, move, horizontal, vertical, diagonalDown, diagonalUp
}

public enum AnnotationGeometry {
    /// 判定は表示上のpt。縮小時も小さな誤ドラッグを注釈にしない。
    public static func isValidDrag(tool: AnnotationTool, from a: CGPoint, to b: CGPoint, displayScale: Double) -> Bool {
        if tool == .arrow { return hypot(b.x - a.x, b.y - a.y) * displayScale > 4 }
        return abs(b.x - a.x) * displayScale > 4 && abs(b.y - a.y) * displayScale > 4
    }
    public static func handles(for annotation: Annotation) -> [CGPoint] {
        switch annotation.tool {
        case .rectangle, .spotlight, .mosaic:
            let r = annotation.rect
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        case .arrow: return [annotation.start, annotation.end]
        case .selection, .text, .number: return []
        }
    }
    public static func resizeHandle(at point: CGPoint, annotation: Annotation, tolerance: Double) -> AnnotationResizeHandle? {
        let points = handles(for: annotation)
        if annotation.tool == .arrow {
            if hypot(point.x - annotation.start.x, point.y - annotation.start.y) <= tolerance { return .arrowStart }
            if hypot(point.x - annotation.end.x, point.y - annotation.end.y) <= tolerance { return .arrowEnd }
            return nil
        }
        guard [.rectangle, .spotlight, .mosaic].contains(annotation.tool) else { return nil }
        let corners: [AnnotationResizeHandle] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
        if let index = points.firstIndex(where: { hypot(point.x - $0.x, point.y - $0.y) <= tolerance }) { return corners[index] }
        let r = annotation.rect
        if point.x >= r.minX - tolerance, point.x <= r.maxX + tolerance {
            if abs(point.y - r.minY) <= tolerance { return .top }
            if abs(point.y - r.maxY) <= tolerance { return .bottom }
        }
        if point.y >= r.minY - tolerance, point.y <= r.maxY + tolerance {
            if abs(point.x - r.minX) <= tolerance { return .left }
            if abs(point.x - r.maxX) <= tolerance { return .right }
        }
        return nil
    }
    public static func resized(_ annotation: Annotation, handle: AnnotationResizeHandle, to point: CGPoint) -> Annotation {
        var result = annotation
        let r = annotation.rect
        switch handle {
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

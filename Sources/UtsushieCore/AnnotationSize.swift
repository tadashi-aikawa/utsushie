import Foundation

public enum AnnotationSize: Int, CaseIterable, Sendable {
    case smallest, small, normal, large, largest

    public var multiplier: Double {
        switch self {
        case .smallest: 0.6
        case .small: 0.8
        case .normal: 1
        case .large: 1.4
        case .largest: 2
        }
    }
    public var dotDiameter: Double { [6, 8, 10, 13, 16][rawValue] }
    public func stepped(_ direction: AnnotationSizeDirection) -> AnnotationSize {
        Self(rawValue: max(0, min(Self.allCases.count - 1, rawValue + direction.rawValue)))!
    }
}

public enum AnnotationSizeDirection: Int, Sendable {
    case smaller = -1, larger = 1

    /// 入力文字はIMEで「かぎ括弧」などに変わるため、刻印の物理キーを配列別に判定する。
    /// USは33/30、JISは30/42。配列はApp側でイベントのkeyboard typeから求める。
    public init?(keyCode: UInt16, isJIS: Bool, modified: Bool = false, editingText: Bool = false) {
        guard !modified, !editingText else { return nil }
        switch keyCode {
        case isJIS ? 30 : 33: self = .smaller
        case isJIS ? 42 : 30: self = .larger
        default: return nil
        }
    }
}

extension AnnotationDocument {
    public func steppedSize(_ ids: Set<UUID>, direction: AnnotationSizeDirection, defaultSize: AnnotationSize) -> AnnotationSize {
        let first = annotations.first { ids.contains($0.id) && $0.tool.usesSize }
        return (first?.size ?? defaultSize).stepped(direction)
    }

    /// 文字の実測はApp側から渡す。Coreだけでは既存の札を倍率比で拡縮する。
    public func settingSize(_ ids: Set<UUID>, size: AnnotationSize, imageSize: CGSize,
                            measureText: ((String, AnnotationStyle) -> CGSize)? = nil) -> AnnotationDocument {
        var result = self
        for index in result.annotations.indices where ids.contains(result.annotations[index].id) && result.annotations[index].tool.usesSize {
            var annotation = result.annotations[index]
            let previous = annotation.size
            annotation.size = size
            let style = AnnotationStyle(imageSize: imageSize, size: size)
            if annotation.tool == .text {
                let center = CGPoint(x: annotation.rect.midX, y: annotation.rect.midY)
                let ratio = size.multiplier / previous.multiplier
                let measured = measureText?(annotation.text, style)
                    ?? CGSize(width: annotation.rect.width * ratio, height: annotation.rect.height * ratio)
                annotation.start = CGPoint(x: center.x - measured.width / 2, y: center.y - measured.height / 2)
                annotation.end = CGPoint(x: annotation.start.x + measured.width, y: annotation.start.y + measured.height)
            }
            result.annotations[index] = AnnotationGeometry.placed(annotation, bounds: result.bounds(of: annotation, style: style), imageSize: imageSize)
        }
        return result
    }
}

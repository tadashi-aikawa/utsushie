import Foundation
import CoreGraphics

/// AXのヒット要素から親へ辿った列。座標は呼び出し側で統一する。
public struct CaptureElementNode: Sendable {
    public let rect: CGRect?
    public let label: String
    public let clipsChildren: Bool
    public let isCandidate: Bool
    public init(rect: CGRect?, label: String, clipsChildren: Bool = false, isCandidate: Bool = true) {
        self.rect = rect; self.label = label; self.clipsChildren = clipsChildren; self.isCandidate = isCandidate
    }
}

public struct CaptureElement: Equatable, Sendable {
    public let rect: CGRect
    public let label: String
    public init(rect: CGRect, label: String) { self.rect = rect; self.label = label }
}

public struct ElementSelection: Sendable {
    public private(set) var candidates: [CaptureElement] = []
    public private(set) var index = 0
    public var selected: CaptureElement? { candidates.isEmpty ? nil : candidates[index] }
    public var canSelectParent: Bool { index + 1 < candidates.count }
    public var canSelectChild: Bool { index > 0 }
    public init() {}

    /// leaf→rootの順。親自身は子のスクロール枠で切らず、子だけを祖先の枠へ収める。
    public init(nodes: [CaptureElementNode], point: CGPoint, visibleBounds: CGRect, occludingBounds: [CGRect] = []) {
        guard Self.isValid(visibleBounds), point.x.isFinite, point.y.isFinite else { return }
        var clip = visibleBounds
        var clipped: [CaptureElement] = []
        for node in nodes.reversed() {
            if node.clipsChildren {
                guard let rect = node.rect, Self.isValid(rect) else { return }
                clip = clip.intersection(rect)
            }
            guard node.isCandidate, let rect = node.rect, Self.isValid(rect) else { continue }
            let visible = rect.intersection(clip)
            guard Self.isValid(visible), visible.contains(point) else { continue }
            clipped.append(CaptureElement(rect: visible, label: node.label))
        }
        for candidate in clipped.reversed() {
            // region撮影には手前の窓も写る。隠れた親へ広げず、見えている候補だけを残す。
            if occludingBounds.contains(where: {
                let overlap = candidate.rect.intersection($0)
                return !overlap.isNull && overlap.width > 0 && overlap.height > 0
            }) { break }
            // ARIAで親が付け替えられた場合も、↑で現在の枠が縮んだり横へ飛んだりしない。
            if let previous = candidates.last,
               (!candidate.rect.contains(previous.rect) || Self.matches(candidate.rect, previous.rect)) { continue }
            candidates.append(candidate)
        }
    }

    public mutating func selectParent() { if canSelectParent { index += 1 } }
    public mutating func selectChild() { if canSelectChild { index -= 1 } }

    /// AXとWindowServerで生じる端数だけを許容する。ptのまま比較し、Retina倍率を掛けない。
    public static func matches(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        isValid(lhs) && isValid(rhs) &&
        abs(lhs.minX - rhs.minX) <= tolerance && abs(lhs.minY - rhs.minY) <= tolerance &&
        abs(lhs.maxX - rhs.maxX) <= tolerance && abs(lhs.maxY - rhs.maxY) <= tolerance
    }

    public static func isValid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite &&
        rect.width >= 1 && rect.height >= 1
    }
}

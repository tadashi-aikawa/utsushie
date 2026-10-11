import AppKit

/// 短い読み取りではカーソルを変えず、連続した取得待ちだけを示す。
@MainActor
final class ElementReadCursor {
    private var timer: Task<Void, Never>?
    private(set) var isVisible = false

    func begin(onChange: @escaping @MainActor () -> Void) {
        guard timer == nil, !isVisible else { return }
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.timer = nil
            self.isVisible = true
            onChange()
        }
    }

    func end() {
        timer?.cancel()
        timer = nil
        isVisible = false
    }

    static let cursor: NSCursor = {
        let arrow = NSCursor.arrow
        let arrowSize = arrow.image.size
        let size = NSSize(width: max(arrowSize.width, 16) + 12, height: max(arrowSize.height, 24))
        let image = NSImage(size: size, flipped: false) { _ in
            arrow.image.draw(in: NSRect(x: 0, y: size.height - arrowSize.height,
                                       width: arrowSize.width, height: arrowSize.height))
            let badge = NSRect(x: size.width - 13, y: 1, width: 12, height: 17)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
            let glass = NSBezierPath()
            glass.move(to: NSPoint(x: badge.minX + 3, y: badge.maxY - 3))
            glass.line(to: NSPoint(x: badge.maxX - 3, y: badge.maxY - 3))
            glass.line(to: NSPoint(x: badge.minX + 3, y: badge.minY + 3))
            glass.line(to: NSPoint(x: badge.maxX - 3, y: badge.minY + 3))
            glass.close()
            glass.lineWidth = 1.5
            NSColor.black.setStroke()
            glass.stroke()
            return true
        }
        // 元の矢印の位置とホットスポットを保ち、砂時計だけ右下へ足す。
        return NSCursor(image: image, hotSpot: arrow.hotSpot)
    }()
}

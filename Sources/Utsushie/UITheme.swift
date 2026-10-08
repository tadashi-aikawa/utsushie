import AppKit

@MainActor
enum UITheme {
    static let indigo = color(0x4270C0)
    static let paper = color(0xF3EBDA)
    static let ink = color(0x1C1C1E)
    static let red = color(0xE5352A)
    static let redFace = color(0xD23125)
    static let highlighter = color(0xF2D130).withAlphaComponent(0.55)
    static let muted = color(0xA1A1A6)
    static let text = color(0xE5E5EA)
    static let key = color(0x8E8E93)
    private static func color(_ hex: Int) -> NSColor {
        NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1)
    }
}

@MainActor
enum UIDrawing {
    static func curtain(_ bounds: CGRect, selection: CGRect?) {
        let curtain = NSBezierPath(rect: bounds)
        if let selection {
            let hole = selection.intersection(bounds)
            if !hole.isNull { curtain.appendRect(hole) }
        }
        curtain.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.42).setFill(); curtain.fill()
    }
    static func fill(_ rect: CGRect, color: NSColor, radius: CGFloat) {
        color.setFill(); NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
    static func text(_ string: String, in rect: CGRect, size: CGFloat = 12, color: NSColor = UITheme.text,
                     weight: NSFont.Weight = .medium, centered: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail; style.alignment = centered ? .center : .left
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color, .paragraphStyle: style]
        (string as NSString).draw(in: rect, withAttributes: attributes)
    }
    static func key(_ string: String, in rect: CGRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        NSColor.white.withAlphaComponent(0.38).setStroke(); path.lineWidth = 0.7; path.stroke()
        text(string, in: rect.insetBy(dx: 1, dy: 1), size: 10.5, centered: true)
    }
    /// 鉤の6ptの下地まで、範囲の外へ離す。影は使わない。
    static func selection(_ rect: CGRect, video: Bool) {
        let outer = rect.insetBy(dx: -4, dy: -4)
        let path = NSBezierPath()
        let length = min(20, min(outer.width, outer.height) / 2)
        for (x, y, sx, sy) in [(outer.minX, outer.minY, CGFloat(1), CGFloat(1)),
            (outer.maxX, outer.minY, -1, 1), (outer.minX, outer.maxY, 1, -1), (outer.maxX, outer.maxY, -1, -1)] {
            path.move(to: CGPoint(x: x, y: y + sy * length))
            path.line(to: CGPoint(x: x, y: y)); path.line(to: CGPoint(x: x + sx * length, y: y))
        }
        path.lineCapStyle = .square; path.lineJoinStyle = .miter
        (video ? NSColor.white : UITheme.paper).setStroke(); path.lineWidth = 6; path.stroke()
        (video ? UITheme.red : UITheme.indigo).setStroke(); path.lineWidth = 3.5; path.stroke()
        let edge = NSBezierPath(rect: rect.insetBy(dx: -0.75, dy: -0.75))
        NSColor.white.withAlphaComponent(0.9).setStroke(); edge.lineWidth = 1; edge.stroke()
    }
    static func recordingBorder(_ rect: CGRect) {
        let path = NSBezierPath(rect: rect.insetBy(dx: -3, dy: -3))
        NSColor.white.setStroke(); path.lineWidth = 4; path.stroke()
        UITheme.red.setStroke(); path.lineWidth = 2; path.stroke()
    }
}

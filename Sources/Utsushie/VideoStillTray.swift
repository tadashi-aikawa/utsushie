import AppKit
import UtsushieCore

@MainActor
final class VideoStillTray: NSView {
    private let scroll = NSScrollView()
    private let list = VideoStillList()
    private var marks: [VideoStillMark] = []
    private var rows: [UUID: VideoStillRow] = [:]
    var onSelect: ((UUID) -> Void)?
    var onRemove: ((UUID) -> Void)?
    override var isFlipped: Bool { true }
    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false; scroll.documentView = list
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(marks: [VideoStillMark], images: [UUID: NSImage], active: UUID?) {
        self.marks = marks
        let ids = Set(marks.map(\.id))
        for (id, row) in rows where !ids.contains(id) { row.removeFromSuperview(); rows[id] = nil }
        for (index, mark) in marks.enumerated() {
            let row: VideoStillRow
            if let existing = rows[mark.id] { row = existing }
            else {
                row = VideoStillRow(mark: mark)
                row.onSelect = { [weak self] in self?.onSelect?(mark.id) }
                row.onRemove = { [weak self] in self?.onRemove?(mark.id) }
                rows[mark.id] = row; list.addSubview(row)
            }
            row.number = index + 1; row.image = images[mark.id]; row.active = active == mark.id
            row.needsDisplay = true
        }
        needsLayout = true; needsDisplay = true
    }
    override func layout() {
        super.layout()
        scroll.frame = CGRect(x: 0, y: 54, width: bounds.width, height: max(0, bounds.height - 80))
        list.frame = CGRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(scroll.contentSize.height, CGFloat(marks.count) * 112))
        for (index, mark) in marks.enumerated() {
            rows[mark.id]?.frame = CGRect(x: 16, y: CGFloat(index) * 112 + 6, width: max(1, list.bounds.width - 32), height: 104)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.095, alpha: 1).setFill(); bounds.fill()
        NSColor.black.setFill(); CGRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        UIDrawing.text("静止画 \(marks.count)枚", in: CGRect(x: 16, y: 12, width: bounds.width - 24, height: 18), size: 13, weight: .semibold)
        UIDrawing.text("完了でWebPにしてコピー", in: CGRect(x: 16, y: 34, width: bounds.width - 24, height: 16), size: 11, color: UITheme.key)
        UIDrawing.text("⏎ 再生位置のコマを足す", in: CGRect(x: 16, y: bounds.height - 24, width: bounds.width - 24, height: 18), size: 11, color: UITheme.key)
    }
}

@MainActor private final class VideoStillList: NSView { override var isFlipped: Bool { true } }

@MainActor
private final class VideoStillRow: NSView {
    let mark: VideoStillMark
    var number = 1
    var image: NSImage?
    var active = false { didSet { removeButton.isHidden = !active } }
    var onSelect: (() -> Void)?
    var onRemove: (() -> Void)?
    private let removeButton = ToolbarButton(title: "×", face: .secondary)
    init(mark: VideoStillMark) {
        self.mark = mark; super.init(frame: .zero)
        removeButton.target = self; removeButton.action = #selector(remove)
        removeButton.toolTip = "静止画の印を外す"; removeButton.setAccessibilityLabel("静止画の印を外す")
        addSubview(removeButton)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func layout() { super.layout(); removeButton.frame = CGRect(x: bounds.width - 26, y: 4, width: 24, height: 24) }
    @objc private func remove() { onRemove?() }
    override func mouseDown(with event: NSEvent) { onSelect?() }
    override func draw(_ dirtyRect: NSRect) {
        let preview = CGRect(x: 0, y: 0, width: bounds.width, height: 81)
        UIDrawing.fill(preview, color: .black, radius: 5)
        if let image {
            let scale = min(preview.width / image.size.width, preview.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: preview.midX - size.width / 2, y: preview.midY - size.height / 2, width: size.width, height: size.height),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if active {
            let outline = NSBezierPath(roundedRect: preview.insetBy(dx: -1, dy: -1), xRadius: 6, yRadius: 6)
            UITheme.paper.setStroke(); outline.lineWidth = 2; outline.stroke()
        }
        UIDrawing.fill(CGRect(x: 5, y: 5, width: 20, height: 18), color: UITheme.paper, radius: 2)
        UIDrawing.text("\(number)", in: CGRect(x: 5, y: 6, width: 20, height: 16), size: 11, color: UITheme.ink, weight: .semibold, centered: true)
        UIDrawing.text(VideoEditFormatting.time(mark.time), in: CGRect(x: 0, y: 87, width: bounds.width, height: 16), size: 11, color: UITheme.muted)
    }
}

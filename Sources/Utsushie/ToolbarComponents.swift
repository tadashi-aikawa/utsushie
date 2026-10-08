import AppKit
import UtsushieCore

/// 編集画面と撮影の帯が共有する、台・刻印・操作の面。
@MainActor
enum ToolbarDrawing {
    enum Face { case tool, outline, secondary, primary, plain, zoom }
    static func width(_ text: String, size: CGFloat = 12.5) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium)]).width)
    }
    static func keyWidth(_ key: String) -> CGFloat { max(17, width(key, size: 10.5) + 8) }
    static func contentWidth(title: String, key: String?, symbol: Bool = false, recording: Bool = false) -> CGFloat {
        width(title) + (symbol ? 19 : 0) + (recording ? 14 : 0)
            + (key.map { ($0 == "ドラッグ" ? width($0, size: 10.5) : keyWidth($0)) + 5 } ?? 0)
    }
    static func itemWidth(title: String, key: String?, symbol: Bool = false, recording: Bool = false, face: Face = .tool) -> CGFloat {
        let padding: CGFloat = face == .secondary || face == .primary ? 19 : 11
        return contentWidth(title: title, key: key, symbol: symbol, recording: recording) + padding
    }
    static func tray(_ rect: CGRect) {
        UIDrawing.fill(rect, color: NSColor.white.withAlphaComponent(0.055), radius: 9)
    }
    static func face(_ rect: CGRect, style: Face, selected: Bool = false, recording: Bool = false,
                     armed: Bool = false, dimmed: Bool = false, highlighted: Bool = false) {
        let fill: NSColor?
        switch style {
        case .primary: fill = UITheme.indigo
        case .secondary: fill = .white.withAlphaComponent(armed ? 0.2 : 0.1)
        case .zoom: fill = .white.withAlphaComponent(0.08)
        default: fill = selected ? (recording ? UITheme.redFace : .white.withAlphaComponent(0.17)) : nil
        }
        if let fill { UIDrawing.fill(rect, color: fill, radius: 7) }
        if highlighted { UIDrawing.fill(rect, color: .white.withAlphaComponent(0.08), radius: 7) }
        if style == .outline || armed {
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
            NSColor.white.withAlphaComponent(armed ? 0.7 : dimmed ? 0.14 : 0.26).setStroke()
            path.lineWidth = armed || !dimmed ? 1 : 0.7; path.stroke()
        }
    }
    static func key(_ string: String, in rect: CGRect, color: NSColor = UITheme.text, strong: Bool = false, dimmed: Bool = false) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.35, dy: 0.35), xRadius: 4, yRadius: 4)
        NSColor.white.withAlphaComponent(dimmed ? 0.16 : strong ? 0.55 : 0.38).setStroke()
        path.lineWidth = 0.7; path.stroke()
        text(string, in: rect.insetBy(dx: 4, dy: 0), size: 10.5, color: color, centered: true)
    }
    static func text(_ string: String, in rect: CGRect, size: CGFloat = 12.5, color: NSColor = UITheme.text, centered: Bool = false) {
        let height = (string as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium)]).height
        UIDrawing.text(string, in: CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height), size: size, color: color, centered: centered)
    }
    static func item(title: String, key: String?, symbol: NSImage? = nil, in rect: CGRect,
                     style: Face = .tool, selected: Bool = false, recording: Bool = false,
                     armed: Bool = false, dimmed: Bool = false, highlighted: Bool = false, centered: Bool = false) {
        face(rect, style: style, selected: selected, recording: recording, armed: armed, dimmed: dimmed, highlighted: highlighted)
        let color: NSColor = dimmed ? UITheme.key : selected || armed || style == .primary ? .white : UITheme.text
        var x = centered ? rect.midX - contentWidth(title: title, key: key, symbol: symbol != nil, recording: recording) / 2
            : rect.minX + (style == .secondary || style == .primary ? 11 : 6)
        if recording {
            UITheme.red.setFill()
            NSBezierPath(ovalIn: CGRect(x: x, y: rect.midY - 4, width: 8, height: 8)).fill()
            x += 14
        }
        if let symbol {
            let tinted = symbol.withSymbolConfiguration(.init(paletteColors: [color])) ?? symbol
            tinted.draw(in: CGRect(x: x, y: rect.midY - 7, width: 14, height: 14), from: .zero,
                        operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += 19
        }
        text(title, in: CGRect(x: x, y: rect.minY, width: width(title), height: rect.height), color: color)
        x += width(title) + 5
        if let key {
            if key == "ドラッグ" {
                text(key, in: CGRect(x: x, y: rect.minY, width: width(key, size: 10.5), height: rect.height), size: 10.5, color: UITheme.key)
            } else {
                self.key(key, in: CGRect(x: x, y: rect.midY - 8.5, width: keyWidth(key), height: 17),
                         color: color, strong: selected || armed || style == .primary, dimmed: dimmed)
            }
        }
    }
}

@MainActor
final class ToolbarButton: NSButton {
    var key: String? { didSet { needsDisplay = true } }
    var face: ToolbarDrawing.Face = .tool
    var dimmed = false
    var armed = false {
        didSet {
            if let confirmationTitle {
                title = armed ? confirmationTitle : restingTitle
                setAccessibilityLabel(title)
            }
            needsDisplay = true
        }
    }
    private let restingTitle: String
    private let confirmationTitle: String?
    var fixedWidth: CGFloat?
    var naturalWidth: CGFloat { fixedWidth ?? ToolbarDrawing.itemWidth(title: title, key: key, symbol: image != nil, face: face) }
    override var isFlipped: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if face == .zoom {
            ToolbarDrawing.face(bounds, style: .zoom, highlighted: isHighlighted)
            let color = isEnabled ? UITheme.text : UITheme.key
            ToolbarDrawing.text(title, in: CGRect(x: 8, y: 0, width: bounds.width - 25, height: bounds.height), size: 11.5, color: color)
            let symbol = image?.withSymbolConfiguration(.init(paletteColors: [color])) ?? image
            symbol?.draw(in: CGRect(x: bounds.maxX - 16, y: bounds.midY - 4.5, width: 9, height: 9), from: .zero,
                         operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        ToolbarDrawing.item(title: title, key: key, symbol: image, in: bounds, style: face,
                            selected: state == .on, armed: armed, dimmed: dimmed || !isEnabled, highlighted: isHighlighted, centered: fixedWidth != nil)
        if window?.firstResponder === self {
            NSGraphicsContext.saveGraphicsState()
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
            NSColor.white.withAlphaComponent(0.7).setStroke(); focus.lineWidth = 1; focus.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    init(title: String = "", key: String? = nil, face: ToolbarDrawing.Face = .tool, confirmationTitle: String? = nil) {
        restingTitle = title; self.confirmationTitle = confirmationTitle
        super.init(frame: .zero)
        self.title = title; self.key = key; self.face = face
        isBordered = false; setButtonType(.momentaryPushIn)
        setAccessibilityLabel(title)
        setAccessibilityHelp(key.map { "キー \($0)" })
        if let confirmationTitle {
            fixedWidth = max(ToolbarDrawing.itemWidth(title: title, key: key, face: face),
                             ToolbarDrawing.itemWidth(title: confirmationTitle, key: key, face: face))
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
final class ToolbarTray: NSView {
    let buttons: [ToolbarButton]
    var naturalWidth: CGFloat { buttons.reduce(4) { $0 + $1.naturalWidth } + CGFloat(max(0, buttons.count - 1)) * 2 }
    override var isFlipped: Bool { true }
    init(_ buttons: [ToolbarButton]) {
        self.buttons = buttons; super.init(frame: .zero)
        buttons.forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) { ToolbarDrawing.tray(bounds) }
    override func layout() {
        super.layout()
        var x: CGFloat = 2
        for button in buttons {
            button.frame = CGRect(x: x, y: 2, width: button.naturalWidth, height: 28)
            x += button.naturalWidth + 2
        }
    }
}

/// 手引きと一時的な状態を同じ位置に描く。失敗の印だけ朱にする。
@MainActor
final class ToolbarHintView: NSView {
    var hint = ToolbarHint() { didSet { setAccessibilityLabel(hint.text); needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        var x: CGFloat = 0
        if hint.isError {
            let badge = CGRect(x: 0, y: bounds.midY - 8, width: 16, height: 16)
            UIDrawing.fill(badge, color: UITheme.redFace, radius: 8)
            UIDrawing.text("!", in: badge, size: 11, color: .white, weight: .bold, centered: true)
            x = 22
        }
        var remainder = hint.text[...]
        while !remainder.isEmpty {
            let match = hint.keys.compactMap { key -> (String, Range<String.Index>)? in
                remainder.range(of: key).map { (key, $0) }
            }.min { lhs, rhs in lhs.1.lowerBound == rhs.1.lowerBound ? lhs.0.count > rhs.0.count : lhs.1.lowerBound < rhs.1.lowerBound }
            let plain = String(match.map { remainder[..<$0.1.lowerBound] } ?? remainder)
            let width = ToolbarDrawing.width(plain, size: 12)
            ToolbarDrawing.text(plain, in: CGRect(x: x, y: 0, width: min(width, max(0, bounds.width - x)), height: bounds.height), size: 12, color: UITheme.muted)
            x += width
            guard let (key, range) = match, x < bounds.width else { break }
            let keyWidth = ToolbarDrawing.keyWidth(key)
            ToolbarDrawing.key(key, in: CGRect(x: x, y: bounds.midY - 8.5, width: keyWidth, height: 17))
            x += keyWidth + 3; remainder = remainder[range.upperBound...]
        }
    }
}

@MainActor
final class HighlighterColorButton: NSButton {
    let color: HighlighterColor
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(color: HighlighterColor) {
        self.color = color
        super.init(frame: .zero)
        title = ""; isBordered = false; setButtonType(.momentaryPushIn)
        toolTip = "\(color.label) \(color.key)"
        setAccessibilityLabel("蛍光ペン \(color.label)")
        setAccessibilityHelp("キー \(color.key)")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        let rect = CGRect(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16)
        UITheme.highlighter(color).withAlphaComponent(isEnabled ? 1 : 0.35).setFill()
        NSBezierPath(ovalIn: rect).fill()
        if state == .on || isHighlighted {
            let border = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            NSColor.white.setStroke(); border.lineWidth = 2; border.stroke()
        }
    }
}

@MainActor
final class HighlighterControlsView: NSView {
    let colorButtons: [HighlighterColor: HighlighterColorButton]
    let darkButton = ToolbarButton(title: "暗い地", key: "D", face: .outline)
    var naturalWidth: CGFloat { 4 * 26 + 8 + darkButton.naturalWidth }
    override var isFlipped: Bool { true }
    init() {
        colorButtons = Dictionary(uniqueKeysWithValues: HighlighterColor.allCases.map { ($0, HighlighterColorButton(color: $0)) })
        super.init(frame: .zero)
        isHidden = true
        darkButton.allowsMixedState = true
        HighlighterColor.allCases.forEach { addSubview(colorButtons[$0]!) }
        addSubview(darkButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(color: HighlighterColor?, darkBackground: Bool?, enabled: Bool) {
        for (choice, button) in colorButtons {
            button.state = choice == color ? .on : .off
            button.isEnabled = enabled; button.needsDisplay = true
        }
        darkButton.state = darkBackground.map { $0 ? .on : .off } ?? .mixed
        darkButton.isEnabled = enabled; darkButton.needsDisplay = true
    }
    override func layout() {
        super.layout()
        for (index, color) in HighlighterColor.allCases.enumerated() {
            colorButtons[color]?.frame = CGRect(x: CGFloat(index) * 26, y: 0, width: 24, height: 25)
        }
        darkButton.frame = CGRect(x: 4 * 26 + 8, y: 0, width: darkButton.naturalWidth, height: 25)
    }
}

@MainActor
final class AnnotationToolbarView: NSView {
    let toolButtons: [AnnotationTool: ToolbarButton]
    let aiButton: ToolbarButton
    let undoButton = ToolbarButton(title: "↶", face: .plain)
    let redoButton = ToolbarButton(title: "↷", face: .plain)
    let finishButton = ToolbarButton(title: "完了", key: "↩", face: .primary)
    let zoomButton = ToolbarButton(title: "100%", face: .zoom)
    let hintView = ToolbarHintView()
    let highlighterControls = HighlighterControlsView()
    let dimensions = NSTextField(labelWithString: "")
    let trays: [ToolbarTray]
    var minimumWidth: CGFloat {
        max(AnnotationToolbarPresentation.minimumWidth, trays.reduce(28) { $0 + $1.naturalWidth + 10 }
            + finishButton.naturalWidth + 80)
    }
    override var isFlipped: Bool { true }
    init() {
        let ai = ToolbarButton(title: "AIで隠す", key: "H", face: .outline)
        aiButton = ai
        var buttons: [AnnotationTool: ToolbarButton] = [:]
        for tool in AnnotationTool.allCases {
            let button = ToolbarButton(title: tool.label, key: tool.key.uppercased())
            let symbol: String
            switch tool {
            case .selection: symbol = "cursorarrow"
            case .rectangle: symbol = "rectangle"
            case .spotlight: symbol = "light.max"
            case .arrow: symbol = "arrow.up.right"
            case .line: symbol = "line.diagonal"
            case .highlighter: symbol = "highlighter"
            case .text: symbol = "textformat"
            case .number: symbol = "1.circle"
            case .mosaic: symbol = "square.grid.3x3.fill"
            }
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tool.label)
            buttons[tool] = button
        }
        toolButtons = buttons
        trays = [[AnnotationTool.selection], [.rectangle, .spotlight, .arrow, .line, .highlighter], [.text, .number], [.mosaic]].enumerated().map { index, tools in
            ToolbarTray(tools.compactMap { buttons[$0] } + (index == 3 ? [ai] : []))
        }
        super.init(frame: .zero)
        aiButton.fixedWidth = max(ToolbarDrawing.itemWidth(title: "AIで隠す", key: "H", face: .outline),
                                  ToolbarDrawing.itemWidth(title: "探しています", key: "Esc", face: .outline))
        undoButton.fixedWidth = 28; redoButton.fixedWidth = 28
        zoomButton.fixedWidth = 76
        zoomButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "倍率メニュー")
        dimensions.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        dimensions.textColor = UITheme.key
        trays.forEach { addSubview($0) }
        [undoButton, redoButton, finishButton, zoomButton, hintView, highlighterControls, dimensions].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        UITheme.ink.setFill(); bounds.fill()
        NSColor.black.setFill(); CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        NSColor.white.withAlphaComponent(0.12).setFill()
        CGRect(x: finishButton.frame.minX - 9, y: 15, width: 1, height: 20).fill()
    }
    override func layout() {
        super.layout()
        var x: CGFloat = 14
        for tray in trays {
            tray.frame = CGRect(x: x, y: 9, width: tray.naturalWidth, height: 32)
            tray.needsLayout = true
            x += tray.naturalWidth + 10
        }
        var right = bounds.width - 14
        for button in [finishButton, redoButton, undoButton] {
            button.frame = CGRect(x: right - button.naturalWidth, y: 11, width: button.naturalWidth, height: 28)
            right = button.frame.minX - (button === finishButton ? 18 : button === redoButton ? 2 : 6)
        }
        zoomButton.frame = CGRect(x: bounds.width - 90, y: 47, width: 76, height: 22)
        let dimensionWidth = ceil(dimensions.intrinsicContentSize.width)
        dimensions.frame = CGRect(x: zoomButton.frame.minX - dimensionWidth - 10, y: 50, width: dimensionWidth, height: 18)
        hintView.frame = CGRect(x: 16, y: 46, width: max(0, dimensions.frame.minX - 28), height: 25)
        highlighterControls.frame = CGRect(x: 16, y: 46, width: highlighterControls.naturalWidth, height: 25)
        highlighterControls.needsLayout = true
    }
}

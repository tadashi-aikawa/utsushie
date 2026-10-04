import AppKit
import UtsushieCore

@MainActor
final class AnnotationEditorController: NSObject, NSWindowDelegate {
    // アプリ起動中だけ共有する。設定ファイルへ書き戻さない。
    private static var lastTool: AnnotationTool = .rectangle
    let window: AnnotationPanel
    let canvas: AnnotationCanvas
    private let hint = NSTextField(labelWithString: "")
    private let undoButton = AnnotationButton()
    private let redoButton = AnnotationButton()
    private var toolButtons: [AnnotationTool: NSButton] = [:]
    private var finishButton: NSButton!
    private var discardButton: NSButton!
    private var discardArmed = false
    private var saving = false
    private var closing = false
    private let initial: AnnotationDocument
    var onComplete: ((CGImage, AnnotationDocument) async throws -> Void)?
    var onClose: (() -> Void)?

    init(image: CGImage, document: AnnotationDocument, screen: NSScreen?) {
        initial = document
        canvas = AnnotationCanvas(image: image, document: document, tool: Self.lastTool)
        let visible = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: min(max(CGFloat(image.width) + 80, 1180), visible.width - 40),
                          height: min(max(CGFloat(image.height) + 132, 420), visible.height - 80))
        window = AnnotationPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.title = "UTSUSHIE — 注釈"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.becomesKeyOnlyIfNeeded = false
        window.hidesOnDeactivate = false
        window.level = .floating
        window.acceptsMouseMovedEvents = true
        window.minSize = CGSize(width: min(1000, size.width), height: 300)
        window.delegate = self
        window.editor = self
        let root = AnnotationEditorLayout(frame: CGRect(origin: .zero, size: size))
        root.wantsLayer = true; root.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        let bar = NSStackView()
        bar.orientation = .horizontal; bar.alignment = .centerY; bar.spacing = 4
        for tool in AnnotationTool.allCases {
            let button = AnnotationButton(title: "\(tool.label)  \(tool == .selection ? tool.key : tool.key.uppercased())", target: self, action: #selector(selectTool(_:)))
            button.image = NSImage(systemSymbolName: Self.symbol(tool), accessibilityDescription: tool.label)
            button.imagePosition = .imageLeading
            button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 12)
            button.setButtonType(.pushOnPushOff)
            toolButtons[tool] = button; bar.addArrangedSubview(button)
        }
        configure(undoButton, title: "↶", action: #selector(undoAnnotation))
        configure(redoButton, title: "↷", action: #selector(redoAnnotation))
        undoButton.toolTip = "取り消し ⌘Z"; redoButton.toolTip = "やり直し ⇧⌘Z"
        bar.addArrangedSubview(undoButton); bar.addArrangedSubview(redoButton)
        hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor
        hint.alignment = .center; hint.lineBreakMode = .byTruncatingTail
        hint.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.addArrangedSubview(hint)
        discardButton = AnnotationButton(title: "破棄 Q", target: self, action: #selector(discard))
        finishButton = AnnotationButton(title: "完了 ⌘↩", target: self, action: #selector(finish))
        discardButton.bezelStyle = .rounded; finishButton.bezelStyle = .rounded
        finishButton.bezelColor = AnnotationRenderer.red
        bar.addArrangedSubview(discardButton); bar.addArrangedSubview(finishButton)
        root.bar = bar; root.canvas = canvas
        root.addSubview(bar); root.addSubview(canvas)
        window.contentView = root
        window.setFrameOrigin(CGPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
        canvas.onChange = { [weak self] in self?.discardArmed = false; self?.update() }
        canvas.onToolChange = { tool in Self.lastTool = tool }
        canvas.onDiscard = { [weak self] in self?.discard() }
        update()
    }
    private static func symbol(_ tool: AnnotationTool) -> String {
        switch tool {
        case .selection: "cursorarrow"
        case .rectangle: "rectangle"
        case .spotlight: "light.max"
        case .text: "textformat"
        case .number: "1.circle"
        case .arrow: "arrow.up.right"
        case .mosaic: "square.grid.3x3.fill"
        }
    }
    private func configure(_ button: NSButton, title: String, action: Selector) {
        button.title = title; button.target = self; button.action = action; button.bezelStyle = .rounded
    }
    func show() {
        // 非アクティブカードからでも、アプリのアクティベーションを頼まず入力を受ける。
        window.orderFrontRegardless(); window.makeKey(); window.makeFirstResponder(canvas)
    }
    private func update() {
        for (tool, button) in toolButtons { button.state = tool == canvas.tool ? .on : .off }
        undoButton.isEnabled = canvas.history.canUndo && !saving
        redoButton.isEnabled = canvas.history.canRedo && !saving
        if discardArmed { hint.stringValue = "もう一度押すと破棄"; return }
        if canvas.isEditingText { hint.stringValue = "Enterで確定 ・ ⇧Enterで改行"; return }
        let instruction: String
        switch canvas.tool {
        case .selection: instruction = "注釈をクリックで選択"
        case .number: instruction = "クリックで \(canvas.document.nextNumber) を置く"
        case .text: instruction = "クリックして文字を入力"
        case .arrow: instruction = "始点から終点へドラッグ"
        default: instruction = "ドラッグで\(canvas.tool.label)を置く"
        }
        hint.stringValue = instruction + " ・ 注釈はドラッグで移動"
    }
    @objc private func selectTool(_ sender: NSButton) {
        guard !saving, let tool = toolButtons.first(where: { $0.value === sender })?.key else { return }
        canvas.commitText(); canvas.tool = tool; Self.lastTool = tool
        discardArmed = false; update(); window.makeFirstResponder(canvas)
    }
    @objc private func undoAnnotation() { guard !saving else { return }; canvas.commitText(); canvas.undoAnnotation() }
    @objc private func redoAnnotation() { guard !saving else { return }; canvas.commitText(); canvas.redoAnnotation() }
    func handleEquivalent(_ event: NSEvent) -> Bool {
        guard window.attachedSheet == nil else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags == .command, event.keyCode == 13 { discard(); return true } // W
        if flags == .command, event.keyCode == 36 || event.keyCode == 76 { finish(); return true }
        if canvas.isEditingText { return false }
        if flags == .command, event.keyCode == 8 { finish(); return true }
        if flags == .command, event.keyCode == 6 { undoAnnotation(); return true }
        if flags == [.command, .shift], event.keyCode == 6 { redoAnnotation(); return true }
        return false
    }
    @objc private func discard() {
        guard !saving, window.attachedSheet == nil else { return }
        if canvas.hasChanges(comparedTo: initial), !discardArmed {
            discardArmed = true; update()
        } else { close() }
    }
    @objc private func finish() {
        guard !saving, window.attachedSheet == nil else { return }
        canvas.commitText()
        let document = canvas.document
        saving = true; canvas.isEnabled = false
        finishButton.isEnabled = false; discardButton.isEnabled = false
        toolButtons.values.forEach { $0.isEnabled = false }; update()
        hint.stringValue = "保存中…"
        Task { [self] in
            do {
                let image = try AnnotationRenderer.compose(canvas.original, document: document)
                try await onComplete?(image, document)
                close()
            } catch {
                saving = false; canvas.isEnabled = true
                finishButton.isEnabled = true; discardButton.isEnabled = true
                toolButtons.values.forEach { $0.isEnabled = true }; update()
                let alert = NSAlert(); alert.messageText = "注釈を保存できませんでした"; alert.informativeText = error.localizedDescription
                await alert.beginSheetModal(for: window)
            }
        }
    }
    private func close() { closing = true; window.close() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closing { return true }
        discard(); return false
    }
    func windowWillClose(_ notification: Notification) {
        onClose?(); onClose = nil; onComplete = nil
    }
}

@MainActor
final class AnnotationPanel: NSPanel {
    weak var editor: AnnotationEditorController?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if editor?.handleEquivalent(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
private final class AnnotationButton: NSButton {
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class AnnotationEditorLayout: NSView {
    var bar: NSStackView!
    var canvas: AnnotationCanvas!
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        bar.frame = CGRect(x: 14, y: 0, width: max(0, bounds.width - 28), height: 52)
        canvas.frame = CGRect(x: 0, y: 52, width: bounds.width, height: max(0, bounds.height - 52))
    }
}

@MainActor
final class AnnotationCanvas: NSView, NSTextViewDelegate {
    let original: CGImage
    private(set) var history: AnnotationHistory
    var tool: AnnotationTool { didSet { updateCursor(); needsDisplay = true } }
    var onChange: (() -> Void)?
    var onDiscard: (() -> Void)?
    var isEnabled = true
    private(set) var selection: UUID?
    private var gesture: Gesture?
    private var preview: AnnotationDocument?
    private var composed: CGImage?
    private var renderedDocument: AnnotationDocument?
    private var cursorPoint: CGPoint?
    private var textInput: AnnotationTextView?
    private var textAnnotation: Annotation?
    private enum Gesture {
        case create(Annotation)
        case move(Annotation, CGPoint)
        case resize(Annotation, AnnotationResizeHandle)
    }
    var document: AnnotationDocument { preview ?? history.document }
    var isEditingText: Bool { textInput != nil }
    private var style: AnnotationStyle { AnnotationStyle(imageSize: CGSize(width: original.width, height: original.height)) }
    var imageRect: CGRect {
        let factor = min(1, max(1, bounds.width - 80) / CGFloat(original.width), max(1, bounds.height - 80) / CGFloat(original.height))
        let size = CGSize(width: CGFloat(original.width) * factor, height: CGFloat(original.height) * factor)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    var displayScale: Double { imageRect.width / CGFloat(original.width) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(image: CGImage, document: AnnotationDocument, tool: AnnotationTool) {
        original = image; history = AnnotationHistory(document); self.tool = tool
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); layoutText(); needsDisplay = true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    private func point(_ event: NSEvent, clamped: Bool = true) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil), r = imageRect
        let x = (p.x - r.minX) / displayScale, y = (p.y - r.minY) / displayScale
        return clamped ? CGPoint(x: max(0, min(CGFloat(original.width), x)), y: max(0, min(CGFloat(original.height), y))) : CGPoint(x: x, y: y)
    }
    private func viewPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: imageRect.minX + p.x * displayScale, y: imageRect.minY + p.y * displayScale)
    }
    private func viewRect(_ r: CGRect) -> CGRect {
        CGRect(origin: viewPoint(r.origin), size: CGSize(width: r.width * displayScale, height: r.height * displayScale))
    }
    private func changed() { updateCursor(); needsDisplay = true; onChange?() }
    func undoAnnotation() { history.undo(); preview = nil; selection = nil; changed() }
    func redoAnnotation() { history.redo(); preview = nil; selection = nil; changed() }
    func hasChanges(comparedTo initial: AnnotationDocument) -> Bool {
        if history.document != initial { return true }
        guard let textInput, let textAnnotation else { return false }
        return textInput.string != textAnnotation.text
    }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        cursorPoint = imageRect.contains(p) ? point(event) : nil
        updateCursor(); needsDisplay = true
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func cursorUpdate(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { cursorPoint = nil; if window?.isKeyWindow == true { NSCursor.arrow.set() }; needsDisplay = true }
    private func updateCursor() {
        guard window?.isKeyWindow == true, window?.attachedSheet == nil, !isEditingText else { return }
        guard let cursorPoint else { return }
        let interaction: AnnotationInteraction
        switch gesture {
        case .create: interaction = .create
        case .move(let annotation, _): interaction = .move(annotation.id)
        case .resize(let annotation, let handle): interaction = .resize(annotation.id, handle)
        case nil: interaction = document.interaction(at: cursorPoint, selected: selection, tool: tool, style: style, tolerance: 7 / displayScale)
        }
        let cursor: NSCursor
        switch interaction.cursor(tool: tool) {
        case .arrow: cursor = .arrow
        case .crosshair: cursor = .crosshair
        case .move:
            if case .move = gesture { cursor = .closedHand } else { cursor = .openHand }
        case .horizontal: cursor = .frameResize(position: .left, directions: .all)
        case .vertical: cursor = .frameResize(position: .top, directions: .all)
        case .diagonalDown: cursor = .frameResize(position: .topLeft, directions: .all)
        case .diagonalUp: cursor = .frameResize(position: .topRight, directions: .all)
        }
        cursor.set()
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        commitText(); window?.makeFirstResponder(self)
        guard imageRect.contains(convert(event.locationInWindow, from: nil)) else { selection = nil; changed(); return }
        let p = point(event)
        cursorPoint = p
        let interaction = document.interaction(at: p, selected: selection, tool: tool, style: style, tolerance: 7 / displayScale)
        switch interaction {
        case .resize(let id, let handle):
            guard let annotation = document.annotations.first(where: { $0.id == id }) else { return }
            gesture = .resize(annotation, handle); changed(); return
        case .move(let id):
            guard let annotation = document.annotations.first(where: { $0.id == id }) else { return }
            selection = id
            if event.clickCount == 2, annotation.tool == .text { beginText(annotation); return }
            gesture = .move(annotation, p); changed(); return
        case .none: selection = nil; changed(); return
        case .create: break
        }
        selection = nil
        let annotation = Annotation(tool: tool, start: p)
        if tool == .number {
            var next = document; next.replace(annotation); history.commit(next); selection = annotation.id; changed()
        } else if tool == .text { beginText(annotation) }
        else { gesture = .create(annotation) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, let gesture else { return }
        let p = point(event)
        cursorPoint = p
        var annotation: Annotation
        switch gesture {
        case .create(let initial): annotation = initial; annotation.end = p
        case .move(let initial, let anchor):
            let r = history.document.bounds(of: initial, style: style)
            let delta = CGPoint(x: max(-r.minX, min(CGFloat(original.width) - r.maxX, p.x - anchor.x)),
                                y: max(-r.minY, min(CGFloat(original.height) - r.maxY, p.y - anchor.y)))
            annotation = initial.translated(by: delta)
        case .resize(let initial, let handle): annotation = AnnotationGeometry.resized(initial, handle: handle, to: p)
        }
        var next = history.document; next.replace(annotation); preview = next
        selection = annotation.id; changed()
    }
    override func mouseUp(with event: NSEvent) {
        guard let gesture else { return }
        defer { self.gesture = nil; preview = nil; changed() }
        guard let next = preview else { return }
        let annotation: Annotation?
        switch gesture {
        case .create(let initial), .resize(let initial, _): annotation = next.annotations.first { $0.id == initial.id }
        case .move: annotation = nil
        }
        if let annotation, !AnnotationGeometry.isValidDrag(tool: annotation.tool, from: annotation.start, to: annotation.end, displayScale: displayScale) {
            if case .create = gesture { selection = nil }
            return
        }
        history.commit(next)
    }
    override func keyDown(with event: NSEvent) {
        guard isEnabled, !isEditingText, window?.attachedSheet == nil else { return }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags.isEmpty, event.keyCode == 12 {
            if !event.isARepeat { onDiscard?() }
            return
        }
        if flags.isEmpty, event.keyCode == 53 { escape(); return }
        if flags.isEmpty, let next = AnnotationTool.allCases.first(where: { $0.keyCode == event.keyCode }) {
            tool = next; rememberTool(); changed(); return
        }
        interpretKeyEvents([event])
    }
    private func rememberTool() {
        // ボタンとキーの持ち替えを同じ経路へ通す。
        onToolChange?(tool)
    }
    var onToolChange: ((AnnotationTool) -> Void)?
    override func cancelOperation(_ sender: Any?) { escape() }
    func escape() {
        guard isEnabled else { return }
        if isEditingText { commitText(); return }
        gesture = nil; preview = nil
        if tool != .selection { tool = .selection; rememberTool(); changed() }
        else if selection != nil { selection = nil; changed() }
    }
    override func deleteBackward(_ sender: Any?) { deleteSelected() }
    override func deleteForward(_ sender: Any?) { deleteSelected() }
    private func deleteSelected() {
        guard let selection else { return }
        var next = history.document; next.remove(selection); history.commit(next); self.selection = nil; changed()
    }
    private func beginText(_ annotation: Annotation) {
        textAnnotation = annotation; selection = annotation.id
        let input = AnnotationTextView(frame: .zero)
        input.isRichText = false; input.allowsUndo = true; input.drawsBackground = true
        input.backgroundColor = AnnotationRenderer.red; input.textColor = .white
        input.textContainerInset = CGSize(width: style.horizontalPadding * displayScale, height: style.verticalPadding * displayScale)
        input.textContainer?.lineFragmentPadding = 0
        input.isHorizontallyResizable = false; input.isVerticallyResizable = false
        input.autoresizingMask = []
        input.string = annotation.text
        input.delegate = self
        input.onCommit = { [weak self] in self?.commitText() }
        input.onEscape = { [weak self] in self?.escape() }
        textInput = input; addSubview(input); layoutText()
        window?.makeFirstResponder(input); input.setSelectedRange(NSRange(location: input.string.utf16.count, length: 0))
        changed()
    }
    private func layoutText() {
        guard let input = textInput, let annotation = textAnnotation else { return }
        let font = NSFont.systemFont(ofSize: style.fontSize * displayScale, weight: .bold)
        if input.font != font { input.font = font }
        let size = AnnotationRenderer.textSize(input.string.isEmpty ? "入力" : input.string, style: style)
        let rect = CGRect(origin: annotation.start, size: CGSize(width: max(100 / displayScale, size.width + 4), height: size.height + 4))
        input.frame = viewRect(rect)
        input.textContainer?.containerSize = CGSize(width: input.bounds.width - input.textContainerInset.width * 2, height: CGFloat.greatestFiniteMagnitude)
    }
    func textDidChange(_ notification: Notification) { layoutText(); changed() }
    func commitText() {
        guard let input = textInput, var annotation = textAnnotation else { return }
        input.unmarkText()
        annotation.text = input.string
        var next = history.document
        if annotation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { next.remove(annotation.id); selection = nil }
        else {
            let size = AnnotationRenderer.textSize(annotation.text, style: style)
            annotation.end = CGPoint(x: annotation.start.x + size.width, y: annotation.start.y + size.height)
            next.replace(annotation)
        }
        input.removeFromSuperview(); textInput = nil; textAnnotation = nil
        history.commit(next); window?.makeFirstResponder(self); changed()
    }
    override func draw(_ dirtyRect: NSRect) {
        var drawnDocument = document
        if let textAnnotation { drawnDocument.remove(textAnnotation.id) }
        if renderedDocument != drawnDocument {
            composed = try? AnnotationRenderer.compose(original, document: drawnDocument)
            renderedDocument = drawnDocument
        }
        let image = NSImage(cgImage: composed ?? original, size: CGSize(width: original.width, height: original.height))
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if let selected = document.annotations.first(where: { $0.id == selection }), !isEditingText {
            let rect = viewRect(document.bounds(of: selected, style: style))
            NSColor.white.withAlphaComponent(0.8).setStroke()
            let border = NSBezierPath(rect: rect); border.lineWidth = 1
            border.setLineDash([4, 3], count: 2, phase: 0); border.stroke()
            for handle in AnnotationGeometry.handles(for: selected) {
                let p = viewPoint(handle), r = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
                NSColor.white.setFill(); NSBezierPath(ovalIn: r).fill()
                AnnotationRenderer.red.setStroke(); NSBezierPath(ovalIn: r).stroke()
            }
        }
        if tool == .number, let cursorPoint, !isEditingText, gesture == nil {
            let string = String(document.nextNumber) as NSString
            let r = viewRect(style.numberRect(at: cursorPoint, number: document.nextNumber))
            AnnotationRenderer.red.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: style.fontSize * displayScale, weight: .bold), .foregroundColor: NSColor.white.withAlphaComponent(0.6)]
            let size = string.size(withAttributes: attributes)
            string.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attributes)
        }
    }
}

/// IMEのEnterはinput contextに任せ、未変換文字がないEnterだけ注釈として確定する。
@MainActor
final class AnnotationTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onEscape: (() -> Void)?
    private var markedAtKeyDown = false
    // 確定済みの文字編集を、次に開いた文字の⌘Zへ持ち越さない。
    private let textUndoManager = UndoManager()
    override var undoManager: UndoManager? { textUndoManager }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func keyDown(with event: NSEvent) {
        markedAtKeyDown = hasMarkedText()
        super.keyDown(with: event)
        markedAtKeyDown = false
    }
    override func insertNewline(_ sender: Any?) {
        if hasMarkedText() || markedAtKeyDown || NSApp.currentEvent?.modifierFlags.contains(.shift) == true { super.insertNewline(sender) }
        else { onCommit?() }
    }
    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) { super.insertNewline(sender) }
    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() || markedAtKeyDown { super.cancelOperation(sender) }
        else { onEscape?() }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags == .command {
            switch event.keyCode {
            case 8: copy(nil); return true // C
            case 7: cut(nil); return true // X
            case 9: paste(nil); return true // V
            case 0: selectAll(nil); return true // A
            case 6: undoManager?.undo(); return true // Z
            default: break
            }
        }
        if flags == [.command, .shift], event.keyCode == 6 { undoManager?.redo(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

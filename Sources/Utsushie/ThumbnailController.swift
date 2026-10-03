import AppKit

@MainActor
final class ThumbnailController {
    private var cards: [ThumbnailCard] = []
    private var suspended = false

    func add(_ artifact: SharedArtifact, image: CGImage, copied: Bool, seconds: Double, screen: NSScreen?) {
        let card = ThumbnailCard(artifact: artifact, image: image, copied: copied, seconds: seconds)
        card.screen = screen ?? NSScreen.main ?? NSScreen.screens.first
        card.onClose = { [weak self, weak card] in
            guard let self, let card else { return }
            card.close()
            self.cards.removeAll { $0 === card }
            self.layout()
        }
        cards.append(card)
        layout()
        if !suspended { card.show() }
    }
    func setSuspended(_ value: Bool) {
        suspended = value
        cards.forEach { value ? $0.hide() : $0.show() }
    }
    private func layout() {
        // 配列は古い順。逆順に下から置くので最新が最下段。
        var heights: [ObjectIdentifier: CGFloat] = [:]
        for card in cards.reversed() {
            guard let screen = card.screen else { continue }
            let key = ObjectIdentifier(screen)
            let offset = heights[key] ?? 0
            let visible = screen.visibleFrame
            card.panel.setFrameOrigin(CGPoint(x: visible.maxX - 282, y: visible.minY + 18 + offset))
            heights[key] = offset + card.panel.frame.height + 12
        }
    }
}

@MainActor
private final class ThumbnailCard {
    let panel: CapturePanel
    var artifact: SharedArtifact
    var screen: NSScreen?
    var onClose: (() -> Void)?
    private var view: ThumbnailView!
    private var timer: Timer?
    private var remaining: Double
    private var started: Date?
    private var hovered = false
    private var visible = false
    private var dragging = false
    private var saving = false
    private var keyMonitor: Any?

    init(artifact: SharedArtifact, image: CGImage, copied: Bool, seconds: Double) {
        self.artifact = artifact; remaining = seconds
        panel = CapturePanel(contentRect: CGRect(x: 0, y: 0, width: 264, height: 216), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        view = ThumbnailView(frame: CGRect(x: 0, y: 0, width: 264, height: 216))
        view.card = self
        view.image = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        view.copied = copied
        panel.contentView = view
    }
    func show() {
        visible = true; panel.orderFrontRegardless(); resumeTimer()
    }
    func hide() {
        visible = false; pauseTimer(); stopKeys(); hovered = false; panel.orderOut(nil)
    }
    func close() { hide(); onClose = nil }
    private func pauseTimer() {
        if let started { remaining = max(0, remaining - Date().timeIntervalSince(started)) }
        timer?.invalidate(); timer = nil; started = nil
    }
    private func resumeTimer() {
        guard visible, !hovered, !dragging, !saving, timer == nil else { return }
        started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: max(0.01, remaining), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.onClose?() }
        }
    }
    func hover(_ value: Bool) {
        hovered = value
        if value {
            pauseTimer()
            // nonactivatingPanelだけではキーは届かない。キー化とfirst responderを明示する。
            panel.makeKey(); panel.makeFirstResponder(view)
            if keyMonitor == nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, self.hovered,
                          event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
                    switch event.keyCode {
                    case 1: if !event.isARepeat { self.saveAs() }; return nil // S
                    case 31: if !event.isARepeat { self.reveal() }; return nil // O
                    case 7, 53: self.onClose?(); return nil // X, Esc
                    default: return event
                    }
                }
            }
        } else { stopKeys(); panel.resignKey(); resumeTimer() }
    }
    private func stopKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
    func reveal() { NSWorkspace.shared.activateFileViewerSelecting([artifact.url]) }
    func saveAs() {
        guard !saving else { return }
        saving = true; pauseTimer(); stopKeys()
        let save = NSSavePanel()
        save.nameFieldStringValue = artifact.url.lastPathComponent
        save.directoryURL = artifact.url.deletingLastPathComponent()
        save.allowedContentTypes = [UTType(filenameExtension: artifact.kind.fileExtension) ?? .data]
        save.canCreateDirectories = true
        NSApp.activate()
        save.begin { [weak self] response in
            guard let self else { return }
            if response == .OK, let target = save.url, target != self.artifact.url {
                do {
                    // 元の自動保存は残す。追加保存を求められたパスへ同一バイトを保存する。
                    let data = try Data(contentsOf: self.artifact.url)
                    try data.write(to: target, options: .atomic)
                } catch {
                    let alert = NSAlert(); alert.messageText = "保存できませんでした"; alert.informativeText = error.localizedDescription; alert.runModal()
                }
            }
            self.saving = false
            self.hovered = self.panel.frame.contains(NSEvent.mouseLocation)
            if self.hovered { self.hover(true) } else { self.resumeTimer() }
        }
    }
    func dragStarted() { dragging = true; pauseTimer() }
    func dragEnded() {
        dragging = false
        hover(panel.frame.contains(NSEvent.mouseLocation))
    }
}

import UniformTypeIdentifiers

@MainActor
private final class ThumbnailView: NSView, NSDraggingSource {
    weak var card: ThumbnailCard?
    var image: NSImage?
    var copied = false
    private var downEvent: NSEvent?
    private var dragged = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { card?.hover(true) }
    override func mouseExited(with event: NSEvent) { card?.hover(false) }
    override func mouseDown(with event: NSEvent) { downEvent = event; dragged = false }
    override func mouseUp(with event: NSEvent) {
        defer { downEvent = nil }
        guard !dragged, let card else { return }
        let point = convert(event.locationInWindow, from: nil)
        if point.y >= 177 {
            if point.x >= 224 { card.onClose?() }
            else if point.x >= 190 { card.reveal() }
            else if point.x >= 156 { card.saveAs() }
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard !dragged, let downEvent, let card else { return }
        let a = convert(downEvent.locationInWindow, from: nil), b = convert(event.locationInWindow, from: nil)
        guard hypot(a.x - b.x, a.y - b.y) > 4 else { return }
        dragged = true; card.dragStarted()
        // NSURLのドラッグはファイル参照のみ。画像のPNG/TIFF表現は付加しない。
        let item = NSDraggingItem(pasteboardWriter: card.artifact.url as NSURL)
        item.setDraggingFrame(CGRect(x: b.x - 100, y: b.y - 60, width: 200, height: 120), contents: image)
        beginDraggingSession(with: [item], event: downEvent, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { card?.dragEnded() }
    override func draw(_ dirtyRect: NSRect) {
        guard let card else { return }
        NSColor(calibratedWhite: 0.10, alpha: 0.97).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
        let preview = CGRect(x: 12, y: 12, width: 240, height: 140)
        NSColor.black.setFill(); NSBezierPath(roundedRect: preview, xRadius: 6, yRadius: 6).fill()
        if let image {
            let factor = min(preview.width / image.size.width, preview.height / image.size.height)
            let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
            image.draw(in: CGRect(x: preview.midX - size.width / 2, y: preview.midY - size.height / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let info = "\(card.artifact.kind.label)  \(card.artifact.width)×\(card.artifact.height)  \(max(1, Int((Double(card.artifact.byteCount) / 1024).rounded())))KB"
        text(info, at: CGPoint(x: 14, y: 160), size: 12)
        text(copied ? "Copied" : "Saved", at: CGPoint(x: 14, y: 189), size: 12)
        text("S", at: CGPoint(x: 162, y: 187), size: 14)
        text("O", at: CGPoint(x: 198, y: 187), size: 14)
        text("×", at: CGPoint(x: 234, y: 187), size: 17)
    }
    private func text(_ string: String, at point: CGPoint, size: Double) {
        (string as NSString).draw(at: point, withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor.white])
    }
}

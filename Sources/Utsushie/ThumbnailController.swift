import AppKit
import UtsushieCore

@MainActor
final class ThumbnailController {
    private var cards: [ThumbnailCard] = []
    private var suspended = false
    private var keyboardTargetID: UUID?
    var annotationConfig: () -> UtsushieConfig = { ConfigLoader.load().config }

    @discardableResult
    func add(_ artifact: SharedArtifact, image: CGImage?, copied: Bool, seconds: Double, screen: NSScreen?, finalizing: Bool = false) -> UUID {
        let card = ThumbnailCard(artifact: artifact, image: image, copied: copied, seconds: seconds, finalizing: finalizing)
        card.screen = screen ?? NSScreen.main ?? NSScreen.screens.first
        card.annotationConfig = { [weak self] in self?.annotationConfig() ?? UtsushieConfig() }
        card.canShow = { [weak self] in self?.suspended == false }
        card.onRequestKeys = { [weak self, weak card] in
            guard let self, let card, self.cards.contains(where: { $0 === card }) else { return }
            self.keyboardTargetID = card.id
            self.updateKeyboardTarget()
        }
        card.onClose = { [weak self, weak card] in
            guard let self, let card else { return }
            card.close()
            self.cards.removeAll { $0 === card }
            if self.keyboardTargetID == card.id { self.keyboardTargetID = self.cards.last?.id }
            self.updateKeyboardTarget()
            self.layout()
        }
        cards.append(card)
        keyboardTargetID = card.id
        updateKeyboardTarget()
        layout()
        if !suspended { card.show() }
        return card.id
    }
    func complete(_ id: UUID, artifact: SharedArtifact, image: CGImage, copied: Bool) {
        cards.first { $0.id == id }?.complete(artifact: artifact, image: image, copied: copied)
    }
    func remove(_ id: UUID) {
        cards.first { $0.id == id }?.onClose?()
    }
    func setSuspended(_ value: Bool) {
        suspended = value
        cards.forEach { value ? $0.hide() : $0.show() }
    }
    private func updateKeyboardTarget() {
        for card in cards { card.setKeyboardTarget(card.id == keyboardTargetID) }
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
final class ThumbnailCard: NSObject, NSWindowDelegate {
    let id = UUID()
    let panel: ThumbnailPanel
    var artifact: SharedArtifact
    var screen: NSScreen?
    var onClose: (() -> Void)?
    var onRequestKeys: (() -> Void)?
    private var view: ThumbnailView!
    private var timer: Timer?
    private var remaining: Double
    private var started: Date?
    private var hovered = false
    private var visible = false
    private var dragging = false
    private var saving = false
    private var keyMonitor: Any?
    private var previousApplication: NSRunningApplication?
    private var isKeyboardTarget = false
    private let lifetime: Double
    private let originalImage: CGImage?
    private var annotations = AnnotationDocument()
    private var editor: AnnotationEditorController?
    var annotationConfig: () -> UtsushieConfig = { UtsushieConfig() }
    var canShow: () -> Bool = { true }
    var canEdit: Bool { artifact.kind == .webP && originalImage != nil && !finalizing }
    private(set) var finalizing: Bool

    init(artifact: SharedArtifact, image: CGImage?, copied: Bool, seconds: Double, finalizing: Bool) {
        self.artifact = artifact; remaining = seconds; self.finalizing = finalizing
        lifetime = seconds; originalImage = artifact.kind == .webP ? image : nil
        panel = ThumbnailPanel(contentRect: CGRect(x: 0, y: 0, width: 264, height: 216), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        view = ThumbnailView(frame: CGRect(x: 0, y: 0, width: 264, height: 216))
        view.card = self
        view.configureButtons()
        if let image { view.image = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)) }
        view.copied = copied
        view.refreshControls()
        panel.contentView = view
    }
    func complete(artifact: SharedArtifact, image: CGImage, copied: Bool) {
        self.artifact = artifact; finalizing = false
        view.image = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        view.copied = copied; view.refreshControls(); view.needsDisplay = true
        resumeTimer()
    }
    func show(claimKeyboard: Bool = true) {
        guard editor == nil else { return }
        visible = true; panel.orderFrontRegardless()
        if claimKeyboard { claimKeys() }
        resumeTimer()
    }
    func hide() {
        visible = false; pauseTimer(); releaseKeys(); hovered = false; panel.orderOut(nil)
    }
    func close() {
        let restore = panel.isKeyWindow
        hide(); panel.close(); onClose = nil
        if restore { restoreFocus() }
    }
    func setKeyboardTarget(_ value: Bool) {
        isKeyboardTarget = value
        if !value { releaseKeys() }
    }
    private func claimKeys() {
        guard isKeyboardTarget, visible, editor == nil, !saving, !dragging else { return }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = front
        }
        // 非アクティブのまま指定されたカードへキーだけを渡す。キー取得だけでは寿命を止めない。
        panel.receivesKeyboard = true
        panel.makeKey(); panel.makeFirstResponder(view)
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isKeyboardTarget, self.visible, self.panel.isKeyWindow, event.window === self.panel,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
            switch event.keyCode {
            case 14: if !event.isARepeat { self.edit() }; return nil // E。動画では何もしない。
            case 1: if !event.isARepeat { self.saveAs() }; return nil // S
            case 31: if !event.isARepeat { self.reveal() }; return nil // O
            case 7, 53: self.onClose?(); return nil // X, Esc
            default: return event
            }
        }
    }
    private func releaseKeys() {
        stopKeys()
        if panel.isKeyWindow { panel.resignKey() }
        panel.receivesKeyboard = false
    }
    private func restoreFocus() {
        guard let previousApplication, previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        NSApp.yieldActivation(to: previousApplication)
        _ = previousApplication.activate(options: [])
    }
    func windowDidResignKey(_ notification: Notification) {
        // 別のアプリをクリックしたときは取り戻さない。次のshowまたは明示的なホバーで再取得する。
        stopKeys()
        view.refreshControls(); view.needsDisplay = true
    }
    func windowDidBecomeKey(_ notification: Notification) { view.refreshControls(); view.needsDisplay = true }
    @objc func dismiss() { onClose?() }
    @objc func edit() {
        guard canEdit, editor == nil, let originalImage else { return }
        hide()
        let controller = AnnotationEditorController(image: originalImage, document: annotations, screen: screen)
        editor = controller
        controller.onComplete = { [weak self] image, document in
            guard let self else { return }
            let config = self.annotationConfig()
            let data = try await Task.detached(priority: .userInitiated) {
                try WebPEncoder.encode(image, quality: config.quality, lossless: config.lossless)
            }.value
            let updated = try AnnotationSave.commit(data: data, artifact: self.artifact, mode: config.clipboard)
            self.annotations = document
            self.complete(artifact: updated, image: image, copied: true)
        }
        controller.onClose = { [weak self] in
            guard let self else { return }
            self.editor = nil; self.remaining = self.lifetime
            // 編集パネルが手放したキーを貼り付け先へ返す。ホバー時には再び取得できる。
            if self.canShow() { self.show(claimKeyboard: false) }
        }
        controller.show()
    }
    private func pauseTimer() {
        if let started { remaining = max(0, remaining - Date().timeIntervalSince(started)) }
        timer?.invalidate(); timer = nil; started = nil
    }
    private func resumeTimer() {
        guard visible, editor == nil, !hovered, !dragging, !saving, !finalizing, timer == nil else { return }
        started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: max(0.01, remaining), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.onClose?() }
        }
    }
    func hover(_ value: Bool) {
        guard editor == nil, visible else { return }
        hovered = value
        if value {
            pauseTimer()
            // 古いカードでもホバーを契機に受け手を切り替え、ほかのカードはキーを手放す。
            onRequestKeys?()
            claimKeys()
        } else { resumeTimer() }
    }
    private func stopKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
    @objc func reveal() {
        guard !finalizing else { return }
        NSWorkspace.shared.activateFileViewerSelecting([artifact.url])
    }
    @objc func saveAs() {
        guard !saving, !finalizing else { return }
        saving = true; pauseTimer(); releaseKeys()
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
            self.claimKeys()
            if self.hovered { self.pauseTimer() } else { self.resumeTimer() }
        }
    }
    func dragStarted() { dragging = true; pauseTimer(); releaseKeys() }
    func dragEnded() {
        dragging = false
        hovered = panel.frame.contains(NSEvent.mouseLocation)
        if !hovered { resumeTimer() }
    }
}

@MainActor
final class ThumbnailPanel: NSPanel {
    var receivesKeyboard = false
    override var canBecomeKey: Bool { receivesKeyboard }
    override var canBecomeMain: Bool { false }
}

import UniformTypeIdentifiers

@MainActor
final class ThumbnailView: NSView, NSDraggingSource {
    weak var card: ThumbnailCard?
    var image: NSImage?
    var copied = false
    private var downEvent: NSEvent?
    private var dragged = false
    private var buttons: [CardAction: CardButton] = [:]
    private let spinner = NSProgressIndicator()
    func configureButtons() {
        guard let card else { return }
        let definitions: [(CardAction, String, String, String, Selector)] = [
            (.annotate, "pencil", "E", "注釈 E", #selector(ThumbnailCard.edit)),
            (.save, "square.and.arrow.down", "S", "別名保存 S", #selector(ThumbnailCard.saveAs)),
            (.reveal, "folder", "O", "Finderで表示 O", #selector(ThumbnailCard.reveal)),
            (.close, "xmark", "×", "閉じる X・Esc", #selector(ThumbnailCard.dismiss))]
        for (action, symbol, key, label, selector) in definitions {
            let button = CardButton(frame: CardPresentation.button(action))
            button.symbol = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.key = key; button.target = card; button.action = selector
            button.isBordered = false; button.toolTip = label; button.setAccessibilityLabel(label)
            buttons[action] = button; addSubview(button)
        }
        spinner.style = .spinning; spinner.controlSize = .small
        spinner.frame = CGRect(x: 18, y: 164, width: 12, height: 12)
        spinner.isDisplayedWhenStopped = false; addSubview(spinner)
    }
    func refreshControls() {
        guard let card else { return }
        for (action, button) in buttons {
            button.isEnabled = action == .close || !card.finalizing && (action != .annotate || card.canEdit)
            button.showsKey = card.panel.isKeyWindow; button.needsDisplay = true
        }
        if card.finalizing { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
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
        guard !dragged, let card, let downEvent else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard CardPresentation.action(at: convert(downEvent.locationInWindow, from: nil)) == CardPresentation.action(at: point) else { return }
        switch CardPresentation.action(at: point) {
        case .annotate: card.edit()
        case .save: card.saveAs()
        case .reveal: card.reveal()
        case .close: card.onClose?()
        case nil: break
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard !dragged, let downEvent, let card, !card.finalizing,
              CardPresentation.action(at: convert(downEvent.locationInWindow, from: nil)) == nil else { return }
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
        UITheme.ink.withAlphaComponent(0.97).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
        if card.panel.isKeyWindow {
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 13.25, yRadius: 13.25)
            outline.lineWidth = 1.5; NSColor.white.withAlphaComponent(0.62).setStroke(); outline.stroke()
        }
        let preview = CGRect(x: 12, y: 12, width: 240, height: 140)
        NSColor.black.setFill(); NSBezierPath(roundedRect: preview, xRadius: 8, yRadius: 8).fill()
        if let image {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: preview, xRadius: 8, yRadius: 8).addClip()
            let factor = min(preview.width / image.size.width, preview.height / image.size.height)
            let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
            image.draw(in: CGRect(x: preview.midX - size.width / 2, y: preview.midY - size.height / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        if let duration = card.artifact.duration {
            let durationText = "▶ \(MediaFormatting.elapsed(duration))"
            let width = ceil((durationText as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium)]).width) + 14
            let badge = CGRect(x: preview.maxX - width - 6, y: preview.maxY - 24, width: width, height: 18)
            UIDrawing.fill(badge, color: UITheme.ink.withAlphaComponent(0.85), radius: 4)
            UIDrawing.text(durationText, in: badge.insetBy(dx: 6, dy: 2), size: 10.5, color: .white)
        }
        let status = CardPresentation.status(copied: copied, finalizing: card.finalizing)
        let statusWidth = ceil((status as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold)]).width) + 14 + (card.finalizing ? 17 : 0)
        let chip = CGRect(x: 12, y: 160, width: statusWidth, height: 20)
        UIDrawing.fill(chip, color: copied && !card.finalizing ? UITheme.indigo : NSColor.white.withAlphaComponent(0.12), radius: 5)
        UIDrawing.text(status, in: CGRect(x: chip.minX + 7 + (card.finalizing ? 17 : 0), y: chip.minY + 2,
                                        width: chip.width - 14 - (card.finalizing ? 17 : 0), height: 16), size: 11.5, color: .white, weight: .semibold)
        let info = CardPresentation.info(format: card.artifact.kind.label, width: card.artifact.width, height: card.artifact.height, bytes: card.artifact.byteCount)
        let infoRect = CGRect(x: chip.maxX + 8, y: 164, width: 252 - chip.maxX - 8, height: 16)
        var fontSize: CGFloat = 11.5
        while fontSize > 9 && (info as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium)]).width > infoRect.width { fontSize -= 0.5 }
        UIDrawing.text(info, in: infoRect, size: fontSize, color: UITheme.muted)
    }
}

@MainActor
private final class CardButton: NSButton {
    var symbol: NSImage?
    var key = ""
    var showsKey = false
    override var isFlipped: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isEnabled ? 1 : 0.3
        UIDrawing.fill(bounds, color: NSColor.white.withAlphaComponent((isHighlighted ? 0.18 : 0.08) * alpha), radius: 6)
        let imageX = showsKey ? bounds.midX - 16 : bounds.midX - 7
        if let symbol {
            let tinted = NSImage(size: CGSize(width: 14, height: 14), flipped: true) { rect in
                symbol.draw(in: rect); UITheme.text.setFill(); rect.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: CGRect(x: imageX, y: 5, width: 14, height: 14), from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
        }
        if showsKey { UIDrawing.text(key, in: CGRect(x: bounds.midX + 4, y: 5, width: 16, height: 15), size: 10.5, color: UITheme.key.withAlphaComponent(alpha), weight: .semibold) }
    }
}

import AppKit
import UtsushieCore

@MainActor
final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayController {
    private(set) var state = CaptureState()
    private(set) var last: CGRect?
    var selection: CGRect? { state.gesture.areaPreview }
    var displayedLast: CGRect? { state.gesture.lastPreview ?? last }
    private(set) var highlighted: CaptureRequest?
    private(set) var message = ""
    private var panels: [CapturePanel] = []
    private var keyMonitor: Any?
    var onCapture: ((CaptureRequest, Bool, CaptureOutput) -> Void)?
    var onMoveLast: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onAccessibilityNeeded: (() -> Void)?
    var isVisible: Bool { !panels.isEmpty }

    func show(last: CGRect?) {
        close()
        state = CaptureState()
        self.last = last
        message = ""
        for screen in NSScreen.screens {
            let panel = CapturePanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.setFrame(screen.frame, display: false)
            panel.isOpaque = false; panel.backgroundColor = .clear
            panel.hasShadow = false; panel.hidesOnDeactivate = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.acceptsMouseMovedEvents = true
            let view = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.controller = self; view.screenFrame = screen.frame
            panel.contentView = view
            panels.append(panel)
            panel.orderFrontRegardless()
        }
        let underMouse = panels.first { $0.frame.contains(NSEvent.mouseLocation) } ?? panels.first
        underMouse?.makeKey()
        if let view = underMouse?.contentView { underMouse?.makeFirstResponder(view) }
        // local monitorはIMEへ渡る前のkeyDownを受け取る。charactersは読まない。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard modifiers.isEmpty, [UInt16(53), 48, 13, 8, 36, 76].contains(event.keyCode) else { return event }
            if !event.isARepeat { self.key(event.keyCode) }
            return nil
        }
        NSCursor.crosshair.set()
    }
    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        state.cancelGesture(); highlighted = nil
        NSCursor.arrow.set()
    }
    func repeatCapture() { perform(state.repeatCapture(hasLast: last != nil)) }
    private func key(_ code: UInt16) {
        message = ""
        perform(state.key(code, hasLast: last != nil))
        updateWindow()
        redraw()
    }
    private func perform(_ action: CaptureAction) {
        switch action {
        case .none: break
        case .cancel: close(); onCancel?()
        case .captureLast:
            if let last { onCapture?(.region(last), true, state.output) }
        case .captureChrome:
            do { onCapture?(.region(try ChromeArea.rect()), false, state.output) }
            catch {
                state.fallbackToArea(); highlighted = nil; message = error.localizedDescription
                if !AXIsProcessTrusted() { onAccessibilityNeeded?() }
            }
        }
        redraw()
    }
    func mouseMoved() { updateWindow(); redraw() }
    private func updateWindow() {
        guard state.target == .window else { highlighted = nil; return }
        NSCursor.arrow.set()
        let point = NSEvent.mouseLocation
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        highlighted = nil
        for item in list {
            guard item[kCGWindowOwnerPID as String] as? Int32 != ownPID,
                  item[kCGWindowLayer as String] as? Int == 0,
                  (item[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = item[kCGWindowBounds as String] as? [String: Any],
                  let cgRect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  let id = item[kCGWindowNumber as String] as? UInt32 else { continue }
            let rect = ScreenGeometry.appKit(cgRect)
            if rect.contains(point) { highlighted = .window(id, rect); break }
        }
    }
    func mouseDown() {
        guard isVisible else { return }
        performPointer(state.pointerDown(at: NSEvent.mouseLocation, last: last))
    }
    func mouseDragged() {
        guard isVisible else { return }
        state.pointerDragged(to: NSEvent.mouseLocation)
        redraw()
    }
    func mouseUp() {
        guard isVisible else { return }
        performPointer(state.pointerUp(at: NSEvent.mouseLocation))
    }
    private func performPointer(_ action: PointerAction) {
        switch action {
        case .none: break
        case .cancel: perform(.cancel)
        case .captureWindow:
            updateWindow()
            if let highlighted { onCapture?(highlighted, false, state.output) }
        case let .captureArea(rect): onCapture?(.region(rect), true, state.output)
        case let .moveLast(rect):
            if CaptureGeometry.isVisible(rect, displays: ScreenGeometry.displays) {
                last = rect; onMoveLast?(rect)
            } else { message = "前回範囲を画面内へ移動してください" }
            // 移動中はプレビューだけを変え、離したときに確定する。Escでは保存しない。
        }
        redraw()
    }
    func showError(_ error: Error) {
        message = error.localizedDescription; state.fallbackToArea(); redraw()
    }
    private func redraw() { panels.forEach { $0.contentView?.needsDisplay = true } }
}

@MainActor
private final class OverlayView: NSView {
    weak var controller: OverlayController?
    var screenFrame = CGRect.zero
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseDown(with event: NSEvent) { controller?.mouseDown() }
    override func mouseDragged(with event: NSEvent) { controller?.mouseDragged() }
    override func mouseUp(with event: NSEvent) { controller?.mouseUp() }
    override func mouseMoved(with event: NSEvent) { controller?.mouseMoved() }
    override func draw(_ dirtyRect: NSRect) {
        guard let controller else { return }
        NSColor.black.withAlphaComponent(0.26).setFill(); bounds.fill()
        func local(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY) }
        if let last = controller.displayedLast {
            let rect = local(last)
            let outline = NSBezierPath(rect: rect); outline.lineWidth = 2
            outline.setLineDash([7, 5], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.85).setStroke(); outline.stroke()
            label("Last  \(Int(last.width)) × \(Int(last.height))\nEnter / hotkey ×2", at: CGPoint(x: rect.minX + 12, y: rect.maxY - 46), size: 13)
        }
        if let rect = controller.selection ?? controller.highlighted?.rect {
            let area = local(rect)
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill(); area.fill()
            let border = NSBezierPath(rect: area); border.lineWidth = 2
            NSColor.controlAccentColor.setStroke(); border.stroke()
            label("\(Int(rect.width)) × \(Int(rect.height))", at: CGPoint(x: area.minX + 6, y: area.maxY + 8), size: 13)
        }
        let strip = CGRect(x: (bounds.width - 420) / 2, y: bounds.height - 134, width: 420, height: 102)
        NSColor(calibratedWhite: 0.08, alpha: 0.93).setFill()
        NSBezierPath(roundedRect: strip, xRadius: 14, yRadius: 14).fill()
        let image = controller.state.output == .image ? "[Image]   Video" : "Image   [Video]"
        label("\(image)                       Tab: output", at: CGPoint(x: strip.minX + 18, y: strip.maxY - 30), size: 15)
        label("drag: Area   W: Window   C: Chrome", at: CGPoint(x: strip.minX + 18, y: strip.maxY - 56), size: 14)
        label("Enter: Last   Esc: Cancel", at: CGPoint(x: strip.minX + 18, y: strip.maxY - 81), size: 14)
        let status = controller.message
        if !status.isEmpty {
            let messageRect = CGRect(x: max(16, (bounds.width - 640) / 2), y: strip.minY - 66, width: min(640, bounds.width - 32), height: 54)
            NSColor.black.withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: messageRect, xRadius: 8, yRadius: 8).fill()
            (status as NSString).draw(in: messageRect.insetBy(dx: 12, dy: 8), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white])
        }
    }
    private func label(_ text: String, at point: CGPoint, size: Double) {
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black; shadow.shadowBlurRadius = 3
        (text as NSString).draw(at: point, withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor.white, .shadow: shadow])
    }
}

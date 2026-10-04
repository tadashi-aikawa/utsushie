import AppKit
import ScreenCaptureKit
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
    private(set) var highlightedApp = ""
    var config = UtsushieConfig()
    private var windowContent: SCShareableContent?
    private var contentTask: Task<Void, Never>?
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
        refreshWindowContent()
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
        contentTask?.cancel(); contentTask = nil; windowContent = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        state.cancelGesture(); highlighted = nil; highlightedApp = ""
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
        guard state.target == .window else { highlighted = nil; highlightedApp = ""; NSCursor.crosshair.set(); return }
        NSCursor.arrow.set()
        let point = NSEvent.mouseLocation
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        highlighted = nil
        highlightedApp = ""
        for item in list {
            guard item[kCGWindowOwnerPID as String] as? Int32 != ownPID,
                  item[kCGWindowLayer as String] as? Int == 0,
                  (item[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = item[kCGWindowBounds as String] as? [String: Any],
                  let cgRect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  let id = item[kCGWindowNumber as String] as? UInt32 else { continue }
            let rect = ScreenGeometry.appKit(cgRect)
            if rect.contains(point) {
                highlighted = .window(id, rect)
                highlightedApp = item[kCGWindowOwnerName as String] as? String ?? "ウィンドウ"
                if windowContent?.windows.first(where: { $0.windowID == id })?.frame != cgRect { refreshWindowContent() }
                break
            }
        }
    }
    private func refreshWindowContent() {
        guard contentTask == nil else { return }
        contentTask = Task { [weak self] in
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard !Task.isCancelled, let self, self.isVisible else { return }
            self.contentTask = nil; self.windowContent = content; self.redraw()
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
    func dimensions(_ rect: CGRect, window: Bool = false) -> String {
        let video = state.output == .video
        let downscale = video ? config.video.downscale : config.downscale
        var points = rect.size
        var scale = CaptureGeometry.scale(for: rect, displays: ScreenGeometry.displays, downscale: downscale)
        if window, case let .window(id, _) = highlighted,
           let selected = windowContent?.windows.first(where: { $0.windowID == id }),
           ScreenGeometry.appKit(selected.frame) == rect {
            let filter = SCContentFilter(desktopIndependentWindow: selected)
            points = filter.contentRect.size; scale = Double(filter.pointPixelScale)
        }
        return OverlayPresentation.dimensions(points: points, scale: scale, output: state.output, downscale: downscale)
    }
    private func redraw() { panels.forEach { $0.contentView?.needsDisplay = true } }
}

@MainActor
final class OverlayView: NSView {
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
        func local(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY) }
        let selected = controller.selection ?? controller.highlighted?.rect
        UIDrawing.curtain(bounds, selection: selected.map(local))
        if let last = controller.displayedLast {
            let rect = local(last)
            let outline = NSBezierPath(rect: rect); outline.lineWidth = 1.5
            outline.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.85).setStroke(); outline.stroke()
            label("前回 \(controller.dimensions(last)) ⏎", at: CGPoint(x: rect.minX + 8, y: rect.maxY - 30))
        }
        if let rect = selected {
            let area = local(rect)
            UIDrawing.selection(area, video: controller.state.output == .video)
            let isWindow = controller.selection == nil && controller.highlighted != nil
            let dimensions = controller.dimensions(rect, window: isWindow)
            let title = isWindow ? "\(controller.highlightedApp) · \(dimensions)" : dimensions
            let width = min(bounds.width - 16, ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium)]).width) + 16)
            let placement = OverlayPresentation.dimensionLabel(selection: area, screen: bounds, size: CGSize(width: width, height: 22))
            label(title, in: placement)
        }
        guard screenFrame.contains(NSEvent.mouseLocation) else { return }
        // Dockの上に置き、失敗の札を帯の下へ確保する。
        let visible = local(NSScreen.screens.first { $0.frame == screenFrame }?.visibleFrame ?? screenFrame)
        drawHUD(controller, visible: visible)
    }
    private func label(_ string: String, at point: CGPoint) {
        let width = ceil((string as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium)]).width) + 16
        label(string, in: CGRect(origin: point, size: CGSize(width: width, height: 22)))
    }
    private func label(_ string: String, in rect: CGRect) {
        UIDrawing.fill(rect, color: UITheme.ink.withAlphaComponent(0.94), radius: 6)
        UIDrawing.text(string, in: CGRect(x: rect.minX + 8, y: rect.minY + 3, width: rect.width - 16, height: 16), size: 11.5)
    }
    private func drawHUD(_ controller: OverlayController, visible: CGRect) {
        let items = OverlayPresentation.items(output: controller.state.output, target: controller.state.target, hasLast: controller.last != nil)
        let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let keyFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        func width(_ text: String, font: NSFont) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
        let widths = items.map { item in
            width(item.title, font: font) + 14 + (item.key.map { width($0, font: keyFont) + ($0 == "ドラッグ" ? 6 : 14) } ?? 0)
        }
        let stripWidth = max(620, widths.reduce(0, +) + 78)
        let factor = min(1, (visible.width - 24) / stripWidth)
        let hasError = !controller.message.isEmpty
        let errorWidth = min(640, visible.width - 24)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
        let errorHeight = hasError ? max(38, ceil((controller.message as NSString).boundingRect(with: CGSize(width: errorWidth - 54, height: .greatestFiniteMagnitude),
            options: .usesLineFragmentOrigin, attributes: [.font: font, .paragraphStyle: paragraph]).height) + 20) : 0
        let origin = CGPoint(x: visible.midX - stripWidth * factor / 2,
                             y: visible.minY + 18 + (hasError ? errorHeight + 10 : 0))
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform(); transform.translateX(by: origin.x, yBy: origin.y); transform.scale(by: factor); transform.concat()
        UIDrawing.fill(CGRect(x: 0, y: 0, width: stripWidth, height: 40), color: UITheme.ink.withAlphaComponent(0.94), radius: 12)
        var x: CGFloat = 8
        for (index, item) in items.enumerated() {
            if index == 2 {
                UIDrawing.key("Tab", in: CGRect(x: x + 4, y: 11.5, width: 28, height: 17)); x += 38
                divider(x); x += 8
            } else if index == 6 { divider(x + 3); x += 10 }
            let cell = CGRect(x: x, y: 7, width: widths[index], height: 26)
            if item.selected {
                UIDrawing.fill(cell, color: item.recording ? UITheme.redFace : NSColor.white.withAlphaComponent(0.15), radius: 6)
            }
            let color = !item.enabled ? UITheme.key : item.selected ? NSColor.white : UITheme.text
            UIDrawing.text(item.title, in: CGRect(x: x + 7, y: 12, width: width(item.title, font: font), height: 17), size: 12.5, color: color)
            if let key = item.key {
                let keyX = x + 7 + width(item.title, font: font) + 6
                if key == "ドラッグ" {
                    UIDrawing.text(key, in: CGRect(x: keyX, y: 13, width: widths[index] - (keyX - x), height: 15), size: 10.5, color: UITheme.key)
                } else {
                    UIDrawing.key(key, in: CGRect(x: keyX, y: 11.5, width: width(key, font: keyFont) + 8, height: 17))
                }
            }
            x += widths[index] + 2
        }
        NSGraphicsContext.restoreGraphicsState()
        if hasError {
            let box = CGRect(x: visible.midX - errorWidth / 2, y: visible.minY + 18, width: errorWidth, height: errorHeight)
            UIDrawing.fill(box, color: UITheme.ink.withAlphaComponent(0.94), radius: 10)
            let badge = CGRect(x: box.minX + 12, y: box.midY - 9, width: 18, height: 18)
            UIDrawing.fill(badge, color: UITheme.redFace, radius: 9)
            UIDrawing.text("!", in: badge, size: 12, color: .white, weight: .bold, centered: true)
            (controller.message as NSString).draw(in: CGRect(x: box.minX + 40, y: box.minY + 10, width: box.width - 54, height: box.height - 20),
                withAttributes: [.font: font, .foregroundColor: UITheme.text, .paragraphStyle: paragraph])
        }
    }
    private func divider(_ x: CGFloat) {
        NSColor.white.withAlphaComponent(0.14).setFill(); CGRect(x: x, y: 10, width: 1, height: 20).fill()
    }
}

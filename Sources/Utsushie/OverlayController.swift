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
    var displayedLast: CGRect? {
        state.gesture.isSelectingArea ? nil : state.gesture.lastPreview ?? last
    }
    private(set) var highlighted: CaptureRequest?
    private(set) var highlightedApp = ""
    var config = UtsushieConfig()
    private var windowContent: SCShareableContent?
    private var contentTask: Task<Void, Never>?
    private(set) var message = ""
    private var panels: [CapturePanel] = []
    private var keyMonitor: Any?
    private var registeredCursor: CaptureCursor?
    var cursor: NSCursor { state.cursor == .crosshair ? .crosshair : .arrow }
    var onCapture: ((CaptureRequest, Bool, CaptureOutput) -> Void)?
    var onMoveLast: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onAccessibilityNeeded: (() -> Void)?
    var isVisible: Bool { !panels.isEmpty }

    init(state: CaptureState = CaptureState()) { self.state = state }

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
            // くり抜きの完全透明な画素でも、下のウィンドウへマウス入力を通さない。
            panel.ignoresMouseEvents = false
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
            guard modifiers.isEmpty, [UInt16(53), 48, 8, 36, 76].contains(event.keyCode) else { return event }
            if !event.isARepeat { self.key(event.keyCode) }
            return nil
        }
        updateWindow(); redraw()
    }
    func close() {
        contentTask?.cancel(); contentTask = nil; windowContent = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        registeredCursor = nil
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
    func mouseMoved() {
        guard isVisible else { return }
        // cursorUpdateとカーソル矩形はキーウィンドウで有効になる。
        // 別画面へ移ったら非アクティブのまま受け手を移す。ドラッグの配送先は変えない。
        if NSEvent.pressedMouseButtons & 1 == 0,
           let panel = panels.first(where: { $0.frame.contains(NSEvent.mouseLocation) }), !panel.isKeyWindow {
            panel.makeKey()
            if let view = panel.contentView { panel.makeFirstResponder(view) }
        }
        updateWindow(); redraw()
    }
    func updateCursor() {
        guard isVisible else { return }
        cursor.set()
    }
    private func updateWindow() {
        guard isVisible, state.highlightsWindow else { highlighted = nil; highlightedApp = ""; return }
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
    func mouseDown(movingLast: Bool = false) {
        guard isVisible else { return }
        performPointer(state.pointerDown(at: NSEvent.mouseLocation, last: last, movingLast: movingLast))
    }
    func mouseDragged() {
        guard isVisible else { return }
        state.pointerDragged(to: NSEvent.mouseLocation)
        updateWindow(); redraw()
    }
    func mouseUp() {
        guard isVisible else { return }
        updateWindow()
        performPointer(state.pointerUp(at: NSEvent.mouseLocation, hasWindow: highlighted != nil))
    }
    private func performPointer(_ action: PointerAction) {
        switch action {
        case .none: break
        case .captureWindow:
            if let highlighted { onCapture?(highlighted, false, state.output) }
        case let .captureArea(rect): onCapture?(.region(rect), true, state.output)
        case let .moveLast(rect):
            if CaptureGeometry.isVisible(rect, displays: ScreenGeometry.displays) {
                last = rect; onMoveLast?(rect)
            } else { message = "前回範囲を画面内へ移動してください" }
            // 移動中はプレビューだけを変え、離したときに確定する。Escでは保存しない。
        }
        updateWindow(); redraw()
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
    private func redraw() {
        if registeredCursor != state.cursor {
            registeredCursor = state.cursor
            for panel in panels {
                if let view = panel.contentView { panel.invalidateCursorRects(for: view) }
            }
        }
        updateCursor()
        panels.forEach { $0.contentView?.needsDisplay = true }
    }
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
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self))
        // activeAlwaysとの組合せではcursorUpdateは届かない。移動の追跡とは分ける。
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        guard let controller, controller.isVisible else { return }
        addCursorRect(visibleRect, cursor: controller.cursor)
    }
    override func cursorUpdate(with event: NSEvent) { controller?.updateCursor() }
    override func mouseEntered(with event: NSEvent) { controller?.mouseMoved() }
    override func mouseDown(with event: NSEvent) { controller?.mouseDown(movingLast: event.modifierFlags.contains(.option)) }
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
            UITheme.ink.setStroke(); outline.stroke()
            outline.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.85).setStroke(); outline.stroke()
            label("前回 ⏎", at: CGPoint(x: rect.minX + 8, y: rect.maxY - 30))
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
        let widths = items.map { item in
            ToolbarDrawing.itemWidth(title: item.title, key: item.key, recording: item.recording, face: item.title == "やめる" ? .secondary : .tool)
        }
        let layout = OverlayToolbarLayout(itemWidths: widths, tabWidth: ToolbarDrawing.keyWidth("Tab"))
        let stripWidth = layout.width
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
        ToolbarDrawing.tray(layout.outputTray)
        ToolbarDrawing.tray(layout.targetTray)
        ToolbarDrawing.key("Tab", in: layout.tab)
        for (index, item) in items.enumerated() {
            ToolbarDrawing.item(title: item.title, key: item.key, in: layout.items[index],
                style: item.title == "やめる" ? .secondary : .tool, selected: item.selected, recording: item.recording, dimmed: !item.enabled)
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
}

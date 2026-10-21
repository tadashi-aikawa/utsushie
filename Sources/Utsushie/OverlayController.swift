import AppKit
import ScreenCaptureKit
import UtsushieCore

@MainActor
final class CapturePanel: NSPanel, CaptureExcludedWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// 止めた画面はcontentViewのlayerへ置き、選択の表示はその上の子ビューへ描く。
    var overlayView: OverlayView?
}

@MainActor
final class OverlayController {
    private(set) var state = CaptureState()
    /// 画像の撮影だけに使う。動画・要素選択へ切り替えたら今の画面へ戻し、その回は止め直さない。
    private(set) var frozen: [FrozenDisplay]?
    private(set) var last: CGRect?
    var selection: CGRect? { state.target == .element ? nil : state.gesture.areaPreview }
    var displayedLast: CGRect? {
        state.gesture.isSelectingArea ? nil : state.gesture.lastPreview ?? last
    }
    private(set) var highlighted: CaptureRequest?
    private(set) var highlightedApp = ""
    private(set) var highlightedDisplay = false
    var config = UtsushieConfig()
    private var windowContent: SCShareableContent?
    private var contentTask: Task<Void, Never>?
    private(set) var message = ""
    private var panels: [CapturePanel] = []
    private var keyMonitor: Any?
    private var registeredCursor: CaptureCursor?
    private let elementReader = AccessibilityElementReader()
    private var elementTask: Task<Void, Never>?
    private var elementGeneration = 0
    private var elementQuery: AccessibilityElementReader.Query?
    private var elementSelection = ElementSelection()
    private var elementClick: (element: CaptureElement, query: AccessibilityElementReader.Query)?
    private var confirmingElement = false
    private(set) var elementHint = ""
    private let elementHelp = "⏎ クリックで撮影 · ↑ 親へ · ↓ 戻る · Eで要素選択を終了"
    var cursor: NSCursor { state.cursor == .crosshair ? .crosshair : .arrow }
    var onCapture: ((CaptureRequest, Bool, CaptureOutput) -> Void)?
    var onMoveLast: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onAccessibilityNeeded: (() -> Void)?
    var isVisible: Bool { !panels.isEmpty }

    init(state: CaptureState = CaptureState()) { self.state = state }

    func show(last: CGRect?, frozen: [FrozenDisplay]? = nil) {
        close()
        state = CaptureState(audio: config.video.audio)
        state.modifiersChanged(shift: NSEvent.modifierFlags.contains(.shift))
        self.last = last
        self.frozen = frozen
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
            panel.animationBehavior = .none
            // 止めた画面と選択の幕を同じ窓で1度に出す。別の窓に分けると、幕の下で今の画面が動いてから止めた画面へ戻って見える。
            let container = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
            container.wantsLayer = true
            if let display = frozen?.first(where: { $0.geometry.frame == screen.frame }) {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                container.layer?.contents = display.image
                container.layer?.contentsGravity = .resize
                container.layer?.contentsScale = display.geometry.scale
                CATransaction.commit()
            }
            let view = OverlayView(frame: container.bounds)
            view.autoresizingMask = [.width, .height]
            view.controller = self; view.screenFrame = screen.frame
            container.addSubview(view)
            panel.contentView = container
            panel.overlayView = view
            panels.append(panel)
            panel.orderFrontRegardless()
        }
        let underMouse = panels.first { $0.frame.contains(NSEvent.mouseLocation) } ?? panels.first
        underMouse?.makeKey()
        if let view = underMouse?.overlayView { underMouse?.makeFirstResponder(view) }
        // local monitorはIMEへ渡る前のkeyDownを受け取る。charactersは読まない。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let arrows = self.state.target == .element && [125, 126].contains(event.keyCode)
            guard modifiers.isEmpty, arrows || self.state.handles(event.keyCode) else {
                if self.confirmingElement { self.clearElements(); self.updateWindow(); self.redraw() }
                return event
            }
            if !event.isARepeat { self.key(event.keyCode) }
            return nil
        }
        updateWindow(); redraw()
    }
    func close() {
        clearElements(); elementClick = nil; elementHint = ""
        contentTask?.cancel(); contentTask = nil; windowContent = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        frozen = nil
        registeredCursor = nil
        state.cancelGesture(); highlighted = nil; highlightedApp = ""; highlightedDisplay = false
        NSCursor.arrow.set()
    }
    private func unfreeze() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        panels.forEach { $0.contentView?.layer?.contents = nil }
        CATransaction.commit()
        frozen = nil
    }
    func repeatCapture() {
        elementClick = nil; clearElements()
        perform(state.repeatCapture(hasLast: last != nil))
        updateWindow(); redraw()
    }
    private func key(_ code: UInt16) {
        message = ""
        // 音と解像度の切り替えは要素の候補や取得中の確認を保つ。
        if code == 0 || code == 15 { _ = state.key(code, hasLast: last != nil); redraw(); return }
        elementClick = nil
        if state.target == .element, code == 36 || code == 76 {
            state.cancelGesture()
            // 取得中や候補なしのEnterで、見えていない前回範囲を撮らない。
            guard elementTask == nil, highlighted != nil,
                  let selected = elementSelection.selected, let query = elementQuery else { return }
            captureElement((selected, query))
            return
        }
        if state.target == .element, code == 125 || code == 126 {
            state.cancelGesture()
            if elementTask != nil { clearElements(); updateWindow(); redraw(); return }
            if code == 126 { elementSelection.selectParent() } else { elementSelection.selectChild() }
            if let selected = elementSelection.selected, let query = elementQuery, !selected.rect.contains(query.point) {
                clearElements(); updateWindow(); redraw(); return
            }
            displayElement(); redraw()
            return
        }
        if code == 14, state.target != .element, !AXIsProcessTrusted() {
            message = "要素選択にはアクセシビリティの許可が必要です。Escで閉じ、システム設定で許可してください"
            onAccessibilityNeeded?(); redraw()
            return
        }
        clearElements()
        perform(state.key(code, hasLast: last != nil))
        // 録画と要素選択は今の画面を撮る・読む。止めた絵と食い違う枠を出さない。
        if state.output == .video || state.target == .element, frozen != nil { unfreeze() }
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
        // flagsChangedを取りこぼしても、移動・別画面への進入で現在の⇧状態へ戻す。
        state.modifiersChanged(shift: NSEvent.modifierFlags.contains(.shift))
        // cursorUpdateとカーソル矩形はキーウィンドウで有効になる。
        // 別画面へ移ったら非アクティブのまま受け手を移す。ドラッグの配送先は変えない。
        if NSEvent.pressedMouseButtons & 1 == 0,
           let panel = panels.first(where: { $0.frame.contains(NSEvent.mouseLocation) }), !panel.isKeyWindow {
            panel.makeKey()
            if let view = panel.overlayView { panel.makeFirstResponder(view) }
        }
        updateWindow(); redraw()
    }
    func updateCursor() {
        guard isVisible else { return }
        cursor.set()
    }
    func flagsChanged(shift: Bool) {
        if confirmingElement { clearElements() }
        state.modifiersChanged(shift: shift)
        updateWindow(); redraw()
    }
    private func updateWindow(windowOnly: Bool = false) {
        // 離した後の手ぶれでは撮影を取り消さない。確定地点の窓は結果の受領時に検証する。
        if confirmingElement { return }
        let previousHighlight = highlighted
        let previousApp = highlightedApp
        let previousQuery = elementQuery
        highlighted = nil; highlightedApp = ""; highlightedDisplay = false
        elementHint = ""
        if state.target != .element { clearElements() }
        guard isVisible, !state.gesture.isDragging else { return }
        let point = NSEvent.mouseLocation
        if state.highlightsDisplay && !windowOnly {
            clearElements()
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
                highlighted = .region(screen.frame)
                highlightedApp = screen.localizedName
                highlightedDisplay = true
            }
            return
        }
        guard let window = windowUnderPointer() else {
            clearElements()
            if state.target == .element { elementHint = "アプリのウィンドウへカーソルを移動 · Eで戻る" }
            return
        }
        if state.target == .element {
            guard let query = elementQuery(for: window) else {
                clearElements()
                elementHint = "この場所の要素は取得できません · Eで戻る"
                return
            }
            // 同じ窓・可視範囲の取得待ちだけ、表示を残す。選択候補はupdateElementで別に破棄する。
            if let previousQuery, query.hasSameContext(as: previousQuery) {
                highlighted = previousHighlight
                highlightedApp = previousApp
            }
            updateElement(query)
            return
        }
        highlighted = .window(window.id, ScreenGeometry.appKit(window.bounds))
        highlightedApp = window.name
        if windowContent?.windows.first(where: { $0.windowID == window.id })?.frame != window.bounds { refreshWindowContent() }
    }

    private struct PointerWindow {
        let id: UInt32
        let processID: Int32
        let bounds: CGRect
        let name: String
        let occludingBounds: [CGRect]
    }
    private func windowUnderPointer(at point: CGPoint? = nil) -> PointerWindow? {
        let point = point ?? NSEvent.mouseLocation
        let selectingElement = state.target == .element
        let policy = CaptureWindowExclusion.policy(for: CaptureWindowExclusion.windows())
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var occludingBounds: [CGRect] = []
        for item in list {
            guard let id = item[kCGWindowNumber as String] as? UInt32,
                  let layer = item[kCGWindowLayer as String] as? Int,
                  !policy.excludes(windowID: id), (item[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = item[kCGWindowBounds as String] as? [String: Any],
                  let cgRect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            let selectable = policy.canSelect(windowID: id, processID: item[kCGWindowOwnerPID as String] as? Int32,
                                              layer: layer, alpha: 1)
            let rect = ScreenGeometry.appKit(cgRect)
            if rect.contains(point), selectable || selectingElement {
                // 通常の窓選択では無視するPiP等も、要素撮影では背後を撮らないため遮蔽物として扱う。
                guard selectable else { return nil }
                guard let pid = item[kCGWindowOwnerPID as String] as? Int32 else { return nil }
                return PointerWindow(id: id, processID: pid, bounds: cgRect,
                    name: item[kCGWindowOwnerName as String] as? String ?? "ウィンドウ",
                    occludingBounds: occludingBounds.filter { $0.intersects(cgRect) }.sorted {
                        if $0.minX != $1.minX { return $0.minX < $1.minX }
                        if $0.minY != $1.minY { return $0.minY < $1.minY }
                        if $0.width != $1.width { return $0.width < $1.width }
                        return $0.height < $1.height
                    })
            }
            if selectingElement { occludingBounds.append(cgRect) }
        }
        return nil
    }

    private func elementQuery(for window: PointerWindow, at cgPoint: CGPoint? = nil) -> AccessibilityElementReader.Query? {
        guard AXIsProcessTrusted() else { return nil }
        let point = cgPoint ?? CGPoint(x: NSEvent.mouseLocation.x, y: ScreenGeometry.primaryHeight - NSEvent.mouseLocation.y)
        let appKitPoint = CGPoint(x: point.x, y: ScreenGeometry.primaryHeight - point.y)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(appKitPoint) }) else { return nil }
        return .init(point: point, windowID: window.id, processID: window.processID, windowBounds: window.bounds,
                     visibleBounds: window.bounds.intersection(ScreenGeometry.cg(screen.frame)), occludingBounds: window.occludingBounds)
    }
    private func clearElements() {
        confirmingElement = false
        elementGeneration += 1
        elementTask?.cancel(); elementTask = nil
        elementQuery = nil; elementSelection = ElementSelection()
    }
    private func displayElement() {
        highlighted = elementSelection.selected.map { .region(ScreenGeometry.appKit($0.rect)) }
        let appName = elementQuery.flatMap { NSRunningApplication(processIdentifier: $0.processID)?.localizedName } ?? "アプリ"
        highlightedApp = "\(appName) · \(elementSelection.selected?.label ?? "要素")"
        elementHint = elementSelection.selected == nil
            ? "この場所の要素は取得できません · Eで戻る"
            : elementHelp
    }
    private func updateElement(_ query: AccessibilityElementReader.Query) {
        // ↑で広げた後の持ち替えで葉へ戻さない。枠内だけ保持し、撮影時には必ずAXを再確認する。
        if elementSelection.canSelectChild, let previous = elementQuery,
           query.hasSameContext(as: previous), let selected = elementSelection.selected, selected.rect.contains(query.point) {
            elementQuery = query
            displayElement()
            return
        }
        if elementQuery == query {
            if elementTask == nil { displayElement() }
            else { elementHint = elementHelp }
            return
        }
        clearElements()
        elementQuery = query
        let generation = elementGeneration
        elementHint = elementHelp
        elementTask = Task { [weak self, elementReader] in
            // 高頻度のmouseMovedでAX要求を積まない。静止後の最新位置だけを問い合わせる。
            do { try await Task.sleep(for: .milliseconds(35)) } catch { return }
            let selection = await elementReader.selection(for: query)
            guard !Task.isCancelled, let self, self.isVisible, self.state.target == .element,
                  self.elementGeneration == generation, self.elementQuery == query else { return }
            self.elementTask = nil
            self.elementSelection = selection
            self.displayElement(); self.redraw()
        }
    }
    private func captureElement(_ click: (element: CaptureElement, query: AccessibilityElementReader.Query)) {
        guard let window = windowUnderPointer(), let query = elementQuery(for: window),
              query.windowID == click.query.windowID, query.processID == click.query.processID,
              click.element.rect.contains(query.point) else { updateWindow(); redraw(); return }
        clearElements()
        elementQuery = query
        let generation = elementGeneration
        highlighted = nil
        confirmingElement = true
        elementHint = elementHelp
        redraw()
        elementTask = Task { [weak self, elementReader] in
            let fresh = await elementReader.selection(for: query)
            guard !Task.isCancelled, let self, self.isVisible, self.state.target == .element,
                  self.elementGeneration == generation,
                  let currentWindow = self.windowUnderPointer(at: CGPoint(x: query.point.x, y: ScreenGeometry.primaryHeight - query.point.y)),
                  self.elementQuery(for: currentWindow, at: query.point) == query else {
                if let self, self.elementGeneration == generation {
                    self.clearElements(); self.updateWindow(); self.redraw()
                }
                return
            }
            self.elementTask = nil
            self.confirmingElement = false
            // ページ更新・スクロール後の古い枠で撮らない。親へ広げた選択も新しい祖先列と照合する。
            if let current = fresh.candidates.first(where: { ElementSelection.matches($0.rect, click.element.rect) }) {
                self.redraw()
                self.onCapture?(.region(ScreenGeometry.appKit(current.rect)), false, self.state.output)
            } else {
                self.elementSelection = fresh
                self.displayElement()
                self.elementHint = "要素が変わりました。枠を選び直してください · Eで戻る"
                self.redraw()
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
    func mouseDown(movingLast: Bool = false, selectingDisplay: Bool = false) {
        guard isVisible else { return }
        var click: (element: CaptureElement, query: AccessibilityElementReader.Query)?
        if state.target == .element,
           let selected = elementSelection.selected, let previous = elementQuery,
           let window = windowUnderPointer(), let query = elementQuery(for: window),
           query.windowID == previous.windowID, selected.rect.contains(query.point) {
            click = (selected, previous)
        }
        // 先のクリックの確認中に次の操作が来たら、その撮影を取り消す。
        if elementTask != nil { clearElements() }
        updateWindow()
        elementClick = click
        state.modifiersChanged(shift: selectingDisplay)
        performPointer(state.pointerDown(at: NSEvent.mouseLocation, last: last, movingLast: movingLast,
                                         displayFrames: ScreenGeometry.displays.map(\.frame), selectingDisplay: selectingDisplay))
    }
    func mouseDragged() {
        guard isVisible else { return }
        state.pointerDragged(to: NSEvent.mouseLocation)
        if state.target != .element { elementClick = nil }
        updateWindow(); redraw()
    }
    func mouseUp() {
        guard isVisible else { return }
        if state.target == .element {
            let click = elementClick; elementClick = nil
            let action = state.pointerUp(at: NSEvent.mouseLocation, hasWindow: click != nil)
            if action == .captureWindow, let click { captureElement(click) }
            else {
                if action == .none { clearElements() }
                performPointer(action)
            }
            return
        }
        // ⇧の表示状態と、mouseDownで決まったクリック対象を分ける。
        updateWindow(windowOnly: true)
        performPointer(state.pointerUp(at: NSEvent.mouseLocation, hasWindow: highlighted != nil))
    }
    private func performPointer(_ action: PointerAction) {
        switch action {
        case .none: break
        case .captureWindow:
            if let highlighted { onCapture?(highlighted, false, state.output) }
        case let .captureArea(rect): onCapture?(.region(rect), true, state.output)
        case let .captureDisplay(rect): onCapture?(.region(rect), false, state.output)
        case let .moveLast(rect):
            if CaptureGeometry.isVisible(rect, displays: ScreenGeometry.displays) {
                last = rect; onMoveLast?(rect)
            } else { message = "前回範囲を画面内へ移動してください" }
            // 移動中はプレビューだけを変え、離したときに確定する。Escでは保存しない。
        }
        updateWindow(); redraw()
    }
    func showError(_ error: Error) {
        message = error.localizedDescription; state.fallbackToArea(); clearElements(); redraw()
    }
    func dimensions(_ rect: CGRect, window: Bool = false) -> String {
        let downscale = state.effectiveDownscale(config: config)
        var points = rect.size
        var scale = CaptureGeometry.scale(for: rect, displays: ScreenGeometry.displays, downscale: downscale)
        // 止めた画面ではウィンドウも枠で切り出し、画面外の部分は切り詰める。保存と同じ計算にする。
        if window, let frozen, case .window = highlighted {
            let displays = frozen.map(\.geometry)
            let visible = CaptureGeometry.visibleBounds(rect, displays: displays) ?? rect
            points = visible.size; scale = CaptureGeometry.scale(for: visible, displays: displays, downscale: downscale)
        } else if window, case let .window(id, _) = highlighted,
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
                if let view = panel.overlayView { panel.invalidateCursorRects(for: view) }
            }
        }
        updateCursor()
        panels.forEach { $0.overlayView?.needsDisplay = true }
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
    override func flagsChanged(with event: NSEvent) { controller?.flagsChanged(shift: event.modifierFlags.contains(.shift)) }
    override func mouseDown(with event: NSEvent) {
        controller?.mouseDown(movingLast: event.modifierFlags.contains(.option), selectingDisplay: event.modifierFlags.contains(.shift))
    }
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
        if let rect = selected, !controller.highlightedDisplay || rect == screenFrame {
            let area = local(rect)
            let isDisplay = controller.highlightedDisplay
            UIDrawing.selection(area, video: controller.state.output == .video, inside: isDisplay)
            let isHighlighted = controller.selection == nil && controller.highlighted != nil
            let dimensions = controller.dimensions(rect, window: isHighlighted && !isDisplay)
            let title = isHighlighted ? "\(controller.highlightedApp) · \(dimensions)" : dimensions
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
        let audio = OverlayPresentation.audioItem(output: controller.state.output, audio: controller.state.audio)
        let resolution = OverlayPresentation.resolutionItem(downscale: controller.state.effectiveDownscale(config: controller.config))
        let layout = OverlayToolbarLayout(itemWidths: widths, tabWidth: ToolbarDrawing.keyWidth("Tab"),
            resolutionWidth: ToolbarDrawing.itemWidth(title: resolution.title, key: resolution.key, recording: false, face: .tool),
            audioWidth: audio.map { ToolbarDrawing.itemWidth(title: $0.title, key: $0.key, recording: false, face: .tool) })
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
        if let frame = layout.resolution {
            ToolbarDrawing.item(title: resolution.title, key: resolution.key, in: frame, style: .tool, selected: resolution.selected, recording: false, dimmed: false)
        }
        if let audio, let frame = layout.audio {
            ToolbarDrawing.item(title: audio.title, key: audio.key, in: frame, style: .tool, selected: audio.selected, recording: false, dimmed: false)
        }
        for (index, item) in items.enumerated() {
            ToolbarDrawing.item(title: item.title, key: item.key, in: layout.items[index],
                style: item.title == "やめる" ? .secondary : .tool, selected: item.selected, recording: item.recording, dimmed: !item.enabled)
        }
        NSGraphicsContext.restoreGraphicsState()
        if !controller.elementHint.isEmpty {
            label(controller.elementHint, at: CGPoint(x: max(visible.minX + 12, origin.x), y: origin.y + 50))
        }
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

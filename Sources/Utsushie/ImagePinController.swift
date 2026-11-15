import AppKit
import ImageIO
import OSLog
import UtsushieCore

/// ピンチの届き先の診断。ピンチのたびに出るのでdebugで残す。
let imagePinLog = Logger(subsystem: "com.tadashi-aikawa.utsushie", category: "ImagePin")

/// 撮った画像を最前面に浮かべるウィンドウの束。カードの寿命と別に、閉じるまで残す。
@MainActor
final class ImagePinController {
    private(set) var pins: [ImagePin] = []
    /// 録画中は、撮っているフィルターから外し終えてから出す。カードと同じ合図を使う。
    var beforeShowing: ((NSWindow) async -> Bool)?
    /// 撮影用UIのウィンドウが増えた。ウィンドウの一覧を取り直す合図にする。
    var onAdded: (() -> Void)?
    var loadImage: @Sendable (URL) throws -> CGImage = { try ImagePinController.decode($0) }
    /// クリックで前面にする。macOSは前面にないアプリへピンチを渡さないため。
    /// 非推奨APIだが、編集画面と同じく別アプリの協調に依存せず前面化を要求する。
    var activate: () -> Void = { if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) } }
    private var localMagnify: Any?
    private var globalMagnify: Any?

    /// カーソルの下で一番手前の浮かべた画像。台紙の上だけを数える。
    func pin(at point: CGPoint) -> ImagePin? {
        pins.last { !$0.closed && $0.panel.isVisible && $0.matFrame.contains(point) }
    }
    /// ピンチの届き先を記録し、前面の別のアプリへ届いたピンチも浮かべた画像で拾う。
    /// 前面にないアプリへのジェスチャーは、macOSが前面のアプリへ渡すことがあるため。
    private func watchMagnify() {
        guard localMagnify == nil else { return }
        localMagnify = NSEvent.addLocalMonitorForEvents(matching: .magnify) { event in
            MainActor.assumeIsolated {
                let target = event.window.map { String(describing: type(of: $0)) } ?? "nil"
                imagePinLog.debug("magnify local: window=\(target, privacy: .public) active=\(NSApp.isActive) phase=\(event.phase.rawValue)")
            }
            return event
        }
        globalMagnify = NSEvent.addGlobalMonitorForEvents(matching: .magnify) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let pin = self.pin(at: NSEvent.mouseLocation) else { return }
                let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
                imagePinLog.debug("magnify global over pin: frontmost=\(front, privacy: .public) phase=\(event.phase.rawValue)")
                pin.zoom(by: 1 + event.magnification, around: NSEvent.mouseLocation)
            }
        }
    }
    private func unwatchMagnify() {
        guard pins.isEmpty else { return }
        if let localMagnify { NSEvent.removeMonitor(localMagnify) }
        if let globalMagnify { NSEvent.removeMonitor(globalMagnify) }
        localMagnify = nil; globalMagnify = nil
    }

    /// 保存済みのファイルを読み直して浮かべる。注釈を入れた後の画像を出すため。
    func pin(url: URL, scale: Double?, anchor: CGRect?, screen: NSScreen?) async throws {
        let load = loadImage
        let image = try await Task.detached(priority: .userInitiated) { try load(url) }.value
        show(image, scale: scale, anchor: anchor, screen: screen)
    }
    @discardableResult
    func show(_ image: CGImage, scale: Double?, anchor: CGRect?, screen: NSScreen?) -> ImagePin {
        let natural = ImagePinGeometry.pointSize(pixels: CGSize(width: image.width, height: image.height), scale: scale)
        let target = anchor.flatMap { area in NSScreen.screens.first { $0.frame.contains(CGPoint(x: area.midX, y: area.midY)) } }
            ?? screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = target?.visibleFrame ?? CGRect(origin: .zero, size: natural)
        let pin = ImagePin(image: image, natural: natural,
                           frame: ImagePinGeometry.initialFrame(size: natural, anchor: anchor, visible: visible))
        pin.activate = activate
        pin.onClose = { [weak self, weak pin] in
            guard let self, let pin else { return }
            pins.removeAll { $0 === pin }
            unwatchMagnify()
        }
        pins.append(pin)
        watchMagnify()
        if let beforeShowing {
            Task { [weak pin] in
                guard let pin else { return }
                if await beforeShowing(pin.panel) { pin.show(); self.focus(pin) } else { pin.close() }
                self.onAdded?()
            }
        } else {
            pin.show(); focus(pin); onAdded?()
        }
        return pin
    }
    func closeAll() { pins.forEach { $0.close() } }
    /// 浮かべた直後に前面にしてキーにする。クリックせずにピンチ・Escを受けるため。
    /// 浮かべるのはカードと一覧のボタン・Pの操作だけなので、利用者の操作の続きとして前面を移す。
    private func focus(_ pin: ImagePin) {
        guard !pin.closed else { return }
        activate()
        pin.panel.makeKey()
    }

    nonisolated static func decode(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw CaptureError.unavailable("画像を読み込めませんでした")
        }
        return image
    }
}

@MainActor
final class ImagePin {
    let panel: ImagePinPanel
    let natural: CGSize
    var onClose: (() -> Void)?
    var activate: () -> Void = {}
    private let view: ImagePinView
    private(set) var closed = false

    /// 画像の枠。台紙と影はこの外側に描く。
    var imageFrame: CGRect { ImagePinGeometry.imageFrame(panel: panel.frame) }
    var matFrame: CGRect { imageFrame.insetBy(dx: -ImagePinGeometry.mat, dy: -ImagePinGeometry.mat) }

    init(image: CGImage, natural: CGSize, frame: CGRect) {
        self.natural = natural
        let frame = ImagePinGeometry.panelFrame(image: frame)
        // nonactivatingPanelにしない。クリックでアプリが前面になり、ピンチを受けられるようにする。
        // 出すときはorderFrontRegardlessだけなので、前面のアプリは奪わない。
        panel = ImagePinPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        // 影は台紙の外の余白へ自分で描く。ウィンドウの影は透明な余白の外形に付いてしまうため。
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        view = ImagePinView(frame: CGRect(origin: .zero, size: frame.size))
        view.image = NSImage(cgImage: image, size: natural)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        view.pin = self
    }
    func show() {
        guard !closed else { return }
        panel.orderFrontRegardless()
    }
    func close() {
        guard !closed else { return }
        closed = true
        panel.orderOut(nil); panel.close()
        onClose?(); onClose = nil
    }
    var opacity: Double { panel.alphaValue }
    func zoom(by factor: Double, around point: CGPoint) {
        let frame = ImagePinGeometry.zoomed(imageFrame, by: factor, around: point, natural: natural)
        guard frame != imageFrame else { return }
        panel.setFrame(ImagePinGeometry.panelFrame(image: frame), display: true)
        view.flash(ImagePinGeometry.zoomLabel(frame: frame, natural: natural))
    }
    func resetZoom() {
        let frame = ImagePinGeometry.actualSize(imageFrame, natural: natural)
        if frame != imageFrame { panel.setFrame(ImagePinGeometry.panelFrame(image: frame), display: true) }
        view.flash(ImagePinGeometry.zoomLabel(frame: frame, natural: natural))
    }
    func changeOpacity(scrollDelta: Double, precise: Bool) {
        let value = ImagePinGeometry.opacity(panel.alphaValue, scrollDelta: scrollDelta, precise: precise)
        guard value != panel.alphaValue else { return }
        panel.alphaValue = value
        view.flash(ImagePinGeometry.opacityLabel(value))
    }
}

/// 撮影用UIとして撮影から外す。出すときは前面のアプリを奪わず、クリックで前面にしてキーになる。
@MainActor
final class ImagePinPanel: NSPanel, CaptureExcludedWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ImagePinView: NSView {
    weak var pin: ImagePin?
    var image: NSImage?
    private(set) var hovered = false
    private var pressedClose = false
    private(set) var label: String?
    private var labelTimer: Timer?

    /// 影・ピン・縁の見た目。
    @MainActor enum Style {
        /// 影を落とす下地。台紙は置かないので画像に隠れる。
        static let paper = NSColor.white
        static let edge = NSColor.clear
        /// 白い縁の画像が白い背景に溶けないよう、注釈の余白と同じ黒14%の線を画像の外側へ引く。
        static let imageEdge = NSColor.black.withAlphaComponent(0.14)
        /// 暗い背景では影も黒の線も沈むので、その外へ白18%の線を引く。ダークモードのウィンドウの縁と同じ考え方。
        /// 明るい背景では見えず、黒の線だけが効く。
        static let darkEdge = NSColor.white.withAlphaComponent(0.18)
        /// 影は2重。遠くへ大きく落とす影で浮いている高さを、縁に沿った締まった影で輪郭を見せる。
        /// ビューは上下を反転しているので、正の高さで下へ落ちる。
        static let shadows: [(color: NSColor, offset: CGSize, blur: CGFloat)] = [
            (NSColor.black.withAlphaComponent(0.5), CGSize(width: 0, height: 10), 28),
            (NSColor.black.withAlphaComponent(0.35), CGSize(width: 0, height: 1), 3),
        ]
        static let pin = ImagePinLook.orange
    }
    /// 台紙と外縁の色。見た目の案を差し替えて描けるよう、ビューごとに持つ。
    var paper: NSColor = Style.paper { didSet { needsDisplay = true } }
    var edgeColor: NSColor = Style.edge { didSet { needsDisplay = true } }
    var edgeWidth: CGFloat = 1 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// ビュー座標の画像の枠。外側に台紙と影の余白がある。
    var imageRect: CGRect {
        let inset = ImagePinGeometry.mat + ImagePinGeometry.shadowMargin
        return bounds.insetBy(dx: inset, dy: inset)
    }
    var matRect: CGRect { imageRect.insetBy(dx: -ImagePinGeometry.mat, dy: -ImagePinGeometry.mat) }
    var closeRect: CGRect {
        ImagePinGeometry.closeButton(in: imageRect.size).offsetBy(dx: imageRect.minX, dy: imageRect.minY)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // 影の余白ではホバーにしない。台紙の上だけで×と手のカーソルを出す。
        addTrackingArea(NSTrackingArea(rect: matRect, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self))
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize); updateTrackingAreas(); window?.invalidateCursorRects(for: self)
    }
    /// どこを持っても動かせるので開いた手にする。前回枠やズームの枠の移動と同じ手。押すボタンの×だけ矢印。
    func cursor(at point: CGPoint) -> NSCursor? {
        guard matRect.contains(point) else { return nil }
        return hovered && closeRect.contains(point) ? .arrow : .openHand
    }
    override func resetCursorRects() {
        addCursorRect(matRect, cursor: .openHand)
        if hovered { addCursorRect(closeRect, cursor: .arrow) }
    }
    // カーソル矩形はキーウィンドウでしか効かない。前面でないときもホバーで決め直す。
    private func updateCursor(_ event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil))?.set()
    }
    override func mouseEntered(with event: NSEvent) {
        hovered = true; needsDisplay = true; window?.invalidateCursorRects(for: self); updateCursor(event)
    }
    override func mouseMoved(with event: NSEvent) { updateCursor(event) }
    override func mouseExited(with event: NSEvent) {
        hovered = false; needsDisplay = true; window?.invalidateCursorRects(for: self); NSCursor.arrow.set()
    }
    override func mouseDown(with event: NSEvent) {
        let wasActive = NSApp.isActive
        pin?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            imagePinLog.debug("pin clicked: activeBefore=\(wasActive) activeAfter=\(NSApp.isActive)")
        }
        window?.makeKey(); window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if hovered && closeRect.contains(point) { pressedClose = true; return }
        // つかんでいる間は握った手。performDragはドラッグが終わるまで戻らない。
        NSCursor.closedHand.push()
        window?.performDrag(with: event)
        NSCursor.pop()
        updateCursor(event)
    }
    override func mouseUp(with event: NSEvent) {
        defer { pressedClose = false }
        guard pressedClose else { return }
        if closeRect.contains(convert(event.locationInWindow, from: nil)) { pin?.close() }
    }
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.isEmpty && event.keyCode == 53 { if !event.isARepeat { pin?.close() }; return } // Esc
        // 編集画面の⌘0と同じキーで、浮かべた画像では倍率を100%へ戻す。
        if modifiers == .command && event.keyCode == 29 { if !event.isARepeat { pin?.resetZoom() }; return } // ⌘0
        super.keyDown(with: event)
    }
    override func cancelOperation(_ sender: Any?) { pin?.close() }
    override func magnify(with event: NSEvent) {
        pin?.zoom(by: 1 + event.magnification, around: NSEvent.mouseLocation)
    }
    override func scrollWheel(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let delta = Double(event.scrollingDeltaY)
        switch modifiers {
        case .command: pin?.zoom(by: ImagePinGeometry.zoomFactor(scrollDelta: delta, precise: event.hasPreciseScrollingDeltas), around: NSEvent.mouseLocation)
        case .option: pin?.changeOpacity(scrollDelta: delta, precise: event.hasPreciseScrollingDeltas)
        default: super.scrollWheel(with: event)
        }
    }
    /// 変えた値を左下へ1秒だけ出す。
    func flash(_ text: String) {
        label = text; needsDisplay = true
        labelTimer?.invalidate()
        labelTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.label = nil; self?.needsDisplay = true }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        // 枠で囲わず、強い影で画像そのものを浮かせる。元の画面に枠線を足しただけに見えないため。
        let mat = matRect
        for layer in Style.shadows {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = layer.color; shadow.shadowOffset = layer.offset; shadow.shadowBlurRadius = layer.blur
            shadow.set()
            paper.setFill(); mat.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        image?.draw(in: imageRect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        let imageEdge = NSBezierPath(rect: imageRect.insetBy(dx: -0.5, dy: -0.5))
        imageEdge.lineWidth = 1; Style.imageEdge.setStroke(); imageEdge.stroke()
        let darkEdge = NSBezierPath(rect: imageRect.insetBy(dx: -1.5, dy: -1.5))
        darkEdge.lineWidth = 1; Style.darkEdge.setStroke(); darkEdge.stroke()
        let edge = NSBezierPath(rect: mat.insetBy(dx: edgeWidth / 2, dy: edgeWidth / 2))
        edge.lineWidth = edgeWidth; edgeColor.setStroke(); edge.stroke()
        // 針の先を画像の上端から3pt内側に刺す。頭は上の透明な余白へ出る。
        drawPin(tip: CGPoint(x: mat.midX, y: mat.minY + 3))
        if hovered {
            let button = closeRect
            UITheme.ink.withAlphaComponent(0.85).setFill(); NSBezierPath(ovalIn: button).fill()
            let mark = NSBezierPath(), inset = button.width * 0.32
            mark.move(to: CGPoint(x: button.minX + inset, y: button.minY + inset)); mark.line(to: CGPoint(x: button.maxX - inset, y: button.maxY - inset))
            mark.move(to: CGPoint(x: button.maxX - inset, y: button.minY + inset)); mark.line(to: CGPoint(x: button.minX + inset, y: button.maxY - inset))
            mark.lineWidth = 1.6; mark.lineCapStyle = .round; NSColor.white.setStroke(); mark.stroke()
        }
        if let label {
            let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
            let area = imageRect
            let width = min(area.width - 12, ceil((label as NSString).size(withAttributes: [.font: font]).width) + 14)
            let chip = CGRect(x: area.minX + 6, y: area.maxY - 26, width: max(0, width), height: 20)
            UIDrawing.fill(chip, color: UITheme.ink.withAlphaComponent(0.85), radius: 5)
            UIDrawing.text(label, in: CGRect(x: chip.minX + 7, y: chip.minY + 2, width: max(0, chip.width - 14), height: 16),
                           size: 11.5, color: .white, weight: .semibold)
        }
    }
    /// 台紙の上辺に刺した押しピン。頭(つまみ・くびれ・つば)と灰の針を分けて塗り、1色の記号に見せない。
    /// `tip`は針の先。頭は時計回りに傾けて右上へ出し、紙のすぐ上に立つ硬い影を落とす。
    private func drawPin(tip: CGPoint) {
        let look = Style.pin
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: tip.x, y: tip.y)
        // ビューは上下を反転しているので、正の角度で時計回りになる。
        context.rotate(by: look.angle * .pi / 180)
        // 形は22ptで組み、lengthまで拡大する。影はCTMの影響を受けないので値のまま効く。
        context.scaleBy(x: look.length / 22, y: look.length / 22)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.shadowOffset = CGSize(width: 3, height: 3); shadow.shadowBlurRadius = 3
        shadow.set()
        // 影を部品ごとに重ねないよう、ピン全体を1枚にまとめてから影を落とす。
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        let needle = NSBezierPath(); needle.move(to: CGPoint(x: 0, y: 0)); needle.line(to: CGPoint(x: 0, y: -10))
        needle.lineWidth = 1.5; needle.lineCapStyle = .round; UITheme.muted.setStroke(); needle.stroke()
        let flange = NSBezierPath(roundedRect: CGRect(x: -5, y: -12, width: 10, height: 2.5), xRadius: 1.2, yRadius: 1.2)
        let waist = NSBezierPath(rect: CGRect(x: -2.4, y: -15.5, width: 4.8, height: 4))
        let knob = NSBezierPath(roundedRect: CGRect(x: -4.5, y: -22, width: 9, height: 7), xRadius: 3.5, yRadius: 3.5)
        let head = NSBezierPath(); head.append(flange); head.append(waist); head.append(knob)
        look.head.setFill(); head.fill()
        if let edge = look.edge {
            head.lineWidth = edge.width; edge.color.setStroke(); head.stroke()
        }
        // つまみの上の面だけ1段明るくする。光沢のグラデーションにはしない。
        NSGraphicsContext.saveGraphicsState()
        knob.addClip()
        NSColor.white.withAlphaComponent(look.highlight).setFill()
        CGRect(x: -4.5, y: -22, width: 9, height: 3).fill()
        NSGraphicsContext.restoreGraphicsState()
        context.endTransparencyLayer()
        context.restoreGState()
    }
}

/// 押しピンの見た目。頭の色・縁・明るい面・傾き。
struct ImagePinLook: Sendable {
    var head: NSColor
    var edge: (color: NSColor, width: CGFloat)?
    var highlight: CGFloat = 0.25
    var angle: CGFloat = 30
    /// 針の先から頭の端まで。22ptでは控えめで目立たなかったため大きくした。
    var length: CGFloat = 30

    /// 橙の頭。注釈のインクの橙を流用し、色の約束に当たらない。墨は暗い画像の上で沈み、地味だったため。
    static let orange = ImagePinLook(head: NSColor(srgbRed: 0xF0 / 255, green: 0x8A / 255, blue: 0x24 / 255, alpha: 1))
}

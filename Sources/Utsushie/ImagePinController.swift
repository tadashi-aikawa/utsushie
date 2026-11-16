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
    /// ピンが刺さり影が浮き出る演出を付けるか。視差効果を減らす設定では、止まった見た目でその場に出す。
    var animatesEntrance: () -> Bool = { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
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
        pin.animatesEntrance = animatesEntrance()
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
    var animatesEntrance = true
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
        if animatesEntrance { view.beginEntrance() }
        panel.orderFrontRegardless()
    }
    func close() {
        guard !closed else { return }
        closed = true
        view.endEntrance()
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

/// 浮かべた画像。下から影、画像、縁・ピン・×・値のバッジの3枚に分けて重ねる。
/// 出てくる演出で画像が膨らむ間は、大きい画像を毎回描き直すと間に合わないので、画像のビューの層を引き伸ばす。
@MainActor
final class ImagePinView: NSView {
    weak var pin: ImagePin?
    var image: NSImage? { didSet { imageView.image = image } }
    private(set) var hovered = false
    private var pressedClose = false
    private(set) var label: String?
    private var labelTimer: Timer?
    /// 出してからの秒数。演出の間だけ値を持ち、止まった見た目ではnil。
    var entranceTime: Double? { didSet { layoutParts(); redraw() } }
    private var entranceLink: CADisplayLink?
    private var entranceStart: CFTimeInterval?
    private var entranceDeadline: Task<Void, Never>?
    private let imageView = ImagePinImageView()
    private let overlay = ImagePinOverlayView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(imageView)
        overlay.owner = self
        addSubview(overlay)
        layoutParts()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

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
    var paper: NSColor = Style.paper { didSet { redraw() } }
    var edgeColor: NSColor = Style.edge { didSet { redraw() } }
    var edgeWidth: CGFloat = 1 { didSet { redraw() } }
    /// 影と、縁・ピン・×・値のバッジを描き直す。画像は寸法が変わったときだけ描き直す。
    private func redraw() { needsDisplay = true; overlay.needsDisplay = true }
    /// 今の見た目。演出の外では止まった見た目。
    var entrance: ImagePinEntrance.Frame { entranceTime.map(ImagePinEntrance.frame(at:)) ?? .rest }
    /// 演出で膨らんだ画像の枠。中心を保つ。
    var shownImageRect: CGRect {
        let swell = CGFloat(entrance.imageScale), base = imageRect
        return base.insetBy(dx: -base.width * (swell - 1) / 2, dy: -base.height * (swell - 1) / 2)
    }
    private func layoutParts() {
        overlay.frame = bounds
        let rest = imageRect, shown = shownImageRect
        // 止まった寸法が変わったときだけ描き直す。膨らむ間は描いた中身を層で引き伸ばす。
        if imageView.restSize != rest.size { imageView.restSize = rest.size; imageView.needsDisplay = true }
        imageView.frame = shown
    }
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
        super.setFrameSize(newSize); layoutParts(); updateTrackingAreas(); window?.invalidateCursorRects(for: self)
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
        hovered = true; redraw(); window?.invalidateCursorRects(for: self); updateCursor(event)
    }
    override func mouseMoved(with event: NSEvent) { updateCursor(event) }
    override func mouseExited(with event: NSEvent) {
        hovered = false; redraw(); window?.invalidateCursorRects(for: self); NSCursor.arrow.set()
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
    /// ピンが手前から刺さり、影が浮き出る演出を始める。画面の更新ごとに描き直す。
    func beginEntrance() {
        endEntrance()
        entranceTime = 0
        let link = displayLink(target: self, selector: #selector(stepEntrance(_:)))
        link.add(to: .main, forMode: .common)
        entranceLink = link
        // 画面の更新が届かなくても、止まった見た目へ必ず戻す。ピンと影が出ないまま残らないため。
        entranceDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ImagePinEntrance.duration + 0.5))
            guard !Task.isCancelled else { return }
            self?.endEntrance()
        }
    }
    @objc private func stepEntrance(_ link: CADisplayLink) {
        let start = entranceStart ?? link.timestamp
        entranceStart = start
        let time = link.targetTimestamp - start
        if time >= ImagePinEntrance.duration { endEntrance() } else { entranceTime = time }
    }
    func endEntrance() {
        entranceLink?.invalidate(); entranceLink = nil
        entranceDeadline?.cancel(); entranceDeadline = nil
        entranceStart = nil
        if entranceTime != nil { entranceTime = nil }
    }
    /// 変えた値を左下へ1秒だけ出す。
    func flash(_ text: String) {
        label = text; redraw()
        labelTimer?.invalidate()
        labelTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.label = nil; self?.redraw() }
        }
    }
    /// 一番下の影。画像は上の画像のビューが描く。
    override func draw(_ dirtyRect: NSRect) {
        let entrance = entrance
        let mat = shownImageRect.insetBy(dx: -ImagePinGeometry.mat, dy: -ImagePinGeometry.mat)
        let lift = CGFloat(entrance.lift)
        // 枠で囲わず、強い影で画像そのものを浮かせる。元の画面に枠線を足しただけに見えないため。
        // 出てくるときは、画面にくっついた細く薄い影から、下へずれながらぼけて広がる。
        if lift > 0 {
            for layer in Style.shadows {
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = layer.color.withAlphaComponent(layer.color.alphaComponent * (0.2 + 0.8 * lift))
                shadow.shadowOffset = CGSize(width: layer.offset.width * lift, height: layer.offset.height * lift)
                shadow.shadowBlurRadius = layer.blur * lift
                shadow.set()
                paper.setFill(); mat.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            // 画像の下は抜いておく。透明な部分のある画像で、影を落とすための下地を透かさないため。
            shownImageRect.fill(using: .clear)
        }
    }
    /// 画像の上に重ねる縁・ピン・×・値のバッジ。
    func drawOverlay() {
        let entrance = entrance
        let shown = shownImageRect
        let mat = shown.insetBy(dx: -ImagePinGeometry.mat, dy: -ImagePinGeometry.mat)
        let lift = CGFloat(entrance.lift)
        let imageEdge = NSBezierPath(rect: shown.insetBy(dx: -0.5, dy: -0.5))
        imageEdge.lineWidth = 1; Style.imageEdge.withAlphaComponent(Style.imageEdge.alphaComponent * lift).setStroke(); imageEdge.stroke()
        let darkEdge = NSBezierPath(rect: shown.insetBy(dx: -1.5, dy: -1.5))
        darkEdge.lineWidth = 1; Style.darkEdge.withAlphaComponent(Style.darkEdge.alphaComponent * lift).setStroke(); darkEdge.stroke()
        let edge = NSBezierPath(rect: mat.insetBy(dx: edgeWidth / 2, dy: edgeWidth / 2))
        edge.lineWidth = edgeWidth; edgeColor.withAlphaComponent(edgeColor.alphaComponent * lift).setStroke(); edge.stroke()
        // 針の先を画像の上端から3pt内側に刺す。頭は上の透明な余白へ出る。
        drawPin(tip: CGPoint(x: mat.midX, y: mat.minY + 3), entrance: entrance)
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
    /// 出てくるときは針の先を中心に手前で大きく、影は遠く薄く落とし、刺さるにつれて止まったときの影へ寄せる。
    private func drawPin(tip: CGPoint, entrance: ImagePinEntrance.Frame = .rest) {
        let look = Style.pin
        guard entrance.pinOpacity > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // 透明レイヤーは切り抜きの大きさで作られる。大きい画像で毎コマ全体を合成すると重いので、ピンと影の周りへ絞る。
        let reach = 40 * look.length / 22 * entrance.pinScale + 30
        context.clip(to: CGRect(x: tip.x - reach, y: tip.y - reach, width: reach * 2, height: reach * 2))
        context.setAlpha(entrance.pinOpacity)
        context.translateBy(x: tip.x, y: tip.y)
        // ビューは上下を反転しているので、正の角度で時計回りになる。
        context.rotate(by: look.angle * .pi / 180)
        // 形は22ptで組み、lengthまで拡大する。影はCTMの影響を受けないので値のまま効く。
        let scale = look.length / 22 * entrance.pinScale
        context.scaleBy(x: scale, y: scale)
        let near = CGFloat(entrance.pinNear), far = 1 - near
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35 * near + 0.12 * far)
        shadow.shadowOffset = CGSize(width: 3 * near + 14 * far, height: 3 * near + 18 * far)
        shadow.shadowBlurRadius = 3 * near + 9 * far
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

/// 浮かべた画像そのもの。止まった寸法で1回描き、演出で膨らむ間は描き直さずに層の中身を引き伸ばす。
@MainActor
final class ImagePinImageView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    /// 描いた寸法。これが変わったときだけ描き直す。
    var restSize: CGSize = .zero
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layerContentsPlacement = .scaleAxesIndependently
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    // 操作は下の浮かべた画像のビューが受ける。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        image?.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// 画像の上に重ねる縁・ピン・×・値のバッジ。描くのは浮かべた画像のビューで、状態もそちらが持つ。
@MainActor
final class ImagePinOverlayView: NSView {
    weak var owner: ImagePinView?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { owner?.drawOverlay() }
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

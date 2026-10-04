import AppKit
@preconcurrency import AVFoundation
import UtsushieCore

@MainActor
final class VideoEditorController: NSObject, NSWindowDelegate {
    let window: VideoEditorPanel
    let timeline: VideoEditorTimeline
    let player: AVPlayer
    private let initial: VideoEditDocument
    private var history: VideoEditHistory
    private let focus: AnnotationApplicationFocus
    private var previousApplication: NSRunningApplication?
    let toolbar = VideoToolbarView()
    private let source: URL
    private var root: VideoEditorLayout!
    private var message: ToolbarHint?
    private var stillImages: [UUID: NSImage] = [:]
    private var stillTasks: [UUID: Task<Void, Never>] = [:]
    private var stillTaskIDs: [UUID: UUID] = [:]
    private var activeStill: UUID?
    private var observer: Any?
    private var boundaryObserver: Any?
    private var mediaTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var seekID = UUID()
    private var frameTimes: [Double] = []
    private(set) var position = 0.0
    private var playing = false
    private var seeking = false
    private var transitionTask: Task<Void, Never>?
    private var transitioning = false
    private var discardArmed = false
    private var closing = false
    var onComplete: ((VideoEditDocument) -> Void)?
    var onClose: (() -> Void)?
    var hintText: String { toolbar.hintView.hint.text }
    var canCapture: Bool { !frameTimes.isEmpty }

    init(source: URL, document: VideoEditDocument, screen: NSScreen?, focus: AnnotationApplicationFocus = .init()) {
        initial = document; history = VideoEditHistory(document); self.focus = focus; self.source = source
        player = AVPlayer(url: source)
        timeline = VideoEditorTimeline(document: document)
        let visible = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: min(1040, visible.width - 40), height: min(735, visible.height - 80))
        window = VideoEditorPanel(contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.editor = self; window.delegate = self
        window.title = "UTSUSHIE — 動画"; window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false; window.becomesKeyOnlyIfNeeded = false
        window.hidesOnDeactivate = false; window.level = .floating
        window.acceptsMouseMovedEvents = true; window.minSize = CGSize(width: min(1000, size.width), height: 440)
        root = VideoEditorLayout(frame: CGRect(origin: .zero, size: size))
        for (button, action) in [(toolbar.startButton, #selector(setStart)), (toolbar.endButton, #selector(setEnd)),
            (toolbar.cutButton, #selector(cut)), (toolbar.captureButton, #selector(captureFrame)),
            (toolbar.undoButton, #selector(undo)), (toolbar.redoButton, #selector(redo)),
            (toolbar.discardButton, #selector(discard)), (toolbar.finishButton, #selector(finish))] {
            button.target = self; button.action = action
        }
        let preview = VideoEditorPreview(player: player)
        root.bar = toolbar; root.preview = preview; root.timeline = timeline
        root.addSubview(preview); root.addSubview(timeline); root.addSubview(root.tray); root.addSubview(toolbar)
        root.tray.onSelect = { [weak self] id in self?.selectStill(id) }
        root.tray.onRemove = { [weak self] id in self?.apply { $0.removeStill(id) } }
        window.contentView = root
        window.setFrameOrigin(CGPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
        timeline.onSeek = { [weak self] time in self?.seek(to: time) }
        timeline.onPlay = { [weak self] in self?.togglePlay() }
        timeline.onStart = { [weak self] in self?.goToStart() }
        timeline.onEnd = { [weak self] in self?.goToEnd() }
        timeline.onSelectStill = { [weak self] id in self?.selectStill(id) }
        timeline.onEdit = { [weak self] document, commit in
            guard let self else { return }
            pause(); discardArmed = false; message = nil
            if commit { history.commit(document); updateBoundaries() }
            timeline.document = document; update()
        }
        timeline.onSelection = { [weak self] in self?.discardArmed = false; self?.update() }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1 / 60.0, preferredTimescale: 60000), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        mediaTask = Task { [weak self] in
            guard let self else { return }
            do {
                frameTimes = try await VideoEditMedia.frameTimes(url: source)
                try Task.checkCancellation()
                update()
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 180, height: 100)
                for index in 0..<12 {
                    try Task.checkCancellation()
                    let time = document.duration * (Double(index) + 0.5) / 12
                    let result = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60000))
                    guard !closing else { return }
                    timeline.images.append(NSImage(cgImage: result.image, size: CGSize(width: result.image.width, height: result.image.height)))
                    timeline.needsDisplay = true
                }
            } catch is CancellationError { }
            catch { if !closing { message = ToolbarHint("プレビューの読み取りに失敗しました", isError: true); update() } }
        }
        updateBoundaries(); update()
    }
    func show() {
        if let front = focus.frontmostApplication(), front.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApplication = front }
        requestActivation()
        window.orderFrontRegardless(); window.makeKey(); window.makeFirstResponder(timeline)
        AnnotationNavigationDiagnostics.observeFocus("video editor shown", isActive: focus.isActive(), frontmostApplication: focus.frontmostApplication())
    }
    func requestActivation() {
        let front = focus.frontmostApplication()
        AnnotationNavigationDiagnostics.observeFocus("video editor activation request", isActive: focus.isActive(), frontmostApplication: front)
        guard !closing, front?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        focus.activate()
        AnnotationNavigationDiagnostics.observeFocus("video editor activation after", isActive: focus.isActive(), frontmostApplication: focus.frontmostApplication())
    }
    private func update() {
        toolbar.undoButton.isEnabled = history.canUndo; toolbar.redoButton.isEnabled = history.canRedo
        toolbar.cutButton.isEnabled = timeline.selection != nil; toolbar.cutButton.state = timeline.selection == nil ? .off : .on
        toolbar.captureButton.isEnabled = canCapture
        let frame = VideoFrameNavigation.frame(times: frameTimes, at: position)
        toolbar.captureButton.state = timeline.document.stills.contains(where: { $0.time == frame }) ? .on : .off
        toolbar.finishButton.isEnabled = timeline.document.outputDuration > 0
        toolbar.discardButton.armed = discardArmed; toolbar.discardButton.needsDisplay = true
        toolbar.hintView.hint = VideoToolbarPresentation.hint(document: timeline.document, discardArmed: discardArmed, message: message)
        toolbar.length.stringValue = VideoToolbarPresentation.length(document: timeline.document); toolbar.needsLayout = true
        root.hasStills = !timeline.document.stills.isEmpty
        root.tray.update(marks: timeline.document.stills, images: stillImages, active: activeStill)
        timeline.activeStill = activeStill
        loadStillImages()
        timeline.needsDisplay = true
    }
    private func loadStillImages() {
        let marks = timeline.document.stills
        let ids = Set(marks.map(\.id))
        for (id, task) in stillTasks where !ids.contains(id) {
            task.cancel(); stillTasks[id] = nil; stillTaskIDs[id] = nil
        }
        for mark in marks where stillImages[mark.id] == nil && stillTasks[mark.id] == nil {
            let taskID = UUID(); stillTaskIDs[mark.id] = taskID
            stillTasks[mark.id] = Task { [weak self] in
                guard let self else { return }
                defer {
                    if stillTaskIDs[mark.id] == taskID { stillTasks[mark.id] = nil; stillTaskIDs[mark.id] = nil }
                }
                do {
                    let image = try await VideoStillExporter.frame(source: source, time: mark.time, maximumSize: CGSize(width: 160, height: 90))
                    guard !closing, !Task.isCancelled else { return }
                    stillImages[mark.id] = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
                    root.tray.update(marks: timeline.document.stills, images: stillImages, active: activeStill)
                } catch {
                    guard !closing, !Task.isCancelled else { return }
                    message = ToolbarHint("静止画のプレビューを読めませんでした", isError: true); update()
                }
            }
        }
    }
    @objc func captureFrame() {
        guard !closing else { return }
        pause()
        guard let frame = VideoFrameNavigation.frame(times: frameTimes, at: position) else {
            message = ToolbarHint("コマを読み込んでいます…"); update(); return
        }
        apply { document in
            activeStill = document.addStill(at: frame) ?? document.stills.first { abs($0.time - frame) < 1 / 120000.0 }?.id
        }
    }
    private func selectStill(_ id: UUID) {
        guard let mark = timeline.document.stills.first(where: { $0.id == id }) else { return }
        activeStill = id; seek(to: mark.time)
    }
    private func apply(_ change: (inout VideoEditDocument) -> Void) {
        timeline.closeTransitionMenu(); pause(); _ = timeline.cancelInteraction(); var document = history.document; change(&document)
        history.commit(document); timeline.document = history.document; timeline.selection = nil
        discardArmed = false; message = nil; updateBoundaries(); update()
    }
    @objc func setStart() { apply { $0.setStart(position) } }
    @objc func setEnd() { apply { $0.setEnd(position) } }
    @objc func cut() {
        guard let selection = timeline.selection else { return }
        apply { _ = $0.cut(selection) }
    }
    @objc func undo() { timeline.closeTransitionMenu(); pause(); if !timeline.cancelInteraction() { history.undo() }; timeline.document = history.document; timeline.selection = nil; discardArmed = false; message = nil; updateBoundaries(); update() }
    @objc func redo() { timeline.closeTransitionMenu(); pause(); _ = timeline.cancelInteraction(); history.redo(); timeline.document = history.document; timeline.selection = nil; discardArmed = false; message = nil; updateBoundaries(); update() }
    @objc func discard() {
        guard !closing else { return }
        if timeline.document != initial, !discardArmed { discardArmed = true; update() }
        else { close() }
    }
    @objc func finish() {
        guard !closing, timeline.document.outputDuration > 0 else { return }
        let document = timeline.document, complete = onComplete
        // カードを先に戻し、長い書き出しはカードで待つ。
        close(); complete?(document)
    }
    func handleKey(_ event: NSEvent) -> Bool {
        guard !closing, window.attachedSheet == nil else { return false }
        if window.firstResponder is NSTextView { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command {
            switch event.keyCode {
            case 36, 76: if !event.isARepeat { finish() }; return true
            case 6: undo(); return true
            case 13: if !event.isARepeat { discard() }; return true
            case 123: goToStart(); return true
            case 124: goToEnd(); return true
            default: return false
            }
        }
        if flags == [.command, .shift], event.keyCode == 6 { redo(); return true }
        if flags == .shift, event.keyCode == 123 || event.keyCode == 124 {
            seek(to: position + (event.keyCode == 123 ? -1 : 1)); return true
        }
        guard flags.isEmpty else { return false }
        switch event.keyCode {
        case 115: goToStart(); return true // Home
        case 119: goToEnd(); return true // End
        case 36, 76: if !event.isARepeat { captureFrame() }; return true
        case 49: if !event.isARepeat { togglePlay() }; return true
        case 123, 124:
            let next = VideoFrameNavigation.step(times: frameTimes, from: position, forward: event.keyCode == 124)
            seek(to: next); return true
        case 34: if !event.isARepeat { setStart() }; return true
        case 31: if !event.isARepeat { setEnd() }; return true
        case 51: if !event.isARepeat { cut() }; return true
        case 12: if !event.isARepeat { discard() }; return true
        default: return false
        }
    }
    private func pause(clearTransition: Bool = true) {
        seekTask?.cancel(); seekID = UUID(); seeking = false
        transitionTask?.cancel(); transitionTask = nil; transitioning = false
        playing = false; player.pause(); timeline.playing = false
        (root.preview as? VideoEditorPreview)?.showSpeed(nil)
        if clearTransition { (root.preview as? VideoEditorPreview)?.clearTransition() }
    }
    func seek(to time: Double, resume: Bool = false, retainingTransition: Bool = false) {
        pause(clearTransition: !retainingTransition); discardArmed = false; message = nil
        position = min(max(0, time), initial.duration)
        timeline.position = position; update()
        let id = UUID(); seekID = id; seeking = true; playing = resume; timeline.playing = resume
        seekTask = Task { [weak self] in
            guard let self else { return }
            let succeeded = await player.seek(to: CMTime(seconds: position, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
            guard !closing, !Task.isCancelled, seekID == id else { return }
            seeking = false
            (root.preview as? VideoEditorPreview)?.clearTransition()
            if succeeded, resume { updatePlaybackRate(at: position) }
            else { playing = false; timeline.playing = false }
        }
    }
    @objc func goToStart() { seek(to: 0) }
    @objc func goToEnd() { seek(to: initial.duration) }
    private func togglePlay() {
        if playing { pause(); discardArmed = false; message = nil; update(); return }
        let document = timeline.document
        guard let next = document.playbackTime(at: position) ?? document.kept.first?.start else { return }
        seek(to: next, resume: true)
    }
    private func tick(_ time: Double) {
        guard !closing, !seeking, !transitioning, time.isFinite else { return }
        if playing {
            if let transition = timeline.document.transitions.first(where: {
                ($0.kind == .fade || $0.kind == .dissolve) && time >= $0.range.start && position < $0.range.end
            }) {
                previewTransition(transition); return
            }
            guard let next = timeline.document.playbackTime(at: time) else {
                seek(to: timeline.document.kept.last?.end ?? initial.duration); return
            }
            if next > time + 1 / 60000.0 { seek(to: next, resume: true); return }
            position = time; timeline.position = time
            updatePlaybackRate(at: time)
        }
    }
    private func updatePlaybackRate(at time: Double) {
        let transition = timeline.document.transitions.first { $0.kind == .fastForward && $0.range.contains(time) }
        player.rate = Float(transition?.multiplier ?? 1)
        (root.preview as? VideoEditorPreview)?.showSpeed(transition?.multiplier)
    }
    private func previewTransition(_ transition: VideoCutTransition) {
        guard let preview = root.preview as? VideoEditorPreview else { return }
        transitioning = true; player.pause(); preview.showSpeed(nil)
        // 半開区間の境界では、前は境界より厳密に前、後ろは境界を含む表示コマを使う。
        let beforeTime = frameTimes.last { $0 < transition.range.start } ?? transition.range.start
        let afterTime = frameTimes.last { $0 <= transition.range.end } ?? transition.range.end
        transitionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let before = try await VideoStillExporter.frame(source: source, time: beforeTime, maximumSize: CGSize(width: 1280, height: 1280))
                let after = try await VideoStillExporter.frame(source: source, time: afterTime, maximumSize: CGSize(width: 1280, height: 1280))
                try Task.checkCancellation()
                preview.beginTransition(before: before, after: after)
                let began = CACurrentMediaTime()
                while CACurrentMediaTime() - began < 0.5 {
                    try Task.checkCancellation()
                    let progress = min(1, (CACurrentMediaTime() - began) / 0.5)
                    preview.transitionProgress(progress, kind: transition.kind)
                    position = progress < 0.5 ? transition.range.start : transition.range.end
                    timeline.position = position
                    try await Task.sleep(for: .milliseconds(16))
                }
                transitionTask = nil; transitioning = false
                preview.transitionProgress(1, kind: transition.kind)
                seek(to: transition.range.end, resume: true, retainingTransition: true)
            } catch is CancellationError { }
            catch {
                guard !closing, !Task.isCancelled else { return }
                transitionTask = nil; transitioning = false
                seek(to: transition.range.end, resume: true)
                message = ToolbarHint("つなぎのプレビューを読めませんでした", isError: true); update()
            }
        }
    }
    private func updateBoundaries() {
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
        let times = history.document.kept.flatMap { [$0.start, $0.end] }.map { NSValue(time: CMTime(seconds: $0, preferredTimescale: 60000)) }
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: times, queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.playing else { return }
                self.tick(self.player.currentTime().seconds)
            }
        }
    }
    private func close() { closing = true; window.close() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if closing { return true }; discard(); return false }
    func windowWillClose(_ notification: Notification) {
        closing = true; pause(); mediaTask?.cancel(); seekTask?.cancel()
        timeline.closeTransitionMenu()
        stillTasks.values.forEach { $0.cancel() }; stillTasks = [:]
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver); self.boundaryObserver = nil }
        AnnotationNavigationDiagnostics.observeFocus("video editor close", isActive: focus.isActive(), frontmostApplication: focus.frontmostApplication())
        if focus.frontmostApplication()?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           let previousApplication, !previousApplication.isTerminated,
           previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier { focus.restore(previousApplication) }
        onClose?(); onClose = nil; onComplete = nil
    }
}

@MainActor
final class VideoEditorPanel: NSPanel {
    weak var editor: VideoEditorController?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown || event.type == .scrollWheel { editor?.requestActivation() }
        if event.type == .keyDown, editor?.handleKey(event) == true { return }
        super.sendEvent(event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        editor?.handleKey(event) == true || super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class VideoEditorButton: NSButton {
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class VideoEditorPreview: NSView {
    private let playerLayer: AVPlayerLayer
    private let badgeLayer = CALayer()
    private let beforeLayer = CALayer()
    private let afterLayer = CALayer()
    private let blackLayer = CALayer()
    private var speed: Int?
    init(player: AVPlayer) {
        playerLayer = AVPlayerLayer(player: player)
        super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect; layer?.addSublayer(playerLayer)
        badgeLayer.contentsGravity = .resizeAspect; layer?.addSublayer(badgeLayer)
        for overlay in [beforeLayer, afterLayer, blackLayer] {
            overlay.contentsGravity = .resizeAspect; overlay.isHidden = true; layer?.addSublayer(overlay)
        }
        blackLayer.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    private var videoRect: CGRect { playerLayer.videoRect.offsetBy(dx: playerLayer.frame.minX, dy: playerLayer.frame.minY) }
    override func layout() {
        super.layout(); playerLayer.frame = bounds.insetBy(dx: 16, dy: 4)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for overlay in [badgeLayer, beforeLayer, afterLayer, blackLayer] { overlay.frame = videoRect }
        CATransaction.commit()
    }
    func showSpeed(_ speed: Int?) {
        guard self.speed != speed else { return }; self.speed = speed
        let size = playerLayer.player?.currentItem?.presentationSize ?? CGSize(width: 1280, height: 720)
        badgeLayer.contents = speed.flatMap { try? VideoFastForwardBadge.image(width: max(1, Int(size.width)), height: max(1, Int(size.height)), speed: $0) }
        badgeLayer.frame = videoRect
    }
    func beginTransition(before: CGImage, after: CGImage) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        beforeLayer.contents = before; afterLayer.contents = after
        beforeLayer.isHidden = false; afterLayer.isHidden = false; blackLayer.isHidden = false
        for overlay in [beforeLayer, afterLayer, blackLayer] { overlay.frame = videoRect }
        afterLayer.opacity = 0; blackLayer.opacity = 0
        CATransaction.commit()
    }
    func transitionProgress(_ progress: Double, kind: VideoTransitionKind) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        afterLayer.opacity = kind == .dissolve ? Float(progress) : (progress < 0.5 ? 0 : 1)
        blackLayer.opacity = kind == .dissolve ? 0 : Float(progress < 0.5 ? progress * 2 : (1 - progress) * 2)
        CATransaction.commit()
    }
    func clearTransition() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for overlay in [beforeLayer, afterLayer, blackLayer] { overlay.isHidden = true; overlay.contents = nil }
        CATransaction.commit()
    }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class VideoEditorLayout: NSView {
    var bar: VideoToolbarView!
    var preview: NSView!
    var timeline: VideoEditorTimeline!
    let tray = VideoStillTray(frame: .zero)
    var hasStills = false { didSet { if oldValue != hasStills { needsLayout = true } } }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        let height = VideoToolbarPresentation.height
        bar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        let trayWidth: CGFloat = hasStills ? 176 : 0
        preview.frame = CGRect(x: 0, y: height, width: bounds.width - trayWidth, height: max(0, bounds.height - height - 184))
        tray.isHidden = !hasStills
        tray.frame = CGRect(x: bounds.width - trayWidth, y: height, width: trayWidth, height: preview.frame.height)
        timeline.frame = CGRect(x: 0, y: bounds.height - 184, width: bounds.width, height: 184)
    }
    override func draw(_ dirtyRect: NSRect) { UITheme.ink.setFill(); bounds.fill() }
}

@MainActor
final class VideoEditorTimeline: NSView {
    var document: VideoEditDocument { didSet { if oldValue != document { refreshRestoreButtons() }; needsDisplay = true } }
    var selection: VideoRange? { didSet { needsDisplay = true } }
    var position = 0.0 { didSet { needsDisplay = true } }
    var playing = false { didSet { play.title = playing ? "Ⅱ" : "▶" } }
    var images: [NSImage] = []
    var onSeek: ((Double) -> Void)?
    var onPlay: (() -> Void)?
    var onStart: (() -> Void)?
    var onEnd: (() -> Void)?
    var onSelectStill: ((UUID) -> Void)?
    var activeStill: UUID? { didSet { needsDisplay = true } }
    var onEdit: ((VideoEditDocument, Bool) -> Void)?
    var onSelection: (() -> Void)?
    private let play = VideoEditorButton()
    let startButton = VideoEditorButton()
    let endButton = VideoEditorButton()
    private var restoreButtons: [VideoEditorButton] = []
    private var dragStart: CGPoint?
    private var dragDocument: VideoEditDocument?
    private var hit: VideoTimelineHit = .outside
    private var hoveredCut: Int?
    private var hoveredLabel: Int?
    private var transitionPopover: NSPopover?
    func transitionLabelRect(for range: VideoRange) -> CGRect {
        let title = document.transition(for: range).text + "⌄"
        let available = max(24, x(range.end) - x(range.start) - 12)
        let width = min(strip.width, available, ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width) + 24)
        let middle = (x(range.start) + x(range.end)) / 2
        return CGRect(x: min(strip.maxX - width, max(strip.minX, middle - width / 2)), y: strip.midY - 10, width: width, height: 20)
    }
    private func label(at point: CGPoint) -> Int? {
        document.cuts.firstIndex { range in
            range.start > 0 && range.end < document.duration && transitionLabelRect(for: range).contains(point)
        }
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        for range in document.interiorCuts { addCursorRect(transitionLabelRect(for: range), cursor: .pointingHand) }
    }
    func showTransitionMenu(for range: VideoRange) {
        guard document.interiorCuts.contains(range) else { return }
        transitionPopover?.close()
        // 編集開始時は再生を止める。選択自体は履歴へ入れない。
        onSelection?(); onEdit?(document, false)
        let popover = NSPopover(); popover.behavior = .transient
        popover.contentViewController = VideoTransitionMenu(transition: document.transition(for: range)) { [weak self] kind, speed in
            guard let self else { return }
            var next = document; next.setTransition(for: range, kind: kind, speed: speed); onEdit?(next, true)
        }
        transitionPopover = popover
        popover.show(relativeTo: transitionLabelRect(for: range), of: self, preferredEdge: .minY)
    }
    func closeTransitionMenu() { transitionPopover?.close(); transitionPopover = nil }
    private var strip: CGRect { CGRect(x: 24, y: 70, width: max(1, bounds.width - 48), height: 56) }
    init(document: VideoEditDocument) {
        self.document = document; super.init(frame: .zero)
        play.title = "▶"; play.bezelStyle = .rounded; play.target = self; play.action = #selector(togglePlay)
        play.toolTip = "再生・停止 Space"; addSubview(play)
        for (button, symbol, label, action) in [(startButton, "backward.end", "先頭へ", #selector(goToStart)),
                                               (endButton, "forward.end", "末尾へ", #selector(goToEnd))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.bezelStyle = .rounded; button.target = self; button.action = action
            button.toolTip = label; button.setAccessibilityLabel(label); addSubview(button)
        }
        refreshRestoreButtons()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func x(_ time: Double) -> CGFloat { strip.minX + time / max(document.duration, 0.00001) * strip.width }
    private func time(_ x: CGFloat) -> Double { min(1, max(0, (x - strip.minX) / strip.width)) * document.duration }
    @objc private func togglePlay() { onPlay?() }
    @objc private func goToStart() { onStart?() }
    @objc private func goToEnd() { onEnd?() }
    private func refreshRestoreButtons() {
        restoreButtons.forEach { $0.removeFromSuperview() }
        restoreButtons = document.cuts.enumerated().map { index, _ in
            let button = VideoEditorButton(title: "↺", target: self, action: #selector(restore(_:)))
            button.bezelStyle = .rounded; button.tag = index; button.toolTip = "切った範囲を戻す"; addSubview(button); return button
        }
        needsLayout = true
    }
    @objc private func restore(_ sender: NSButton) {
        guard document.cuts.indices.contains(sender.tag) else { return }
        var next = document; next.restore(document.cuts[sender.tag]); selection = nil; onEdit?(next, true)
    }
    override func layout() {
        super.layout()
        startButton.frame = CGRect(x: 24, y: 12, width: 30, height: 28)
        play.frame = CGRect(x: 58, y: 12, width: 30, height: 28)
        endButton.frame = CGRect(x: 92, y: 12, width: 30, height: 28)
        for (index, range) in document.cuts.enumerated() where restoreButtons.indices.contains(index) {
            let middle = (x(range.start) + x(range.end)) / 2
            let origin = range.start > 0 && range.end < document.duration ? transitionLabelRect(for: range).maxX + 4
                : (x(range.end) - x(range.start) > 100 ? middle + 24 : middle - 12)
            restoreButtons[index].frame = CGRect(x: min(strip.maxX - 24, max(strip.minX, origin)), y: strip.midY - 12, width: 24, height: 24)
            restoreButtons[index].isHidden = hoveredCut != index
        }
        window?.invalidateCursorRects(for: self)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // ごく短い切り口でも、はみ出した↺へ乗る途中でボタンを隠さない。
        let button = restoreButtons.firstIndex { !$0.isHidden && $0.frame.contains(point) }
        hoveredCut = button ?? label(at: point) ?? (strip.contains(point) ? document.cuts.firstIndex { $0.contains(time(point.x)) } : nil)
        hoveredLabel = label(at: point); needsDisplay = true
        if let hoveredLabel { toolTip = document.transition(for: document.cuts[hoveredLabel]).text + " ・ つなぎ方を選ぶ" }
        else { toolTip = nil }
        for (index, button) in restoreButtons.enumerated() { button.isHidden = hoveredCut != index }
    }
    override func mouseExited(with event: NSEvent) { hoveredCut = nil; hoveredLabel = nil; toolTip = nil; needsDisplay = true; restoreButtons.forEach { $0.isHidden = true } }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = label(at: point) { showTransitionMenu(for: document.cuts[index]); return }
        if (46...67).contains(point.y), let mark = document.stills.min(by: { abs(x($0.time) - point.x) < abs(x($1.time) - point.x) }),
           abs(x(mark.time) - point.x) <= 10 { onSelectStill?(mark.id); return }
        hit = VideoTimelineGesture.hit(x: point.x - strip.minX, y: point.y - strip.minY, width: strip.width, document: document)
        guard hit != .outside else { return }
        dragStart = point; dragDocument = document; selection = nil; onSelection?()
        if hit == .strip { onSeek?(time(point.x)) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, var next = dragDocument else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch hit {
        case let .boundary(segment, start):
            next.moveBoundary(segment: segment, start: start, to: time(point.x)); onEdit?(next, false)
        case .strip:
            selection = VideoTimelineGesture.selection(from: start.x - strip.minX, to: point.x - strip.minX,
                width: strip.width, duration: document.duration)
            onSeek?(time(point.x)); onSelection?()
        case .outside: break
        }
    }
    override func mouseUp(with event: NSEvent) {
        if case .boundary = hit { onEdit?(document, true) }
        dragStart = nil; dragDocument = nil; hit = .outside
    }
    func cancelInteraction() -> Bool {
        let interacting = dragStart != nil
        dragStart = nil; dragDocument = nil; hit = .outside
        return interacting
    }
    override func draw(_ dirtyRect: NSRect) {
        UITheme.ink.setFill(); bounds.fill()
        UIDrawing.text("\(VideoEditFormatting.time(position)) / \(VideoEditFormatting.time(document.duration))", in: CGRect(x: 134, y: 18, width: 176, height: 20), size: 14)
        UIDrawing.text("Space 再生 ・ ←→ 1コマ ・ ⇧←→ 1秒 ・ ⌘←→ 先頭・末尾", in: CGRect(x: 324, y: 19, width: bounds.width - 348, height: 18), size: 11.5, color: UITheme.key)
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: strip).addClip()
        NSColor.black.setFill(); strip.fill()
        for (index, image) in images.enumerated() {
            let tile = CGRect(x: strip.minX + Double(index) / 12 * strip.width, y: strip.minY, width: strip.width / 12, height: strip.height)
            let scale = max(tile.width / image.size.width, tile.height / image.size.height)
            let crop = CGRect(x: (image.size.width - tile.width / scale) / 2, y: (image.size.height - tile.height / scale) / 2,
                              width: tile.width / scale, height: tile.height / scale)
            image.draw(in: tile, from: crop, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        for range in document.cuts {
            let rect = CGRect(x: x(range.start), y: strip.minY, width: x(range.end) - x(range.start), height: strip.height)
            let fastForward = document.transition(for: range).kind == .fastForward
            NSColor.black.withAlphaComponent(fastForward ? 0.55 : 0.7).setFill(); rect.fill()
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: rect).addClip()
            let hatch = NSBezierPath()
            var p = rect.minX - strip.height
            while p < rect.maxX { hatch.move(to: CGPoint(x: p, y: rect.maxY)); hatch.line(to: CGPoint(x: p + strip.height, y: rect.minY)); p += 8 }
            NSColor.white.withAlphaComponent(fastForward ? 0.18 : 0.12).setStroke(); hatch.lineWidth = 1; hatch.stroke()
            NSGraphicsContext.restoreGraphicsState()
            if fastForward, playing, range.contains(position) {
                NSColor.white.withAlphaComponent(0.7).setFill()
                CGRect(x: rect.minX, y: rect.maxY - 2, width: x(position) - rect.minX, height: 2).fill()
            }
            if range.start == 0 || range.end == document.duration, rect.width > 85 {
                UIDrawing.text(String(format: "%.1f秒を切る", range.duration), in: rect.insetBy(dx: 4, dy: 20), size: 11, centered: true)
            }
        }
        if let selection {
            let rect = CGRect(x: x(selection.start), y: strip.minY, width: x(selection.end) - x(selection.start), height: strip.height)
            UITheme.indigo.withAlphaComponent(0.38).setFill(); rect.fill()
            let outline = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1)); outline.lineWidth = 2; UITheme.indigo.setStroke(); outline.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        for range in document.interiorCuts {
            let rect = transitionLabelRect(for: range)
            let hovered = document.cuts.firstIndex(of: range) == hoveredLabel
            UIDrawing.fill(rect, color: NSColor(white: hovered ? 0.25 : 0.08, alpha: 0.94), radius: 10)
            let outline = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
            NSColor.white.withAlphaComponent(hovered ? 0.55 : 0.22).setStroke(); outline.lineWidth = 0.7; outline.stroke()
            if rect.width > 50 {
                UIDrawing.text(document.transition(for: range).text, in: CGRect(x: rect.minX + 6, y: rect.minY + 2, width: rect.width - 24, height: 16), size: 11, centered: true)
            }
            UIDrawing.text("⌄", in: CGRect(x: rect.maxX - 19, y: rect.minY + 2, width: 14, height: 16), size: 11, centered: true)
        }
        for (index, mark) in document.stills.enumerated() {
            let px = x(mark.time)
            UITheme.paper.withAlphaComponent(0.75).setFill()
            CGRect(x: px - 0.75, y: 61, width: 1.5, height: 65).fill()
            let flag = NSBezierPath()
            flag.move(to: CGPoint(x: px - 9, y: 48)); flag.line(to: CGPoint(x: px + 9, y: 48))
            flag.line(to: CGPoint(x: px + 9, y: 61)); flag.line(to: CGPoint(x: px + 3, y: 61))
            flag.line(to: CGPoint(x: px, y: 65)); flag.line(to: CGPoint(x: px - 3, y: 61))
            flag.line(to: CGPoint(x: px - 9, y: 61)); flag.close()
            UITheme.paper.setFill(); flag.fill()
            if activeStill == mark.id { NSColor.white.setStroke(); flag.lineWidth = 1; flag.stroke() }
            UIDrawing.text("\(index + 1)", in: CGRect(x: px - 9, y: 49, width: 18, height: 14), size: 10, color: UITheme.ink, weight: .semibold, centered: true)
        }
        for range in document.kept {
            let rect = CGRect(x: x(range.start), y: strip.minY, width: x(range.end) - x(range.start), height: strip.height)
            let outline = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            outline.lineWidth = 3; UITheme.indigo.setStroke(); outline.stroke()
            for (edge, left) in [(rect.minX, true), (rect.maxX, false)] {
                let grip = CGRect(x: left ? edge - 10 : edge, y: rect.minY - 1, width: 10, height: rect.height + 2)
                UIDrawing.fill(grip, color: UITheme.indigo, radius: 3)
                NSColor.white.withAlphaComponent(0.9).setFill()
                CGRect(x: grip.midX - 2, y: grip.midY - 9, width: 1, height: 18).fill()
                CGRect(x: grip.midX + 1, y: grip.midY - 9, width: 1, height: 18).fill()
            }
        }
        NSColor.white.setFill(); CGRect(x: x(position) - 1, y: strip.minY - 4, width: 2, height: strip.height + 8).fill()
        let head = NSBezierPath(); head.move(to: CGPoint(x: x(position) - 6, y: strip.minY - 11)); head.line(to: CGPoint(x: x(position) + 6, y: strip.minY - 11)); head.line(to: CGPoint(x: x(position), y: strip.minY - 4)); head.close(); head.fill()
        for index in 0...6 {
            let t = document.duration * Double(index) / 6, px = x(t)
            NSColor.white.withAlphaComponent(0.45).setFill(); CGRect(x: px, y: 134, width: 1, height: 6).fill()
            UIDrawing.text(MediaFormatting.elapsed(t), in: CGRect(x: min(strip.maxX - 46, px + 3), y: 143, width: 50, height: 15), size: 10, color: UITheme.key)
        }
        if let selection { UIDrawing.text(String(format: "%.1f秒を選択 ・ ⌫で切る", selection.duration), in: CGRect(x: 24, y: 49, width: 260, height: 16), size: 11, color: UITheme.text) }
    }
}

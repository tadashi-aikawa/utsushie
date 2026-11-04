import AppKit
@preconcurrency import AVFoundation
import UtsushieCore

@MainActor
final class VideoEditorController: NSObject, NSWindowDelegate {
    let window: VideoEditorWindow
    let timeline: VideoEditorTimeline
    let player: AVPlayer
    private let initial: VideoEditDocument
    private var history: VideoEditHistory
    private let focus: AnnotationApplicationFocus
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
    private(set) var boundaryPreviewTime: Double?
    private lazy var boundaryPreview = VideoBoundaryPreview(source: source, show: { [weak self] image, _ in
        guard let self, !closing else { return }
        (root.preview as? VideoEditorPreview)?.showBoundary(image)
    }, failed: { [weak self] in
        guard let self, !closing else { return }
        message = ToolbarHint("端のプレビューを読めませんでした", isError: true); update()
    })
    private(set) var position = 0.0 { didSet { if oldValue != position { refreshZoom() } } }
    /// ズームのツール中は寄せずに全体を見せ、プレビューのドラッグで寄せる範囲を選ぶ。
    private(set) var zoomTool = false
    /// 元録画のピクセル寸法。ズームの矩形はこの座標で持つ。
    private(set) var videoSize: CGSize?
    /// ズームのツール中は、再生と停止で寄った見え方と全体表示・枠を切り替える。
    private var playing = false { didSet { if oldValue != playing { refreshZoom() } } }
    private var seeking = false
    private var transitionTask: Task<Void, Never>?
    private var transitioning = false
    /// 演出のプレビューの進み具合。演出を見せている間だけ値を持つ。
    private(set) var transitionPreviewProgress: Double?
    /// プレビューに今掛けている寄せる範囲。
    var previewZoomCrop: CGRect? { (root.preview as? VideoEditorPreview)?.zoomCrop }
    /// 演出の間、切った範囲の頭の音を絞りながら鳴らす。映像は出さない。
    private lazy var outgoingAudio: AVPlayer = {
        let player = AVPlayer(url: source); player.automaticallyWaitsToMinimizeStalling = false
        return player
    }()
    private struct TransitionFrames: Sendable { let before: CGImage; let after: CGImage }
    private var transitionPreload: (range: VideoRange, task: Task<TransitionFrames, Error>)?
    private var incomingReady = false
    private var discardArmed = false
    private var closing = false
    var onComplete: ((VideoEditDocument) -> Void)?
    var onClose: (() -> Void)?
    var hintText: String { toolbar.hintView.hint.text }
    var canCapture: Bool { !frameTimes.isEmpty }

    /// 完了時に静止画をクリップボードへ載せるか。手引きの文言だけに使う。
    private let copiesStills: Bool
    init(source: URL, document: VideoEditDocument, screen: NSScreen?, focus: AnnotationApplicationFocus = .init(),
         copiesStills: Bool = true) {
        self.copiesStills = copiesStills
        initial = document; history = VideoEditHistory(document); self.focus = focus; self.source = source
        player = AVPlayer(url: source)
        timeline = VideoEditorTimeline(document: document)
        let visible = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: min(1040, visible.width - 40), height: min(735, visible.height - 80))
        window = VideoEditorWindow(contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.editor = self; window.delegate = self
        window.title = "UTSUSHIE — 動画"; window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false; window.level = .normal
        window.acceptsMouseMovedEvents = true; window.minSize = CGSize(width: min(1000, size.width), height: 440)
        root = VideoEditorLayout(frame: CGRect(origin: .zero, size: size))
        for (button, action) in [(toolbar.startButton, #selector(setStart)), (toolbar.endButton, #selector(setEnd)),
            (toolbar.cutButton, #selector(cut)), (toolbar.zoomButton, #selector(toggleZoomTool)), (toolbar.captureButton, #selector(captureFrame)),
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
            pause(clearBoundaryPreview: commit); discardArmed = false; message = nil
            if commit { history.commit(document); updateBoundaries() }
            timeline.document = document; update()
        }
        timeline.onBoundaryPreview = { [weak self] time in self?.previewBoundary(at: time) }
        timeline.onSelection = { [weak self] in self?.discardArmed = false; self?.update() }
        preview.onZoomBegin = { [weak self] in
            guard let self else { return }
            pause(); _ = timeline.cancelInteraction(); discardArmed = false; message = nil
            // 移動・リサイズの対象は押した時点の区間に固定する。途中で再生位置が変わっても別の区間へ移さない。
            zoomDragTarget = movableZoom?.id; update()
        }
        preview.onZoomDrag = { [weak self] anchor, point, finished in self?.dragZoom(from: anchor, to: point, finished: finished) }
        preview.onZoomCancel = { [weak self] in self?.refreshZoom() }
        preview.onZoomMove = { [weak self] delta, finished in self?.moveZoom(by: delta, finished: finished) }
        preview.onZoomResize = { [weak self] edges, delta, finished in self?.resizeZoom(edges: edges, by: delta, finished: finished) }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1 / 60.0, preferredTimescale: 60000), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        mediaTask = Task { [weak self] in
            guard let self else { return }
            do {
                frameTimes = try await VideoEditMedia.frameTimes(url: source)
                try Task.checkCancellation()
                if let boundaryPreviewTime { previewBoundary(at: boundaryPreviewTime) }
                if let track = try await AVURLAsset(url: source).loadTracks(withMediaType: .video).first {
                    let size = try await track.load(.naturalSize)
                    try Task.checkCancellation()
                    videoSize = size; preview.videoSize = size; timeline.videoSize = size
                }
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
        window.orderFrontRegardless(); window.makeKey(); window.makeFirstResponder(timeline)
        focus.activateEditor()
        AnnotationNavigationDiagnostics.observeFocus("video editor shown", isActive: focus.isActive(), frontmostApplication: focus.frontmostApplication())
    }
    private func update() {
        toolbar.undoButton.isEnabled = history.canUndo; toolbar.redoButton.isEnabled = history.canRedo
        toolbar.cutButton.isEnabled = timeline.selection != nil; toolbar.cutButton.state = timeline.selection == nil ? .off : .on
        toolbar.captureButton.isEnabled = canCapture
        let frame = VideoFrameNavigation.frame(times: frameTimes, at: position)
        toolbar.captureButton.state = timeline.document.stills.contains(where: { $0.time == frame }) ? .on : .off
        toolbar.zoomButton.state = zoomTool ? .on : .off; toolbar.zoomButton.needsDisplay = true
        if let id = timeline.selectedZoom, !timeline.document.zooms.contains(where: { $0.id == id }) { timeline.selectedZoom = nil }
        toolbar.finishButton.isEnabled = timeline.document.outputDuration > 0
        toolbar.discardButton.armed = discardArmed; toolbar.discardButton.needsDisplay = true
        toolbar.hintView.hint = VideoToolbarPresentation.hint(document: timeline.document, discardArmed: discardArmed, message: message,
            copiesStills: copiesStills, zoomTool: zoomTool, selection: timeline.selection)
        refreshZoom()
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
    @objc func toggleZoomTool() { setZoomTool(!zoomTool) }
    private func setZoomTool(_ on: Bool) {
        guard !closing else { return }
        timeline.closeTransitionMenu(); pause(); _ = timeline.cancelInteraction()
        cancelZoomDrag()
        zoomTool = on; (root.preview as? VideoEditorPreview)?.zoomTool = on
        discardArmed = false; message = on && videoSize == nil ? ToolbarHint("動画を読み込んでいます…") : nil
        update()
    }
    /// 押した点を角に固定した矩形を、ドラッグ中はカーソルに沿って見せ、離したら再生位置にズーム区間を置く。
    /// 最小の幅はドラッグ中には当てない。押した直後に枠が一定の大きさへ跳ねて見えるため。離したときに当てる。
    private func dragZoom(from anchor: CGPoint, to point: CGPoint, finished: Bool) {
        guard let videoSize, let preview = root.preview as? VideoEditorPreview else { return }
        let rect = VideoZoom.anchored(from: anchor, to: point, size: videoSize, limitsScale: finished)
        guard finished else { preview.showZoomOutline(rect); return }
        guard let rect else { refreshZoom(); return }
        var placed: UUID?
        // 時間軸で範囲を選んであれば、2秒の目安ではなくその範囲に置く。時間を先に決めたいときの置き方。
        let selected = timeline.selection
        apply { document in
            if let selected { placed = document.addZoom(drag: rect, size: videoSize, range: selected) }
            else { placed = document.addZoom(drag: rect, size: videoSize, at: position) }
        }
        guard let placed else {
            message = ToolbarHint(selected == nil ? "ここにはズームを置けません。ほかの区間と重ならない位置へ移してください"
                : "選んだ範囲にはズームを置けません。ほかの区間と重ならない範囲を選んでください", isError: true)
            timeline.selection = selected; update(); return
        }
        // ツールに留まり、全体表示と枠のまま移動・リサイズで調整を続けられるようにする。
        timeline.selectedZoom = placed
        // 録画末尾や切った範囲から置くと、再生位置が区間の外に残り、枠とリサイズの対象を見失う。区間の頭へ移る。
        if let zoom = timeline.document.zooms.first(where: { $0.id == placed }), !zoom.range.contains(position) {
            seek(to: zoom.range.start)
        } else { update() }
    }
    /// 縦横比を保ったリサイズを、ドラッグ中も確定と同じ形で見せ、離したら1回の履歴に入れる。
    private func resizeZoom(edges: LastFrameEdges, by delta: CGPoint, finished: Bool) {
        guard let videoSize, let zoom = draggedZoom, let preview = root.preview as? VideoEditorPreview else { return }
        guard finished else { preview.showZoomOutline(VideoZoom.resized(zoom.rect, edges: edges, by: delta, size: videoSize)); return }
        apply { $0.resizeZoom(zoom.id, edges: edges, by: delta, size: videoSize) }
    }
    @objc func removeSelectedZoom() {
        guard let id = timeline.selectedZoom else { return }
        apply { $0.removeZoom(id) }
    }
    /// 再生位置の寄り方をプレビューへ出す。ツール中は寄せずに、今の区間の矩形を枠で示す。
    private func refreshZoom() {
        guard let preview = root?.preview as? VideoEditorPreview else { return }
        // 暗転・ディゾルブの間は、書き出しと同じく進み具合で補間した寄り方を保つ。位置は演出の途中で末尾へ飛ぶため使わない。
        // ツール中でも再生中は寄るので、演出の間も同じ寄り方にする。
        if transitionPreviewProgress != nil { return }
        let zooms = timeline.document.zooms
        if zoomTool, playing {
            // ツール中の再生は、ツール外と同じく寄った見え方にする。枠と調整は停止したら戻す。
            preview.movableRect = nil; preview.showZoomOutline(nil)
            preview.showZoom(videoSize.flatMap { zooms.crop(at: position, size: $0) })
            return
        }
        preview.movableRect = movableZoom?.rect
        if zoomTool {
            preview.showZoom(nil)
            if !preview.isDraggingZoom { preview.showZoomOutline(movableZoom?.rect) }
        } else {
            preview.showZoom(videoSize.flatMap { zooms.crop(at: position, size: $0) })
            // 選んだ区間の矩形を薄く重ね、⌥ドラッグで動かせる所を示す。
            if !preview.isDraggingZoom { preview.showZoomOutline(movableZoom?.rect, faint: true) }
        }
    }
    /// ⌥ドラッグで動かす区間。ツール中は再生位置の区間、ツール外はレーンで選んだ区間。
    private var movableZoom: VideoZoom? {
        let zooms = timeline.document.zooms
        if zoomTool { return zooms.zoom(at: position) }
        return zooms.first { $0.id == timeline.selectedZoom }
    }
    /// 移動・リサイズ中の区間。押した時点で決め、離す・取り消すまで変えない。
    private var zoomDragTarget: UUID?
    private var draggedZoom: VideoZoom? {
        guard let id = zoomDragTarget else { return nil }
        return timeline.document.zooms.first { $0.id == id }
    }
    /// プレビューのドラッグを取り消し、対象の区間も外す。ドラッグ中だったかを返す。
    @discardableResult private func cancelZoomDrag() -> Bool {
        zoomDragTarget = nil
        return (root?.preview as? VideoEditorPreview)?.cancelZoomDrag() ?? false
    }
    /// 寸法を保って動かした矩形を、ドラッグ中も確定と同じ形で見せ、離したら1回の履歴に入れる。
    private func moveZoom(by delta: CGPoint, finished: Bool) {
        guard let videoSize, let zoom = draggedZoom, let preview = root.preview as? VideoEditorPreview else { return }
        guard finished else { preview.showZoomOutline(VideoZoom.moved(zoom.rect, by: delta, size: videoSize)); return }
        apply { $0.moveZoom(zoom.id, by: delta, size: videoSize) }
    }
    func flagsChanged(_ event: NSEvent) {
        (root.preview as? VideoEditorPreview)?.refreshCursor(option: event.modifierFlags.contains(.option))
    }
    /// プレビューの今のカーソルと枠。テストだけに使う。
    var previewCursor: CaptureCursor? { (root.preview as? VideoEditorPreview)?.currentCursor }
    var previewOutline: CGRect? { (root.preview as? VideoEditorPreview)?.outlineRect }
    private func apply(_ change: (inout VideoEditDocument) -> Void) {
        cancelZoomDrag()
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
    // プレビューのドラッグ中の取り消しは、時間軸のドラッグと同じくドラッグだけを取り消す。
    @objc func undo() {
        timeline.closeTransitionMenu(); pause(); let dragging = cancelZoomDrag()
        if !timeline.cancelInteraction(), !dragging { history.undo() }
        timeline.document = history.document; timeline.selection = nil; discardArmed = false; message = nil; updateBoundaries(); update()
    }
    @objc func redo() { timeline.closeTransitionMenu(); pause(); cancelZoomDrag(); _ = timeline.cancelInteraction(); history.redo(); timeline.document = history.document; timeline.selection = nil; discardArmed = false; message = nil; updateBoundaries(); update() }
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
        case 51:
            if !event.isARepeat { if timeline.selectedZoom != nil { removeSelectedZoom() } else { cut() } }
            return true
        case 6: if !event.isARepeat { toggleZoomTool() }; return true // Z
        case 53: // Esc
            if zoomTool { setZoomTool(false); return true }
            if timeline.selectedZoom != nil {
                // ⌥ドラッグの途中なら取り消し、未確定の枠と暗幕を残さない。
                cancelZoomDrag()
                timeline.selectedZoom = nil; update(); return true
            }
            return false
        case 12: if !event.isARepeat { discard() }; return true
        default: return false
        }
    }
    private func previewBoundary(at time: Double?) {
        boundaryPreviewTime = time
        guard let time else {
            boundaryPreview.cancel(); (root.preview as? VideoEditorPreview)?.showBoundary(nil); return
        }
        guard let frame = VideoFrameNavigation.frame(times: frameTimes, at: time) else { return }
        boundaryPreview.request(frame)
    }
    private func pause(clearTransition: Bool = true, clearBoundaryPreview: Bool = true) {
        if clearBoundaryPreview { previewBoundary(at: nil) }
        seekTask?.cancel(); seekID = UUID(); seeking = false
        transitionTask?.cancel(); transitionTask = nil
        if transitioning { outgoingAudio.pause(); player.volume = 1 }
        transitioning = false
        if transitionPreviewProgress != nil { transitionPreviewProgress = nil; refreshZoom() }
        playing = false; player.pause(); timeline.playing = false
        (root.preview as? VideoEditorPreview)?.showSpeed(nil)
        if clearTransition { (root.preview as? VideoEditorPreview)?.clearTransition() }
    }
    func seek(to time: Double, resume: Bool = false, retainingTransition: Bool = false) {
        // ツール中の枠は再生位置の区間なので、ドラッグ中に位置が変わったら取り消し、別の区間へ当てない。
        pause(clearTransition: !retainingTransition); cancelZoomDrag(); discardArmed = false; message = nil
        position = min(max(0, time), initial.duration)
        timeline.position = position; update()
        let id = UUID(); seekID = id; seeking = true; playing = resume; timeline.playing = resume
        seekTask = Task { [weak self] in
            guard let self else { return }
            let succeeded = await player.seek(to: VideoExportTiming.time(position), toleranceBefore: .zero, toleranceAfter: .zero)
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
            if let upcoming = timeline.document.transitions.first(where: {
                ($0.kind == .fade || $0.kind == .dissolve) && $0.range.start > time && $0.range.start - time <= 0.6
            }) { _ = preloadTransition(upcoming) }
            if let transition = timeline.document.transitionCrossed(from: position, to: time) {
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
        // 書き出しと同じく、早送りの間は音を出さない。
        player.isMuted = transition != nil
        (root.preview as? VideoEditorPreview)?.showSpeed(transition?.multiplier)
    }
    /// 演出の手前で前後のコマを読み、切った範囲の頭へ音を合わせておく。演出の開始で再生を止める時間をなくすため。
    private func preloadTransition(_ transition: VideoCutTransition) -> Task<TransitionFrames, Error> {
        if let transitionPreload, transitionPreload.range == transition.range { return transitionPreload.task }
        transitionPreload?.task.cancel()
        // 半開区間の境界では、前は境界より厳密に前、後ろは境界を含む表示コマを使う。
        let beforeTime = frameTimes.last { $0 < transition.range.start } ?? transition.range.start
        let afterTime = frameTimes.last { $0 <= transition.range.end } ?? transition.range.end
        let outgoing = outgoingAudio, source = source
        let task = Task {
            outgoing.pause()
            let seeked = await outgoing.seek(to: VideoExportTiming.time(transition.range.start), toleranceBefore: .zero, toleranceAfter: .zero)
            if seeked, outgoing.status == .readyToPlay { _ = await outgoing.preroll(atRate: 1) }
            let before = try await VideoStillExporter.frame(source: source, time: beforeTime, maximumSize: CGSize(width: 1280, height: 1280))
            let after = try await VideoStillExporter.frame(source: source, time: afterTime, maximumSize: CGSize(width: 1280, height: 1280))
            return TransitionFrames(before: before, after: after)
        }
        transitionPreload = (transition.range, task)
        return task
    }
    private func previewTransition(_ transition: VideoCutTransition) {
        guard let preview = root.preview as? VideoEditorPreview else { return }
        transitioning = true; player.pause(); player.isMuted = false; preview.showSpeed(nil)
        let frames = preloadTransition(transition); transitionPreload = nil
        let audio = VideoTransitionAudioPreview(kind: transition.kind, cut: transition.range)
        let plan = VideoExportPlan(document: timeline.document)
        let junction = plan.junctions.first { $0.transition.range == transition.range }
        // 書き出しの計画と同じく、切った範囲の頭と末尾の寄り方を進み具合で補間する。
        func showZoom(_ progress: Double) {
            transitionPreviewProgress = progress
            // ズームのツール中も、再生中は通常の再生と同じく寄せる。
            preview.showZoomOutline(nil); preview.movableRect = nil
            preview.showZoom(videoSize.flatMap { size in junction.flatMap { plan.transitionCrop($0, progress: progress, size: size) } })
        }
        transitionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await frames.value
                try Task.checkCancellation()
                preview.beginTransition(before: loaded.before, after: loaded.after)
                showZoom(0)
                // 書き出しと同じく、前は切った範囲の頭の音を絞り、後ろは末尾の手前から音を戻す。映像は演出の絵で隠れている。
                outgoingAudio.volume = audio.outgoingVolume(at: 0)
                if audio.outgoing > 0 { outgoingAudio.play() }
                player.volume = 0; incomingReady = false
                let resumeAt = transition.range.end - audio.incoming
                Task { [weak self] in
                    guard let self else { return }
                    let seeked = await player.seek(to: VideoExportTiming.time(resumeAt), toleranceBefore: .zero, toleranceAfter: .zero)
                    if seeked, transitioning { incomingReady = true }
                }
                let began = CACurrentMediaTime()
                var incomingStarted = false
                while true {
                    let elapsed = CACurrentMediaTime() - began
                    guard elapsed < VideoTransitionAudioPreview.duration else { break }
                    try Task.checkCancellation()
                    outgoingAudio.volume = audio.outgoingVolume(at: elapsed)
                    if elapsed >= audio.outgoing { outgoingAudio.pause() }
                    if !incomingStarted, incomingReady, audio.incoming > 0, elapsed >= audio.incomingStart {
                        player.play(); incomingStarted = true
                    }
                    player.volume = audio.incomingVolume(at: elapsed)
                    let progress = min(1, elapsed / VideoTransitionAudioPreview.duration)
                    preview.transitionProgress(progress, kind: transition.kind)
                    showZoom(progress)
                    position = progress < 0.5 ? transition.range.start : transition.range.end
                    timeline.position = position
                    try await Task.sleep(for: .milliseconds(16))
                }
                outgoingAudio.pause(); player.volume = 1
                preview.transitionProgress(1, kind: transition.kind)
                showZoom(1)
                // 再生開始の遅れの分だけ、本体はまだ末尾の手前にいる。後ろのコマを見せたまま着くのを待ち、
                // 切った範囲の中と判定してシークし直す一瞬の停止を避ける。
                let waitStarted = CACurrentMediaTime()
                while incomingStarted, player.currentTime().seconds < transition.range.end - 1 / 60000.0,
                      CACurrentMediaTime() - waitStarted < 0.3 {
                    try await Task.sleep(for: .milliseconds(4))
                }
                transitionTask = nil; transitioning = false
                transitionPreviewProgress = nil; refreshZoom()
                if incomingStarted {
                    // 本体は切った範囲の末尾まで進んでいる。シークし直さず続け、残す範囲の頭の音を途切れさせない。
                    preview.clearTransition()
                    position = transition.range.end; timeline.position = position
                    updatePlaybackRate(at: position)
                } else { seek(to: transition.range.end, resume: true, retainingTransition: true) }
            } catch is CancellationError { }
            catch {
                guard !closing, !Task.isCancelled else { return }
                outgoingAudio.pause(); player.volume = 1
                transitionTask = nil; transitioning = false; transitionPreviewProgress = nil
                seek(to: transition.range.end, resume: true)
                message = ToolbarHint("つなぎのプレビューを読めませんでした", isError: true); update()
            }
        }
    }
    private func updateBoundaries() {
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
        let times = history.document.kept.flatMap { [$0.start, $0.end] }.map { NSValue(time: VideoExportTiming.time($0)) }
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
        onClose?(); onClose = nil; onComplete = nil
    }
}

@MainActor
final class VideoEditorWindow: NSWindow {
    weak var editor: VideoEditorController?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, editor?.handleKey(event) == true { return }
        // ⌥の押し離しでプレビューのカーソルを変える。first responderは時間軸なのでウィンドウで受ける。
        if event.type == .flagsChanged { editor?.flagsChanged(event) }
        super.sendEvent(event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        editor?.handleKey(event) == true || super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class VideoEditorButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class VideoEditorPreview: NSView {
    private let playerLayer: AVPlayerLayer
    private let badgeLayer = CALayer()
    private let beforeLayer = CALayer()
    private let afterLayer = CALayer()
    private let blackLayer = CALayer()
    private let zoomShade = CAShapeLayer()
    private let zoomOutline = CAShapeLayer()
    private let boundaryLayer = CALayer()
    private var speed: Int?
    /// 元録画のピクセル寸法。読み込むまではAVPlayerLayerの表示範囲を使う。
    var videoSize: CGSize? { didSet { needsLayout = true } }
    private var crop: CGRect?
    var zoomCrop: CGRect? { crop }
    var zoomTool = false { didSet { refreshCursor() } }
    /// ⌥ドラッグで動かせる矩形。ツール中は再生位置の区間、ツール外は選んだ区間。
    var movableRect: CGRect? { didSet { if oldValue != movableRect { refreshCursor() } } }
    var onZoomBegin: (() -> Void)?
    /// 押した点と今の点の、元録画のピクセル座標。離したらtrue。
    var onZoomDrag: ((CGPoint, CGPoint, Bool) -> Void)?
    var onZoomCancel: (() -> Void)?
    /// 押した点からの移動量。元録画のピクセル。離したらtrue。
    var onZoomMove: ((CGPoint, Bool) -> Void)?
    /// つかんだ辺と押した点からの移動量。辺と移動量は元録画の左上原点の向き。離したらtrue。
    var onZoomResize: ((LastFrameEdges, CGPoint, Bool) -> Void)?
    private var dragOrigin: CGPoint?
    private var dragMoved = false
    private var grab: VideoZoom.Grab = .none
    var isDraggingZoom: Bool { dragOrigin != nil }
    /// つかんでいる操作。押していなければnone。
    private var activeGrab: VideoZoom.Grab { dragOrigin == nil ? .none : grab }
    /// 表示中の枠の矩形。テストと診断だけに使う。
    private(set) var outlineRect: CGRect?
    private(set) var currentCursor: CaptureCursor = .arrow
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
        zoomShade.fillRule = .evenOdd; zoomShade.fillColor = NSColor.black.withAlphaComponent(0.45).cgColor
        zoomOutline.fillColor = nil; zoomOutline.strokeColor = NSColor.white.cgColor; zoomOutline.lineWidth = 2
        for shape in [zoomShade, zoomOutline] { shape.isHidden = true; layer?.addSublayer(shape) }
        boundaryLayer.contentsGravity = .resizeAspect; boundaryLayer.isHidden = true
        // 境界のプレビューは常に最前面に置く。
        layer?.addSublayer(boundaryLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    private var base: CGRect { bounds.insetBy(dx: 16, dy: 4) }
    /// 寄せる前の映像の範囲。ズームの変形はこの範囲へ切り詰める。
    private var videoRect: CGRect {
        if let videoSize, videoSize.width > 0, videoSize.height > 0 { return AVMakeRect(aspectRatio: videoSize, insideRect: base) }
        return playerLayer.videoRect.offsetBy(dx: base.minX, dy: base.minY)
    }
    /// 寄る対象の層。演出の層にも同じ変形を掛け、合成後に寄せた見え方にする。
    private var zoomedLayers: [CALayer] { [playerLayer, beforeLayer, afterLayer, blackLayer] }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // 変形中のframeは外接矩形になるため、変形を外してから置き直す。
        zoomedLayers.forEach { $0.transform = CATransform3DIdentity }
        playerLayer.frame = base
        for overlay in [badgeLayer, beforeLayer, afterLayer, blackLayer] { overlay.frame = videoRect }
        boundaryLayer.frame = base
        // 寄った表示では枠が映像の外へはみ出すので、映像の範囲で切る。
        for shape in [zoomShade, zoomOutline] { shape.frame = videoRect; shape.masksToBounds = true }
        applyZoom()
        CATransaction.commit()
        drawOutline()
    }
    /// cropは元録画の左上原点のピクセル座標。nilなら寄せない。
    func showZoom(_ crop: CGRect?) {
        guard self.crop != crop else { return }
        self.crop = crop
        CATransaction.begin(); CATransaction.setDisableActions(true); applyZoom(); CATransaction.commit()
        drawOutline()
    }
    /// 今の寄り方で表示している元録画の範囲。
    private var displayedPixels: CGRect? {
        guard let videoSize, videoSize.width > 0, videoSize.height > 0 else { return nil }
        return crop ?? CGRect(origin: .zero, size: videoSize)
    }
    /// 元録画のピクセル座標の矩形を、今の寄り方の表示上の位置へ写す。
    private func displayedViewRect(forPixel rect: CGRect) -> CGRect? {
        let stage = videoRect
        guard let shown = displayedPixels, shown.width > 0, shown.height > 0, stage.width > 0 else { return nil }
        let sx = stage.width / shown.width, sy = stage.height / shown.height
        return CGRect(x: stage.minX + (rect.minX - shown.minX) * sx, y: stage.maxY - (rect.maxY - shown.minY) * sy,
                      width: rect.width * sx, height: rect.height * sy)
    }
    private func viewRect(forPixel rect: CGRect) -> CGRect? {
        let stage = videoRect
        guard let videoSize, videoSize.width > 0, videoSize.height > 0, stage.width > 0 else { return nil }
        return CGRect(x: stage.minX + rect.minX / videoSize.width * stage.width,
                      y: stage.minY + (videoSize.height - rect.maxY) / videoSize.height * stage.height,
                      width: rect.width / videoSize.width * stage.width, height: rect.height / videoSize.height * stage.height)
    }
    private func applyZoom() {
        let stage = videoRect
        guard let crop, let target = viewRect(forPixel: crop), target.width > 0, target.height > 0 else {
            zoomedLayers.forEach { $0.transform = CATransform3DIdentity; $0.mask = nil }
            return
        }
        let sx = stage.width / target.width, sy = stage.height / target.height
        for layer in zoomedLayers {
            layer.transform = CATransform3DIdentity
            let frame = layer.frame
            // 層の中心を基準に拡大し、寄せる範囲の中心を映像の中心へ移す。
            let tx = stage.midX - frame.midX + sx * (frame.midX - target.midX)
            let ty = stage.midY - frame.midY + sy * (frame.midY - target.midY)
            // マスクは層と一緒に変形されるので、寄せる範囲を層の座標で切り抜く。
            let mask = layer.mask ?? CALayer()
            mask.backgroundColor = NSColor.black.cgColor
            mask.frame = target.offsetBy(dx: -frame.minX, dy: -frame.minY)
            layer.mask = mask
            layer.transform = CATransform3DMakeAffineTransform(CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: tx, ty: ty))
        }
    }
    private var outlineFaint = false
    /// 寄せる範囲を枠で示す。ツール中とドラッグ中は外側を暗くし、ツール外で選んだ区間は薄い枠だけにする。
    func showZoomOutline(_ rect: CGRect?, faint: Bool = false) {
        outlineRect = rect; outlineFaint = faint; drawOutline()
    }
    private func drawOutline() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let stage = videoRect
        if let rect = outlineRect, let view = displayedViewRect(forPixel: rect)?.offsetBy(dx: -stage.minX, dy: -stage.minY) {
            let shade = CGMutablePath(); shade.addRect(CGRect(origin: .zero, size: stage.size)); shade.addRect(view)
            zoomShade.path = shade; zoomOutline.path = CGPath(rect: view.insetBy(dx: 1, dy: 1), transform: nil)
            zoomOutline.strokeColor = NSColor.white.withAlphaComponent(outlineFaint ? 0.5 : 1).cgColor
            zoomOutline.lineWidth = outlineFaint ? 1 : 2
            zoomShade.isHidden = outlineFaint; zoomOutline.isHidden = false
        } else { zoomShade.isHidden = true; zoomOutline.isHidden = true }
        CATransaction.commit()
    }
    /// 今の寄り方の表示上の点を、元録画のピクセル座標へ戻す。映像の外の点は縁へ寄せる。
    private func pixel(at point: CGPoint) -> CGPoint {
        let stage = videoRect, shown = displayedPixels ?? CGRect(origin: .zero, size: stage.size)
        let x = min(stage.maxX, max(stage.minX, point.x)), y = min(stage.maxY, max(stage.minY, point.y))
        return CGPoint(x: shown.minX + (x - stage.minX) / max(1, stage.width) * shown.width,
                       y: shown.minY + (stage.maxY - y) / max(1, stage.height) * shown.height)
    }
    private func insideMovable(_ point: CGPoint) -> Bool {
        guard let movableRect, videoRect.contains(point) else { return false }
        return movableRect.contains(pixel(at: point))
    }
    /// 範囲選択の前回枠と同じく、表示上の矩形の内外6ptの縁を辺と角、内側を移動として判定する。
    private func grip(at point: CGPoint) -> LastFrameGrip? {
        guard let movableRect, let frame = displayedViewRect(forPixel: movableRect) else { return nil }
        return LastFrameGrip.at(point, in: frame)
    }
    /// カーソル矩形はキーの状態で変えられないため、移動・修飾変更・カーソル更新のたびに決め直す。
    func refreshCursor(at location: CGPoint? = nil, option: Bool = NSEvent.modifierFlags.contains(.option)) {
        guard let window else { return }
        let point = location ?? convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard activeGrab != .none || bounds.contains(point) else { return }
        applyCursor(VideoZoom.cursor(tool: zoomTool, option: option, grip: grip(at: point), insideMovable: insideMovable(point),
                                     insideVideo: videoRect.contains(point), active: activeGrab))
    }
    private func applyCursor(_ cursor: CaptureCursor) {
        currentCursor = cursor
        switch cursor {
        case .crosshair: NSCursor.crosshair.set()
        case .openHand: NSCursor.openHand.set()
        case .closedHand: NSCursor.closedHand.set()
        case let .resize(edges): NSCursor.frameResize(position: OverlayController.resizePosition(edges), directions: .all).set()
        default: NSCursor.arrow.set()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        // .activeAlwaysと.cursorUpdateを組み合わせると通知されないため分ける。
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        refreshCursor(at: convert(event.locationInWindow, from: nil), option: event.modifierFlags.contains(.option))
    }
    override func cursorUpdate(with event: NSEvent) {
        refreshCursor(at: convert(event.locationInWindow, from: nil), option: event.modifierFlags.contains(.option))
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // ⌥と縁は押した時点だけで決め、ドラッグ途中の修飾変更では切り替えない。
        let decided = videoSize == nil ? .none : VideoZoom.grab(tool: zoomTool, option: event.modifierFlags.contains(.option),
            grip: grip(at: point), insideMovable: insideMovable(point), insideVideo: videoRect.contains(point))
        guard decided != .none else { super.mouseDown(with: event); return }
        onZoomBegin?()
        grab = decided; dragOrigin = point; dragMoved = false
        applyCursor(VideoZoom.cursor(tool: zoomTool, option: false, grip: nil, insideMovable: false, insideVideo: true, active: decided))
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        // 表示上4ptを超えるまではクリックとして扱う。
        if hypot(point.x - origin.x, point.y - origin.y) > 4 { dragMoved = true }
        guard dragMoved else { return }
        switch grab {
        case .move: onZoomMove?(delta(from: origin, to: point), false)
        case let .resize(edges): onZoomResize?(edges.flippedVertically, delta(from: origin, to: point), false)
        default: onZoomDrag?(pixel(at: origin), pixel(at: point), false)
        }
        refreshCursor(at: point)
    }
    override func mouseUp(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        let moved = dragMoved, decided = grab
        dragOrigin = nil; dragMoved = false; grab = .none
        switch decided {
        case .move: onZoomMove?(moved ? delta(from: origin, to: point) : .zero, true)
        case let .resize(edges): onZoomResize?(edges.flippedVertically, moved ? delta(from: origin, to: point) : .zero, true)
        default: if moved { onZoomDrag?(pixel(at: origin), pixel(at: point), true) } else { onZoomCancel?() }
        }
        refreshCursor(at: point, option: event.modifierFlags.contains(.option))
    }
    /// 押した時点の寄り方の表示倍率で、表示上の移動量を元録画のピクセルへ直す。ドラッグ中は寄り方を変えない。
    /// プレビューの外まで引いても頭打ちにしないよう、点は映像の範囲へ制限しない。端の制限はVideoZoom.movedだけで行う。
    private func delta(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let stage = videoRect
        guard let shown = displayedPixels, stage.width > 0, stage.height > 0 else { return .zero }
        return CGPoint(x: (b.x - a.x) * shown.width / stage.width, y: -(b.y - a.y) * shown.height / stage.height)
    }
    func cancelZoomDrag() -> Bool {
        let dragging = dragOrigin != nil
        dragOrigin = nil; dragMoved = false; grab = .none
        // 握った手やリサイズの向きを残さない。
        if dragging { applyCursor(.arrow); refreshCursor() }
        return dragging
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
        for overlay in [beforeLayer, afterLayer, blackLayer] { overlay.transform = CATransform3DIdentity; overlay.frame = videoRect }
        applyZoom()
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
    func showBoundary(_ image: CGImage?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // 再生位置は変えず、離すとそのコマへ戻る。Playerの準備前でも画像の縦横比を保つ。
        boundaryLayer.frame = base; boundaryLayer.backgroundColor = NSColor.black.cgColor
        boundaryLayer.contents = image; boundaryLayer.isHidden = image == nil
        CATransaction.commit()
    }
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
    var selectedZoom: UUID? { didSet { needsDisplay = true } }
    /// 倍率の表示だけに使う。
    var videoSize: CGSize? { didSet { needsDisplay = true } }
    var onEdit: ((VideoEditDocument, Bool) -> Void)?
    var onBoundaryPreview: ((Double?) -> Void)?
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
        for zoom in document.zooms {
            // 中は引いて動かせることを手で示す。端の伸縮のカーソルを後から足して優先する。
            let lane = zoomLaneRect(zoom).insetBy(dx: 7, dy: 0)
            if lane.width > 0 { addCursorRect(lane, cursor: .openHand) }
            for time in [zoom.range.start, zoom.range.end] {
                addCursorRect(CGRect(x: x(time) - 4, y: zoomLaneRect(zoom).minY, width: 8, height: zoomLaneRect(zoom).height), cursor: .resizeLeftRight)
            }
        }
    }
    func zoomLaneRect(_ zoom: VideoZoom) -> CGRect {
        let lane = VideoTimelineGesture.zoomLane
        return CGRect(x: x(zoom.range.start), y: strip.minY + lane.lowerBound,
                      width: max(2, x(zoom.range.end) - x(zoom.range.start)), height: lane.upperBound - lane.lowerBound)
    }
    /// 長い順の文字の候補。幅が足りない区間では倍率だけを出す。
    private func zoomTitles(_ zoom: VideoZoom) -> [String] {
        guard let videoSize else { return ["ズーム"] }
        let scale = String(format: "×%.1f", zoom.scale(size: videoSize))
        return ["ズーム \(scale)", scale]
    }
    /// 選んだズーム区間の状態と消すキー。秒数のメニューと⌥ドラッグの移動は文言で案内しない。
    func zoomSummary(_ zoom: VideoZoom) -> String {
        zoomTitles(zoom)[0] + String(format: " ・ 長さ %.1f秒 ・ イン・アウト %.1f秒 ・ ⌫ 消す", zoom.range.duration, zoom.ease)
    }
    /// レーンの台形に書く文字。文字の上端の高さでの台形の幅に収まる最も長い候補で、どれも収まらなければnil。
    /// 中ほどの幅で測ると、補間が長い区間では文字の上側が斜辺を越える。
    func zoomLaneTitle(_ zoom: VideoZoom) -> String? {
        let lane = zoomLaneRect(zoom)
        let ramp = min(lane.width / 2, x(zoom.range.start + zoom.ramp) - x(zoom.range.start))
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        // 台形は上へ行くほど両側がrampずつ狭まる。文字は描く矩形の上端、レーンの上端から1ptの所から描く。
        let top = lane.width - 2 * ramp * (lane.height - 1) / lane.height
        return zoomTitles(zoom).first {
            ceil(($0 as NSString).size(withAttributes: [.font: font]).width) <= top - 8
        }
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
    /// 早送りの倍率と同じ型のメニューで、選んだズーム区間のイン・アウトの秒数を変える。台とキーは足さない。
    func showZoomMenu(for id: UUID) {
        guard let zoom = document.zooms.first(where: { $0.id == id }) else { return }
        transitionPopover?.close()
        let popover = NSPopover(); popover.behavior = .transient
        popover.contentViewController = VideoZoomMenu(ease: zoom.ease) { [weak self] seconds in
            guard let self else { return }
            var next = document; next.setZoomEase(id, seconds: seconds); onEdit?(next, true)
        }
        transitionPopover = popover
        popover.show(relativeTo: zoomLaneRect(zoom), of: self, preferredEdge: .minY)
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
        if case let .zoom(index) = hit {
            // 区間を選び、押した位置へ移る。4ptを超えて引くと長さを保って動かす。
            // 選んである区間を動かさずに離すと、補間の秒数のメニューを開く。
            let id = document.zooms[index].id
            zoomBoundaryWasSelected = selectedZoom == id
            dragStart = point; dragDocument = document; selection = nil; selectedZoom = id; zoomBoundaryMoved = false
            onSelection?(); onSeek?(time(point.x))
            return
        }
        dragStart = point; dragDocument = document; selection = nil; zoomBoundaryMoved = false
        if case let .zoomBoundary(index, _) = hit {
            zoomBoundaryWasSelected = selectedZoom == document.zooms[index].id
            selectedZoom = document.zooms[index].id
        } else { selectedZoom = nil }
        onSelection?()
        if hit == .strip { onSeek?(time(point.x)) }
        if case let .boundary(segment, start) = hit {
            onEdit?(document, false)
            onBoundaryPreview?(start ? document.kept[segment].start : document.kept[segment].end)
        }
        if case let .zoomBoundary(index, start) = hit {
            onEdit?(document, false)
            onBoundaryPreview?(start ? document.zooms[index].range.start : document.zooms[index].range.end)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, var next = dragDocument else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch hit {
        case let .boundary(segment, start):
            let boundary = next.moveBoundary(segment: segment, start: start, to: time(point.x))
            onEdit?(next, false); onBoundaryPreview?(boundary)
        case let .zoomBoundary(index, edge):
            // 短い区間では端の判定が区間全体を覆うので、4ptを超えるまではクリックとして扱う。
            if !zoomBoundaryMoved, hypot(point.x - start.x, point.y - start.y) <= 4 { return }
            zoomBoundaryMoved = true
            let boundary = next.moveZoomBoundary(index: index, start: edge, to: time(point.x))
            onEdit?(next, false); onBoundaryPreview?(boundary)
        case let .zoom(index):
            if !zoomBoundaryMoved, hypot(point.x - start.x, point.y - start.y) <= 4 { return }
            zoomBoundaryMoved = true
            // 押した時点の区間から、押した点からの移動量だけ動かす。再生位置は区間と一緒に動かし、ツールの枠を見失わない。
            let original = next.zooms[index].range.start
            guard let moved = next.moveZoomRange(index: index, by: time(point.x) - time(start.x)) else { return }
            onEdit?(next, false); onSeek?(time(start.x) + moved - original)
        case .strip:
            selection = VideoTimelineGesture.selection(from: start.x - strip.minX, to: point.x - strip.minX,
                width: strip.width, duration: document.duration)
            onSeek?(time(point.x)); onSelection?()
        case .outside: break
        }
    }
    private var draggingBoundary: Bool {
        switch hit { case .boundary, .zoomBoundary: true; default: false }
    }
    /// ズーム区間の端か中を押してから、4ptを超えて動かしたか。
    private var zoomBoundaryMoved = false
    private var zoomBoundaryWasSelected = false
    override func mouseUp(with event: NSEvent) {
        if draggingBoundary { onEdit?(document, true); onBoundaryPreview?(nil) }
        if case .zoom = hit, zoomBoundaryMoved { onEdit?(document, true) }
        // 選んである区間を端でも中でも動かさずに離したら、秒数のメニューを開く。
        var menu: UUID?
        switch hit {
        case let .zoomBoundary(index, _), let .zoom(index):
            if !zoomBoundaryMoved, zoomBoundaryWasSelected, document.zooms.indices.contains(index) { menu = document.zooms[index].id }
        default: break
        }
        dragStart = nil; dragDocument = nil; hit = .outside; zoomBoundaryMoved = false; zoomBoundaryWasSelected = false
        if let menu { showZoomMenu(for: menu) }
    }
    /// 開いている秒数のメニュー。テストだけに使う。
    var zoomMenu: VideoZoomMenu? { transitionPopover?.contentViewController as? VideoZoomMenu }
    func cancelInteraction() -> Bool {
        let interacting = dragStart != nil
        if draggingBoundary { onBoundaryPreview?(nil) }
        // 引いている途中の変更は履歴に入っていないので、引く前へ戻す。ツールの切り替えなどで取り消しても、未確定の形を残さない。
        if let original = dragDocument, document != original { onEdit?(original, false) }
        // 区間を動かした分だけ再生位置も動かしたので、押した位置へ戻す。戻さないとツールの枠の対象を見失う。
        if case .zoom = hit, zoomBoundaryMoved, let start = dragStart { onSeek?(time(start.x)) }
        dragStart = nil; dragDocument = nil; hit = .outside; zoomBoundaryMoved = false; zoomBoundaryWasSelected = false
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
        // ズーム区間は墨の台形に白い縁で、イン・アウトの補間の幅を斜辺に見せる。切った範囲の墨の斜線とは別のレーンに置く。
        // 白い動画のコマの上でも見落とさないよう、つなぎ方のバッジと同じ墨の地にする。暗い動画では白い縁で形を見せる。
        for zoom in document.zooms {
            let lane = zoomLaneRect(zoom)
            let ramp = min(lane.width / 2, x(zoom.range.start + zoom.ramp) - x(zoom.range.start))
            let shape = NSBezierPath()
            shape.move(to: CGPoint(x: lane.minX, y: lane.maxY)); shape.line(to: CGPoint(x: lane.minX + ramp, y: lane.minY))
            shape.line(to: CGPoint(x: lane.maxX - ramp, y: lane.minY)); shape.line(to: CGPoint(x: lane.maxX, y: lane.maxY)); shape.close()
            UITheme.ink.withAlphaComponent(0.92).setFill(); shape.fill()
            NSColor.white.withAlphaComponent(0.6).setStroke(); shape.lineWidth = 1; shape.stroke()
            if let title = zoomLaneTitle(zoom) {
                UIDrawing.text(title, in: lane.insetBy(dx: ramp / 2 + 4, dy: 1), size: 10, color: .white, weight: .semibold, centered: true)
            }
            if zoom.id == selectedZoom {
                let outline = NSBezierPath(rect: lane.insetBy(dx: 1, dy: 1)); outline.lineWidth = 2; UITheme.indigo.setStroke(); outline.stroke()
            }
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
        else if let zoom = document.zooms.first(where: { $0.id == selectedZoom }) {
            UIDrawing.text(zoomSummary(zoom), in: CGRect(x: 24, y: 49, width: 680, height: 16), size: 11, color: UITheme.text)
        }
    }
}

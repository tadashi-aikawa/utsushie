import AppKit
import UtsushieCore

@MainActor
final class ThumbnailController {
    private(set) var cards: [ThumbnailCard] = []
    private var libraryCards: [ThumbnailCard] = []
    private var allCards: [ThumbnailCard] { cards + libraryCards }
    private var suspended = false
    private var editingCards: Set<UUID> = []
    private var removingURLs: Set<URL> = []
    private var keyboardTargetID: UUID?
    let recentImages = RecentImageMemory()
    var annotationConfig: () -> UtsushieConfig = { ConfigLoader.load().config }
    var editorFocus = AnnotationApplicationFocus()
    var makeVideoSession: (SharedArtifact, Int) -> VideoEditSession = { VideoEditSession(artifact: $0, fps: $1) }
    var onArtifactsChange: (() -> Void)?
    var onLibraryExportStatus: ((URL, String?) -> Void)?

    @discardableResult
    func add(_ artifact: SharedArtifact, image: CGImage?, copied: Bool, seconds: Double, screen: NSScreen?, finalizing: Bool = false,
             imageState: ImageEditState? = nil, libraryOnly: Bool = false) -> UUID {
        let card = ThumbnailCard(artifact: artifact, image: image, copied: copied, seconds: seconds, finalizing: finalizing, imageState: imageState)
        card.screen = screen ?? NSScreen.main ?? NSScreen.screens.first
        card.editorFocus = editorFocus
        card.makeVideoSession = makeVideoSession
        card.onEditingChange = { [weak self, weak card] editing in
            guard let self, let card else { return }
            if editing { editingCards.insert(card.id) } else { editingCards.remove(card.id) }
            for other in allCards { other.setEditingSuspended(!editingCards.isEmpty, restart: !editing) }
            // 画像の再編集はRecentImageMemoryの最新10件へ委ねる。動画だけ一覧を閉じるまで元を持つ。
            if !editing && libraryOnly && card.artifact.kind == .webP { card.onClose?() }
        }
        card.setEditingSuspended(!editingCards.isEmpty)
        card.onArtifactChange = { [weak self, weak card] in
            guard let self, let card else { return }
            rememberImage(card)
        }
        card.annotationConfig = { [weak self] in self?.annotationConfig() ?? UtsushieConfig() }
        card.onStills = { [weak self, weak card] stills in
            guard let self, let card else { return }
            for still in stills {
                if card.libraryEditing {
                    let state = ImageEditState(original: still.image)
                    if let files = try? RecentCaptureStore.files(in: still.artifact.url.deletingLastPathComponent()) {
                        recentImages.remember(state, at: still.artifact.url, among: files)
                    }
                } else { self.add(still.artifact, image: still.image, copied: true, seconds: seconds, screen: card.screen) }
            }
            if !stills.isEmpty { onArtifactsChange?() }
        }
        card.onExportStatus = { [weak self, weak card] status in
            guard let card else { return }
            self?.onLibraryExportStatus?(card.artifact.url, status)
        }
        card.canShow = { [weak self] in !libraryOnly && self?.suspended == false }
        card.onRequestKeys = { [weak self, weak card] in
            guard let self, let card, self.cards.contains(where: { $0 === card }) else { return }
            self.keyboardTargetID = card.id
            self.updateKeyboardTarget()
        }
        card.onClose = { [weak self, weak card] in
            guard let self, let card else { return }
            card.close()
            self.cards.removeAll { $0 === card }
            self.libraryCards.removeAll { $0 === card }
            if !libraryOnly {
                if self.keyboardTargetID == card.id { self.keyboardTargetID = self.cards.last?.id }
                self.updateKeyboardTarget(); self.layout()
            }
        }
        if libraryOnly { libraryCards.append(card) } else { cards.append(card) }
        if !finalizing { rememberImage(card) }
        if !libraryOnly {
            keyboardTargetID = card.id
            updateKeyboardTarget(); layout()
            if !suspended { card.show() }
        }
        return card.id
    }
    func complete(_ id: UUID, artifact: SharedArtifact, image: CGImage, copied: Bool) {
        cards.first { $0.id == id }?.complete(artifact: artifact, image: image, copied: copied)
        if !cards.contains(where: { $0.id == id }) { onArtifactsChange?() }
    }
    func remove(_ id: UUID) {
        cards.first { $0.id == id }?.onClose?()
    }
    func setSuspended(_ value: Bool) {
        suspended = value
        cards.forEach { value ? $0.hide() : $0.show() }
    }
    func card(for url: URL) -> ThumbnailCard? {
        allCards.first { $0.artifact.url.standardizedFileURL == url.standardizedFileURL }
    }
    /// カードの編集セッションを使うが、一覧専用のカードは配置・キー・寿命へ参加させない。
    func editFromLibrary(_ url: URL, onReturn: @escaping () -> Void) async throws {
        guard !removingURLs.contains(url.standardizedFileURL) else {
            throw CaptureError.unavailable("ゴミ箱へ移しています")
        }
        var target = card(for: url)
        if target == nil {
            let file = RecentCaptureFile(url: url.standardizedFileURL, date: Date())
            let state = recentImages.state(for: url)
            let capture = try await RecentCaptureStore.load(file, maximumPixelSize: state != nil || file.kind == .mp4 ? 320 : nil)
            guard !Task.isCancelled else { return }
            target = card(for: url)
            if target == nil {
                add(capture.artifact, image: capture.image, copied: false, seconds: 5, screen: NSScreen.main,
                    imageState: state, libraryOnly: true)
                target = card(for: url)
            }
        }
        guard let target, !removingURLs.contains(url.standardizedFileURL) else { return }
        guard target.canEdit else { throw CaptureError.unavailable("書き出しが終わるまでお待ちください") }
        target.openEditorFromLibrary(onReturn: onReturn)
    }
    func closeLibrarySessions() {
        for card in libraryCards { card.onClose?() }
    }
    func pruneMemory(to files: [RecentCaptureFile]) { recentImages.retain(files) }
    func canRemoveFromLibrary(_ url: URL) -> Bool {
        guard !removingURLs.contains(url.standardizedFileURL) else { return false }
        return allCards.filter { $0.artifact.url.standardizedFileURL == url.standardizedFileURL }
            .allSatisfy { $0.editor == nil && $0.videoEditor == nil && !$0.finalizing }
    }
    /// 非同期のゴミ箱移動中に、カードから同じファイルの編集を始めない。
    func reserveLibraryRemoval(_ urls: [URL]) {
        removingURLs.formUnion(urls.map(\.standardizedFileURL))
        for card in allCards where removingURLs.contains(card.artifact.url.standardizedFileURL) {
            card.setRemovalPending(true)
        }
    }
    func finishLibraryRemoval(_ urls: [URL], removed: Set<URL>) {
        forgetLibraryFiles(removed)
        removingURLs.subtract(urls.map(\.standardizedFileURL))
        for card in allCards where urls.contains(card.artifact.url.standardizedFileURL) { card.setRemovalPending(false) }
    }
    func forgetLibraryFiles(_ urls: Set<URL>) {
        let normalized = Set(urls.map(\.standardizedFileURL))
        for card in allCards where normalized.contains(card.artifact.url.standardizedFileURL) { card.onClose?() }
        recentImages.remove(normalized)
    }
    private func rememberImage(_ card: ThumbnailCard) {
        if let files = try? RecentCaptureStore.files(in: card.artifact.url.deletingLastPathComponent()) {
            if let state = card.imageState { recentImages.remember(state, at: card.artifact.url, among: files) }
            else { pruneMemory(to: files) }
        }
        onArtifactsChange?()
    }
    @discardableResult
    func restore(_ url: URL, seconds: Double, screen: NSScreen?) async throws -> UUID {
        guard !removingURLs.contains(url.standardizedFileURL) else { throw CaptureError.unavailable("ゴミ箱へ移しています") }
        if let existing = card(for: url) { bringForward(existing); return existing.id }
        let file = RecentCaptureFile(url: url.standardizedFileURL, date: Date())
        let state = recentImages.state(for: url)
        let capture = try await RecentCaptureStore.load(file, maximumPixelSize: state != nil || file.kind == .mp4 ? 320 : nil)
        // 読み込みを待つ間に同じファイルが選ばれても、カードを重ねて増やさない。
        guard !removingURLs.contains(url.standardizedFileURL), FileManager.default.fileExists(atPath: url.path) else {
            throw CaptureError.unavailable("ファイルが移動されました")
        }
        if let existing = card(for: url) { bringForward(existing); return existing.id }
        return add(capture.artifact, image: capture.image, copied: false, seconds: seconds, screen: screen, imageState: state)
    }
    private func bringForward(_ card: ThumbnailCard) {
        keyboardTargetID = card.id; updateKeyboardTarget()
        card.restartLifetime()
        if !suspended { card.bringForward() }
    }
    private func updateKeyboardTarget() {
        for card in cards { card.setKeyboardTarget(card.id == keyboardTargetID) }
    }
    private func layout() {
        // 配列は古い順。逆順に下から置くので最新が最下段。
        var indices: [ObjectIdentifier: Int] = [:]
        for card in cards.reversed() {
            guard let screen = card.screen else { continue }
            let key = ObjectIdentifier(screen)
            let index = indices[key] ?? 0
            card.panel.setFrameOrigin(CardPresentation.stackOrigin(index: index, visible: screen.visibleFrame, cardSize: card.panel.frame.size))
            indices[key] = index + 1
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
    var onStills: (([VideoStillArtifact]) -> Void)?
    var onEditingChange: ((Bool) -> Void)?
    var onArtifactChange: (() -> Void)?
    var onExportStatus: ((String?) -> Void)?
    private var onLibraryReturn: (() -> Void)?
    private(set) var libraryEditing = false
    private var view: ThumbnailView!
    private(set) var timer: Timer?
    private var remaining: Double
    private var started: Date?
    private var hovered = false
    private var visible = false
    private var dragging = false
    private var saving = false
    private var editingSuspended = false
    private var removalPending = false
    private var keyMonitor: Any?
    private var previousApplication: NSRunningApplication?
    private var isKeyboardTarget = false
    private let lifetime: Double
    let imageState: ImageEditState?
    private(set) var editor: AnnotationEditorController?
    private(set) var videoEditor: VideoEditorController?
    private var videoSession: VideoEditSession?
    private var closed = false
    var annotationConfig: () -> UtsushieConfig = { UtsushieConfig() }
    var canShow: () -> Bool = { true }
    var editorFocus = AnnotationApplicationFocus()
    var copyImage: (SharedArtifact, Data, ClipboardMode) -> Bool = {
        ClipboardWriter.copy($0, data: $1, mode: $2, to: .general, preservingOnFailure: true)
    }
    var copyEntries: ([ClipboardEntry], ClipboardMode) -> Bool = {
        ClipboardWriter.copy($0, mode: $1, to: .general, preservingOnFailure: true)
    }
    var makeVideoSession: (SharedArtifact, Int) -> VideoEditSession = { VideoEditSession(artifact: $0, fps: $1) }
    var canEdit: Bool { !finalizing && !removalPending && (artifact.kind == .mp4 || imageState != nil) }
    var canDrag: Bool { !finalizing && !removalPending }
    private(set) var finalizing: Bool

    init(artifact: SharedArtifact, image: CGImage?, copied: Bool, seconds: Double, finalizing: Bool, imageState: ImageEditState? = nil) {
        self.artifact = artifact; remaining = seconds; self.finalizing = finalizing
        lifetime = seconds
        self.imageState = artifact.kind == .webP ? imageState ?? image.map { ImageEditState(original: $0) } : nil
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
        onArtifactChange?()
        resumeTimer()
    }
    func show(claimKeyboard: Bool = true) {
        guard editor == nil, videoEditor == nil, !closed else { return }
        visible = true; panel.orderFrontRegardless()
        if claimKeyboard { claimKeys() }
        resumeTimer()
    }
    func hide() {
        visible = false; pauseTimer(); releaseKeys(); hovered = false; panel.orderOut(nil)
    }
    func close() {
        closed = true
        editor?.window.close(); videoEditor?.window.close()
        if !finalizing { videoSession?.close() }
        let restore = panel.isKeyWindow
        hide(); panel.close(); onClose = nil
        if restore { restoreFocus() }
    }
    func bringForward() {
        if let editor { editor.window.orderFrontRegardless(); editor.window.makeKey(); return }
        if let videoEditor { videoEditor.window.orderFrontRegardless(); videoEditor.window.makeKey(); return }
        show()
    }
    func restartLifetime() { pauseTimer(); remaining = lifetime; resumeTimer() }
    func setEditingSuspended(_ value: Bool, restart: Bool = false) {
        pauseTimer(); editingSuspended = value
        if restart { remaining = lifetime }
        resumeTimer()
    }
    func setRemovalPending(_ value: Bool) {
        pauseTimer(); removalPending = value; view.refreshControls()
        resumeTimer()
    }
    func setKeyboardTarget(_ value: Bool) {
        isKeyboardTarget = value
        if !value { releaseKeys() }
    }
    private func claimKeys() {
        guard isKeyboardTarget, visible, editor == nil, videoEditor == nil, !saving, !dragging else { return }
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
            case 36, 76, 14: if !event.isARepeat { self.edit() }; return nil // Enter, テンキーEnter, E
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
    func openEditorFromLibrary(onReturn: @escaping () -> Void) {
        libraryEditing = true; onLibraryReturn = onReturn
        if editor != nil || videoEditor != nil { bringForward() } else { startEdit() }
    }
    private func returnToLibrary() {
        onLibraryReturn?(); onLibraryReturn = nil
        // 動画はonCloseの後にonCompleteを呼ぶ。ここで起点を消すと静止画カードが出てしまう。
    }
    @objc func edit() {
        libraryEditing = false; onLibraryReturn = nil
        startEdit()
    }
    private func startEdit() {
        if artifact.kind == .mp4 { editVideo(); return }
        guard canEdit, editor == nil, let imageState else { return }
        hide()
        let controller = AnnotationEditorController(image: imageState.original, document: imageState.history.document, screen: screen,
            applicationFocus: editorFocus, privacyConfig: annotationConfig().privacy, history: imageState.history)
        editor = controller
        onEditingChange?(true)
        controller.onComplete = { [weak self, weak controller] image, _ in
            guard let self, let controller else { return }
            let config = self.annotationConfig()
            let data = try await Task.detached(priority: .userInitiated) {
                try WebPEncoder.encode(image, quality: config.quality, lossless: config.lossless)
            }.value
            let updated = try AnnotationSave.commit(data: data, artifact: self.artifact, mode: config.clipboard,
                imageSize: CGSize(width: image.width, height: image.height), copy: self.copyImage)
            imageState.history = controller.canvas.history
            self.complete(artifact: updated, image: image, copied: true)
        }
        controller.onClose = { [weak self] in
            guard let self else { return }
            self.editor = nil; self.remaining = self.lifetime
            // 編集パネルが手放したキーを貼り付け先へ返す。ホバー時には再び取得できる。
            if self.canShow() { self.show(claimKeyboard: false) }
            self.onEditingChange?(false)
            self.returnToLibrary()
        }
        controller.show()
    }
    private func editVideo() {
        guard canEdit, videoEditor == nil, let duration = artifact.duration, duration > 0 else { return }
        hide()
        if videoSession == nil { videoSession = makeVideoSession(artifact, annotationConfig().video.fps) }
        guard let session = videoSession else { return }
        let controller = VideoEditorController(source: session.sourceURL, document: session.document, screen: screen, focus: editorFocus)
        videoEditor = controller
        onEditingChange?(true)
        controller.onClose = { [weak self] in
            guard let self else { return }
            videoEditor = nil; remaining = lifetime
            if canShow() { show(claimKeyboard: false) }
            onEditingChange?(false)
            returnToLibrary()
        }
        controller.onComplete = { [weak self] document in
            guard let self else { return }
            // 失敗しても、次のEで元の録画に今回の範囲を重ねる。
            session.document = document
            let config = annotationConfig()
            finalizing = true; pauseTimer(); view.copied = false; view.refreshControls(); view.needsDisplay = true
            onExportStatus?("書き出し中…")
            Task { [self] in
                defer { if closed { session.close() } }
                do {
                    let result = try await session.finish(artifact: artifact, config: config) {
                        copyEntries($0, config.clipboard)
                    }
                    if let image = result.image {
                        complete(artifact: result.video, image: image, copied: result.stills.isEmpty)
                    } else {
                        finalizing = false; view.copied = result.stills.isEmpty
                        view.refreshControls(); view.needsDisplay = true; resumeTimer()
                        onArtifactChange?()
                    }
                    onStills?(result.stills)
                    onExportStatus?(nil)
                    libraryEditing = false
                } catch {
                    finalizing = false; view.refreshControls(); view.needsDisplay = true
                    onExportStatus?("! 動画の編集を完了できませんでした: " + error.localizedDescription)
                    let reportInLibrary = libraryEditing
                    libraryEditing = false
                    if reportInLibrary { return }
                    if !closed {
                        // Eで開き直すまで失敗の説明を読めるように寿命を止める。
                        hovered = true
                        let alert = NSAlert(); alert.messageText = "動画の編集を完了できませんでした"
                        alert.informativeText = error.localizedDescription + "\nEで開き直して再試行できます。切った範囲と静止画の印は保持しています。"
                        NSApp.activate(); await alert.beginSheetModal(for: panel)
                    }
                }
            }
        }
        controller.show()
    }
    private func pauseTimer() {
        if let started { remaining = max(0, remaining - Date().timeIntervalSince(started)) }
        timer?.invalidate(); timer = nil; started = nil
    }
    private func resumeTimer() {
        guard visible, editor == nil, videoEditor == nil, !closed, !hovered, !dragging, !saving, !finalizing, !editingSuspended, !removalPending, timer == nil else { return }
        started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: max(0.01, remaining), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.onClose?() }
        }
    }
    func hover(_ value: Bool) {
        guard editor == nil, videoEditor == nil, visible else { return }
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
            (.annotate, card.artifact.kind == .mp4 ? "scissors" : "pencil", "⏎", card.artifact.kind == .mp4 ? "動画を編集 ⏎" : "注釈 ⏎", #selector(ThumbnailCard.edit)),
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
        guard !dragged, let downEvent, let card, card.canDrag,
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

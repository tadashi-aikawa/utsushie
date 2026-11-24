import AppKit
import UtsushieCore

@MainActor
final class ThumbnailController {
    private(set) var cards: [ThumbnailCard] = []
    private var libraryCards: [ThumbnailCard] = []
    private var allCards: [ThumbnailCard] { cards + libraryCards }
    private var suspended = false
    private var holdingForImport = false
    private var hidden: Bool { suspended || holdingForImport }
    private var editingCards: Set<UUID> = []
    private var removingURLs: Set<URL> = []
    private var keyboardTargetID: UUID?
    let recentImages = RecentImageMemory()
    /// ファイルへ書き出す・変換する非同期の作業。一覧を閉じてカードが外れても、終わるまで数える。
    let backgroundWork = BackgroundWorkTracker()
    /// 設定の再読込で変わったら、表示中のカードも新しい隅へ積み直す。
    var corner: CardCorner = .bottomRight { didSet { if corner != oldValue { layout() } } }
    var annotationConfig: () -> UtsushieConfig = { ConfigLoader.load().config }
    var editorFocus = AnnotationApplicationFocus()
    var makeVideoSession: (SharedArtifact, Int) -> VideoEditSession = { VideoEditSession(artifact: $0, fps: $1) }
    var onArtifactsChange: (() -> Void)?
    /// 表示中のカードのウィンドウが増えた。撮影用UIの除外に使うウィンドウの一覧を取り直す合図にする。
    var onCardAdded: (() -> Void)?
    var onLibraryExportStatus: ((URL, String?) -> Void)?
    /// 保存時の問題をメニューの警告へ出す。
    var onWarning: ((String) -> Void)?
    var beforeShowingCard: ((NSWindow) async -> Bool)?
    var trashFiles: @Sendable ([URL]) -> CaptureLibraryTrashResult = { CaptureLibraryFileActions.trash($0) }
    var reportTrashFailure: (ThumbnailCard) -> Void = { $0.showTrashFailure() }
    private(set) var trashTask: Task<Void, Never>?
    let pins = ImagePinController()
    /// 浮かべる画像の読み込みや表示に失敗した。
    var onPinFailure: ((Error) -> Void)?

    @discardableResult
    func add(_ artifact: SharedArtifact, image: CGImage?, copied: Bool, seconds: Double, screen: NSScreen?, finalizing: Bool = false,
             imageState: ImageEditState? = nil, libraryOnly: Bool = false, notice: String? = nil) -> UUID {
        let card = ThumbnailCard(artifact: artifact, image: image, copied: copied, seconds: seconds, finalizing: finalizing, imageState: imageState)
        card.notice = notice
        card.screen = screen ?? NSScreen.main ?? NSScreen.screens.first
        card.editorFocus = editorFocus
        card.makeVideoSession = makeVideoSession
        card.backgroundWork = backgroundWork
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
        card.onStills = { [weak self, weak card] stills, copied in
            guard let self, let card else { return }
            for still in stills {
                if card.libraryEditing {
                    let state = ImageEditState(original: still.image, scale: still.artifact.pixelScale)
                    if let files = try? RecentCaptureStore.files(in: still.artifact.url.deletingLastPathComponent()) {
                        recentImages.remember(state, at: still.artifact.url, among: files)
                    }
                } else { self.add(still.artifact, image: still.image, copied: copied, seconds: seconds, screen: card.screen) }
            }
            if !stills.isEmpty { onArtifactsChange?() }
            if stills.contains(where: \.usedDefaultName) { onWarning?(CaptureFileNaming.fallbackWarning) }
        }
        card.onExportStatus = { [weak self, weak card] status in
            guard let card else { return }
            self?.onLibraryExportStatus?(card.artifact.url, status)
        }
        card.canShow = { [weak self] in !libraryOnly && self?.hidden == false }
        card.prepareToShow = { [weak self, weak card] in
            guard let prepare = self?.beforeShowingCard, let card else { return nil }
            return Task { await prepare(card.panel) }
        }
        card.onRequestKeys = { [weak self, weak card] in
            guard let self, let card, self.cards.contains(where: { $0 === card }) else { return }
            self.keyboardTargetID = card.id
            self.updateKeyboardTarget()
        }
        card.onTrash = { [weak self, weak card] in
            guard let self, let card else { return }
            trash(card)
        }
        card.onPin = { [weak self, weak card] in
            guard let self, let card else { return }
            Task {
                do { try await self.pin(card.artifact.url, screen: card.screen) }
                catch { self.onPinFailure?(error) }
            }
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
            if !hidden { card.show() }
            onCardAdded?()
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
    /// 撮影したカードのEと同じく、カードを隠して編集画面を開く。一覧専用のカードも、restoreが返したものを開く。
    /// キーの受け手もこのカードにし、後から表示するほかのカードに編集画面のキーを取らせない。
    /// 一覧専用のカードはキーを持たないので、表示中のカードはどれも受け手でなくなる。
    func edit(_ id: UUID) {
        guard let card = allCards.first(where: { $0.id == id }) else { return }
        keyboardTargetID = id; updateKeyboardTarget()
        // 同じファイルの編集画面が開いていれば、新しく開かずに前へ出す。
        if card.editor != nil || card.videoEditor != nil { card.bringForward() } else { card.edit() }
    }
    /// 撮影・録画の間はカードを隠す。取り込みの保持とは別に持ち、どちらも解けたときだけ戻す。
    func setSuspended(_ value: Bool) {
        suspended = value; applyVisibility()
    }
    /// Finderからの取り込みの間はカードを隠して寿命を止める。動画の変換を待つ間に、先に足したカードが消えないため。
    func setHoldingForImport(_ value: Bool) {
        holdingForImport = value; applyVisibility()
    }
    private func applyVisibility() {
        cards.forEach { hidden ? $0.hide() : $0.show() }
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
    /// 保存済みのWebPを読み直して浮かべる。撮った範囲と倍率はカードがあればそこから取り、無ければ1xで画面の中央に出す。
    func pin(_ url: URL, screen: NSScreen?) async throws {
        guard url.pathExtension.lowercased() == ArtifactKind.webP.fileExtension else {
            throw CaptureError.unavailable("浮かべられるのは画像だけです")
        }
        guard !removingURLs.contains(url.standardizedFileURL) else { throw CaptureError.unavailable("ゴミ箱へ移しています") }
        let artifact = card(for: url)?.artifact
        pins.beforeShowing = beforeShowingCard
        try await pins.pin(url: url, scale: artifact?.pixelScale ?? recentImages.state(for: url)?.history.document.scale,
                           anchor: artifact?.captureFrame, screen: screen)
    }
    func pruneMemory(to files: [RecentCaptureFile]) { recentImages.retain(files) }
    /// 開いている編集画面。ファイルへ書く作業はカードの寿命と切り離して`backgroundWork`で数える。
    var hasEditorOpen: Bool { !editingCards.isEmpty }
    func isRemoving(_ url: URL) -> Bool { removingURLs.contains(url.standardizedFileURL) }
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
    /// 一覧のゴミ箱と同じ予約を使い、移している間は同じファイルの編集・ドラッグ・一覧からの削除を止める。
    private func trash(_ card: ThumbnailCard) {
        let url = card.artifact.url.standardizedFileURL
        guard canRemoveFromLibrary(url) else { return }
        reserveLibraryRemoval([url])
        let trash = trashFiles
        backgroundWork.begin(.trash)
        trashTask = Task { [self] in
            defer { backgroundWork.end(.trash) }
            // 移し終えたらforgetLibraryFilesがカードを閉じ、動画の隠し元も後片付けする。
            let result = await Task.detached(priority: .userInitiated) { trash([url]) }.value
            finishLibraryRemoval([url], removed: result.removed)
            onArtifactsChange?()
            if !result.failed.isEmpty { reportTrashFailure(card) }
        }
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
        if !hidden { card.bringForward() }
    }
    private func updateKeyboardTarget() {
        for card in cards { card.setKeyboardTarget(card.id == keyboardTargetID) }
    }
    private func layout() {
        // 配列は古い順。逆順に隅から置くので最新が隅に来る。
        var indices: [ObjectIdentifier: Int] = [:]
        for card in cards.reversed() {
            guard let screen = card.screen else { continue }
            let key = ObjectIdentifier(screen)
            let index = indices[key] ?? 0
            card.panel.setFrameOrigin(CardPresentation.stackOrigin(index: index, visible: screen.visibleFrame,
                cardSize: card.panel.frame.size, corner: corner))
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
    var onTrash: (() -> Void)?
    var onPin: (() -> Void)?
    var onRequestKeys: (() -> Void)?
    var onStills: (([VideoStillArtifact], Bool) -> Void)?
    var onEditingChange: ((Bool) -> Void)?
    var onArtifactChange: (() -> Void)?
    var onExportStatus: ((String?) -> Void)?
    private var onLibraryReturn: (() -> Void)?
    private(set) var libraryEditing = false
    private var view: ThumbnailView!
    /// 保存の状態に添える知らせ。表示中に変えたら描き直す。
    var notice: String? {
        get { view.notice }
        set { view.notice = newValue; view.needsDisplay = true }
    }
    private(set) var timer: Timer?
    private var remaining: Double
    private var started: Date?
    private var hovered = false
    private var visible = false
    private var dragging = false
    private var saving = false
    private var editingSuspended = false
    private var removalPending = false
    private(set) var alerting = false
    private var keyMonitor: Any?
    private var previousApplication: NSRunningApplication?
    private var isKeyboardTarget = false
    private let lifetime: Double
    let imageState: ImageEditState?
    private(set) var editor: AnnotationEditorController?
    private(set) var videoEditor: VideoEditorController?
    private var videoSession: VideoEditSession?
    private var closed = false
    private var showTask: Task<Void, Never>?
    var prepareToShow: (() -> Task<Bool, Never>?)?
    var annotationConfig: () -> UtsushieConfig = { UtsushieConfig() }
    var canShow: () -> Bool = { true }
    var editorFocus = AnnotationApplicationFocus()
    /// 閉じる編集画面のキーが、ほかへ移っていないか。閉じる時点と、カードを出す時点の両方で確かめる。
    /// テストではアプリが前面にならず、編集画面がキーにならないので差し替える。
    var keepsEditorFocus: (NSWindow?) -> Bool = { ThumbnailCard.keepsEditorFocus($0) }
    /// 自分が前面のまま、キーが閉じる編集画面にあるか、どこにも無い。閉じた後は編集画面が解放されてnilになる。
    static func keepsEditorFocus(_ editor: NSWindow?) -> Bool {
        guard NSApp.isActive else { return false }
        guard let key = NSApp.keyWindow else { return true }
        return key === editor
    }
    var copyImage: (SharedArtifact, Data, ClipboardMode) -> Bool = {
        ClipboardWriter.copy($0, data: $1, mode: $2, to: .general, preservingOnFailure: true)
    }
    var copyEntries: ([ClipboardEntry], ClipboardMode) -> Bool = {
        ClipboardWriter.copy($0, mode: $1, to: .general, preservingOnFailure: true)
    }
    var makeVideoSession: (SharedArtifact, Int) -> VideoEditSession = { VideoEditSession(artifact: $0, fps: $1) }
    /// 書き出しの開始から完了までを数える先。カードの寿命と切り離すため、コントローラーが持つ。
    var backgroundWork: BackgroundWorkTracker?
    var canEdit: Bool { !finalizing && !removalPending && (artifact.kind == .mp4 || imageState != nil) }
    var canDrag: Bool { !finalizing && !removalPending }
    var canTrash: Bool { !finalizing && !removalPending && editor == nil && videoEditor == nil && !closed }
    var canPin: Bool { artifact.kind == .webP && !finalizing && !removalPending && !closed }
    /// 一覧と同じ2回押しの確認。対象は常にこのカードのファイル1件。
    private(set) var trashConfirmation = CaptureLibraryDeleteConfirmation()
    private(set) var finalizing: Bool

    init(artifact: SharedArtifact, image: CGImage?, copied: Bool, seconds: Double, finalizing: Bool, imageState: ImageEditState? = nil) {
        self.artifact = artifact; remaining = seconds; self.finalizing = finalizing
        lifetime = seconds
        self.imageState = artifact.kind == .webP ? imageState ?? image.map { ImageEditState(original: $0, scale: artifact.pixelScale) } : nil
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
    func show(claimKeyboard: Bool = true) { show(claimingKeys: { claimKeyboard }) }
    /// キーを取るかは、表示する時点で決める。録画中はフィルターの更新を待つので、その間に変わりうる。
    private func show(claimingKeys: @escaping () -> Bool) {
        guard editor == nil, videoEditor == nil, !closed else { return }
        showTask?.cancel()
        if let preparation = prepareToShow?() {
            showTask = Task { [weak self] in
                let ready = await preparation.value
                guard ready, !Task.isCancelled, let self, self.canShow(),
                      self.editor == nil, self.videoEditor == nil, !self.closed else { return }
                self.showPrepared(claimKeyboard: claimingKeys())
                self.showTask = nil
            }
        } else { showPrepared(claimKeyboard: claimingKeys()) }
    }
    private func showPrepared(claimKeyboard: Bool) {
        visible = true; panel.orderFrontRegardless()
        if claimKeyboard { claimKeys() }
        resumeTimer()
    }
    func hide() {
        disarmTrash(.resignKey)
        showTask?.cancel(); showTask = nil
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
        trashConfirmation.interrupt(.otherKey)
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
            guard let self, self.isKeyboardTarget, self.visible, self.panel.isKeyWindow, event.window === self.panel else { return event }
            return self.handleKey(event) ? nil : event
        }
    }
    /// 物理keyCodeで判定する。ゴミ箱の確認中は、X以外のキーで確認を解除する。Escは解除だけで閉じない。
    func handleKey(_ event: NSEvent) -> Bool {
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if plain && event.keyCode == 7 { pressTrash(isRepeat: event.isARepeat); return true } // X
        let wasArmed = disarmTrash(event.keyCode == 53 ? .escape : .otherKey)
        guard plain else { return false }
        switch event.keyCode {
        case 36, 76, 14: if !event.isARepeat { edit() }; return true // Enter, テンキーEnter, E
        case 1: if !event.isARepeat { saveAs() }; return true // S
        case 31: if !event.isARepeat { reveal() }; return true // O
        case 35: if !event.isARepeat { pin() }; return true // P
        case 53: if !wasArmed && !event.isARepeat { onClose?() }; return true // Esc
        default: return false
        }
    }
    @objc func trash() { pressTrash(isRepeat: false) }
    @objc func pin() {
        disarmTrash(.click)
        guard canPin else { return }
        onPin?()
    }
    func pressTrash(isRepeat: Bool) {
        guard canTrash else { return }
        let action = trashConfirmation.press(selected: [artifact.url], isRepeat: isRepeat)
        view.refreshControls()
        if action == .trash { onTrash?() }
    }
    @discardableResult
    func disarmTrash(_ reason: CaptureLibraryDeleteInterruption) -> Bool {
        guard trashConfirmation.interrupt(reason) else { return false }
        view.refreshControls(); return true
    }
    func showTrashFailure() {
        guard !closed, visible else { return }
        // 説明を読めるように、シートを閉じるまで寿命を止める。ホバーの出入りでは再開しない。
        alerting = true; pauseTimer()
        let alert = NSAlert(); alert.messageText = "ゴミ箱へ移せませんでした"
        alert.informativeText = "ファイルは移動されたか、移す権限がありません。"
        NSApp.activate()
        alert.beginSheetModal(for: panel) { [weak self] _ in
            guard let self else { return }
            alerting = false
            hovered = panel.frame.contains(NSEvent.mouseLocation)
            resumeTimer()
        }
    }
    private func releaseKeys() {
        stopKeys()
        if panel.isKeyWindow { panel.resignKey() }
        panel.receivesKeyboard = false
    }
    /// 閉じた後のカードがキーを持つので、カードを閉じたときは編集を開く直前の前面アプリへ返す。
    /// 自分が前面だったら返さない。撮影時のアプリへ戻すと、開いている一覧から別のアプリへ移ってしまう。
    private func rememberApplicationBeforeEditing() {
        let front = NSWorkspace.shared.frontmostApplication
        previousApplication = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
    }
    /// 編集画面を閉じたら、撮影直後と同じくキーを取って出し直す。完了・Escの後に、続けてX・⏎などを押せるようにする。
    /// 閉じた編集画面のキーがほかへ移っていないときだけ取る。保存や録画のフィルターの更新を待つ間に、
    /// 別のアプリやウィンドウへ移ったら、そちらから奪わない。そのアプリを返す先として覚え直すこともしない。
    /// ほかの編集画面が開いている間と、一覧から開いた編集では取らない。一覧から開いた編集は一覧へキーを戻す。
    private func reappearAfterEditing(from editor: NSWindow?) {
        onEditingChange?(false)
        // 動画は書き出しを終えるとlibraryEditingを戻すので、閉じた時点の値で決める。
        let fromLibrary = libraryEditing
        let claims = { [weak self, weak editor] in
            guard let self, !fromLibrary, !editingSuspended else { return false }
            return keepsEditorFocus(editor)
        }
        // 閉じた時点で見送ったら、出す時点でキーがどこにも無くなっていても取らない。
        guard claims() else {
            if canShow() { show(claimKeyboard: false) }
            return
        }
        onRequestKeys?()
        if canShow() { show(claimingKeys: claims) }
    }
    private func restoreFocus() {
        guard let previousApplication, previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        NSApp.yieldActivation(to: previousApplication)
        _ = previousApplication.activate(options: [])
    }
    func windowDidResignKey(_ notification: Notification) {
        // 別のアプリをクリックしたときは取り戻さない。次のshowまたは明示的なホバーで再取得する。
        stopKeys(); trashConfirmation.interrupt(.resignKey)
        view.refreshControls(); view.needsDisplay = true
    }
    func windowDidBecomeKey(_ notification: Notification) { view.refreshControls(); view.needsDisplay = true }
    func openEditorFromLibrary(onReturn: @escaping () -> Void) {
        libraryEditing = true; onLibraryReturn = onReturn
        if editor != nil || videoEditor != nil { bringForward() } else { startEdit() }
    }
    private func returnToLibrary() {
        onLibraryReturn?(); onLibraryReturn = nil
        // 動画はonCloseの後にonCompleteを呼ぶ。ここで起点を消すと静止画カードが出てしまう。
    }
    @objc func edit() {
        disarmTrash(.click)
        libraryEditing = false; onLibraryReturn = nil
        startEdit()
    }
    private func startEdit() {
        if artifact.kind == .mp4 { editVideo(); return }
        guard canEdit, editor == nil, let imageState else { return }
        rememberApplicationBeforeEditing()
        hide()
        let controller = AnnotationEditorController(image: imageState.original, document: imageState.history.document, screen: screen,
            applicationFocus: editorFocus, privacyConfig: annotationConfig().privacy, history: imageState.history)
        editor = controller
        onEditingChange?(true)
        controller.onComplete = { [weak self, weak controller] image, _ in
            guard let self, let controller else { return }
            // 一覧を閉じて編集画面とカードが外れても、置き換え終わるまで数える。
            let work = self.backgroundWork
            work?.begin(.annotationSave)
            defer { work?.end(.annotationSave) }
            let config = self.annotationConfig()
            let data = try await Task.detached(priority: .userInitiated) {
                try WebPEncoder.encode(image, quality: config.quality, lossless: config.lossless)
            }.value
            let updated = try AnnotationSave.commit(data: data, artifact: self.artifact, mode: config.clipboard,
                imageSize: CGSize(width: image.width, height: image.height), copy: self.copyImage)
            imageState.history = controller.canvas.history
            self.complete(artifact: updated, image: image, copied: config.clipboard.copiesAutomatically)
        }
        controller.onClose = { [weak self, weak controller] in
            guard let self else { return }
            let window = controller?.window
            self.editor = nil; self.remaining = self.lifetime
            self.reappearAfterEditing(from: window)
            self.returnToLibrary()
        }
        controller.show()
    }
    private func editVideo() {
        guard canEdit, videoEditor == nil, let duration = artifact.duration, duration > 0 else { return }
        rememberApplicationBeforeEditing()
        hide()
        if videoSession == nil { videoSession = makeVideoSession(artifact, annotationConfig().video.fps) }
        guard let session = videoSession else { return }
        let controller = VideoEditorController(source: session.sourceURL, document: session.document, screen: screen, focus: editorFocus,
            copiesStills: annotationConfig().clipboard.copiesAutomatically)
        videoEditor = controller
        onEditingChange?(true)
        controller.onClose = { [weak self, weak controller] in
            guard let self else { return }
            let window = controller?.window
            videoEditor = nil; remaining = lifetime
            reappearAfterEditing(from: window)
            returnToLibrary()
        }
        controller.onComplete = { [weak self] document in
            guard let self else { return }
            // 失敗しても、次のEで元の録画に今回の範囲を重ねる。
            session.document = document
            let config = annotationConfig()
            finalizing = true; pauseTimer(); view.copied = false; view.refreshControls(); view.needsDisplay = true
            onExportStatus?("書き出し中…")
            let work = backgroundWork
            work?.begin(.videoExport)
            Task { [self] in
                defer { if closed { session.close() }; work?.end(.videoExport) }
                do {
                    let result = try await session.finish(artifact: artifact, config: config) {
                        copyEntries($0, config.clipboard)
                    }
                    let copied = config.clipboard.copiesAutomatically
                    if let image = result.image {
                        complete(artifact: result.video, image: image, copied: copied && result.stills.isEmpty)
                    } else {
                        finalizing = false; view.copied = copied && result.stills.isEmpty
                        view.refreshControls(); view.needsDisplay = true; resumeTimer()
                        onArtifactChange?()
                    }
                    onStills?(result.stills, copied)
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
        guard visible, editor == nil, videoEditor == nil, !closed, !hovered, !dragging, !saving, !finalizing, !editingSuspended, !removalPending,
              !alerting, timer == nil else { return }
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
        } else { disarmTrash(.pointerExit); resumeTimer() }
    }
    private func stopKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
    @objc func reveal() {
        disarmTrash(.click)
        guard !finalizing else { return }
        NSWorkspace.shared.activateFileViewerSelecting([artifact.url])
    }
    @objc func saveAs() {
        disarmTrash(.click)
        guard !saving, !finalizing else { return }
        saving = true; pauseTimer(); releaseKeys()
        // 保存先を選ぶパネルはカードと別に残るので、閉じて書き終えるまで数える。
        let work = backgroundWork
        work?.begin(.saveCopy)
        let save = NSSavePanel()
        save.nameFieldStringValue = artifact.url.lastPathComponent
        save.directoryURL = artifact.url.deletingLastPathComponent()
        save.allowedContentTypes = [UTType(filenameExtension: artifact.kind.fileExtension) ?? .data]
        save.canCreateDirectories = true
        NSApp.activate()
        save.begin { [weak self] response in
            defer { work?.end(.saveCopy) }
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
final class ThumbnailPanel: NSPanel, CaptureExcludedWindow {
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
    /// 保存の状態に添える知らせ。
    var notice: String?
    private var downEvent: NSEvent?
    private var dragged = false
    private var buttons: [CardAction: CardButton] = [:]
    private let spinner = NSProgressIndicator()
    func configureButtons() {
        guard let card else { return }
        let definitions: [(CardAction, String, String, String, Selector)] = [
            (.annotate, card.artifact.kind == .mp4 ? "scissors" : "pencil", "⏎", card.artifact.kind == .mp4 ? "動画を編集 ⏎" : "注釈 ⏎", #selector(ThumbnailCard.edit)),
            (.pin, "pin", "P", "画面に浮かべる P", #selector(ThumbnailCard.pin)),
            (.save, "square.and.arrow.down", "S", "別名保存 S", #selector(ThumbnailCard.saveAs)),
            (.reveal, "folder", "O", "Finderで表示 O", #selector(ThumbnailCard.reveal)),
            (.trash, "trash", "X", "ゴミ箱へ移す X を2回", #selector(ThumbnailCard.trash))]
        for (action, symbol, key, label, selector) in definitions {
            let button = CardButton(frame: CardPresentation.button(action))
            if action == .trash { button.confirmationTitle = "もう一度"; button.confirmationLabel = "もう一度押すとゴミ箱へ移す" }
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
            switch action {
            case .annotate: button.isEnabled = !card.finalizing && card.canEdit
            case .trash: button.isEnabled = card.canTrash
            case .pin: button.isEnabled = card.canPin
            case .save, .reveal: button.isEnabled = !card.finalizing
            }
            button.confirming = action == .trash && card.trashConfirmation.isArmed
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
    override func mouseDown(with event: NSEvent) {
        downEvent = event; dragged = false
        // ゴミ箱のボタン自身の押下はNSButtonが受ける。ここへ届くのはほかの場所のクリック。
        card?.disarmTrash(.click)
    }
    // 右・中ボタンは別のイベントで届く。どのボタンでもカードを押したら確認を解除する。
    override func rightMouseDown(with event: NSEvent) { card?.disarmTrash(.click); super.rightMouseDown(with: event) }
    override func otherMouseDown(with event: NSEvent) { card?.disarmTrash(.click); super.otherMouseDown(with: event) }
    override func mouseUp(with event: NSEvent) {
        defer { downEvent = nil }
        guard !dragged, let card, let downEvent else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard CardPresentation.action(at: convert(downEvent.locationInWindow, from: nil)) == CardPresentation.action(at: point) else { return }
        switch CardPresentation.action(at: point) {
        case .annotate: card.edit()
        case .save: card.saveAs()
        case .reveal: card.reveal()
        case .pin: card.pin()
        case .trash: card.trash()
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
        let status = CardPresentation.status(copied: copied, finalizing: card.finalizing, notice: notice)
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
    var confirmationTitle: String?
    var confirmationLabel: String?
    /// 削除の確認中は赤い面へ「もう一度」を出す。赤は削除の確認に使ってよい色。
    var confirming = false {
        didSet {
            guard confirming != oldValue else { return }
            setAccessibilityLabel(confirming ? confirmationLabel : toolTip)
        }
    }
    override var isFlipped: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if confirming, let confirmationTitle {
            UIDrawing.fill(bounds, color: UITheme.redFace, radius: 6)
            // 5つのボタンでは幅が狭いので、「もう一度」が切れない大きさまで字を縮める。
            var size: CGFloat = 10.5
            while size > 8 && (confirmationTitle as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .bold)]).width > bounds.width - 4 {
                size -= 0.5
            }
            UIDrawing.text(confirmationTitle, in: CGRect(x: 2, y: 4.5 + (10.5 - size) / 2, width: bounds.width - 4, height: 15), size: size,
                           color: .white, weight: .bold, centered: true)
            return
        }
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

import AppKit
import Testing
import UtsushieCore
@testable import Utsushie

@MainActor private func recentImage() throws -> CGImage {
    let context = try AnnotationRenderer.bitmap(width: 160, height: 100)
    context.setFillColor(CGColor(gray: 0.7, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
    return try #require(context.makeImage())
}
private func recentDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
@MainActor private func recentArtifact(_ image: CGImage, in directory: URL, seconds: Double = 0) throws -> SharedArtifact {
    let date = Date(timeIntervalSince1970: seconds)
    let data = try WebPEncoder.encode(image, quality: 80, lossless: true)
    let url = try ArtifactStore.save(data: data, kind: .webP, directory: directory, date: date)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    return SharedArtifact(url: url, kind: .webP, width: image.width, height: image.height, byteCount: data.count)
}
@MainActor private func recentController() -> ThumbnailController {
    let controller = ThumbnailController()
    controller.editorFocus = .init(activate: {}, restore: { _ in })
    controller.annotationConfig = { UtsushieConfig() }
    return controller
}
@MainActor private func closeRecentCards(_ controller: ThumbnailController) {
    for card in controller.cards { controller.remove(card.id) }
}
@MainActor private func recentLifetimeIs(_ card: ThumbnailCard?, seconds: Double) -> Bool {
    guard let timer = card?.timer, timer.isValid else { return false }
    // 非反復TimerのtimeIntervalは0。実際の期限が寿命全体ぶん先にあることを確かめる。
    return abs(timer.fireDate.timeIntervalSinceNow - seconds) < 0.5
}

@MainActor @Test(arguments: [false, true])
func allCardLifetimesPauseDuringEitherEditorAndResumeIndependently(_ video: Bool) throws {
    let dir = try recentDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let image = try recentImage(), controller = recentController()
    defer { closeRecentCards(controller) }
    var source = try recentArtifact(image, in: dir)
    if video { source.kind = .mp4; source.duration = 12 }
    controller.add(source, image: image, copied: false, seconds: 5, screen: nil)
    let other = try recentArtifact(image, in: dir, seconds: 1)
    controller.add(other, image: image, copied: false, seconds: 7, screen: nil)
    let card = try #require(controller.card(for: source.url))
    let sibling = try #require(controller.card(for: other.url))
    let oldTimer = try #require(sibling.timer)
    let pending = SharedArtifact(url: dir.appendingPathComponent("pending.mp4"), kind: .mp4, width: 160, height: 100, byteCount: 0, duration: 12)
    let pendingID = controller.add(pending, image: image, copied: false, seconds: 9, screen: nil, finalizing: true)
    card.edit()
    #expect(sibling.timer == nil && !oldTimer.isValid)
    sibling.hover(true); sibling.hover(false)
    #expect(sibling.timer == nil)
    let added = try recentArtifact(image, in: dir, seconds: 2)
    controller.add(added, image: image, copied: false, seconds: 11, screen: nil)
    #expect(controller.card(for: added.url)?.timer == nil)
    sibling.hover(true)
    if video { try #require(card.videoEditor).window.close() }
    else { try #require(card.editor).window.close() }
    #expect(sibling.timer == nil)
    sibling.hover(false)
    #expect(recentLifetimeIs(sibling, seconds: 7))
    #expect(recentLifetimeIs(controller.card(for: added.url), seconds: 11))
    #expect(controller.card(for: pending.url)?.timer == nil)
    controller.complete(pendingID, artifact: pending, image: image, copied: false)
    #expect(recentLifetimeIs(controller.card(for: pending.url), seconds: 9))
}

@MainActor @Test func nestedEditorsKeepAllTimersPausedAndCaptureSuspensionRemainsIndependent() throws {
    let dir = try recentDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let image = try recentImage(), controller = recentController()
    defer { closeRecentCards(controller) }
    for second in 0..<3 { controller.add(try recentArtifact(image, in: dir, seconds: Double(second)), image: image, copied: false, seconds: 5, screen: nil) }
    let first = controller.cards[0], second = controller.cards[1], sibling = controller.cards[2]
    first.edit(); second.edit()
    #expect(sibling.timer == nil)
    controller.setSuspended(true)
    try #require(first.editor).window.close()
    controller.setSuspended(false)
    #expect(sibling.timer == nil)
    controller.setSuspended(true)
    try #require(second.editor).window.close()
    #expect(sibling.timer == nil)
    controller.setSuspended(false)
    #expect(controller.cards.allSatisfy { recentLifetimeIs($0, seconds: 5) })
}

@MainActor @Test func recentImageReopensOriginalAndUndoRedoHistoryThenFallsBackAfterRestartOrEviction() async throws {
    let dir = try recentDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let original = try recentImage(), controller = recentController()
    defer { closeRecentCards(controller) }
    let artifact = try recentArtifact(original, in: dir)
    controller.add(artifact, image: original, copied: false, seconds: 5, screen: nil)
    let card = try #require(controller.card(for: artifact.url))
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    card.copyImage = { ClipboardWriter.copy($0, data: $1, mode: $2, to: board) }
    card.edit()
    let editor = try #require(card.editor)
    let first = Annotation(tool: .rectangle, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 80, y: 60))
    let second = Annotation(tool: .arrow, start: CGPoint(x: 30, y: 70), end: CGPoint(x: 120, y: 70))
    editor.canvas.appendPrivacyAnnotations([first]); editor.canvas.appendPrivacyAnnotations([second]); editor.canvas.undoAnnotation()
    let savedDocument = editor.canvas.document
    let image = try AnnotationRenderer.compose(original, document: savedDocument)
    try await editor.onComplete?(image, savedDocument)
    editor.window.close(); controller.remove(card.id)
    #expect(controller.cards.isEmpty && controller.recentImages.count == 1)
    let restoredID = try await controller.restore(artifact.url, seconds: 8, screen: nil)
    let restored = try #require(controller.card(for: artifact.url))
    #expect(recentLifetimeIs(restored, seconds: 8) && restored.imageState?.original === original)
    #expect(try await controller.restore(artifact.url, seconds: 8, screen: nil) == restoredID && controller.cards.count == 1)
    restored.edit()
    let reopened = try #require(restored.editor)
    #expect(reopened.canvas.document == savedDocument && reopened.canvas.history.canUndo && reopened.canvas.history.canRedo)
    reopened.canvas.redoAnnotation(); #expect(reopened.canvas.document.annotations.count == 2)
    reopened.canvas.undoAnnotation(); reopened.canvas.undoAnnotation(); #expect(reopened.canvas.document.annotations.isEmpty)
    reopened.window.close()
    #expect(restored.imageState?.history.document == savedDocument)
    restored.timer?.fire()
    #expect(controller.cards.isEmpty)
    let restarted = recentController()
    defer { closeRecentCards(restarted) }
    try await restarted.restore(artifact.url, seconds: 5, screen: nil)
    let flattened = try #require(restarted.card(for: artifact.url)?.imageState)
    #expect(flattened.original !== original && flattened.history.document.annotations.isEmpty && !flattened.history.canUndo)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: artifact.url.path)
    for second in 1...10 {
        controller.add(try recentArtifact(original, in: dir, seconds: Double(second)), image: original, copied: false, seconds: 5, screen: nil)
    }
    #expect(controller.recentImages.count == 10 && controller.recentImages.state(for: artifact.url) == nil)
    try await controller.restore(artifact.url, seconds: 5, screen: nil)
    let evicted = try #require(controller.card(for: artifact.url)?.imageState)
    #expect(evicted.original !== original && evicted.history.document.annotations.isEmpty)
    #expect(controller.recentImages.count == 10)
}

@MainActor @Test func recentMemoryCountsMoviesWithinTheTenFileLimit() throws {
    let image = try recentImage(), memory = RecentImageMemory()
    let files = (0..<12).map { index in
        RecentCaptureFile(url: URL(fileURLWithPath: "/tmp/recent-\(index).\(index.isMultiple(of: 2) ? "webp" : "mp4")"), date: Date(timeIntervalSince1970: Double(index)))
    }
    for file in files where file.kind == .webP { memory.remember(ImageEditState(original: image), at: file.url, among: files) }
    #expect(memory.count == 5 && memory.state(for: files[0].url) == nil && memory.state(for: files[2].url) != nil)
    memory.retain([]); #expect(memory.count == 0)
}

@MainActor @Test func libraryListsFilesAndKeepsSelectionAcrossUpdatesAndFinderDeletion() async throws {
    let dir = try recentDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let image = try recentImage()
    let old = try recentArtifact(image, in: dir), newest = try recentArtifact(image, in: dir, seconds: 1)
    try Data([1]).write(to: dir.appendingPathComponent(".private-original.webp"))
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("folder.mp4"), withIntermediateDirectories: true)
    let recent = CaptureLibraryController(directory: { dir }, config: { UtsushieConfig() }, thumbnails: recentController(), remembersFrame: false)
    await recent.reload()
    #expect(recent.files.map(\.url) == [newest.url, old.url])
    #expect(recent.selection.focusedURL == newest.url)
    recent.select(old.url)
    let third = try recentArtifact(image, in: dir, seconds: 2)
    await recent.reload()
    #expect(recent.selection.focusedURL == old.url)
    try FileManager.default.removeItem(at: newest.url)
    await recent.reload(); #expect(recent.files.count == 2 && recent.selection.focusedURL == old.url)
    try FileManager.default.removeItem(at: old.url)
    await recent.reload(); #expect(recent.selection.focusedURL == third.url)
    try FileManager.default.removeItem(at: third.url)
    await recent.reload(); #expect(recent.files.isEmpty && recent.selection.urls.isEmpty)
}

@MainActor @Test func unreadableLibraryCaptureDoesNotBlockListingAndLoadsFailIndependently() async throws {
    let dir = try recentDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    _ = try recentArtifact(recentImage(), in: dir)
    try Data([1, 2]).write(to: dir.appendingPathComponent("broken.webp"))
    let files = try RecentCaptureStore.files(in: dir)
    #expect(files.count == 2)
    var loaded = 0, failed = 0
    for file in files {
        do { _ = try await RecentCaptureStore.load(file, maximumPixelSize: 64); loaded += 1 }
        catch { failed += 1 }
    }
    #expect(loaded == 1 && failed == 1)
}

@MainActor @Test func libraryEditingNeverShowsCardOrChangesVisibleCardPlacementAndRetainsHistory() async throws {
    let dir = try recentDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let image = try recentImage(), controller = recentController()
    defer { controller.closeLibrarySessions(); closeRecentCards(controller) }
    let visible = try recentArtifact(image, in: dir, seconds: 1)
    controller.add(visible, image: image, copied: false, seconds: 20, screen: nil)
    let sibling = try #require(controller.card(for: visible.url)), frame = sibling.panel.frame
    let hidden = try recentArtifact(image, in: dir)
    var returned = 0
    try await controller.editFromLibrary(hidden.url) { returned += 1 }
    let card = try #require(controller.card(for: hidden.url))
    #expect(controller.cards.count == 1 && !card.panel.isVisible && card.timer == nil)
    #expect(sibling.panel.frame == frame && sibling.timer == nil)
    let original = try #require(card.imageState).original
    let editor = try #require(card.editor)
    let mark = Annotation(tool: .rectangle, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 60, y: 60))
    editor.canvas.appendPrivacyAnnotations([mark])
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    card.copyImage = { ClipboardWriter.copy($0, data: $1, mode: $2, to: board) }
    let composed = try AnnotationRenderer.compose(original, document: editor.canvas.document)
    try await editor.onComplete?(composed, editor.canvas.document)
    editor.window.close()
    #expect(returned == 1 && !card.panel.isVisible && card.timer == nil)
    #expect(controller.card(for: hidden.url) == nil)
    #expect(recentLifetimeIs(sibling, seconds: 20) && sibling.panel.frame == frame)
    try await controller.editFromLibrary(hidden.url) { returned += 1 }
    let reopened = try #require(controller.card(for: hidden.url))
    #expect(reopened.imageState?.original === original)
    #expect(reopened.editor?.canvas.document.annotations == [mark])
    reopened.editor?.window.close()
    #expect(returned == 2)
    controller.closeLibrarySessions()
    #expect(controller.card(for: hidden.url) == nil && controller.cards.count == 1)
}

@MainActor @Test func libraryEditingReusesAlreadyVisibleCardAndAlreadyOpenEditor() async throws {
    let dir = try recentDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let image = try recentImage(), controller = recentController()
    defer { closeRecentCards(controller) }
    let artifact = try recentArtifact(image, in: dir)
    controller.add(artifact, image: image, copied: false, seconds: 10, screen: nil)
    let card = try #require(controller.card(for: artifact.url))
    card.edit(); let editor = try #require(card.editor)
    var returned = false
    try await controller.editFromLibrary(artifact.url) { returned = true }
    #expect(controller.cards.count == 1 && card.editor === editor)
    editor.window.close()
    #expect(returned && card.panel.isVisible)
}

@MainActor @Test func libraryPhysicalNavigationIgnoresIMECharactersAndCommandModifiers() async throws {
    let dir = try recentDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let image = try recentImage()
    for second in 0..<6 { _ = try recentArtifact(image, in: dir, seconds: Double(second)) }
    let library = CaptureLibraryController(directory: { dir }, config: { UtsushieConfig() }, thumbnails: recentController(), remembersFrame: false)
    await library.reload()
    func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: library.window!.windowNumber, context: nil, characters: "あ", charactersIgnoringModifiers: "あ", isARepeat: false, keyCode: code))
    }
    #expect(library.handleKey(try key(37)) && library.selection.focusedURL == library.files[1].url)
    #expect(library.handleKey(try key(38)) && library.selection.focusedURL == library.files[5].url)
    #expect(library.handleKey(try key(40)) && library.selection.focusedURL == library.files[1].url)
    #expect(library.handleKey(try key(4)) && library.selection.focusedURL == library.files[0].url)
    #expect(!library.handleKey(try key(37, .command)) && library.selection.focusedURL == library.files[0].url)
    #expect(!library.handleKey(try key(14)) && library.selection.focusedURL == library.files[0].url)
    #expect(library.numberOfPreviewItems(in: nil) == 1)
    #expect((library.previewPanel(nil, previewItemAt: 0) as? NSURL) as URL? == library.files[0].url)
}

@MainActor @Test(arguments: [UInt16(36), 76])
func libraryEnterIgnoresRepeatModifiersAndMultipleSelection(_ code: UInt16) async throws {
    let dir = try recentDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let image = try recentImage(), controller = recentController()
    defer { controller.closeLibrarySessions() }
    for second in 0..<2 { _ = try recentArtifact(image, in: dir, seconds: Double(second)) }
    let library = CaptureLibraryController(directory: { dir }, config: { UtsushieConfig() }, thumbnails: controller, remembersFrame: false)
    await library.reload()
    func key(_ modifiers: NSEvent.ModifierFlags = [], repeating: Bool = false) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: library.window!.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: repeating, keyCode: code))
    }
    #expect(library.handleKey(try key(repeating: true)))
    #expect(!library.isPerformingAction)
    for modifier: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
        #expect(!library.handleKey(try key(modifier)))
        #expect(!library.isPerformingAction)
    }
    library.select(library.files[1].url, mode: .toggle)
    #expect(library.selection.urls.count == 2)
    #expect(library.handleKey(try key()))
    #expect(!library.isPerformingAction && library.footerStatus == "この操作は1件ずつ")
}

@MainActor @Test(arguments: [UInt16(36), 76])
func libraryPreviewEnterOpensSelectedEditor(_ code: UInt16) async throws {
    let dir = try recentDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let image = try recentImage(), controller = recentController()
    defer { controller.closeLibrarySessions() }
    let artifact = try recentArtifact(image, in: dir)
    let library = CaptureLibraryController(directory: { dir }, config: { UtsushieConfig() }, thumbnails: controller, remembersFrame: false)
    await library.reload()
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: library.window!.windowNumber, context: nil, characters: "あ", charactersIgnoringModifiers: "あ", isARepeat: false, keyCode: code))
    #expect(library.previewPanel(nil, handle: event))
    for _ in 0..<300 where library.isPerformingAction { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!library.isPerformingAction)
    #expect(controller.card(for: artifact.url)?.editor != nil)
    #expect(controller.cards.isEmpty)
}

@MainActor @Test(arguments: [UInt16(12), 53, 13])
func libraryCloseKeysCloseOnlyOncePerPressWithoutPreview(_ code: UInt16) throws {
    let dir = try recentDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let library = CaptureLibraryController(directory: { dir }, config: { UtsushieConfig() }, thumbnails: recentController(), remembersFrame: false)
    library.applicationFocus = .init(activate: {}, restore: { _ in })
    library.open(); defer { library.close() }
    func key(repeating: Bool) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: code == 13 ? .command : [], timestamp: 0,
            windowNumber: library.window!.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: repeating, keyCode: code))
    }
    #expect(library.handleKey(try key(repeating: true)) && library.window?.isVisible == true)
    #expect(library.handleKey(try key(repeating: false)) && library.window?.isVisible == false)
}

@MainActor @Test(arguments: [20, 860])
func libraryRestoresSavedFrameBeforeAttachingDelegateAndKeepsGridPositive(_ savedWidth: Int) throws {
    let name = "UTSUSHIE-Library-Test-\(UUID().uuidString)"
    defer { NSWindow.removeFrame(usingName: name) }
    let seed = NSWindow(contentRect: CGRect(x: 40, y: 40, width: savedWidth, height: 520),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    seed.isReleasedWhenClosed = false
    let savedFrame = seed.frame
    seed.saveFrame(usingName: name); seed.close()
    let directory = try recentDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // 同じ保存済みframeで2回生成し、次回起動と同じ復元経路を通す。
    for _ in 0..<2 {
        let library = CaptureLibraryController(directory: { directory }, config: { UtsushieConfig() },
            thumbnails: recentController(), frameAutosaveName: name)
        let window = try #require(library.window)
        defer { window.setFrameAutosaveName(""); library.close() }
        #expect(window.frameAutosaveName == name && window.delegate === library)
        if savedWidth >= 680 { #expect(window.frame.size == savedFrame.size) }
        let content = try #require(window.contentView)
        let scroll = try #require(content.subviews.compactMap { $0 as? NSScrollView }.first)
        let collection = try #require(scroll.documentView as? NSCollectionView)
        let layout = try #require(collection.collectionViewLayout as? NSCollectionViewFlowLayout)
        #expect(layout.itemSize.width > 0 && layout.itemSize.height > 0)
        library.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        library.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        #expect(layout.itemSize.width > 0 && layout.itemSize.height > 0)
        let grid = CaptureLibrary.gridLayout(for: scroll.contentSize.width)
        #expect(layout.itemSize == CGSize(width: grid.itemWidth, height: grid.itemHeight))
    }
}

@MainActor @Test func applicationMenuIsCompleteAndTerminationIsSafeWithoutLibrary() throws {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification, object: app)) }
    // 起動全体は実行せず、設定・利用者の保存先を読む前のメニュー生成だけを試す。
    delegate.installStatusMenu()
    let menu = try #require(delegate.installedStatusMenu)
    #expect(menu.items.contains { $0.title == "撮影" && $0.target === delegate })
    #expect(menu.items.contains { $0.title == "撮影の一覧を開く" && $0.target === delegate })
    #expect(menu.items.contains { $0.title == "UTSUSHIEを終了" && $0.target === delegate })
}

@MainActor @Test func libraryReusesCellsAndLimitsThumbnailReadsToVisibleFilesAndFourAtOnce() async throws {
    let dir = try recentDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    for index in 0..<1200 { try Data([0]).write(to: dir.appendingPathComponent("\(index).webp")) }
    let image = try recentImage()
    let library = CaptureLibraryController(directory: { dir }, config: { UtsushieConfig() }, thumbnails: recentController(), remembersFrame: false)
    library.applicationFocus = .init(activate: {}, restore: { _ in })
    var reads = 0, simultaneous = 0, peak = 0
    library.loadThumbnail = { file in
        reads += 1; simultaneous += 1; peak = max(peak, simultaneous)
        defer { simultaneous -= 1 }
        try await Task.sleep(for: .milliseconds(20))
        return LoadedCapture(artifact: SharedArtifact(url: file.url, kind: .webP, width: 160, height: 100, byteCount: 1), image: image)
    }
    library.open(); defer { library.close() }
    for _ in 0..<300 where library.files.count != 1200 || reads == 0 || library.isLoadingThumbnails {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(library.files.count == 1200 && reads > 0 && reads < 40 && peak <= 4)
    let content = try #require(library.window?.contentView)
    let scroll = try #require(content.subviews.compactMap { $0 as? NSScrollView }.first)
    let collection = try #require(scroll.documentView as? NSCollectionView)
    #expect(collection.visibleItems().count < 40 && !collection.visibleItems().isEmpty)
    let firstReads = reads
    await library.reload()
    for _ in 0..<300 where library.isLoadingThumbnails { try await Task.sleep(for: .milliseconds(10)) }
    #expect(reads == firstReads)
    library.select(library.files.last!.url)
    for _ in 0..<300 where reads == firstReads || library.isLoadingThumbnails { try await Task.sleep(for: .milliseconds(10)) }
    #expect(reads > firstReads && reads < 80 && peak <= 4)
}

@MainActor private final class LibraryRunningApplication: NSRunningApplication, @unchecked Sendable {
    let identifier: pid_t
    init(_ identifier: pid_t) { self.identifier = identifier; super.init() }
    override var processIdentifier: pid_t { identifier }
    override var isTerminated: Bool { false }
}

@MainActor @Test func libraryClosesBackToOpeningApplicationOnlyWhenOwnPIDIsFrontmost() throws {
    let dir = try recentDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let previous = LibraryRunningApplication(-2)
    for ownPIDAtClose in [false, true] {
        var front: NSRunningApplication = previous
        var restored: NSRunningApplication?, activations = 0
        let library = CaptureLibraryController(directory: { dir }, config: { UtsushieConfig() }, thumbnails: recentController(), remembersFrame: false)
        library.applicationFocus = .init(isActive: { true }, frontmostApplication: { front }, activate: { activations += 1 }, restore: { restored = $0 })
        library.open(); library.open()
        #expect(activations == 2)
        front = LibraryRunningApplication(ownPIDAtClose ? ProcessInfo.processInfo.processIdentifier : -3)
        library.close()
        #expect(ownPIDAtClose ? restored === previous : restored == nil)
    }
}

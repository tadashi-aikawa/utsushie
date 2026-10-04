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

@MainActor @Test func recentMenuReadsImageTitlesThumbnailsAndSelectionAndDefersStructuralChanges() async throws {
    let dir = try recentDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let image = try recentImage()
    let old = try recentArtifact(image, in: dir), newest = try recentArtifact(image, in: dir, seconds: 1)
    try Data([1]).write(to: dir.appendingPathComponent(".private-original.webp"))
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("folder.mp4"), withIntermediateDirectories: true)
    var selected: URL?, listed: [RecentCaptureFile] = []
    let recent = RecentCaptureMenu(directory: { dir }, onFiles: { listed = $0 }, onSelect: { selected = $0 })
    recent.refresh()
    for _ in 0..<200 where recent.menu.items.contains(where: { !$0.isEnabled }) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(listed.map(\.url) == [newest.url, old.url])
    #expect(recent.menu.items.count == 2 && recent.menu.items.allSatisfy { $0.isEnabled && $0.image != nil && $0.title.hasSuffix("WebP 160×100") })
    recent.menu.performActionForItem(at: 0); #expect(selected == newest.url)
    recent.menuWillOpen(recent.menu)
    try FileManager.default.removeItem(at: newest.url)
    recent.refresh(); #expect(recent.menu.items.count == 2)
    recent.menuDidClose(recent.menu)
    for _ in 0..<200 where recent.menu.items.count != 1 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(recent.menu.items.count == 1)
    try FileManager.default.removeItem(at: old.url)
    recent.refresh(); #expect(recent.menu.items.count == 1 && recent.menu.items[0].title == "撮影はありません" && !recent.menu.items[0].isEnabled)
}

@MainActor @Test func unreadableRecentCaptureIsDisabledAndDoesNotBlockOtherRows() async throws {
    let dir = try recentDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    _ = try recentArtifact(recentImage(), in: dir)
    try Data([1, 2]).write(to: dir.appendingPathComponent("broken.webp"))
    let recent = RecentCaptureMenu(directory: { dir }, onFiles: { _ in }, onSelect: { _ in })
    recent.refresh()
    for _ in 0..<200 where recent.menu.items.contains(where: { $0.title == "読み込み中…" }) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(recent.menu.items.filter(\.isEnabled).count == 1)
    #expect(recent.menu.items.first { !$0.isEnabled }?.title == "読み取れません: broken.webp")
}

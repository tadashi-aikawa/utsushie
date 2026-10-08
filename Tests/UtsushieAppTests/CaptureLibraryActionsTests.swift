import AppKit
import Testing
import UtsushieCore
@testable import Utsushie

private func actionsDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("utsushie-library-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor private func actionsImage() throws -> CGImage {
    let context = try AnnotationRenderer.bitmap(width: 32, height: 24)
    return try #require(context.makeImage())
}

@MainActor private func actionsKey(_ code: UInt16, flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: repeatKey, keyCode: code))
}

@MainActor private func finishActions(_ library: CaptureLibraryController) async throws {
    for _ in 0..<1000 {
        if !library.isPerformingAction { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("一覧の操作が完了しませんでした")
}

@Test func libraryTrashMovesOnlyTemporaryFilesAndReportsIndependentFailures() throws {
    let directory = try actionsDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("\(UUID().uuidString).webp")
    let second = directory.appendingPathComponent("\(UUID().uuidString).mp4")
    let absent = directory.appendingPathComponent("missing.webp")
    try Data([1]).write(to: first); try Data([2]).write(to: second)
    var trashed: [URL] = []
    defer { for url in trashed { try? FileManager.default.removeItem(at: url) } }
    let result = CaptureLibraryFileActions.trash([first, absent, second]) { url in
        var target: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &target)
        trashed.append(try #require(target as URL?))
    }
    #expect(result.removed == [first, second] && result.failed == [absent])
    #expect(!FileManager.default.fileExists(atPath: first.path) && !FileManager.default.fileExists(atPath: second.path))
    #expect(try trashed.map { try Data(contentsOf: $0) } == [Data([1]), Data([2])])
}

@MainActor @Test(arguments: ClipboardMode.allCases)
func libraryCopiesAllImagesAndVideosInDisplayOrderWithoutGeneralPasteboard(_ mode: ClipboardMode) throws {
    let directory = try actionsDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let urls = ["first.webp", "middle.mp4", "last.WEBP"].map { directory.appendingPathComponent($0) }
    try Data([1]).write(to: urls[0]); try Data([3]).write(to: urls[2])
    // MP4は存在しなくても読み込まない。URLだけを渡す契約を確認する。
    let entries = try CaptureLibraryFileActions.clipboardEntries(urls, mode: mode)
    #expect(entries.map { $0.artifact.url } == urls && entries[1].data == nil)
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    #expect(ClipboardWriter.copy(entries, mode: mode, to: board))
    let items = try #require(board.pasteboardItems)
    #expect(items.count == 3)
    for index in [0, 2] {
        let expected: Set<NSPasteboard.PasteboardType> = mode == .file ? [.fileURL]
            : mode == .data ? [.init("org.webmproject.webp")] : [.fileURL, .init("org.webmproject.webp")]
        #expect(Set(items[index].types) == expected)
        if mode != .file { #expect(items[index].data(forType: .init("org.webmproject.webp")) == Data([UInt8(index + 1)])) }
    }
    #expect(items[1].types == [.fileURL] && items[1].string(forType: .fileURL) == urls[1].absoluteString)
}

@MainActor @Test func libraryKeysExtendSelectAllCopyAndDisableSingleItemActions() async throws {
    let directory = try actionsDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for index in 0..<4 { try Data([UInt8(index)]).write(to: directory.appendingPathComponent("\(index).webp")) }
    let thumbnails = ThumbnailController()
    let library = CaptureLibraryController(directory: { directory }, config: { UtsushieConfig() }, thumbnails: thumbnails, remembersFrame: false)
    await library.reload()
    let urls = library.files.map(\.url)
    #expect(library.handleKey(try actionsKey(124, flags: .shift)))
    #expect(library.selection.urls == Set(urls[0...1]))
    _ = library.handleKey(try actionsKey(37, flags: .shift))
    #expect(library.selection.urls == Set(urls[0...2]))
    _ = library.handleKey(try actionsKey(4, flags: .shift))
    #expect(library.selection.urls == Set(urls[0...1]))
    _ = library.handleKey(try actionsKey(0, flags: .command))
    #expect(library.selection.urls == Set(urls))
    for code: UInt16 in [36, 76, 1, 31, 49] {
        #expect(library.handleKey(try actionsKey(code)))
        #expect(!library.isPerformingAction && library.footerStatus?.contains("1件ずつ") == true)
    }
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    library.copyEntries = { entries, mode in ClipboardWriter.copy(entries, mode: mode, to: board) }
    _ = library.handleKey(try actionsKey(8, flags: .command))
    try await finishActions(library)
    #expect(board.pasteboardItems?.count == 4 && library.footerStatus == "コピー済み 4件")
    _ = library.handleKey(try actionsKey(124))
    #expect(library.selection.urls.count == 1)
}

@MainActor @Test func libraryTrashClosesCardsForgetsMemoryAndKeepsFailedSelection() async throws {
    let directory = try actionsDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let thumbnails = ThumbnailController(), image = try actionsImage()
    thumbnails.editorFocus = .init(activate: {}, restore: { _ in })
    thumbnails.annotationConfig = { UtsushieConfig() }
    let data = try WebPEncoder.encode(image, quality: 80, lossless: true)
    var artifacts: [SharedArtifact] = []
    for index in 0..<3 {
        let url = directory.appendingPathComponent("\(index).webp")
        try data.write(to: url)
        let artifact = SharedArtifact(url: url, kind: .webP, width: 32, height: 24, byteCount: data.count)
        thumbnails.add(artifact, image: image, copied: false, seconds: 100, screen: nil, libraryOnly: true)
        artifacts.append(artifact)
    }
    defer { thumbnails.closeLibrarySessions() }
    let library = CaptureLibraryController(directory: { directory }, config: { UtsushieConfig() }, thumbnails: thumbnails, remembersFrame: false)
    await library.reload()
    let failed = library.files[1].url
    library.trashFiles = { urls in
        CaptureLibraryFileActions.trash(urls) { url in
            if url == failed { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: url, to: directory.appendingPathComponent(".moved-" + url.lastPathComponent))
        }
    }
    _ = library.handleKey(try actionsKey(0, flags: .command))
    _ = library.handleKey(try actionsKey(7))
    #expect(library.deleteConfirmation.isArmed && library.footerStatus?.hasPrefix("!") == true)
    _ = library.handleKey(try actionsKey(7, repeatKey: true))
    #expect(library.deleteConfirmation.isArmed && !library.isPerformingAction)
    _ = library.handleKey(try actionsKey(53))
    #expect(!library.deleteConfirmation.isArmed && library.files.count == 3)
    _ = library.handleKey(try actionsKey(7)); _ = library.handleKey(try actionsKey(7))
    try await finishActions(library)
    #expect(library.files.map(\.url) == [failed] && library.selection.urls == [failed])
    #expect(library.footerStatus?.hasPrefix("!") == true && thumbnails.recentImages.count == 1)
    for artifact in artifacts { #expect((thumbnails.card(for: artifact.url) != nil) == (artifact.url == failed)) }
}

@MainActor @Test func libraryExcludesEditingAndExportingFilesFromTrashAndAllDragsDuringExport() async throws {
    let directory = try actionsDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let thumbnails = ThumbnailController(), image = try actionsImage()
    thumbnails.editorFocus = .init(activate: {}, restore: { _ in })
    thumbnails.annotationConfig = { UtsushieConfig() }
    var urls: [URL] = []
    let data = try WebPEncoder.encode(image, quality: 80, lossless: true)
    for index in 0..<3 {
        let url = directory.appendingPathComponent("\(index).webp"); try data.write(to: url); urls.append(url)
        thumbnails.add(SharedArtifact(url: url, kind: .webP, width: 32, height: 24, byteCount: data.count),
            image: image, copied: false, seconds: 100, screen: nil, finalizing: index == 1, libraryOnly: true)
    }
    defer { thumbnails.closeLibrarySessions() }
    try #require(thumbnails.card(for: urls[0])).edit()
    let library = CaptureLibraryController(directory: { directory }, config: { UtsushieConfig() }, thumbnails: thumbnails, remembersFrame: false)
    await library.reload()
    library.trashFiles = { urls in
        CaptureLibraryFileActions.trash(urls) { url in
            try FileManager.default.moveItem(at: url, to: directory.appendingPathComponent(".moved-" + url.lastPathComponent))
        }
    }
    _ = library.handleKey(try actionsKey(0, flags: .command))
    #expect(library.dragURLs(from: urls[0]).isEmpty)
    _ = library.handleKey(try actionsKey(7)); _ = library.handleKey(try actionsKey(7))
    try await finishActions(library)
    #expect(Set(library.files.map(\.url)) == Set(urls[0...1]))
    #expect(library.footerStatus?.contains("2件は除外") == true)
    #expect(thumbnails.card(for: urls[0])?.editor != nil && thumbnails.card(for: urls[1])?.finalizing == true)
    #expect(thumbnails.card(for: urls[2]) == nil)
}

@MainActor @Test func libraryMoveCompletionClosesVisibleCardAndReconcilesSelection() async throws {
    let directory = try actionsDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let thumbnails = ThumbnailController(), image = try actionsImage()
    let url = try ArtifactStore.save(data: WebPEncoder.encode(image, quality: 80, lossless: true), kind: .webP, directory: directory)
    thumbnails.add(SharedArtifact(url: url, kind: .webP, width: 32, height: 24, byteCount: 1),
        image: image, copied: false, seconds: 100, screen: nil)
    defer { for card in thumbnails.cards { thumbnails.remove(card.id) } }
    let library = CaptureLibraryController(directory: { directory }, config: { UtsushieConfig() }, thumbnails: thumbnails, remembersFrame: false)
    await library.reload()
    library.dragEnded([url], operation: .copy)
    #expect(thumbnails.card(for: url) != nil && thumbnails.recentImages.count == 1)
    try FileManager.default.moveItem(at: url, to: directory.appendingPathComponent(".outside.webp"))
    library.dragEnded([url], operation: .move)
    await library.reload()
    #expect(thumbnails.cards.isEmpty && thumbnails.recentImages.count == 0 && library.selection.urls.isEmpty)
}

@MainActor @Test func libraryMouseSelectionKeepsGroupUntilReleaseAndDoubleClickDoesNotEditGroup() async throws {
    let directory = try actionsDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for index in 0..<4 { try Data([UInt8(index)]).write(to: directory.appendingPathComponent("\(index).webp")) }
    let library = CaptureLibraryController(directory: { directory }, config: { UtsushieConfig() },
        thumbnails: ThumbnailController(), remembersFrame: false)
    await library.reload()
    let urls = library.files.map(\.url)
    let scrollViews = library.window?.contentView?.subviews.compactMap { $0 as? NSScrollView } ?? []
    let scroll = try #require(scrollViews.first)
    let collection = try #require(scroll.documentView as? NSCollectionView)
    func cell(_ index: Int) -> NSView {
        library.collectionView(collection, itemForRepresentedObjectAt: IndexPath(item: index, section: 0)).view
    }
    func mouse(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
    }
    let commandCell = cell(2)
    commandCell.mouseDown(with: try mouse(.leftMouseDown, flags: .command))
    commandCell.mouseUp(with: try mouse(.leftMouseUp))
    #expect(library.selection.urls == [urls[0], urls[2]] && library.selection.anchorURL == urls[2])
    let rangeCell = cell(3)
    rangeCell.mouseDown(with: try mouse(.leftMouseDown, flags: .shift))
    rangeCell.mouseUp(with: try mouse(.leftMouseUp))
    #expect(library.selection.urls == [urls[2], urls[3]])
    let selectedCell = cell(2)
    selectedCell.mouseDown(with: try mouse(.leftMouseDown))
    #expect(library.selection.urls == [urls[2], urls[3]])
    selectedCell.mouseUp(with: try mouse(.leftMouseUp))
    #expect(library.selection.urls == [urls[2]])
    selectedCell.mouseDown(with: try mouse(.leftMouseDown, clicks: 2))
    selectedCell.mouseUp(with: try mouse(.leftMouseUp, clicks: 2))
    #expect(!library.isPerformingAction)
    _ = library.handleKey(try actionsKey(0, flags: .command))
    #expect(library.dragURLs(from: urls[2]) == urls)
    _ = library.handleKey(try actionsKey(7))
    let toggleCell = cell(2)
    toggleCell.mouseDown(with: try mouse(.leftMouseDown, flags: .command))
    toggleCell.mouseUp(with: try mouse(.leftMouseUp))
    #expect(!library.deleteConfirmation.isArmed && library.selection.urls == Set([urls[0], urls[1], urls[3]]))
    #expect(library.dragURLs(from: urls[2]) == [urls[2]])
    _ = library.handleKey(try actionsKey(7))
    library.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: library.window))
    #expect(!library.deleteConfirmation.isArmed)
    _ = library.handleKey(try actionsKey(7))
    _ = library.handleKey(try actionsKey(36))
    #expect(!library.deleteConfirmation.isArmed)
}

@MainActor @Test func libraryRemovalReservationPreventsCardEditingAndDragUntilFailureReturns() throws {
    let directory = try actionsDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let thumbnails = ThumbnailController(), image = try actionsImage()
    let url = try ArtifactStore.save(data: WebPEncoder.encode(image, quality: 80, lossless: true), kind: .webP, directory: directory)
    thumbnails.add(SharedArtifact(url: url, kind: .webP, width: 32, height: 24, byteCount: 1),
        image: image, copied: false, seconds: 100, screen: nil)
    defer { for card in thumbnails.cards { thumbnails.remove(card.id) } }
    let card = try #require(thumbnails.card(for: url))
    thumbnails.reserveLibraryRemoval([url])
    #expect(!card.canEdit && !card.canDrag && card.timer == nil)
    card.edit()
    #expect(card.editor == nil && !thumbnails.canRemoveFromLibrary(url))
    thumbnails.finishLibraryRemoval([url], removed: [])
    #expect(card.canEdit && card.canDrag && card.timer != nil)
}

@MainActor @Test func libraryPhysicalQIgnoresModifiersAndCancelsDeletionBeforeClosing() async throws {
    let directory = try actionsDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("q-close.webp")
    try Data([1]).write(to: url)
    let library = CaptureLibraryController(directory: { directory }, config: { UtsushieConfig() },
        thumbnails: ThumbnailController(), remembersFrame: false)
    library.applicationFocus = .init(activate: {}, restore: { _ in })
    // 自動再読込との競合を避け、テストの読み込みだけで選択を用意する。
    library.window?.orderFront(nil); defer { library.close() }
    await library.reload()
    for flags: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
        #expect(!library.handleKey(try actionsKey(12, flags: flags)))
        #expect(library.window?.isVisible == true)
    }
    _ = library.handleKey(try actionsKey(7))
    #expect(library.deleteConfirmation.isArmed)
    #expect(library.handleKey(try actionsKey(12, repeatKey: true)))
    #expect(!library.deleteConfirmation.isArmed && library.window?.isVisible == true)
    _ = library.handleKey(try actionsKey(7))
    #expect(library.deleteConfirmation.isArmed)
    // 文字がQでなくても、物理keyCodeだけで閉じる。
    let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: library.window!.windowNumber, context: nil, characters: "あ", charactersIgnoringModifiers: "あ",
        isARepeat: false, keyCode: 12))
    #expect(library.handleKey(key))
    #expect(!library.deleteConfirmation.isArmed && library.window?.isVisible == false)
    #expect(FileManager.default.fileExists(atPath: url.path))
}

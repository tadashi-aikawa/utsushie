import AppKit
import Testing
import UtsushieCore
@testable import Utsushie

@MainActor private func settleGrid(_ content: NSView, _ scroll: NSScrollView, _ collection: NSCollectionView) async {
    for _ in 0..<5 {
        content.layoutSubtreeIfNeeded(); collection.layoutSubtreeIfNeeded(); scroll.tile()
        await Task.yield()
    }
}

@MainActor private func expectGridAndVerticalKeys(_ library: CaptureLibraryController, _ collection: NSCollectionView) throws {
    let scroll = try #require(collection.enclosingScrollView)
    let layout = try #require(collection.collectionViewLayout as? NSCollectionViewFlowLayout)
    let files = try #require(library.sections.first).files
    let frames = try files.indices.map { index in
        try #require(layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))).frame
    }
    let first = try #require(frames.first)
    let displayedColumns = frames.filter { abs($0.minY - first.minY) < 0.5 }.count
    let grid = CaptureLibrary.gridLayout(for: scroll.contentSize.width)
    #expect(displayedColumns == grid.columns)
    #expect(layout.itemSize == CGSize(width: grid.itemWidth, height: grid.itemHeight))
    guard files.count >= displayedColumns * 2 else { return }
    // 実際の移動先から、Coreへ渡る列数も表示と同じであることを確かめる。
    for (down, up): (UInt16, UInt16) in [(125, 126), (38, 40)] {
        for column in 0..<displayedColumns {
            library.select(files[column].url)
            func key(_ code: UInt16) throws -> NSEvent {
                try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            }
            #expect(library.handleKey(try key(down)))
            let selected = try #require(files.firstIndex { $0.url == library.selection.focusedURL })
            #expect(selected == column + displayedColumns)
            #expect(abs(frames[selected].minX - frames[column].minX) < 0.5)
            #expect(frames[selected].minY > frames[column].minY)
            #expect(library.handleKey(try key(up)))
            #expect(library.selection.focusedURL == files[column].url)
        }
    }
}

@MainActor @Test func libraryGridKeepsVerticalMovementInColumnWhenLegacyScrollerAppears() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("utsushie-grid-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = CaptureLibraryController(directory: { directory }, config: { UtsushieConfig() },
        thumbnails: ThumbnailController(), remembersFrame: false)
    defer { library.close() }
    library.loadThumbnail = { _ in throw CocoaError(.fileReadCorruptFile) }
    let window = try #require(library.window)
    let content = try #require(window.contentView)
    let scroll = try #require(content.subviews.compactMap { $0 as? NSScrollView }.first)
    let collection = try #require(scroll.documentView as? NSCollectionView)
    let layout = try #require(collection.collectionViewLayout as? NSCollectionViewFlowLayout)
    scroll.scrollerStyle = .legacy
    await library.reload()
    content.layoutSubtreeIfNeeded()
    collection.layoutSubtreeIfNeeded()
    // 空の一覧で列幅を確定し、窓をリサイズせずに内容だけを増やす。
    library.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
    let widthWithoutScroller = scroll.contentSize.width
    let sizeWithoutScroller = layout.itemSize
    for index in 0..<48 {
        try Data([1]).write(to: directory.appendingPathComponent("\(index).webp"))
    }
    await library.reload()
    await settleGrid(content, scroll, collection)
    #expect(scroll.contentSize.width < widthWithoutScroller)
    #expect(scroll.verticalScroller?.isHidden == false)
    try expectGridAndVerticalKeys(library, collection)
    #expect(layout.itemSize != sizeWithoutScroller)
    // 件数が減ってスクロールバーが消える場合も、元の幅へ戻す。
    for file in library.files.dropFirst(4) { try FileManager.default.removeItem(at: file.url) }
    await library.reload()
    await settleGrid(content, scroll, collection)
    #expect(scroll.verticalScroller?.isHidden == true)
    #expect(scroll.contentSize.width == widthWithoutScroller)
    #expect(layout.itemSize == sizeWithoutScroller)
    try expectGridAndVerticalKeys(library, collection)
}

@MainActor @Test(arguments: [NSScroller.Style.legacy, .overlay])
func libraryGridKeepsVerticalMovementInColumnAfterFrameRestoreAndResize(_ style: NSScroller.Style) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("utsushie-grid-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for index in 0..<48 { try Data([1]).write(to: directory.appendingPathComponent("\(index).webp")) }
    let name = "UTSUSHIE-Grid-Test-\(UUID().uuidString)"
    defer { NSWindow.removeFrame(usingName: name) }
    let seed = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 860, height: 520),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    seed.isReleasedWhenClosed = false
    let savedSize = seed.frame.size
    seed.saveFrame(usingName: name); seed.close()
    let library = CaptureLibraryController(directory: { directory }, config: { UtsushieConfig() },
        thumbnails: ThumbnailController(), frameAutosaveName: name)
    let window = try #require(library.window)
    defer { window.setFrameAutosaveName(""); library.close() }
    library.loadThumbnail = { _ in throw CocoaError(.fileReadCorruptFile) }
    #expect(window.frame.size == savedSize)
    let content = try #require(window.contentView)
    let scroll = try #require(content.subviews.compactMap { $0 as? NSScrollView }.first)
    let collection = try #require(scroll.documentView as? NSCollectionView)
    scroll.scrollerStyle = style
    await library.reload()
    await settleGrid(content, scroll, collection)
    try expectGridAndVerticalKeys(library, collection)
    for width in [1100, 680, 1040] {
        window.setContentSize(CGSize(width: width, height: 520))
        await settleGrid(content, scroll, collection)
        try expectGridAndVerticalKeys(library, collection)
    }
}

import Foundation
import Testing
import UtsushieCore

private func libraryFile(_ name: String, _ seconds: Double = 0) -> RecentCaptureFile {
    RecentCaptureFile(url: URL(fileURLWithPath: "/tmp/\(name)"), date: Date(timeIntervalSince1970: seconds))
}

@Test func libraryCloseKeysDismissPreviewBeforeLibrary() {
    #expect(CaptureLibrary.closeTarget(previewVisible: true) == .preview)
    #expect(CaptureLibrary.closeTarget(previewVisible: false) == .library)
}

@Test func libraryIncludesThousandsOfFilesWithStableSortingAndExclusions() {
    let files = (0..<4000).map { libraryFile("\($0).\($0.isMultiple(of: 2) ? "mp4" : "webp")", Double($0)) }
    let excluded = [libraryFile(".hidden.webp"), libraryFile("live.recording.mp4"), libraryFile("x.webp.tmp"), libraryFile("x.png"),
        RecentCaptureFile(url: URL(fileURLWithPath: "/tmp/directory.webp"), date: Date(), isRegularFile: false),
        RecentCaptureFile(url: URL(fileURLWithPath: "/tmp/hidden.webp"), date: Date(), isHidden: true)]
    #expect(RecentCaptures.all(files + excluded) == files.reversed())
    let ties = [libraryFile("a.webp"), libraryFile("b.MP4")]
    #expect(RecentCaptures.all(ties) == ties.reversed())
    #expect(RecentCaptures.newest(files).count == 10)
}

@Test func libraryDayHeadersUseLocalDayBoundariesAndYesterdayAcrossMonth() {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
    func date(_ month: Int, _ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
    let now = date(10, 1, 0)
    let files = [date(10, 1, 0), date(9, 30, 23), date(9, 30, 1), date(9, 26, 12)].enumerated().map {
        RecentCaptureFile(url: URL(fileURLWithPath: "/tmp/\($0.offset).webp"), date: $0.element)
    }
    let sections = CaptureLibrary.sections(files.reversed(), now: now, calendar: calendar)
    #expect(sections.map(\.title) == ["今日", "昨日", "9月26日(土)"])
    #expect(sections.map { $0.files.count } == [1, 2, 1])
    #expect(CaptureLibrary.sections([], now: now, calendar: calendar).isEmpty)
}

@Test func libraryGridMovesAcrossHeadersInSameColumnAndClampsShortRows() {
    let counts = [6, 2, 9]
    func moved(_ section: Int, _ item: Int, _ direction: CaptureGridDirection, columns: Int = 4) -> CaptureGridPosition {
        CaptureGridPosition(section: section, item: item).moved(direction, counts: counts, columns: columns)
    }
    #expect(moved(0, 3, .down) == .init(section: 0, item: 5))
    #expect(moved(0, 5, .down) == .init(section: 1, item: 1))
    #expect(moved(1, 1, .up) == .init(section: 0, item: 5))
    #expect(moved(1, 1, .down) == .init(section: 2, item: 1))
    #expect(moved(2, 3, .up) == .init(section: 1, item: 1))
    #expect(moved(0, 5, .right) == .init(section: 1, item: 0))
    #expect(moved(1, 0, .left) == .init(section: 0, item: 5))
    #expect(moved(0, 0, .left) == .init(section: 0, item: 0))
    #expect(moved(0, 3, .up) == .init(section: 0, item: 3))
    #expect(moved(2, 8, .down) == .init(section: 2, item: 8))
    #expect(moved(2, 8, .right) == .init(section: 2, item: 8))
    #expect(moved(0, 3, .down, columns: 2) == .init(section: 0, item: 5))
    #expect(moved(0, 3, .up, columns: 2) == .init(section: 0, item: 1))
    #expect(moved(0, 3, .down, columns: 6) == .init(section: 1, item: 1))
    #expect(CaptureGridPosition(section: 9, item: 0).moved(.down, counts: counts, columns: 0) == .init(section: 9, item: 0))
    #expect(CaptureGridPosition(section: 0, item: 0).moved(.down, counts: [1, 0, 2], columns: 4) == .init(section: 2, item: 0))
    #expect(CaptureLibrary.columns(for: 1100) == 4 && CaptureLibrary.columns(for: 680) == 2)
}

@Test(arguments: [Double(-100), 0, 1, 12, 36, 49, 543, 544, 680, 1100, .nan, .infinity, -.infinity, .greatestFiniteMagnitude])
func libraryGridAlwaysProducesFinitePositiveItemSize(_ width: Double) {
    let grid = CaptureLibrary.gridLayout(for: width)
    #expect(grid.columns >= 1)
    #expect(grid.itemWidth.isFinite && grid.itemWidth >= 13)
    #expect(grid.itemHeight.isFinite && grid.itemHeight > 36)
    #expect(CaptureLibrary.columns(for: width) == grid.columns)
    if width.isFinite && width >= 49 {
        // 最大の有限値でも列幅の合計を掛け算でオーバーフローさせず検証する。
        let roomPerItem = (width - 36 - 16 * Double(grid.columns - 1)) / Double(grid.columns)
        #expect(grid.itemWidth <= roomPerItem)
    }
}

@Test func libraryGridColumnCountUsesTheSameInsetsAndSpacingAsItemSize() {
    let boundary = CaptureLibrary.gridLayout(for: 544)
    #expect(boundary.columns == 2 && boundary.itemWidth == 246)
    #expect(CaptureLibrary.gridLayout(for: 543).columns == 1)
    let regular = CaptureLibrary.gridLayout(for: 1100)
    #expect(regular.columns == 4 && regular.itemWidth == 254 && regular.itemHeight == 187.25)
    let compact = CaptureLibrary.gridLayout(for: 680)
    #expect(compact.columns == 2 && compact.itemWidth == 314)
}

@Test func libraryMetadataAndVideoBadgesAreCompactAndGuardInvalidDuration() {
    let file = libraryFile("image.webp"), zone = TimeZone(secondsFromGMT: 9 * 3600)!
    #expect(CaptureLibrary.metadata(file: file, width: 1280, height: 800, bytes: 186 * 1024, timeZone: zone) == "09:00  1280×800  186 KB")
    #expect(CaptureLibrary.metadata(file: file, width: 1, height: 1, bytes: 1_572_864, timeZone: zone).hasSuffix("1.5 MB"))
    #expect(CaptureLibrary.videoBadge(24.9) == "▶ 0:24")
    #expect(CaptureLibrary.videoBadge(.nan) == "▶ 0:00")
    #expect(CaptureLibrary.videoBadge(-1) == "▶ 0:00")
}

@Test func librarySelectionPersistsThroughReorderingAndFallsBackWhenDeleted() {
    let first = libraryFile("a.webp"), second = libraryFile("b.webp")
    var selection = CaptureLibrarySelection()
    selection.reconcile([first, second]); #expect(selection.focusedURL == first.url)
    selection.select(second.url); selection.reconcile([second, first])
    #expect(selection.urls == [second.url] && selection.focusedURL == second.url)
    selection.reconcile([first]); #expect(selection.focusedURL == first.url)
    selection.reconcile([]); #expect(selection.urls.isEmpty && selection.focusedURL == nil)
}

@Test func libraryHotkeyIsOptionalValidatedAndDisabledOnCaptureConflict() {
    #expect(ConfigLoader.parse(toml: "").config.libraryHotkey == nil)
    let valid = ConfigLoader.parse(toml: "[libraryHotkey]\nkeyCode = 37\nmodifiers = [\"command\", \"shift\"]")
    #expect(valid.config.libraryHotkey == Hotkey(keyCode: 37, modifiers: 768) && valid.warnings.isEmpty)
    for text in ["keyCode = 128\nmodifiers = [\"command\"]", "keyCode = 1\nmodifiers = [\"shift\"]",
                 "keyCode = 1\nmodifiers = [\"unknown\"]", "keyCode = 1", "modifiers = [\"command\"]", ""] {
        let result = ConfigLoader.parse(toml: "[libraryHotkey]\n" + text)
        #expect(result.config.libraryHotkey == nil && result.config.hotkey == Hotkey())
        #expect(result.warnings == ["libraryHotkey が不正なため無効にします"])
    }
    let invalidSection = ConfigLoader.parse(toml: "libraryHotkey = false")
    #expect(invalidSection.config.libraryHotkey == nil && invalidSection.warnings == ["libraryHotkey が不正なため無効にします"])
    let conflict = ConfigLoader.parse(toml: "[libraryHotkey]\nkeyCode = 19\nmodifiers = [\"shift\", \"command\"]\n[webp]\nquality = 90")
    #expect(conflict.config.libraryHotkey == nil && conflict.config.hotkey == Hotkey() && conflict.config.quality == 90)
    #expect(conflict.warnings.contains { $0.contains("撮影のホットキーと同じ") })
    let custom = ConfigLoader.parse(toml: "[hotkey]\nkeyCode = 37\nmodifiers = [\"option\"]\n[libraryHotkey]\nkeyCode = 37\nmodifiers = [\"option\"]")
    #expect(custom.config.libraryHotkey == nil && custom.config.hotkey.keyCode == 37)
}

@Test func libraryShiftSelectionExpandsShrinksAndCrossesAnchorInDisplayOrder() {
    let urls = (0..<7).map { libraryFile("range-\($0).webp").url }
    var selection = CaptureLibrarySelection()
    selection.select(urls[3])
    selection.select(urls[6], mode: .range, orderedURLs: urls)
    #expect(selection.urls == Set(urls[3...6]) && selection.anchorURL == urls[3])
    selection.select(urls[4], mode: .range, orderedURLs: urls)
    #expect(selection.urls == Set(urls[3...4]))
    selection.select(urls[1], mode: .range, orderedURLs: urls)
    #expect(selection.urls == Set(urls[1...3]) && selection.focusedURL == urls[1])
    selection.select(urls[3], mode: .range, orderedURLs: urls)
    #expect(selection.urls == [urls[3]])
}

@Test func libraryCommandToggleAllAndPlainSelectionKeepFocusAndAnchor() {
    let urls = (0..<4).map { libraryFile("toggle-\($0).webp").url }
    var selection = CaptureLibrarySelection()
    selection.select(urls[0])
    selection.select(urls[2], mode: .toggle, orderedURLs: urls)
    #expect(selection.urls == [urls[0], urls[2]] && selection.anchorURL == urls[2])
    selection.select(urls[2], mode: .toggle, orderedURLs: urls)
    #expect(selection.urls == [urls[0]] && selection.focusedURL == urls[2])
    selection.select(urls[3], mode: .range, orderedURLs: urls)
    #expect(selection.urls == [urls[2], urls[3]])
    selection.selectAll(urls)
    #expect(selection.urls == Set(urls) && selection.focusedURL == urls[3])
    selection.select(urls[1], mode: .single, orderedURLs: urls)
    #expect(selection.urls == [urls[1]] && selection.anchorURL == urls[1])
    selection.select(urls[1], mode: .toggle, orderedURLs: urls)
    #expect(selection.urls.isEmpty && selection.anchorURL == urls[1])
    selection.selectAll([])
    #expect(selection.urls.isEmpty && selection.focusedURL == nil && selection.anchorURL == nil)
}

@Test func libraryMultipleSelectionReconcilesRemovedFocusWithoutLosingSurvivors() {
    let files = (0..<4).map { libraryFile("reconcile-\($0).webp") }, urls = files.map(\.url)
    var selection = CaptureLibrarySelection()
    selection.selectAll(urls)
    selection.reconcile(Array(files[1...].reversed()))
    #expect(selection.urls == Set(urls[1...]) && selection.focusedURL == urls[3] && selection.anchorURL == urls[3])
    selection.reconcile([files[2], files[3]])
    #expect(selection.urls == [urls[2], urls[3]])
    selection.select(urls[3], mode: .toggle, orderedURLs: urls)
    selection.reconcile([files[2], files[3]])
    #expect(selection.urls == [urls[2]] && selection.focusedURL == urls[3])
    selection.reconcile([])
    #expect(selection.urls.isEmpty && selection.focusedURL == nil && selection.anchorURL == nil)
}

@Test func libraryDeletionNeedsTwoDistinctPressesAndIgnoresRepeats() {
    let first = libraryFile("delete-a.webp").url, second = libraryFile("delete-b.webp").url
    var confirmation = CaptureLibraryDeleteConfirmation()
    #expect(confirmation.press(selected: [first], isRepeat: true) == .ignored && !confirmation.isArmed)
    #expect(confirmation.press(selected: [], isRepeat: false) == .ignored)
    #expect(confirmation.press(selected: [first], isRepeat: false) == .armed)
    #expect(confirmation.press(selected: [first], isRepeat: true) == .ignored && confirmation.isArmed)
    #expect(confirmation.press(selected: [second], isRepeat: false) == .armed)
    #expect(confirmation.press(selected: [second], isRepeat: false) == .trash && !confirmation.isArmed)
}

@Test(arguments: CaptureLibraryDeleteInterruption.allCases)
func libraryDeletionConfirmationCancelsOnEveryInterruption(_ reason: CaptureLibraryDeleteInterruption) {
    var confirmation = CaptureLibraryDeleteConfirmation()
    let urls: Set<URL> = [libraryFile("interrupt.webp").url]
    _ = confirmation.press(selected: urls, isRepeat: false)
    #expect(confirmation.interrupt(reason) && !confirmation.isArmed)
    let cancelledAgain = confirmation.interrupt(reason)
    #expect(!cancelledAgain)
    #expect(confirmation.press(selected: urls, isRepeat: false) == .armed)
}

@Test func libraryDeletedSelectionMovesForwardThenBackOrEmptyAndRetainsFailures() {
    let urls = (0..<6).map { libraryFile("next-\($0).webp").url }
    var selection = CaptureLibrarySelection()
    selection.selectAll(urls)
    selection.didRemove(Set(urls[1...3]), orderedURLs: urls)
    #expect(selection.urls == [urls[4]])
    selection.didRemove(Set(urls[4...]), orderedURLs: Array(urls[0...0]) + Array(urls[4...]))
    #expect(selection.urls == [urls[0]])
    selection.didRemove([urls[0]], orderedURLs: [urls[0]])
    #expect(selection.urls.isEmpty && selection.focusedURL == nil)
    selection.didRemove([urls[1], urls[3]], failed: [urls[2], urls[4]], orderedURLs: urls)
    #expect(selection.urls == [urls[2], urls[4]] && selection.focusedURL == urls[2])
    selection.didRemove([], failed: [urls[5]], orderedURLs: urls)
    #expect(selection.urls == [urls[5]])
    selection.didRemove([urls[1], urls[4]], orderedURLs: urls)
    #expect(selection.urls == [urls[2]])
}

@Test func libraryDragPreservesSelectedSetOrSelectsOnlyOutsideItemAndForcesOperation() {
    let urls = (0..<3).map { libraryFile("drag-\($0).webp").url }
    var selection = CaptureLibrarySelection()
    selection.select(urls[0]); selection.select(urls[1], mode: .toggle, orderedURLs: urls)
    selection.prepareDrag(from: urls[0])
    #expect(selection.urls == [urls[0], urls[1]])
    selection.prepareDrag(from: urls[2])
    #expect(selection.urls == [urls[2]] && selection.anchorURL == urls[2])
    #expect(CaptureLibraryDragOperation.allowed(commandPressed: false) == .copy)
    #expect(CaptureLibraryDragOperation.allowed(commandPressed: true) == .move)
}

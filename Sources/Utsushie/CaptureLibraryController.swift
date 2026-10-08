import AppKit
import QuickLookUI
import UniformTypeIdentifiers
import UtsushieCore

/// セルの絵は可視項目だけ、同時に4件まで読む。全件の列挙はメインスレッド外で行う。
@MainActor
final class CaptureLibraryController: NSWindowController, NSWindowDelegate, NSCollectionViewDataSource,
    NSCollectionViewDelegate, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    private let directory: () -> URL
    private let config: () -> UtsushieConfig
    private let thumbnails: ThumbnailController
    private let collection = LibraryCollectionView()
    private let scroll = NSScrollView()
    private let layout = NSCollectionViewFlowLayout()
    private let footer = LibraryFooter()
    private let empty = NSTextField(labelWithString: "撮影はありません")
    private let pathLabel = NSTextField(labelWithString: "")
    private var previousApplication: NSRunningApplication?
    var applicationFocus = AnnotationApplicationFocus()
    var loadThumbnail: (RecentCaptureFile) async throws -> LoadedCapture = {
        try await RecentCaptureStore.load($0, maximumPixelSize: 640)
    }
    private(set) var files: [RecentCaptureFile] = []
    private(set) var sections: [CaptureDaySection] = []
    private(set) var selection = CaptureLibrarySelection()
    private(set) var deleteConfirmation = CaptureLibraryDeleteConfirmation()
    private var isTrashing = false
    var trashFiles: @Sendable ([URL]) -> CaptureLibraryTrashResult = { CaptureLibraryFileActions.trash($0) }
    var copyEntries: ([ClipboardEntry], ClipboardMode) -> Bool = {
        ClipboardWriter.copy($0, mode: $1, to: .general, preservingOnFailure: true)
    }
    var isPerformingAction: Bool { actionTask != nil }
    var footerStatus: String? { footer.status }
    private var orderedURLs: [URL] { sections.flatMap { $0.files.map(\.url) } }
    private var selectedURLs: [URL] { orderedURLs.filter { selection.urls.contains($0) } }
    private var singleSelectedURL: URL? { selection.urls.count == 1 ? selectedURLs.first : nil }
    private var positions: [URL: IndexPath] = [:]
    private var columns = 4
    private var reloadTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var generation = 0
    private var previewPanel: QLPreviewPanel?
    private var keyMonitor: Any?
    private let cache = NSCache<NSString, LibraryThumbnail>()
    private var pending: [RecentCaptureFile] = []
    private var loading: [String: Task<Void, Never>] = [:]
    var isLoadingThumbnails: Bool { !pending.isEmpty || !loading.isEmpty }
    private var statuses: [URL: String] = [:]
    private var message: String?
    private var isClosing = false

    init(directory: @escaping () -> URL, config: @escaping () -> UtsushieConfig, thumbnails: ThumbnailController,
         remembersFrame: Bool = true, frameAutosaveName: String = "CaptureLibrary") {
        self.directory = directory; self.config = config; self.thumbnails = thumbnails
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 732),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.title = "撮影の一覧 0件"; window.minSize = CGSize(width: 680, height: 440)
        window.backgroundColor = UITheme.ink; window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right
        accessory.view = NSView(frame: CGRect(x: 0, y: 0, width: 380, height: 28))
        pathLabel.frame = CGRect(x: 0, y: 6, width: 362, height: 18)
        pathLabel.font = .systemFont(ofSize: 12); pathLabel.textColor = UITheme.key
        pathLabel.alignment = .right; pathLabel.lineBreakMode = .byTruncatingMiddle
        accessory.view.addSubview(pathLabel); window.addTitlebarAccessoryViewController(accessory)
        guard let content = window.contentView else { return }
        content.wantsLayer = true; content.layer?.backgroundColor = UITheme.ink.cgColor
        layout.minimumInteritemSpacing = 16; layout.minimumLineSpacing = 18
        layout.sectionInset = NSEdgeInsets(top: 4, left: 18, bottom: 8, right: 18)
        collection.collectionViewLayout = layout
        collection.backgroundColors = [UITheme.ink]; collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.dataSource = self; collection.delegate = self
        collection.register(LibraryItem.self, forItemWithIdentifier: .init("Capture"))
        collection.register(LibraryDayHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: .init("Day"))
        collection.handleKey = { [weak self] event in self?.handleKey(event) ?? false }
        collection.onBackgroundClick = { [weak self] in
            guard let self, !self.isTrashing else { return }
            self.selection.select(nil); self.selectionChanged()
        }
        scroll.documentView = collection; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = true; scroll.backgroundColor = UITheme.ink
        for view in [scroll, footer, empty] {
            view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view)
        }
        empty.textColor = UITheme.muted; empty.font = .systemFont(ofSize: 14)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor), footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor), footer.heightAnchor.constraint(equalToConstant: 40),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])
        cache.countLimit = 120; cache.totalCostLimit = 64 * 1024 * 1024
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification, object: scroll.contentView)
        // 保存済みframeの復元はresize通知を起こす。ビューを用意し、delegateなしで復元する。
        if remembersFrame { window.setFrameAutosaveName(frameAutosaveName) }
        resizeGrid()
        window.delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func open() {
        guard let window else { return }
        isClosing = false
        if !window.isVisible {
            selection.select(nil); cancelDelete(.selectionChange); message = nil
            if let front = applicationFocus.frontmostApplication(), front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousApplication = front
            }
        }
        applicationFocus.activate(); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(collection)
        installKeyMonitor(); resizeGrid(); refresh()
    }
    func refresh() {
        guard window?.isVisible == true else { return }
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in await self?.reload() }
    }
    /// 公開フォルダの状態を値として取り込み、同じURLの選択を保つ。
    func reload() async {
        guard !isTrashing else { return }
        generation += 1; let token = generation; let directory = directory()
        do {
            let result = try await Task.detached(priority: .userInitiated) { try RecentCaptureStore.files(in: directory) }.value
            guard !Task.isCancelled, token == generation else { return }
            files = result; sections = CaptureLibrary.sections(result)
            layout.headerReferenceSize = sections.isEmpty ? .zero : CGSize(width: 0, height: 42)
            positions = [:]
            for (section, day) in sections.enumerated() {
                for (item, file) in day.files.enumerated() { positions[file.url] = IndexPath(item: item, section: section) }
            }
            let oldSelection = selection
            selection.reconcile(result); thumbnails.pruneMemory(to: result)
            if selection != oldSelection { cancelDelete(.selectionChange) }
            statuses = statuses.filter { positions[$0.key] != nil }
            pathLabel.stringValue = directory.path; pathLabel.toolTip = directory.path
            window?.title = "撮影の一覧 \(result.count)件"
            empty.stringValue = "撮影はありません"; empty.isHidden = !result.isEmpty
            collection.reloadData(); syncSelection(scrollToSelection: false); updateFooter()
            previewPanel?.reloadData()
        } catch {
            guard !Task.isCancelled, token == generation else { return }
            message = "! 撮影の一覧を読めませんでした: " + error.localizedDescription
            empty.stringValue = "! 撮影の一覧を読めませんでした"; empty.isHidden = !files.isEmpty
            updateFooter()
        }
    }
    func windowDidBecomeKey(_ notification: Notification) { if notification.object as? NSWindow === window { refresh() } }
    func windowDidResignKey(_ notification: Notification) {
        if notification.object as? NSWindow === window { cancelDelete(.resignKey) }
    }
    func windowDidResize(_ notification: Notification) { if notification.object as? NSWindow === window { resizeGrid() } }
    private func resizeGrid() {
        window?.contentView?.layoutSubtreeIfNeeded()
        updateGridLayout()
    }
    @objc private func clipFrameDidChange(_ notification: Notification) {
        // スクロールバーの出入りでも幅が変わる。通知中に親のレイアウトを再入させない。
        updateGridLayout()
    }
    private func updateGridLayout() {
        let grid = CaptureLibrary.gridLayout(for: scroll.contentView.bounds.width)
        let itemSize = CGSize(width: grid.itemWidth, height: grid.itemHeight)
        guard columns != grid.columns || layout.itemSize != itemSize else { return }
        columns = grid.columns
        layout.itemSize = itemSize
        layout.invalidateLayout()
    }
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        isClosing = true
        cancelDelete(.resignKey)
        closePreview(); reloadTask?.cancel(); actionTask?.cancel(); generation += 1
        loading.values.forEach { $0.cancel() }; pending.removeAll()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil
        thumbnails.closeLibrarySessions()
        if applicationFocus.frontmostApplication()?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           let previousApplication, !previousApplication.isTerminated,
           previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            applicationFocus.restore(previousApplication)
        }
        previousApplication = nil
    }
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, let eventWindow = event.window, self.window?.attachedSheet == nil,
                  eventWindow === self.window || eventWindow === self.previewPanel else { return event }
            if event.type != .keyDown { self.cancelDelete(.click); return event }
            return self.handleKey(event) ? nil : event
        }
    }
    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        guard window?.attachedSheet == nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 7 && modifiers.isEmpty {
            if !isTrashing && actionTask == nil {
                switch deleteConfirmation.press(selected: selection.urls, isRepeat: event.isARepeat) {
                case .armed: message = nil; syncSelection(scrollToSelection: false); updateFooter()
                case .trash: trashSelected()
                case .ignored: break
                }
            }
            return true
        }
        if event.keyCode == 53 && modifiers.isEmpty && deleteConfirmation.isArmed {
            if !event.isARepeat { cancelDelete(.escape) }
            return true
        }
        cancelDelete(.otherKey)
        if modifiers == .command {
            switch event.keyCode {
            case 0:
                if !event.isARepeat && !isTrashing {
                    selection.selectAll(orderedURLs); selectionChanged()
                }
                return true
            case 8: if !event.isARepeat { copySelected() }; return true
            case 13: if !event.isARepeat { closeFromKeyboard() }; return true
            default: return false
            }
        }
        guard modifiers.isEmpty || modifiers == .shift else { return false }
        let direction: CaptureGridDirection?
        switch event.keyCode {
        case 123, 4: direction = .left
        case 124, 37: direction = .right
        case 125, 38: direction = .down
        case 126, 40: direction = .up
        default: direction = nil
        }
        if let direction { move(direction, extending: modifiers == .shift); return true }
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 36, 76, 14: if !event.isARepeat { editSelected() }; return true
        case 1: if !event.isARepeat { saveSelected() }; return true
        case 31:
            if !event.isARepeat, requireSingleSelection(), let url = singleSelectedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            return true
        case 49: if !event.isARepeat { togglePreview() }; return true
        case 12, 53: if !event.isARepeat { closeFromKeyboard() }; return true
        default: return false
        }
    }
    func select(_ url: URL, mode: CaptureLibrarySelectionMode = .single) {
        guard positions[url] != nil, !isTrashing else { return }
        selection.select(url, mode: mode, orderedURLs: orderedURLs); selectionChanged()
    }
    private func selectionChanged(scrollToSelection: Bool = true) {
        cancelDelete(.selectionChange); message = nil; syncSelection(scrollToSelection: scrollToSelection); updateFooter()
        if selection.urls.count != 1 { closePreview() }
        previewPanel?.reloadData()
    }
    func move(_ direction: CaptureGridDirection, extending: Bool = false) {
        if selection.focusedURL == nil, let first = orderedURLs.first {
            select(first); return
        }
        guard let url = selection.focusedURL, let current = positions[url] else { return }
        let next = CaptureGridPosition(section: current.section, item: current.item)
            .moved(direction, counts: sections.map { $0.files.count }, columns: columns)
        select(sections[next.section].files[next.item].url, mode: extending ? .range : .single)
    }
    private func syncSelection(scrollToSelection: Bool = true) {
        collection.selectionIndexPaths = Set(selection.urls.compactMap { positions[$0] })
        for case let item as LibraryItem in collection.visibleItems() {
            item.isSelected = item.cell.file.map { selection.urls.contains($0.url) } ?? false
            item.cell.deleteArmed = deleteConfirmation.isArmed && item.isSelected
            item.cell.multipleSelection = selection.urls.count > 1
            item.cell.needsDisplay = true
        }
        if scrollToSelection, let url = selection.focusedURL, let position = positions[url] {
            collection.scrollToItems(at: [position], scrollPosition: .nearestHorizontalEdge.union(.nearestVerticalEdge))
        }
    }
    private func updateFooter() {
        footer.multiple = selection.urls.count > 1
        footer.deleteArmed = deleteConfirmation.isArmed
        footer.filename = footer.multiple ? "\(selection.urls.count)件を選択" : singleSelectedURL?.lastPathComponent ?? ""
        if deleteConfirmation.isArmed {
            let blocked = selectedURLs.filter { !thumbnails.canRemoveFromLibrary($0) }.count
            footer.status = "! もう一度 X でゴミ箱へ \(selection.urls.count - blocked)件"
                + (blocked > 0 ? "・編集中／書き出し中の\(blocked)件は除外" : "")
        } else { footer.status = message ?? singleSelectedURL.flatMap { statuses[$0] } }
        footer.needsDisplay = true
    }
    private func cancelDelete(_ reason: CaptureLibraryDeleteInterruption) {
        guard deleteConfirmation.interrupt(reason) else { return }
        syncSelection(scrollToSelection: false); updateFooter()
    }
    private func requireSingleSelection() -> Bool {
        guard selection.urls.count == 1 else {
            if selection.urls.count > 1 { message = "この操作は1件ずつ"; updateFooter() }
            return false
        }
        return true
    }
    private func trashSelected() {
        let ordered = orderedURLs, selected = selectedURLs
        let targets = selected.filter { thumbnails.canRemoveFromLibrary($0) }
        let skipped = selected.count - targets.count
        syncSelection(scrollToSelection: false)
        guard !targets.isEmpty else {
            message = "! 編集中／書き出し中の\(skipped)件はゴミ箱へ移せません"; updateFooter(); return
        }
        closePreview(); isTrashing = true; reloadTask?.cancel(); generation += 1
        thumbnails.reserveLibraryRemoval(targets)
        message = "ゴミ箱へ移しています \(targets.count)件"; updateFooter()
        let trash = trashFiles
        actionTask = Task { [self] in
            defer { actionTask = nil }
            // 開始済みの移動は一覧を閉じても完了させ、カードと元録画を必ず後片付けする。
            let result = await Task.detached(priority: .userInitiated) { trash(targets) }.value
            thumbnails.finishLibraryRemoval(targets, removed: result.removed)
            selection.didRemove(result.removed, failed: result.failed, orderedURLs: ordered)
            isTrashing = false
            message = !result.failed.isEmpty ? "! \(result.failed.count)件をゴミ箱へ移せませんでした"
                : "ゴミ箱へ移しました \(result.removed.count)件"
            if skipped > 0 { message = (message ?? "") + "・! 編集中／書き出し中の\(skipped)件は除外" }
            if !isClosing { await reload() }
        }
    }
    func setExportStatus(_ url: URL, status: String?) {
        statuses[url.standardizedFileURL] = status
        updateVisibleItems(); updateFooter()
        if status == nil { refresh() }
    }
    private func fail(_ error: Error) { message = "! " + error.localizedDescription; updateFooter() }
    private func editSelected() {
        guard requireSingleSelection(), let url = singleSelectedURL, actionTask == nil else { return }
        closePreview(); message = nil; updateFooter()
        actionTask = Task { [weak self] in
            guard let self else { return }
            defer { actionTask = nil }
            do {
                try await thumbnails.editFromLibrary(url) { [weak self] in
                    guard let self, !self.isClosing, let window = self.window, window.isVisible else { return }
                    selection.select(url); syncSelection(); updateFooter()
                    applicationFocus.activate(); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(collection); refresh()
                }
            } catch { if !Task.isCancelled { fail(error) } }
        }
    }
    private func copySelected() {
        let urls = selectedURLs
        guard !urls.isEmpty, actionTask == nil else { return }
        let mode = config().clipboard
        actionTask = Task { [weak self] in
            guard let self else { return }; defer { actionTask = nil }
            do {
                let entries = try await Task.detached(priority: .userInitiated) {
                    try CaptureLibraryFileActions.clipboardEntries(urls, mode: mode)
                }.value
                guard !Task.isCancelled else { return }
                guard copyEntries(entries, mode) else {
                    throw CaptureError.unavailable("クリップボードへコピーできませんでした")
                }
                message = "コピー済み \(entries.count)件"; updateFooter()
            } catch { fail(error) }
        }
    }
    private func saveSelected() {
        guard requireSingleSelection(), let url = singleSelectedURL, let window, actionTask == nil else { return }
        let save = NSSavePanel(); save.nameFieldStringValue = url.lastPathComponent
        save.directoryURL = url.deletingLastPathComponent(); save.canCreateDirectories = true
        save.allowedContentTypes = [UTType(filenameExtension: url.pathExtension) ?? .data]
        save.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let target = save.url, target.standardizedFileURL != url.standardizedFileURL else { return }
            self.actionTask = Task { [weak self] in
                guard let self else { return }; defer { actionTask = nil }
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try Data(contentsOf: url, options: .mappedIfSafe).write(to: target, options: .atomic)
                    }.value
                    refresh()
                } catch { fail(error) }
            }
        }
    }

    // MARK: 再利用するセルと、可視項目だけの縮小読み込み
    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { sections[section].files.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: .init("Capture"), for: indexPath) as! LibraryItem
        configure(item, file: sections[indexPath.section].files[indexPath.item])
        return item
    }
    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: .init("Day"), for: indexPath) as! LibraryDayHeader
        let day = sections[indexPath.section]; header.title = day.title; header.count = day.files.count; header.needsDisplay = true
        return header
    }
    private func configure(_ item: LibraryItem, file: RecentCaptureFile) {
        let view = item.cell
        view.file = file; view.status = statuses[file.url]; view.selected = selection.urls.contains(file.url)
        view.deleteArmed = deleteConfirmation.isArmed && view.selected
        view.multipleSelection = selection.urls.count > 1
        view.onSelect = { [weak self] event, mouseUp in
            guard let self else { return }
            self.cancelDelete(.click)
            // 選択済みの項目を押した時点では複数選択を保ち、ドラッグせず離したら1件へ戻す。
            let modifiers = event.modifierFlags.intersection([.command, .shift])
            if mouseUp {
                if modifiers.isEmpty && event.clickCount == 1 { self.select(file.url) }
            } else if event.clickCount < 2 || self.selection.urls.count <= 1 {
                if modifiers.contains(.shift) { self.select(file.url, mode: .range) }
                else if modifiers.contains(.command) { self.select(file.url, mode: .toggle) }
                else if !self.selection.urls.contains(file.url) { self.select(file.url) }
            }
        }
        view.onEdit = { [weak self] in self?.editSelected() }
        view.dragItems = { [weak self] in self?.dragItems(from: file.url) ?? [] }
        view.canMove = { [weak self] urls in
            guard let self else { return false }
            return urls.allSatisfy { self.thumbnails.canRemoveFromLibrary($0) }
        }
        view.onDragEnd = { [weak self] urls, operation in self?.dragEnded(urls, operation: operation) }
        if let thumbnail = cache.object(forKey: file.cacheKey as NSString) { view.thumbnail = thumbnail }
        else {
            view.thumbnail = nil
            if loading[file.cacheKey] == nil && !pending.contains(where: { $0.cacheKey == file.cacheKey }) { pending.append(file) }
            // itemForRepresentedObjectAt中はまだ可視配列へ入っていない。配送後にキューを確認する。
            Task { [weak self] in self?.pumpThumbnails() }
        }
        view.needsDisplay = true
    }
    func dragURLs(from url: URL) -> [URL] {
        guard !isTrashing else { return [] }
        selection.prepareDrag(from: url); selectionChanged(scrollToSelection: false)
        let urls = selectedURLs
        guard !urls.contains(where: { thumbnails.card(for: $0)?.finalizing == true || statuses[$0] == "書き出し中…" }) else {
            message = "! 書き出し中の項目を含むためドラッグできません"; updateFooter(); return []
        }
        return urls
    }
    private func dragItems(from url: URL) -> [(URL, NSImage?)] {
        let byURL = Dictionary(uniqueKeysWithValues: files.map { ($0.url, $0) })
        return dragURLs(from: url).map { url in
            let file = byURL[url]
            return (url, file.flatMap { cache.object(forKey: $0.cacheKey as NSString)?.image })
        }
    }
    func dragEnded(_ urls: [URL], operation: NSDragOperation) {
        guard operation.contains(.move) else { return }
        let missing = Set(urls.filter { !FileManager.default.fileExists(atPath: $0.path) })
        thumbnails.forgetLibraryFiles(missing)
        selection.didRemove(missing, orderedURLs: orderedURLs)
        refresh()
    }
    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        Task { [weak self] in self?.pumpThumbnails() }
    }
    private func pumpThumbnails() {
        guard window?.isVisible == true else { pending.removeAll(); return }
        let visible = Set(collection.visibleItems().compactMap { ($0 as? LibraryItem)?.cell.file?.cacheKey })
        pending.removeAll { !visible.contains($0.cacheKey) }
        while loading.count < 4, !pending.isEmpty {
            let file = pending.removeFirst(), key = file.cacheKey
            loading[key] = Task { [weak self] in
                guard let self else { return }
                let thumbnail: LibraryThumbnail
                do { thumbnail = LibraryThumbnail(capture: try await loadThumbnail(file)) }
                catch { thumbnail = LibraryThumbnail(failure: "! 読み取れません") }
                loading[key] = nil
                if !Task.isCancelled {
                    cache.setObject(thumbnail, forKey: key as NSString, cost: thumbnail.cost)
                    for case let item as LibraryItem in collection.visibleItems() where item.cell.file?.cacheKey == key {
                        item.cell.thumbnail = thumbnail; item.cell.needsDisplay = true
                    }
                }
                pumpThumbnails()
            }
        }
    }
    private func updateVisibleItems() {
        for case let item as LibraryItem in collection.visibleItems() {
            guard let file = item.cell.file else { continue }
            item.cell.status = statuses[file.url]; item.cell.needsDisplay = true
        }
    }

    // MARK: 標準のQuick Look。パネルの制御はresponder chainから受け取る。
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { window?.isVisible == true }
    }
    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { previewPanel = panel; panel.dataSource = self; panel.delegate = self }
    }
    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil; panel.delegate = nil; previewPanel = nil }
    }
    private func togglePreview() {
        guard requireSingleSelection() else { return }
        if previewPanel?.isVisible == true { closePreview(); return }
        guard singleSelectedURL != nil, let panel = QLPreviewPanel.shared() else { return }
        panel.makeKeyAndOrderFront(nil)
    }
    private func closePreview() { previewPanel?.orderOut(nil) }
    private func closeFromKeyboard() {
        switch CaptureLibrary.closeTarget(previewVisible: previewPanel?.isVisible == true) {
        case .preview:
            closePreview()
            window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(collection)
        case .library: window?.close()
        }
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { singleSelectedURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        singleSelectedURL.map { $0 as NSURL }
    }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool { event.type == .keyDown && handleKey(event) }
}

private extension RecentCaptureFile {
    var cacheKey: String { "\(url.path)\u{0}\(date.timeIntervalSince1970)\u{0}\(byteCount)" }
}

@MainActor
private final class LibraryThumbnail: NSObject {
    let capture: LoadedCapture?
    let image: NSImage?
    let failure: String?
    var cost: Int { capture.map { $0.image.bytesPerRow * $0.image.height } ?? 1 }
    init(capture: LoadedCapture) {
        self.capture = capture; image = NSImage(cgImage: capture.image, size: CGSize(width: capture.image.width, height: capture.image.height))
        failure = nil
    }
    init(failure: String) { self.failure = failure; capture = nil; image = nil }
}

@MainActor
private final class LibraryCollectionView: NSCollectionView {
    var handleKey: ((NSEvent) -> Bool)?
    var onBackgroundClick: (() -> Void)?
    override func keyDown(with event: NSEvent) { if handleKey?(event) != true { super.keyDown(with: event) } }
    override func mouseDown(with event: NSEvent) { onBackgroundClick?() }
}

@MainActor
private final class LibraryItem: NSCollectionViewItem {
    var cell: LibraryCell { view as! LibraryCell }
    override func loadView() { view = LibraryCell() }
    override var isSelected: Bool { didSet { cell.selected = isSelected; cell.needsDisplay = true } }
    override func prepareForReuse() {
        super.prepareForReuse(); cell.file = nil; cell.thumbnail = nil; cell.onSelect = nil; cell.onEdit = nil
        cell.dragItems = nil; cell.canMove = nil; cell.onDragEnd = nil; cell.deleteArmed = false
    }
}

@MainActor
private final class LibraryCell: NSView, NSDraggingSource {
    var file: RecentCaptureFile?
    var thumbnail: LibraryThumbnail?
    var selected = false
    var deleteArmed = false
    var status: String?
    var multipleSelection = false
    private var doubleClickBlocked = false
    var onSelect: ((NSEvent, Bool) -> Void)?
    var onEdit: (() -> Void)?
    var dragItems: (() -> [(URL, NSImage?)])?
    var canMove: (([URL]) -> Bool)?
    var onDragEnd: (([URL], NSDragOperation) -> Void)?
    private var draggedURLs: [URL] = []
    private var downEvent: NSEvent?
    private var dragged = false
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if let collection = superview as? NSCollectionView { window?.makeFirstResponder(collection) }
        if event.clickCount == 1 { doubleClickBlocked = multipleSelection }
        downEvent = event; dragged = false; onSelect?(event, false)
        if event.clickCount == 2 && !doubleClickBlocked { onEdit?() }
    }
    override func mouseUp(with event: NSEvent) {
        if !dragged, let downEvent { onSelect?(downEvent, true) }
        downEvent = nil
    }
    override func mouseDragged(with event: NSEvent) {
        guard !dragged, let downEvent else { return }
        let a = convert(downEvent.locationInWindow, from: nil), b = convert(event.locationInWindow, from: nil)
        guard hypot(a.x - b.x, a.y - b.y) > 4 else { return }
        dragged = true
        let captures = dragItems?() ?? []
        guard !captures.isEmpty else { return }
        draggedURLs = captures.map(\.0)
        let items = captures.enumerated().map { offset, capture in
            let item = NSDraggingItem(pasteboardWriter: capture.0 as NSURL)
            item.setDraggingFrame(CGRect(x: b.x - 100 + CGFloat(offset % 6) * 8,
                y: b.y - 60 + CGFloat(offset % 6) * 8, width: 200, height: 120), contents: capture.1 ?? thumbnail?.image)
            return item
        }
        beginDraggingSession(with: items, event: downEvent, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        switch CaptureLibraryDragOperation.allowed(commandPressed: NSEvent.modifierFlags.contains(.command)) {
        case .copy: return .copy
        case .move: return canMove?(draggedURLs) == true ? .move : []
        }
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragEnd?(draggedURLs, operation); draggedURLs = []; downEvent = nil
    }
    override func draw(_ dirtyRect: NSRect) {
        let preview = CGRect(x: 6, y: 6, width: max(1, bounds.width - 12), height: max(1, bounds.width - 12) * 10 / 16)
        UIDrawing.fill(preview, color: .black, radius: 6)
        if let image = thumbnail?.image {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: preview, xRadius: 6, yRadius: 6).addClip()
            let scale = min(preview.width / image.size.width, preview.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: preview.midX - size.width / 2, y: preview.midY - size.height / 2, width: size.width, height: size.height),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            UIDrawing.text(thumbnail?.failure ?? "読み込み中…", in: CGRect(x: preview.minX + 8, y: preview.midY - 8, width: preview.width - 16, height: 20),
                size: 12, color: thumbnail?.failure == nil ? UITheme.key : UITheme.red, centered: true)
        }
        if selected {
            let path = NSBezierPath(roundedRect: preview.insetBy(dx: -4, dy: -4), xRadius: 10, yRadius: 10)
            (deleteArmed ? UITheme.red : UITheme.indigo).setStroke(); path.lineWidth = 2.5; path.stroke()
        }
        if let duration = thumbnail?.capture?.artifact.duration {
            let text = CaptureLibrary.videoBadge(duration)
            let width = ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium)]).width) + 14
            let badge = CGRect(x: preview.maxX - width - 6, y: preview.maxY - 24, width: width, height: 18)
            UIDrawing.fill(badge, color: UITheme.ink.withAlphaComponent(0.85), radius: 4)
            UIDrawing.text(text, in: badge.insetBy(dx: 6, dy: 2), size: 10.5, color: .white)
        }
        if let status {
            let badge = CGRect(x: preview.minX + 6, y: preview.minY + 6, width: preview.width - 12, height: 22)
            UIDrawing.fill(badge, color: UITheme.ink.withAlphaComponent(0.9), radius: 4)
            UIDrawing.text(status, in: badge.insetBy(dx: 6, dy: 3), size: 11.5, color: status.hasPrefix("!") ? UITheme.red : UITheme.text)
        }
        if let file {
            let artifact = thumbnail?.capture?.artifact
            if let artifact {
                let parts = CaptureLibrary.metadata(file: file, width: artifact.width, height: artifact.height, bytes: artifact.byteCount)
                    .components(separatedBy: "  ")
                let time = parts[0]
                let timeWidth = ceil((time as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold)]).width)
                UIDrawing.text(time, in: CGRect(x: preview.minX + 2, y: preview.maxY + 8, width: timeWidth + 1, height: 18),
                    size: 12.5, color: selected ? .white : UITheme.text, weight: .semibold)
                UIDrawing.text(parts.dropFirst().joined(separator: "  "),
                    in: CGRect(x: preview.minX + timeWidth + 10, y: preview.maxY + 8, width: preview.width - timeWidth - 12, height: 18),
                    size: 12, color: UITheme.muted)
            } else {
                UIDrawing.text(file.url.lastPathComponent,
                    in: CGRect(x: preview.minX + 2, y: preview.maxY + 8, width: preview.width - 4, height: 18), size: 12, color: UITheme.muted)
            }
        }
    }
}

@MainActor
private final class LibraryDayHeader: NSView {
    var title = ""
    var count = 0
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let width = ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold)]).width)
        UIDrawing.text(title, in: CGRect(x: 24, y: 18, width: width + 1, height: 20), size: 14, weight: .semibold)
        UIDrawing.text("\(count)件", in: CGRect(x: width + 32, y: 20, width: 100, height: 18), size: 12, color: UITheme.key)
    }
}

@MainActor
private final class LibraryFooter: NSView {
    var filename = ""
    var status: String?
    var multiple = false
    var deleteArmed = false
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        UITheme.ink.setFill(); bounds.fill()
        NSColor.white.withAlphaComponent(0.07).setFill(); CGRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        let closeHint = (deleteArmed ? "Esc" : "Q Esc", deleteArmed ? "確認解除" : "閉じる")
        var hints = multiple
            ? [("⇧←↓↑→", "範囲"), ("⌘A", "全選択"), ("X", "ゴミ箱"), ("⌘C", "コピー"), closeHint]
            : [("←↓↑→ HJKL", "移動"), ("⏎", "編集"), ("S", "保存"), ("O", "Finder"), ("X", "ゴミ箱"), ("⌘C", "コピー"), ("Space", "プレビュー"), closeHint]
        func measure(_ hints: [(String, String)]) -> [(CGFloat, CGFloat)] {
            hints.map { key, label in
                (max(17, ceil((key as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium)]).width) + 8),
                 ceil((label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width))
            }
        }
        func width(_ sizes: [(CGFloat, CGFloat)]) -> CGFloat { sizes.reduce(CGFloat(0)) { $0 + $1.0 + $1.1 + 19 } - 14 }
        let label = multiple && status != nil ? filename + "・" + (status ?? "") : status ?? filename
        let labelWidth = ceil((label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium)]).width)
        let reserved = status == nil ? CGFloat(180) : min(bounds.width - 120, max(300, labelWidth + 48))
        var sizes = measure(hints), hintWidth = width(sizes)
        // ファイル名に132ptを残す。閉じる手引きは最後まで落とさず、他はこの順で省く。
        for key in ["←↓↑→ HJKL", "⇧←↓↑→", "⌘A", "O", "S", "Space", "⏎", "⌘C", "X"] where hintWidth > bounds.width - reserved {
            hints.removeAll { $0.0 == key }; sizes = measure(hints); hintWidth = width(sizes)
        }
        UIDrawing.text(label, in: CGRect(x: 16, y: 12, width: max(60, bounds.width - hintWidth - 48), height: 18), size: 11.5,
            color: status?.contains("!") == true ? UITheme.red : UITheme.key)
        var x = bounds.width - hintWidth - 16
        for ((key, label), (keyWidth, labelWidth)) in zip(hints, sizes) {
            UIDrawing.key(key, in: CGRect(x: x, y: 12, width: keyWidth, height: 17))
            UIDrawing.text(label, in: CGRect(x: x + keyWidth + 5, y: 12, width: labelWidth + 1, height: 18), size: 12, color: UITheme.muted)
            x += keyWidth + labelWidth + 19
        }
    }
}

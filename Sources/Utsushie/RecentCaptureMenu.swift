import AppKit
import UtsushieCore

@MainActor
final class RecentCaptureMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu(title: "最近の撮影")
    private let directory: () -> URL
    private let onFiles: ([RecentCaptureFile]) -> Void
    private let onSelect: (URL) -> Void
    private var cached: [URL: (Date, LoadedCapture)] = [:]
    private var loading: Task<Void, Never>?
    private var isOpen = false
    private var refreshPending = false
    init(directory: @escaping () -> URL, onFiles: @escaping ([RecentCaptureFile]) -> Void,
         onSelect: @escaping (URL) -> Void) {
        self.directory = directory; self.onFiles = onFiles; self.onSelect = onSelect
        super.init()
        menu.delegate = self; menu.autoenablesItems = false
    }
    func refresh() {
        // トラッキング中は行を追加・削除しない。既存行の読み込み結果だけ更新する。
        guard !isOpen else { refreshPending = true; return }
        menuNeedsUpdate(menu)
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        loading?.cancel(); menu.removeAllItems()
        let files: [RecentCaptureFile]
        do { files = try RecentCaptureStore.files(in: directory()) }
        catch {
            let item = NSMenuItem(title: "最近の撮影を読めませんでした", action: nil, keyEquivalent: "")
            item.isEnabled = false; menu.addItem(item); return
        }
        onFiles(files)
        let urls = Set(files.map(\.url)); cached = cached.filter { urls.contains($0.key) }
        if files.isEmpty {
            let item = NSMenuItem(title: "撮影はありません", action: nil, keyEquivalent: "")
            item.isEnabled = false; menu.addItem(item); return
        }
        let rows = files.map { file in
            let item = NSMenuItem(title: "読み込み中…", action: #selector(select(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = file.url; item.toolTip = file.url.lastPathComponent
            item.isEnabled = false; menu.addItem(item)
            if let (date, capture) = cached[file.url], date == file.date { configure(item, file: file, capture: capture) }
            return item
        }
        loading = Task { [weak self] in
            guard let self else { return }
            for (file, item) in zip(files, rows) where !item.isEnabled {
                guard !Task.isCancelled else { return }
                do {
                    let capture = try await RecentCaptureStore.load(file, maximumPixelSize: 64)
                    guard !Task.isCancelled else { return }
                    cached[file.url] = (file.date, capture); configure(item, file: file, capture: capture)
                } catch {
                    guard !Task.isCancelled else { return }
                    item.title = "読み取れません: \(file.url.lastPathComponent)"
                }
            }
        }
    }
    private func configure(_ item: NSMenuItem, file: RecentCaptureFile, capture: LoadedCapture) {
        let artifact = capture.artifact
        item.title = RecentCaptures.title(file: file, width: artifact.width, height: artifact.height, duration: artifact.duration)
        let size = CGSize(width: capture.image.width, height: capture.image.height)
        let scale = min(32 / size.width, 20 / size.height)
        item.image = NSImage(cgImage: capture.image, size: CGSize(width: size.width * scale, height: size.height * scale))
        item.isEnabled = true
    }
    @objc private func select(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { onSelect(url) }
    }
    func menuWillOpen(_ menu: NSMenu) { isOpen = true }
    func menuDidClose(_ menu: NSMenu) {
        isOpen = false
        if refreshPending {
            refreshPending = false
            // AppKitの開閉通知中には行を変えず、通知から戻ってから更新する。
            Task { [weak self] in self?.refresh() }
        }
    }
}

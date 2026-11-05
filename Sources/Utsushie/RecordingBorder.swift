import AppKit
import UtsushieCore

/// 録画中に範囲選択の暗幕・鉤と経過時間のバッジを引き継ぐ。入力を透過し、撮影用UIとして録画から除外する。
@MainActor
final class RecordingBorder: NSObject {
    struct Screen: Equatable {
        let id: UInt32
        let frame: CGRect
        let visibleFrame: CGRect
    }
    private struct Entry {
        let id: UInt32
        let panel: RecordingBorderPanel
        let view: RecordingCurtainView
    }
    private var entries: [Entry] = []
    private var rect = CGRect.zero
    /// 範囲の左上を、範囲と最も広く重なる画面の左上から測った位置。画面の並びや高さが変わっても録画の範囲へ付いていく。
    /// 理由: 録画はディスプレイの左上原点の座標で範囲を固定しているため。
    private var anchor: (id: UInt32, offset: CGPoint)?
    private var elapsed: String?
    private var revealed = false
    var panels: [RecordingBorderPanel] { entries.map(\.panel) }

    /// 除外する窓番号を録画の準備前に確保するため先に出す。`reveal`までは何も描かない。
    func show(rect: CGRect) {
        close()
        self.rect = rect
        sync(screens: Self.currentScreens())
        updateAnchor()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }
    /// 選択画面を閉じる直前に呼ぶ。暗幕を同期で描き、選択画面の暗幕と二重に重なる時間を作らない。
    func reveal() {
        revealed = true
        for entry in entries { entry.view.revealed = true; entry.view.display() }
    }
    /// 移動するウィンドウの枠へくり抜きを付いていかせる。
    func move(to rect: CGRect) {
        guard rect != self.rect else { return }
        self.rect = rect
        for entry in entries { entry.view.selection = rect; entry.view.needsDisplay = true }
        updateAnchor()
        updateBadgeScreen()
    }
    /// 録画が始まったら経過時間を出す。nilなら出さない。
    func setElapsed(_ text: String?) {
        guard text != elapsed else { return }
        elapsed = text
        for entry in entries where entry.view.showsBadge { entry.view.setBadge(text) }
    }
    func close() {
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        entries.forEach { $0.panel.orderOut(nil) }; entries.removeAll()
        elapsed = nil; revealed = false; anchor = nil
    }
    /// 録画中に画面が増減しても全ディスプレイを暗く保つ。残る画面のパネルは作り直さない。
    /// 理由: 録画のフィルターは開始時の窓番号で暗幕を除外しているため。増えた画面は録画中のディスプレイではない。
    func sync(screens: [Screen]) {
        if let anchor, let screen = screens.first(where: { $0.id == anchor.id }) {
            let moved = CGRect(x: screen.frame.minX + anchor.offset.x, y: screen.frame.maxY - anchor.offset.y - rect.height,
                               width: rect.width, height: rect.height)
            if moved != rect {
                rect = moved
                for entry in entries { entry.view.selection = rect; entry.view.needsDisplay = true }
            }
        }
        let ids = Set(screens.map(\.id))
        for entry in entries where !ids.contains(entry.id) { entry.panel.orderOut(nil) }
        entries.removeAll { !ids.contains($0.id) }
        for screen in screens {
            if let entry = entries.first(where: { $0.id == screen.id }) {
                guard entry.view.screenFrame != screen.frame || entry.view.visibleFrame != local(screen.visibleFrame, in: screen.frame) else { continue }
                entry.panel.setFrame(screen.frame, display: false)
                entry.view.frame = CGRect(origin: .zero, size: screen.frame.size)
                configure(entry.view, screen: screen)
                entry.view.needsDisplay = true
            } else {
                entries.append(makeEntry(screen))
            }
        }
        updateBadgeScreen()
    }
    @objc private func screensChanged() { sync(screens: Self.currentScreens()) }
    private static func currentScreens() -> [Screen] {
        NSScreen.screens.map { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return Screen(id: id, frame: screen.frame, visibleFrame: screen.visibleFrame)
        }
    }
    private func makeEntry(_ screen: Screen) -> Entry {
        let panel = RecordingBorderPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.setFrame(screen.frame, display: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none
        panel.sharingType = .none
        let view = RecordingCurtainView(frame: CGRect(origin: .zero, size: screen.frame.size))
        configure(view, screen: screen)
        view.revealed = revealed
        panel.contentView = view
        panel.orderFrontRegardless()
        return Entry(id: screen.id, panel: panel, view: view)
    }
    private func configure(_ view: RecordingCurtainView, screen: Screen) {
        view.screenFrame = screen.frame
        view.visibleFrame = local(screen.visibleFrame, in: screen.frame)
        view.selection = rect
    }
    private func local(_ rect: CGRect, in frame: CGRect) -> CGRect { rect.offsetBy(dx: -frame.minX, dy: -frame.minY) }
    private func updateAnchor() {
        guard let index = RecordingPresentation.badgeScreen(selection: rect, screens: entries.map(\.view.screenFrame)) else { anchor = nil; return }
        let frame = entries[index].view.screenFrame
        anchor = (entries[index].id, CGPoint(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY))
    }
    private func updateBadgeScreen() {
        let index = RecordingPresentation.badgeScreen(selection: rect, screens: entries.map(\.view.screenFrame))
        for (offset, entry) in entries.enumerated() {
            entry.view.setBadge(offset == index ? elapsed : nil, shows: offset == index)
        }
    }
}

@MainActor
final class RecordingBorderPanel: NSPanel, CaptureExcludedWindow {}

@MainActor
final class RecordingCurtainView: NSView {
    var screenFrame = CGRect.zero
    var visibleFrame = CGRect.zero
    var selection = CGRect.zero
    var revealed = false
    var showsBadge = false
    private(set) var badgeText: String?

    /// 表示先の切り替えも、古いバッジの矩形を測ってから変え、前後の両方を描き直す。
    func setBadge(_ text: String?, shows: Bool? = nil) {
        let shows = shows ?? showsBadge
        guard text != badgeText || shows != showsBadge else { return }
        if let old = badgeFrame() { setNeedsDisplay(old.insetBy(dx: -2, dy: -2)) }
        badgeText = text; showsBadge = shows
        if let new = badgeFrame() { setNeedsDisplay(new.insetBy(dx: -2, dy: -2)) }
    }
    private var local: CGRect { selection.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY) }
    func badgeFrame() -> CGRect? {
        guard showsBadge, let badgeText else { return nil }
        let size = CGSize(width: UIDrawing.recordingBadgeWidth(badgeText), height: 22)
        return RecordingPresentation.badge(selection: local, visible: visibleFrame, size: size)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard revealed else { return }
        let area = local
        UIDrawing.curtain(bounds, selection: area)
        if area.intersects(bounds.insetBy(dx: -10, dy: -10)) {
            UIDrawing.selection(area, video: true, inside: RecordingPresentation.cornersInside(selection: area, screen: bounds))
        }
        if let frame = badgeFrame(), let badgeText { UIDrawing.recordingBadge(badgeText, in: frame) }
    }
}

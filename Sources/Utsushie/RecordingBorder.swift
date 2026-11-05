import AppKit
import UtsushieCore

/// 録画中に範囲選択の暗幕・鉤と経過時間のバッジを引き継ぐ。入力を透過し、撮影用UIとして録画から除外する。
@MainActor
final class RecordingBorder {
    private var panels: [NSPanel] = []
    private var views: [RecordingCurtainView] = []
    private var rect = CGRect.zero
    private var elapsed: String?

    /// 除外する窓番号を録画の準備前に確保するため先に出す。`reveal`までは何も描かない。
    func show(rect: CGRect) {
        close()
        self.rect = rect
        for screen in NSScreen.screens {
            let panel = RecordingBorderPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.setFrame(screen.frame, display: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.animationBehavior = .none
            panel.sharingType = .none
            let view = RecordingCurtainView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.screenFrame = screen.frame
            view.visibleFrame = screen.visibleFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            view.selection = rect
            panel.contentView = view
            panel.orderFrontRegardless(); panels.append(panel); views.append(view)
        }
        updateBadgeScreen()
    }
    /// 選択画面を閉じる直前に呼ぶ。暗幕を同期で描き、選択画面の暗幕と二重に重なる時間を作らない。
    func reveal() {
        for view in views { view.revealed = true; view.display() }
    }
    /// 移動するウィンドウの枠へくり抜きを付いていかせる。
    func move(to rect: CGRect) {
        guard rect != self.rect else { return }
        self.rect = rect
        for view in views { view.selection = rect; view.needsDisplay = true }
        updateBadgeScreen()
    }
    /// 録画が始まったら経過時間を出す。nilなら出さない。
    func setElapsed(_ text: String?) {
        guard text != elapsed else { return }
        elapsed = text
        for view in views where view.showsBadge { view.setBadge(text) }
    }
    func close() {
        panels.forEach { $0.orderOut(nil) }; panels.removeAll(); views.removeAll(); elapsed = nil
    }
    private func updateBadgeScreen() {
        let index = RecordingPresentation.badgeScreen(selection: rect, screens: views.map(\.screenFrame))
        for (offset, view) in views.enumerated() {
            let shows = offset == index
            guard shows != view.showsBadge else { continue }
            view.showsBadge = shows
            view.setBadge(shows ? elapsed : nil)
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

    func setBadge(_ text: String?) {
        guard text != badgeText else { return }
        if let old = badgeFrame() { setNeedsDisplay(old.insetBy(dx: -2, dy: -2)) }
        badgeText = text
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

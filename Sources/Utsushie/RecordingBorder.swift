import AppKit

@MainActor
final class RecordingBorder {
    private var panels: [NSPanel] = []
    func show(rect: CGRect) {
        close()
        for screen in NSScreen.screens where screen.frame.intersects(rect.insetBy(dx: -5, dy: -5)) {
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.setFrame(screen.frame, display: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.sharingType = .none
            let view = BorderView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.rect = rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            panel.contentView = view
            panel.orderFrontRegardless(); panels.append(panel)
        }
    }
    func close() { panels.forEach { $0.orderOut(nil) }; panels.removeAll() }
}

@MainActor
private final class BorderView: NSView {
    var rect = CGRect.zero
    override func draw(_ dirtyRect: NSRect) {
        UIDrawing.recordingBorder(rect)
    }
}

import AppKit
import OSLog

/// アプリへ届いたmagnifyを観測する。イベントの配送やズーム処理には介入しない。
@MainActor
final class AnnotationNavigationDiagnostics {
    private var monitor: Any?
    private static let log = Logger(subsystem: "com.tadashi-aikawa.utsushie", category: "AnnotationNavigation")

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { event in
            MainActor.assumeIsolated { _ = Self.observeMagnify(event) }
            return event
        }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
    static func observeMagnify(_ event: NSEvent) -> NSEvent {
        let destination = event.window
        let windowType = destination.map { String(describing: type(of: $0)) } ?? "nil"
        let windowNumber = destination?.windowNumber ?? event.windowNumber
        let front = NSWorkspace.shared.frontmostApplication
        let frontBundle = front?.bundleIdentifier ?? "nil"
        let frontPID = front?.processIdentifier ?? -1
        log.debug("app magnify received: window=\(windowNumber) type=\(windowType, privacy: .public) active=\(NSApp.isActive) frontmost=\(frontBundle, privacy: .public) frontmostPID=\(frontPID)")
        return event
    }
    static func observeFocus(_ context: String, isActive: Bool, frontmostApplication: NSRunningApplication?) {
        let frontBundle = frontmostApplication?.bundleIdentifier ?? "nil"
        let frontPID = frontmostApplication?.processIdentifier ?? -1
        let ownPID = ProcessInfo.processInfo.processIdentifier
        log.debug("focus \(context, privacy: .public): active=\(isActive) frontmost=\(frontBundle, privacy: .public) frontmostPID=\(frontPID) ownPID=\(ownPID)")
    }
}

import AppKit
import UtsushieCore

@MainActor
enum ScreenGeometry {
    static var displays: [DisplayGeometry] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return DisplayGeometry(id: id.uint32Value, frame: screen.frame, scale: screen.backingScaleFactor)
        }
    }
    static var primaryHeight: Double { Double(NSScreen.screens.first?.frame.height ?? 0) }
    static func appKit(_ cgRect: CGRect) -> CGRect { CaptureGeometry.flip(cgRect, primaryHeight: primaryHeight) }
    static func cg(_ rect: CGRect) -> CGRect { CaptureGeometry.flip(rect, primaryHeight: primaryHeight) }
}

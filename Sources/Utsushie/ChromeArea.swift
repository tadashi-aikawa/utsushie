import AppKit
import ApplicationServices

@MainActor
enum ChromeArea {
    static func rect() throws -> CGRect {
        guard let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first else {
            throw CaptureError.unavailable("Google Chromeが起動していません")
        }
        guard AXIsProcessTrusted() else {
            throw CaptureError.unavailable("Chrome撮影にはアクセシビリティの許可が必要です。Escで閉じ、システム設定で許可してください")
        }
        let app = AXUIElementCreateApplication(chrome.processIdentifier)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
        }
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        // UTSUSHIE起動で前面アプリが変わってもChrome自身の最前面ウィンドウを対象にする。
        let main = windows.first { (attribute($0, kAXMainAttribute) as? Bool) == true } ?? windows.first
        guard let main else { throw CaptureError.unavailable("Chromeのウィンドウが見つかりません") }
        var queue = [main]
        var index = 0
        // AXツリーはページにより巨大になる。上限を設けメインスレッドを無制限に占有しない。
        while index < queue.count && index < 3000 {
            let element = queue[index]; index += 1
            if (attribute(element, kAXRoleAttribute) as? String) == "AXWebArea",
               let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
               let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() {
                var point = CGPoint.zero, dimensions = CGSize.zero
                if AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
                   dimensions.width > 0, dimensions.height > 0 {
                    return ScreenGeometry.appKit(CGRect(origin: point, size: dimensions)).integral
                }
            }
            if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children) }
        }
        throw CaptureError.unavailable("ChromeのWeb表示領域を取得できません。ページを表示して選び直してください")
    }
}

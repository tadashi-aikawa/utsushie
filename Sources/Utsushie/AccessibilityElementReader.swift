import ApplicationServices
import Foundation
import UtsushieCore

/// AX参照はこのactor内で完結させ、画面側へは値だけを渡す。
/// アプリへ属性を書かず、公開AXに現れる範囲だけを選ぶ試作。
actor AccessibilityElementReader {
    struct Query: Equatable, Sendable {
        let point: CGPoint
        let windowID: UInt32
        let processID: Int32
        let windowBounds: CGRect
        let visibleBounds: CGRect
        let occludingBounds: [CGRect]
        init(point: CGPoint, windowID: UInt32, processID: Int32, windowBounds: CGRect,
             visibleBounds: CGRect? = nil, occludingBounds: [CGRect] = []) {
            self.point = point; self.windowID = windowID; self.processID = processID
            self.windowBounds = windowBounds; self.visibleBounds = visibleBounds ?? windowBounds
            self.occludingBounds = occludingBounds
        }
        func hasSameContext(as other: Query) -> Bool {
            windowID == other.windowID && processID == other.processID && windowBounds == other.windowBounds &&
            visibleBounds == other.visibleBounds && occludingBounds == other.occludingBounds
        }
    }

    func selection(for query: Query) -> ElementSelection {
        guard !Task.isCancelled, AXIsProcessTrusted() else { return ElementSelection() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(300))
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            guard !Task.isCancelled, clock.now < deadline else { return nil }
            // timeoutは参照ごとに設定する。appへだけ設定しても子には引き継がれない。
            AXUIElementSetMessagingTimeout(element, 0.08)
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
        }
        func rect(_ element: AXUIElement) -> CGRect? {
            guard let p = attribute(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
                  let s = attribute(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero, size = CGSize.zero
            guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
                  AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
            return CGRect(origin: point, size: size)
        }
        let app = AXUIElementCreateApplication(query.processID)
        AXUIElementSetMessagingTimeout(app, 0.08)
        var hit: AXUIElement?
        // システム全体へ問い合わせると自分の撮影パネルが当たる。対象アプリの参照へ限定する。
        guard AXUIElementCopyElementAtPosition(app, Float(query.point.x), Float(query.point.y), &hit) == .success else {
            return ElementSelection()
        }
        var current = hit
        var visited: [AXUIElement] = []
        var nodes: [CaptureElementNode] = []
        var foundWebArea = false
        for _ in 0..<64 {
            guard !Task.isCancelled, clock.now < deadline, let element = current,
                  !visited.contains(where: { CFEqual($0, element) }) else { return ElementSelection() }
            visited.append(element)
            guard let role = attribute(element, kAXRoleAttribute) as? String else { return ElementSelection() }
            let bounds = rect(element)
            if role == kAXWindowRole {
                // 同じ位置の窓は、呼び出し側のCGWindowListとappのAXヒットの両方のz順で絞る。
                guard let bounds, ElementSelection.matches(bounds, query.windowBounds, tolerance: 1) else {
                    return ElementSelection()
                }
                return ElementSelection(nodes: nodes, point: query.point, visibleBounds: query.visibleBounds,
                                        occludingBounds: query.occludingBounds)
            }
            if !foundWebArea {
                nodes.append(CaptureElementNode(rect: bounds, label: Self.label(for: role),
                    clipsChildren: role == "AXWebArea" || role == kAXScrollAreaRole))
                foundWebArea = role == "AXWebArea"
            } else if role == "AXWebArea" || role == kAXScrollAreaRole {
                // iframeの外側のWebAreaも可視範囲を制限する。ブラウザの外枠は選択候補にはしない。
                nodes.append(CaptureElementNode(rect: bounds, label: "", clipsChildren: true, isCandidate: false))
            }
            guard let parent = attribute(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else {
                return ElementSelection()
            }
            current = (parent as! AXUIElement)
        }
        return ElementSelection()
    }

    private static func label(for role: String) -> String {
        switch role {
        case kAXButtonRole: "ボタン"
        case kAXStaticTextRole: "文字"
        case "AXLink": "リンク"
        case kAXImageRole: "画像"
        case kAXTextFieldRole, kAXTextAreaRole: "入力欄"
        case kAXScrollAreaRole: "スクロール領域"
        case "AXWebArea": "ページ"
        default: "要素"
        }
    }
}

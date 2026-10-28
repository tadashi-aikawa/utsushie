import ApplicationServices
import AppKit
import Foundation
import os
import UtsushieCore

/// AX参照は専用キューで完結させ、画面側へは値だけを渡す。
/// アプリへ属性を書かず、公開AXに現れる範囲だけを選ぶ試作。
@MainActor
final class AccessibilityElementReader {
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

    /// キューで読む1回の問い合わせ。待ち手の再開は、読み終わり・取り消し・停止の検知の最初の1回だけ。
    final class Request: Sendable {
        private struct State: Sendable {
            var continuation: CheckedContinuation<ElementSelection, Never>?
            var cancelled = false
            var finished = false
            var step = "queued"
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        var isCancelled: Bool { state.withLock { $0.cancelled } }
        var isFinished: Bool { state.withLock { $0.finished } }
        /// 戻らない呼び出しを見つけたとき、どのAX呼び出しで止まったかを記録する。
        var step: String { state.withLock { $0.step } }
        func enter(_ step: String) { state.withLock { $0.step = step } }
        fileprivate func attach(_ continuation: CheckedContinuation<ElementSelection, Never>) {
            let cancelled = state.withLock { state in
                if !state.cancelled { state.continuation = continuation }
                return state.cancelled
            }
            if cancelled { continuation.resume(returning: ElementSelection()) }
        }
        fileprivate func resume(_ selection: ElementSelection, finished: Bool = false, cancelled: Bool = false) {
            let continuation = state.withLock { state in
                if finished { state.finished = true }
                if cancelled { state.cancelled = true }
                defer { state.continuation = nil }
                return state.continuation
            }
            continuation?.resume(returning: selection)
        }
    }

    nonisolated private static let log = Logger(subsystem: "com.tadashi-aikawa.utsushie", category: "Element")
    private nonisolated static func makeQueue() -> DispatchQueue {
        DispatchQueue(label: "com.tadashi-aikawa.utsushie.element", qos: .userInitiated)
    }
    /// アプリ寿命で同じキューを使い続けると、戻らないAX呼び出しが1回あるだけで再起動まで要素を取れなくなる。
    /// 1回の読み取りは300msで打ち切るので、待ち行列を含めてもstallLimitを超えたらキューごと見捨てる。
    private var queue = AccessibilityElementReader.makeQueue()
    private let stallLimit: Duration
    private let read: @Sendable (Query, Request) -> ElementSelection

    init(stallLimit: Duration = .seconds(2),
         read: @escaping @Sendable (Query, Request) -> ElementSelection = AccessibilityElementReader.read) {
        self.stallLimit = stallLimit
        self.read = read
    }

    func selection(for query: Query) async -> ElementSelection {
        let queue = queue, read = read, request = Request()
        // 取り消された問い合わせも、キューが戻らなければ次の問い合わせを塞ぐ。待ち手とは別に見張る。
        let watchdog = Task { [weak self, stallLimit] in
            try? await Task.sleep(for: stallLimit)
            guard !request.isFinished else { return }
            self?.abandon(queue, query: query, step: request.step)
            // 見捨てたキューが後で動き出しても、この要求でAXを読み始めない。
            request.resume(ElementSelection(), cancelled: true)
        }
        let selection = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                request.attach(continuation)
                queue.async { request.resume(read(query, request), finished: true) }
            }
        } onCancel: {
            request.resume(ElementSelection(), cancelled: true)
        }
        if request.isFinished { watchdog.cancel() }
        return selection
    }

    private func abandon(_ stalled: DispatchQueue, query: Query, step: String) {
        guard stalled === queue else { return }
        queue = Self.makeQueue()
        let app = NSRunningApplication(processIdentifier: query.processID)?.bundleIdentifier ?? "unknown"
        Self.log.error("""
            element stalled: limit=\(String(describing: self.stallLimit), privacy: .public) \
            app=\(app, privacy: .public) pid=\(query.processID) step=\(step, privacy: .public)
            """)
    }

    nonisolated static func read(_ query: Query, _ request: Request) -> ElementSelection {
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start.advanced(by: .milliseconds(300))
        func finish(_ outcome: String, _ selection: ElementSelection = ElementSelection()) -> ElementSelection {
            log.debug("""
                element read: pid=\(query.processID) elapsed=\(start.duration(to: clock.now), privacy: .public) \
                outcome=\(outcome, privacy: .public) candidates=\(selection.candidates.count)
                """)
            return selection
        }
        guard !request.isCancelled else { return ElementSelection() }
        guard AXIsProcessTrusted() else {
            log.notice("element read: not trusted")
            return finish("notTrusted")
        }
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            guard !request.isCancelled, clock.now < deadline else { return nil }
            // timeoutは参照ごとに設定する。appへだけ設定しても子には引き継がれない。
            AXUIElementSetMessagingTimeout(element, 0.08)
            request.enter(name)
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
        request.enter("elementAtPosition")
        // システム全体へ問い合わせると自分の撮影パネルが当たる。対象アプリの参照へ限定する。
        let hitError = AXUIElementCopyElementAtPosition(app, Float(query.point.x), Float(query.point.y), &hit)
        guard hitError == .success else {
            // 権限を失った・AXが応答しないなどの再発時の手掛かりにする。ほかの失敗は対象外の場所でも起きる。
            if hitError != .noValue { log.notice("element hit failed: pid=\(query.processID) error=\(hitError.rawValue)") }
            return finish("hitError(\(hitError.rawValue))")
        }
        var current = hit
        var visited: [AXUIElement] = []
        var nodes: [CaptureElementNode] = []
        var foundWebArea = false
        for _ in 0..<64 {
            guard !request.isCancelled, clock.now < deadline, let element = current,
                  !visited.contains(where: { CFEqual($0, element) }) else { return finish("interrupted") }
            visited.append(element)
            guard let role = attribute(element, kAXRoleAttribute) as? String else { return finish("noRole") }
            let bounds = rect(element)
            if role == kAXWindowRole {
                // 同じ位置の窓は、呼び出し側のCGWindowListとappのAXヒットの両方のz順で絞る。
                guard let bounds, ElementSelection.matches(bounds, query.windowBounds, tolerance: 1) else {
                    return finish("windowMismatch")
                }
                return finish("found", ElementSelection(nodes: nodes, point: query.point, visibleBounds: query.visibleBounds,
                                                        occludingBounds: query.occludingBounds))
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
                return finish("noParent")
            }
            current = (parent as! AXUIElement)
        }
        return finish("tooDeep")
    }

    private nonisolated static func label(for role: String) -> String {
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

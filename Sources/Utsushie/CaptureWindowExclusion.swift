import AppKit
import ScreenCaptureKit
import UtsushieCore

/// 撮影操作そのもののウィンドウだけに付ける。新しい編集ウィンドウには付けない。
@MainActor
protocol CaptureExcludedWindow: AnyObject {}

@MainActor
enum CaptureWindowExclusion {
    static func windows() -> [NSWindow] {
        NSApp.windows.filter { $0 is any CaptureExcludedWindow }
    }

    static func policy(for windows: [NSWindow]) -> CaptureWindowPolicy {
        CaptureWindowPolicy(ownProcessID: ProcessInfo.processInfo.processIdentifier,
            excludedWindowIDs: Set(windows.compactMap { UInt32(exactly: $0.windowNumber) }.filter { $0 > 0 }))
    }

    static func excludedWindows(in content: SCShareableContent, policy: CaptureWindowPolicy) throws -> [SCWindow] {
        // ウィンドウ番号はWindowServer全体で一意。所有アプリ情報が無いウィンドウも番号だけで対応させる。
        let excluded = content.windows.filter { policy.excludes(windowID: $0.windowID) }
        guard policy.excludedWindowIDs.isSubset(of: Set(excluded.map(\.windowID))) else {
            // 列挙できなかった撮影用UIを黙って含めず、写り込みを防ぐ。
            throw CaptureError.unavailable("撮影用のウィンドウを撮影対象から外せませんでした")
        }
        return excluded
    }
}

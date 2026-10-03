import Foundation
import CoreGraphics

public enum VideoGeometry {
    public static func display(containing rect: CGRect, displays: [DisplayGeometry]) -> DisplayGeometry? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        return displays.first { $0.frame.contains(rect) }
    }
    public static func size(points: CGSize, scale: Double, downscale: Bool) -> (width: Int, height: Int) {
        let size = CaptureGeometry.outputSize(points: points, scale: scale, downscale: downscale)
        // H.264の4:2:0は偶数寸法が必要。選択範囲より大きくしないよう切り下げる。
        // 1ptの場合だけ最小の2pxとする。画像の寸法計算にはこの制約を持ち込まない。
        return (max(2, size.width / 2 * 2), max(2, size.height / 2 * 2))
    }
}

public enum RecordingPhase: Equatable, Sendable { case idle, starting, recording, finalizing }
public struct RecordingState: Sendable {
    public private(set) var phase: RecordingPhase = .idle
    public init() {}
    public mutating func begin() -> Bool {
        guard phase == .idle else { return false }
        phase = .starting; return true
    }
    public mutating func didStart() { if phase == .starting { phase = .recording } }
    public mutating func stop() -> Bool {
        guard phase == .recording else { return false }
        phase = .finalizing; return true
    }
    public mutating func reset() { phase = .idle }
}

public struct VideoEnd: Equatable, Sendable {
    public var duration: Double
    public var tailPresentation: Double?
}
public struct VideoTimeline: Sendable {
    private var firstSource: Double?
    private var firstHost: Double?
    public private(set) var lastPresentation: Double?
    public init() {}
    public mutating func accept(sourceTime: Double, hostTime: Double) -> Double? {
        guard sourceTime.isFinite, hostTime.isFinite else { return nil }
        let relative = sourceTime - (firstSource ?? sourceTime)
        if let lastPresentation, relative <= lastPresentation { return nil }
        if firstSource == nil { firstSource = sourceTime; firstHost = hostTime }
        lastPresentation = relative
        return relative
    }
    /// 最後の実フレームから停止までを保持。SCStreamは静止中にフレームを送らないため、
    /// 最終フレームの複製とendSessionの時刻を明示して実時間をMP4へ残す。
    /// メディア時刻とホスト時計のepochを同一と仮定せず、最初の受信時刻から差分を取る。
    public func end(hostTime: Double, fps: Int) -> VideoEnd? {
        guard let firstHost, let lastPresentation, hostTime.isFinite else { return nil }
        let frame = 1 / Double(fps)
        let duration = max(frame, max(hostTime - firstHost, lastPresentation + frame))
        let tail = duration - frame
        return VideoEnd(duration: duration, tailPresentation: tail > lastPresentation + 0.000_001 ? tail : nil)
    }
}

public enum MediaFormatting {
    public static func elapsed(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
    public static func videoInfo(width: Int, height: Int, duration: Double, bytes: Int) -> String {
        String(format: "MP4  %d×%d  %.1fs  %.1fMB", width, height, duration, Double(bytes) / 1_048_576)
    }
}

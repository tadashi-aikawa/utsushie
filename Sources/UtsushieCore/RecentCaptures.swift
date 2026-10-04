import Foundation

public enum RecentCaptureKind: String, Sendable { case webP = "WebP", mp4 = "MP4" }

public struct RecentCaptureFile: Equatable, Sendable {
    public let url: URL
    public let date: Date
    public let isRegularFile: Bool
    public let isHidden: Bool
    public init(url: URL, date: Date, isRegularFile: Bool = true, isHidden: Bool = false) {
        self.url = url; self.date = date; self.isRegularFile = isRegularFile; self.isHidden = isHidden
    }
    public var kind: RecentCaptureKind? {
        switch url.pathExtension.lowercased() {
        case "webp": .webP
        case "mp4": .mp4
        default: nil
        }
    }
}

public enum RecentCaptures {
    public static let limit = 10
    public static func newest(_ files: [RecentCaptureFile]) -> [RecentCaptureFile] {
        Array(files.filter {
            $0.isRegularFile && !$0.isHidden && !$0.url.lastPathComponent.hasPrefix(".") && $0.kind != nil
                && !$0.url.lastPathComponent.lowercased().hasSuffix(".recording.mp4")
        }.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.url.path > $1.url.path
        }.prefix(limit))
    }
    public static func title(file: RecentCaptureFile, width: Int, height: Int, duration: Double? = nil,
                             timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        let detail = file.kind == .mp4 ? MediaFormatting.elapsed(duration.flatMap { $0.isFinite ? $0 : nil } ?? 0)
            : "\(width)×\(height)"
        return "\(formatter.string(from: file.date)) \(file.kind?.rawValue ?? "") \(detail)"
    }
}

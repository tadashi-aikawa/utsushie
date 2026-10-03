import Foundation

public enum CaptureFileNaming {
    public static func name(date: Date, sequence: Int = 0, extension suffix: String = "webp", timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let serial = sequence == 0 ? "" : "-\(sequence)"
        return "utsushie-\(formatter.string(from: date))\(serial).\(suffix)"
    }
}
public struct LastArea: Codable, Equatable, Sendable {
    public var rect: CGRect
    public init(rect: CGRect) { self.rect = rect }
    public static func load(from url: URL) -> LastArea? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

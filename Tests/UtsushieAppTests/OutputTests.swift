import AppKit
import ImageIO
import Testing
import UtsushieCore
@testable import Utsushie

private func fixture() throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: 17, height: 11, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 17, height: 11))
    return try #require(context.makeImage())
}
@Test(arguments: [false, true])
func realWebPEncoding(_ lossless: Bool) throws {
    let data = try WebPEncoder.encode(fixture(), quality: 80, lossless: lossless)
    #expect(String(data: data.prefix(4), encoding: .ascii) == "RIFF")
    #expect(String(data: data[8..<12], encoding: .ascii) == "WEBP")
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(decoded.width == 17 && decoded.height == 11)
}
@Test func fileCollisionPreservesPreviousBytes() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let date = Date(timeIntervalSince1970: 0)
    let first = try ArtifactStore.save(data: Data([1]), kind: .webP, directory: dir, date: date).url
    let second = try ArtifactStore.save(data: Data([2]), kind: .webP, directory: dir, date: date).url
    #expect(first != second)
    #expect(second.lastPathComponent.hasSuffix("-1.webp"))
    #expect(try Data(contentsOf: first) == Data([1]))
    #expect(try Data(contentsOf: second) == Data([2]))
}
@Test func customFileNamePatternSavesImagesAndVideosWithSerialOnCollision() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let date = Date(timeIntervalSince1970: 0), pattern = "{yyyyMMdd}-utsushie"
    let day = CaptureFileNaming.name(date: date, extension: "", pattern: pattern).dropLast()
    let first = try ArtifactStore.save(data: Data([1]), kind: .webP, directory: dir, date: date, pattern: pattern)
    let second = try ArtifactStore.save(data: Data([2]), kind: .webP, directory: dir, date: date, pattern: pattern)
    #expect(first.url.lastPathComponent == "\(day).webp" && second.url.lastPathComponent == "\(day)-1.webp")
    #expect(!first.usedDefaultName && !second.usedDefaultName)
    #expect(try Data(contentsOf: first.url) == Data([1]) && Data(contentsOf: second.url) == Data([2]))
    let recording = dir.appendingPathComponent(".pending.recording.mp4")
    try Data([3]).write(to: recording)
    let video = try ArtifactStore.publishVideo(from: recording, date: date, pattern: pattern)
    #expect(video.url.lastPathComponent == "\(day).mp4" && !video.usedDefaultName)
}
@Test func unusableExpandedFileNameFallsBackToDefaultAndKeepsVideo() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
    let date = Date(timeIntervalSince1970: 1_790_763_343) // 2026-09-30T19:15:43+09:00
    // タイムゾーン名の`/`と、長い月名で255バイトを超える名前は、保存時に既定の名前へ戻す。
    for pattern in ["shot-{VV}", String(repeating: "{MMMM}", count: 30)] {
        let image = try ArtifactStore.save(data: Data([1]), kind: .webP, directory: dir, date: date, pattern: pattern, timeZone: tokyo)
        #expect(image.usedDefaultName)
        #expect(image.url.lastPathComponent.hasPrefix("utsushie-20260930-191543"))
        let recording = dir.appendingPathComponent(".utsushie-\(UUID().uuidString).recording.mp4")
        try Data([2]).write(to: recording)
        let video = try ArtifactStore.publishVideo(from: recording, date: date, pattern: pattern, timeZone: tokyo)
        #expect(video.usedDefaultName && FileManager.default.fileExists(atPath: video.url.path))
        #expect(!FileManager.default.fileExists(atPath: recording.path))
    }
}
@Test func losslessPreservesOrientationAndAlpha() throws {
    let width = 8, height = 6
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: 3))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 0.5))
    context.fill(CGRect(x: 0, y: 3, width: width, height: 3))
    let original = try #require(context.makeImage())
    let encoded = try WebPEncoder.encode(original, quality: 80, lossless: true)
    let source = try #require(CGImageSourceCreateWithData(encoded as CFData, nil))
    let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let rendered = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    rendered.draw(decoded, in: CGRect(x: 0, y: 0, width: width, height: height))
    let expected = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    let actual = try #require(rendered.data).assumingMemoryBound(to: UInt8.self)
    for index in 0..<(width * height * 4) { #expect(abs(Int(actual[index]) - Int(expected[index])) <= 1) }
}
@MainActor
@Test(arguments: ClipboardMode.allCases)
func clipboardContainsOnlyRequestedWebPTypes(_ mode: ClipboardMode) {
    let artifact = SharedArtifact(url: URL(fileURLWithPath: "/tmp/image.webp"), kind: .webP, width: 17, height: 11, byteCount: 1)
    let item = ClipboardWriter.item(for: artifact, data: Data([1]), mode: mode)
    let expected: Set<NSPasteboard.PasteboardType>
    switch mode {
    // noneは一覧の⌘Cのように自分で選んだコピーで呼ばれ、既定のbothで載せる。
    case .both, .none: expected = [.fileURL, .init("org.webmproject.webp")]
    case .file: expected = [.fileURL]
    case .data: expected = [.init("org.webmproject.webp")]
    }
    #expect(Set(item.types) == expected)
    #expect(!item.types.contains(.png) && !item.types.contains(.tiff))
}

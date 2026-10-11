import AppKit
import Testing
@testable import Utsushie

@MainActor @Test func readCursorDelaysAndCancelsWithoutRestartingContinuousWait() async throws {
    let cursor = ElementReadCursor()
    var changes = 0
    cursor.begin { changes += 1 }
    #expect(!cursor.isVisible)
    cursor.end()
    try await Task.sleep(for: .milliseconds(200))
    #expect(!cursor.isVisible && changes == 0)
    cursor.begin { changes += 1 }
    try await Task.sleep(for: .milliseconds(100))
    cursor.begin { changes += 1 }
    try await Task.sleep(for: .milliseconds(100))
    #expect(cursor.isVisible && changes == 1)
    cursor.end()
    #expect(!cursor.isVisible)
    #expect(ElementReadCursor.cursor.hotSpot == NSCursor.arrow.hotSpot)
    #expect(ElementReadCursor.cursor.image.size.width > NSCursor.arrow.image.size.width)
    if let path = ProcessInfo.processInfo.environment["UTSUSHIE_CURSOR_PREVIEW"] {
        let image = try #require(ElementReadCursor.cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        try WebPEncoder.encode(image, quality: 90, lossless: false).write(to: URL(fileURLWithPath: path))
    }
}

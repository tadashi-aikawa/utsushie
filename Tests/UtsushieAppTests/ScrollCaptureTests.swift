import AppKit
import CoreVideo
import Testing
import UtsushieCore
@testable import Utsushie

/// 白地に単語のような矩形を並べた縦長のページ。行の間は真っ白で、同じ並びの行は出ない。
private func pageRows(width: Int, height: Int) -> [[UInt8]] {
    var state: UInt64 = 42
    func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
    var rows = [[UInt8]](repeating: [UInt8](repeating: 255, count: width * 4), count: height)
    var y = 6
    while y + 14 < height {
        var x = 8
        let shade = UInt8(30 + next(80))
        while x < width - 30 {
            let word = 10 + next(40)
            for row in y..<(y + 12) {
                for column in x..<min(width - 8, x + word) {
                    rows[row][column * 4] = shade; rows[row][column * 4 + 1] = shade; rows[row][column * 4 + 2] = UInt8(next(255))
                }
            }
            x += word + 6 + next(6)
        }
        y += 18 + next(5)
    }
    return rows
}

private func solidRows(width: Int, height: Int, value: UInt8) -> [[UInt8]] {
    [[UInt8]](repeating: (0..<width).flatMap { _ in [value, value, value, 255] }, count: height)
}

private func pixelBuffer(_ rows: [[UInt8]], width: Int) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, rows.count, kCVPixelFormatType_32BGRA, nil, &buffer)
    let pixel = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixel, [])
    let base = try #require(CVPixelBufferGetBaseAddress(pixel))
    let stride = CVPixelBufferGetBytesPerRow(pixel)
    for (index, row) in rows.enumerated() {
        row.withUnsafeBytes { (base + index * stride).copyMemory(from: $0.baseAddress!, byteCount: width * 4) }
    }
    CVPixelBufferUnlockBaseAddress(pixel, [])
    return pixel
}

private func bytes(of image: CGImage) -> [[UInt8]] {
    let width = image.width
    var data = [UInt8](repeating: 0, count: width * image.height * 4)
    let context = CGContext(data: &data, width: width, height: image.height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))
    return stride(from: 0, to: data.count, by: width * 4).map { Array(data[$0..<($0 + width * 4)]) }
}

/// 実際のBGRAのコマから、固定のヘッダー・フッターを1回ずつにして継ぎ目なくつなぐ。
@Test func scrollSinkStitchesPixelBuffersWithStickyBars() async throws {
    let width = 320
    let page = pageRows(width: width, height: 1400)
    let header = solidRows(width: width, height: 30, value: 40), footer = solidRows(width: width, height: 20, value: 200)
    let region = 240
    let sink = ScrollCaptureSink(width: width, height: 30 + region + 20, excludedRight: 16, onProgress: { _ in }, onStop: {})
    var offset = 0
    for step in [0, 0, 17, 60, 33, 90, 5, 120, 80] {
        offset += step
        let frame = try pixelBuffer(header + Array(page[offset..<(offset + region)]) + footer, width: width)
        sink.queue.sync { sink.process(frame) }
    }
    let result = try #require(await sink.finish())
    #expect(!result.reachedLimit)
    let expected = header + Array(page[0..<(offset + region)]) + footer
    #expect(result.image.height == expected.count)
    #expect(bytes(of: result.image) == expected)
}

/// 右端のスクロールバーは照合に使わない。動く中身と別に右端だけ変わっても、ずれを取り違えない。
@Test func scrollSinkIgnoresScrollbarColumn() async throws {
    let width = 200
    let page = pageRows(width: width, height: 900)
    let region = 200
    let sink = ScrollCaptureSink(width: width, height: region, excludedRight: 16, onProgress: { _ in }, onStop: {})
    var offset = 0
    for (index, step) in [0, 40, 40, 40].enumerated() {
        offset += step
        var rows = Array(page[offset..<(offset + region)])
        // 画面に固定されたスクロールバーのつまみ。コマごとに位置が動く。
        for row in (20 + index * 30)..<(60 + index * 30) {
            for column in (width - 10)..<(width - 4) { rows[row][column * 4 ..< column * 4 + 3] = [120, 120, 120] }
        }
        let frame = try pixelBuffer(rows, width: width)
        sink.queue.sync { sink.process(frame) }
    }
    let result = try #require(await sink.finish())
    #expect(result.image.height == offset + region)
}

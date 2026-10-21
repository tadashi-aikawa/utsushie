import AppKit
import Testing
import UtsushieCore
@testable import Utsushie

private func solid(width: Int, height: Int, top: CGColor, bottom: CGColor) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(bottom); context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
    context.setFillColor(top); context.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
    return try #require(context.makeImage())
}

/// 左上原点の行と列で、RGBの最大の成分を返す。
private func dominant(_ image: CGImage, x: Int, y: Int) throws -> String {
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let context = try #require(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let offset = (y * width + x) * 4
    let rgb = Array(bytes[offset..<offset + 3])
    guard let max = rgb.max(), max > 200 else { return "black" }
    return ["red", "green", "blue"][rgb.firstIndex(of: max)!]
}

private let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
private let green = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
private let blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)

private func displays() throws -> [FrozenDisplay] {
    [FrozenDisplay(geometry: DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 50), scale: 2),
                   image: try solid(width: 200, height: 100, top: red, bottom: green)),
     FrozenDisplay(geometry: DisplayGeometry(id: 2, frame: CGRect(x: -100, y: 0, width: 100, height: 50), scale: 1),
                   image: try solid(width: 100, height: 50, top: blue, bottom: blue))]
}

@Test func frozenRegionSpansDisplaysAtMaxScale() throws {
    let image = try CaptureService.image(for: .region(CGRect(x: -20, y: 10, width: 60, height: 20)), downscale: false, frozen: displays())
    #expect(image.width == 120 && image.height == 40)
    // 上の10pxは主画面の上半分、残りは下半分。左の40pxは1xの画面を拡大したもの。
    #expect(try dominant(image, x: 100, y: 2) == "red")
    #expect(try dominant(image, x: 100, y: 30) == "green")
    #expect(try dominant(image, x: 10, y: 20) == "blue")
}

@Test func frozenRegionHonorsDownscale() throws {
    let image = try CaptureService.image(for: .region(CGRect(x: 10, y: 10, width: 60, height: 20)), downscale: true, frozen: displays())
    #expect(image.width == 60 && image.height == 20)
    #expect(try dominant(image, x: 30, y: 2) == "red")
    #expect(try dominant(image, x: 30, y: 18) == "green")
}

@Test func frozenWindowIsClippedToVisibleDisplays() throws {
    let image = try CaptureService.image(for: .window(7, CGRect(x: 50, y: 0, width: 100, height: 50)), downscale: false, frozen: displays())
    #expect(image.width == 100 && image.height == 100)
    #expect(throws: CaptureError.self) {
        try CaptureService.image(for: .window(7, CGRect(x: 300, y: 0, width: 10, height: 10)), downscale: false, frozen: displays())
    }
    #expect(throws: CaptureError.self) {
        try CaptureService.image(for: .region(CGRect(x: 90, y: 0, width: 20, height: 10)), downscale: false, frozen: displays())
    }
}

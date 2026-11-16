import Foundation
import Testing
import UtsushieCore

private let output = URL(fileURLWithPath: "/Users/me/Pictures/UTSUSHIE", isDirectory: true)

@Test func importEditsListedWebPAndMP4InOutputFolderInPlace() {
    #expect(CaptureImport.action(for: output.appendingPathComponent("a.webp"), media: .image, outputDirectory: output) == .editInPlace)
    #expect(CaptureImport.action(for: output.appendingPathComponent("b.MP4"), media: .video, outputDirectory: output) == .editInPlace)
}

@Test func importCopiesHiddenOrRecordingFilesAndFilesElsewhere() {
    let desktop = URL(fileURLWithPath: "/Users/me/Desktop", isDirectory: true)
    #expect(CaptureImport.action(for: desktop.appendingPathComponent("a.webp"), media: .image, outputDirectory: output) == .copyWebP)
    #expect(CaptureImport.action(for: output.appendingPathComponent(".a.webp"), media: .image, outputDirectory: output) == .copyWebP)
    #expect(CaptureImport.action(for: output.appendingPathComponent("sub/a.webp"), media: .image, outputDirectory: output) == .copyWebP)
    #expect(CaptureImport.action(for: desktop.appendingPathComponent("a.mp4"), media: .video, outputDirectory: output) == .copyMP4)
    #expect(CaptureImport.action(for: output.appendingPathComponent("x.recording.mp4"), media: .video, outputDirectory: output) == .copyMP4)
}

@Test func importEncodesOtherImagesAndConvertsOtherMovies() {
    #expect(CaptureImport.action(for: output.appendingPathComponent("a.png"), media: .image, outputDirectory: output) == .encodeImage)
    #expect(CaptureImport.action(for: URL(fileURLWithPath: "/tmp/a.HEIC"), media: .image, outputDirectory: output) == .encodeImage)
    #expect(CaptureImport.action(for: output.appendingPathComponent("a.mov"), media: .video, outputDirectory: output) == .convertVideo)
}

@Test func importTreatsOnly144DPIAsRetina() {
    #expect(CaptureImport.pixelScale(dpiWidth: 144, dpiHeight: 144) == 2)
    #expect(CaptureImport.pixelScale(dpiWidth: 72, dpiHeight: 72) == 1)
    #expect(CaptureImport.pixelScale(dpiWidth: 144, dpiHeight: 72) == 1)
    #expect(CaptureImport.pixelScale(dpiWidth: 300, dpiHeight: 300) == 1)
    #expect(CaptureImport.pixelScale(dpiWidth: nil, dpiHeight: nil) == 1)
}

@Test func importLimitsWebPSidesAndRoundsFrameRate() {
    #expect(CaptureImport.fitsWebP(width: 16383, height: 1))
    #expect(!CaptureImport.fitsWebP(width: 16384, height: 1))
    #expect(!CaptureImport.fitsWebP(width: 0, height: 10))
    #expect(CaptureImport.tooLargeMessage(width: 16384, height: 2) == "16384×2pxはWebPに入りません。1辺16383pxまでです")
    #expect(CaptureImport.frameRate(nominal: 29.97) == 30)
    #expect(CaptureImport.frameRate(nominal: 0) == nil)
    #expect(CaptureImport.frameRate(nominal: .nan) == nil)
}

@Test func importFailuresAreListedOnePerLine() {
    #expect(CaptureImport.failureMessage([("a.pdf", "画像か動画ではありません"), ("b.png", "画像を読めませんでした")])
        == "a.pdf: 画像か動画ではありません\nb.png: 画像を読めませんでした")
}

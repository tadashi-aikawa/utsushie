import AppKit
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import AVFoundation
import Testing
import UtsushieCore
@testable import Utsushie

private func workspace() throws -> (source: URL, config: UtsushieConfig) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = root.appendingPathComponent("Desktop")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    var config = UtsushieConfig()
    config.outputDir = root.appendingPathComponent("UTSUSHIE").path
    return (source, config)
}

private func image(width: Int, height: Int) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}

private func write(_ image: CGImage, to url: URL, type: UTType, properties: [CFString: Any] = [:]) throws {
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
}

private func failure(_ body: () async throws -> ImportedCapture) async -> String? {
    do { _ = try await body(); return nil } catch { return error.localizedDescription }
}

private func files(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
}

@Test func importEncodesPNGToWebPInOutputFolderAndKeepsRetinaScale() async throws {
    let (source, config) = try workspace()
    let png = source.appendingPathComponent("設計メモ.png")
    try write(image(width: 40, height: 30), to: png, type: .png, properties: [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144])
    let original = try Data(contentsOf: png)
    let date = Date(timeIntervalSince1970: 0)
    let imported = try await CaptureImporter.importFile(png, media: .image, action: .encodeImage, config: config, date: date)
    #expect(imported.artifact.kind == .webP)
    #expect(imported.artifact.url.deletingLastPathComponent().path == config.outputURL().path)
    #expect(imported.artifact.url.lastPathComponent
        == CaptureFileNaming.resolve(date: date, sequence: 0, extension: "webp", pattern: config.fileName).name)
    #expect(imported.artifact.width == 40 && imported.artifact.height == 30 && imported.artifact.pixelScale == 2)
    let data = try Data(contentsOf: imported.artifact.url)
    #expect(String(data: data[8..<12], encoding: .ascii) == "WEBP" && data.count == imported.artifact.byteCount)
    #expect(try Data(contentsOf: png) == original)
}

@Test func importAppliesJPEGOrientationAndTreatsPlainDPIAs1x() async throws {
    let (source, config) = try workspace()
    let jpeg = source.appendingPathComponent("photo.jpg")
    // 6は時計回りに90度回して見せる指定。保存された画素は横長でも、取り込みは縦長になる。
    try write(image(width: 20, height: 10), to: jpeg, type: .jpeg, properties: [kCGImagePropertyOrientation: 6])
    let imported = try await CaptureImporter.importFile(jpeg, media: .image, action: .encodeImage, config: config)
    #expect(imported.image.width == 10 && imported.image.height == 20)
    #expect(imported.artifact.width == 10 && imported.artifact.height == 20 && imported.artifact.pixelScale == 1)
}

@Test func importCopiesWebPBytesWithoutRecompressing() async throws {
    let (source, config) = try workspace()
    let webp = source.appendingPathComponent("other.webp")
    let bytes = try WebPEncoder.encode(image(width: 9, height: 7), quality: 30, lossless: false)
    try bytes.write(to: webp)
    let imported = try await CaptureImporter.importFile(webp, media: .image, action: .copyWebP, config: config)
    #expect(try Data(contentsOf: imported.artifact.url) == bytes)
    #expect(imported.artifact.width == 9 && imported.artifact.height == 7)
}

@Test func importRejectsImagesTooLargeForWebPAndUnreadableFilesWithoutLeavingFiles() async throws {
    let (source, config) = try workspace()
    let wide = source.appendingPathComponent("wide.png")
    try write(image(width: 16384, height: 1), to: wide, type: .png)
    #expect(await failure { try await CaptureImporter.importFile(wide, media: .image, action: .encodeImage, config: config) }
        == "16384×1pxはWebPに入りません。1辺16383pxまでです")
    let broken = source.appendingPathComponent("broken.png")
    try Data("not an image".utf8).write(to: broken)
    #expect(await failure { try await CaptureImporter.importFile(broken, media: .image, action: .encodeImage, config: config) }
        == "画像を読めませんでした")
    #expect(!FileManager.default.fileExists(atPath: config.outputURL().path))
}

/// 30fps・2秒の単色の動画。transformは再生時の向きの指定。
private func movie(at url: URL, type: AVFileType, width: Int = 64, height: Int = 48,
                   transform: CGAffineTransform = .identity) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: type)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: VideoEncoding.settings(width: width, height: height, fps: 30, compression: .standard))
    input.expectsMediaDataInRealTime = false; input.transform = transform; writer.add(input)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    #expect(writer.startWriting()); writer.startSession(atSourceTime: .zero)
    for index in 0..<60 {
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { throw try #require(writer.error) }
            try await Task.sleep(for: .milliseconds(1))
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = try #require(CVPixelBufferGetBaseAddress(pixels))
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixels)
        // 左上の4分の1だけ明るくし、向きを見分けられるようにする。
        for y in 0..<height {
            memset(base + y * bytesPerRow, 30, width * 4)
            if y < height / 2 { memset(base + y * bytesPerRow, 230, width / 2 * 4) }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30)))
    }
    writer.endSession(atSourceTime: CMTime(value: 60, timescale: 30)); input.markAsFinished()
    await writer.finishWriting(); #expect(writer.status == .completed)
}

@Test func importConvertsMOVToMP4AndKeepsLengthAndFrameRate() async throws {
    let (source, config) = try workspace()
    let mov = source.appendingPathComponent("画面収録.mov")
    try await movie(at: mov, type: .mov)
    let imported = try await CaptureImporter.importFile(mov, media: .video, action: .convertVideo, config: config)
    #expect(imported.artifact.kind == .mp4 && imported.artifact.url.pathExtension == "mp4")
    #expect(abs((imported.artifact.duration ?? 0) - 2) < 0.1)
    #expect(imported.artifact.videoFPS == 30)
    #expect(imported.artifact.width == 64 && imported.artifact.height == 48)
    // 一時ファイルは残さず、公開したMP4だけが並ぶ。
    #expect(try files(in: config.outputURL()) == [imported.artifact.url.lastPathComponent])
    #expect(FileManager.default.fileExists(atPath: mov.path))
}

@Test func importBakesRotationSoTheEditorSeesUprightFrames() async throws {
    let (source, config) = try workspace()
    let mov = source.appendingPathComponent("portrait.mov")
    try await movie(at: mov, type: .mov, transform: CGAffineTransform(rotationAngle: .pi / 2))
    let imported = try await CaptureImporter.importFile(mov, media: .video, action: .convertVideo, config: config)
    let track = try #require(try await AVURLAsset(url: imported.artifact.url).loadTracks(withMediaType: .video).first)
    let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
    #expect(transform.isIdentity)
    #expect(size == CGSize(width: 48, height: 64))
    #expect(imported.artifact.width == 48 && imported.artifact.height == 64)
    // 向きの指定どおりに再生した元の見た目と、焼き込んだ画素の明るい隅が同じ所にある。
    let expected = try await brightCorners(of: AVURLAsset(url: mov), appliesTransform: true)
    let actual = try await brightCorners(of: AVURLAsset(url: imported.artifact.url), appliesTransform: false)
    #expect(expected.filter { $0 }.count == 1 && actual == expected)
}

/// 最初のコマの四隅(左上・右上・左下・右下)が明るいか。
private func brightCorners(of asset: AVURLAsset, appliesTransform: Bool) async throws -> [Bool] {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = appliesTransform
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    let frame = try await generator.image(at: .zero).image
    let side = 4
    let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
    context.interpolationQuality = .none
    context.draw(frame, in: CGRect(x: 0, y: 0, width: side, height: side))
    let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    // CGContextの行0は上端。
    return [pixels[0], pixels[side - 1], pixels[(side - 1) * side], pixels[side * side - 1]].map { $0 > 128 }
}

@Test func importCopiesMP4BytesAsIs() async throws {
    let (source, config) = try workspace()
    let mp4 = source.appendingPathComponent("clip.mp4")
    try await movie(at: mp4, type: .mp4)
    let imported = try await CaptureImporter.importFile(mp4, media: .video, action: .copyMP4, config: config)
    #expect(try Data(contentsOf: imported.artifact.url) == Data(contentsOf: mp4))
    #expect(try files(in: config.outputURL()) == [imported.artifact.url.lastPathComponent])
}

@Test func importReadsFinderFileURLsFromServicePasteboard() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
    defer { pasteboard.releaseGlobally() }
    let urls = [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.mov")]
    pasteboard.clearContents()
    #expect(pasteboard.writeObjects(urls as [NSURL]))
    #expect(FinderImportService.fileURLs(in: pasteboard) == urls)
}

@MainActor
@Test func importServiceReportsFilesAndRejectsEmptyPasteboard() throws {
    let service = FinderImportService()
    var received: [URL] = []
    service.onFiles = { received = $0 }
    let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    var message: NSString?
    service.editInUtsushie(pasteboard, userData: nil, error: &message)
    #expect(received.isEmpty && message == "UTSUSHIEへ渡せるファイルがありません")
    pasteboard.clearContents(); message = nil
    #expect(pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/a.png")] as [NSURL]))
    service.editInUtsushie(pasteboard, userData: nil, error: &message)
    #expect(received == [URL(fileURLWithPath: "/tmp/a.png")] && message == nil)
}

@MainActor private func importController() -> ThumbnailController {
    let controller = ThumbnailController()
    controller.editorFocus = .init(activate: {}, restore: { _ in })
    controller.annotationConfig = { UtsushieConfig() }
    return controller
}

@MainActor private func savedArtifact(in directory: URL, seconds: Double) throws -> (SharedArtifact, CGImage) {
    let picture = try image(width: 160, height: 100)
    let data = try WebPEncoder.encode(picture, quality: 80, lossless: true)
    let url = try ArtifactStore.save(data: data, kind: .webP, directory: directory, date: Date(timeIntervalSince1970: seconds)).url
    return (SharedArtifact(url: url, kind: .webP, width: 160, height: 100, byteCount: data.count), picture)
}

/// 取り込みの間はカードを隠して寿命を止め、最初の1件を開いてから戻す。AppDelegate.runImportと同じ順。
@MainActor @Test func importHoldsCardsUntilFirstEditorOpensAndKeepsKeysOnTheEditor() throws {
    let (_, config) = try workspace()
    let directory = config.outputURL()
    let controller = importController()
    defer { for card in controller.cards { controller.remove(card.id) } }
    controller.setHoldingForImport(true)
    let (firstArtifact, firstImage) = try savedArtifact(in: directory, seconds: 0)
    let first = controller.add(firstArtifact, image: firstImage, copied: false, seconds: 5, screen: nil)
    // 取り込みの途中で撮影のホットキーを押してEscで閉じても、取り込みの保持は解けない。
    controller.setSuspended(true); controller.setSuspended(false)
    let (secondArtifact, secondImage) = try savedArtifact(in: directory, seconds: 1)
    let second = controller.add(secondArtifact, image: secondImage, copied: false, seconds: 5, screen: nil)
    let firstCard = try #require(controller.cards.first { $0.id == first })
    let secondCard = try #require(controller.cards.first { $0.id == second })
    // 動画の変換を待つ間も、先に足したカードの寿命は進まない。
    #expect(firstCard.timer == nil && secondCard.timer == nil && !firstCard.panel.isVisible)
    controller.edit(first)
    controller.setHoldingForImport(false)
    #expect(firstCard.editor != nil && !firstCard.panel.isVisible)
    // 後から出したカードは、開いた編集画面からキーを取らない。
    #expect(secondCard.panel.isVisible && !secondCard.panel.receivesKeyboard)
    #expect(secondCard.timer == nil)
    try #require(firstCard.editor).window.close()
}

/// 一覧から開いた動画は、編集を閉じても一覧を閉じるまで一覧専用のカードが残る。
@MainActor @Test func importOpensTheLibraryOnlyVideoCardThatRestoreReturns() async throws {
    let (_, config) = try workspace()
    let directory = config.outputURL()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("clip.mp4")
    try await movie(at: url, type: .mp4)
    let controller = importController()
    controller.makeVideoSession = { VideoEditSession(artifact: $0, fps: $1, rememberDirectory: { _ in }) }
    defer { controller.closeLibrarySessions() }
    try await controller.editFromLibrary(url) {}
    let card = try #require(controller.card(for: url))
    try #require(card.videoEditor).window.close()
    // 一覧専用のカードが残っている間にFinderから同じファイルと画像を渡しても、動画の編集画面が開く。
    controller.setHoldingForImport(true)
    let restored = try await controller.restore(url, seconds: 5, screen: nil)
    #expect(restored == card.id && controller.cards.isEmpty)
    let (artifact, picture) = try savedArtifact(in: directory, seconds: 1)
    let imageID = controller.add(artifact, image: picture, copied: false, seconds: 5, screen: nil)
    defer { controller.remove(imageID) }
    controller.edit(restored)
    controller.setHoldingForImport(false)
    let editor = try #require(card.videoEditor)
    // 後から足した画像のカードは、動画の編集画面からキーを取らない。
    let imageCard = try #require(controller.cards.first { $0.id == imageID })
    #expect(imageCard.panel.isVisible && !imageCard.panel.receivesKeyboard)
    // 開いたままもう一度渡しても、2つ目は開かずに同じ編集画面を前へ出す。
    controller.edit(restored)
    #expect(card.videoEditor === editor)
    editor.window.close()
}

@Test func importClassifiesImagesAndMoviesByType() {
    #expect(CaptureImporter.media(of: URL(fileURLWithPath: "/tmp/a.png")) == .image)
    #expect(CaptureImporter.media(of: URL(fileURLWithPath: "/tmp/a.heic")) == .image)
    #expect(CaptureImporter.media(of: URL(fileURLWithPath: "/tmp/a.mov")) == .video)
    #expect(CaptureImporter.media(of: URL(fileURLWithPath: "/tmp/a.mp4")) == .video)
    #expect(CaptureImporter.media(of: URL(fileURLWithPath: "/tmp/a.pdf")) == nil)
}

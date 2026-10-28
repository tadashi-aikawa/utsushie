import CoreGraphics
import Testing
@testable import UtsushieCore

@Test func compressionKeyTogglesOnlyForVideoAndResetsOnReopen() {
    var state = CaptureState()
    #expect(!state.handles(1))
    #expect(state.key(1, hasLast: true) == .none)
    #expect(state.compression == .compact)
    _ = state.key(48, hasLast: true)
    #expect(state.handles(1))
    _ = state.pointerDown(at: .zero, last: nil)
    state.pointerDragged(to: CGPoint(x: 40, y: 30))
    #expect(state.key(1, hasLast: true) == .none)
    #expect(state.compression == .standard)
    #expect(state.effectiveVideoConfig(VideoConfig()).compression == .standard)
    #expect(state.pointerUp(at: CGPoint(x: 40, y: 30)) == .captureArea(CGRect(x: 0, y: 0, width: 40, height: 30)))
    _ = state.key(1, hasLast: true)
    #expect(state.effectiveVideoConfig(VideoConfig()).compression == .compact)
    #expect(CaptureState().compression == .compact)
    #expect(UtsushieConfig().video.compression == .compact)
}

@Test func compressionItemAppearsOnlyForVideoAfterAudio() {
    #expect(OverlayPresentation.compressionItem(output: .image, compression: .standard) == nil)
    let compact = OverlayPresentation.compressionItem(output: .video, compression: .compact)
    #expect(compact?.title == "容量 小" && compact?.key == "S" && compact?.selected == false)
    #expect(OverlayPresentation.compressionItem(output: .video, compression: .standard)?.selected == true)
    let widths: [CGFloat] = [40, 56, 87, 63, 90, 80, 91]
    let audioOnly = OverlayToolbarLayout(itemWidths: widths, tabWidth: 28, resolutionWidth: 50, audioWidth: 70)
    let layout = OverlayToolbarLayout(itemWidths: widths, tabWidth: 28, resolutionWidth: 50, audioWidth: 70, compressionWidth: 60)
    #expect(audioOnly.compression == nil)
    let audio = try! #require(layout.audio), compression = try! #require(layout.compression)
    #expect(compression.minX - audio.maxX == 10 && compression.width == 60)
    #expect(layout.targetTray.minX - compression.maxX == 10)
    #expect(layout.width - audioOnly.width == 70)
}

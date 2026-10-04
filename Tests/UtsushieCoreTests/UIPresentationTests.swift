import Foundation
import CoreGraphics
import Testing
@testable import UtsushieCore

@Test func dimensionLabelFallsInsideAtScreenTopAndStaysOnScreen() {
    let screen = CGRect(x: -1000, y: 900, width: 1000, height: 700)
    let size = CGSize(width: 100, height: 22)
    let below = CGRect(x: -600, y: 1000, width: 200, height: 100)
    let outside = OverlayPresentation.dimensionLabel(selection: below, screen: screen, size: size)
    #expect(outside.minY > below.maxY && screen.contains(outside))
    let top = CGRect(x: -40, y: 1400, width: 40, height: 200)
    let inside = OverlayPresentation.dimensionLabel(selection: top, screen: screen, size: size)
    #expect(inside.maxY < top.maxY && screen.contains(inside))
    let wide = OverlayPresentation.dimensionLabel(selection: top, screen: screen, size: CGSize(width: 2000, height: 22))
    #expect(screen.contains(wide))
}

@Test func overlayDimensionsUseOutputPixelsAndVideoEvenSize() {
    let points = CGSize(width: 331, height: 211)
    #expect(OverlayPresentation.dimensions(points: points, scale: 2, output: .image, downscale: true) == "331×211")
    #expect(OverlayPresentation.dimensions(points: points, scale: 2, output: .image, downscale: false) == "662×422")
    #expect(OverlayPresentation.dimensions(points: points, scale: 2, output: .video, downscale: true) == "330×210")
    #expect(OverlayPresentation.dimensions(points: points, scale: 2, output: .video, downscale: false) == "662×422")
}

@Test func hudSeparatesSelectedOutputAndTargetAndDisablesMissingLast() {
    let initial = OverlayPresentation.items(output: .image, target: .area, hasLast: false)
    #expect(initial.filter(\.selected).map(\.title) == ["画像", "範囲"])
    #expect(initial.first { $0.title == "前回" }?.enabled == false)
    #expect(initial.first { $0.title == "動画" }?.recording == false)
    #expect(initial.filter(\.recording).isEmpty)
    let video = OverlayPresentation.items(output: .video, target: .window, hasLast: true)
    #expect(video.filter(\.selected).map(\.title) == ["動画", "ウィンドウ"])
    #expect(video.filter(\.recording).map(\.title) == ["動画"])
    #expect(video.first { $0.title == "ウィンドウ" }?.key == "W")
    #expect(video.first { $0.title == "前回" }?.enabled == true)
}

@Test func cardButtonsUseEqualWidthsAndDoNotHitGapsOrPreview() {
    for action in CardAction.allCases {
        let rect = CardPresentation.button(action)
        #expect(rect.width == 55.5 && rect.height == 24)
        #expect(CardPresentation.action(at: CGPoint(x: rect.midX, y: rect.midY)) == action)
        #expect(CardPresentation.action(at: CGPoint(x: rect.midX, y: rect.minY - 1)) == nil)
        #expect(CardPresentation.action(at: CGPoint(x: rect.midX, y: rect.maxY + 1)) == nil)
    }
    #expect(CardPresentation.action(at: CGPoint(x: 70, y: 198)) == nil)
    #expect(CardPresentation.action(at: CGPoint(x: 263, y: 198)) == nil)
    #expect(CardPresentation.action(at: CGPoint(x: 120, y: 70)) == nil)
}

@Test func stateWordsAndMetadataMatchJapaneseUI() {
    #expect(CardPresentation.status(copied: true, finalizing: false) == "コピー済み")
    #expect(CardPresentation.status(copied: false, finalizing: false) == "保存のみ")
    #expect(CardPresentation.status(copied: true, finalizing: true) == "書き出し中")
    #expect(CardPresentation.info(format: "WebP", width: 330, height: 210, bytes: 88_064) == "WebP · 330×210 · 86 KB")
    #expect(CardPresentation.info(format: "MP4", width: 1280, height: 720, bytes: 3_355_443) == "MP4 · 1280×720 · 3.2 MB")
    #expect(CardPresentation.info(format: "MP4", width: 1280, height: 720, bytes: 0) == "MP4 · 1280×720 · —")
    #expect(RecordingPresentation.title(phase: .starting, elapsed: 0) == "準備中")
    #expect(RecordingPresentation.title(phase: .recording, elapsed: 12.4) == "■ 0:12")
    #expect(RecordingPresentation.title(phase: .finalizing, elapsed: 12.4) == "書き出し中")
    #expect(RecordingPresentation.title(phase: .idle, elapsed: 0).isEmpty)
    for phase in [RecordingPhase.idle, .starting, .recording, .finalizing] {
        #expect(RecordingPresentation.stopsOnClick(phase: phase) == (phase == .recording))
    }
}

@Test func menuHotkeyLabelUsesConfiguredPhysicalKeyAndModifiers() {
    #expect(HotkeyPresentation.label(Hotkey()) == "⇧⌘2")
    #expect(HotkeyPresentation.label(Hotkey(keyCode: 14, modifiers: 4096 | 2048)) == "⌃⌥E")
    #expect(HotkeyPresentation.label(Hotkey(keyCode: 122, modifiers: 256)) == "⌘F1")
}

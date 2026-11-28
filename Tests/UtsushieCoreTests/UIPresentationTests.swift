import Foundation
import CoreGraphics
import Testing
@testable import UtsushieCore

@Test func fullDisplayHighlightFitsItsCornersAndLabelInsideTheDisplay() {
    let screen = CGRect(x: -1000, y: 900, width: 1000, height: 700)
    let corners = OverlayPresentation.selectionCornerBounds(selection: screen, inside: true)
    // 下地は6pt幅。正方形の線端と四隅を含めても画面内へ収める。
    #expect(screen.contains(corners.insetBy(dx: -3, dy: -3)))
    let normalCorners = OverlayPresentation.selectionCornerBounds(selection: screen, inside: false)
    #expect(normalCorners.insetBy(dx: 3, dy: 3).contains(screen))
    let label = OverlayPresentation.dimensionLabel(selection: screen, screen: screen, size: CGSize(width: 1200, height: 22))
    #expect(screen.contains(label))
    #expect(label.maxY < screen.maxY)
}

@Test func recordingBadgeFollowsTheDimensionLabelAndAvoidsTheMenuBarInside() {
    let screen = CGRect(x: -1000, y: 900, width: 1000, height: 700)
    let visible = CGRect(x: -1000, y: 900, width: 1000, height: 676)
    let size = CGSize(width: 60, height: 22)
    let area = CGRect(x: -600, y: 1000, width: 200, height: 100)
    #expect(RecordingPresentation.badge(selection: area, visible: visible, size: size)
        == OverlayPresentation.dimensionLabel(selection: area, screen: visible, size: size))
    #expect(RecordingPresentation.badge(selection: area, visible: visible, size: size).minY == area.maxY + 10)
    // 画面全体: メニューバーの下で、内側の鉤(内側4pt+線幅)の右へ置く。
    let full = RecordingPresentation.badge(selection: screen, visible: visible, size: size)
    #expect(full == CGRect(x: -992, y: visible.maxY - 30, width: 60, height: 22))
    // メニューバーのすぐ下まで伸びる範囲も、バッジはメニューバーへ掛けない。
    let top = CGRect(x: -600, y: 1300, width: 200, height: 300)
    let inside = RecordingPresentation.badge(selection: top, visible: visible, size: size)
    #expect(inside.maxY <= visible.maxY - 8 && inside.minX == top.minX + 8 && top.contains(inside))
    #expect(RecordingPresentation.cornersInside(selection: screen, screen: screen))
    #expect(!RecordingPresentation.cornersInside(selection: area, screen: screen))
}

@Test func recordingBadgeGoesToTheScreenWithTheLargestOverlap() {
    let screens = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 1000, y: 0, width: 1000, height: 800)]
    #expect(RecordingPresentation.badgeScreen(selection: CGRect(x: 900, y: 100, width: 300, height: 100), screens: screens) == 1)
    #expect(RecordingPresentation.badgeScreen(selection: CGRect(x: 700, y: 100, width: 400, height: 100), screens: screens) == 0)
    #expect(RecordingPresentation.badgeScreen(selection: CGRect(x: 3000, y: 100, width: 100, height: 100), screens: screens) == nil)
}

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

@Test func lastLabelAddsDimensionsAfterKey() {
    #expect(OverlayPresentation.lastLabel(dimensions: "662×422") == "前回 ⏎ · 662×422")
}

@Test func lastLabelFrameMatchesTheSelectionBadgeOnItsScreen() {
    let left = CGRect(x: 0, y: 0, width: 1000, height: 800), right = CGRect(x: 1000, y: 0, width: 1000, height: 800)
    let size = CGSize(width: 140, height: 22)
    // 選択範囲の寸法のバッジと同じく、枠の上10ptの外で左端をそろえる。
    let area = CGRect(x: 100, y: 100, width: 300, height: 200)
    let placed: CGRect = OverlayPresentation.lastLabelFrame(last: area, screens: [left, right], size: size)
    let selection: CGRect = OverlayPresentation.dimensionLabel(selection: area, screen: left, size: size)
    #expect(placed == selection)
    #expect(placed == CGRect(x: 100, y: 310, width: 140, height: 22))
    // 狭い枠を右端へ寄せても、枠のある画面の中へ戻す。隣の画面へははみ出さない。
    let edge = OverlayPresentation.lastLabelFrame(last: CGRect(x: 950, y: 100, width: 50, height: 200), screens: [left, right], size: size)
    #expect(edge.maxX == 996)
    // 跨ぐ枠は最も広く重なる画面を基準にする。
    let spanning = OverlayPresentation.lastLabelFrame(last: CGRect(x: 900, y: 100, width: 400, height: 200), screens: [left, right], size: size)
    #expect(right.contains(spanning))
    // 上端の枠は選択範囲と同じく内側へ回る。
    let top = OverlayPresentation.lastLabelFrame(last: CGRect(x: 100, y: 600, width: 300, height: 200), screens: [left, right], size: size)
    #expect(left.contains(top))
}

@Test func badgeFrameStopsAtTheTopOfItsScreenWhenSpanningUpward() {
    let lower = CGRect(x: 0, y: 0, width: 1000, height: 800), upper = CGRect(x: 0, y: 800, width: 1000, height: 800)
    let size = CGSize(width: 140, height: 22)
    // 下の画面が基準で、枠の上端だけ上の画面へ跨ぐ。上の画面へ切れ端を出さない。
    let frame = OverlayPresentation.badgeFrame(selection: CGRect(x: 100, y: 300, width: 300, height: 520), screens: [lower, upper], size: size)
    #expect(lower.contains(frame))
}

@Test func lastLabelFrameMovesOffTheHighlightBadge() {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let size = CGSize(width: 140, height: 22)
    let last = CGRect(x: 100, y: 100, width: 300, height: 200)
    let highlightSize = CGSize(width: 180, height: 22)
    // 前回枠とウィンドウの左上がそろうと、強調のバッジと同じ所になる。強調のバッジの上へずらす。
    let highlight: CGRect = OverlayPresentation.dimensionLabel(selection: last, screen: screen, size: highlightSize)
    let moved: CGRect = OverlayPresentation.lastLabelFrame(last: last, screens: [screen], size: size, avoiding: (last, highlightSize))
    #expect(!moved.intersects(highlight))
    #expect(moved.minY > highlight.maxY)
    // 上に入らなければ下へずらす。
    let top = CGRect(x: 100, y: 500, width: 300, height: 270)
    let topHighlight: CGRect = OverlayPresentation.dimensionLabel(selection: top, screen: screen, size: highlightSize)
    let below: CGRect = OverlayPresentation.lastLabelFrame(last: top, screens: [screen], size: size, avoiding: (top, highlightSize))
    #expect(!below.intersects(topHighlight))
    #expect(screen.contains(below))
    // 重ならなければ動かさない。
    let far = CGRect(x: 600, y: 100, width: 300, height: 200)
    let kept: CGRect = OverlayPresentation.lastLabelFrame(last: last, screens: [screen], size: size, avoiding: (far, size))
    let plain: CGRect = OverlayPresentation.badgeFrame(selection: last, screens: [screen], size: size)
    #expect(kept == plain)
}

@Test func lastLabelFrameAvoidsTheHighlightBadgeDrawnOnItsOwnScreen() {
    let left = CGRect(x: 0, y: 0, width: 1000, height: 800), right = CGRect(x: 1000, y: 0, width: 1000, height: 800)
    let size = CGSize(width: 140, height: 22), highlightSize = CGSize(width: 180, height: 22)
    // ウィンドウの大半は右の画面でも、左の画面のパネルは強調のバッジを左の画面の中へ収めて描く。
    let last = CGRect(x: 830, y: 100, width: 160, height: 200)
    let window = CGRect(x: 900, y: 100, width: 900, height: 200)
    let drawnOnLeft: CGRect = OverlayPresentation.dimensionLabel(selection: window, screen: left, size: highlightSize)
    let placed: CGRect = OverlayPresentation.lastLabelFrame(last: last, screens: [left, right], size: size, avoiding: (window, highlightSize))
    #expect(!placed.intersects(drawnOnLeft))
}

@Test func hudSeparatesSelectedOutputAndTargetAndDisablesMissingLast() {
    let initial = OverlayPresentation.items(output: .image, target: .area, hasLast: false)
    #expect(initial.filter(\.selected).map(\.title) == ["画像", "範囲"])
    #expect(initial.first { $0.title == "前回" }?.enabled == false)
    #expect(initial.first { $0.title == "動画" }?.recording == false)
    #expect(initial.filter(\.recording).isEmpty)
    let video = OverlayPresentation.items(output: .video, target: .area, hasLast: true)
    #expect(video.filter(\.selected).map(\.title) == ["動画", "範囲"])
    #expect(video.filter(\.recording).map(\.title) == ["動画"])
    #expect(video.map(\.title) == ["画像", "動画", "スクロール", "範囲", "前回", "Chrome", "要素", "やめる"])
    #expect(!video.contains { $0.key == "W" })
    #expect(video.first { $0.title == "前回" }?.enabled == true)
}

@Test func cardButtonsUseEqualWidthsAndDoNotHitGapsOrPreview() {
    for action in CardAction.allCases {
        let rect = CardPresentation.button(action)
        #expect(abs(rect.width - 43.2) < 0.001 && rect.height == 24)
        #expect(CardPresentation.action(at: CGPoint(x: rect.midX, y: rect.midY)) == action)
        #expect(CardPresentation.action(at: CGPoint(x: rect.midX, y: rect.minY - 1)) == nil)
        #expect(CardPresentation.action(at: CGPoint(x: rect.midX, y: rect.maxY + 1)) == nil)
    }
    #expect(CardPresentation.button(.trash).maxX - 252 < 0.001)
    #expect(CardPresentation.action(at: CGPoint(x: 58, y: 198)) == nil)
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

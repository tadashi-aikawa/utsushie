import Testing
@testable import UtsushieCore

/// 行ごとに模様の違う縦長のページ。同じ行は2度と出ない。
private func page(width: Int, height: Int, seed: UInt64 = 7) -> [[UInt8]] {
    var state = seed
    func next() -> UInt8 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return UInt8(truncatingIfNeeded: state >> 33)
    }
    return (0..<height).map { _ in (0..<width).map { _ in next() } }
}

private struct Rig {
    var stitcher: ScrollStitcher
    var canvas: ScrollCanvas
    let width: Int
    init(width: Int, maxHeight: Int = ScrollStitcher.webPLimit) {
        self.width = width
        stitcher = ScrollStitcher(maxHeight: maxHeight); canvas = ScrollCanvas(rowBytes: width)
    }
    @discardableResult
    mutating func add(_ rows: [[UInt8]]) -> ScrollStep {
        let flat = rows.flatMap { $0 }
        let step = stitcher.add(ScrollLuma(width: width, height: rows.count, values: flat))
        flat.withUnsafeBytes { canvas.add($0, stride: width, step: step) }
        return step
    }
    var output: [[UInt8]] {
        let bytes = canvas.output(still: stitcher.isStill)
        return stride(from: 0, to: bytes.count, by: width).map { Array(bytes[$0..<($0 + width)]) }
    }
}

@Test func stitchesDownwardScrollWithoutSeams() {
    let source = page(width: 24, height: 600)
    var rig = Rig(width: 24)
    var offset = 0
    for step in [0, 0, 7, 20, 33, 1, 60, 45] {
        offset += step
        rig.add(Array(source[offset..<(offset + 100)]))
    }
    #expect(rig.output == Array(source[0..<(offset + 100)]))
    #expect(rig.stitcher.outputHeight == offset + 100)
}

@Test func keepsStickyHeaderAndFooterOnce() {
    let source = page(width: 24, height: 600)
    let header = page(width: 24, height: 12, seed: 11), footer = page(width: 24, height: 9, seed: 13)
    var rig = Rig(width: 24)
    var offset = 0
    for step in [0, 15, 30, 30, 44] {
        offset += step
        rig.add(header + Array(source[offset..<(offset + 80)]) + footer)
    }
    #expect(rig.output == header + Array(source[0..<(offset + 80)]) + footer)
}

@Test func scrollingBackUpAddsNothingAndContinuesBelow() {
    let source = page(width: 24, height: 600)
    var rig = Rig(width: 24)
    for offset in [0, 40, 80, 50, 20, 60, 120] { rig.add(Array(source[offset..<(offset + 100)])) }
    #expect(rig.output == Array(source[0..<220]))
}

@Test func firstMovementUpwardKeepsFirstFramesFooter() {
    let source = page(width: 24, height: 600)
    let footer = page(width: 24, height: 9, seed: 13)
    var rig = Rig(width: 24)
    for offset in [100, 70, 130] { rig.add(Array(source[offset..<(offset + 80)]) + footer) }
    #expect(rig.output == Array(source[100..<210]) + footer)
}

@Test func losesTrackWhenTooFastAndResumesAfterGoingBack() {
    let source = page(width: 24, height: 600)
    var rig = Rig(width: 24)
    rig.add(Array(source[0..<100]))
    rig.add(Array(source[30..<130]))
    let jump = rig.add(Array(source[300..<400]))
    #expect(jump.lost && jump.append == nil)
    #expect(rig.stitcher.lost)
    let back = rig.add(Array(source[100..<200]))
    #expect(!back.lost)
    #expect(rig.output == Array(source[0..<200]))
}

@Test func stopsAtLimit() {
    let source = page(width: 24, height: 600)
    var rig = Rig(width: 24, maxHeight: 250)
    var reached = false
    for offset in stride(from: 0, through: 400, by: 40) where !reached {
        reached = rig.add(Array(source[offset..<(offset + 100)])).reachedLimit
    }
    #expect(reached)
    #expect(rig.output == Array(source[0..<250]))
    #expect(rig.stitcher.outputHeight == 250)
}

@Test func stillFrameKeepsFirstFrame() {
    let source = page(width: 24, height: 600)
    var rig = Rig(width: 24)
    rig.add(Array(source[0..<100])); rig.add(Array(source[0..<100]))
    #expect(rig.stitcher.isStill)
    #expect(rig.output == Array(source[0..<100]))
}

/// 白地に短い文字が等間隔に並ぶ行。文字の間隔と位置は行ごとに違うが、行の高さと間は等しい。
/// 理由: 行の並びまで周期的なページは、どのずれでも同じに見えて区別できないため。
private func periodicPage(width: Int, height: Int, period: Int) -> [[UInt8]] {
    var state: UInt64 = 5
    func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
    let lines = (0...(height / period)).map { _ in (offset: next(29), spacing: 17 + next(13)) }
    return (0..<height).map { row in
        let line = lines[row / period]
        guard row % period < 8 else { return [UInt8](repeating: 255, count: width) }
        return (0..<width).map { column in (column + line.offset) % line.spacing < 4 ? 30 : 255 }
    }
}

/// 白地の多い画面でも、重なりが無ければ一致と見なさない。
private func sparsePage(width: Int, height: Int) -> [[UInt8]] {
    var rows = [[UInt8]](repeating: [UInt8](repeating: 255, count: width), count: height)
    var state: UInt64 = 3
    for line in stride(from: 10, to: height - 10, by: 40) {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let x = Int((state >> 33) % UInt64(width - 12))
        for row in line..<(line + 6) { for column in x..<(x + 8) { rows[row][column] = 20 } }
    }
    return rows
}

@Test func periodicLinesKeepTheTrueShift() {
    let source = periodicPage(width: 120, height: 900, period: 24)
    var rig = Rig(width: 120)
    for offset in [0, 120, 240] { rig.add(Array(source[offset..<(offset + 240)])) }
    #expect(rig.output == Array(source[0..<480]))
}

@Test func sparseFramesWithoutOverlapAreLost() {
    let source = sparsePage(width: 120, height: 1200)
    let reference = ScrollLuma(width: 120, height: 200, values: Array(source[0..<200]).flatMap { $0 })
    let far = ScrollLuma(width: 120, height: 200, values: Array(source[600..<800]).flatMap { $0 })
    #expect(ScrollMatcher.shift(reference, far, top: 0, bottom: 0, hint: 0) == .lost)
    let near = ScrollLuma(width: 120, height: 200, values: Array(source[90..<290]).flatMap { $0 })
    #expect(ScrollMatcher.shift(reference, near, top: 0, bottom: 0, hint: 0) == .shift(90))
}

@Test func tallStickyHeaderStillMatches() {
    let source = page(width: 24, height: 600)
    let header = page(width: 24, height: 100, seed: 17)
    var rig = Rig(width: 24)
    var offset = 0
    for step in [0, 20, 20, 30] {
        offset += step
        rig.add(header + Array(source[offset..<(offset + 140)]))
    }
    #expect(!rig.stitcher.lost)
    #expect(rig.output == header + Array(source[0..<(offset + 140)]))
}

@Test func periodicLinesOnTallFrameKeepTheTrueShift() {
    let source = periodicPage(width: 160, height: 3000, period: 24)
    var rig = Rig(width: 160)
    for offset in [0, 600, 1200] { rig.add(Array(source[offset..<(offset + 1200)])) }
    #expect(!rig.stitcher.lost)
    #expect(rig.output == Array(source[0..<2400]))
}

/// 暗い固定のサイドバーと、白地に短い文字が並ぶ本文。
private func withSidebar(_ rows: [[UInt8]], sidebar: [[UInt8]]) -> [[UInt8]] {
    zip(sidebar, rows).map { $0 + $1 }
}

@Test func fixedSidebarDoesNotHideMismatchOrShift() {
    let body = sparsePage(width: 120, height: 1600)
    let sidebar = page(width: 40, height: 300, seed: 23).map { $0.map { $0 / 4 } }
    var rig = Rig(width: 160)
    rig.add(withSidebar(Array(body[0..<300]), sidebar: sidebar))
    rig.add(withSidebar(Array(body[30..<330]), sidebar: sidebar))
    #expect(rig.stitcher.outputHeight == 330)
    // サイドバーの40列は照合から外れる。本文の白い余白の列も外れる。
    #expect(rig.stitcher.columns?.contains { $0 < 40 } == false)
    let jump = rig.add(withSidebar(Array(body[630..<930]), sidebar: sidebar))
    #expect(jump.lost)
    #expect(rig.stitcher.outputHeight == 330)
}

/// 横幅いっぱいが同じ色の行が、色を変えながら続く画面。
@Test func horizontallyUniformBandsStillMatch() {
    let source: [[UInt8]] = (0..<900).map { row in [UInt8](repeating: UInt8((row / 30 * 37) % 200 + 20), count: 24) }
    var rig = Rig(width: 24)
    for offset in [0, 40, 95] { rig.add(Array(source[offset..<(offset + 200)])) }
    #expect(rig.output == Array(source[0..<295]))
}

@Test func mostlyFixedHeaderStillMatchesShortBody() {
    let source = page(width: 24, height: 600)
    let header = page(width: 24, height: 220, seed: 29)
    var rig = Rig(width: 24)
    rig.add(header + Array(source[0..<20]))
    rig.add(header + Array(source[5..<25]))
    #expect(rig.stitcher.header == 220)
    #expect(rig.output == header + Array(source[0..<25]))
}

/// ページの前半は左寄せ、300行目からは右へ寄せた本文。最初は余白だった右の列に、後から中身が出る。
@Test func contentMovingIntoFormerMarginKeepsStitching() {
    let left = sparsePage(width: 60, height: 300), right = sparsePage(width: 60, height: 500)
    let blank = [UInt8](repeating: 255, count: 60)
    let source = left.map { $0 + blank } + right.map { blank + $0 }
    var rig = Rig(width: 120)
    var offset = 0
    while offset + 100 <= 700 {
        rig.add(Array(source[offset..<(offset + 100)]))
        offset += 20
    }
    #expect(!rig.stitcher.lost)
    #expect(rig.output == Array(source[0..<(offset - 20 + 100)]))
}

/// 区間の平均が同じになる4種類の文字の行を、決まった周期なしに並べる。
@Test func fewLineKindsInIrregularOrderKeepTheTrueShift() {
    var state: UInt64 = 9
    func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
    let kinds = (0..<4).map { kind in (0..<160).map { column -> UInt8 in (column + kind * 2) % 10 < 5 ? 30 : 255 } }
    let blank = [UInt8](repeating: 255, count: 160)
    var source: [[UInt8]] = []
    while source.count < 2400 {
        let kind = kinds[next(4)]
        source += [[UInt8]](repeating: kind, count: 8) + [[UInt8]](repeating: blank, count: 16)
    }
    var rig = Rig(width: 160)
    for offset in [0, 600, 1200] { rig.add(Array(source[offset..<(offset + 1200)])) }
    #expect(!rig.stitcher.lost)
    #expect(rig.output == Array(source[0..<2400]))
}

@Test func repeatedFrameWithSidebarDoesNotGrow() {
    let body = sparsePage(width: 120, height: 1600)
    let sidebar = page(width: 40, height: 300, seed: 23).map { $0.map { $0 / 4 } }
    var rig = Rig(width: 160)
    rig.add(withSidebar(Array(body[0..<300]), sidebar: sidebar))
    let moved = withSidebar(Array(body[30..<330]), sidebar: sidebar)
    rig.add(moved)
    let once = rig.output
    for _ in 0..<3 { rig.add(moved) }
    #expect(rig.stitcher.outputHeight == 330)
    #expect(rig.output == once)
}

/// 広い余白の中に、3列だけの細い本文がある画面。
@Test func narrowContentInWideMarginStillStitches() {
    let narrow = page(width: 3, height: 400)
    let source = narrow.map { [UInt8](repeating: 255, count: 80) + $0 + [UInt8](repeating: 255, count: 77) }
    var rig = Rig(width: 160)
    for offset in [0, 20, 45] { rig.add(Array(source[offset..<(offset + 100)])) }
    #expect(rig.output == Array(source[0..<145]))
}

@Test func nearTiesNeverPickAboveLimit() {
    #expect(ScrollMatcher.choose([(40, 0.35), (0, 0.5)], hint: 0) == .shift(40))
}

@Test func retryWithoutMatchKeepsLost() {
    let source = page(width: 24, height: 600)
    let reference = ScrollLuma(width: 24, height: 13, values: Array(source[0..<13]).flatMap { $0 })
    let other = ScrollLuma(width: 24, height: 13, values: Array(source[300..<313]).flatMap { $0 })
    #expect(ScrollMatcher.shift(reference, other, top: 0, bottom: 0, hint: 0) == .lost)
}

@Test func firstFrameIsCutAtLimit() {
    let source = page(width: 24, height: 600)
    var rig = Rig(width: 24, maxHeight: 100)
    #expect(rig.add(Array(source[0..<240])).reachedLimit)
    #expect(rig.output == Array(source[0..<100]))
    #expect(rig.stitcher.outputHeight == 100)
}

@Test func flatFramesDoNotDecideMovement() {
    let flat = [[UInt8]](repeating: [UInt8](repeating: 250, count: 24), count: 100)
    #expect(ScrollMatcher.shift(ScrollLuma(width: 24, height: 100, values: flat.flatMap { $0 }),
                                ScrollLuma(width: 24, height: 100, values: flat.flatMap { $0 }), top: 0, bottom: 0, hint: 0) == .unknown)
}

@Test func toleratesSmallDifferencesFromDownscaling() {
    let source = page(width: 24, height: 300)
    let blurred = source.map { row in row.map { UInt8(min(255, Int($0) + 3)) } }
    let reference = ScrollLuma(width: 24, height: 100, values: Array(source[0..<100]).flatMap { $0 })
    let current = ScrollLuma(width: 24, height: 100, values: Array(blurred[37..<137]).flatMap { $0 })
    #expect(ScrollMatcher.shift(reference, current, top: 0, bottom: 0, hint: 0) == .shift(37))
}

@Test func scrollOutputCyclesWithTabAndStreams() {
    var state = CaptureState()
    #expect(state.output == .image)
    _ = state.key(48, hasLast: false); #expect(state.output == .video)
    _ = state.key(48, hasLast: false); #expect(state.output == .scroll)
    #expect(state.output.streams)
    // 音と容量は動画だけ。
    #expect(!state.handles(0) && !state.handles(1))
    _ = state.key(48, hasLast: false); #expect(state.output == .image)
}

@Test func scrollBadgeShowsHeightAndLimit() {
    #expect(ScrollPresentation.badge(height: 4820) == "↓ 4,820 / 16,383px")
    #expect(ScrollPresentation.status(height: 980) == "■ ↓ 980px")
    let items = OverlayPresentation.items(output: .scroll, target: .area, hasLast: false)
    #expect(items.filter(\.selected).map(\.title) == ["スクロール", "範囲"])
    #expect(items.filter(\.recording).isEmpty)
}

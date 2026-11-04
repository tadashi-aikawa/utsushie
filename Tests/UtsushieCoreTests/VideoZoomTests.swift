import Testing
import CoreGraphics
import UtsushieCore

private let size = CGSize(width: 1600, height: 900)

@Test func zoomRectExpandsToOutputAspectAroundCenterAndStaysInsideRecording() {
    // 縦長のドラッグは横へ広げる。
    #expect(VideoZoom.fitted(CGRect(x: 700, y: 300, width: 100, height: 270), size: size) == CGRect(x: 510, y: 300, width: 480, height: 270))
    // 端をはみ出す分は押し戻す。逆向きのドラッグも同じ。
    #expect(VideoZoom.fitted(CGRect(x: 1600, y: 900, width: -320, height: -90), size: size) == CGRect(x: 1280, y: 720, width: 320, height: 180))
    // 寄りすぎは1/8で止める。
    #expect(VideoZoom.fitted(CGRect(x: 800, y: 450, width: 4, height: 1), size: size)?.width == 200)
    // 全体と同じなら寄らない。
    #expect(VideoZoom.fitted(CGRect(x: 0, y: 0, width: 1600, height: 100), size: size) == nil)
    #expect(VideoZoom.fitted(.zero, size: size) == nil)
}

@Test func zoomRectKeepsPressedCornerAndGrowsTowardCursorAtOutputAspect() {
    // 右下へ。幅と高さのうち比に対して大きいほうへ合わせる。
    #expect(VideoZoom.anchored(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 200), size: size)
            == CGRect(x: 100, y: 100, width: 400, height: 225))
    // 左上へ。押した点が右下の角になる。
    let up = VideoZoom.anchored(from: CGPoint(x: 1000, y: 600), to: CGPoint(x: 900, y: 300), size: size)
    #expect(up.map { abs($0.maxX - 1000) < 1e-9 && $0.maxY == 600 && $0.height == 300 } == true)
    // 元録画の外へ出る分は、起点を動かさずにカーソル側で止める。
    #expect(VideoZoom.anchored(from: CGPoint(x: 1200, y: 100), to: CGPoint(x: 1700, y: 500), size: size)
            == CGRect(x: 1200, y: 100, width: 400, height: 225))
    // 最小寸法は1/8。起点から収まらないときだけ内側へ押し戻す。
    #expect(VideoZoom.anchored(from: CGPoint(x: 800, y: 450), to: CGPoint(x: 805, y: 451), size: size)
            == CGRect(x: 800, y: 450, width: 200, height: 112.5))
    #expect(VideoZoom.anchored(from: CGPoint(x: 1550, y: 450), to: CGPoint(x: 1560, y: 455), size: size)
            == CGRect(x: 1400, y: 450, width: 200, height: 112.5))
    // 全体と同じなら寄らない。
    #expect(VideoZoom.anchored(from: .zero, to: CGPoint(x: 1600, y: 900), size: size) == nil)
    // ドラッグ中の枠は最小寸法を当てず、カーソルに沿って小さいまま広げる。端の制限と縦横比は同じ。
    #expect(VideoZoom.anchored(from: CGPoint(x: 800, y: 450), to: CGPoint(x: 816, y: 451), size: size, limitsScale: false)
            == CGRect(x: 800, y: 450, width: 16, height: 9))
    #expect(VideoZoom.anchored(from: CGPoint(x: 1550, y: 450), to: CGPoint(x: 1700, y: 455), size: size, limitsScale: false)
            == CGRect(x: 1550, y: 450, width: 50, height: 28.125))
    #expect(VideoZoom.anchored(from: CGPoint(x: 800, y: 450), to: CGPoint(x: 800, y: 450), size: size, limitsScale: false) == nil)
}

@Test func zoomMoveKeepsSizeAndStopsAtRecordingEdges() throws {
    let rect = CGRect(x: 400, y: 200, width: 800, height: 450)
    #expect(VideoZoom.moved(rect, by: CGPoint(x: 100, y: -50), size: size) == CGRect(x: 500, y: 150, width: 800, height: 450))
    #expect(VideoZoom.moved(rect, by: CGPoint(x: 5000, y: 5000), size: size) == CGRect(x: 800, y: 450, width: 800, height: 450))
    #expect(VideoZoom.moved(rect, by: CGPoint(x: -5000, y: -5000), size: size) == CGRect(x: 0, y: 0, width: 800, height: 450))
    #expect(VideoZoom.moved(rect, by: CGPoint(x: CGFloat.nan, y: 0), size: size) == rect)
    var document = VideoEditDocument(duration: 10, zooms: [VideoZoom(range: .init(2, 4), rect: rect)])
    var history = VideoEditHistory(document)
    document.moveZoom(document.zooms[0].id, by: CGPoint(x: -1000, y: 10), size: size); history.commit(document)
    #expect(history.document.zooms[0].rect == CGRect(x: 0, y: 210, width: 800, height: 450))
    #expect(history.document.zooms[0].range == .init(2, 4))
    history.undo(); #expect(history.document.zooms[0].rect == rect)
}

@Test func zoomGrabIsDecidedAtMouseDownAndCursorShowsHandOnlyWithOption() {
    // ⌥で矩形の中なら移動。⌥なしはツール中だけ描き直し。ツール外の⌥なしは何もしない。
    #expect(VideoZoom.grab(tool: true, option: true, grip: .move, insideMovable: true, insideVideo: true) == .move)
    #expect(VideoZoom.grab(tool: true, option: false, grip: .move, insideMovable: true, insideVideo: true) == .draw)
    #expect(VideoZoom.grab(tool: true, option: true, grip: nil, insideMovable: false, insideVideo: true) == .draw)
    #expect(VideoZoom.grab(tool: false, option: true, grip: .move, insideMovable: true, insideVideo: true) == .move)
    #expect(VideoZoom.grab(tool: false, option: false, grip: .move, insideMovable: true, insideVideo: true) == .none)
    #expect(VideoZoom.grab(tool: true, option: true, grip: nil, insideMovable: true, insideVideo: false) == .none)
    #expect(VideoZoom.cursor(tool: false, option: true, grip: .move, insideMovable: true, insideVideo: true) == .openHand)
    #expect(VideoZoom.cursor(tool: false, option: false, grip: .move, insideMovable: true, insideVideo: true) == .arrow)
    #expect(VideoZoom.cursor(tool: true, option: false, grip: .move, insideMovable: true, insideVideo: true) == .crosshair)
    #expect(VideoZoom.cursor(tool: true, option: true, grip: nil, insideMovable: false, insideVideo: true) == .crosshair)
    // つかんだ後は⌥を離しても握った手。
    #expect(VideoZoom.cursor(tool: true, option: false, grip: nil, insideMovable: false, insideVideo: false, active: .move) == .closedHand)
}

@Test func zoomEdgeBandAlwaysResizesInToolAndOptionMovesOnlyInterior() {
    // ツール中は縁を常にリサイズにし、⌥でも移動を優先しない。外側の縁は映像の外でもつかめる。
    #expect(VideoZoom.grab(tool: true, option: true, grip: .resize([.maxX]), insideMovable: true, insideVideo: true) == .resize([.maxX]))
    #expect(VideoZoom.grab(tool: true, option: false, grip: .resize([.minX, .maxY]), insideMovable: false, insideVideo: false)
            == .resize([.minX, .maxY]))
    // ツール外は従来どおり⌥の移動だけ。
    #expect(VideoZoom.grab(tool: false, option: true, grip: .resize([.maxX]), insideMovable: true, insideVideo: true) == .move)
    #expect(VideoZoom.grab(tool: false, option: false, grip: .resize([.maxX]), insideMovable: true, insideVideo: true) == .none)
    #expect(VideoZoom.cursor(tool: true, option: false, grip: .resize([.maxX, .maxY]), insideMovable: true, insideVideo: true)
            == .resize([.maxX, .maxY]))
    #expect(VideoZoom.cursor(tool: false, option: true, grip: .resize([.maxX]), insideMovable: true, insideVideo: true) == .openHand)
    #expect(VideoZoom.cursor(tool: true, option: false, grip: nil, insideMovable: false, insideVideo: true, active: .resize([.minY]))
            == .resize([.minY]))
    // 表示の辺は上下だけ入れ替えて元録画の辺にする。
    #expect(LastFrameEdges([.minX, .minY]).flippedVertically == [.minX, .maxY])
    #expect(LastFrameEdges([.maxX, .maxY]).flippedVertically == [.maxX, .minY])
    #expect(LastFrameEdges([.maxX]).flippedVertically == [.maxX])
}

@Test func zoomResizeKeepsAspectFixesOppositeSideAndStaysInsideRecording() {
    let rect = CGRect(x: 400, y: 200, width: 800, height: 450)
    func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1e-6 && abs(a.minY - b.minY) < 1e-6 && abs(a.width - b.width) < 1e-6 && abs(a.height - b.height) < 1e-6
    }
    // 角: 反対の角を固定し、比に対して大きいほうへ合わせる。
    #expect(close(VideoZoom.resized(rect, edges: [.maxX, .maxY], by: CGPoint(x: 160, y: 0), size: size), CGRect(x: 400, y: 200, width: 960, height: 540)))
    #expect(close(VideoZoom.resized(rect, edges: [.minX, .minY], by: CGPoint(x: 100, y: 300), size: size),
                  CGRect(x: 500, y: 256.25, width: 700, height: 393.75)))
    // 辺: 反対の辺を固定し、他方の軸は中心を保つ。他方の軸の移動量は使わない。
    #expect(close(VideoZoom.resized(rect, edges: [.maxX], by: CGPoint(x: -400, y: 999), size: size), CGRect(x: 400, y: 312.5, width: 400, height: 225)))
    let top = VideoZoom.resized(rect, edges: [.minY], by: CGPoint(x: 0, y: -100), size: size)
    #expect(abs(top.maxY - 650) < 1e-6 && abs(top.height - 550) < 1e-6 && abs(top.midX - 800) < 1e-6)
    // 1/8の最小寸法で止め、裏返さない。
    #expect(close(VideoZoom.resized(rect, edges: [.maxX, .maxY], by: CGPoint(x: -2000, y: -2000), size: size), CGRect(x: 400, y: 200, width: 200, height: 112.5)))
    // 固定した辺から元録画の端までで止める。
    #expect(close(VideoZoom.resized(rect, edges: [.maxX], by: CGPoint(x: 5000, y: 0), size: size), CGRect(x: 400, y: 87.5, width: 1200, height: 675)))
    // 中心を保つ軸がはみ出す分は内側へ押し戻す。
    #expect(close(VideoZoom.resized(CGRect(x: 400, y: 800, width: 160, height: 90), edges: [.maxX], by: CGPoint(x: 320, y: 0), size: size),
                  CGRect(x: 400, y: 630, width: 480, height: 270)))
    // ドキュメントでは離したときの1回の履歴。
    var document = VideoEditDocument(duration: 10, zooms: [VideoZoom(range: .init(2, 4), rect: rect)])
    var history = VideoEditHistory(document)
    document.resizeZoom(document.zooms[0].id, edges: [.maxX, .maxY], by: CGPoint(x: 160, y: 0), size: size); history.commit(document)
    #expect(close(history.document.zooms[0].rect, CGRect(x: 400, y: 200, width: 960, height: 540)))
    history.undo(); #expect(history.document.zooms[0].rect == rect)
}

@Test func zoomEaseIsPerRangeClampedToTenthsAndShortensForShortRanges() throws {
    let rect = CGRect(x: 800, y: 450, width: 800, height: 450)
    #expect(VideoZoom.clampedEase(1.25) == 1.3 && VideoZoom.clampedEase(2.4) == 2 && VideoZoom.clampedEase(-1) == 0)
    #expect(VideoZoom.clampedEase(.nan) == VideoZoom.defaultEase)
    let slow = VideoZoom(range: .init(2, 5), rect: rect, ease: 1)
    #expect(slow.ramp == 1 && abs(slow.progress(at: 2.5) - 0.5) < 1e-9 && slow.progress(at: 3) == 1)
    // 区間が短いときは半分ずつ。
    #expect(VideoZoom(range: .init(0, 1), rect: rect, ease: 2).ramp == 0.5)
    // 0秒は区間の中で常に寄りきる。
    let instant = VideoZoom(range: .init(2, 5), rect: rect, ease: 0)
    #expect(instant.crop(at: 2, size: size) == rect && instant.crop(at: 4.99, size: size) == rect && instant.crop(at: 5, size: size) == nil)
    // ドキュメントの区間ごとに持ち、書き出しの分け方へ反映する。
    var document = VideoEditDocument(duration: 6, zooms: [VideoZoom(range: .init(2, 5), rect: rect)])
    var history = VideoEditHistory(document)
    let id = document.zooms[0].id
    document.setZoomEase(id, seconds: 0); history.commit(document)
    #expect(VideoExportPlan(document: history.document).zoomPieces(source: .init(1, 6), fps: 30, size: size).map(\.crop) == [nil, rect, nil])
    document.setZoomEase(id, seconds: 1); history.commit(document)
    let pieces = VideoExportPlan(document: history.document).zoomPieces(source: .init(1, 6), fps: 30, size: size)
    #expect(pieces.filter { $0.crop != nil && $0.crop != rect && $0.source.start < 3 }.count == 29)
    history.undo(); #expect(history.document.zooms[0].ease == 0)
    history.undo(); #expect(history.document.zooms[0].ease == 0.3)
}

@Test func zoomIsPlacedAroundPlayheadInsideKeptRangeAndNeverOverlaps() throws {
    var document = VideoEditDocument(duration: 10, kept: [.init(1, 4), .init(6, 10)])
    let rect = CGRect(x: 0, y: 0, width: 800, height: 450)
    let added = document.addZoom(drag: rect, size: size, at: 3.5)
    let first = try #require(added)
    #expect(document.zooms.map(\.range) == [.init(2, 4)])
    // 切った範囲の中では近い残す範囲へ置く。
    _ = document.addZoom(drag: rect, size: size, at: 5.5)
    #expect(document.zooms.map(\.range) == [.init(2, 4), .init(6, 8)])
    // 前後の区間の間へ収める。
    _ = document.addZoom(drag: rect, size: size, at: 9.5)
    #expect(document.zooms.map(\.range) == [.init(2, 4), .init(6, 8), .init(8, 10)])
    // 2秒に足りない隙間は、その長さで置く。
    _ = document.addZoom(drag: rect, size: size, at: 1.95)
    #expect(document.zooms.map(\.range) == [.init(1, 2), .init(2, 4), .init(6, 8), .init(8, 10)])
    // 隙間が無ければ置かない。
    #expect(document.addZoom(drag: rect, size: size, at: 5) == nil)
    // 区間の中で描き直すと矩形だけ変える。
    let moved = CGRect(x: 800, y: 450, width: 800, height: 450)
    #expect(document.addZoom(drag: moved, size: size, at: 3) == first)
    #expect(document.zooms[1].rect == moved && document.zooms.count == 4)
    // 端の伸縮は隣の区間と最短の長さで止める。
    #expect(document.moveZoomBoundary(index: 2, start: false, to: 9) == 8)
    #expect(document.moveZoomBoundary(index: 2, start: true, to: 1) == 4)
    let moved2 = document.moveZoomBoundary(index: 2, start: true, to: 9)
    let shrunk = try #require(moved2)
    #expect(abs(shrunk - 7.9) < 1e-9)
    #expect(document.moveZoomBoundary(index: 0, start: true, to: -3) == 0)
    #expect(document.moveZoomBoundary(index: 5, start: true, to: 1) == nil)
    document.removeZoom(first)
    #expect(document.zooms.count == 3 && document.zooms.allSatisfy { $0.id != first })
    // 重なる区間は初期化でも受け付けない。
    let overlapping = VideoEditDocument(duration: 10, zooms: [
        VideoZoom(range: .init(1, 3), rect: rect), VideoZoom(range: .init(2, 4), rect: rect), VideoZoom(range: .init(9, 11), rect: rect)])
    #expect(overlapping.zooms.map(\.range) == [.init(1, 3)])
}

@Test func zoomEasesInAndOutOverRampAndShortensRampForShortRanges() throws {
    let zoom = VideoZoom(range: .init(2, 5), rect: CGRect(x: 800, y: 450, width: 800, height: 450))
    #expect(zoom.scale(size: size) == 2)
    #expect(zoom.progress(at: 1.99) == 0 && zoom.progress(at: 5) == 0)
    #expect(zoom.crop(at: 2, size: size) == nil)
    #expect(abs(zoom.progress(at: 2.15) - 0.5) < 1e-9)
    #expect(abs(zoom.progress(at: 2.075) - 0.15625) < 1e-9)
    #expect(zoom.progress(at: 3) == 1)
    #expect(abs(zoom.progress(at: 4.85) - 0.5) < 1e-9)
    let half = try #require(zoom.crop(at: 2.15, size: size))
    #expect(abs(half.minX - 400) < 1e-6 && abs(half.minY - 225) < 1e-6 && abs(half.width - 1200) < 1e-6 && abs(half.height - 675) < 1e-6)
    #expect(zoom.crop(at: 3, size: size) == zoom.rect)
    // 0.6秒未満なら半分ずつ。
    let short = VideoZoom(range: .init(0, 0.4), rect: zoom.rect)
    #expect(short.ramp == 0.2)
    #expect(short.progress(at: 0.1) == 0.5 && short.progress(at: 0.2) == 1)
}

@Test func exportPlanCarriesZoomsAndSplitsHeldFramesDuringRamps() throws {
    var document = VideoEditDocument(duration: 6, kept: [.init(0, 2), .init(3, 6)])
    let rect = CGRect(x: 800, y: 450, width: 800, height: 450)
    _ = document.addZoom(drag: rect, size: size, at: 4.5)
    #expect(document.zooms.map(\.range) == [.init(3.5, 5.5)])
    #expect(document.completionText == "完了で 5.0秒に切る ・ ズーム1区間を付ける")
    let plan = VideoExportPlan(document: document)
    #expect(plan.zooms == document.zooms)
    #expect(plan.zoomCrop(atSource: 1, size: size) == nil)
    #expect(plan.zoomCrop(atSource: 4.5, size: size) == rect)
    // 外は1枚、補間中は1/30秒ごと、寄りきった間は1枚。
    let pieces = plan.zoomPieces(source: .init(3, 6), fps: 30, size: size)
    let head = try #require(pieces.first)
    #expect(head.crop == nil && head.source.start == 3 && abs(head.source.end - 3.5 - 1 / 30.0) < 1e-9)
    let rampIn = pieces.filter { $0.source.start >= 3.5 && $0.source.end <= 3.8 + 1e-9 && $0.crop != nil && $0.crop != rect }
    #expect(rampIn.count == 8)
    #expect(pieces.contains { $0.crop == rect && abs($0.source.start - 3.8) < 1e-9 && abs($0.source.end - 5.2 - 1 / 30.0) < 1e-9 })
    #expect(pieces.last?.crop == nil && pieces.last?.source.end == 6)
    #expect(zip(pieces, pieces.dropFirst()).allSatisfy { $0.source.end == $1.source.start })
    // 区間がなければ分けない。
    #expect(VideoExportPlan(document: VideoEditDocument(duration: 6)).zoomPieces(source: .init(1, 2), fps: 30, size: size)
            == [VideoZoomPiece(source: .init(1, 2), crop: nil)])
}

@Test func zoomOutputPiecesDropZeroLengthTicksAtRampBoundary() throws {
    let rect = CGRect(x: 800, y: 450, width: 800, height: 450)
    // 補間の終わりが1.000001秒で、1.0秒のコマの頭をわずかに切る。
    let document = VideoEditDocument(duration: 3, zooms: [VideoZoom(range: .init(0.700001, 2), rect: rect)])
    let plan = VideoExportPlan(document: document)
    let frame = VideoRange(1, 62000 / 60000.0)
    let raw = plan.zoomPieces(source: frame, fps: 30, size: size)
    #expect(raw.count == 2 && VideoExportPlan.tick(raw[0].source.start) == VideoExportPlan.tick(raw[0].source.end))
    let pieces = plan.zoomOutputPieces(segment: try #require(plan.segments.first), source: frame, fps: 30, size: size)
    #expect(pieces == [VideoZoomOutputPiece(start: 60000, end: 62000, crop: rect)])
    // コマ全体を通して、PTSは単調に増え、長さは0にならない。
    var all: [VideoZoomOutputPiece] = []
    for index in 0..<90 {
        all += plan.zoomOutputPieces(segment: plan.segments[0], source: .init(Double(index) / 30, Double(index + 1) / 30), fps: 30, size: size)
    }
    #expect(all.allSatisfy { $0.end > $0.start })
    #expect(zip(all, all.dropFirst()).allSatisfy { $0.end == $1.start })
}

@Test func repeatedZoomFromCutDoesNotOverlapZoomAtClampedPosition() {
    var document = VideoEditDocument(duration: 10, kept: [.init(0, 4), .init(6, 10)])
    let rect = CGRect(x: 0, y: 0, width: 800, height: 450)
    #expect(document.addZoom(drag: rect, size: size, at: 5.5) != nil)
    #expect(document.addZoom(drag: rect, size: size, at: 5.5) == nil)
    #expect(document.zooms.map(\.range) == [.init(6, 8)])
    // 再生位置が区間の中なら従来どおり描き直す。
    #expect(document.addZoom(drag: rect.offsetBy(dx: 100, dy: 0), size: size, at: 7) == document.zooms[0].id)
    #expect(document.zooms.count == 1 && document.zooms[0].rect.minX == 100)
}

@Test func transitionZoomInterpolatesBetweenBothEndsOfCut() throws {
    let rect = CGRect(x: 800, y: 450, width: 800, height: 450)
    var document = VideoEditDocument(duration: 10, kept: [.init(0, 4), .init(6, 10)],
        zooms: [VideoZoom(range: .init(2, 5), rect: rect)])
    document.setTransition(for: .init(4, 6), kind: .dissolve)
    let plan = VideoExportPlan(document: document)
    let junction = try #require(plan.junctions.first)
    #expect(plan.transitionCrop(junction, progress: 0, size: size) == rect)
    #expect(plan.transitionCrop(junction, progress: 0.5, size: size) == CGRect(x: 400, y: 225, width: 1200, height: 675))
    #expect(plan.transitionCrop(junction, progress: 1, size: size) == CGRect(origin: .zero, size: size))
    let plain = VideoExportPlan(document: VideoEditDocument(duration: 10, kept: [.init(0, 4), .init(6, 10)]))
    #expect(plain.transitionCrop(try #require(plain.junctions.first), progress: 0.5, size: size) == nil)
}

@Test func zoomLaneTakesPriorityOverKeptBoundaryAndSelectsRange() {
    let rect = CGRect(x: 800, y: 450, width: 800, height: 450)
    let document = VideoEditDocument(duration: 10, kept: [.init(1, 9)], zooms: [VideoZoom(range: .init(1, 4), rect: rect)])
    #expect(VideoTimelineGesture.hit(x: 101, y: 46, width: 1000, document: document) == .zoomBoundary(index: 0, start: true))
    #expect(VideoTimelineGesture.hit(x: 101, y: 20, width: 1000, document: document) == .boundary(segment: 0, start: true))
    #expect(VideoTimelineGesture.hit(x: 396, y: 46, width: 1000, document: document) == .zoomBoundary(index: 0, start: false))
    #expect(VideoTimelineGesture.hit(x: 250, y: 46, width: 1000, document: document) == .zoom(index: 0))
    #expect(VideoTimelineGesture.hit(x: 600, y: 46, width: 1000, document: document) == .strip)
}

@Test func zoomEditsShareHistory() throws {
    let initial = VideoEditDocument(duration: 10)
    var history = VideoEditHistory(initial)
    var document = initial
    let added = document.addZoom(drag: CGRect(x: 0, y: 0, width: 400, height: 225), size: size, at: 5)
    let id = try #require(added)
    history.commit(document)
    document.moveZoomBoundary(index: 0, start: false, to: 7); history.commit(document)
    document.removeZoom(id); history.commit(document)
    history.undo(); #expect(history.document.zooms.map(\.range) == [.init(4, 7)])
    history.undo(); #expect(history.document.zooms.map(\.range) == [.init(4, 6)])
    history.undo(); #expect(history.document == initial)
    history.redo(); #expect(history.document.zooms.count == 1)
}

@Test func zoomRangeMovesKeepingLengthAndStopsAtNeighborsAndEnds() throws {
    var document = VideoEditDocument(duration: 10)
    document.addZoom(drag: CGRect(x: 0, y: 0, width: 400, height: 225), size: size, at: 2)
    document.addZoom(drag: CGRect(x: 0, y: 0, width: 400, height: 225), size: size, at: 8)
    #expect(document.zooms.map(\.range) == [.init(1, 3), .init(7, 9)])
    #expect(document.moveZoomRange(index: 0, by: 1.5) == 2.5)
    #expect(document.zooms.map(\.range) == [.init(2.5, 4.5), .init(7, 9)])
    // 隣の区間と録画の両端で止め、長さは変えない。
    #expect(document.moveZoomRange(index: 0, by: 10) == 5)
    #expect(document.zooms[0].range == .init(5, 7))
    #expect(document.moveZoomRange(index: 0, by: -10) == 0)
    #expect(document.moveZoomRange(index: 1, by: 5) == 8)
    #expect(document.zooms.map(\.range) == [.init(0, 2), .init(8, 10)])
    #expect(document.moveZoomRange(index: 2, by: 1) == nil && document.moveZoomRange(index: 0, by: .nan) == nil)
}

@Test func zoomPlacedOnSelectedRangeIsClippedAndRejectsOverlapOrTooShort() throws {
    var document = VideoEditDocument(duration: 10)
    let rect = CGRect(x: 0, y: 0, width: 400, height: 225)
    // 2秒の目安ではなく、選んだ範囲そのものに置く。録画の外は切り詰める。
    let first = document.addZoom(drag: rect, size: size, range: .init(1, 6.5))
    #expect(first != nil && document.zooms.map(\.range) == [.init(1, 6.5)])
    #expect(document.addZoom(drag: rect, size: size, range: .init(8, 12)) != nil)
    #expect(document.zooms.map(\.range) == [.init(1, 6.5), .init(8, 10)])
    // ほかの区間と重なる範囲と、最短の長さに足りない範囲には置かない。
    #expect(document.addZoom(drag: rect, size: size, range: .init(6, 7)) == nil)
    #expect(document.addZoom(drag: rect, size: size, range: .init(7, 7.05)) == nil)
    #expect(document.addZoom(drag: rect, size: size, range: .init(6.5, 8)) != nil)
    #expect(document.zooms.map(\.range) == [.init(1, 6.5), .init(6.5, 8), .init(8, 10)])
}

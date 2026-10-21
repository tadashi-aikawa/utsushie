import Foundation
import CoreGraphics
import Testing
@testable import UtsushieCore

private let full = CGSize(width: 1600, height: 1200)

@Test func cropDropsOnlyFullyOutsideAnnotationsAndMovesTheRestIntoNewImage() throws {
    let arrow = Annotation(tool: .arrow, start: CGPoint(x: 40, y: 1100), end: CGPoint(x: 200, y: 1000))
    let frame = Annotation(tool: .rectangle, start: CGPoint(x: 480, y: 200), end: CGPoint(x: 880, y: 400))
    let text = Annotation(tool: .text, start: CGPoint(x: 1000, y: 120), end: CGPoint(x: 1200, y: 200), text: "文字")
    let mosaic = Annotation(tool: .mosaic, start: CGPoint(x: 720, y: 400), end: CGPoint(x: 960, y: 800))
    let spot = Annotation(tool: .spotlight, start: CGPoint(x: 1400, y: 500), end: CGPoint(x: 1590, y: 700))
    let number = Annotation(tool: .number, start: CGPoint(x: 1300, y: 300), leaderTarget: CGPoint(x: 1250, y: 250))
    let document = AnnotationDocument(annotations: [arrow, frame, text, mosaic, spot, number])

    let cropped = try #require(document.cropping(to: CGRect(x: 800, y: 0, width: 800, height: 600), imageSize: full))
    let size = CGSize(width: 800, height: 600)
    #expect(cropped.crop == AnnotationCrop(rect: CGRect(x: 800, y: 0, width: 800, height: 600)))
    #expect(cropped.annotations.map(\.id) == [frame.id, text.id, mosaic.id, spot.id, number.id])
    let byID = Dictionary(uniqueKeysWithValues: cropped.annotations.map { ($0.id, $0) })
    // 中心が外の枠は余白へ出る。中の注釈は同じ見た目の位置へ写す。
    #expect(byID[frame.id]?.rect == CGRect(x: -320, y: 200, width: 400, height: 200))
    #expect(byID[text.id]?.rect == CGRect(x: 200, y: 120, width: 200, height: 80))
    #expect(byID[number.id]?.start == CGPoint(x: 500, y: 300))
    #expect(byID[number.id]?.leaderTarget == CGPoint(x: 450, y: 250))
    // モザイクは押し戻さず、はみ出た分を切る。
    #expect(byID[mosaic.id]?.rect == CGRect(x: 0, y: 400, width: 160, height: 200))
    let spotRect = try #require(byID[spot.id]?.rect)
    let inset = cropped.style().areaInset(for: .spotlight)
    #expect(spotRect.minX == 600 && spotRect.minY == 500 && abs(spotRect.maxY - (600 - inset)) < 1e-9)
    #expect(cropped.exportLayout(imageSize: size).left > 0)
}

@Test func cropKeepsCaptureScaleAndComposesWithEarlierCrop() throws {
    let text = Annotation(tool: .text, start: CGPoint(x: 1000, y: 120), end: CGPoint(x: 1200, y: 200), text: "文字")
    let document = AnnotationDocument(annotations: [text], scale: 2)
    let first = try #require(document.cropping(to: CGRect(x: 800, y: 0, width: 800, height: 600), imageSize: full))
    let second = try #require(first.cropping(to: CGRect(x: 150.4, y: 100.6, width: 300, height: 200), imageSize: CGSize(width: 800, height: 600)))
    // 範囲は整数へ広げ、元画像の座標で積み上げる。
    #expect(second.crop == AnnotationCrop(rect: CGRect(x: 950, y: 100, width: 301, height: 201)))
    #expect(second.annotations.first?.rect == CGRect(x: 50, y: 20, width: 200, height: 80))
    #expect(second.style() == document.style() && second.style() == AnnotationStyle(scale: 2))
}

@Test func cropIgnoresWholeImageAndEmptyRangeAndStaysInsideImage() throws {
    let document = AnnotationDocument()
    #expect(document.cropping(to: CGRect(origin: .zero, size: full), imageSize: full) == nil)
    #expect(document.cropping(to: CGRect(x: -100, y: -100, width: 1900, height: 1500), imageSize: full) == nil)
    #expect(document.cropping(to: CGRect(x: 2000, y: 0, width: 100, height: 100), imageSize: full) == nil)
    #expect(document.cropping(to: CGRect(x: 100, y: 100, width: 0, height: 50), imageSize: full) == nil)
    let clipped = try #require(document.cropping(to: CGRect(x: 1500, y: -20, width: 400, height: 220), imageSize: full))
    #expect(clipped.crop?.rect == CGRect(x: 1500, y: 0, width: 100, height: 200))
}

@Test func croppedHighlighterKeepsOutsidePointsAndShapeThroughLaterChanges() throws {
    let size = CGSize(width: 200, height: 300)
    let diagonal = Annotation(tool: .highlighter, start: .zero, end: CGPoint(x: 1000, y: 1000),
                              points: [.zero, CGPoint(x: 1000, y: 1000)], highlighterColor: .cyan, darkBackground: true)
    // 範囲を出て、また入る線も1本のまま残す。分けると重なりで色が二重になる。
    let loop = Annotation(tool: .highlighter, start: CGPoint(x: 450, y: 250),
                          points: [CGPoint(x: 450, y: 250), CGPoint(x: 450, y: 100), CGPoint(x: 550, y: 100), CGPoint(x: 550, y: 250)])
    let document = AnnotationDocument(annotations: [diagonal, loop])
    let cropped = try #require(document.cropping(to: CGRect(x: 400, y: 200, width: 200, height: 300), imageSize: CGSize(width: 1000, height: 1000)))
    #expect(cropped.annotations.map(\.id) == [diagonal.id, loop.id])
    let line = cropped.annotations[0], partial = cropped.annotations[1]
    #expect(line.points == [CGPoint(x: -400, y: -200), CGPoint(x: 600, y: 800)])
    #expect(partial.points.first == CGPoint(x: 50, y: 50) && partial.points[1] == CGPoint(x: 50, y: -100))

    let resized = cropped.settingSize([line.id, partial.id], size: .large, imageSize: size)
    #expect(resized.annotations.map(\.points) == [line.points, partial.points])
    #expect(resized.annotations.allSatisfy { $0.size == .large })

    // 画像より大きい線は押し戻さず、画像から完全には出さない。
    let moved = cropped.moving([line.id], by: CGPoint(x: 10, y: 0), imageSize: size)
    #expect(moved.annotations[0].points == line.points.map { CGPoint(x: $0.x + 10, y: $0.y) })
    let away = cropped.moving([line.id], by: CGPoint(x: 5000, y: 0), imageSize: size)
    #expect(away.annotations[0].rect.minX > -400 && away.annotations[0].rect.minX < 199)
    #expect(!away.intersecting(CGRect(origin: .zero, size: size), style: away.style()).isEmpty)
    // 外接矩形は重なっても、斜めの線が画像から外れる移動は止める。
    let slant = try #require(AnnotationDocument(annotations: [Annotation(tool: .highlighter, start: CGPoint(x: 100, y: 100),
        points: [CGPoint(x: 100, y: 100), CGPoint(x: 900, y: 900)])])
        .cropping(to: CGRect(x: 400, y: 400, width: 200, height: 200), imageSize: CGSize(width: 1000, height: 1000)))
    let square = CGSize(width: 200, height: 200)
    let slid = slant.moving(Set(slant.annotations.map(\.id)), by: CGPoint(x: 300, y: 0), imageSize: square)
    let squareImage = CGRect(origin: .zero, size: square)
    #expect(slid.annotations[0].points[0].x > -300 && slid.annotations[0].points[0].x < 0)
    #expect(AnnotationGeometry.highlighterShows(slid.annotations[0], in: squareImage, style: slid.style()))
    #expect(!AnnotationGeometry.highlighterShows(slid.annotations[0].translated(by: CGPoint(x: 2, y: 0)), in: squareImage,
                                                 style: slid.style()))
    // 複製を繰り返しても、線が画像から消える所までずらさない。
    let corner = try #require(AnnotationDocument(annotations: [Annotation(tool: .highlighter, start: CGPoint(x: 200, y: 999),
        points: [CGPoint(x: 200, y: 999), CGPoint(x: 999, y: 200)])])
        .cropping(to: CGRect(x: 400, y: 400, width: 200, height: 200), imageSize: CGSize(width: 1000, height: 1000)))
    var copies = corner
    var latest = Set(copies.annotations.map(\.id))
    for _ in 0..<5 { latest = copies.duplicate(latest, imageSize: square) }
    #expect(copies.annotations.count == 6)
    #expect(copies.annotations.allSatisfy { AnnotationGeometry.highlighterShows($0, in: squareImage, style: copies.style()) })
    // 画像に収まる大きさの線は、移動で形を保ったまま中へ戻す。
    let inside = cropped.moving([partial.id], by: CGPoint(x: 10, y: 0), imageSize: size).annotations[1]
    #expect(zip(inside.points, partial.points).allSatisfy { $0.x - $1.x == 10 && $0.y - $1.y == 100 })
}

@Test func highlighterVisibilityUsesFlatEndsAndRoundJoins() throws {
    let style = AnnotationStyle()
    let half = style.highlighterWidth / 2
    let pen = Annotation(tool: .highlighter, start: CGPoint(x: 40, y: 50), points: [CGPoint(x: 40, y: 50), CGPoint(x: 120, y: 50)])
    // 端は平らなので、端の先の範囲には見えない。丸い端なら半幅だけ先まで塗れていた。
    #expect(!AnnotationGeometry.highlighterShows(pen, in: CGRect(x: 125, y: 40, width: 30, height: 20), style: style))
    #expect(!AnnotationGeometry.highlighterShows(pen, in: CGRect(x: 0, y: 40, width: 39, height: 20), style: style))
    #expect(AnnotationGeometry.highlighterShows(pen, in: CGRect(x: 118, y: 40, width: 30, height: 20), style: style))
    #expect(AnnotationGeometry.highlighterShows(pen, in: CGRect(x: 60, y: 50 + half - 3, width: 10, height: 10), style: style))
    #expect(!AnnotationGeometry.highlighterShows(pen, in: CGRect(x: 60, y: 50 + half + 1, width: 10, height: 10), style: style))
    // 帯の中に画像が丸ごと入る場合も見える。
    #expect(AnnotationGeometry.highlighterShows(pen, in: CGRect(x: 80, y: 49, width: 2, height: 2), style: style))
    // 斜めの線も帯の向きで測る。
    let slant = Annotation(tool: .highlighter, start: .zero, points: [.zero, CGPoint(x: 100, y: 100)])
    #expect(!AnnotationGeometry.highlighterShows(slant, in: CGRect(x: 101, y: 101, width: 20, height: 20), style: style))
    #expect(AnnotationGeometry.highlighterShows(slant, in: CGRect(x: 95, y: 80, width: 5, height: 5), style: style))
    // 折れ線の途中の点は丸い継ぎ目なので、外側の角まで塗れる。
    let bend = Annotation(tool: .highlighter, start: CGPoint(x: 0, y: 50),
                          points: [CGPoint(x: 0, y: 50), CGPoint(x: 100, y: 50), CGPoint(x: 100, y: 150)])
    let outsideCorner = CGRect(x: 100 + half * 0.5, y: 50 - half * 0.5 - 2, width: 2, height: 2)
    #expect(AnnotationGeometry.highlighterShows(bend, in: outsideCorner, style: style))
    // 内側の角には継ぎ目を足さない。
    let insideCorner = CGRect(x: 100 - half * 2, y: 50 + half * 2, width: 2, height: 2)
    #expect(!AnnotationGeometry.highlighterShows(bend, in: insideCorner, style: style))
    // まっすぐ続く途中の点と、描き始めに重なった点は、平らな端より手前へ塗らない。
    let straight = Annotation(tool: .highlighter, start: CGPoint(x: 40, y: 50),
                              points: [CGPoint(x: 40, y: 50), CGPoint(x: 40, y: 50), CGPoint(x: 45, y: 50), CGPoint(x: 120, y: 50)])
    #expect(!AnnotationGeometry.highlighterShows(straight, in: CGRect(x: 30, y: 40, width: 9, height: 20), style: style))
    // 折り返した点は、進んでいた向きの先へ半円だけ塗る。
    let back = Annotation(tool: .highlighter, start: CGPoint(x: 40, y: 50),
                          points: [CGPoint(x: 40, y: 50), CGPoint(x: 100, y: 50), CGPoint(x: 60, y: 50)])
    #expect(AnnotationGeometry.highlighterShows(back, in: CGRect(x: 100 + half - 4, y: 49, width: 2, height: 2), style: style))
    #expect(!AnnotationGeometry.highlighterShows(back, in: CGRect(x: 100 + half + 1, y: 49, width: 2, height: 2), style: style))
    // 半円の弧が矩形の角を少しだけかすめる場合も、近似せずに見えると判定する。
    #expect(AnnotationGeometry.highlighterShows(back, in: CGRect(x: 110, y: 52, width: 20, height: 20), style: style))
    #expect(!AnnotationGeometry.highlighterShows(back, in: CGRect(x: 110, y: 57, width: 20, height: 20), style: style))
    // ごく短い線は帯が潰れても、延長線上を見えると判定しない。
    let tiny = Annotation(tool: .highlighter, start: CGPoint(x: 40, y: 50), points: [CGPoint(x: 40, y: 50), CGPoint(x: 41, y: 51)])
    #expect(!AnnotationGeometry.highlighterShows(tiny, in: CGRect(x: 29, y: 62, width: 1, height: 1), style: style))
    // 1点だけの線は見えない。
    #expect(!AnnotationGeometry.highlighterShows(Annotation(tool: .highlighter, start: CGPoint(x: 40, y: 50), points: [CGPoint(x: 40, y: 50)]),
                                                 in: CGRect(x: 0, y: 0, width: 200, height: 100), style: style))

    // 端の先へ切り詰めたら、見えない線として消す。
    let document = AnnotationDocument(annotations: [pen])
    let cropped = try #require(document.cropping(to: CGRect(x: 125, y: 40, width: 30, height: 20), imageSize: CGSize(width: 200, height: 100)))
    #expect(cropped.annotations.isEmpty)
    // 移動は端が画像から出る手前で止める。
    let image = CGSize(width: 200, height: 100)
    let moved = document.moving([pen.id], by: CGPoint(x: 300, y: 0), imageSize: image)
    #expect(AnnotationGeometry.highlighterShows(moved.annotations[0], in: CGRect(origin: .zero, size: image), style: style))
    #expect(moved.annotations[0].points[0].x < 200)
}

@Test func pastingCopiesTakenBeforeCropMapsThemToTheSamePlaceInSourceImage() throws {
    let size = CGSize(width: 1000, height: 1000), square = CGSize(width: 200, height: 200)
    let pen = Annotation(tool: .highlighter, start: CGPoint(x: 200, y: 999), points: [CGPoint(x: 200, y: 999), CGPoint(x: 999, y: 200)])
    let text = Annotation(tool: .text, start: CGPoint(x: 450, y: 450), end: CGPoint(x: 500, y: 480), text: "文字")
    // 切り落とした場所の蛍光ペンは画像の中央へ寄せる。
    let gone = Annotation(tool: .highlighter, start: CGPoint(x: 10, y: 10), points: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 10)])
    // 外接矩形の中心が線の上に無い折れ線も、線の上の点を中央へ合わせる。
    let bend = Annotation(tool: .highlighter, start: CGPoint(x: 100, y: 100),
                          points: [CGPoint(x: 100, y: 100), CGPoint(x: 900, y: 100), CGPoint(x: 900, y: 900)])
    let original = AnnotationDocument(annotations: [pen, text, gone, bend])
    var clipboard = AnnotationClipboard()
    clipboard.copy([pen.id, text.id, gone.id, bend.id], from: original)
    var document = try #require(original.cropping(to: CGRect(x: 400, y: 400, width: 200, height: 200), imageSize: size))
    let pasted = clipboard.paste(into: &document, imageSize: square)
    let copies = document.annotations.filter { pasted.contains($0.id) }
    #expect(copies.count == 4)
    #expect(copies[3].points[1] == CGPoint(x: 118, y: 118))
    #expect(copies[1].rect == CGRect(x: 68, y: 68, width: 50, height: 30))
    let image = CGRect(origin: .zero, size: square)
    #expect(copies.filter { $0.tool == .highlighter }.allSatisfy {
        AnnotationGeometry.highlighterShows($0, in: image, style: document.style())
    })
    // 中央へ寄せた後に、貼り付けのずれを足す。
    #expect(copies[2].rect == CGRect(x: 93, y: 118, width: 50, height: 0))
}

@Test func cropIsOneHistoryStepWithAnnotations() throws {
    let text = Annotation(tool: .text, start: CGPoint(x: 1000, y: 120), end: CGPoint(x: 1200, y: 200), text: "文字")
    var history = AnnotationHistory(AnnotationDocument(annotations: [text]))
    history.commit(try #require(history.document.cropping(to: CGRect(x: 800, y: 0, width: 800, height: 600), imageSize: full)))
    // 切った後の移動もトリミングを保つ。
    history.commit(history.document.moving([text.id], by: CGPoint(x: 10, y: 0), imageSize: CGSize(width: 800, height: 600)))
    #expect(history.document.crop?.rect == CGRect(x: 800, y: 0, width: 800, height: 600))
    history.undo(); history.undo()
    #expect(history.document == AnnotationDocument(annotations: [text]))
    history.redo()
    #expect(history.document.crop != nil && history.document.annotations.first?.rect.minX == 200)
}

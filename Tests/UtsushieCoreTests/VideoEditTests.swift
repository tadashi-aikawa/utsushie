import Testing
import UtsushieCore

@Test func videoRangesMergeOverlapTouchAndClampInvalidValues() {
    #expect(VideoRange.merged([.init(8, 12), .init(2, 4), .init(3, 6), .init(6, 8), .init(-2, 1),
                               .init(4, 4), .init(.nan, 2), .init(8, 7)], duration: 10)
            == [.init(0, 1), .init(2, 10)])
}

@Test func videoTimeDisplaysHundredthsWithoutChangingSourceTime() {
    #expect(VideoEditFormatting.time(15.8) == "0:15.80")
    #expect(VideoEditFormatting.time(65.432) == "1:05.43")
    #expect(VideoEditFormatting.time(-1) == "0:00.00")
}
@Test func videoCutKeepsSourceScaleAndMapsOnlyKeptTimes() {
    var document = VideoEditDocument(duration: 24)
    document.setStart(2); document.setEnd(22)
    let cut = document.cut(.init(6, 11))
    #expect(cut)
    #expect(document.kept == [.init(2, 6), .init(11, 22)])
    #expect(document.cuts == [.init(0, 2), .init(6, 11), .init(22, 24)])
    #expect(document.outputDuration == 15)
    #expect(document.outputTime(forSource: 2) == 0)
    #expect(document.outputTime(forSource: 6) == nil)
    #expect(document.outputTime(forSource: 11) == 4)
    #expect(document.outputTime(forSource: 15) == 8)
    #expect(document.outputTime(forSource: 22) == 15)
    #expect(document.outputTime(forSource: 23) == nil)
    #expect(document.completionText == "完了で 15.0秒に切る")
    let plan = VideoExportPlan(document: document)
    #expect(plan.segments.map(\.outputStart) == [0, 4])
    #expect(plan.junctions.map(\.outputTime) == [4])
    #expect(plan.junctions.map(\.precedingSegment) == [0])
}
@Test func videoPlaybackSkipsCutsButFrameNavigationCanEnterThem() {
    var document = VideoEditDocument(duration: 10)
    _ = document.cut(.init(0, 2)); _ = document.cut(.init(4, 7)); _ = document.cut(.init(9, 10))
    #expect(document.playbackTime(at: 0) == 2)
    #expect(document.playbackTime(at: 3.9) == 3.9)
    #expect(document.playbackTime(at: 4) == 7)
    #expect(document.playbackTime(at: 6.999) == 7)
    #expect(document.playbackTime(at: 9) == nil)
    #expect(VideoFrameNavigation.step(times: [0, 2, 4.2, 7, 9], from: 4, forward: true) == 4.2)
    #expect(VideoFrameNavigation.step(times: [0, 2, 4.2, 7, 9], from: 4.2, forward: false) == 2)
    #expect(VideoFrameNavigation.step(times: [0, 2, 4.2, 7, 9], from: 4.2 - 0.000001, forward: true) == 7)
}
@Test func videoBoundaryDragClampsAndCanRestoreInteriorCut() {
    var document = VideoEditDocument(duration: 10)
    _ = document.cut(.init(3, 6))
    document.moveBoundary(segment: 0, start: false, to: 4)
    #expect(document.cuts == [.init(4, 6)])
    document.moveBoundary(segment: 1, start: true, to: 4)
    #expect(document.kept == [.init(0, 10)])
    document.moveBoundary(segment: 0, start: true, to: 20)
    #expect(document.outputDuration > 0)
    document.setStart(0); document.setEnd(2)
    #expect(document.kept == [.init(0, 2)])
    document.setEnd(10)
    #expect(!document.isTrimmed)
    let cut = document.cut(.init(0, 10))
    #expect(!cut)
    #expect(document.kept == [.init(0, 10)])
}

@Test func videoIOInsideCutAlignsOuterBoundaryToRequestedSourceTime() {
    var start = VideoEditDocument(duration: 10, kept: [.init(0, 3), .init(6, 10)])
    start.setStart(4)
    #expect(start.kept == [.init(4, 10)])
    var end = VideoEditDocument(duration: 10, kept: [.init(0, 3), .init(6, 10)])
    end.setEnd(5)
    #expect(end.kept == [.init(0, 5)])
}
@Test func videoTimelineUsesDisplayPointThresholdAndNearestHandle() {
    let document = VideoEditDocument(duration: 10, kept: [.init(1, 4), .init(6, 9)])
    #expect(VideoTimelineGesture.hit(x: 98, y: 20, width: 1000, document: document) == .boundary(segment: 0, start: true))
    #expect(VideoTimelineGesture.hit(x: 601, y: 20, width: 1000, document: document) == .boundary(segment: 1, start: true))
    #expect(VideoTimelineGesture.hit(x: 500, y: 20, width: 1000, document: document) == .strip)
    #expect(VideoTimelineGesture.hit(x: 500, y: -1, width: 1000, document: document) == .outside)
    #expect(VideoTimelineGesture.selection(from: 400, to: 404, width: 1000, duration: 10) == nil)
    #expect(VideoTimelineGesture.selection(from: 600, to: 200, width: 1000, duration: 10) == .init(2, 6))
    #expect(VideoTimelineGesture.selection(from: -20, to: 1200, width: 1000, duration: 10) == .init(0, 10))
}
@Test func videoHistoryCommitsWholeDragAndRestorationAsSeparateSteps() {
    let initial = VideoEditDocument(duration: 10)
    var history = VideoEditHistory(initial)
    var document = initial; _ = document.cut(.init(3, 6))
    history.commit(document); history.commit(document)
    document.restore(.init(3, 6)); history.commit(document)
    history.undo(); #expect(history.document.cuts == [.init(3, 6)])
    history.undo(); #expect(history.document == initial); #expect(!history.canUndo)
    history.redo(); #expect(history.document.cuts == [.init(3, 6)])
    var next = history.document; next.setStart(2); history.commit(next)
    #expect(!history.canRedo)
}

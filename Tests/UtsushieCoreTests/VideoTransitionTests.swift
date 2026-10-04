import Testing
import UtsushieCore

@Test func fastForwardInitialSpeedBoundsAndUndoPreserveExplicitSpeed() {
    #expect(VideoCutTransition.initialSpeed(duration: 1.5) == 4)
    #expect(VideoCutTransition.initialSpeed(duration: 4.8) == 5)
    #expect(VideoCutTransition.initialSpeed(duration: 180) == 100)
    var document = VideoEditDocument(duration: 24)
    _ = document.cut(.init(6, 10.8))
    let range = document.interiorCuts[0]
    #expect(document.transition(for: range).kind == .none)
    document.setTransition(for: range, kind: .fastForward)
    #expect(document.transitions[0].multiplier == 5)
    document.setTransition(for: range, kind: .fastForward, speed: 1)
    #expect(document.transitions[0].multiplier == 2)
    document.setTransition(for: range, kind: .fastForward, speed: 101)
    #expect(document.transitions[0].multiplier == 100)
    document.setTransition(for: range, kind: .fastForward, speed: 8)
    var history = VideoEditHistory(document)
    document.setTransition(for: range, kind: .none); history.commit(document)
    document.setTransition(for: range, kind: .fastForward); history.commit(document)
    #expect(history.document.transitions[0].multiplier == 8)
    history.undo(); #expect(history.document.transitions[0].kind == .none)
    history.undo(); #expect(history.document.transitions[0].multiplier == 8)
}

@Test func transitionFollowsBoundaryAndLongestCutWinsMerge() {
    var document = VideoEditDocument(duration: 20, kept: [.init(0, 2), .init(5, 7), .init(12, 20)])
    document.setTransition(for: .init(2, 5), kind: .fastForward, speed: 4)
    document.setTransition(for: .init(7, 12), kind: .fastForward, speed: 9)
    document.moveBoundary(segment: 1, start: false, to: 8)
    #expect(document.transition(for: .init(8, 12)).multiplier == 9)
    _ = document.cut(.init(4, 9))
    #expect(document.interiorCuts == [.init(2, 12)])
    #expect(document.transitions[0].multiplier == 9)
    document.restore(.init(2, 12)); #expect(document.transitions.isEmpty)
    document.setStart(2); document.setEnd(18)
    document.setTransition(for: .init(0, 2), kind: .fastForward)
    #expect(document.transitions.isEmpty)
}

@Test func fastForwardPlanMapsSourceTimesAndAddsOnlyInteriorTransitionLength() {
    var document = VideoEditDocument(duration: 24.1, kept: [.init(2.4, 6.2), .init(11, 21.8)])
    _ = document.addStill(at: 8)
    document.setTransition(for: .init(6.2, 11), kind: .fastForward)
    let plan = VideoExportPlan(document: document)
    #expect(abs(document.keptDuration - 14.6) < 0.000001)
    #expect(abs(document.transitionDuration - 0.96) < 0.000001)
    #expect(abs(plan.duration - 15.56) < 0.000001)
    #expect(plan.segments.map(\.speed) == [1, 5, 1])
    #expect(abs(document.outputTime(forSource: 8.6)! - 4.28) < 0.000001)
    #expect(abs(document.outputTime(forSource: 11)! - 4.76) < 0.000001)
    #expect(document.playbackTime(at: 8.6) == 8.6)
    #expect(document.outputTime(forSource: 1) == nil)
    #expect(document.transitions[0].text == "▶▶ ×5 ・ 1.0秒で見せる")
    #expect(VideoToolbarPresentation.length(document: document) == "残す 14.6秒 + つなぎ 1.0秒 / 24.1秒")
    #expect(document.completionText == "完了で 残す 14.6秒 + つなぎ 1.0秒 ・ 静止画1枚をコピー")
    #expect(document.stills[0].time == 8)
}

@Test func fadeAddsHalfSecondAndLeavesKeptFramesAndStillsAtSourceTimes() {
    var document = VideoEditDocument(duration: 10, kept: [.init(0, 2), .init(6, 10)])
    _ = document.addStill(at: 5)
    document.setTransition(for: .init(2, 6), kind: .fade)
    let plan = VideoExportPlan(document: document)
    #expect(plan.duration == 6.5 && document.keptDuration == 6)
    #expect(plan.segments.map(\.outputStart) == [0, 2.5])
    #expect(plan.segments.map(\.source) == document.kept)
    #expect(document.outputTime(forSource: 7) == 3.5)
    #expect(document.outputTime(forSource: 5) == nil && document.playbackTime(at: 5) == 6)
    #expect(document.transitions[0].text == "暗転 ・ 4.0秒を切る")
    #expect(document.stills[0].time == 5)
}

@Test func draggingAwayMiddleKeptSegmentMergesCutsAndKeepsLongerTransition() {
    for start in [true, false] {
        var document = VideoEditDocument(duration: 20, kept: [.init(0, 2), .init(5, 7), .init(12, 20)])
        document.setTransition(for: .init(2, 5), kind: .fade)
        document.setTransition(for: .init(7, 12), kind: .fastForward, speed: 9)
        document.moveBoundary(segment: 1, start: start, to: start ? 7 : 5)
        #expect(document.kept == [.init(0, 2), .init(12, 20)])
        #expect(document.transitions == [.init(range: .init(2, 12), kind: .fastForward, speed: 9)])
    }
    var tied = VideoEditDocument(duration: 10, kept: [.init(0, 2), .init(4, 6), .init(8, 10)])
    tied.setTransition(for: .init(2, 4), kind: .dissolve)
    tied.setTransition(for: .init(6, 8), kind: .fade)
    tied.moveBoundary(segment: 1, start: false, to: 4)
    #expect(tied.transitions[0].kind == .dissolve)
}

@Test func mixedTransitionsMapAllFollowingSegmentsAndIgnoreOuterCuts() {
    var document = VideoEditDocument(duration: 30, kept: [.init(1, 3), .init(5, 7), .init(11, 13), .init(17, 29)])
    document.setTransition(for: .init(3, 5), kind: .fastForward, speed: 2)
    document.setTransition(for: .init(7, 11), kind: .fade)
    document.setTransition(for: .init(13, 17), kind: .dissolve)
    let plan = VideoExportPlan(document: document)
    #expect(plan.segments.map(\.outputStart) == [0, 2, 3, 5.5, 8])
    #expect(plan.junctions.map(\.precedingSegment) == [0, 2, 3])
    #expect(plan.junctions.map(\.followingSegment) == [2, 3, 4])
    #expect(document.outputDuration == 20 && document.transitionDuration == 2)
    #expect(document.outputTime(forSource: 18) == 9)
    #expect(document.outputTime(forSource: 29) == 20)
    #expect(document.transitions[2].text == "ディゾルブ ・ 4.0秒を切る")
    document.setStart(12)
    #expect(document.transitions.count == 1 && document.transitions[0].kind == .dissolve)
    document.setEnd(15)
    #expect(document.transitions.isEmpty)
}

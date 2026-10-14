import Testing
import CoreGraphics
@testable import UtsushieCore

@Test func audioConfigDefaultsToNoneAndRejectsUnknownSource() {
    #expect(UtsushieConfig().video.audio == .none)
    for (text, audio) in [("none", VideoAudio.none), ("system", .system), ("mic", .microphone), ("both", .both)] {
        let result = ConfigLoader.parse(toml: "[video]\naudio = \"\(text)\"")
        #expect(result.warnings.isEmpty)
        #expect(result.config.video.audio == audio)
    }
    for invalid in ["\"microphone\"", "true"] {
        let result = ConfigLoader.parse(toml: "[video]\naudio = \(invalid)\nfps = 24")
        #expect(result.warnings == ["video.audio が不正なため既定値を使います"])
        #expect(result.config.video.audio == .none)
        #expect(result.config.video.fps == 24)
    }
}

@Test func audioKeyCyclesOnlyForVideoAndKeepsDrag() {
    var state = CaptureState(audio: .microphone)
    #expect(state.audio == .microphone)
    #expect(!state.handles(0))
    #expect(state.key(0, hasLast: false) == .none)
    #expect(state.audio == .microphone)
    _ = state.key(48, hasLast: false)
    #expect(state.handles(0))
    _ = state.pointerDown(at: .zero, last: nil)
    state.pointerDragged(to: CGPoint(x: 40, y: 30))
    var seen: [VideoAudio] = []
    for _ in 0..<4 { _ = state.key(0, hasLast: false); seen.append(state.audio) }
    #expect(seen == [.both, .none, .system, .microphone])
    #expect(state.pointerUp(at: CGPoint(x: 40, y: 30)) == .captureArea(CGRect(x: 0, y: 0, width: 40, height: 30)))
    #expect(VideoAudio.both.capturesSystem && VideoAudio.both.capturesMicrophone)
    #expect(!VideoAudio.none.capturesSystem && !VideoAudio.none.capturesMicrophone)
}

@Test func audioItemAppearsOnlyForVideoAndShiftsTargets() {
    #expect(OverlayPresentation.audioItem(output: .image, audio: .both) == nil)
    let off = OverlayPresentation.audioItem(output: .video, audio: .none)
    #expect(off?.title == "音 なし" && off?.key == "A" && off?.selected == false)
    #expect(OverlayPresentation.audioItem(output: .video, audio: .system)?.selected == true)
    let widths: [CGFloat] = [40, 56, 87, 63, 90, 80, 91]
    let plain = OverlayToolbarLayout(itemWidths: widths, tabWidth: 28)
    let layout = OverlayToolbarLayout(itemWidths: widths, tabWidth: 28, audioWidth: 70)
    #expect(plain.audio == nil)
    let audio = try! #require(layout.audio)
    #expect(audio.minX - layout.tab.maxX == 10 && audio.width == 70)
    #expect(layout.targetTray.minX - audio.maxX == 10)
    #expect(layout.width - plain.width == 80)
    #expect(layout.width - layout.items[6].maxX == 6)
}

@Test func audioStartsAtFirstFrameAndDropsEarlierSound() {
    var timeline = VideoTimeline()
    #expect(timeline.audioPresentation(sourceTime: 99.9) == nil)
    _ = timeline.accept(sourceTime: 100, hostTime: 1000)
    #expect(timeline.audioPresentation(sourceTime: 99.99) == nil)
    #expect(timeline.audioPresentation(sourceTime: 100) == 0)
    #expect(abs(timeline.audioPresentation(sourceTime: 101.25)! - 1.25) < 1e-9)
}

@Test func audioPlanSilencesFastForwardAndSmoothsSeams() {
    var document = VideoEditDocument(duration: 10, kept: [.init(1, 3), .init(5, 7), .init(8, 9)])
    document.setTransition(for: .init(3, 5), kind: .fastForward, speed: 4)
    let plan = VideoAudioPlan(plan: VideoExportPlan(document: document), sourceDuration: 10)
    #expect(plan.clips.map(\.source) == [.init(1, 3), .init(5, 7), .init(8, 9)])
    #expect(plan.clips.map(\.outputStart) == [0, 2.5, 4.5])
    #expect(plan.clips.map(\.track) == [0, 1, 0])
    #expect(plan.clips.allSatisfy { $0.fadeIn == VideoAudioPlan.seam && $0.fadeOut == VideoAudioPlan.seam })
    let whole = VideoAudioPlan(plan: VideoExportPlan(document: VideoEditDocument(duration: 4, kept: [.init(0, 4)])), sourceDuration: 4)
    #expect(whole.clips.map(\.fadeIn) == [0] && whole.clips.map(\.fadeOut) == [0])
}

@Test func audioPlanFillsFadeAndDissolveWithCutSound() {
    var document = VideoEditDocument(duration: 10, kept: [.init(0, 2), .init(4, 6), .init(6.1, 10)])
    document.setTransition(for: .init(2, 4), kind: .fade)
    document.setTransition(for: .init(6, 6.1), kind: .dissolve)
    let export = VideoExportPlan(document: document)
    let plan = VideoAudioPlan(plan: export, sourceDuration: 10)
    // 暗転: 前は切った範囲の先頭0.25秒で絞り、後ろは直前の0.25秒から出す。
    #expect(plan.clips[0].source == .init(0, 2.25) && plan.clips[0].fadeOut == 0.25)
    #expect(abs(plan.clips[1].source.start - 3.75) < 1e-9 && plan.clips[1].fadeIn == 0.25)
    #expect(abs(plan.clips[1].outputStart - 2.25) < 1e-9)
    #expect(abs(plan.clips[0].outputEnd - 2.25) < 1e-9)
    // ディゾルブ: 切った範囲が0.1秒しかなければ、その長さだけ重ねる。
    #expect(abs(plan.clips[1].source.end - 6.1) < 1e-9 && abs(plan.clips[1].fadeOut - 0.1) < 1e-9)
    #expect(abs(plan.clips[2].source.start - 6) < 1e-9 && abs(plan.clips[2].fadeIn - 0.1) < 1e-9)
    #expect(abs(plan.clips[2].outputStart - (export.segments[2].outputStart - 0.1)) < 1e-9)
    #expect(plan.clips.map(\.track) == [0, 1, 0])
}

@Test func transitionPreviewAudioMatchesExportFades() {
    let fade = VideoTransitionAudioPreview(kind: .fade, cut: .init(2, 4))
    #expect(fade.outgoing == 0.25 && fade.incoming == 0.25 && fade.incomingStart == 0.25)
    #expect(fade.outgoingVolume(at: 0) == 1 && abs(fade.outgoingVolume(at: 0.125) - 0.5) < 1e-6 && fade.outgoingVolume(at: 0.25) == 0)
    #expect(fade.incomingVolume(at: 0.2) == 0 && abs(fade.incomingVolume(at: 0.375) - 0.5) < 1e-6 && fade.incomingVolume(at: 0.5) == 1)
    // 暗転の中央は前後とも無音。
    #expect(fade.outgoingVolume(at: 0.25) + fade.incomingVolume(at: 0.25) == 0)
    let dissolve = VideoTransitionAudioPreview(kind: .dissolve, cut: .init(2, 4))
    #expect(dissolve.incomingStart == 0)
    #expect(abs(dissolve.outgoingVolume(at: 0.25) + dissolve.incomingVolume(at: 0.25) - 1) < 1e-6)
    let short = VideoTransitionAudioPreview(kind: .dissolve, cut: .init(6, 6.1))
    #expect(abs(short.outgoing - 0.1) < 1e-9 && abs(short.incomingStart - 0.4) < 1e-9)
    #expect(short.outgoingVolume(at: 0.2) == 0 && short.incomingVolume(at: 0.3) == 0)
    for kind in [VideoTransitionKind.none, .fastForward] {
        let none = VideoTransitionAudioPreview(kind: kind, cut: .init(2, 4))
        #expect(none.outgoing == 0 && none.incoming == 0)
    }
}

@Test func audioPlanNeverOverlapsFadesOnShortClip() {
    let document = VideoEditDocument(duration: 10, kept: [.init(0, 2), .init(5, 5.012), .init(8, 10)])
    let plan = VideoAudioPlan(plan: VideoExportPlan(document: document), sourceDuration: 10)
    let short = plan.clips[1]
    #expect(short.fadeIn + short.fadeOut <= short.source.duration + 1e-12)
    #expect(abs(short.fadeIn - short.fadeOut) < 1e-12)
}

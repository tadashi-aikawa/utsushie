import Foundation
import CoreGraphics
import Testing
@testable import UtsushieCore

@Test func videoSettingsHaveIndependentDefaults() {
    let result = ConfigLoader.parse(toml: "[webp]\ndownscale = false")
    #expect(!result.config.downscale)
    #expect(result.config.video == VideoConfig())
    #expect(result.config.video.fps == 30)
    #expect(result.config.video.downscale && result.config.video.showsCursor)
}
@Test func customizedVideoSettings() {
    let result = ConfigLoader.parse(toml: "[video]\nfps = 60\ndownscale = false\nshowsCursor = false")
    #expect(result.warnings.isEmpty)
    #expect(result.config.video.fps == 60)
    #expect(!result.config.video.downscale && !result.config.video.showsCursor)
    #expect(result.config.downscale)
}
@Test(arguments: ["fps = 0", "fps = 61", "fps = 29.5", "fps = \"30\"", "downscale = 1", "showsCursor = \"yes\""])
func invalidVideoSettings(_ setting: String) {
    let result = ConfigLoader.parse(toml: "[video]\n\(setting)")
    #expect(result.config.video == VideoConfig())
    #expect(result.warnings.count == 1)
}
@Test func videoDimensionsRoundDownToEven() {
    let oneX = VideoGeometry.size(points: CGSize(width: 1281, height: 721), scale: 2, downscale: true)
    #expect(oneX.width == 1280 && oneX.height == 720)
    let native = VideoGeometry.size(points: CGSize(width: 1281, height: 721), scale: 2, downscale: false)
    #expect(native.width == 2562 && native.height == 1442)
    let tiny = VideoGeometry.size(points: CGSize(width: 1, height: 1), scale: 1, downscale: true)
    #expect(tiny.width == 2 && tiny.height == 2)
}
@Test func videoRegionMustStayInsideOneDisplay() {
    let main = DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)
    let left = DisplayGeometry(id: 2, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), scale: 1)
    #expect(VideoGeometry.display(containing: CGRect(x: -100, y: 10, width: 200, height: 100), displays: [main, left]) == nil)
    #expect(VideoGeometry.display(containing: CGRect(x: -400, y: 10, width: 200, height: 100), displays: [main, left])?.id == 2)
    #expect(VideoGeometry.display(containing: main.frame, displays: [main, left])?.id == 1)
}
@Test func videoAllTargetsWorkWithSamePhysicalKeys() {
    var state = CaptureState()
    _ = state.key(48, hasLast: false)
    #expect(state.repeatCapture(hasLast: false) == .none)
    #expect(state.repeatCapture(hasLast: true) == .captureLast)
    #expect(state.key(8, hasLast: true) == .captureChrome)
    _ = state.key(13, hasLast: true)
    #expect(state.pointerDown(at: .zero, last: nil) == .none)
    #expect(state.pointerUp(at: .zero, hasWindow: true) == .captureWindow)
    _ = state.pointerDown(at: .zero, last: nil)
    #expect(state.output == .video)
    #expect(state.key(53, hasLast: true) == .cancel)
    #expect(state.pointerUp(at: CGPoint(x: 10, y: 10)) == .none)
}
@Test func duplicateStopDoesNotFinalizeTwice() {
    var state = RecordingState()
    #expect(state.stop() == false)
    #expect(state.begin() == true)
    #expect(state.begin() == false)
    #expect(state.stop() == false)
    state.didStart()
    #expect(state.phase == .recording)
    #expect(state.stop() == true)
    #expect(state.phase == .finalizing)
    #expect(state.stop() == false)
    #expect(state.begin() == false)
    state.reset()
    #expect(state.begin() == true)
}
@Test func variableFramesKeepTimeGaps() {
    var timeline = VideoTimeline()
    #expect(timeline.accept(sourceTime: 1000, hostTime: 2000) == 0)
    #expect(timeline.accept(sourceTime: 1002, hostTime: 2002) == 2)
    #expect(timeline.accept(sourceTime: 1007, hostTime: 2007) == 7)
    #expect(timeline.accept(sourceTime: 1006, hostTime: 2008) == nil)
    #expect(timeline.accept(sourceTime: 1007, hostTime: 2008) == nil)
}
@Test func frozenScreenHasRealDuration() throws {
    var timeline = VideoTimeline()
    _ = timeline.accept(sourceTime: 1000, hostTime: 2000)
    let end = try #require(timeline.end(hostTime: 2012.4, fps: 30))
    #expect(abs(end.duration - 12.4) < 0.000001)
    #expect(abs(try #require(end.tailPresentation) - (12.4 - 1 / 30.0)) < 0.000001)
}
@Test func recordingWithoutFramesHasNoTimeline() {
    var timeline = VideoTimeline()
    #expect(timeline.end(hostTime: 10, fps: 30) == nil)
    #expect(timeline.accept(sourceTime: .nan, hostTime: 10) == nil)
    #expect(timeline.end(hostTime: 20, fps: 30) == nil)
}
@Test func veryShortRecordingStillHasOneFrame() throws {
    var timeline = VideoTimeline()
    _ = timeline.accept(sourceTime: 10, hostTime: 100)
    let end = try #require(timeline.end(hostTime: 100.001, fps: 30))
    #expect(end.duration == 1 / 30.0)
    #expect(end.tailPresentation == nil)
}
@Test func mediaLabels() {
    #expect(MediaFormatting.elapsed(12.9) == "0:12")
    #expect(MediaFormatting.elapsed(3661) == "61:01")
    #expect(MediaFormatting.videoInfo(width: 1280, height: 720, duration: 12.4, bytes: 3_355_443) == "MP4  1280×720  12.4s  3.2MB")
}

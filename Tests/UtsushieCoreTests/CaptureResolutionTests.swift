import CoreGraphics
import Testing
@testable import UtsushieCore

@Test func resolutionUsesEachOutputDefaultAndKeepsInversionAcrossTab() {
    for imageDefault in [false, true] {
        for videoDefault in [false, true] {
            var config = UtsushieConfig()
            config.downscale = imageDefault; config.video.downscale = videoDefault
            var state = CaptureState()
            #expect(state.handles(15))
            #expect(state.effectiveDownscale(config: config) == imageDefault)
            #expect(state.key(15, hasLast: true) == .none)
            #expect(state.effectiveDownscale(config: config) == !imageDefault)
            #expect(state.output == .image && state.target == .area)
            _ = state.key(48, hasLast: true)
            #expect(state.handles(15))
            #expect(state.effectiveDownscale(config: config) == !videoDefault)
            _ = state.key(48, hasLast: true)
            #expect(state.effectiveDownscale(config: config) == !imageDefault)
            _ = state.key(15, hasLast: true)
            #expect(state.effectiveDownscale(config: config) == imageDefault)
            _ = state.key(15, hasLast: true)
            #expect(CaptureState().effectiveDownscale(config: config) == imageDefault)
            #expect(config.downscale == imageDefault && config.video.downscale == videoDefault)
        }
    }
}

@Test func resolutionKeyKeepsDragAndEveryCaptureTarget() {
    for video in [false, true] {
        var state = CaptureState()
        if video { _ = state.key(48, hasLast: false) }
        _ = state.pointerDown(at: .zero, last: nil)
        state.pointerDragged(to: CGPoint(x: 40, y: 30))
        _ = state.key(15, hasLast: false)
        #expect(state.gesture.isDragging)
        #expect(state.pointerUp(at: CGPoint(x: 40, y: 30)) == .captureArea(CGRect(x: 0, y: 0, width: 40, height: 30)))
        #expect(state.repeatCapture(hasLast: true) == .captureLast)
        #expect(state.resolutionInverted)
        for code: UInt16 in [36, 8, 14] {
            _ = state.key(code, hasLast: true)
            let target = state.target
            _ = state.key(15, hasLast: true)
            #expect(state.target == target)
            #expect(state.output == (video ? .video : .image))
        }
    }
}

@Test func videoResolutionUsesSixtyFPSOnlyForNativePixels() {
    for downscale in [false, true] {
        for fps in [1, 24, 30, 60] {
            var defaults = VideoConfig()
            defaults.downscale = downscale; defaults.fps = fps
            defaults.audio = .both; defaults.showsCursor = false
            var state = CaptureState()
            _ = state.key(48, hasLast: false)
            for inverted in [false, true] {
                if inverted { _ = state.key(15, hasLast: false) }
                let effective = state.effectiveVideoConfig(defaults)
                #expect(effective.downscale == (downscale != inverted))
                #expect(effective.fps == (effective.downscale ? fps : 60))
                #expect(effective.audio == defaults.audio && effective.showsCursor == defaults.showsCursor)
            }
            #expect(defaults.downscale == downscale && defaults.fps == fps)
        }
    }
}

@Test func resolutionLabelAndDimensionsFollowEffectiveDownscale() throws {
    let widths: [CGFloat] = [40, 56, 87, 63, 90, 80, 91]
    let plain = OverlayToolbarLayout(itemWidths: widths, tabWidth: 28)
    for audioWidth: CGFloat? in [nil, 70] {
        let layout = OverlayToolbarLayout(itemWidths: widths, tabWidth: 28, resolutionWidth: 54, audioWidth: audioWidth)
        let resolution = try #require(layout.resolution)
        #expect(resolution.minX == layout.tab.maxX + 10 && resolution.width == 54)
        if let audioWidth {
            let audio = try #require(layout.audio)
            #expect(audio.minX == resolution.maxX + 10 && audio.width == audioWidth)
            #expect(layout.targetTray.minX == audio.maxX + 10)
            #expect(layout.width == plain.width + 64 + audioWidth + 10)
        } else {
            #expect(layout.audio == nil && layout.targetTray.minX == resolution.maxX + 10)
            #expect(layout.width == plain.width + 64)
        }
        #expect(layout.outputTray == plain.outputTray && layout.tab == plain.tab)
    }
    for output in [CaptureOutput.image, .video] {
        for downscale in [false, true] {
            let item = OverlayPresentation.resolutionItem(downscale: downscale)
            #expect(item.title == (downscale ? "1x" : "2x") && item.key == "R")
            #expect(item.selected == !downscale && item.enabled && !item.recording)
            for scale in [1.0, 2.0] {
                let dimensions = OverlayPresentation.dimensions(points: CGSize(width: 1280, height: 800), scale: scale,
                    output: output, downscale: downscale)
                #expect(dimensions == (downscale || scale == 1 ? "1280×800" : "2560×1600"))
            }
        }
    }
}

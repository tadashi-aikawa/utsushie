import CoreGraphics
import Testing
@testable import UtsushieCore

@Test func toolbarHintsOnlyDescribeTextAndNumbers() {
    for tool in [AnnotationTool.selection, .rectangle, .spotlight, .arrow, .mosaic] {
        #expect(AnnotationToolbarPresentation.hint(tool: tool, nextNumber: 4).text.isEmpty)
    }
    #expect(AnnotationToolbarPresentation.hint(tool: .number, nextNumber: 4).text == "クリックで4 ・ 指す点からドラッグで引き出し線")
    #expect(AnnotationToolbarPresentation.hint(tool: .text, nextNumber: 4).text == "クリックで文字 ・ 指す点からドラッグで引き出し線")
    let editing = AnnotationToolbarPresentation.hint(tool: .text, nextNumber: 4, editingText: true)
    #expect(editing.text == "⏎で確定 ・ ⇧⏎で改行" && editing.keys == ["⇧⏎", "⏎"])
    let crop = AnnotationToolbarPresentation.hint(tool: .crop, nextNumber: 4)
    #expect(crop.text == "ドラッグした範囲を新しい画像にする ・ ⌘Zで戻す" && crop.keys == ["⌘Z"])
}

@Test func colorControlsFollowToolAndGiveInkPriorityInMixedSelection() {
    let inkTools: [AnnotationTool] = [.rectangle, .spotlight, .arrow, .line, .text, .number]
    let selections: [[AnnotationTool]] = [[], [.highlighter], [.mosaic], [.highlighter, .mosaic], [.line, .highlighter], [.text, .number], [.number, .mosaic]]
    for tool in AnnotationTool.allCases {
        for selected in selections {
            let expected: AnnotationColorControls
            switch tool {
            case .highlighter: expected = .highlighter
            case .mosaic, .crop: expected = .none
            case .selection:
                expected = selected.contains(where: { inkTools.contains($0) }) ? .ink : selected.contains(.highlighter) ? .highlighter : .none
            default: expected = .ink
            }
            #expect(AnnotationToolbarPresentation.colorControls(tool: tool, selectedTools: selected) == expected)
        }
    }
}

@Test func toolbarStatusTakesPriorityAndSearchLivesInButton() {
    let result = ToolbarHint("3 か所にモザイクを入れました")
    let error = ToolbarHint("隠す箇所を探せませんでした", isError: true)
    for message in [result, error, ToolbarHint(AnnotationToolbarPresentation.aiDisabled)] {
        #expect(AnnotationToolbarPresentation.hint(tool: .number, nextNumber: 4, editingText: true, message: message) == message)
    }
    #expect(AnnotationToolbarPresentation.hint(tool: .number, nextNumber: 4, findingPrivacy: true).text.isEmpty)
    #expect(AnnotationToolbarPresentation.hint(tool: .text, nextNumber: 4, editingText: true, findingPrivacy: true).text == "⏎で確定 ・ ⇧⏎で改行")
    #expect(AnnotationToolbarPresentation.hint(tool: .text, nextNumber: 4, message: error, saving: true).text == "書き出し中…")
}

@Test func overlayToolbarFitsContentWithEqualOuterPadding() {
    let samples: [[CGFloat]] = [[40, 56, 87, 63, 90, 91], [100, 100, 100, 100, 100, 100], [20, 20, 20, 20, 20, 20]]
    for widths in samples {
        let layout = OverlayToolbarLayout(itemWidths: widths, tabWidth: 28, resolutionWidth: 50)
        #expect(layout.height == 80)
        #expect(layout.items.map(\.width) == widths)
        // 1段目: 出力の台とTab。
        #expect(layout.outputTray.minX == 6 && layout.outputTray.maxY == 76)
        #expect(layout.items[0].minX - layout.outputTray.minX == 2)
        #expect(layout.outputTray.maxX - layout.items[1].maxX == 2)
        #expect(layout.tab.minX - layout.outputTray.maxX == 6 && layout.tab.midY == layout.items[0].midY)
        // 2段目: 左に切り替え、縦線、右に対象の台とやめる。
        #expect(layout.targetTray.minY == 4 && layout.targetTray.maxY < layout.outputTray.minY)
        #expect(layout.resolution?.minX == 8 && layout.resolution?.midY == layout.items[2].midY)
        #expect(layout.divider.minX - layout.resolution!.maxX == 10)
        #expect(layout.targetTray.minX - layout.divider.maxX == 10)
        #expect(layout.items[2].minX - layout.targetTray.minX == 2)
        #expect(layout.targetTray.maxX - layout.items[4].maxX == 2)
        #expect(layout.items[5].minX - layout.targetTray.maxX == 10)
        #expect(layout.width - layout.items[5].maxX == 6)
        for index in [0, 2, 3] { #expect(layout.items[index + 1].minX - layout.items[index].maxX == 2) }
    }
    let compact = OverlayToolbarLayout(itemWidths: Array(repeating: 20, count: 6), tabWidth: 28)
    #expect(compact.width < 620)
}

@Test func overlayToolbarWidthTracksSecondRowWithoutExtraTrailingSpace() {
    let baseline = OverlayToolbarLayout(itemWidths: Array(repeating: 50, count: 6), tabWidth: 28)
    for index in 0..<6 {
        var widths: [CGFloat] = Array(repeating: 50, count: 6); widths[index] += 37
        let expanded = OverlayToolbarLayout(itemWidths: widths, tabWidth: 28)
        // 出力は2段目より短い1段目にあるので、幅を変えない。
        #expect(expanded.width - baseline.width == (index < 2 ? 0 : 37))
        #expect(expanded.width - expanded.items[5].maxX == 6)
    }
}

@Test func overlayToolbarKeepsOperationsInPlaceWithinToggleSpace() {
    let widths: [CGFloat] = [40, 56, 87, 63, 90, 80, 91]
    // 確保する幅は 40 + 10 + 80 + 10 + 70。
    let image = OverlayToolbarLayout(itemWidths: widths, tabWidth: 28, resolutionWidth: 40, outputCount: 3, toggleSpace: 210)
    let video = OverlayToolbarLayout(itemWidths: widths, tabWidth: 28, resolutionWidth: 40, audioWidth: 80, compressionWidth: 70,
                                     outputCount: 3, toggleSpace: 210)
    #expect(image.width == video.width)
    #expect(image.targetTray == video.targetTray && image.divider == video.divider)
    #expect(Array(image.items[3...]) == Array(video.items[3...]))
    #expect(image.resolution == video.resolution)
    // 画像では切り替えが短く、縦線との間が空く。
    #expect(image.divider.minX - image.resolution!.maxX == 180)
    #expect(video.divider.minX - video.compression!.maxX == 10)
    // 確保より長い切り替えは幅を広げる。
    let wide = OverlayToolbarLayout(itemWidths: widths, tabWidth: 28, resolutionWidth: 40, audioWidth: 120, compressionWidth: 70,
                                    outputCount: 3, toggleSpace: 210)
    #expect(wide.width - video.width == 40)
}

@Test func videoToolbarShowsCompletionAndDurationWithoutDiscardHint() {
    var document = VideoEditDocument(duration: 24.1, kept: [.init(0, 14.6)])
    _ = document.addStill(at: 15); _ = document.addStill(at: 20)
    #expect(VideoToolbarPresentation.height == AnnotationToolbarPresentation.height)
    #expect(VideoToolbarPresentation.hint(document: document, discardArmed: true).text == "完了で 14.6秒に切る ・ 静止画2枚をコピー")
    #expect(VideoToolbarPresentation.hint(document: document, copiesStills: false).text == "完了で 14.6秒に切る ・ 静止画2枚を保存")
    #expect(VideoToolbarPresentation.hint(document: VideoEditDocument(duration: 24.1), copiesStills: false).text
        == "ドラッグで切る範囲を選ぶ ・ ⏎でこのコマを撮る")
    #expect(VideoToolbarPresentation.length(document: document) == "残す 14.6秒 / 24.1秒")
}

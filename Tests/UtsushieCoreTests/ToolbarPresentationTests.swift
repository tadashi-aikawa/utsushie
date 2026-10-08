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
}

@Test func highlighterControlsAppearForToolOrSelectedHighlighters() {
    for tool in AnnotationTool.allCases {
        #expect(AnnotationToolbarPresentation.showsHighlighterControls(tool: tool, selectedTools: []) == (tool == .highlighter))
        #expect(AnnotationToolbarPresentation.showsHighlighterControls(tool: tool, selectedTools: [.line, .highlighter]))
        #expect(AnnotationToolbarPresentation.showsHighlighterControls(tool: tool, selectedTools: [.text, .number]) == (tool == .highlighter))
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
        let layout = OverlayToolbarLayout(itemWidths: widths, tabWidth: 28)
        #expect(layout.outputTray.minX == 6)
        #expect(layout.width - layout.items[5].maxX == 6)
        #expect(layout.items.map(\.width) == widths)
        #expect(layout.items[0].minX - layout.outputTray.minX == 2)
        #expect(layout.outputTray.maxX - layout.items[1].maxX == 2)
        #expect(layout.targetTray.minX - layout.tab.maxX == 10)
        #expect(layout.items[2].minX - layout.targetTray.minX == 2)
        #expect(layout.targetTray.maxX - layout.items[4].maxX == 2)
        #expect(layout.items[5].minX - layout.targetTray.maxX == 10)
        for index in [0, 2, 3] { #expect(layout.items[index + 1].minX - layout.items[index].maxX == 2) }
    }
    let compact = OverlayToolbarLayout(itemWidths: Array(repeating: 20, count: 6), tabWidth: 28)
    #expect(compact.width < 620)
}

@Test func overlayToolbarWidthTracksEveryItemWithoutExtraTrailingSpace() {
    let baseline = OverlayToolbarLayout(itemWidths: Array(repeating: 50, count: 6), tabWidth: 28)
    for index in 0..<6 {
        var widths: [CGFloat] = Array(repeating: 50, count: 6); widths[index] += 37
        let expanded = OverlayToolbarLayout(itemWidths: widths, tabWidth: 28)
        #expect(expanded.width - baseline.width == 37)
        #expect(expanded.width - expanded.items[5].maxX == 6)
    }
}

@Test func videoToolbarShowsCompletionAndDurationWithoutDiscardHint() {
    var document = VideoEditDocument(duration: 24.1, kept: [.init(0, 14.6)])
    _ = document.addStill(at: 15); _ = document.addStill(at: 20)
    #expect(VideoToolbarPresentation.height == AnnotationToolbarPresentation.height)
    #expect(VideoToolbarPresentation.hint(document: document, discardArmed: true).text == "完了で 14.6秒に切る ・ 静止画2枚をコピー")
    #expect(VideoToolbarPresentation.length(document: document) == "残す 14.6秒 / 24.1秒")
}

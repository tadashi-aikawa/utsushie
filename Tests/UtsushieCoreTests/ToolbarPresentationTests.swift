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

@Test func toolbarStatusTakesPriorityAndSearchLivesInButton() {
    let result = ToolbarHint("3 か所にモザイクを入れました")
    let error = ToolbarHint("隠す箇所を探せませんでした", isError: true)
    for message in [result, error, ToolbarHint(AnnotationToolbarPresentation.aiDisabled)] {
        #expect(AnnotationToolbarPresentation.hint(tool: .number, nextNumber: 4, editingText: true, message: message) == message)
        let discard = AnnotationToolbarPresentation.hint(tool: .number, nextNumber: 4, editingText: true, discardArmed: true, message: message)
        #expect(discard.text == "もう一度 Q で、注釈を捨てて閉じます" && discard.keys == ["Q"])
    }
    #expect(AnnotationToolbarPresentation.hint(tool: .number, nextNumber: 4, findingPrivacy: true).text.isEmpty)
    #expect(AnnotationToolbarPresentation.hint(tool: .text, nextNumber: 4, editingText: true, findingPrivacy: true).text == "⏎で確定 ・ ⇧⏎で改行")
    #expect(AnnotationToolbarPresentation.hint(tool: .text, nextNumber: 4, discardArmed: true, message: error, saving: true).text == "書き出し中…")
}

@Test func overlayToolbarFitsContentWithEqualOuterPadding() {
    let samples: [[CGFloat]] = [[40, 56, 87, 63, 109, 90, 91], [100, 100, 100, 100, 100, 100, 100], [20, 20, 20, 20, 20, 20, 20]]
    for widths in samples {
        let layout = OverlayToolbarLayout(itemWidths: widths, tabWidth: 28)
        #expect(layout.outputTray.minX == 6)
        #expect(layout.width - layout.items[6].maxX == 6)
        #expect(layout.items.map(\.width) == widths)
        #expect(layout.items[0].minX - layout.outputTray.minX == 2)
        #expect(layout.outputTray.maxX - layout.items[1].maxX == 2)
        #expect(layout.targetTray.minX - layout.tab.maxX == 10)
        #expect(layout.items[2].minX - layout.targetTray.minX == 2)
        #expect(layout.targetTray.maxX - layout.items[5].maxX == 2)
        #expect(layout.items[6].minX - layout.targetTray.maxX == 10)
        for index in [0, 2, 3, 4] { #expect(layout.items[index + 1].minX - layout.items[index].maxX == 2) }
    }
    let compact = OverlayToolbarLayout(itemWidths: Array(repeating: 20, count: 7), tabWidth: 28)
    #expect(compact.width < 620)
}

@Test func overlayToolbarWidthTracksEveryItemWithoutExtraTrailingSpace() {
    let baseline = OverlayToolbarLayout(itemWidths: Array(repeating: 50, count: 7), tabWidth: 28)
    for index in 0..<7 {
        var widths: [CGFloat] = Array(repeating: 50, count: 7); widths[index] += 37
        let expanded = OverlayToolbarLayout(itemWidths: widths, tabWidth: 28)
        #expect(expanded.width - baseline.width == 37)
        #expect(expanded.width - expanded.items[6].maxX == 6)
    }
}

import AppKit
import UtsushieCore

@MainActor
final class VideoToolbarView: NSView {
    let startButton = ToolbarButton(title: "始め", key: "I")
    let endButton = ToolbarButton(title: "終わり", key: "O")
    let cutButton = ToolbarButton(title: "切る", key: "⌫")
    let captureButton = ToolbarButton(title: "撮る", key: "⏎")
    let undoButton = ToolbarButton(title: "↶", face: .plain)
    let redoButton = ToolbarButton(title: "↷", face: .plain)
    let discardButton = ToolbarButton(title: "破棄", key: "Q", face: .secondary, confirmationTitle: "もう一度")
    let finishButton = ToolbarButton(title: "完了", key: "⌘↩", face: .primary)
    let hintView = ToolbarHintView()
    let length = NSTextField(labelWithString: "")
    var trays: [ToolbarTray] { [cutTray, captureTray] }
    override var isFlipped: Bool { true }
    convenience init() { self.init(frame: .zero) }
    override init(frame: CGRect) {
        super.init(frame: frame)
        // 台は共通部品の描画と余白をそのまま使う。
        cutTray = ToolbarTray([startButton, endButton, cutButton])
        captureTray = ToolbarTray([captureButton])
        undoButton.fixedWidth = 28; redoButton.fixedWidth = 28
        undoButton.toolTip = "取り消し ⌘Z"; redoButton.toolTip = "やり直し ⇧⌘Z"
        length.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium); length.textColor = UITheme.key
        [cutTray!, captureTray!, undoButton, redoButton, discardButton, finishButton, hintView, length].forEach { addSubview($0) }
    }
    private(set) var cutTray: ToolbarTray!
    private(set) var captureTray: ToolbarTray!
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        cutTray.frame = CGRect(x: 14, y: 9, width: cutTray.naturalWidth, height: 32)
        captureTray.frame = CGRect(x: cutTray.frame.maxX + 10, y: 9, width: captureTray.naturalWidth, height: 32)
        cutTray.needsLayout = true; captureTray.needsLayout = true
        var right = bounds.width - 14
        for button in [finishButton, discardButton, redoButton, undoButton] {
            button.frame = CGRect(x: right - button.naturalWidth, y: 11, width: button.naturalWidth, height: 28)
            right = button.frame.minX - (button === discardButton ? 18 : button === redoButton ? 2 : 6)
        }
        let width = ceil(length.intrinsicContentSize.width)
        length.frame = CGRect(x: bounds.width - 14 - width, y: 50, width: width, height: 18)
        hintView.frame = CGRect(x: 16, y: 46, width: max(0, length.frame.minX - 28), height: 25)
    }
    override func draw(_ dirtyRect: NSRect) {
        UITheme.ink.setFill(); bounds.fill()
        NSColor.black.setFill(); CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        NSColor.white.withAlphaComponent(0.12).setFill(); CGRect(x: discardButton.frame.minX - 9, y: 15, width: 1, height: 20).fill()
    }
}

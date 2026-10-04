import AppKit
import UtsushieCore

/// 数字欄に通常の文字入力を渡せる、切った範囲専用のメニュー。
@MainActor
final class VideoTransitionMenu: NSViewController, NSTextFieldDelegate {
    private var transition: VideoCutTransition
    private let change: (VideoTransitionKind, Int?) -> Void
    private let speedField = NSTextField(string: "")
    private let stepper = NSStepper()
    private var buttons: [NSButton] = []
    init(transition: VideoCutTransition, change: @escaping (VideoTransitionKind, Int?) -> Void) {
        self.transition = transition; self.change = change; super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        let height = CGFloat(VideoTransitionKind.allCases.count * 32 + 16)
        view = NSView(frame: CGRect(x: 0, y: 0, width: 250, height: height))
        for (index, kind) in VideoTransitionKind.allCases.enumerated() {
            let button = VideoEditorButton(title: kind.title, target: self, action: #selector(selectKind(_:)))
            button.tag = index; button.bezelStyle = .rounded; button.isBordered = false
            button.alignment = .left; button.font = .systemFont(ofSize: 13)
            button.frame = CGRect(x: 10, y: height - 8 - CGFloat(index + 1) * 32, width: 125, height: 30)
            button.setAccessibilityLabel(kind.title); view.addSubview(button); buttons.append(button)
            if kind == .fastForward {
                let label = NSTextField(labelWithString: "×")
                label.frame = CGRect(x: 140, y: button.frame.minY + 6, width: 15, height: 20); view.addSubview(label)
                speedField.frame = CGRect(x: 158, y: button.frame.minY + 3, width: 50, height: 24)
                speedField.delegate = self; speedField.setAccessibilityLabel("早送りの倍率 2から100")
                speedField.target = self; speedField.action = #selector(editSpeed)
                view.addSubview(speedField)
                stepper.minValue = 2; stepper.maxValue = 100; stepper.increment = 1
                stepper.frame = CGRect(x: 213, y: button.frame.minY + 2, width: 19, height: 27)
                stepper.target = self; stepper.action = #selector(stepSpeed); view.addSubview(stepper)
            }
        }
        refresh()
    }
    private func refresh() {
        for (index, kind) in VideoTransitionKind.allCases.enumerated() {
            buttons[index].title = (transition.kind == kind ? "✓ " : "　 ") + kind.title
        }
        speedField.integerValue = transition.multiplier; stepper.integerValue = transition.multiplier
    }
    @objc private func selectKind(_ sender: NSButton) {
        let kind = VideoTransitionKind.allCases[sender.tag]
        transition = VideoCutTransition(range: transition.range, kind: kind, speed: transition.speed)
        refresh(); change(kind, transition.speed)
    }
    @objc private func stepSpeed() { commitSpeed(stepper.integerValue) }
    @objc private func editSpeed() {
        guard let value = Int(speedField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else { refresh(); return }
        commitSpeed(value)
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        // 数字欄へフォーカスしただけで、暗転などを早送りへ切り替えない。
        if Int(speedField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) != transition.multiplier { editSpeed() }
    }
    private func commitSpeed(_ value: Int) {
        transition = VideoCutTransition(range: transition.range, kind: .fastForward, speed: value)
        refresh(); change(.fastForward, transition.speed)
    }
}

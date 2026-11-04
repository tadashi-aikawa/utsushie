import AppKit
import UtsushieCore

/// ズーム区間のイン・アウトの補間の秒数を入力するメニュー。早送りの倍率と同じく、入力欄と0.1秒刻みのステッパーで変える。
@MainActor
final class VideoZoomMenu: NSViewController, NSTextFieldDelegate {
    private var ease: Double
    private let change: (Double) -> Void
    private let field = NSTextField(string: "")
    private let stepper = NSStepper()
    init(ease: Double, change: @escaping (Double) -> Void) {
        self.ease = VideoZoom.clampedEase(ease); self.change = change; super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        view = NSView(frame: CGRect(x: 0, y: 0, width: 220, height: 48))
        let label = NSTextField(labelWithString: "イン・アウト")
        label.font = .systemFont(ofSize: 13); label.frame = CGRect(x: 12, y: 14, width: 82, height: 20); view.addSubview(label)
        field.frame = CGRect(x: 96, y: 12, width: 50, height: 24)
        field.delegate = self; field.target = self; field.action = #selector(editEase)
        field.setAccessibilityLabel("イン・アウトの秒数 0から2")
        view.addSubview(field)
        stepper.minValue = 0; stepper.maxValue = VideoZoom.maximumEase; stepper.increment = 0.1; stepper.valueWraps = false
        stepper.frame = CGRect(x: 151, y: 11, width: 19, height: 27)
        stepper.target = self; stepper.action = #selector(stepEase); view.addSubview(stepper)
        let unit = NSTextField(labelWithString: "秒")
        unit.font = .systemFont(ofSize: 13); unit.frame = CGRect(x: 176, y: 14, width: 30, height: 20); view.addSubview(unit)
        refresh()
    }
    private func refresh() {
        field.stringValue = String(format: "%.1f", ease); stepper.doubleValue = ease
    }
    @objc private func stepEase() { commit(stepper.doubleValue) }
    /// 入力欄はフォーカスが外れたときもactionを送る。値が変わったときだけ履歴へ入れる。
    @objc private func editEase() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(text), VideoZoom.clampedEase(value) != ease else { refresh(); return }
        commit(value)
    }
    func controlTextDidEndEditing(_ obj: Notification) { editEase() }
    private func commit(_ value: Double) {
        let next = VideoZoom.clampedEase(value)
        guard next != ease else { refresh(); return }
        ease = next; refresh(); change(ease)
    }
}

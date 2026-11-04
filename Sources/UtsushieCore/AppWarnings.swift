/// メニューの「設定の警告」に出す文。設定の再読込で作り直す分と、保存時などに見つけて残す分を分けて持つ。
/// 理由: メニューを開くたびに設定を読み直すので、1つの配列だと保存時の警告が設定の警告で上書きされて消えるためです。
public struct AppWarnings: Equatable, Sendable {
    public private(set) var configuration: [String] = []
    /// アプリを終えるまで残す。同じ文は重ねない。
    public private(set) var runtime: [String] = []
    public init() {}
    public mutating func replaceConfiguration(_ warnings: [String]) { configuration = warnings }
    public mutating func add(_ warning: String) {
        if !runtime.contains(warning) { runtime.append(warning) }
    }
    public var all: [String] { configuration + runtime.filter { !configuration.contains($0) } }
    /// 警告が無ければnilで、メニュー項目を隠す。
    public var menuTitle: String? { all.isEmpty ? nil : "設定の警告 \(all.count)件…" }
}

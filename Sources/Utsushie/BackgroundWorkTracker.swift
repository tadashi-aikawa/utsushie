import UtsushieCore

/// カードや一覧の寿命と切り離して、書き出しと取り込みを数える。
@MainActor
final class BackgroundWorkTracker {
    private(set) var count = BackgroundWorkCount()

    func begin(_ kind: BackgroundWorkCount.Kind) { count.begin(kind) }
    func end(_ kind: BackgroundWorkCount.Kind) { count.end(kind) }
}

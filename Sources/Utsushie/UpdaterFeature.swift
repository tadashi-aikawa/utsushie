import AppKit
import UtsushieCore

/// メニューの「アップデートを確認…」から動く確認。差し替えはせず、案内だけをNSAlertで出す。
@MainActor
final class UpdaterFeature {
    private enum Pending {
        /// 確認の結果。作業中かは出す時点で決める
        case result(UpdateCheckResult)
        case failure(String)
        /// ボタンの動作の後に続けて出すアラート
        case content(UpdateAlertContent)
    }

    nonisolated static let target = UpdateTarget.utsushie
    /// 確認の通信から、続けて出すアラートまで閉じ終えるまで。表示を待つ間も含む。
    private var checking = false
    /// 出すのを待っているアラート。待たせる間は短い間隔で確かめ直す。
    private var pending: Pending?
    private var waitTask: Task<Void, Never>?
    /// 終了させると失う作業と、アラートを出すと困る場面か。
    var workState: () -> UpdateWorkState = { UpdateWorkState() }
    /// 「コマンドをコピーして終了」の終了。
    var quit: () -> Void = { NSApp.terminate(nil) }

    static var isInstalledViaHomebrew: Bool {
        target.caskroomPaths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    func checkForUpdates() {
        guard !checking else { return }
        checking = true
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0-development"
        Task { @MainActor in
            do { show(.result(try await Self.check(currentVersion: currentVersion))) }
            catch { show(.failure(error.localizedDescription)) }
        }
    }

    /// 取得の処理をメインアクターの外で組み、`UpdateCheckLogic`へ渡す。
    private nonisolated static func check(currentVersion: String) async throws -> UpdateCheckResult {
        try await UpdateCheckLogic.check(currentVersion: currentVersion) {
            var request = URLRequest(url: target.latestReleaseAPIURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
        }
    }

    /// アラートはどれもここを通し、撮影や範囲選択の間は終わるまで待たせる。
    private func show(_ next: Pending) {
        pending = next
        presentPendingIfPossible()
    }

    private func presentPendingIfPossible() {
        guard let next = pending else { return }
        guard !workState().defersAlert else { waitUntilPresentable(); return }
        pending = nil
        let content: UpdateAlertContent
        switch next {
        case .result(let result):
            content = .forResult(result, target: Self.target, isInstalledViaHomebrew: Self.isInstalledViaHomebrew,
                                 keepsRunning: workState().keepsRunning)
        case .failure(let message):
            content = .forFailure(errorDescription: message, target: Self.target)
        case .content(let shown):
            content = shown
        }
        if let followUp = present(content) { show(.content(followUp)) } else { checking = false }
    }

    /// 段階の変わり目を知らせる経路は場面ごとに違うので、待つ間は確かめ直す。
    private func waitUntilPresentable() {
        guard waitTask == nil else { return }
        waitTask = Task { @MainActor in
            while pending != nil, workState().defersAlert {
                try? await Task.sleep(for: .milliseconds(200))
            }
            waitTask = nil
            presentPendingIfPossible()
        }
    }

    /// 出して閉じるまで。続けて出すアラートがあれば返す。
    private func present(_ content: UpdateAlertContent) -> UpdateAlertContent? {
        // メニューバーだけのアプリなので、前面にしないとアラートがほかのウィンドウの後ろに出る。
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = content.title
        alert.informativeText = content.message
        alert.alertStyle = content.style == .warning ? .warning : .informational
        if let primary = content.primaryButton {
            alert.addButton(withTitle: primary.title)
            alert.addButton(withTitle: UpdateAlertContent.closeButtonTitle)
        }
        let response = alert.runModal()
        guard let primary = content.primaryButton, response == .alertFirstButtonReturn else { return nil }
        let outcome = UpdateAlertActionRunner.run(primary.action, keepsRunning: { workState().keepsRunning }, copy: { command in
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(command, forType: .string)
        }, quit: quit, open: { NSWorkspace.shared.open($0) })
        return content.followUp(after: outcome, target: Self.target)
    }
}

import Foundation
import Testing
@testable import UtsushieCore

@Test func semanticVersionParsesWithOrWithoutPrefix() {
    #expect(SemanticVersion("1.2.3") == SemanticVersion(major: 1, minor: 2, patch: 3))
    #expect(SemanticVersion("v1.2.3") == SemanticVersion(major: 1, minor: 2, patch: 3))
    #expect(SemanticVersion("v1.2.3")?.description == "1.2.3")
}
@Test func semanticVersionRejectsDevelopmentAndMalformed() {
    for text in ["0.0.0-development", "1.2.3-beta.1", "1.2", "1.2.3.4", "abc", "", "1.x.3"] {
        #expect(SemanticVersion(text) == nil)
    }
}
@Test func semanticVersionComparesNumerically() {
    #expect(SemanticVersion("1.0.0")! < SemanticVersion("2.0.0")!)
    #expect(SemanticVersion("1.1.0")! < SemanticVersion("1.1.1")!)
    #expect(SemanticVersion("0.9.9")! < SemanticVersion("0.10.0")!)
    #expect(!(SemanticVersion("1.2.3")! < SemanticVersion("1.2.3")!))
}

private let target = UpdateTarget.utsushie
private let releasePage = URL(string: "https://github.com/tadashi-aikawa/utsushie/releases/tag/v1.3.0")!
private let command = "brew update && brew upgrade --cask utsushie && open -a UTSUSHIE"
private struct NetworkDown: Error {}

private func body(tag: String) -> Data {
    Data(#"{"tag_name":"\#(tag)","html_url":"\#(releasePage.absoluteString)","assets":[]}"#.utf8)
}

@Test func targetDerivesURLsAndCommand() {
    #expect(target.repo == "tadashi-aikawa/utsushie")
    #expect(target.latestReleaseAPIURL.absoluteString == "https://api.github.com/repos/tadashi-aikawa/utsushie/releases/latest")
    #expect(target.releasesPageURL.absoluteString == "https://github.com/tadashi-aikawa/utsushie/releases")
    #expect(target.caskroomPaths == ["/opt/homebrew/Caskroom/utsushie", "/usr/local/Caskroom/utsushie"])
    #expect(target.brewUpgradeCommand == command)
}

@Test func developmentBuildSkipsFetch() async throws {
    var fetched = false
    let result = try await UpdateCheckLogic.check(currentVersion: "0.0.0-development") {
        fetched = true
        return (200, body(tag: "v1.3.0"))
    }
    #expect(result == .developmentBuild(currentVersion: "0.0.0-development"))
    #expect(!fetched)
}
@Test func newerReleaseUsesHTMLURL() async throws {
    let result = try await UpdateCheckLogic.check(currentVersion: "1.2.3") { (200, body(tag: "v1.3.0")) }
    #expect(result == .updateAvailable(current: .init(major: 1, minor: 2, patch: 3), latest: .init(major: 1, minor: 3, patch: 0),
                                       releasePageURL: releasePage))
}
@Test func sameOrOlderReleaseIsUpToDate() async throws {
    for current in ["1.3.0", "1.10.0"] {
        let result = try await UpdateCheckLogic.check(currentVersion: current) { (200, body(tag: "v1.3.0")) }
        #expect(result == .upToDate(current: SemanticVersion(current)!))
    }
}
@Test func responseWithoutAssetsSucceeds() async throws {
    let data = Data(#"{"tag_name":"v1.3.0","html_url":"\#(releasePage.absoluteString)"}"#.utf8)
    let result = try await UpdateCheckLogic.check(currentVersion: "1.2.3") { (200, data) }
    #expect(result == .updateAvailable(current: .init(major: 1, minor: 2, patch: 3), latest: .init(major: 1, minor: 3, patch: 0),
                                       releasePageURL: releasePage))
}
@Test func responseWithoutTagNameFails() async {
    let data = Data(#"{"html_url":"\#(releasePage.absoluteString)","assets":[]}"#.utf8)
    await #expect(throws: DecodingError.self) { try await UpdateCheckLogic.check(currentVersion: "1.2.3") { (200, data) } }
}
@Test func httpStatusAndBadTagFail() async {
    await #expect(throws: UpdateCheckError.apiFailed(statusCode: 403)) {
        try await UpdateCheckLogic.check(currentVersion: "1.2.3") { (403, Data()) }
    }
    await #expect(throws: UpdateCheckError.invalidTag("nightly")) {
        try await UpdateCheckLogic.check(currentVersion: "1.2.3") { (200, body(tag: "nightly")) }
    }
    #expect(UpdateCheckError.apiFailed(statusCode: 404).localizedDescription == "GitHub API の呼び出しに失敗しました (HTTP 404)")
    #expect(UpdateCheckError.invalidTag("nightly").localizedDescription == "リリースタグを解釈できませんでした: nightly")
}
@Test func fetchErrorPassesThrough() async {
    await #expect(throws: NetworkDown.self) { try await UpdateCheckLogic.check(currentVersion: "1.2.3") { throw NetworkDown() } }
}

private let current = SemanticVersion(major: 1, minor: 2, patch: 3)
private let latest = SemanticVersion(major: 2, minor: 0, patch: 0)
private let available = UpdateCheckResult.updateAvailable(current: current, latest: latest, releasePageURL: releasePage)

@Test func developmentBuildAlertKeepsRawVersion() {
    let content = UpdateAlertContent.forResult(.developmentBuild(currentVersion: "0.0.0-development"), target: target,
                                               isInstalledViaHomebrew: true, keepsRunning: false)
    #expect(content == .init(title: "開発ビルドです", message: "開発ビルド(0.0.0-development)ではアップデート確認をスキップします。",
                             style: .informational, primaryButton: nil))
}
@Test func upToDateAlertUsesParsedVersion() {
    // 先頭のvを外したSemVerの表記で出す。
    let content = UpdateAlertContent.forResult(.upToDate(current: SemanticVersion("v1.2.3")!), target: target,
                                               isInstalledViaHomebrew: true, keepsRunning: false)
    #expect(content == .init(title: "最新版です", message: "UTSUSHIE v1.2.3 は最新です。", style: .informational, primaryButton: nil))
}
@Test func homebrewAlertCopiesCommandAndQuits() {
    let content = UpdateAlertContent.forResult(available, target: target, isInstalledViaHomebrew: true, keepsRunning: false)
    #expect(content == .init(title: "v2.0.0 が利用可能です",
                             message: "Homebrew でインストールされているため、以下のコマンドで更新してください。\n\n\(command)\n\nコピーすると UTSUSHIE は終了します(更新完了後に自動で起動します)。",
                             style: .informational, primaryButton: .init(title: "コマンドをコピーして終了", action: .copyCommandAndQuit(command: command))))
}
@Test func homebrewAlertDuringWorkOnlyCopies() {
    let content = UpdateAlertContent.forResult(available, target: target, isInstalledViaHomebrew: true, keepsRunning: true)
    #expect(content == .init(title: "v2.0.0 が利用可能です",
                             message: "Homebrew でインストールされているため、以下のコマンドで更新してください。\n\n\(command)\n\n作業中のため UTSUSHIE は終了しません。作業を終えてから UTSUSHIE を終了し、コマンドを実行してください。",
                             style: .informational, primaryButton: .init(title: "コマンドをコピー", action: .copyCommand(command: command))))
}
@Test func manualInstallAlertOpensReleasePage() {
    // 作業中でもHomebrew以外は終了しないので変わらない。
    for keepsRunning in [false, true] {
        let content = UpdateAlertContent.forResult(available, target: target, isInstalledViaHomebrew: false, keepsRunning: keepsRunning)
        #expect(content == .init(title: "v2.0.0 が利用可能です", message: "現在のバージョン: 1.2.3\nリリースページから新しいバージョンを入手できます。",
                                 style: .informational, primaryButton: .init(title: "リリースページを開く", action: .openURL(releasePage))))
    }
}
@Test func failureAlertIsWarningAndOpensReleasesList() {
    let content = UpdateAlertContent.forFailure(errorDescription: "GitHub API の呼び出しに失敗しました (HTTP 500)", target: target)
    #expect(content == .init(title: "アップデートを確認できませんでした",
                             message: "GitHub API の呼び出しに失敗しました (HTTP 500)\n\nリリースページで最新のバージョンを確認できます。",
                             style: .warning, primaryButton: .init(title: "リリースページを開く", action: .openURL(target.releasesPageURL))))
    #expect(UpdateAlertContent.closeButtonTitle == "閉じる")
}

private func counting(_ kinds: BackgroundWorkCount.Kind...) -> BackgroundWorkCount {
    var count = BackgroundWorkCount()
    for kind in kinds { count.begin(kind) }
    return count
}

@Test func workStateKeepsRunningDuringAnyWork() {
    #expect(!UpdateWorkState().keepsRunning)
    for phase in [RecordingPhase.starting, .recording, .finalizing] { #expect(UpdateWorkState(recording: phase).keepsRunning) }
    #expect(UpdateWorkState(stoppingStream: true).keepsRunning)
    #expect(UpdateWorkState(editorOpen: true).keepsRunning)
    // ファイルへ書く作業は、どの種類でも作業中になる。
    for kind in BackgroundWorkCount.Kind.allCases { #expect(UpdateWorkState(fileWork: counting(kind)).keepsRunning) }
}
@Test func selectingIsNotWorkButDefersAlert() {
    // 範囲選択は失う作業ではないが、選択画面のキーモニターがアラート宛てのReturnを拾うので待たせる。
    #expect(!UpdateWorkState(selecting: true).keepsRunning)
    #expect(UpdateWorkState(selecting: true).defersAlert)
}
@Test func capturingScreenDefersAlertUntilLiveImageIsTaken() {
    // 要素選択や止め損ねた回は、選択画面を閉じてから実画面を撮る。その間に出すと撮った画像へ写る。
    #expect(UpdateWorkState(capturingScreen: true).defersAlert)
    #expect(!UpdateWorkState(capturingScreen: true).keepsRunning)
    // 取り終えてエンコードと保存へ移ったら、作業中のまま表示待ちだけ解く。
    let saving = UpdateWorkState(fileWork: counting(.captureSave))
    #expect(!saving.defersAlert && saving.keepsRunning)
}
@Test func workStateDefersAlertUntilStreamHasStopped() {
    #expect(UpdateWorkState(recording: .starting).defersAlert && UpdateWorkState(recording: .recording).defersAlert)
    // 停止の操作で.finalizingになっても、ストリームが止まり切るまでは待たせる。
    #expect(UpdateWorkState(recording: .finalizing, stoppingStream: true).defersAlert)
    #expect(!UpdateWorkState(recording: .finalizing).defersAlert && !UpdateWorkState().defersAlert)
    let allFileWork = counting(.captureSave, .annotationSave, .videoExport, .importFiles, .saveCopy, .trash)
    #expect(!UpdateWorkState(fileWork: allFileWork, editorOpen: true).defersAlert)
}
@Test func followUpAlertsAfterButtonAction() {
    let content = UpdateAlertContent.forResult(available, target: target, isInstalledViaHomebrew: true, keepsRunning: false)
    #expect(content.followUp(after: .finished, target: target) == nil)
    // コピーに失敗したら同じアラート、終了を止めたら理由のアラートを、どちらも表示待ちの判定を通して出す。
    #expect(content.followUp(after: .copyFailed, target: target) == content)
    #expect(content.followUp(after: .quitWithheld, target: target) == .quitWithheld(target: target))
}
@Test func backgroundWorkCountsEachKindIndependently() {
    var count = BackgroundWorkCount()
    #expect(!count.isActive(.videoExport) && !count.isActive(.importFiles))
    count.begin(.videoExport); count.begin(.videoExport); count.begin(.importFiles)
    count.end(.videoExport)
    #expect(count.isActive(.videoExport) && count.isActive(.importFiles))
    count.end(.videoExport); count.end(.importFiles)
    #expect(count == BackgroundWorkCount())
    // 対になるbeginの無いendで負にならず、次のbeginで作業中になる。
    count.end(.importFiles); count.begin(.importFiles)
    #expect(count.isActive(.importFiles))
}
@Test func fileWorkIsIdleOnlyWhenEveryKindHasEnded() {
    var count = counting(.annotationSave, .saveCopy)
    #expect(!count.isIdle)
    count.end(.annotationSave)
    #expect(!count.isIdle && UpdateWorkState(fileWork: count).keepsRunning)
    count.end(.saveCopy)
    #expect(count.isIdle && !UpdateWorkState(fileWork: count).keepsRunning)
}
@Test func quitWithheldAlertExplainsWhy() {
    #expect(UpdateAlertContent.quitWithheld(target: target) == .init(title: "UTSUSHIE は終了していません",
        message: "作業中のため UTSUSHIE は終了しません。作業を終えてから UTSUSHIE を終了し、コマンドを実行してください。",
        style: .informational, primaryButton: nil))
}

private struct ActionLog { var copied: [String] = []; var quits = 0; var opened: [URL] = [] }
private func run(_ action: UpdateAlertContent.Action, keepsRunning: Bool, copySucceeds: Bool = true) -> (UpdateAlertOutcome, ActionLog) {
    var log = ActionLog()
    let outcome = UpdateAlertActionRunner.run(action, keepsRunning: { keepsRunning },
                                              copy: { log.copied.append($0); return copySucceeds },
                                              quit: { log.quits += 1 }, open: { log.opened.append($0) })
    return (outcome, log)
}

@Test func copyAndQuitQuitsWhenIdle() {
    let (outcome, log) = run(.copyCommandAndQuit(command: command), keepsRunning: false)
    #expect(outcome == .finished && log.copied == [command] && log.quits == 1)
}
@Test func copyAndQuitOnlyCopiesWhenWorkStartedAfterAlert() {
    let (outcome, log) = run(.copyCommandAndQuit(command: command), keepsRunning: true)
    #expect(outcome == .quitWithheld && log.copied == [command] && log.quits == 0)
}
@Test func failedCopyDoesNotQuitAndAsksAgain() {
    let (outcome, log) = run(.copyCommandAndQuit(command: command), keepsRunning: false, copySucceeds: false)
    #expect(outcome == .copyFailed && log.quits == 0)
    #expect(run(.copyCommand(command: command), keepsRunning: true, copySucceeds: false).0 == .copyFailed)
}
@Test func copyCommandNeverQuits() {
    for keepsRunning in [false, true] {
        let (outcome, log) = run(.copyCommand(command: command), keepsRunning: keepsRunning)
        #expect(outcome == .finished && log.copied == [command] && log.quits == 0)
    }
}
@Test func openURLOpensOnly() {
    let (outcome, log) = run(.openURL(releasePage), keepsRunning: false)
    #expect(outcome == .finished && log.opened == [releasePage] && log.copied.isEmpty && log.quits == 0)
}

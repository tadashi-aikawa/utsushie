import Foundation

/// アップデート判定用のセマンティックバージョン。
/// `v0.1.2` / `0.1.2` を受け付け、`0.0.0-development` のようなprerelease付きは開発ビルドとして比較しない。
public struct SemanticVersion: Equatable, Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// prerelease付きや、数値3要素で読めない文字列はnil(開発ビルド扱い)。
    public init?(_ string: String) {
        let body = string.hasPrefix("v") ? String(string.dropFirst()) : string
        guard !body.contains("-") else { return nil }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

/// アップデート確認の対象アプリ。repoは`tadashi-aikawa/<cask>`。
public struct UpdateTarget: Equatable, Sendable {
    public static let utsushie = UpdateTarget(appName: "UTSUSHIE", cask: "utsushie")

    /// メニューや文言に出す表示名
    public let appName: String
    /// Homebrewのcask名
    public let cask: String

    public init(appName: String, cask: String) {
        self.appName = appName
        self.cask = cask
    }

    public var repo: String { "tadashi-aikawa/\(cask)" }
    public var latestReleaseAPIURL: URL { URL(string: "https://api.github.com/repos/\(repo)/releases/latest")! }
    public var releasesPageURL: URL { URL(string: "https://github.com/\(repo)/releases")! }
    /// どちらかがあればHomebrewで入れている。
    public var caskroomPaths: [String] { ["/opt/homebrew/Caskroom/\(cask)", "/usr/local/Caskroom/\(cask)"] }
    /// brewが.appを置き換えても起動中のプロセスは古いまま動くので、末尾の`open -a`で新しいほうを起動させる。
    public var brewUpgradeCommand: String { "brew update && brew upgrade --cask \(cask) && open -a \(appName)" }
}

/// GitHub Releases API`releases/latest`の応答のうち、アップデート確認に使う項目。
public struct LatestReleaseResponse: Decodable, Equatable, Sendable {
    public let tagName: String
    public let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

public enum UpdateCheckResult: Equatable, Sendable {
    /// 現在のバージョンがSemVerとして読めないので確認しない
    case developmentBuild(currentVersion: String)
    /// 既に最新
    case upToDate(current: SemanticVersion)
    /// 新しいバージョンがある
    case updateAvailable(current: SemanticVersion, latest: SemanticVersion, releasePageURL: URL)
}

public enum UpdateCheckError: LocalizedError, Equatable {
    case apiFailed(statusCode: Int)
    case invalidTag(String)

    public var errorDescription: String? {
        switch self {
        case .apiFailed(let statusCode): "GitHub API の呼び出しに失敗しました (HTTP \(statusCode))"
        case .invalidTag(let tag): "リリースタグを解釈できませんでした: \(tag)"
        }
    }
}

public enum UpdateCheckLogic {
    /// 現在のバージョンがSemVerとして読めなければ、取得せずに開発ビルドとする。
    /// `fetchLatestRelease`は`releases/latest`のHTTPステータスと本文を返す。HTTP以外の応答なら-1。
    /// 通信エラーは`fetchLatestRelease`が投げたものをそのまま投げる。
    public static func check(currentVersion: String,
                             fetchLatestRelease: () async throws -> (statusCode: Int, body: Data)) async throws -> UpdateCheckResult {
        guard let current = SemanticVersion(currentVersion) else { return .developmentBuild(currentVersion: currentVersion) }
        let (statusCode, body) = try await fetchLatestRelease()
        guard statusCode == 200 else { throw UpdateCheckError.apiFailed(statusCode: statusCode) }
        let release = try JSONDecoder().decode(LatestReleaseResponse.self, from: body)
        guard let latest = SemanticVersion(release.tagName) else { throw UpdateCheckError.invalidTag(release.tagName) }
        guard current < latest else { return .upToDate(current: current) }
        return .updateAvailable(current: current, latest: latest, releasePageURL: release.htmlURL)
    }
}

/// ファイルへ書き出す・変換する非同期の作業を、カードや一覧の寿命と切り離して数える。
/// 開始で増やし、完了・失敗・取り消しのどれでも減らす。
/// カードと編集画面は一覧を閉じると外れるので、それらの状態からは書いている途中かを決められない。
/// 録画とスクロール撮影の書き出しは、アプリが持つ`RecordingState`の`.finalizing`で数える。
public struct BackgroundWorkCount: Equatable, Sendable {
    public enum Kind: Hashable, Sendable, CaseIterable {
        /// 撮った画像の切り出し・WebPのエンコード・保存
        case captureSave
        /// 注釈の完了後のWebPのエンコードと同名置換
        case annotationSave
        /// 動画編集の完了後の書き出しと静止画の保存
        case videoExport
        /// Finderからの取り込み。MP4への変換とWebPの保存
        case importFiles
        /// カードと一覧からの別名保存
        case saveCopy
        /// カードと一覧からのゴミ箱への移動
        case trash
    }

    private var counts: [Kind: Int] = [:]

    public init() {}

    public mutating func begin(_ kind: Kind) { counts[kind, default: 0] += 1 }
    /// 対になるbeginの無いendでは負にしない。
    public mutating func end(_ kind: Kind) {
        let remaining = (counts[kind] ?? 0) - 1
        counts[kind] = remaining > 0 ? remaining : nil
    }
    public func isActive(_ kind: Kind) -> Bool { (counts[kind] ?? 0) > 0 }
    /// どの種類も数えていない。
    public var isIdle: Bool { counts.isEmpty }
}

/// 終了させると失う作業が進んでいるか。アップデートの案内で終了するかと、アラートを出す時機を決める。
public struct UpdateWorkState: Equatable, Sendable {
    /// 録画・スクロール撮影の準備中から書き出しの完了まで
    public var recording: RecordingPhase
    /// 停止を操作してから、撮影のストリームが止まり切るまで。`recording`は既に`.finalizing`
    public var stoppingStream: Bool
    /// ファイルへ書き出す・変換する非同期の作業
    public var fileWork: BackgroundWorkCount
    /// 注釈・動画の編集画面
    public var editorOpen: Bool
    /// 範囲選択の画面と、それを出す前に画面を止めている間
    public var selecting: Bool
    /// 選択画面を閉じてから、画像の撮影で実画面を取得し終えるまで。止めた画面が無いときだけ通る
    public var capturingScreen: Bool

    public init(recording: RecordingPhase = .idle, stoppingStream: Bool = false, fileWork: BackgroundWorkCount = .init(),
                editorOpen: Bool = false, selecting: Bool = false, capturingScreen: Bool = false) {
        self.recording = recording
        self.stoppingStream = stoppingStream
        self.fileWork = fileWork
        self.editorOpen = editorOpen
        self.selecting = selecting
        self.capturingScreen = capturingScreen
    }

    /// 当たる間は「コマンドをコピー」だけにして終了しない。
    public var keepsRunning: Bool { recording != .idle || stoppingStream || !fileWork.isIdle || editorOpen }
    /// 当たる間はアップデート確認のアラートをどれも出さない。
    /// 撮っている間は撮影範囲へ写り込み、モーダルの間は録画のタイマーも止まる。停止の操作の後も、ストリームが止まり切るまでは末尾のコマへ写りうる。
    /// 範囲選択の間は、選択画面のキーモニターがアラート宛てのReturnを拾い、前回範囲の撮影・録画を始めうる。
    /// 選択画面を閉じた後も、実画面を取得し終えるまでは撮った画像へ写りうる。
    public var defersAlert: Bool {
        selecting || capturingScreen || recording == .starting || recording == .recording || stoppingStream
    }
}

/// アップデート確認の結果として出すNSAlertの中身。
public struct UpdateAlertContent: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        case informational
        case warning
    }

    public enum Action: Equatable, Sendable {
        /// コマンドをクリップボードへ入れてアプリを終了する
        case copyCommandAndQuit(command: String)
        /// コマンドをクリップボードへ入れるだけ
        case copyCommand(command: String)
        case openURL(URL)
    }

    public struct Button: Equatable, Sendable {
        public let title: String
        public let action: Action
    }

    /// primaryButtonの隣に並べるボタン
    public static let closeButtonTitle = "閉じる"

    public let title: String
    public let message: String
    public let style: Style
    /// nilなら既定のOKだけ。あれば「閉じる」と並べる
    public let primaryButton: Button?

    public static func forResult(_ result: UpdateCheckResult, target: UpdateTarget, isInstalledViaHomebrew: Bool,
                                 keepsRunning: Bool) -> UpdateAlertContent {
        switch result {
        case .developmentBuild(let currentVersion):
            return UpdateAlertContent(title: "開発ビルドです", message: "開発ビルド(\(currentVersion))ではアップデート確認をスキップします。",
                                      style: .informational, primaryButton: nil)
        case .upToDate(let current):
            return UpdateAlertContent(title: "最新版です", message: "\(target.appName) v\(current) は最新です。",
                                      style: .informational, primaryButton: nil)
        case .updateAvailable(let current, let latest, let releasePageURL):
            let title = "v\(latest) が利用可能です"
            guard isInstalledViaHomebrew else {
                return UpdateAlertContent(title: title, message: "現在のバージョン: \(current)\nリリースページから新しいバージョンを入手できます。",
                                          style: .informational, primaryButton: Button(title: "リリースページを開く", action: .openURL(releasePageURL)))
            }
            let command = target.brewUpgradeCommand
            let head = "Homebrew でインストールされているため、以下のコマンドで更新してください。\n\n\(command)\n\n"
            let app = target.appName
            if keepsRunning {
                return UpdateAlertContent(title: title,
                                          message: head + "作業中のため \(app) は終了しません。作業を終えてから \(app) を終了し、コマンドを実行してください。",
                                          style: .informational, primaryButton: Button(title: "コマンドをコピー", action: .copyCommand(command: command)))
            }
            return UpdateAlertContent(title: title, message: head + "コピーすると \(app) は終了します(更新完了後に自動で起動します)。",
                                      style: .informational,
                                      primaryButton: Button(title: "コマンドをコピーして終了", action: .copyCommandAndQuit(command: command)))
        }
    }

    /// 「コマンドをコピーして終了」を押した時点で作業中だったので、コピーだけして終了しなかった。
    public static func quitWithheld(target: UpdateTarget) -> UpdateAlertContent {
        let app = target.appName
        return UpdateAlertContent(title: "\(app) は終了していません",
                                  message: "作業中のため \(app) は終了しません。作業を終えてから \(app) を終了し、コマンドを実行してください。",
                                  style: .informational, primaryButton: nil)
    }

    /// ボタンの動作の後に続けて出すアラート。結果のアラートと同じく、表示を待てるときは待ってから出す。
    public func followUp(after outcome: UpdateAlertOutcome, target: UpdateTarget) -> UpdateAlertContent? {
        switch outcome {
        case .finished: nil
        case .copyFailed: self
        case .quitWithheld: .quitWithheld(target: target)
        }
    }

    public static func forFailure(errorDescription: String, target: UpdateTarget) -> UpdateAlertContent {
        UpdateAlertContent(title: "アップデートを確認できませんでした", message: "\(errorDescription)\n\nリリースページで最新のバージョンを確認できます。",
                           style: .warning, primaryButton: Button(title: "リリースページを開く", action: .openURL(target.releasesPageURL)))
    }
}

public enum UpdateAlertOutcome: Equatable, Sendable {
    case finished
    /// クリップボードへ書けなかった。終了せず、同じアラートをもう一度出す
    case copyFailed
    /// コピーしたが、押した時点で作業中だったので終了しなかった。理由を知らせる
    case quitWithheld
}

public enum UpdateAlertActionRunner {
    /// 押したボタンの動作を行う。終了の直前に作業中かをもう一度確かめ、当たればコピーだけにする。
    /// アラートを出してから押すまでに、撮影や編集が始まることがあるため。
    public static func run(_ action: UpdateAlertContent.Action, keepsRunning: () -> Bool, copy: (String) -> Bool,
                           quit: () -> Void, open: (URL) -> Void) -> UpdateAlertOutcome {
        switch action {
        case .copyCommandAndQuit(let command):
            guard copy(command) else { return .copyFailed }
            guard !keepsRunning() else { return .quitWithheld }
            quit()
        case .copyCommand(let command):
            guard copy(command) else { return .copyFailed }
        case .openURL(let url):
            open(url)
        }
        return .finished
    }
}

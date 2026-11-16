import Foundation

/// Finderから渡されたファイルが画像か動画か。型の判定はアプリ側のUTTypeで行う。
public enum CaptureImportMedia: Sendable, Equatable { case image, video }

/// 取り込むファイルを保存フォルダへどう写すか。
public enum CaptureImportAction: Sendable, Equatable {
    /// 保存フォルダ直下のWebP・MP4。写さずにそのファイルを編集する。
    case editInPlace
    /// WebPは再圧縮で劣化させないよう、バイト列をそのまま写す。
    case copyWebP
    /// ImageIOで読み、設定の品質でWebPへエンコードする。
    case encodeImage
    /// MP4は中身を変えずに写す。向きの指定があれば焼き込むため変換する。
    case copyMP4
    /// MOVなどをMP4へ入れ替える。入らなければ再エンコードする。
    case convertVideo
}

public enum CaptureImport {
    /// 写す先の名前は撮影と同じ書式で取り込んだ日時から作るので、元の名前は判定にしか使わない。
    public static func action(for file: URL, media: CaptureImportMedia, outputDirectory: URL) -> CaptureImportAction {
        let ext = file.pathExtension.lowercased()
        let name = file.lastPathComponent
        let direct = file.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL.path
            == outputDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        // 一覧に出るファイルだけをその場で編集する。隠しファイルと録画中の一時ファイルは写して扱う。
        let listed = !name.hasPrefix(".") && !name.lowercased().hasSuffix(".recording.mp4")
        switch media {
        case .image:
            if ext == "webp" { return direct && listed ? .editInPlace : .copyWebP }
            return .encodeImage
        case .video:
            if ext == "mp4" { return direct && listed ? .editInPlace : .copyMP4 }
            return .convertVideo
        }
    }
    /// Retinaのスクリーンショットは144dpiで書かれる。それ以外は撮影時の倍率が分からないので1xにする。
    public static func pixelScale(dpiWidth: Double?, dpiHeight: Double?) -> Double {
        guard let dpiWidth, let dpiHeight, abs(dpiWidth - 144) < 0.5, abs(dpiHeight - 144) < 0.5 else { return 1 }
        return 2
    }
    public static func fitsWebP(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= ScrollStitcher.webPLimit && height <= ScrollStitcher.webPLimit
    }
    public static func tooLargeMessage(width: Int, height: Int) -> String {
        "\(width)×\(height)pxはWebPに入りません。1辺\(ScrollStitcher.webPLimit)pxまでです"
    }
    /// 動画のfpsは映像トラックの公称値を丸める。読めなければ設定のfpsに任せる。
    public static func frameRate(nominal: Float) -> Int? {
        guard nominal.isFinite, nominal >= 1 else { return nil }
        return Int(nominal.rounded())
    }
    /// 複数のファイルの失敗をまとめて1回だけ知らせる。
    public static func failureMessage(_ failures: [(name: String, reason: String)]) -> String {
        failures.map { "\($0.name): \($0.reason)" }.joined(separator: "\n")
    }
}

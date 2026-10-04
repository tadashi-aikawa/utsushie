# CLAUDE

## プロダクト

UTSUSHIE(写絵)は、画面をWebP画像またはMP4動画で保存し、クリップボードと共有カードから渡すmacOSネイティブアプリです。

## リポジトリ構成

- `Sources/UtsushieCore/`: ロジック層。AppKit・Processは置きません。
  - `Config.swift`: TOMLパース、項目ごとの検証と既定値。
  - `Geometry.swift`: AppKitとCGの反転、画面ローカル座標、1x寸法、ディスプレイ跨ぎ。
  - `CaptureState.swift`: 対象と出力の状態、物理キーの遷移。
  - `SelectionGesture.swift`: クリック取り消しの閾値、範囲選択と前回枠移動のジェスチャー。
  - `FileNaming.swift`: ファイル名と前回範囲の永続化。
  - `Video.swift`: 動画の偶数寸法・単一画面判定・録画状態・VFRの時間計算・表示文言。
  - `Annotation.swift`: 画像ピクセル座標の注釈モデル、連番、スタイル、ヒットテスト、変形と履歴。
- `Sources/Utsushie/`: AppKit・ScreenCaptureKit・ApplicationServicesの実行ターゲット。Swift 6。
  - `AppDelegate.swift`: メニュー、権限、設定の再読込、撮影から共有までの流れ。
  - `GlobalHotkey.swift`: Carbonのグローバルホットキー。
  - `OverlayController.swift`: 全画面の選択パネルと物理キー入力。
  - `ScreenGeometry.swift`: NSScreenからCoreの座標モデルを作る境界。
  - `ChromeArea.swift`: Chromeの最前面ウィンドウからAXWebAreaを探索。
  - `CaptureService.swift`: 自アプリ除外、画面ごとの撮影と合成、単一ウィンドウ撮影。
  - `RecordingService.swift`: SCStreamの構成、単一画面の領域録画、移動を追うウィンドウ録画。
  - `MP4Writer.swift`: 専用キューでcompleteフレームをH.264/MP4へ書く。末尾保持とfinalize。
  - `RecordingBorder.swift`: 入力を透過する範囲外の赤枠。
  - `WebPEncoder.swift`: sRGBへの変換とlibwebpエンコード。
  - `Sharing.swift`: 画像と動画が共有するファイル・クリップボード層。
  - `ThumbnailController.swift`: 非アクティブカード、寿命、D&D、追加保存。
  - `AnnotationEditorController.swift`: 非アクティブパネルの注釈編集、ジェスチャー、標準文字入力とキー操作。
  - `AnnotationRenderer.swift`: 元画像からのモザイク・暗幕・朱の注釈の合成。
  - `AnnotationSave.swift`: 注釈付きWebPの同名置換とコピー失敗時の復元。
- `Tests/UtsushieCoreTests/`: 設定・座標・状態・ファイル名のswift-testing。
- `Tests/UtsushieAppTests/`: WebP実エンコード、MP4実書き込みと再生時間、保存の衝突、クリップボードの形式。
- `Resources/Info.plist`: bundle ID、LSUIElement、macOS 26。
- `Resources/utsushie.png` / `utsushie.icns`: ロゴの元画像とアプリアイコン。管理は [ロゴの管理](docs/logo.md)
- `scripts/make-app.sh`: `.build/UTSUSHIE.app`の組み立て、ICNS・ライセンス同梱と署名。
- `scripts/make-icon.sh`: PNGからICNSを再生成する。
- `scripts/build_release.sh` / `render_cask.sh` / `update_tap.sh`: リリース用。下の「リリース方法」

## 変える前に知っておくこと

- 色は`UITheme.swift`の定数を共有します。システムの強調色と`systemRed`は使いません。
  - テーマ: 藍`#4270C0`。範囲・ウィンドウ選択の鉤とカードの「コピー済み」に使います。
  - 編集画面: 「完了」と選択中の道具も藍で強調します。注釈のインクは赤のままです。
  - 赤: 録画・注釈・失敗だけ。線は`#E5352A`、白文字の面は`#D23125`です。
  - 意味: 赤いUIには「●」「■」「!」か録画の言葉を添えます。
  - 地: 帯・札・カードは固定の墨`#1C1C1E`。帯・寸法・前回の札・カードのボタン・メニューは無彩色です。
- 選択の鉤と下地の縁は選択範囲の外側へ描きます。
  - 下地: 画像選択は生成り`#F3EBDA`、動画選択は白の線を重ねます。外向きの影は使いません。
  - 理由: 撮った画像の縁へ写り込ませないためです。
- 注釈はカードが保持する撮影時のCGImageから合成します。
  - 理由: 保存済みWebPをデコードして再圧縮すると、再編集のたびに画像が劣化します。
  - 座標: 注釈だけは画像左上原点のピクセル座標です。Coreの画面座標とは混ぜません。
- 注釈は元画像の上へ、次の順で重ねます。
  - 1: モザイク
  - 2: スポットライト暗幕
  - 3: 枠と矢印
  - 4: 文字
  - 5: 番号
  - 暗幕: 穴を個別にクリアし、重なった穴も明るい和集合にします。
- 注釈編集のカード非表示と、撮影中の一時非表示は独立して扱います。
  - 寿命: 編集が完了または破棄されたら最初から数え直します。
- 文字入力はNSTextViewのinput contextへ渡します。
  - 注意: IME変換確定のEnterで注釈を確定しません。文字入力中のキーをツール変更へ横取りしません。
  - ツール変更: 編集キャンバスのkeyDownで物理keyCodeを判定します。
- 枠・スポットライト・モザイクは、ツール使用中には縁だけを移動のヒットテストへ使います。
  - 選択モード: 内側も移動できます。新しい注釈は作りません。
  - 選択中: 四隅と各辺のリサイズ判定を優先します。
  - 判定: 操作とカーソルはCoreの同じinteractionから決めます。
- 編集ウィンドウのEscは文字入力の確定、選択モードへの復帰、選択解除に使います。
  - 注意: IME変換中のEscはinput contextに任せます。破棄には使いません。
  - 破棄: 修飾なしの物理Qキー・ボタン・閉じる操作・⌘Wで確認を経て閉じます。文字入力中のQは入力へ渡します。
- 新しい共有カードは最新の1枚だけを非アクティブのままキー化します。
  - ホバー: 古いカードでも受け手をそのカードへ切り替え、ほかのカードはキーを手放します。
  - 継続: カーソルが離れても受け手を変えません。無関係なカードの終了でも受け手を変えません。
  - 寿命: キー取得とホバーは独立です。キー取得だけではタイマーを止めません。
  - 解除: 別アプリへのクリックでキーを失ったら取り戻しません。閉じるとキーを元のアプリへ返します。
- 注釈編集は生成時からnonactivatingPanelを持つNSPanelで開きます。
  - 表示: アプリをactivateせず、orderFrontRegardlessとmakeKeyで前面に出して入力を受けます。
  - 入力: キャンバス・文字入力・ツールボタンはneedsPanelToBecomeKeyとacceptsFirstMouseを明示します。IMEと⌘キーはresponder経由で扱います。
  - 終了: アプリのアクティベーションは変更しません。戻すカードもキーを取り直さず、貼り付け先のフォーカスを奪いません。
  - シート: 保存失敗は標準NSAlertのシートで表示します。表示中は編集のキー操作を処理しません。
- 注釈の保存は同じフォルダの隠し一時ファイルから原子的に同名置換します。
  - 失敗: エンコードや置換の失敗ではコピーしません。コピー失敗では元ファイルのバイトを復元します。

- 利用者向けの操作と設定の正本は[README](README.md)です。
  - READMEには利用者が使う情報だけを書きます。設計の理由や内部の挙動はこのファイルかコードのコメントに書きます。
- 設定ファイルへ状態を書き戻しません。
  - 理由: ユーザーが編集する設定の正本を保つためです。前回範囲だけ別JSONへ保存します。
- Coreの座標はAppKitの主ディスプレイ左下原点です。
  - 注意: CG/AXの反転には主画面の高さを使います。全画面のmaxYは使いません。
- クリップボードには要求されたファイルURLとWebPデータだけを載せます。
  - 注意: NSImageをpasteboardへ渡すとPNG/TIFFなどが追加されます。
- 動画は設定によらずファイルURLだけを載せます。
  - 理由: MP4のバイト列をクリップボードへ載せても対応アプリが少なく、メモリを消費します。
- SCStreamとAVAssetWriterの可変状態は専用のシリアルキューで扱います。
  - 注意: SwiftのSendableを付けるだけで任意スレッドから操作してよい訳ではありません。
- complete以外のSCStreamフレームは書きません。
  - 時間: VFRの時刻差を保ち、停止時に最後のcompleteフレームを複製して静止時間を保持します。
- 完成前のMP4は同じ保存先の隠し一時ファイルへ書きます。
  - 公開: finalize成功後に衝突を避けて改名します。共有とカードの寿命は完成後に始めます。
- ウィンドウの移動は独立ウィンドウのフィルターで追います。
  - 注意: 枠の座標を追うタイマーは録画内容をクロップしません。出力寸法は開始時の値を保ちます。
- 自アプリの除外はSCContentFilterで行います。
  - 理由: パネルを隠すタイミングだけでは合成直前の写り込みを保証できません。
  - 手順: 録画準備ではオーバーレイ表示中に自アプリを列挙し、その後で選択画面を閉じます。
- IMEへ渡る前のlocal monitorで物理keyCodeを判定します。
  - 注意: modifierFlagsの`.function`は修飾キーの判定へ含めません。
- 非アクティブパネルのビューは`acceptsFirstMouse`を明示します。
  - 注意: `.nonactivatingPanel`だけでは最初のクリックがビューへ届きません。
- 範囲選択の十字カーソルは、各画面のビューのカーソル矩形と`cursorUpdate`で保ちます。
  - 理由: `NSCursor.set()`だけではカーソルの適用領域が登録されず、AppKitからのカーソル更新に応答できないためです。
  - 追跡: マウスの移動・進入は`.activeAlways`で受けます。
  - 更新: カーソル更新は別の`.activeInKeyWindow`のtracking areaへ分けます。
    - 理由: `.activeAlways`と`.cursorUpdate`を組み合わせても通知されません。
  - 別画面: ドラッグ中以外はマウス下のパネルを非アクティブのままキー化します。
  - ドラッグ: 入力の配送先は変えず、現在のカーソルを再設定します。
  - 切替: Wのウィンドウ選択だけ矢印にします。対象の変更時は全画面のカーソル矩形を無効化します。
  - 終了: 矢印へ戻します。
- 共有カードの表示時にキーウィンドウとfirst responderを設定します。
  - 検証: 非アクティブの状態で、ホバーなしのE・S・O・X・Escが届くことは実機で確かめます。
- 署名は固定証明書と固定bundle IDを保ちます。
  - 理由: ビルドのたびにTCCの許可を外さないためです。
- 依存は`Package.resolved`とexact指定で固定します。
  - 注意: libwebpのセキュリティ更新時は固定版の更新と実エンコード試験を行います。

## コミット規約

Conventional Commits形式で日本語のdescriptionを使います。

owleryメンバーの作業ではauthorをメンバー名にします。委譲時のコミット禁止指示があればそちらを優先します。

## ビルドとテスト

macOS 26以降とSwift 6.2以降が必要です。

```sh
swift build
swift test
./scripts/make-app.sh release
open .build/UTSUSHIE.app
```

- 署名はUTSUSHIE専用の自己署名証明書`utsushie-dev`を使います。
  - 設定: 別の証明書は`CODESIGN_IDENTITY`で指定できます。
  - 証明書がなければad-hoc署名になり、再ビルドのたびに権限の再許可が要ることがあります。
- 依存は`Package.swift`を参照してください。libwebpはSwiftPMでCソースから同梱し、ライセンスとPATENTSを`.app`に含めます。

権限と入力の受入試験は組み立てた`.app`で行います。

- ユニットテストはCoreロジックと形式の契約を確かめます。
  - 限界: ホットキー、IME、AX、実画面のSCStream、非アクティブのクリック、外部アプリの貼り付け対応は保証しません。
- 試験コードは一時フォルダとNSPasteboardItemを使います。
  - 効果: 利用者の保存フォルダや一般クリップボードを変更しません。

## リリース方法

- `.github/workflows/release.yml`をmainで手動起動します。
  - 処理: semantic-releaseがバージョンを決め、GitHub ReleasesへZIPを公開し、Homebrew tapのCaskを更新します。
- `scripts/build_release.sh <version>`でローカルの配布用ZIPを作れます。
  - 出力: `dist/UTSUSHIE-<version>.zip`
  - 署名: 既定の固定証明書は`utsushie-dev`です。CIでは専用証明書の署名を必須にします。
- `scripts/render_cask.sh <version> <sha256>`でCaskを標準出力へ書き出せます。

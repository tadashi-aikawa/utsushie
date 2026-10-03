# CLAUDE

## プロダクト

UTSUSHIE(写絵)は、画面をWebPで撮影し、クリップボードと共有カードから渡すmacOSネイティブアプリです。

フェーズ1は画像撮影のみです。Videoの状態は定義しています。録画処理は後から追加します。

## リポジトリ構成

- `Sources/UtsushieCore/`: ロジック層。AppKit・Processは置きません。
  - `Config.swift`: TOMLパース、項目ごとの検証と既定値。
  - `Geometry.swift`: AppKitとCGの反転、画面ローカル座標、1x寸法、ディスプレイ跨ぎ。
  - `CaptureState.swift`: 対象と出力の状態、物理キーの遷移。
  - `SelectionGesture.swift`: クリック取り消しの閾値、範囲選択と前回枠移動のジェスチャー。
  - `FileNaming.swift`: ファイル名と前回範囲の永続化。
- `Sources/Utsushie/`: AppKit・ScreenCaptureKit・ApplicationServicesの実行ターゲット。Swift 6。
  - `AppDelegate.swift`: メニュー、権限、設定の再読込、撮影から共有までの流れ。
  - `GlobalHotkey.swift`: Carbonのグローバルホットキー。
  - `OverlayController.swift`: 全画面の選択パネルと物理キー入力。
  - `ScreenGeometry.swift`: NSScreenからCoreの座標モデルを作る境界。
  - `ChromeArea.swift`: Chromeの最前面ウィンドウからAXWebAreaを探索。
  - `CaptureService.swift`: 自アプリ除外、画面ごとの撮影と合成、単一ウィンドウ撮影。
  - `WebPEncoder.swift`: sRGBへの変換とlibwebpエンコード。
  - `Sharing.swift`: 画像と後続の動画が共有するファイル・クリップボード層。
  - `ThumbnailController.swift`: 非アクティブカード、寿命、D&D、追加保存。
- `Tests/UtsushieCoreTests/`: 設定・座標・状態・ファイル名のswift-testing。
- `Tests/UtsushieAppTests/`: WebP実エンコード、保存の衝突、クリップボードの形式。
- `Resources/Info.plist`: bundle ID、LSUIElement、macOS 26。
- `scripts/make-app.sh`: `.build/UTSUSHIE.app`の組み立て、ライセンス同梱と署名。

## 変える前に知っておくこと

- 仕様と設定の正本は[README](README.md)です。
- 設定ファイルへ状態を書き戻しません。
  - 理由: ユーザーが編集する設定の正本を保つためです。前回範囲だけ別JSONへ保存します。
- Coreの座標はAppKitの主ディスプレイ左下原点です。
  - 注意: CG/AXの反転には主画面の高さを使います。全画面のmaxYは使いません。
- クリップボードには要求されたファイルURLとWebPデータだけを載せます。
  - 注意: NSImageをpasteboardへ渡すとPNG/TIFFなどが追加されます。
- 自アプリの除外はSCContentFilterで行います。
  - 理由: パネルを隠すタイミングだけでは合成直前の写り込みを保証できません。
- IMEへ渡る前のlocal monitorで物理keyCodeを判定します。
  - 注意: modifierFlagsの`.function`は修飾キーの判定へ含めません。
- 非アクティブパネルのビューは`acceptsFirstMouse`を明示します。
  - 注意: `.nonactivatingPanel`だけでは最初のクリックがビューへ届きません。
- 共有カードのホバーでキーウィンドウとfirst responderを設定します。
  - 検証: 非アクティブの状態からS・O・Xが届くことは実機で確かめます。
- 署名は固定証明書と固定bundle IDを保ちます。
  - 理由: ビルドのたびにTCCの許可を外さないためです。
- 依存は`Package.resolved`とexact指定で固定します。
  - 注意: libwebpのセキュリティ更新時は固定版の更新と実エンコード試験を行います。

## コミット規約

Conventional Commits形式で日本語のdescriptionを使います。

owleryメンバーの作業ではauthorをメンバー名にします。委譲時のコミット禁止指示があればそちらを優先します。

## テスト実行

```sh
swift build
swift test
./scripts/make-app.sh
```

権限と入力の受入試験は組み立てた`.app`で行います。

- ユニットテストはCoreロジックと形式の契約を確かめます。
  - 限界: ホットキー、IME、AX、非アクティブのクリック、外部アプリの貼り付け対応は保証しません。
- 試験コードは一時フォルダとNSPasteboardItemを使います。
  - 効果: 利用者の保存フォルダや一般クリップボードを変更しません。

## リリース方法

フェーズ1ではリリース自動化は未構築です。`make-app.sh release <version>`でローカル成果物を作れます。

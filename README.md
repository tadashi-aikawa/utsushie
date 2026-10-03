# UTSUSHIE

UTSUSHIE(写絵)は、画面を軽いWebPとして撮影し、コピーとドラッグで共有するmacOSのメニューバーアプリです。

フェーズ1では画像キャプチャを提供します。Videoは状態切替と未実装の表示のみです。

## 導入

macOS 26以降とSwift 6.2以降のCommand Line Toolsが必要です。

```sh
swift build
swift test
./scripts/make-app.sh
open .build/UTSUSHIE.app
```

`.build/UTSUSHIE.app`を`/Applications`などの固定した場所へコピーして利用してください。

- 署名はKIKIGAKIと同じ自己署名証明書`kikigaki-dev`を使います。
  - 理由: bundle IDと証明書を固定し、再ビルド時の権限を維持するためです。
  - 設定: 別の固定証明書は`CODESIGN_IDENTITY`で指定できます。
- 証明書がなければad-hoc署名になります。
  - 制限: 再ビルドで権限の再許可が必要になる場合があります。

## 権限

- 画面収録を許可してください。
  - 手順: 最初の撮影で案内を表示し、システム設定を開きます。UTSUSHIEを許可したら再起動します。
- Chromeの撮影にはアクセシビリティの許可も必要です。
  - 手順: Cで案内を表示し、システム設定を開きます。Escでオーバーレイを閉じて許可してください。

Dockには表示しません。終了と撮影はメニューバーからも操作できます。

## 操作

既定のホットキーは⌘⇧2です。押すと全画面にオーバーレイが出ます。

| 操作 | 動作 |
| --- | --- |
| ドラッグ | 新しい範囲を選択し、離した時点で撮影 |
| 範囲選択中のクリック | 撮影を取り消す。前回枠の中も同じ |
| Enter / ホットキーをもう一度 | 前回範囲を撮影。前回範囲がない場合は無効 |
| 前回の破線枠の中をドラッグ | 寸法を維持して移動。位置を保存し、Enterで撮影 |
| W → クリック | カーソル下のウィンドウを撮影 |
| C | Chromeの最前面ウィンドウのWeb表示領域を即撮影 |
| Tab | ImageとVideoを切替。Videoは未実装の案内を表示 |
| Esc | キャンセル |

- 押してから離すまでの移動が4pt以下ならクリックとして扱います。
  - 理由: 手ぶれによる微小な範囲の誤撮影を防ぐためです。
- ドラッグ中のEscは撮影を取り消します。
  - 動作: マウスを離しても撮影せず、前回枠の移動も確定しません。

- キーは物理keyCodeで判定します。
  - 効果: 日本語入力中もW・C・Tab・Enter・Escを利用できます。
- 前回範囲は`~/.config/utsushie/last-area.json`へ保存します。
  - 条件: ディスプレイの変更で画面外になった範囲は無効になります。
- オーバーレイと共有カードは撮影対象から除外します。
- 複数画面の選択範囲を合成します。
  - 設計: 画面のない隙間は黒になります。
  - 設計: 縮小なしで倍率が異なる画面を跨ぐ場合は、最大倍率に揃えます。

## 保存と共有

- 毎回`~/Pictures/UTSUSHIE/`へ保存します。
  - 命名: `utsushie-YYYYMMDD-HHmmss.webp`。同秒の撮影には`-1`などを付けます。
- 既定の出力は1xの非可逆WebP、品質80です。
  - 寸法: 1280×720点の範囲は1280×720ピクセルになります。
- コピーする形式は設定で切り替えられます。
  - `both`: ファイルURLとWebPデータ。
  - `file`: ファイルURLのみ。
  - `data`: WebPデータのみ。タイプは`org.webmproject.webp`。
  - 制限: PNG・TIFFなどの画像データは載せません。
- 撮影後に右下へ共有カードを表示します。
  - 配置: 連続撮影は縦に積み、最新を一番下に置きます。
  - 寿命: 既定は5秒です。ホバー・ドラッグ・保存先選択中は残り時間を止めます。
  - ドラッグ: WebPファイルをアプリへドロップできます。
  - S: 保存先を選んで追加保存します。元の自動保存ファイルは残します。
  - O: Finderでファイルを表示します。
  - X / ×ボタン: カードを閉じます。

Slack・Bluesky・Obsidianへの貼り付け可否は、アプリ側の対応に依存します。`clipboard.mode`の3通りで実機比較してください。

## 設定

メニューの「設定ファイルを開く」で`~/.config/utsushie/config.toml`を作成して開きます。変更は次の撮影開始時またはメニューを開いた時に反映します。

```toml
outputDir = "~/Pictures/UTSUSHIE"

[hotkey]
keyCode = 19
modifiers = ["command", "shift"]

[webp]
downscale = true
quality = 80
lossless = false

[clipboard]
mode = "both"

[thumbnail]
seconds = 5
```

| キー | 有効値 |
| --- | --- |
| `outputDir` | 絶対パスまたは`~/`から始まるパス |
| `hotkey.keyCode` | 0〜127の物理キー番号。19は2 |
| `hotkey.modifiers` | `command`・`shift`・`option`・`control`の配列 |
| `webp.downscale` | `true`なら1xへ縮小、`false`なら画面倍率の解像度 |
| `webp.quality` | 0〜100。非可逆圧縮の品質 |
| `webp.lossless` | `true`なら可逆圧縮。品質設定は使わない |
| `clipboard.mode` | `both`・`file`・`data` |
| `thumbnail.seconds` | 0.1〜300秒 |

- 不正な値はその項目の既定値へ戻します。
  - 表示: メニューに警告を出します。
  - 例外: TOMLの構文が壊れている場合は設定全体を既定へ戻します。
- ホットキーにはCommand・Option・Controlのいずれかが必要です。
  - 理由: 通常の文字入力を奪う設定を避けるためです。

## 依存

- [libwebp-Xcode](https://github.com/SDWebImage/libwebp-Xcode/tree/1.6.0) 1.6.0をSwiftPMで同梱します。
  - 理由: SDWebImageが管理し、libwebpのCソースをmacOSでビルドできるためです。
  - ライセンス: BSD-3-Clause。バンドル内にライセンスとPATENTSを含めます。
- [TOMLKit](https://github.com/LebJe/TOMLKit) 0.6.0で設定を読みます。
- [swift-testing](https://github.com/swiftlang/swift-testing) 0.12.0をテストに使用します。

Homebrewの`cwebp`などの外部コマンドは不要です。

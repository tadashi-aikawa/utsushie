<div align="center">
    <h1>UTSUSHIE</h1>
    <img src="Resources/utsushie.png" alt="UTSUSHIEのロゴ" width="256" />
    <h3>写絵</h3>
    <p>画面をWebP画像・MP4動画で撮り、注釈や切り出しを加えて、すぐ貼り付け・ドラッグで共有できるmacOSアプリ</p>
    <p>
        <a href="https://github.com/tadashi-aikawa/utsushie/releases/latest"><img src="https://img.shields.io/github/release/tadashi-aikawa/utsushie" alt="release" /></a>
        <a href="https://github.com/tadashi-aikawa/utsushie/actions/workflows/ci.yml"><img src="https://github.com/tadashi-aikawa/utsushie/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
        <a href="https://github.com/tadashi-aikawa/utsushie/blob/main/LICENSE"><img src="https://img.shields.io/github/license/tadashi-aikawa/utsushie" alt="License" /></a>
    </p>
</div>

---

- **撮影**: クリックでウィンドウ、ドラッグで範囲を撮る。画像は見た目の大きさ(1x)のWebP
- **録画**: 範囲やウィンドウをMP4で録る
- **共有**: 保存と同時にクリップボードへ載せる。画面右下のカードからドラッグでも渡せる
- **注釈**: 枠・スポットライト・文字・番号・矢印・モザイク。AIで公開しないほうがよい箇所を探してモザイクにもできる
- **動画の編集**: 不要な範囲を切り、早送り・暗転・ディゾルブでつなぐ。録画から静止画も選べる
- **撮影の一覧**: 保存した画像・動画を一覧で探し、コピー・ドラッグ・編集・削除する

## 対応環境

- macOS 26以降

## インストール

```sh
brew install --cask tadashi-aikawa/tap/utsushie
```

アップデートは `brew upgrade --cask utsushie` です。

手動で入れる場合は、[Releases](https://github.com/tadashi-aikawa/utsushie/releases/latest) から `UTSUSHIE-<version>.zip` をダウンロード・展開し、`UTSUSHIE.app` を `/Applications` に移動します。

> [!NOTE]
> UTSUSHIEは自己署名の未公証アプリです。初回起動がブロックされた場合は、システム設定 → プライバシーとセキュリティ →「このまま開く」で許可してください。

### 権限

- **画面収録**: 最初の撮影で案内が出ます。許可したらUTSUSHIEを再起動してください
- **アクセシビリティ**: Chromeのページ表示領域を撮るとき(C)だけ必要です

## 撮る

ホットキー(既定は⌘⇧2)を押すと、範囲を選べる状態になります。

| 操作 | 動作 |
| --- | --- |
| クリック | カーソルの下のウィンドウを撮る |
| ドラッグ | 選んだ範囲を撮る |
| Enter / ホットキーをもう一度 | 前回と同じ範囲を撮る |
| ⌥を押しながら前回範囲の枠をドラッグ | 前回範囲を動かす |
| C | Chromeで表示中のページ部分だけを撮る |
| Tab | 画像と動画を切り替える |
| Esc | やめる |

動画では、対象を選ぶと録画が始まります。止めるときはホットキーをもう一度押すか、メニューバーの「■ 時間」の札をクリックします。範囲は1つのディスプレイの中で選んでください。音は録りません。

## 共有する

撮った画像・動画は `~/Pictures/UTSUSHIE/` に保存され、同時にクリップボードへ載ります。そのまま⌘Vで貼り付けられます。

画面右下のカードからは、ファイルをドラッグして渡せます。最新のカードでは、カーソルを乗せなくても次のキーが使えます。

| キー | 動作 |
| --- | --- |
| ⏎ | 画像に注釈を入れる・動画を編集する |
| S | 別の場所にも保存する |
| O | Finderで表示する |
| X / Esc | カードを閉じる |

## 撮影の一覧

メニューバーの「撮影の一覧を開く」で、保存フォルダの画像・動画を新しい順に一覧できます。

| キー | 動作 |
| --- | --- |
| ←↓↑→ / HJKL | 選択を移動する |
| ⇧+矢印 / ⇧+HJKL / ⇧+クリック | 範囲を選ぶ |
| ⌘+クリック / ⌘A | 選択へ足す・外す / すべて選ぶ |
| ⏎ / ダブルクリック | 編集を開く |
| S | 別の場所にも保存する |
| O | Finderで表示する |
| ⌘C | 選んだ項目をコピーする |
| X → X | 選んだ項目をゴミ箱へ移す |
| Space | クイックルックを開閉する |
| Q / Esc / ⌘W | クイックルックか一覧を閉じる |

選んだ項目は他のアプリへまとめてドラッグできます。既定はコピーで、⌘を押しながら落とすと移動します。

## 画像に注釈を入れる

画像カードのEで、注釈の編集画面が開きます。

| ツール | キー | 注釈を置く操作 |
| --- | --- | --- |
| 選択 | Esc | 既存の注釈を選択・移動する |
| 枠 | R | ドラッグ |
| スポットライト | S | 明るく残したい範囲をドラッグ |
| 文字 | T | クリックして入力。指したい点からドラッグすると引き出し線付き |
| 番号 | N | クリックで番号。指したい点からドラッグすると引き出し線付き |
| 矢印 | A | 始点から終点へドラッグ |
| モザイク | M | 隠したい範囲をドラッグ |
| AIで隠す | H | 隠したほうがよい箇所を探してモザイクを置く |

| キー | 動作 |
| --- | --- |
| Delete | 選んだ注釈を消す |
| Enter / ⇧Enter | 文字を確定する / 改行する |
| ⌘Z / ⇧⌘Z | 取り消し・やり直し |
| ⌘↩ | 保存して閉じる |
| Q / ⌘W | 破棄する。変更があれば2回押す |
| ピンチ / ⌘+スクロール / ⌘+ / ⌘- | 拡大縮小 |
| ⌘0 / ⌘1 | 全体を表示 / 100%で表示 |
| 2本指スクロール / スペース+ドラッグ | 表示を移動 |

- 文字・番号・枠・矢印は画像の外へ出せます。出した分だけ余白が広がります。
- 保存すると元のWebPを置き換え、カードとクリップボードも更新します。

### AIで隠す

`[privacy] ai = true` で有効になります。Claude Codeをインストールし、`claude auth login` を済ませてください。

- Claudeへは認識した文字だけを送ります。画像と位置は送りません。顔はMac内で検出します。
- 見落としはあります。公開前に画像を確認してください。

## 動画を編集する

動画カードのEで、動画の編集画面が開きます。

- 序盤・終盤は時間軸の藍の枠のつまみを引いて、途中は帯をドラッグして⌫で切ります。
- 途中の切った範囲は、文字をクリックしてつなぎ方を選べます。
    - そのまま: 切った範囲を飛ばす(既定)
    - 早送り: 切った範囲を2〜100倍で見せる
    - 暗転: 黒を挟んで切り替える
    - ディゾルブ: 前後のコマを重ねて切り替える
- ⏎で今のコマを静止画として選ぶと、完了時にWebPで保存します。

| キー | 動作 |
| --- | --- |
| Space | 再生・停止 |
| ← / → | 前・次の1コマへ移動 |
| ⇧← / ⇧→ | 1秒戻る・進む |
| ⌘← / ⌘→ | 先頭・末尾へ移動 |
| I / O | 残す範囲の始め・終わりを再生位置に合わせる |
| ⌫ | 選んだ範囲を切る |
| ⏎ | 今のコマを静止画として選ぶ |
| ⌘Z / ⇧⌘Z | 取り消し・やり直し |
| ⌘↩ | 完了 |
| Q / ⌘W | 破棄する。変更があれば2回押す |

## 設定

メニューの「設定ファイルを開く」で `~/.config/utsushie/config.toml` を開きます。変更は次の撮影から反映されます。

```toml
outputDir = "~/Pictures/UTSUSHIE"

[hotkey]
keyCode = 19                     # 物理キーの番号。19は「2」
modifiers = ["command", "shift"] # ⌘・⌥・⌃のいずれかを含める

# 任意。一覧をホットキーで開く場合だけコメントを外す
# [libraryHotkey]
# keyCode = 37                    # 物理キーL。⌘⇧L
# modifiers = ["command", "shift"]

[webp]
downscale = true                 # 見た目の大きさ(1x)に縮小する
quality = 80                     # 0〜100
lossless = false                 # trueなら可逆圧縮(qualityは使わない)

[video]
fps = 30                         # 1〜60
downscale = true                 # 見た目の大きさ(1x)に縮小する
showsCursor = true               # カーソルを写す

[clipboard]
mode = "both"                    # 画像のコピー形式。both: ファイルとデータ / file / data。動画は常にファイル

[thumbnail]
seconds = 5                      # カードを出しておく秒数

[privacy]
ai = false                       # trueでAIで隠すを有効にする
claude = ""                      # Claude Codeのパス。空なら自動で探す
model = "sonnet"
effort = "low"                   # low / medium / high
```

不正な値はその項目だけ既定値に戻り、メニューに警告が出ます。

## 開発

```sh
swift build
swift test
./scripts/make-app.sh release && open .build/UTSUSHIE.app
```

構成・設計の判断・リリース方法は [CLAUDE.md](CLAUDE.md) を参照してください。

## ライセンス

[MIT](LICENSE)

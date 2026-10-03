<p align="center">
  <img src="Resources/utsushie.png" alt="UTSUSHIEのロゴ" width="180">
</p>

# UTSUSHIE

UTSUSHIE(写絵)は、画面をWebP画像またはMP4動画にして、すぐ貼り付け・ドラッグで共有できるmacOSのメニューバーアプリです。

## インストール

> [!NOTE]
> 配布は準備中です。初回リリース後に次のコマンドで導入できます。

```sh
brew install --cask tadashi-aikawa/tap/utsushie
```

UTSUSHIEは自己署名の未公証アプリです。初回起動がブロックされた場合は、システム設定 → プライバシーとセキュリティ →「このまま開く」で許可してください。

## 権限

- **画面収録**: 最初の撮影で案内が出ます。許可したらUTSUSHIEを再起動してください
- **アクセシビリティ**: Chromeのページ表示領域を撮るとき(C)だけ必要です

## 使い方

ホットキー(既定は⌘⇧2)を押すと、画面が少し暗くなって範囲を選べる状態になります。

| 操作 | 動作 |
| --- | --- |
| ドラッグ | 選んだ範囲を撮る |
| Enter / ホットキーをもう一度 | 前回と同じ範囲を撮る |
| 前回範囲の枠をドラッグ | 前回範囲を動かす |
| W → クリック | クリックしたウィンドウを撮る |
| C | Chromeで表示中のページ部分だけを撮る |
| Tab | 画像(Image)と動画(Video)を切り替える |
| クリック / Esc | やめる |

### 動画

Tabで動画に切り替えてから対象を選ぶと、録画が始まります。止めるときはホットキーをもう一度押すか、メニューの「録画を停止」を選びます。

- 範囲は1つのディスプレイの中で選んでください
- 音は録りません

## 保存と共有

撮った画像・動画は`~/Pictures/UTSUSHIE/`に保存され、同時にクリップボードへ載ります。そのまま⌘Vで貼り付けられます。

画面右下に出るカードからは、ファイルをドラッグして渡せます。カードの上では次のキーが使えます。

| キー | 動作 |
| --- | --- |
| S | 別の場所にも保存する |
| O | Finderで表示する |
| X | カードを閉じる |

画像は見た目の大きさ(1x)のWebPで保存します。

## 設定

メニューの「設定ファイルを開く」で`~/.config/utsushie/config.toml`を開きます。変更は次の撮影から反映されます。

```toml
outputDir = "~/Pictures/UTSUSHIE"

[hotkey]
keyCode = 19                     # 物理キーの番号。19は「2」
modifiers = ["command", "shift"]

[webp]
downscale = true                 # 見た目の大きさ(1x)に縮小する
quality = 80                     # 0〜100
lossless = false                 # trueなら可逆圧縮(qualityは使わない)

[video]
fps = 30                         # 1〜60
downscale = true                 # 見た目の大きさ(1x)に縮小する
showsCursor = true               # カーソルを写す

[clipboard]
mode = "both"                    # 画像のコピー形式。both / file / data

[thumbnail]
seconds = 5                      # カードを出しておく秒数
```

- `clipboard.mode`
    - `both`: ファイルとWebPの画像データの両方
    - `file`: ファイルだけ
    - `data`: WebPの画像データだけ
    - 動画は常にファイルだけを載せます
- ホットキーには⌘・⌥・⌃のいずれかを含めてください
- 不正な値はその項目だけ既定値に戻り、メニューに警告が出ます

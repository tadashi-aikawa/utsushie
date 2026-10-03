# ロゴの管理

採用デザインはC案「撮影の判子」です。

## 元画像と配布用アイコン

- `Resources/utsushie.png`: 1024×1024の透過PNGです。
  - 用途: READMEと派生画像の共通の元画像です。
  - 管理: 採用済みの画像を保ち、加工も生成し直しも行いません。
- `Resources/utsushie.icns`: 配布用アプリアイコンです。
  - 寸法: 次の各サイズの1倍・2倍画像を格納します。
    - 16ポイント
    - 32ポイント
    - 128ポイント
    - 256ポイント
    - 512ポイント
  - 管理: 生成済みのICNSをリポジトリへ含めます。

`./scripts/make-icon.sh`でPNGからICNSを再生成します。

- 通常のアプリビルドは生成済みのICNSを同梱します。
  - 効果: ビルド時に画像生成ツールを必要としません。
- アプリは`CFBundleIconFile`で`utsushie.icns`を参照します。
  - 詳細: [AppleのCFBundleIconFile](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleiconfile)
- メニューバーの待機中アイコンも同じICNSを18ポイントで表示します。
  - 表示: テンプレート画像にせず、ロゴの色を保ちます。
- 録画中・準備中・保存中は従来のシンボルと文言を表示します。
  - 表示: 録画中は経過時間も表示します。
- 画像を同梱しない`swift run`では、待機中も従来の`viewfinder`シンボルを使います。

## 制作

- Codexの内蔵`image_gen`で3案を生成しました。
- C案「撮影の判子」を採用しました。
- ImageMagickで背景を抜き、縁を2px削りました。
- 採用後の画像を`Resources/utsushie.png`として保存しています。

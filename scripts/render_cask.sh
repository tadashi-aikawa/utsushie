#!/usr/bin/env bash
# Cask を標準出力へ書き出す。tap へ push せずに検証できる。
# 使い方: ./scripts/render_cask.sh <version> <sha256>
set -euo pipefail

VERSION="${1:-}"
SHA256="${2:-}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ || ! "$SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Usage: scripts/render_cask.sh <version> <sha256>" >&2
  exit 1
fi

cat <<EOF
cask "utsushie" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/tadashi-aikawa/utsushie/releases/download/v#{version}/UTSUSHIE-#{version}.zip"
  name "UTSUSHIE"
  desc "画面をWebP画像やMP4動画で保存し、コピーとドラッグで共有する macOS 用ツール"
  homepage "https://github.com/tadashi-aikawa/utsushie"

  depends_on macos: :tahoe

  app "UTSUSHIE.app"

  # 自己署名の未公証アプリのため、導入後に quarantine を外す。
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/UTSUSHIE.app"]
  end

  zap trash: "~/.config/utsushie"

  caveats <<~EOS
    UTSUSHIE は自己署名の未公証アプリです。
    初回起動がブロックされた場合は以下で許可してください:
    システム設定 → プライバシーとセキュリティ → 「このまま開く」
  EOS
end
EOF

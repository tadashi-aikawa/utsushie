#!/usr/bin/env bash
# swift build → UTSUSHIE.app → KIKIGAKIと同じ固定証明書で署名
set -euo pipefail

CONFIG="${1:-debug}"
VERSION="${2:-0.0.0-development}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/UTSUSHIE.app"

case "$CONFIG" in debug|release) ;; *) echo "usage: $0 [debug|release] [version]" >&2; exit 1 ;; esac
if [[ ! "$VERSION" =~ ^[A-Za-z0-9.+-]+$ ]]; then
  echo "version must contain only letters, numbers, dots, + and -" >&2
  exit 1
fi

swift build --package-path "$ROOT" -c "$CONFIG"
BIN_DIR="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)"
# 削除するのはこのスクリプトが生成する固定の.appパスだけ。
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Licenses"
cp "$BIN_DIR/Utsushie" "$APP/Contents/MacOS/UTSUSHIE"
sed "s/0\.0\.0-development/$VERSION/" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
cp "$ROOT/.build/checkouts/libwebp-Xcode/LICENSE" "$APP/Contents/Resources/Licenses/libwebp.txt"
cp "$ROOT/.build/checkouts/libwebp-Xcode/libwebp/PATENTS" "$APP/Contents/Resources/Licenses/libwebp-PATENTS.txt"
cp "$ROOT/.build/checkouts/TOMLKit/LICENSE" "$APP/Contents/Resources/Licenses/TOMLKit.txt"
cp "$ROOT/Resources/tomlplusplus-LICENSE.txt" "$APP/Contents/Resources/Licenses/tomlplusplus.txt"

# 同じ開発者の証明書は複数のbundle IDに使用できる。
# KIKIGAKIの既存固定証明書を既定とし、別証明書は環境変数で選べる。
# validのみの-vは付けない。自己署名の「信頼」設定と署名可能かは別。
IDENTITY="${CODESIGN_IDENTITY:-kikigaki-dev}"
if security find-identity -p codesigning | rg -F -q -- "$IDENTITY" &&
  codesign --force --timestamp=none --sign "$IDENTITY" "$APP"; then
  echo "Signed with: $IDENTITY"
else
  codesign --force --sign - "$APP"
  echo "Signed with: ad-hoc"
  echo "固定証明書がありません。再ビルド時に画面収録・アクセシビリティの再許可が必要になる場合があります。" >&2
fi
codesign --verify --deep --strict "$APP"
echo "Built: $APP"
echo "Run: open '$APP'"

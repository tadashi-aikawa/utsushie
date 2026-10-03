#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="${1:-}"
APP="$ROOT_DIR/.build/UTSUSHIE.app"
DIST_DIR="$ROOT_DIR/dist"
ARCHIVE="$DIST_DIR/UTSUSHIE-$VERSION.zip"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Usage: scripts/build_release.sh <version>" >&2
  exit 1
fi

"$SCRIPT_DIR/make-app.sh" release "$VERSION"

# ad-hoc フォールバックのままリリースする事故を防ぐ。
# CI 以外のローカル検証では証明書が無いことがあるためスキップする
if [[ "${CI:-}" == "true" ]]; then
  # grep -q をパイプ終端に置くと SIGPIPE を pipefail に拾われるため、変数に受ける
  CODESIGN_INFO="$(codesign -dvv "$APP" 2>&1)"
  echo "$CODESIGN_INFO"
  grep -q "Authority=utsushie-dev" <<<"$CODESIGN_INFO"
fi

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# 拡張属性・署名メタデータを保持し、展開時の UTSUSHIE.app を1つにまとめる
ditto -c -k --keepParent "$APP" "$ARCHIVE"

unzip -tq "$ARCHIVE"
# -q なしの grep は入力を最後まで読むため、unzip の SIGPIPE を防げる
unzip -Z1 "$ARCHIVE" | grep -x "UTSUSHIE.app/Contents/Info.plist" >/dev/null
unzip -Z1 "$ARCHIVE" | grep -x "UTSUSHIE.app/Contents/MacOS/UTSUSHIE" >/dev/null
# 静的に同梱する依存のライセンスと特許条項を確認する
unzip -Z1 "$ARCHIVE" | grep -x "UTSUSHIE.app/Contents/Resources/Licenses/libwebp.txt" >/dev/null
unzip -Z1 "$ARCHIVE" | grep -x "UTSUSHIE.app/Contents/Resources/Licenses/libwebp-PATENTS.txt" >/dev/null
unzip -Z1 "$ARCHIVE" | grep -x "UTSUSHIE.app/Contents/Resources/Licenses/TOMLKit.txt" >/dev/null
unzip -Z1 "$ARCHIVE" | grep -x "UTSUSHIE.app/Contents/Resources/Licenses/tomlplusplus.txt" >/dev/null

echo "Built and validated $ARCHIVE (version $VERSION)"

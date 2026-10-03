#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="${1:-}"
ARCHIVE="$ROOT_DIR/dist/UTSUSHIE-$VERSION.zip"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Usage: scripts/update_tap.sh <version>" >&2
  exit 1
fi

if [[ -z "${TAP_GITHUB_TOKEN:-}" ]]; then
  echo "TAP_GITHUB_TOKEN is required." >&2
  exit 1
fi

SHA256=$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)
TAP_DIR="$(mktemp -d)/tap"

git clone "https://x-access-token:${TAP_GITHUB_TOKEN}@github.com/tadashi-aikawa/homebrew-tap.git" "$TAP_DIR"
cd "$TAP_DIR"
mkdir -p Casks

# 毎回丸ごと書き出し、初回の作成と文面の変更をこのリポジトリから反映する
"$SCRIPT_DIR/render_cask.sh" "$VERSION" "$SHA256" >Casks/utsushie.rb

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add Casks/utsushie.rb
git commit -m "utsushie $VERSION"
git push

echo "Updated homebrew-tap: utsushie $VERSION ($SHA256)"

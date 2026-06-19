#!/usr/bin/env bash
#
# install.sh — ビルド済み KotoeriLLM.app を入力メソッドとしてインストールする。
#
# 使い方:
#   1) Xcode で KotoeriLLM をビルド（Product > Build）。
#   2) ビルド産物 KotoeriLLM.app のパスを引数に渡す:
#        ./install.sh /path/to/KotoeriLLM.app
#      省略時は Xcode 既定の DerivedData から最新を探す。
#   3) システム設定 > キーボード > 入力ソース で「KotoeriLLM ひらがな」を追加。
#
set -euo pipefail

APP="${1:-}"
if [[ -z "${APP}" ]]; then
  APP="$(find "${HOME}/Library/Developer/Xcode/DerivedData" -name "KotoeriLLM.app" -type d 2>/dev/null | head -n1 || true)"
fi
if [[ -z "${APP}" || ! -d "${APP}" ]]; then
  echo "✗ KotoeriLLM.app が見つかりません。先に Xcode でビルドするか、パスを引数で渡してください。" >&2
  exit 1
fi

DEST="${HOME}/Library/Input Methods/KotoeriLLM.app"
echo "→ インストール: ${APP}"
echo "          → ${DEST}"

# 既存を置換（旧プロセスを止めてから）。
pkill -f "KotoeriLLM.app/Contents/MacOS/KotoeriLLM" 2>/dev/null || true
rm -rf "${DEST}"
mkdir -p "${HOME}/Library/Input Methods"
cp -R "${APP}" "${DEST}"

# ad-hoc 署名（未署名なら）。
codesign --force --deep --sign - "${DEST}" || true

echo "✓ インストール完了。"
echo "  システム設定 > キーボード > 入力ソース > ＋ で「日本語」配下の KotoeriLLM を追加してください。"
echo "  反映されない場合は一度ログアウト/ログインするか、'killall -9 KotoeriLLM' 後に再選択。"

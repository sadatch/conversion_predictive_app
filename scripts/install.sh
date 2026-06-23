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
  # DerivedData から自動探索。
  #  - Index.noindex 配下の「インデックス用の空スタブ」は除外（これを拾うと壊れたバンドルになる）。
  #  - 実行ファイル Contents/MacOS/KotoeriLLM を持つ有効なバンドルだけを候補にする。
  #  - 複数あれば最終更新が最新のものを選ぶ。
  best=""; bestt=0
  while IFS= read -r p; do
    [[ -x "${p}/Contents/MacOS/KotoeriLLM" ]] || continue
    t="$(stat -f %m "${p}" 2>/dev/null || echo 0)"
    if [[ "${t}" -gt "${bestt}" ]]; then bestt="${t}"; best="${p}"; fi
  done < <(find "${HOME}/Library/Developer/Xcode/DerivedData" -type d -name "KotoeriLLM.app" ! -path "*Index.noindex*" 2>/dev/null)
  APP="${best}"
fi
if [[ -z "${APP}" || ! -d "${APP}" ]]; then
  echo "✗ 有効な KotoeriLLM.app が見つかりません。" >&2
  echo "  Xcode のビルドが成功しているか確認し（⌘B / エラーが無いこと）、" >&2
  echo "  Product > Show Build Folder in Finder で .app の場所を確認してパスを引数に渡してください:" >&2
  echo "    ./scripts/install.sh /path/to/Build/Products/Debug/KotoeriLLM.app" >&2
  exit 1
fi
# 妥当性チェック（空スタブを掴んでいないか）。
if [[ ! -x "${APP}/Contents/MacOS/KotoeriLLM" || ! -f "${APP}/Contents/Info.plist" ]]; then
  echo "✗ 選ばれたバンドルが不完全です: ${APP}" >&2
  echo "  実行ファイル/Info.plist が見当たりません。ビルドが本当に成功したか確認してください。" >&2
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

#!/usr/bin/env bash
#
# download_model.sh — LLMモデル(GGUF)を1ファイルだけ取得する。
#
# ストレージ最小化:
#   - 既に存在し非空ならスキップ（重複ダウンロード・重複保存をしない）。
#   - 配布物にモデルを同梱しない。ここで Application Support に1ファイル置くだけ。
#
# 既定: TinySwallow-1.5B-Instruct Q4_K_M (~1.0GB, 日本語特化)
#   環境変数で差し替え可能:
#     MODEL_REPO   … Hugging Face のリポジトリ
#     MODEL_FILE   … GGUF ファイル名
#   例) MODEL_REPO=Qwen/Qwen2.5-1.5B-Instruct-GGUF MODEL_FILE=qwen2.5-1.5b-instruct-q4_k_m.gguf ./download_model.sh
#
set -euo pipefail

MODEL_REPO="${MODEL_REPO:-SakanaAI/TinySwallow-1.5B-Instruct-GGUF}"
MODEL_FILE="${MODEL_FILE:-tinyswallow-1.5b-instruct-q4_k_m.gguf}"

DEST_DIR="${HOME}/Library/Application Support/KotoeriLLM/models"
DEST="${DEST_DIR}/${MODEL_FILE}"

mkdir -p "${DEST_DIR}"

if [[ -s "${DEST}" ]]; then
  echo "✓ モデルは既に存在します（再ダウンロードしません）: ${DEST}"
  echo "  サイズ: $(du -h "${DEST}" | cut -f1)"
  exit 0
fi

URL="https://huggingface.co/${MODEL_REPO}/resolve/main/${MODEL_FILE}?download=true"
echo "↓ ダウンロード: ${MODEL_REPO}/${MODEL_FILE}"
echo "  → ${DEST}"
echo "  (リポジトリ/ファイル名が変わっている場合は MODEL_REPO / MODEL_FILE を指定してください)"

TMP="${DEST}.part"
URLSTAMP="${DEST}.part.url"

# 別URLの残骸 .part に -C - でレジュームすると壊れたファイルを掴むため、
# URLが前回と異なる（or 記録が無い）場合は .part を破棄してからやり直す。
if [[ -f "${TMP}" ]]; then
  if [[ ! -f "${URLSTAMP}" ]] || [[ "$(cat "${URLSTAMP}" 2>/dev/null)" != "${URL}" ]]; then
    echo "  ⚠ 既存の .part は別URL由来の可能性。破棄して取り直します。"
    rm -f "${TMP}"
  fi
fi
printf '%s' "${URL}" > "${URLSTAMP}"

# 同一URLなら -C - でレジューム。失敗しても部分ファイルは .part のまま残す。
curl -L --fail --retry 3 -C - -o "${TMP}" "${URL}"

# サイズ健全性チェック（最低100MB。GGUFが途中で切れていないか粗く検証）。
BYTES=$(stat -f%z "${TMP}" 2>/dev/null || stat -c%s "${TMP}" 2>/dev/null || echo 0)
if [[ "${BYTES}" -lt 104857600 ]]; then
  echo "✗ ダウンロードが小さすぎます(${BYTES} bytes)。中断とみなし .part を残します。" >&2
  exit 1
fi

# 任意: EXPECTED_SHA256 が指定されていれば検証。
if [[ -n "${EXPECTED_SHA256:-}" ]]; then
  echo "  SHA256 を検証中..."
  GOT=$(shasum -a 256 "${TMP}" | awk '{print $1}')
  if [[ "${GOT}" != "${EXPECTED_SHA256}" ]]; then
    echo "✗ SHA256 不一致: got ${GOT}" >&2
    exit 1
  fi
  echo "  ✓ SHA256 一致"
fi

mv "${TMP}" "${DEST}"
rm -f "${URLSTAMP}"

echo "✓ 完了: ${DEST} ($(du -h "${DEST}" | cut -f1))"
echo "  Settings の modelFileName と一致していることを確認してください: ${MODEL_FILE}"

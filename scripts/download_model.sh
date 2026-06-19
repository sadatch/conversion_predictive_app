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

# レジューム対応で取得。途中失敗しても部分ファイルを残さないよう一時名で。
TMP="${DEST}.part"
curl -L --fail --retry 3 -C - -o "${TMP}" "${URL}"
mv "${TMP}" "${DEST}"

echo "✓ 完了: ${DEST} ($(du -h "${DEST}" | cut -f1))"
echo "  Settings の modelFileName と一致していることを確認してください: ${MODEL_FILE}"

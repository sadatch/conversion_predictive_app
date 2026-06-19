#!/usr/bin/env bash
#
# build_llama.sh — llama.cpp を静的ライブラリとしてビルドし、
#                  KotoeriLLM/ThirdParty/llama.cpp/{include,lib} に配置する。
#
# 生成物を Xcode から HEADER_SEARCH_PATHS / LIBRARY_SEARCH_PATHS で参照する
# （project.yml に設定済み。USE_LLAMA=1 と OTHER_LDFLAGS の -lllama 等を有効化のこと）。
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TP="${ROOT}/KotoeriLLM/ThirdParty/llama.cpp"
SRC="${ROOT}/.build/llama.cpp"

mkdir -p "${ROOT}/.build" "${TP}/include" "${TP}/lib"

if [[ ! -d "${SRC}/.git" ]]; then
  echo "↓ llama.cpp を取得"
  git clone --depth 1 https://github.com/ggml-org/llama.cpp "${SRC}"
fi

echo "⚙️  ビルド（Metal有効, 静的ライブラリ, Universal）"
cmake -S "${SRC}" -B "${SRC}/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_SERVER=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"
cmake --build "${SRC}/build" --config Release -j

echo "📦 ヘッダ/ライブラリをコピー"
cp "${SRC}/include/llama.h"            "${TP}/include/" 2>/dev/null || true
cp "${SRC}/ggml/include/"*.h           "${TP}/include/" 2>/dev/null || true
# 静的ライブラリ(.a)を回収（ビルド構成によりパスが異なるため広めに探索）。
find "${SRC}/build" -name "*.a" -exec cp {} "${TP}/lib/" \;

echo "✓ 完了: ${TP}"
echo "  次: project.yml で USE_LLAMA=1 と OTHER_LDFLAGS の -lllama / -lggml* を有効化し、"
echo "      Metal.framework / Accelerate.framework を dependencies に追加して再生成・ビルド。"
ls -1 "${TP}/lib"

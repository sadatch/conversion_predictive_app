# Mozc client ライブラリの組み込み手順

KotoeriLLM は **Mozc の client ライブラリをリンク**してかな漢字変換を委譲する。
ここでは OSS Mozc をビルドして必要な静的ライブラリ＋ヘッダを用意し、
`USE_MOZC=1` で実 Mozc 経路を有効化するまでをまとめる。

> 既定（`USE_MOZC=0`）ではスタブが動くので、Mozc 抜きでも IME はビルド・起動できる。
> まずスタブで全体を通し、その後この手順で実 Mozc に差し替えるのが安全。

## 1. 前提
- macOS / Xcode Command Line Tools
- Bazelisk（`brew install bazelisk`）
- Python 3

## 2. Mozc を取得してビルド
```bash
git clone https://github.com/google/mozc.git
cd mozc/src
# 依存の取得（リポジトリの README/docs/build_mozc_in_osx.md に従う）
# 例（バージョンにより異なる。公式ドキュメントを必ず確認）:
bazel build package --config oss_macos -c opt
```
- 目的は **client と protocol（commands.proto 由来）** を含む静的ライブラリ。
  - 主要ターゲット例: `//client:client`, `//protocol:commands_cc_proto`, `//session:*`
  - 生成された `.a` 群と、`mozc_server`（Converter 実行ファイル）を控えておく。

## 3. ヘッダ／ライブラリの配置
KotoeriLLM 側から参照できるよう、以下を用意する（パスは任意、project.yml に合わせる）。
```
KotoeriLLM/ThirdParty/mozc/
├── src/                      # include ルート（protocol/commands.pb.h, client/client.h 等）
└── lib/                      # 回収した .a 群（client, protocol, base, session, protobuf 等）
```
- `bazel-bin` 配下から必要な `.a` を `lib/` にコピー。
- 生成 protobuf ヘッダ（`*.pb.h`）が `src/protocol/` 等に見えるようにする。

## 4. project.yml を有効化
`KotoeriLLM/project.yml` の該当箇所を編集:
- `GCC_PREPROCESSOR_DEFINITIONS` の `USE_MOZC=0` → `USE_MOZC=1`
- `HEADER_SEARCH_PATHS` に `$(SRCROOT)/ThirdParty/mozc/src` を追加（コメント解除）
- `LIBRARY_SEARCH_PATHS` に `$(SRCROOT)/ThirdParty/mozc/lib` を追加
- `OTHER_LDFLAGS` に Mozc/protobuf の `-l...`（実 lib 名に合わせる）を追加
- 再生成: `cd KotoeriLLM && xcodegen generate`

## 5. mozc_server の起動について
- `mozc::client::Client` は接続時に Converter（`mozc_server`）へ Mach port IPC で繋ぐ。
- 公式 Mozc.app を導入済みなら、その Converter LaunchAgent を利用できる場合がある。
- 自前運用するなら `mozc_server` を常駐させる（LaunchAgent 化、または初回接続時に spawn）。
- 接続可否は `MozcBridge connect`（内部で `PingServer`）で確認し、失敗時はフォールバック。

## 6. 注意（キーマッピング）
- `MozcBridge.mm` の `fillKeyEvent:` は最小マッピング。JISかな入力や特殊キーを正しく
  扱うには Mozc の `mac/KeyCodeMap`（`init_kanamap.h` 等の生成テーブル）を流用するのが望ましい。
- まずローマ字入力（ASCII→かな合成は Mozc が実施）で動作確認し、その後拡張する。

## 参考
- google/mozc（GitHub）/ `src/mac/` の `mozc_imk_input_controller.mm`, `KeyCodeMap.h`
- DeepWiki: google/mozc macOS Integration

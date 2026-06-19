# KotoeriLLM — 文脈予測強化型 日本語IME (macOS)

直近の入力文脈（既定500字）を使って、変換候補を「いい感じ」に並べ替える独自の日本語IME。
かな漢字変換は **Mozc** に委譲し、**ローカルLLM（llama.cpp）** が候補のリランキングだけを担当する。
クラウド送信なし・オフライン動作・**ストレージ最小化**設計。

- 要件定義: [`macos_llm_ime_requirements_v2.md`](macos_llm_ime_requirements_v2.md)（v1からの改善点は §0）
- 設計詳細: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)

## 構成

```
予測変換改造くん/
├── macos_llm_ime_requirements.md       # 元の要件 (v1)
├── macos_llm_ime_requirements_v2.md    # ブラッシュアップ版 (v2)
├── README.md
├── docs/ARCHITECTURE.md
├── scripts/
│   ├── download_model.sh   # GGUFモデルを1ファイル取得 (Application Support)
│   ├── build_llama.sh      # llama.cpp を静的ライブラリ化
│   ├── build_mozc.md       # Mozc client ライブラリ組み込み手順
│   └── install.sh          # .app を ~/Library/Input Methods へ
└── KotoeriLLM/
    ├── project.yml         # XcodeGen 定義 → xcodeproj 生成
    ├── Info.plist          # IMKit 入力メソッド定義
    ├── KotoeriLLM.entitlements
    ├── Resources/rerank.gbnf   # LLM出力を強制する GBNF 文法
    └── Sources/
        ├── main.swift              # IMKServer 起動
        ├── AppServices.swift       # 共有サービス（モデル/Mozc/設定）
        ├── Settings.swift          # 設定（UserDefaultsのみ。入力は保存しない）
        ├── ContextBuffer.swift     # ★インメモリ・リングバッファ（非永続）
        ├── InputController.swift   # IMKInputController 本体（候補パイプライン内包）
        ├── MozcClient.swift         # Mozcブリッジの Swift ラッパ
        ├── LLMReranker.swift        # LLMブリッジの Swift ラッパ（期限/直列化）
        └── Bridging/
            ├── KotoeriLLM-Bridging-Header.h
            ├── MozcBridge.h/.mm     # ObjC++ → Mozc client（USE_MOZC で切替）
            └── LlamaBridge.h/.mm    # ObjC++ → llama.cpp（USE_LLAMA で切替）
```

## クイックスタート（3段階）

依存（Mozc/llama.cpp）は重いので、**スタブで全体を通してから**順に有効化するのが安全。

### 段階1: スタブでビルド & 入力ソース確認（依存なし）
```bash
brew install xcodegen
cd KotoeriLLM
xcodegen generate          # KotoeriLLM.xcodeproj を生成
open KotoeriLLM.xcodeproj   # Xcode でビルド (⌘B)
```
Xcode でビルド後、リポジトリ直下で:
```bash
./scripts/install.sh
```
システム設定 > キーボード > 入力ソース で「KotoeriLLM ひらがな」を追加。
スタブは「ASCIIを溜めて Space でダミー候補」を出すだけだが、候補UI・パイプラインの動作確認になる。

### 段階2: ローカルLLMを有効化（並べ替えを実動作させる）
```bash
./scripts/download_model.sh    # TinySwallow-1.5B Q4_K_M (~1GB) を取得
./scripts/build_llama.sh       # libllama を ThirdParty/ に生成
```
`KotoeriLLM/project.yml` で `USE_LLAMA=0 → 1`、`OTHER_LDFLAGS` の `-lllama`/`-lggml*` と
`Metal.framework`/`Accelerate.framework` を有効化 → `xcodegen generate` → 再ビルド。

### 段階3: 実 Mozc を有効化（実変換候補）
[`scripts/build_mozc.md`](scripts/build_mozc.md) の手順で Mozc client を組み込み、
`USE_MOZC=0 → 1` にして再生成・再ビルド。

## ストレージ最小化（設計の要点）

- **コンテキストは非永続**: `ContextBuffer` はインメモリのリングバッファ。ディスクに書かない（プライバシーも同時に満たす）。
- **入力ログを残さない**: 変換履歴・プロンプト・応答をファイル/ログに出力しない。
- **モデルは単一実体・mmap**: GGUF は `~/Library/Application Support/KotoeriLLM/models/` に1ファイル。`use_mmap=true` で読み、`.app` に同梱しない。
- **KV/セッションの永続化なし**、`n_ctx` 控えめ（既定2048）でRAMも節約。
- 目標フットプリント: アプリ本体は数MB級。総量はおおむね「モデル(~1GB) + Mozc辞書」。

## 設定（UserDefaults）

| キー | 既定 | 説明 |
|---|---|---|
| `contextCharLimit` | 500 | 文脈リングバッファの保持文字数 |
| `llmContextChars` | 160 | LLMへ渡す文脈末尾の文字数（短いほど低レイテンシ） |
| `llmEnabled` | true | LLMリランキングの有効/無効 |
| `llmDeadlineMs` | 150 | LLMハード期限(ms)。超過で並べ替え破棄 |
| `llmContextTokens` | 2048 | n_ctx（KVキャッシュ節約のため控えめ） |
| `maxCandidatesToLLM` | 9 | LLMへ渡す上位候補数（プロンプト短縮） |
| `modelFileName` | tinyswallow-1.5b-instruct-q4_k_m.gguf | モデルファイル名 |

例: `defaults write com.kotoeri.inputmethod.KotoeriLLM llmDeadlineMs -int 120`

## 性能チューニング（実機で効く）

リランキングが「効く/効かない」は実機レイテンシ次第。以下を順に。

1. **計測する**: 環境変数 `KOTOERI_LLM_PROFILE=1` を付けて起動すると、リランクごとに
   `prefill / gen / total(ms)` と KV 再利用率をログ出力する（入力文字列は出さない）。
   まず1リクエストの内訳を見る。
2. **KVプレフィックス再利用**（実装済み, `LlamaBridge.mm`）: 命令+文脈の不変プレフィックスは
   KVを使い回し、毎回のサフィックス（候補+指示）だけ再デコードする。同一composition中は
   文脈が不変なので `reuse=nPrefix/nPrefix`（全再利用）になり、プレフィルが大幅短縮される。
3. **発火を絞る**（実装済み, `InputController`）: 変換キー(Space)で各変換につき1回だけリランク。
   ローマ字蓄積中やSpace連打（候補送り）では発火しない。陳腐化した推論は実行前に破棄。
4. それでも期限超過が続くなら `llmDeadlineMs` を上げる／`llmContextChars`・`maxCandidatesToLLM`
   を下げる／より小さいモデル（Qwen2.5-0.5B 等）に替える。

## 注意・既知の制限
- これは **scaffold（骨組み）**。スタブで即ビルド可、実 Mozc/LLM 組み込みには上記段階2・3が必要。
- `MozcBridge.mm` のキーマッピングは最小限。JISかな・特殊キー網羅は Mozc の KeyCodeMap 流用を推奨。
- IMKCandidates のホットスワップは、ユーザーが候補選択を始める前のみ反映（体験を壊さないため）。
- **段階2でのハマりどころ**: `USE_LLAMA=1` の静的リンク。`libllama`/`libggml*` はリンク順依存があり、
  シンボル未解決が出たら `-lllama` を `-lggml*` より前に置く、`ggml-metal`/`ggml-blas` の有無を確認、
  必要なら `-Wl,-force_load,<path>/libggml.a` を試す。`build_llama.sh` は `.a` を一括回収するため、
  生成された lib 名を `project.yml` の `OTHER_LDFLAGS` に合わせること。
- **リポジトリ名**: GitHub上は `conversion_predictive_app`、作業フォルダは `予測変換改造くん`、
  プロダクト名は `KotoeriLLM` と表記が分かれている。実害はないが、READMEのツリー先頭や
  バンドルID(`com.kotoeri...`)と揃えたい場合は適宜リネームを。

## ライセンスと GitHub 公開時の注意

- 本リポジトリのコードは **MIT ライセンス**（[`LICENSE`](LICENSE)）。必要なら差し替え可。
- 依存する Mozc(BSD-3) / llama.cpp(MIT) / 各LLMモデルは別ライセンス。帰属と再配布条件は [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) を参照。
- **モデル（`*.gguf`）やビルド産物（`ThirdParty/`, `*.a`）はコミットしない**（`.gitignore` で除外済み）。GitHub には 100MB/ファイルの上限があり、~1GB のモデルは置けない。各自 `scripts/download_model.sh` で取得する運用。
- `KotoeriLLM.xcodeproj` は `project.yml` から `xcodegen generate` で再生成できるため除外している（`project.yml` が正本）。チーム共有で `.xcodeproj` を入れたい場合は `.gitignore` の該当行を外す。
- 初回コミット前のチェック:
  ```bash
  git init
  git add -A
  git status            # *.gguf / ThirdParty / DerivedData が含まれていないか確認
  git commit -m "Initial commit: KotoeriLLM scaffold"
  ```
- コミットに記録される `user.name` / `user.email` は各自の git 設定値。公開用に分けたい場合はリポジトリ単位で設定:
  `git config user.email "you@example.com"`

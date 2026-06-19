# アーキテクチャ詳細

## データフロー

```
NSEvent(keyDown)
  │  KotoeriInputController.handle(_:client:)
  ▼
MozcClient.sendKey ──▶ MozcBridge(.mm) ──▶ mozc::client::Client.SendKey
  │                                              │ commands::Output
  ◀──────────────────────────────────────────────┘
  │  MozcResult { consumed, committedText, preedit, candidates }
  ▼
①確定文字列があれば insertText → ContextBuffer.append（インメモリ）
②preedit を setMarkedText で表示
③候補があれば:
    showCandidates(Mozc順)            ← まず即時描画（フォールバック兼初期表示）
    LLMReranker.rerank(期限150ms) ─▶ LlamaBridge(.mm) ─▶ llama.cpp(GBNF, greedy)
        │ インデックス列 [2,0,1,...]
        ▼
    期限内 & ユーザー未選択 なら showCandidates(並べ替え後)  ← ホットスワップ
```

## スレッドモデル
- IMK のコールバック（`handle`, `candidates`, `candidateSelected`）は **メインスレッド**で即返す。
- LLM 推論は `LLMReranker` 内の **専用シリアルキュー**（`com.kotoeri.llm.serial`）で直列化。
  - `llama_context` は非スレッドセーフ。複数同時推論を避けるため必ず直列。
  - ハード期限（`DispatchQueue.asyncAfter`）で、遅い推論結果は捨てる（UIに出さない）。
- 結果反映は `DispatchQueue.main.async` でメインへ戻し、世代カウンタ(`generation`)で
  古い結果を破棄。

## フォールバック設計（多層）
1. Mozc 未接続/失敗 → スタブ or 素通り（`consumed=false` は OS へ委譲）。
2. LLM 未ロード/無効 → Mozc 候補をそのまま表示（`isReady=false`）。
3. LLM 期限超過/失敗 → 並べ替えを破棄し Mozc 順を維持。
4. LLM 出力が壊れている → GBNF で構文強制 + 範囲チェック + 欠落補完（`LLMReranker.rerank`）。

いずれの失敗も入力そのものは止めない（非機能要件「安定性」）。

## ストレージ最小化の実装ポイント
| 項目 | 実装 |
|---|---|
| 文脈の非永続 | `ContextBuffer`（`[Character]` 固定容量、ディスク書き出しなし） |
| 入力ログ非保存 | ログ出力に入力文字列/プロンプト/応答を含めない |
| モデル単一実体 | `Settings.resolvedModelPath` = Application Support/models/＜1ファイル＞ |
| mmap | `LlamaBridge`: `model_params.use_mmap = true`, `use_mlock=false` |
| KV非永続 | セッション保存API不使用。毎リクエストで `llama_memory_clear` |
| RAM節約 | `n_ctx` 既定2048、`maxCandidatesToLLM=9` でプロンプト短縮 |
| バンドル軽量 | `.app` にモデルを同梱しない（数MB級） |

## リランキングのプロンプト/出力
- 入力: 文脈末尾N字 + 番号付き候補（上位K=9）。
- 出力: 並べ替えインデックス列のみ。`rerank.gbnf` で `[整数,整数,...]` に強制。
- サンプリング: greedy（temp=0）で決定的。`temperature` 等のランダム要素は入れない。
- 解析: `LlamaBridge.parseIndices:` が範囲内整数だけ採用。`LLMReranker` 側で重複除去・欠落補完。

## 拡張ポイント（TODO）
- `MozcBridge.fillKeyEvent:` を Mozc `mac/KeyCodeMap` 相当に拡張（JISかな・特殊キー網羅）。
- `LlamaBridge.buildPrompt` を `llama_chat_apply_template` ベースに（モデル本来のテンプレ使用）。
- 追加候補生成（リランキングだけでなく、文脈に基づく新候補の少量補完）。
- フィールド単位の文脈分離（現状はプロセス内グローバル1本）。
- 設定UI（現状は `defaults` コマンド/UserDefaults 直接）。
```

# サードパーティのライセンス / 帰属表示

KotoeriLLM は以下の第三者ソフトウェア・データに依存します。
**これらの成果物（特にモデルの重みファイル）を本リポジトリに同梱・再配布しないでください。**
各自が公式の配布元から取得する運用とし、それぞれのライセンス条件に従ってください。

## ソフトウェア

| 名称 | 用途 | ライセンス | 入手元 |
|---|---|---|---|
| **Mozc** | かな漢字変換エンジン（client/protocol をリンク） | BSD 3-Clause | https://github.com/google/mozc |
| **llama.cpp / ggml** | ローカルLLM推論 | MIT | https://github.com/ggml-org/llama.cpp |
| **Protocol Buffers** | Mozc が依存 | BSD 3-Clause | https://github.com/protocolbuffers/protobuf |

ソースコードを取り込む場合は、各プロジェクトの LICENSE 全文を `licenses/` 等に保持してください。

## LLMモデル（重みファイル）

利用するモデルにより**ライセンスと再配布可否・商用利用可否が異なります**。
モデルファイル（`*.gguf` 等）はリポジトリに含めず、`scripts/download_model.sh` で取得してください。
利用前に各モデルカードのライセンスを必ず確認すること。

| モデル | 提供元 | 確認先（ライセンス・利用規約） |
|---|---|---|
| TinySwallow-1.5B-Instruct（既定） | Sakana AI | 各 Hugging Face モデルカードを参照 |
| Sarashina2.2-0.5B/1B-instruct | SB Intuitions | 各 Hugging Face モデルカードを参照 |
| Qwen2.5-0.5B/1.5B-Instruct | Alibaba（Qwen） | Qwen ライセンス（モデルカード参照） |

> 注意: 「コードが MIT」であることと「モデルが自由に使える」ことは別問題です。
> 商用利用・再配布・派生物の扱いはモデルごとに条件が異なるため、必ず原典で確認してください。

## 商標

- macOS, Xcode は Apple Inc. の商標です。本プロジェクトは Apple 公認ではありません。
- その他の名称は各社の商標です。

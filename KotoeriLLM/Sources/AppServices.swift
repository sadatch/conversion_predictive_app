//
//  AppServices.swift
//  KotoeriLLM
//
//  プロセス全体で共有する長命オブジェクト（Mozcクライアント、LLMリランカー、設定、
//  コンテキストバッファ）を束ねるシングルトン。
//
//  - 重い初期化（モデルの mmap など）は1回だけ行い、全 InputController で共有する。
//  - llama_context は非スレッドセーフのため、推論は LLMReranker 内の専用シリアルキューに集約。
//

import Foundation

final class AppServices {
    static let shared = AppServices()

    let settings = Settings()
    // lazy にすることで settings を直接参照でき、使い捨て Settings() の二重生成を避ける（指摘5）。
    lazy var context = ContextBuffer(capacity: settings.contextCharLimit)
    let mozc = MozcClient()
    let reranker = LLMReranker()

    private var didBootstrap = false
    private let lock = NSLock()

    private init() {}

    /// アプリ起動時に1回呼ぶ。失敗してもクラッシュさせず、各層は内部でフォールバックする。
    func bootstrap() {
        lock.lock(); defer { lock.unlock() }
        guard !didBootstrap else { return }
        didBootstrap = true

        // context は lazy で settings.contextCharLimit を反映済み（明示初期化のため一度触る）。
        _ = context

        // Mozc サーバへの接続確認（USE_MOZC=0 のスタブビルドでは常に false を返す）。
        let mozcOK = mozc.connect()
        NSLog("[KotoeriLLM] Mozc connected = \(mozcOK)")

        // LLM モデルの遅延ロード。重いので背景で。失敗時は reranker.isReady=false のまま
        // → パイプラインは Mozc 候補をそのまま使う（フォールバック）。
        if settings.llmEnabled {
            DispatchQueue.global(qos: .utility).async { [reranker, settings] in
                let ok = reranker.loadModel(
                    path: settings.resolvedModelPath,
                    contextTokens: settings.llmContextTokens,
                    grammarPath: settings.grammarPath
                )
                NSLog("[KotoeriLLM] LLM model loaded = \(ok) path=\(settings.resolvedModelPath)")
            }
        }
    }
}

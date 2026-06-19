//
//  LLMReranker.swift
//  KotoeriLLM
//
//  ObjC++ ブリッジ(LlamaBridge)を包む Swift ラッパ。
//
//  役割: 直近コンテキスト + Mozc候補 を入力し、「並べ替え後の候補配列」を返す。
//  - 推論は llama_context が非スレッドセーフのため、ブリッジ内部の専用シリアルキューで直列化。
//  - ここでは「ハード期限」を被せ、期限超過時は nil を返してフォールバックさせる。
//  - 出力は GBNF 文法で「整数のカンマ区切り（並べ替えインデックス）」に強制され、
//    壊れた出力を構文的に排除する（詳細は LlamaBridge.mm / rerank.gbnf）。
//
//  ストレージ方針: モデルは mmap。プロンプト/応答はディスクに書かない。
//

import Foundation

final class LLMReranker {
    private let bridge = LlamaBridge()
    private let queue = DispatchQueue(label: "com.kotoeri.llm.serial", qos: .userInitiated)

    // 背景ロードで書き、メインで読むためアトミックに（指摘4のデータ競合対策）。
    private let _ready = AtomicBool(false)
    var isReady: Bool { _ready.value }

    /// モデルを mmap でロード。重い処理。背景スレッドから呼ぶこと。
    @discardableResult
    func loadModel(path: String, contextTokens: Int, grammarPath: String) -> Bool {
        let ok = bridge.loadModel(withPath: path,
                                  contextTokens: Int32(contextTokens),
                                  grammarPath: grammarPath)
        _ready.value = ok
        return ok
    }

    /// 候補を文脈で並べ替える。期限内に終わらなければ completion(nil)。
    /// completion は任意スレッドで呼ばれる。
    /// isStale: 推論直前/直後に呼ばれ、true なら結果が既に不要（陳腐化）と判断して捨てる。
    func rerank(context: String,
                candidates: [String],
                deadline: TimeInterval,
                isStale: @escaping () -> Bool = { false },
                completion: @escaping ([String]?) -> Void) {

        guard isReady, !candidates.isEmpty else { completion(nil); return }

        // 期限管理: 1回だけ呼ぶためのガード。
        var finished = false
        let finishLock = NSLock()
        func finishOnce(_ value: [String]?) {
            finishLock.lock(); defer { finishLock.unlock() }
            if finished { return }
            finished = true
            completion(value)
        }

        // タイムアウト用ウォッチドッグ。
        // ★必ず推論用シリアルキューとは別のキューに置くこと。
        //   同じシリアルキューに載せると、同期的な推論ブロックが終わるまで
        //   ウォッチドッグが実行されず、期限が機能しない。
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + deadline) {
            // 期限到達。まだ終わっていなければ諦める（推論自体は走り切るが結果は捨てる）。
            finishOnce(nil)
        }

        queue.async { [bridge] in
            // ★陳腐化チェック: 推論を始める前に、結果がもう不要なら即捨てる。
            //   速い入力でキューに積まれた古いリクエストの推論を走らせず、CPU/電池を節約。
            if isStale() { finishOnce(nil); return }

            // GBNF で順位列を生成 → インデックス配列を取得。
            let order: [Int] = (bridge.rerankIndices(withContext: context,
                                                     candidates: candidates) as? [NSNumber])?
                .map { $0.intValue } ?? []

            guard !order.isEmpty else { finishOnce(nil); return }

            // インデックスの健全性チェック（範囲内・重複除去・欠落補完）。
            var seen = Set<Int>()
            var reordered: [String] = []
            for i in order where i >= 0 && i < candidates.count && !seen.contains(i) {
                seen.insert(i)
                reordered.append(candidates[i])
            }
            // LLM が触れなかった候補を元順で温存（欠落防止）。
            for (i, c) in candidates.enumerated() where !seen.contains(i) {
                reordered.append(c)
            }
            // 推論中に陳腐化していたら反映しない。
            finishOnce(isStale() ? nil : reordered)
        }
    }
}

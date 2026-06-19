//
//  LlamaBridge.mm
//  KotoeriLLM
//
//  llama.cpp へのブリッジ。現行(2025+)の C API を使用:
//    llama_model_load_from_file / llama_init_from_model /
//    llama_sampler_chain_init / llama_sampler_init_grammar / llama_sampler_sample
//
//  ストレージ最小化:
//    - model_params.use_mmap = true（モデルをmmap。RAM常駐コピー・ディスク複製を作らない）
//    - n_ctx は呼び出し側で控えめに固定（KVキャッシュRAM節約）
//    - セッション/KVのディスク保存はしない
//
//  ビルド切替:
//    USE_LLAMA=1 で実推論。未定義(=0)ならスタブ（恒等順）。
//    実ビルドには libllama(+libggml) 静的リンクと include パスが必要（scripts/build_llama.sh）。
//

#import "LlamaBridge.h"

#if USE_LLAMA
#include "llama.h"
#include <string>
#include <vector>
#include <chrono>
#include <algorithm>
#include <cstdlib>   // getenv

// 指定位置から連続するトークン列をデコードするヘルパ（位置を明示制御してKV再利用を可能にする）。
static bool kll_decode(llama_context *ctx, const llama_token *toks, int n, int pos0, bool logitsLast) {
    if (n <= 0) return true;
    llama_batch b = llama_batch_init(n, 0, 1);
    for (int i = 0; i < n; ++i) {
        b.token[i]    = toks[i];
        b.pos[i]      = pos0 + i;
        b.n_seq_id[i] = 1;
        b.seq_id[i][0] = 0;
        b.logits[i]   = (logitsLast && i == n - 1) ? 1 : 0;
    }
    b.n_tokens = n;
    int rc = llama_decode(ctx, b);
    llama_batch_free(b);
    return rc == 0;
}

static int kll_tokenize(const llama_vocab *v, const std::string &s,
                        std::vector<llama_token> &out, bool addSpecial) {
    int cap = (int)s.size() + 8;
    out.resize(cap);
    int n = llama_tokenize(v, s.c_str(), (int)s.size(), out.data(), cap, addSpecial, true);
    if (n < 0) { out.resize(-n); n = llama_tokenize(v, s.c_str(), (int)s.size(), out.data(), (int)out.size(), addSpecial, true); }
    if (n < 0) n = 0;
    out.resize(n);
    return n;
}

@implementation LlamaBridge {
    llama_model   *_model;
    llama_context *_ctx;
    const llama_vocab *_vocab;
    std::string    _grammar;
    BOOL           _loaded;
    std::vector<llama_token> _prefixCache;  // 直近の不変プレフィックス(命令+文脈)トークン列
    BOOL           _profile;                // KOTOERI_LLM_PROFILE=1 でレイテンシ内訳をログ
}

- (BOOL)isLoaded { return _loaded; }

- (BOOL)loadModelWithPath:(NSString *)path
            contextTokens:(int32_t)contextTokens
              grammarPath:(NSString *)grammarPath {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ llama_backend_init(); });

    llama_model_params mp = llama_model_default_params();
    mp.use_mmap = true;       // ★ストレージ/RAM節約: mmap
    mp.use_mlock = false;
    // 余力があれば Metal にオフロード（RAMでなくVRAM/共有メモリ使用）。0なら全CPU。
    mp.n_gpu_layers = 999;

    _model = llama_model_load_from_file(path.UTF8String, mp);
    if (!_model) { _loaded = NO; return NO; }
    _vocab = llama_model_get_vocab(_model);

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx = (uint32_t)contextTokens;   // 控えめ(既定2048)
    cp.n_batch = 512;
    cp.no_perf = true;
    _ctx = llama_init_from_model(_model, cp);
    if (!_ctx) { llama_model_free(_model); _model = nullptr; _loaded = NO; return NO; }

    // GBNF 文法を読み込む（出力をインデックス列に強制）。
    if (grammarPath.length) {
        NSString *g = [NSString stringWithContentsOfFile:grammarPath encoding:NSUTF8StringEncoding error:nil];
        if (g) _grammar = g.UTF8String;
    }
    _prefixCache.clear();
    _profile = (getenv("KOTOERI_LLM_PROFILE") != NULL);
    _loaded = YES;
    return YES;
}

- (NSArray<NSNumber *> *)rerankIndicesWithContext:(NSString *)context
                                       candidates:(NSArray<NSString *> *)candidates {
    if (!_loaded || candidates.count == 0) return @[];

    // プロンプトを「不変プレフィックス(命令+文脈)」と「可変サフィックス(候補+指示)」に分割。
    // 同一composition中は文脈(=確定済みテキスト)が変わらないため、プレフィックスのKVを
    // 再利用し、毎回のサフィックスだけ再デコードすればよい（プレフィル時間を大幅短縮）。
    std::string prefixStr =
        std::string("あなたは日本語入力の変換候補を、直前の文脈に最も自然につながる順に並べ替えます。\n"
                    "出力は候補番号(0始まり)を最良順に並べた配列だけにしてください。例: [2,0,1]\n\n"
                    "文脈:\n") + (context ? context.UTF8String : "") + "\n\n候補:\n";

    std::string suffixStr;
    for (NSUInteger i = 0; i < candidates.count; ++i) {
        suffixStr += "[" + std::to_string((int)i) + "] " + candidates[i].UTF8String + "\n";
    }
    suffixStr += "\n並べ替え結果: ";

    std::vector<llama_token> prefixToks, suffixToks;
    kll_tokenize(_vocab, prefixStr, prefixToks, /*addSpecial(BOS)*/ true);
    kll_tokenize(_vocab, suffixStr, suffixToks, /*addSpecial*/ false);
    if (prefixToks.empty()) return @[];

    auto t0 = std::chrono::steady_clock::now();

    // 既存KVと新プレフィックスの共通長を算出（命令+文脈が不変なら全再利用 = nCommon==nPrefix）。
    // 注: メモリ API はバージョン差あり。古い場合は llama_kv_cache_seq_rm(_ctx,0,p0,p1) 等に置換。
    llama_memory_t mem = llama_get_memory(_ctx);
    int nPrefix = (int)prefixToks.size();
    int maxC = (int)std::min(_prefixCache.size(), prefixToks.size());
    int nCommon = 0;
    while (nCommon < maxC && _prefixCache[nCommon] == prefixToks[nCommon]) ++nCommon;

    // 共通部より後ろのKV（前回のプレフィックス差分・サフィックス・生成分）を破棄。
    llama_memory_seq_rm(mem, 0, nCommon, -1);

    // プレフィックスの未キャッシュ分だけデコード。
    if (nCommon < nPrefix) {
        if (!kll_decode(_ctx, prefixToks.data() + nCommon, nPrefix - nCommon, nCommon, /*logitsLast*/ false))
            return @[];
    }
    _prefixCache = prefixToks;

    // サフィックスをデコード（最後のトークンにだけ logits）。
    if (!kll_decode(_ctx, suffixToks.data(), (int)suffixToks.size(), nPrefix, /*logitsLast*/ true))
        return @[];

    auto t1 = std::chrono::steady_clock::now();

    // --- サンプラ: 文法 + greedy(temp=0, 決定的) ---
    llama_sampler *smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
    if (!_grammar.empty()) {
        llama_sampler_chain_add(smpl, llama_sampler_init_grammar(_vocab, _grammar.c_str(), "root"));
    }
    llama_sampler_chain_add(smpl, llama_sampler_init_greedy());

    std::string out;
    int curPos = nPrefix + (int)suffixToks.size();
    const int kMaxNewTokens = 64;   // 出力は短い数列のみ。
    for (int i = 0; i < kMaxNewTokens; ++i) {
        llama_token tok = llama_sampler_sample(smpl, _ctx, -1);
        if (llama_vocab_is_eog(_vocab, tok)) break;
        char buf[128];
        int len = llama_token_to_piece(_vocab, tok, buf, sizeof(buf), 0, true);
        if (len > 0) out.append(buf, len);
        llama_sampler_accept(smpl, tok);
        if (out.find(']') != std::string::npos) break;  // 数列終端
        if (!kll_decode(_ctx, &tok, 1, curPos, /*logitsLast*/ true)) break;
        ++curPos;
    }
    llama_sampler_free(smpl);

    if (_profile) {
        auto t2 = std::chrono::steady_clock::now();
        double prefill = std::chrono::duration<double, std::milli>(t1 - t0).count();
        double gen     = std::chrono::duration<double, std::milli>(t2 - t1).count();
        // ★入力文字列は出さない。再利用率・デコードトークン数・ms内訳のみ。
        NSLog(@"[KotoeriLLM][profile] reuse=%d/%d decoded(prefix=%d, suffix=%d) prefill=%.1fms gen=%.1fms total=%.1fms",
              nCommon, nPrefix, nPrefix - nCommon, (int)suffixToks.size(), prefill, gen, prefill + gen);
    }

    return [self parseIndices:[NSString stringWithUTF8String:out.c_str()] count:(int)candidates.count];
}

// "[2,0,1,3]" → @[@2,@0,@1,@3]（範囲外は捨てる）。
- (NSArray<NSNumber *> *)parseIndices:(NSString *)s count:(int)count {
    NSMutableArray<NSNumber *> *out = [NSMutableArray array];
    NSScanner *sc = [NSScanner scannerWithString:s];
    NSCharacterSet *skip = [NSCharacterSet characterSetWithCharactersInString:@"[], \n\t"];
    [sc setCharactersToBeSkipped:skip];
    int v = 0;
    while (![sc isAtEnd]) {
        if ([sc scanInt:&v]) {
            if (v >= 0 && v < count) [out addObject:@(v)];
        } else {
            [sc setScanLocation:MIN(sc.scanLocation + 1, s.length)];
        }
    }
    return out;
}

- (void)dealloc {
    if (_ctx) llama_free(_ctx);
    if (_model) llama_model_free(_model);
}

@end

#else

// ============================================================================
//  スタブ経路（llama.cpp 不要）— 恒等順を返す（= Mozc 候補そのまま）
// ============================================================================
@implementation LlamaBridge
- (BOOL)isLoaded { return NO; }
- (BOOL)loadModelWithPath:(NSString *)path contextTokens:(int32_t)contextTokens grammarPath:(NSString *)grammarPath {
    return NO;   // 未ロード扱い → パイプラインは Mozc 候補のまま
}
- (NSArray<NSNumber *> *)rerankIndicesWithContext:(NSString *)context candidates:(NSArray<NSString *> *)candidates {
    return @[];  // 並べ替えなし
}
@end

#endif

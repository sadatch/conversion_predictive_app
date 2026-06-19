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

@implementation LlamaBridge {
    llama_model   *_model;
    llama_context *_ctx;
    const llama_vocab *_vocab;
    std::string    _grammar;
    BOOL           _loaded;
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
    _loaded = YES;
    return YES;
}

- (NSArray<NSNumber *> *)rerankIndicesWithContext:(NSString *)context
                                       candidates:(NSArray<NSString *> *)candidates {
    if (!_loaded || candidates.count == 0) return @[];

    std::string prompt = [self buildPromptWithContext:context candidates:candidates];

    // --- トークナイズ ---
    std::vector<llama_token> tokens(prompt.size() + 16);
    int n = llama_tokenize(_vocab, prompt.c_str(), (int)prompt.size(),
                           tokens.data(), (int)tokens.size(),
                           /*add_special*/ true, /*parse_special*/ true);
    if (n < 0) { tokens.resize(-n); n = llama_tokenize(_vocab, prompt.c_str(), (int)prompt.size(), tokens.data(), (int)tokens.size(), true, true); }
    if (n <= 0) return @[];
    tokens.resize(n);

    // KV をクリアしてプロンプトを評価（セッションは保存しない）。
    // 注: llama.cpp のバージョンで API 名が異なる。新しめは llama_memory_clear(llama_get_memory(ctx), true)。
    //     ビルドが通らなければ旧 API の llama_kv_cache_clear(_ctx) に置換すること。
    llama_memory_clear(llama_get_memory(_ctx), true);
    llama_batch batch = llama_batch_get_one(tokens.data(), (int)tokens.size());
    if (llama_decode(_ctx, batch) != 0) return @[];

    // --- サンプラ: 文法 + greedy(temp=0, 決定的) ---
    llama_sampler *smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
    if (!_grammar.empty()) {
        llama_sampler_chain_add(smpl, llama_sampler_init_grammar(_vocab, _grammar.c_str(), "root"));
    }
    llama_sampler_chain_add(smpl, llama_sampler_init_greedy());

    std::string out;
    const int kMaxNewTokens = 64;   // 出力は短い数列のみ。
    for (int i = 0; i < kMaxNewTokens; ++i) {
        llama_token tok = llama_sampler_sample(smpl, _ctx, -1);
        if (llama_vocab_is_eog(_vocab, tok)) break;
        char buf[128];
        int len = llama_token_to_piece(_vocab, tok, buf, sizeof(buf), 0, true);
        if (len > 0) out.append(buf, len);
        llama_sampler_accept(smpl, tok);
        llama_batch nb = llama_batch_get_one(&tok, 1);
        if (llama_decode(_ctx, nb) != 0) break;
        if (out.find(']') != std::string::npos) break;  // 数列終端
    }
    llama_sampler_free(smpl);

    return [self parseIndices:[NSString stringWithUTF8String:out.c_str()] count:(int)candidates.count];
}

// 文脈 + 候補リスト → リランキング指示プロンプト。
// 注: 本実装はプレーンなプロンプト。モデル本来のチャットテンプレートを使うなら
//     llama_chat_apply_template を併用するとさらに安定する(TODO)。
- (std::string)buildPromptWithContext:(NSString *)context candidates:(NSArray<NSString *> *)cands {
    std::string p = "あなたは日本語入力の変換候補を、直前の文脈に最も自然につながる順に並べ替えます。\n";
    p += "出力は候補番号(0始まり)を最良順に並べた配列だけにしてください。例: [2,0,1]\n\n";
    p += "文脈:\n";
    p += [(context ?: @"") UTF8String];
    p += "\n\n候補:\n";
    for (NSUInteger i = 0; i < cands.count; ++i) {
        p += "[" + std::to_string((int)i) + "] " + [cands[i] UTF8String] + "\n";
    }
    p += "\n並べ替え結果: ";
    return p;
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

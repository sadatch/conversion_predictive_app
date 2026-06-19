//
//  LlamaBridge.h
//  KotoeriLLM
//
//  Swift ↔ llama.cpp(C++) の境界。Objective-C インターフェースのみ公開。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LlamaBridge : NSObject

/// GGUF モデルを mmap でロード（use_mmap=true）。重い。背景スレッドから呼ぶこと。
/// grammarPath: 出力を強制する GBNF 文法（rerank.gbnf）。空なら無制約。
- (BOOL)loadModelWithPath:(NSString *)path
            contextTokens:(int32_t)contextTokens
              grammarPath:(NSString *)grammarPath;

/// context(直近文脈) と candidates(Mozc候補) を与え、並べ替え後の
/// 「元配列に対するインデックス列」を返す。例: @[@2,@0,@1,@3]
/// 失敗時は空配列。スレッド安全性は呼び出し側(LLMReranker)が直列化して担保する。
- (NSArray<NSNumber *> *)rerankIndicesWithContext:(NSString *)context
                                       candidates:(NSArray<NSString *> *)candidates;

@property (nonatomic, readonly) BOOL isLoaded;

@end

NS_ASSUME_NONNULL_END

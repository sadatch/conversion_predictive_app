//
//  MozcBridge.h
//  KotoeriLLM
//
//  Swift ↔ Mozc(client lib, C++) の境界。純粋な Objective-C インターフェースのみを
//  公開し、C++(commands.pb.h 等)はヘッダに漏らさない（Swift から見えるのはこの .h だけ）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 1キー入力に対する Mozc の結果。
@interface MozcKeyResult : NSObject
@property (nonatomic, assign) BOOL consumed;                 // Mozc が処理したか
@property (nonatomic, copy, nullable) NSString *committedText; // 確定文字列
@property (nonatomic, copy) NSString *preedit;                // 変換途中表示
@property (nonatomic, assign) NSInteger preeditCursor;        // preedit内カーソル(UTF-16)
@property (nonatomic, copy) NSArray<NSString *> *candidates;  // 候補(Mozc順)
@end

@interface MozcBridge : NSObject

/// Mozc サーバ(Converter)への接続を確認/確立。スタブビルドでは NO を返す。
- (BOOL)connect;

/// 変換セッションを用意（入力ソース有効化時）。
- (void)ensureSession;

/// NSEvent 相当のキー情報を Mozc に送り、結果を返す。
- (MozcKeyResult *)sendKeyWithKeyCode:(uint16_t)keyCode
                           characters:(NSString *)characters
                            modifiers:(NSUInteger)modifierFlags;

/// 現在の preedit を返す（確定取りこぼし防止用）。
- (NSString *)currentPreedit;

/// composition をリセット（確定後やキャンセル時）。
- (void)resetComposition;

/// 候補選択などで外部確定したことを Mozc に通知（学習等のため）。
- (void)notifyCommitted:(NSString *)text;

@end

NS_ASSUME_NONNULL_END

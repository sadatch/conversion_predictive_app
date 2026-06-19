//
//  MozcBridge.mm
//  KotoeriLLM
//
//  Mozc client ライブラリへのブリッジ実装。
//
//  ビルド切替:
//    USE_MOZC=1 を定義し、Mozc の client/protocol 静的ライブラリとヘッダをリンクすると
//    実 Mozc 経路が有効になる（scripts/build_mozc.md 参照）。
//    未定義(=0, 既定)なら、Mozc 無しでも全体がビルド・起動できるスタブ経路を使う。
//    スタブは「ローマ字をそのまま preedit にため、Space でダミー候補を出す」簡易動作で、
//    IMEシェル/候補パイプライン/LLM並べ替えの結合テストに使える。
//

#import "MozcBridge.h"
#import <AppKit/AppKit.h>

@implementation MozcKeyResult
- (instancetype)init {
    if (self = [super init]) {
        _consumed = NO;
        _committedText = nil;
        _preedit = @"";
        _preeditCursor = 0;
        _candidates = @[];
    }
    return self;
}
@end

#if USE_MOZC

// ============================================================================
//  実 Mozc 経路
//  必要: Mozc を OSS からビルドして libmozc client/protocol を静的リンク。
//        include パスに $(MOZC_SRC)/src を通すこと（project.yml の MOZC_SRC 参照）。
// ============================================================================
#include "protocol/commands.pb.h"
#include "client/client.h"
#include "base/init_mozc.h"

@implementation MozcBridge {
    std::unique_ptr<mozc::client::ClientInterface> _client;
    mozc::commands::Output _lastOutput;
}

- (instancetype)init {
    if (self = [super init]) {
        _client = mozc::client::ClientFactory::NewClient();
    }
    return self;
}

- (BOOL)connect {
    if (!_client) return NO;
    // Converter が落ちていれば起動を試みる。
    _client->EnsureConnection();
    return _client->PingServer();
}

- (void)ensureSession {
    if (_client) _client->EnsureSession();
}

- (MozcKeyResult *)sendKeyWithKeyCode:(uint16_t)keyCode
                           characters:(NSString *)characters
                            modifiers:(NSUInteger)modifierFlags {
    MozcKeyResult *result = [MozcKeyResult new];
    if (!_client) return result;

    // NSEvent → mozc::commands::KeyEvent への変換。
    // 注: 本格対応には Mozc の mac/KeyCodeMap 相当（JISかな・特殊キー網羅）を流用するのが望ましい。
    //     ここでは ASCII + 主要特殊キーの最小マッピングを行う(TODO: 全面対応)。
    mozc::commands::KeyEvent key;
    if (![self fillKeyEvent:&key keyCode:keyCode characters:characters modifiers:modifierFlags]) {
        return result; // Mozc 対象外キー → consumed=NO
    }

    mozc::commands::Output output;
    if (!_client->SendKey(key, &output)) {
        return result; // 送信失敗 → フォールバック
    }
    _lastOutput = output;
    result.consumed = output.consumed();

    // 確定文字列。
    if (output.has_result() && output.result().type() == mozc::commands::Result::STRING) {
        result.committedText = [NSString stringWithUTF8String:output.result().value().c_str()];
    }
    // preedit。
    if (output.has_preedit()) {
        const auto &preedit = output.preedit();
        std::string text;
        for (int i = 0; i < preedit.segment_size(); ++i) text += preedit.segment(i).value();
        result.preedit = [NSString stringWithUTF8String:text.c_str()];
        result.preeditCursor = preedit.cursor();
    }
    // 候補。
    if (output.has_candidates()) {
        NSMutableArray<NSString *> *cands = [NSMutableArray array];
        const auto &c = output.candidates();
        for (int i = 0; i < c.candidate_size(); ++i) {
            [cands addObject:[NSString stringWithUTF8String:c.candidate(i).value().c_str()]];
        }
        result.candidates = cands;
    }
    return result;
}

- (BOOL)fillKeyEvent:(mozc::commands::KeyEvent *)key
             keyCode:(uint16_t)keyCode
          characters:(NSString *)characters
           modifiers:(NSUInteger)modifierFlags {
    using mozc::commands::KeyEvent;
    // 特殊キー
    switch (keyCode) {
        case 49: key->set_special_key(KeyEvent::SPACE); return YES;   // Space
        case 36: key->set_special_key(KeyEvent::ENTER); return YES;   // Return
        case 51: key->set_special_key(KeyEvent::BACKSPACE); return YES; // Delete
        case 53: key->set_special_key(KeyEvent::ESCAPE); return YES;  // Esc
        case 123: key->set_special_key(KeyEvent::LEFT); return YES;
        case 124: key->set_special_key(KeyEvent::RIGHT); return YES;
        case 125: key->set_special_key(KeyEvent::DOWN); return YES;
        case 126: key->set_special_key(KeyEvent::UP); return YES;
        case 48: key->set_special_key(KeyEvent::TAB); return YES;
        default: break;
    }
    if (characters.length == 1) {
        unichar ch = [characters characterAtIndex:0];
        if (ch >= 0x20 && ch < 0x7f) { // 印字可能 ASCII → key_code
            key->set_key_code(ch);
            if (modifierFlags & NSEventModifierFlagShift) key->add_modifier_keys(KeyEvent::SHIFT);
            return YES;
        }
    }
    return NO; // それ以外は Mozc 非対象
}

- (NSString *)currentPreedit {
    if (!_lastOutput.has_preedit()) return @"";
    std::string text;
    const auto &preedit = _lastOutput.preedit();
    for (int i = 0; i < preedit.segment_size(); ++i) text += preedit.segment(i).value();
    return [NSString stringWithUTF8String:text.c_str()];
}

- (void)resetComposition {
    if (!_client) return;
    mozc::commands::Output output;
    _client->SendCommand([] { mozc::commands::SessionCommand c; c.set_type(mozc::commands::SessionCommand::REVERT); return c; }(), &output);
    _lastOutput.Clear();
}

- (void)notifyCommitted:(NSString *)text {
    // 任意: Mozc に外部確定を学習させたい場合に SubmitCandidate 等を送る（TODO）。
}

@end

#else

// ============================================================================
//  スタブ経路（Mozc 不要）— 結合テスト用の簡易動作
// ============================================================================
@implementation MozcBridge {
    NSMutableString *_preedit;
}

- (instancetype)init {
    if (self = [super init]) { _preedit = [NSMutableString string]; }
    return self;
}

- (BOOL)connect { return NO; }            // スタブは未接続扱い
- (void)ensureSession {}

- (MozcKeyResult *)sendKeyWithKeyCode:(uint16_t)keyCode
                           characters:(NSString *)characters
                            modifiers:(NSUInteger)modifierFlags {
    MozcKeyResult *r = [MozcKeyResult new];

    if (keyCode == 49 && _preedit.length > 0) {           // Space: ダミー候補
        r.consumed = YES;
        r.preedit = [_preedit copy];
        r.preeditCursor = (NSInteger)_preedit.length;
        // ローマ字をそのまま並べた“それっぽい”候補をいくつか返す（LLM並べ替えの動作確認用）。
        NSString *base = [_preedit copy];
        r.candidates = @[ base,
                          [base uppercaseString],
                          [NSString stringWithFormat:@"%@。", base],
                          [NSString stringWithFormat:@"【%@】", base] ];
        return r;
    }
    if (keyCode == 36) {                                   // Return: 確定
        r.consumed = _preedit.length > 0;
        r.committedText = _preedit.length > 0 ? [_preedit copy] : nil;
        [_preedit setString:@""];
        r.preedit = @"";
        return r;
    }
    if (keyCode == 51) {                                   // Backspace
        if (_preedit.length > 0) { [_preedit deleteCharactersInRange:NSMakeRange(_preedit.length-1,1)]; r.consumed = YES; }
        r.preedit = [_preedit copy];
        r.preeditCursor = (NSInteger)_preedit.length;
        return r;
    }
    if (characters.length == 1) {                          // 印字 ASCII を ため込む
        unichar ch = [characters characterAtIndex:0];
        if (ch >= 0x20 && ch < 0x7f) {
            [_preedit appendString:characters];
            r.consumed = YES;
            r.preedit = [_preedit copy];
            r.preeditCursor = (NSInteger)_preedit.length;
            return r;
        }
    }
    return r; // consumed=NO
}

- (NSString *)currentPreedit { return [_preedit copy]; }
- (void)resetComposition { [_preedit setString:@""]; }
- (void)notifyCommitted:(NSString *)text {}

@end

#endif

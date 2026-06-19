//
//  MozcClient.swift
//  KotoeriLLM
//
//  ObjC++ ブリッジ(MozcBridge)を包む Swift ラッパ。
//  NSEvent を Mozc が解釈できるキー情報に変換してブリッジへ渡し、
//  返ってきた Output を Swift の MozcResult に詰め替える。
//
//  USE_MOZC=0 のスタブビルドでも動くよう、ブリッジ側がスタブを返す。
//

import Foundation
import AppKit

/// Mozc から1キー入力の結果。
struct MozcResult {
    var consumed: Bool          // Mozc が処理したか（false なら OS に委ねる）
    var committedText: String?  // 今回確定した文字列（あれば）
    var preedit: String         // 変換途中の表示文字列
    var preeditCursor: Int      // preedit 内カーソル位置(UTF-16)
    var candidates: [String]    // 候補（Mozc順）
}

final class MozcClient {
    private let bridge = MozcBridge()

    @discardableResult
    func connect() -> Bool { bridge.connect() }

    func ensureSession() { bridge.ensureSession() }

    func sendKey(event: NSEvent) -> MozcResult {
        let chars = event.charactersIgnoringModifiers ?? ""
        let r = bridge.sendKey(withKeyCode: event.keyCode,
                               characters: chars,
                               modifiers: event.modifierFlags.rawValue)
        return MozcResult(
            consumed: r.consumed,
            committedText: r.committedText,
            preedit: r.preedit,
            preeditCursor: r.preeditCursor,
            candidates: r.candidates as? [String] ?? []
        )
    }

    func currentPreedit() -> String { bridge.currentPreedit() }
    func resetComposition() { bridge.resetComposition() }
    func notifyCommitted(_ text: String) { bridge.notifyCommitted(text) }
}

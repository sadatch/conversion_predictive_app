//
//  ContextBuffer.swift
//  KotoeriLLM
//
//  直近の確定テキストを保持するインメモリ・リングバッファ。
//
//  ストレージ最小化方針の中核:
//   - ディスクに一切書き出さない（永続化なし）。プロセス終了で消える。
//   - 固定容量（文字数）。容量超過時は先頭から捨てる。メモリ上限が予測可能。
//   - Character(書記素クラスタ)単位で扱い、絵文字や結合文字でも壊れない。
//
//  スレッド安全性: IMK のコールバック(主にメインスレッド)から push され、
//  LLM背景キューから tail() で読まれるため、内部ロックで保護する。
//

import Foundation

final class ContextBuffer {
    private var chars: [Character] = []
    private let lock = NSLock()

    /// 最大保持文字数。設定変更で動的に縮小可能。
    var capacity: Int {
        didSet {
            lock.lock(); defer { lock.unlock() }
            trimLocked()
        }
    }

    init(capacity: Int) {
        self.capacity = max(0, capacity)
        self.chars.reserveCapacity(self.capacity)
    }

    /// 確定テキストを追記（commitComposition 時に呼ぶ）。
    func append(_ text: String) {
        guard !text.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        chars.append(contentsOf: text)
        trimLocked()
    }

    /// 直近 n 文字を返す（n=nil で全保持分）。LLMプロンプトの文脈に使う。
    func tail(_ n: Int? = nil) -> String {
        lock.lock(); defer { lock.unlock() }
        guard let n = n, n < chars.count else { return String(chars) }
        return String(chars.suffix(n))
    }

    /// 文脈をクリア（アプリ切替やユーザ操作でリセットしたい場合）。
    func clear() {
        lock.lock(); defer { lock.unlock() }
        chars.removeAll(keepingCapacity: true)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return chars.count
    }

    // capacity を超えた先頭を捨てる。lock 取得済み前提。
    private func trimLocked() {
        if chars.count > capacity {
            chars.removeFirst(chars.count - capacity)
        }
    }
}

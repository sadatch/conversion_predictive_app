//
//  Atomics.swift
//  KotoeriLLM
//
//  メインスレッドと背景キューの間で共有する小さなフラグ/カウンタを安全に扱うための
//  最小限のアトミックラッパ。OSAllocatedUnfairLock（macOS 13+）で保護する。
//
//  用途:
//   - LLMReranker.isReady（背景ロードで書き、メインで読む）
//   - InputController の世代カウンタ（メインで更新、背景の陳腐化判定で読む）
//

import os

final class AtomicInt {
    private let lock: OSAllocatedUnfairLock<Int>
    init(_ value: Int = 0) { lock = OSAllocatedUnfairLock(initialState: value) }
    var value: Int { lock.withLock { $0 } }
    @discardableResult
    func increment() -> Int { lock.withLock { $0 += 1; return $0 } }
}

final class AtomicBool {
    private let lock: OSAllocatedUnfairLock<Bool>
    init(_ value: Bool = false) { lock = OSAllocatedUnfairLock(initialState: value) }
    var value: Bool {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}

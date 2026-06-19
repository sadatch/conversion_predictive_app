//
//  InputController.swift
//  KotoeriLLM
//
//  IMKInputController サブクラス。1入力セッションにつき1インスタンス生成される。
//
//  処理の流れ:
//    NSEvent → Mozc(client lib) へ KeyEvent 送信 → Output(preedit + candidates) 受信
//      → preedit を marked text として表示
//      → 候補があれば CandidatePipeline で「Mozc即時表示 → LLM非同期並べ替え」
//      → 確定(commit)されたら insertText し、確定文字列を ContextBuffer に push
//
//  メインスレッドをブロックしないこと（LLMは背景キュー）。Mozc/LLMの失敗は
//  すべて握りつぶして Mozc 素の候補にフォールバックする。
//

import Foundation
import InputMethodKit
import AppKit

@objc(KotoeriInputController)
final class KotoeriInputController: IMKInputController {

    // 候補ウィンドウ（プロセス共有でも可だが、選択コールバックの取り回しのため
    // コントローラごとに保持し、表示時にこのインスタンスをデリゲートにする）。
    private lazy var candidatesWindow: IMKCandidates = {
        IMKCandidates(server: server, panelType: kIMKSingleColumnScrollingCandidatePanel)
    }()

    // 現在表示中の候補（文字列の配列）。selectIndex で参照する。
    private var currentCandidates: [String] = []
    // pipeline の世代カウンタ。古い非同期結果を破棄するために使う。
    private var generation: Int = 0

    private var services: AppServices { AppServices.shared }

    // MARK: - Lifecycle

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        // 入力ソースに切り替わった。Mozc セッションを用意。
        services.mozc.ensureSession()
    }

    override func deactivateServer(_ sender: Any!) {
        commitComposition(sender)   // 取りこぼし防止
        candidatesWindow.hide()
        super.deactivateServer(sender)
    }

    // MARK: - Key handling

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event, event.type == .keyDown else { return false }

        // NSEvent → Mozc が解釈できる KeyEvent へ。Mozc client lib に委譲し、
        // ローマ字合成・変換・候補生成はすべて Mozc 側で行わせる。
        let result = services.mozc.sendKey(event: event)

        // Mozc が処理しない（= IME外のキー）ならそのまま OS に返す。
        guard result.consumed else {
            return false
        }

        // 1) 確定文字列があれば挿入し、文脈バッファへ。
        if let committed = result.committedText, !committed.isEmpty {
            insertText(committed, client: sender)
            services.context.append(committed)   // ← インメモリのみ（非永続）
        }

        // 2) preedit（変換途中）を marked text として表示。
        updateMarkedText(result.preedit, cursor: result.preeditCursor, client: sender)

        // 3) 候補表示。Mozc 候補を即時 → LLM 非同期並べ替え。
        if result.candidates.isEmpty {
            hideCandidates()
        } else {
            presentCandidates(mozcCandidates: result.candidates, client: sender)
        }

        return true
    }

    // MARK: - Candidate pipeline (即時表示 + 非同期並べ替え)

    private func presentCandidates(mozcCandidates: [String], client sender: Any!) {
        generation &+= 1
        let gen = generation

        // ① まず Mozc 順で即時表示（フォールバック兼初期描画）。
        showCandidates(mozcCandidates)

        // LLM が無効/未ロードならここで終了（= 純 Mozc 動作）。
        guard services.settings.llmEnabled, services.reranker.isReady else { return }

        let contextTail = services.context.tail(services.settings.contextCharLimit)
        let topK = Array(mozcCandidates.prefix(services.settings.maxCandidatesToLLM))

        // ② 背景キューで期限付きリランキング。期限超過/失敗時は ① のまま。
        services.reranker.rerank(
            context: contextTail,
            candidates: topK,
            deadline: services.settings.llmDeadline
        ) { [weak self] reordered in
            guard let self = self else { return }
            DispatchQueue.main.async {
                // 古い世代の結果、または既にユーザが候補選択を始めている場合は無視。
                guard gen == self.generation else { return }
                guard !self.userStartedSelecting else { return }
                guard let reordered = reordered, !reordered.isEmpty else { return }

                // topK を並べ替え、LLM が触れなかった残り候補は末尾に温存。
                let rest = mozcCandidates.dropFirst(topK.count)
                let newList = reordered + rest
                guard newList != self.currentCandidates else { return }
                self.showCandidates(Array(newList))   // ホットスワップ
            }
        }
    }

    private var userStartedSelecting = false

    private func showCandidates(_ list: [String]) {
        currentCandidates = list
        candidatesWindow.update()      // データソース(candidates(_:))から再取得させる
        candidatesWindow.show(kIMKLocateCandidatesBelowHint)
    }

    private func hideCandidates() {
        currentCandidates = []
        userStartedSelecting = false
        candidatesWindow.hide()
    }

    // IMKCandidates のデータソース。表示する候補文字列の配列を返す。
    override func candidates(_ sender: Any!) -> [Any]! {
        return currentCandidates
    }

    // ユーザが候補を選択（Enter/クリック）したとき。
    override func candidateSelected(_ candidateString: NSAttributedString!) {
        let text = candidateString?.string ?? ""
        if !text.isEmpty {
            insertText(text, client: client())
            services.context.append(text)     // 文脈へ（インメモリ）
            services.mozc.notifyCommitted(text)
        }
        hideCandidates()
        services.mozc.resetComposition()
    }

    // 候補ハイライト移動が始まったら、以後のホットスワップを止める（体験を壊さない）。
    override func candidateSelectionChanged(_ candidateString: NSAttributedString!) {
        userStartedSelecting = true
    }

    // MARK: - Commit / marked text helpers

    override func commitComposition(_ sender: Any!) {
        let pending = services.mozc.currentPreedit()
        if !pending.isEmpty {
            insertText(pending, client: sender)
            services.context.append(pending)
        }
        services.mozc.resetComposition()
        hideCandidates()
    }

    private func insertText(_ text: String, client sender: Any!) {
        guard let c = sender as? IMKTextInput ?? client() as? IMKTextInput else { return }
        c.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func updateMarkedText(_ preedit: String, cursor: Int, client sender: Any!) {
        guard let c = sender as? IMKTextInput ?? client() as? IMKTextInput else { return }
        if preedit.isEmpty {
            c.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                            replacementRange: NSRange(location: NSNotFound, length: 0))
        } else {
            let sel = NSRange(location: min(cursor, preedit.utf16.count), length: 0)
            c.setMarkedText(preedit, selectionRange: sel,
                            replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }
}

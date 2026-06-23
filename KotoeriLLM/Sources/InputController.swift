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
    // 注: `server` 単独だと IMKInputController 継承の server() メソッドと衝突するため self.server() を呼ぶ。
    private lazy var candidatesWindow: IMKCandidates = {
        IMKCandidates(server: self.server(), panelType: kIMKSingleColumnScrollingCandidatePanel)
    }()

    // 現在表示中の候補（文字列の配列）。selectIndex で参照する。
    private var currentCandidates: [String] = []
    // pipeline の世代カウンタ。古い/陳腐化した非同期結果を破棄するために使う。
    // メインで更新、背景の陳腐化判定で読むためアトミック（指摘3,4）。
    private let generation = AtomicInt(0)
    // この変換セッションで既にリランク済みか（Space連打＝候補送りでの再発火を防ぐ）。
    private var rerankedThisConversion = false

    private var services: AppServices { AppServices.shared }

    // 変換トリガーとみなすキー（Space）。環境により「変換」キーのkeyCodeを足してよい。
    private static let kVK_Space: UInt16 = 49

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

        // 確定が起きたら変換セッションは終了 → 次の変換で再びリランク可能にする。
        if result.committedText != nil { rerankedThisConversion = false }

        // 3) 候補表示。Mozc 候補を即時 → LLM 非同期並べ替え。
        if result.candidates.isEmpty {
            hideCandidates()
        } else {
            // 発火制御（指摘3）: 変換キー(Space)で、まだこの変換でリランクしていない時だけ発火。
            // ローマ字蓄積中（予測候補が毎キー更新される）やSpace連打（候補送り）では発火させない。
            let isConversionKey = (event.keyCode == Self.kVK_Space)
            let allowRerank = isConversionKey && !rerankedThisConversion
            presentCandidates(mozcCandidates: result.candidates,
                              allowRerank: allowRerank,
                              client: sender)
            if allowRerank { rerankedThisConversion = true }
        }

        return true
    }

    // MARK: - Candidate pipeline (即時表示 + 非同期並べ替え)

    private func presentCandidates(mozcCandidates: [String], allowRerank: Bool, client sender: Any!) {
        // 世代を進める（この時点で過去の非同期結果はすべて陳腐化）。
        let gen = generation.increment()

        // ① まず Mozc 順で即時表示（フォールバック兼初期描画）。show も行う。
        showCandidates(mozcCandidates, reshow: true)

        // 発火しない条件: 変換キー以外/リランク済み、LLM無効/未ロード。→ 純 Mozc 動作。
        guard allowRerank, services.settings.llmEnabled, services.reranker.isReady else { return }

        // LLM へ渡す文脈は短い窓で十分（プレフィル短縮・レイテンシ削減）。
        let contextTail = services.context.tail(services.settings.llmContextChars)
        let topK = Array(mozcCandidates.prefix(services.settings.maxCandidatesToLLM))

        // ② 背景キューで期限付きリランキング。期限超過/失敗/陳腐化時は ① のまま。
        services.reranker.rerank(
            context: contextTail,
            candidates: topK,
            deadline: services.settings.llmDeadline,
            isStale: { [weak self] in self?.generation.value != gen }
        ) { [weak self] reordered in
            guard let self = self else { return }
            DispatchQueue.main.async {
                // 古い世代の結果、または既にユーザが候補選択を始めている場合は無視。
                guard gen == self.generation.value else { return }
                guard !self.userStartedSelecting else { return }
                guard let reordered = reordered, !reordered.isEmpty else { return }

                // topK を並べ替え、LLM が触れなかった残り候補は末尾に温存。
                let rest = mozcCandidates.dropFirst(topK.count)
                let newList = reordered + rest
                guard newList != self.currentCandidates else { return }
                // ホットスワップは update() のみ（show を呼ばず、選択/スクロール位置のリセットを避ける＝指摘6）。
                self.showCandidates(Array(newList), reshow: false)
            }
        }
    }

    private var userStartedSelecting = false

    /// reshow=true: 初回表示（update + show）。reshow=false: 内容だけ差し替え（update のみ）。
    private func showCandidates(_ list: [String], reshow: Bool) {
        currentCandidates = list
        candidatesWindow.update()      // データソース(candidates(_:))から再取得させる
        if reshow {
            candidatesWindow.show(kIMKLocateCandidatesBelowHint)
        }
    }

    private func hideCandidates() {
        currentCandidates = []
        userStartedSelecting = false
        rerankedThisConversion = false
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

    // 送信元(sender)優先で IMKTextInput を取り出す。client() は (IMKTextInput & NSObjectProtocol)? を
    // 返すので、そのまま upcast して返す（冗長な as? ダウンキャスト警告を回避）。
    private func textInput(_ sender: Any!) -> IMKTextInput? {
        if let s = sender as? IMKTextInput { return s }
        return client()
    }

    private func insertText(_ text: String, client sender: Any!) {
        guard let c = textInput(sender) else { return }
        c.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func updateMarkedText(_ preedit: String, cursor: Int, client sender: Any!) {
        guard let c = textInput(sender) else { return }
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

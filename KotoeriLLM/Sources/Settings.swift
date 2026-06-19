//
//  Settings.swift
//  KotoeriLLM
//
//  設定。値は UserDefaults（軽量、KB単位）にのみ保存し、入力内容は一切保存しない。
//  ストレージ最小化方針: モデルは ~/Library/Application Support/KotoeriLLM/models/ に
//  単一ファイルとして置き、mmap で読む。バンドルには同梱しない。
//

import Foundation

final class Settings {
    private let defaults = UserDefaults.standard

    private enum Key {
        static let contextCharLimit = "contextCharLimit"
        static let llmEnabled       = "llmEnabled"
        static let llmDeadlineMs     = "llmDeadlineMs"
        static let llmContextTokens  = "llmContextTokens"
        static let modelFileName     = "modelFileName"
        static let maxCandidatesToLLM = "maxCandidatesToLLM"
    }

    init() {
        defaults.register(defaults: [
            Key.contextCharLimit: 500,
            Key.llmEnabled: true,
            Key.llmDeadlineMs: 150,         // LLMハード期限(ms)。超過で並べ替えを破棄。
            Key.llmContextTokens: 2048,     // n_ctx。控えめに固定しKVキャッシュRAMを節約。
            Key.modelFileName: "tinyswallow-1.5b-instruct-q4_k_m.gguf",
            Key.maxCandidatesToLLM: 9       // LLMへ渡す上位候補数(プロンプト短縮)。
        ])
    }

    /// 直近コンテキストとして保持する最大文字数（リングバッファ容量）。
    var contextCharLimit: Int { defaults.integer(forKey: Key.contextCharLimit) }

    var llmEnabled: Bool { defaults.bool(forKey: Key.llmEnabled) }

    /// LLM推論のハード期限(秒)。
    var llmDeadline: TimeInterval { Double(defaults.integer(forKey: Key.llmDeadlineMs)) / 1000.0 }

    var llmContextTokens: Int { defaults.integer(forKey: Key.llmContextTokens) }

    var maxCandidatesToLLM: Int { defaults.integer(forKey: Key.maxCandidatesToLLM) }

    /// モデル/文法の置き場所（Application Support）。存在しなければ作る。
    var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("KotoeriLLM", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var modelFileName: String { defaults.string(forKey: Key.modelFileName) ?? "model.gguf" }

    /// 解決済みモデルパス。models/ サブフォルダに単一ファイルで配置する想定。
    var resolvedModelPath: String {
        supportDir.appendingPathComponent("models/\(modelFileName)").path
    }

    /// リランキング出力を構文的に強制する GBNF 文法ファイル。
    /// 配置: バンドル内 Resources/rerank.gbnf を優先、なければ Application Support。
    var grammarPath: String {
        if let bundled = Bundle.main.path(forResource: "rerank", ofType: "gbnf") {
            return bundled
        }
        return supportDir.appendingPathComponent("rerank.gbnf").path
    }
}

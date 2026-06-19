//
//  main.swift
//  KotoeriLLM — 文脈予測強化型 日本語IME
//
//  IMKServer を起動し、IMKInputController(= KotoeriInputController) を
//  Info.plist の InputMethodConnectionName 経由で macOS の入力ソースに接続する。
//
//  ストレージ方針: 本プロセスは入力内容を一切ディスクへ書かない。
//  コンテキストはインメモリのリングバッファ(ContextBuffer)のみで保持する。
//

import Foundation
import InputMethodKit

// Info.plist の "InputMethodConnectionName" と一致させること。
let kConnectionName = "KotoeriLLM_1_Connection"

// IMKServer は Info.plist の "InputMethodServerControllerClass" /
// "InputMethodServerDelegateClass" を見て、入力時に Controller を生成する。
// バンドル識別子は Info.plist の CFBundleIdentifier を使う。
let server = IMKServer(
    name: kConnectionName,
    bundleIdentifier: Bundle.main.bundleIdentifier
)

// LLM / Mozc / 設定の初期化（失敗してもアプリは起動し続け、フォールバックする）。
AppServices.shared.bootstrap()

NSLog("[KotoeriLLM] IMKServer started: \(kConnectionName) server=\(String(describing: server))")

// 入力メソッドは LSBackgroundOnly のエージェントとして常駐する。
RunLoop.main.run()

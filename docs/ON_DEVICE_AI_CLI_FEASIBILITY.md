# On-Device AI CLI 可行性研究(Claude Code / Codex 原生 iPhone 執行)

分支:`feature/native-ai-runtime`。狀態:**研究進行中**,本文件只記錄已驗證的事實;未通過的項目一律不標完成。

## 核心目標

在 iPhone 本機執行真正的 Claude Code / Codex CLI,不依賴 SSH、Mac、NAS、VPS 或任何遠端執行主機。
AI 模型推論可以使用網路;CLI runtime、檔案存取、程式執行與測試必須在 iPhone 本機完成。

## 驗收情境(未通過,待實作後驗證)

- [ ] 實體 iPhone 開飛航模式(確認無任何遠端連線),建立 `hello.py` 並成功執行 Python
- [ ] 恢復網路(不連 SSH),啟動 Claude Code → 合法登入 → 要求它修改 `hello.py` → 呼叫本機 Python 執行測試
- [ ] Codex 獨立完成相同測試

## 兩條技術路線

| | 路線 A:Claude Code(Node.js) | 路線 B:Codex(Rust) |
|---|---|---|
| 做法 | 嵌入 nodejs-mobile(JIT-less V8),官方 `cli.js` 原封執行,`child_process` 等用 shim 攔截 | `codex-core` 編成 `aarch64-apple-ios` 靜態庫連進 app,spawn 層換成 LocalShell |
| 先例 | ✅ `ikunluo3-bit/l-shell-ios` 已公開驗證(見下) | 無已知先例,編譯實驗進行中 |
| 主要風險 | 授權(見下)、Node 18 EOL、記憶體 | 依賴樹龐大(100+ crate),平台耦合未知 |

## 研究發現:l-shell-ios(2026-11-17)

來源:`github.com/ikunluo3-bit/l-shell-ios`(MIT),已 clone 至 `~/Documents/research/l-shell-ios` 研讀。

**已驗證可行(該專案公開聲明 + 原始碼佐證):**

- [nodejs-mobile](https://github.com/nodejs-mobile/nodejs-mobile)(JIT-less V8、Node 18.19.1,使用 1Conan fork 的 iOS build)以 XCframework 嵌入,Node 與 app 同程序。
- **官方 Claude Code CLI(2.1.112)未修改直接執行**。關鍵是 `node-runtime/preload/shims/child_process.js`:攔截 `node:child_process` 全部匯出,覆蓋 Claude Code 的 ~41 個呼叫點;async spawn 回傳假 ChildProcess(EventEmitter + stdio streams),sync 回 spawnSync 形狀的物件;指令路由到 registry(bash/sh、rg 由 just-bash 實作),未知指令以 exit 127 / ENOENT 優雅降級(Claude Code 對 gh/tmux 等本來就是 best-effort)。
- 中斷處理:kill()/options.signal/timeout 匯流到單一 AbortController;Claude Code 的 Bash tool 是用 pid tree-kill(`process.kill(pid,'SIGKILL')`),所以 shim 連 `process.kill` 都要對假 pid 路由。
- 其他 shims:`fetch`、`tty`、`wasm-stub`(JIT-less 無 WebAssembly)、`intl`(small-icu)、`process-exit`。
- git 用 isomorphic-git(純 JS、24 子指令)、npm 為 in-process 安裝器、Python 用 BeeWare CPython 3.13、coreutils ~90 個來自 just-bash + 自補。

**該專案誠實承認的限制(對 PocketCode 同樣適用):**

- `npx bun deno ruby perl php go rustc cargo java gcc make` 都不能跑(需要 fork/exec 或 WASM)
- Node 18 已 EOL;MCP stdio server 不支援(單一 Node 實例);每開一次 Claude session 洩漏一個 `cli.js` 模組(多次後需重啟 app)

**與 PocketCode 的差異:**

- l-shell 的 Python/git/coreutils 全在 Node 側;PocketCode 已有 Swift LocalShell + 官方 CPython 3.15 XCframework(python.org PEP 730,非 BeeWare)。整合時 Claude Code 的 Bash tool 應優先路由到我們的 LocalShell/CPython,而不是照搬 just-bash。
- l-shell 以側載(AltStore/Sideloadly)散布,**不在 App Store**;PocketCode 要上 App Store,風險評估必須更嚴格(見下)。

## 授權審查 ⚠️(法務關鍵,未解決)

| 元件 | 授權 | 可商用/可散布? |
|---|---|---|
| l-shell-ios 本體 | MIT | ✅ 可參考、可改作(保留著作權聲明) |
| nodejs-mobile | MIT(Node.js 本體 MIT + V8 BSD) | ✅ |
| just-bash / isomorphic-git / ssh2 | MIT | ✅ |
| **`@anthropic-ai/claude-code`** | **"SEE LICENSE IN README.md" — Anthropic 專有商業授權,非開源** | ❌ **未經 Anthropic 同意不得隨 app 散布**。l-shell 的做法是 repo 不含 CLI、建置時 `npm pack` 下載、僅側載,迴避了「散布」;App Store 上架版把 cli.js 打包進 bundle 即構成散布,需要 Anthropic 授權或改用其他取得方式 |
| Codex CLI(openai/codex) | Apache-2.0 | ✅ 可嵌入、可商用(附授權聲明) |

**結論:路線 B(Codex)授權乾淨;路線 A(Claude Code)散布問題必須先解決**,選項:
1. 向 Anthropic 取得散布許可(正途,需商務接洽)
2. App 不內含 cli.js,首次執行時使用者登入後由 app 內 npm 下載 —— 但這觸發 App Store Guideline 2.5.2(禁止下載並執行程式碼,WebKit/JavaScriptCore 除外;嵌入式 V8 不在豁免內),**風險極高,不建議**
3. 僅路線 B 上架,路線 A 留在 TestFlight/自用開發版

## App Store 風險(需記錄,不假設通過)

- **2.5.2 下載程式碼**:bundle 內建的直譯器+隨 app 審查的腳本一般被接受(大量 app 嵌 Lua/JS);**執行使用者在裝置上寫的腳本**(python、未來的 node)屬灰色地帶,先例(Pythonista、a-Shell、iSH)存在但均經歷過審查波折。in-app npm/pip 下載第三方套件並執行,風險高於執行使用者自寫腳本。
- **JIT-less**:V8 interpreter-only 與 CPython 都不需要 JIT entitlement,合規。
- **私有 API**:nodejs-mobile 聲明不用私有 API;整合後需用 Xcode 驗證掃描確認。
- 審查備註應如實說明「可執行使用者自己的 Python/JS 腳本,全部在 app 沙盒內」。

## 實驗記錄

### 2026-11-17 — 環境與初步解剖

- Rust 1.100 + 1.99.1(codex 釘選)+ `aarch64-apple-ios` target 安裝完成。
- `openai/codex` clone 至 `~/Documents/research/codex`(152 MB)。workspace 100+ crate;平台耦合(linux-sandbox、windows-sandbox-rs、bwrap、tui、pty)已是獨立 crate,核心/平台分離架構對移植有利。子程序生成集中在 `core/src/spawn.rs` + `core/src/exec.rs`(`tokio::process::Command`)— iOS 替換面明確:spawn → PocketCode LocalShell + 內嵌 CPython。
- `cargo check -p codex-core --target aarch64-apple-ios` 進行中,結果待補。
- `l-shell-ios` clone 並研讀(發現見上節)。
- `@anthropic-ai/claude-code@2.1.112` npm metadata 確認授權為專有("SEE LICENSE IN README.md")。

### 待辦(依 codex 指令方向)

- [ ] codex-core iOS 編譯結果與障礙清單(進行中)
- [ ] 獨立實驗 target(不動正式 Terminal)嵌入 nodejs-mobile
- [ ] Claude Code 實機啟動/登入/讀寫專案驗證
- [ ] Agent Tool Bridge:AI 的 Bash tool → LocalShell;python → 內嵌 CPython
- [ ] 效能與記憶體實測(JIT-less Node 啟動時間、Claude session 記憶體、cli.js 洩漏影響)
- [ ] 授權解決方案決策(需產品負責人確認後才能定 App Store 版策略)

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

### 2026-11-17 — 路線 B 編譯可行性確認 ✅

- `cargo check -p codex-core --target aarch64-apple-ios`:**通過**(1m38s,零錯誤)。
- `cargo build -p codex-core --target aarch64-apple-ios --release`:**通過**(4m43s),產出 `libcodex_core.rlib`(557 MB 含 debuginfo;最終 app 內大小待 PoC 連結後量測)。
- 唯一需要的修補:上游 `mxc-sdk`(microsoft/mxc,codex 的沙盒引擎)`dispatch.rs` 兩處無條件呼叫被 cfg 排除在 iOS 外的 `run` 模組;本地 vendor + 兩行 `#[cfg(any(windows, linux, macos))]` 解決(`~/Documents/research/mxc-patched`,workspace `[patch]` 指向)。可向上游提 PR。
- 結論:**Codex 核心移植 iOS 的編譯障礙趨近於零**,工作量集中在(1)spawn/exec 層替換成 LocalShell(2)FFI 橋接(3)UI/登入整合。

### 2026-11-17 — 產品決策與市場查證

- **決策(產品負責人):Codex 先行,不等 Anthropic 授權。** Codex Apache-2.0 可直接商品化;Claude Code(Node 路線)降為後續實驗,等 Codex 整合完或授權明朗再啟動。
- 市場查證(2026-11):App Store 上「手機跑 Claude Code/Codex」的產品(ServerCC、MobileCLI、Cosyra 等)**全部是 SSH thin client,裝置本身不執行程式碼**;唯一本機實作 l-shell-ios 僅側載、未商品化。**「App Store 第一個本機 AI CLI」位置目前無人佔據。**

### 嵌入架構方向(路線 B,草案)

- API 入口:`codex_core::ThreadManager`(= ConversationManager)/`CodexThread`;`exec` crate(無頭執行器)是驅動 core 的現成範例。
- FFI:照 `pocket_python.c` 的成功模式 — Rust `staticlib` + C header + Swift 橋接;事件流(turn 進度、工具呼叫、輸出)經 callback 泵到終端機。
- 工具執行:`core/src/spawn.rs`/`exec.rs` 的 `tokio::process` 路由改接 PocketCode LocalShell(內建指令)與內嵌 CPython;沙盒語意對映 workspace root。
- 認證:API key 先行;OAuth 走既有的 port-forward 機制(Phase 4)。

### 2026-11-17 — FFI 嵌入層 `pocket-codex` 編譯通過 ✅

- 架構定案:**不做逐型別 C 綁定,改嵌 codex 的 app-server**(`run_main_with_transport_options` 是現成函式庫入口,支援 `AppServerTransport::UnixSocket`)。Swift 端連 app 容器內的 UDS、講 app-server JSON-RPC(VS Code 擴充同款協定);FFI 面只有 3 個函式(`pc_start`/`pc_free`/`pc_abi_version`)。`CODEX_HOME` 指向 app 容器,設定與認證全在沙盒內。
- 新增 `native/pocket-codex/`(Cargo.toml + src/lib.rs + include/pocket_codex.h)與 `scripts/build_codex.sh`。
- `codex-app-server` 整包 `cargo check --target aarch64-apple-ios` 通過(2m10s,零額外錯誤);`pocket-codex` 亦通過。
- 踩過的兩個雷(已解決,寫進 build script 防呆):
  1. **patch 表不跨 workspace 繼承** — codex 的 `[patch.crates-io]`(openai fork 的 tokio-tungstenite `proxy` feature 等)必須鏡射到我們的 Cargo.toml。
  2. **版本解析偏移** — 獨立解析會挑到互不相容的 `rama-*` 版本;必須以 codex 的 `Cargo.lock` 為基準。
- `Arg0DispatchPaths` 全 `Option`、`AppServerRuntimeOptions` 可關 signal handler/daemon 行為 — 上游本來就支援函式庫式嵌入,argv[0] 重執行不是障礙。

### 2026-11-17 — ✅ PoC 達成:Codex app-server 在 iOS 模擬器運行並完成 JSON-RPC 握手

實驗 target `CodexLab`(`native/CodexLab/`,獨立 app,不碰正式 PocketCode)。成功證據(simctl console 原文):

```
[codexlab] pc_start ok → /tmp/codexlab.sock
[codexlab] socket connected
[codexlab] websocket upgraded
[codexlab] → initialize sent, waiting for reply…
[codexlab] ← {"id":1,"result":{"userAgent":"pocketcode-lab/0.0.0 (iOS 27.2.0; unknown) …","codexHome":"…/Documents/codex-home","platformFamily":"unix","platformOs":"ios"}}
[codexlab] ← {"method":"remoteControl/status/changed","params":{"status":"disabled",…}}
```

`"platformOs":"ios"` 由 Codex 自己回報;`codexHome` 位於 app 沙盒 Documents。四輪 debug 的完整紀錄(供重現):

1. `Arg0DispatchPaths::default()` → `Codex executable path is not configured`:app-server 啟動時無條件建構 exec-server 選項,需要 self-exe 路徑(僅儲存,spawn 時才用)。解:`codex_self_exe: std::env::current_exe().ok()`。
2. 模擬器 unix socket 路徑超過 `sockaddr_un` 約 104 bytes 上限(host 路徑 130+ 字元)。解:模擬器用 `/tmp`,實機容器 tmp 約 96 字元可用,接近上限 — 正式整合時要防呆(過長時 fallback)。
3. 原始 JSONL 被斷線:UDS transport 實際是 **WebSocket over unix socket**(tungstenite `accept_hdr_async`),accept 不要求認證/特殊 header,壓縮(zstd)選配。
4. Swift 端實作最小 RFC 6455 客戶端(HTTP upgrade + masked text frames,~100 行,零依賴)→ 握手成功。

選 UDS(而非 loopback TCP WebSocket)的理由:unix socket 天然 app 私有,不需碰 `WebsocketAuthSettings` 的 token 機制;loopback TCP 在裝置上可被其他 app 連線,安全面較差。

### 待辦(依 codex 指令方向)

- [x] codex-core iOS 編譯結果與障礙清單(✅ check + release build 均通過,僅 mxc 兩行補丁)
- [ ] 獨立實驗 target(不動正式 Terminal)嵌入 nodejs-mobile
- [ ] Claude Code 實機啟動/登入/讀寫專案驗證
- [ ] Agent Tool Bridge:AI 的 Bash tool → LocalShell;python → 內嵌 CPython
- [ ] 效能與記憶體實測(JIT-less Node 啟動時間、Claude session 記憶體、cli.js 洩漏影響)
- [ ] 授權解決方案決策(需產品負責人確認後才能定 App Store 版策略)

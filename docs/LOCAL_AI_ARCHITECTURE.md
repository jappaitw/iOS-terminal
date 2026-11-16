# PocketCode 本機執行與 AI Agent 架構

> 狀態：Phase 0 稽核產出（2026-11-16）。之後各階段會依實作結果更新。

## 1. 現況盤點（實際讀過程式碼後的結論）

| 模組 | 檔案 | 現況 | 可重用程度 |
|------|------|------|-----------|
| 終端機 UI | `TerminalPanel.swift`、`KeyRow.swift` | SwiftTerm 畫面、分頁、鍵列、連結列、⋯ 選單 | **高**：與後端無關，可直接共用 |
| 終端機工作階段 | `TerminalSession.swift` | **與 SSH 緊密耦合**：持有 `SSHClient`，`start()` 直接呼叫 `withPTY`；輸入走 `InputBox`（保序）；另有連結偵測、OAuth 轉送 | **中**：連結偵測、InputBox、畫面設定可留；執行端要抽成後端介面 |
| SSH 連線 | `SSHConnection.swift`、`PortForward.swift` | 連線、重連、健康檢查、SFTP、遠端指令、`direct-tcpip` 轉送 | 不動（Remote 後端專用） |
| 檔案系統 | `FileSystem.swift` | `FileSystemProvider` 協定，已有 `LocalFileSystem`（App Documents 或 security-scoped 資料夾）與 `SFTPFileSystem` | **高**：本機終端機與 Agent 工具都操作同一個根目錄 |
| 工作區 | `Workspace.swift` | 一個 `Workspace` = 一個根目錄 + 檔案系統 + 編輯器分頁 + 終端機；`newTerminal()` 只在有 SSH 連線時可用 | **中**：要讓本機工作區也能開終端機 |
| 編輯器 | `EditorArea.swift` | Runestone、存檔、跳行 | 高，不需改 |
| 搜尋 / Git | `Search.swift`、`Git.swift` | 本機搜尋已有 Swift 實作；Git 只支援遠端（iOS 無 git 執行檔） | 本機搜尋邏輯可給 Agent 的 `search_files` 重用 |
| 設定 / 授權頁 | `Settings.swift`、`Licenses.swift` | 授權清單由 `scripts/gen_acknowledgements.py` 產生 | 加入 CPython 後要補 PSF 授權 |

測試：`PocketCodeTests`（33 項）＋選擇性的 SSH 轉送整合測試。建置：XcodeGen（`project.yml`）＋ Xcode 27.2，實機簽章 Team `TUBWWB43W7`。

## 2. 目標架構

```text
PocketCode
├── Workspace（Local / Remote）
├── File Explorer、Code Editor（共用）
├── Terminal Manager
│   ├── TerminalSession（UI 狀態、SwiftTerm、連結偵測）
│   └── TerminalBackend 協定
│       ├── SSHBackend          ← 既有行為原封不動搬進來
│       └── LocalShellBackend   ← 新：Swift 指令直譯器
├── Local Runtime
│   ├── LocalShell（行編輯、解析、管線、重導）
│   ├── BuiltinCommands（ls、cd、cat、grep…，純 Swift）
│   ├── PythonRuntime（官方 CPython iOS XCframework，嵌入式）
│   └── WorkspaceSandbox（所有路徑都限制在授權根目錄內）
└── AI Agent Runtime（Phase 3 起）
    ├── AgentSession（對話、提案、審核）
    ├── ToolExecutor：read_file / write_file / list_directory / search_files / apply_patch / run_python
    └── Provider Adapter（BYO API key 等，見 FEASIBILITY）
```

### 關鍵設計決策

1. **終端機 UI 與執行端分離**：`TerminalSession` 保留畫面與共用功能，執行端改為注入的 backend。SSH backend 是把現有程式碼原樣搬遷，降低回歸風險。
2. **本機指令以 Swift 實作，不追求 bash 相容**：iOS 禁止 `fork/exec`，不存在真正的 shell。自寫直譯器支援引號、變數、萬用字元、`|`、`>`、`>>`、`<`、`&&`、`||`、`;`，文件中明確標示「非 bash」。
3. **Python 用官方 CPython 嵌入**：同一個行程內執行，跑在背景執行緒；stdout/stderr 以 pipe 導回終端機；中斷用 `PyErr_SetInterrupt()`（等同 Ctrl-C → `KeyboardInterrupt`）。
4. **路徑沙箱**：本機終端機與 Agent 工具都經過 `WorkspaceSandbox`，路徑解析後必須落在工作區根目錄內（含 symlink 解析），避免存取 App 其他資料（例如主機清單）。
5. **Agent 不能執行任意原生程式**：工具集固定；`run_python` 只能跑工作區內的 Python 檔；破壞性操作（刪除、覆寫）需使用者確認。

## 3. 實作順序

1. Phase 1a：抽出 `TerminalBackend`，SSH 改走 backend（回歸測試確認無變化）→ `LocalShellBackend` ＋內建指令 ＋ 單元測試。
2. Phase 1b：嵌入 CPython，`python`／`python3` 指令、REPL、中斷 → 實機驗收 `python main.py`。
3. Phase 2（可與 1b 並行）：Codex Rust 原始碼研究與 iOS PoC（獨立 target，不碰正式 SSH 程式碼）。
4. Phase 3：Agent 工具層（先做純本機、可測試的工具執行器，再接模型）。
5. Phase 4–6：驗證、授權、整合與測試。

## 4. 對既有 SSH 功能的回歸風險

| 風險 | 緩解 |
|------|------|
| 搬遷 `TerminalSession` 時改壞 SSH 輸入順序、重連、OAuth 轉送 | backend 只是「搬家」不改邏輯；保留現有單元測試；實機重跑 SSH／Claude Code／Codex 登入 |
| 本機工作區開啟終端機的 UI 條件改變影響遠端 | `canOpenTerminal` 對遠端仍等同 `isRemote` |
| 加入 Python 後建置腳本（install_python）影響簽章 | 獨立 Run Script phase；Debug/Release 與實機都要驗證 |

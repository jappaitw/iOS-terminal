# 本機執行與 AI Agent 開發進度

分支：`feature/native-ai-runtime`（實驗性工作不直接推 `main`）

## 進度總覽

| 階段 | 狀態 | 說明 |
|------|------|------|
| Phase 0 稽核 | ✅ 完成 | `LOCAL_AI_ARCHITECTURE.md`、`LOCAL_AI_FEASIBILITY.md` |
| Phase 1a 本機終端機 | ✅ 完成 | Swift 指令直譯器（`LocalShell/`，單元測試通過） |
| Phase 1b Python | ✅ 完成 | 官方 CPython 3.15.2 iOS XCframework；`python` 指令、REPL、Ctrl-C、workspace 防護，模擬器測試 9/9 通過 |
| Phase 2 Codex 研究 | 待開始 | Rust iOS 目標與原始碼下載已獲同意 |
| Phase 3 Agent 工具 | 待開始 | |
| Phase 4 認證 | 待開始 | |
| Phase 5 混合工作區 | 待開始 | |
| Phase 6 測試 | 待開始 | |

## 紀錄

### 2026-11-17 — Phase 1b 完成
- 內嵌官方 CPython 3.15.2：`ThirdParty/Python.xcframework`（`scripts/fetch_python.sh` 下載、不進 git）、
  build phase `scripts/install_python_stdlib.sh` 安裝 stdlib（排除 test/idlelib/tkinter 等省 ~200 MB）。
- `PocketCode/Python/pocket_python.c`：PyConfig 初始化（UTF-8、自訂搜尋路徑）、單執行緒 GIL 管理、`PyErr_SetInterruptEx` 模擬 Ctrl-C。
- `PocketCode/PythonApp/pocketcode_runner.py`：`python file.py / -c / -m / - / REPL / -V`，audit hook 把讀寫限制在 workspace（防禦縱深，非安全邊界）。
- `PythonRuntime.swift`：專屬直譯器執行緒（CPython 訊號只在初始化執行緒處理）、pipe 泵 stdout/stderr、stdin 餵 `input()`/REPL、同時只允許一個終端機使用。
- 修正：iOS 上 runpy 是 frozen 模組沒有 `__file__`，`_print_user_traceback` 原本直接取用導致使用者程式的 traceback 完全吃掉（stderr 空白）；改用 `getattr` 並在修剪失敗時退回完整 traceback。
- 驗收：模擬器 `PythonRuntimeTests` 9/9 通過（hello、argv/exit code、traceback 過濾、pipe/終端機 stdin、workspace 防護、模組重載、Ctrl-C、unittest+sqlite3、REPL）。

### 2026-11-16 — Phase 0
- 稽核現有程式碼：`TerminalSession` 與 SSH 緊密耦合，需抽出 backend；`LocalFileSystem` 與本機搜尋可直接重用。
- 決策：本機指令自寫（不引入 ios_system）；Python 採官方 CPython iOS XCframework（PEP 730）。依據見 FEASIBILITY。
- 使用者同意的下載：CPython iOS XCframework（python.org）、Rust `aarch64-apple-ios` 目標、`openai/codex` 原始碼（僅研究用，放專案外）。

## 需要決策的事項

- 目前無。

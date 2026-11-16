# 本機執行與 AI Agent 開發進度

分支：`feature/native-ai-runtime`（實驗性工作不直接推 `main`）

## 進度總覽

| 階段 | 狀態 | 說明 |
|------|------|------|
| Phase 0 稽核 | ✅ 完成 | `LOCAL_AI_ARCHITECTURE.md`、`LOCAL_AI_FEASIBILITY.md` |
| Phase 1a 本機終端機 | 進行中 | Swift 指令直譯器 |
| Phase 1b Python | 進行中 | 官方 CPython 3.15.2 iOS XCframework（下載已獲同意） |
| Phase 2 Codex 研究 | 待開始 | Rust iOS 目標與原始碼下載已獲同意 |
| Phase 3 Agent 工具 | 待開始 | |
| Phase 4 認證 | 待開始 | |
| Phase 5 混合工作區 | 待開始 | |
| Phase 6 測試 | 待開始 | |

## 紀錄

### 2026-11-16 — Phase 0
- 稽核現有程式碼：`TerminalSession` 與 SSH 緊密耦合，需抽出 backend；`LocalFileSystem` 與本機搜尋可直接重用。
- 決策：本機指令自寫（不引入 ios_system）；Python 採官方 CPython iOS XCframework（PEP 730）。依據見 FEASIBILITY。
- 使用者同意的下載：CPython iOS XCframework（python.org）、Rust `aarch64-apple-ios` 目標、`openai/codex` 原始碼（僅研究用，放專案外）。

## 需要決策的事項

- 目前無。

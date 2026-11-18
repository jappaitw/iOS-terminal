# Pocode Feature Roadmap — 以桌面 codex CLI 為基準

原則:**桌面 CLI 能做的,Pocode 盡可能做到**;iOS 做不到的(spawn 外部程序)用內嵌替代方案逼近。

> **商業化門檻(產品負責人決策,2026-11-18):推進到 v1.3(Extensions 平台)才具實際商業價值、才對外發佈。**
> v1.0–1.2 為內部里程碑(TestFlight 內測),v1.3 完成後進入 App Store 上架與定價。
狀態:✅ 已完成 🔧 已實作待實機驗證 🟡 部分 ⬜ 未開始 ❌ 平台不可能(附替代)

## v1.0 — 核心閉環「AI 在手機上寫程式」(= 目前 build 6/7 範圍)

| 功能 | 桌面 CLI | Pocode | 備註 |
|---|---|---|---|
| ChatGPT 訂閱登入 | ✅ | 🔧 | 實機已登入成功;app 內瀏覽器修復在 build 6 |
| API key 登入 | ✅ | ✅ | 已驗證(到 OpenAI 401/真回應) |
| 互動對話(terminal) | ✅ TUI | ✅ | 終端機 `codex` session |
| shell 工具執行 | ✅ 真 shell | 🔧 | host-exec → LocalShell;審批修復在 build 6 |
| 檔案修改(apply_patch) | ✅ | 🔧 | 引擎內建,審批修復後生效 |
| Python 執行 | ✅ 系統 python | ✅ | 內嵌官方 CPython 3.15 |
| 常用 unix 工具 | ✅ 系統工具 | 🟡 | ls/cat/grep/find/… + 新增 curl/wget/rg/sed;持續擴充(下表) |
| Ctrl-C 中斷 | ✅ | 🔧 | build 6 |
| 登入持久化 | ✅ | ✅ | CODEX_HOME |
| 錯誤診斷 | stderr | ✅ | engine.log 落地+終端機顯示 |

## v1.1 — 日常可用性(CLI 平價 + 手機優勢)

| 功能 | 桌面 CLI | 計畫 |
|---|---|---|
| Session 續接(resume 上次對話) | `codex resume` | ⬜ `thread/resume` 協定現成;`codex` 啟動時問「繼續上次?」 |
| Slash 指令:`/new` `/status` `/model` | ✅ | ⬜ 終端機 session 內實作;model 清單走協定 |
| 審批模式切換(全自動 / 逐項確認) | `/approvals` | ⬜ 目前全自動;加終端機內 y/n 確認模式(安全性) |
| AGENTS.md 專案指示 | ✅ | 🟡 檔案式,理論已通 — 驗證即可 |
| 模型回應串流顯示 | ✅ 逐字 | ⬜ 目前整段;改 item/updated 增量渲染 |
| Reconnecting 噪音修復 | — | ⬜ WebSocket 憑證(rustls platform-verifier) |
| context 壓縮(/compact) | ✅ | ⬜ 協定有 ThreadCompactStart |
| 工具擴充第二批:diff、xargs、cut、tr、jq-lite | ✅ 系統工具 | ⬜ 同 BuiltinsExtra 模式 |
| 改名 Pocode / `>_` 標題列 / 外觀設定 | — | ✅ 手機獨有 |

## v1.2 — 協作與版本控制(GitHub 里程碑,spec 已定)

| 功能 | 桌面 CLI | 計畫 |
|---|---|---|
| `git` 指令(init/add/commit/log/branch/checkout/merge-ff) | ✅ 系統 git | ⬜ libgit2 嵌入(spec: 2026-11-18-github-sync-design.md) |
| GitHub 登入(Device Flow + PAT) | gh CLI | ⬜ 設定頁 + 終端機懶觸發 |
| push / pull / clone、一鍵建 repo | ✅ | ⬜ 手機↔電腦接續開發閉環 |
| codex 叫 git(「幫我 commit 推上去」) | ✅ | ⬜ 經 host-exec 自動獲得 |
| @file 提及 / 編輯器開啟 AI 改過的檔 | ✅ / IDE | ⬜ 手機 GUI 優勢:fileChange item → Editor 跳轉 |

## v1.3 — 擴充平台(Extensions)

| 功能 | 桌面 CLI | 計畫 |
|---|---|---|
| MCP(StreamableHttp) | ✅ | ⬜ 設定頁 GUI:加 URL+token(Keychain);`mcpServerStatus/list` 顯示狀態 |
| MCP(stdio) | ✅ spawn | ❌ → **獨家替代:內嵌 Python 跑 stdio MCP**(pipe 橋接,iPhone 首創) |
| Skills | ✅ 目錄式 | 🟡 引擎側已驗證(skills/list 含種入 skill);GUI 清單(`skills/list`)+ URL 安裝;檔案 App 丟入已可用 |
| Connectors(ChatGPT) | ✅ | 🟡 HTTP 類應可用,實機驗證後決定 |
| Web search 工具 | ✅ | ⬜ 驗證引擎內建版在 iOS 的行為 |
| 自訂 prompts | ✅ | ⬜ 檔案式,低工程 |

## v1.4 — 行動體驗深化

| 功能 | 計畫 |
|---|---|
| 長任務背景續跑:beginBackgroundTask + 斷線 resume | ⬜ 行動端最大痛點 |
| Live Activity(動態島顯示 agent 進度) | ⬜ 功能即行銷 |
| 推播:任務完成通知 | ⬜ |
| 多 thread 管理 GUI(對話列表/切換) | ⬜ 協定全支援 |
| 圖片輸入(截圖給 codex 看) | ⬜ UserInput 支援 image |
| i18n(繁中/簡中/日/韓/西) | ⬜ String Catalog |
| Light 主題(編輯器 Light+ 配色) | ⬜ |

## v2.0 — 平台擴張

- Claude Code 路線(Node 嵌入,待 Anthropic 授權決策;技術已由 CodexLab 期間驗證可行)
- Pocode 自有 agent 模式(直連多家模型 API)
- iPad 多窗/鍵盤深度優化、App Store 正式上架衝刺

## 永久性平台限制(誠實清單)

- 不能 spawn 外部二進位(→ 一切用內嵌/in-process 替代)
- 不能 `npx`/`gcc`/`cargo` 等需要外部工具鏈者(→ SSH 模式仍保留作為出口)
- 背景執行受 iOS 約 30 秒限制(→ v1.4 緩解)

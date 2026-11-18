# GitHub 同步設計(Pocode)

日期:2026-11-18。狀態:設計已與產品負責人逐項確認,待最終審閱。

## 目標

讓使用者把**手機上開發的專案**透過 GitHub 轉移到電腦接續開發,並能拉回手機 — GitHub 是橋,也是備份。核心能力:在 iPhone 本機執行 git(init/commit/push/pull/clone),登入 GitHub 帳號,一鍵建立遠端 repo。

## 非目標(v1 明確不做)

- 桌面端同步 app(電腦端就用標準 git / VS Code,零安裝)
- 衝突三方合併 UI(非 fast-forward 的 merge 衝突 → 中止並建議到電腦處理)
- SSH 協定 remote(v1 僅 HTTPS + token)、submodule、LFS、stash、rebase
- GitLab/Bitbucket(架構保留擴充空間,v1 僅 GitHub)

## 已確認的產品決策

| 決策 | 選擇 |
|---|---|
| 操作形態 | **C:先 CLI 後 GUI** — `git` 成為終端機指令(codex agent 因此也能用);Explorer 的「Publish/Sync」按鈕為後續薄殼 |
| 登入方式 | **C:Device Flow 為主 + PAT 備援** — 與 codex 登入選單同樣的雙軌體驗 |
| 登入入口 | 設定頁 Accounts 區(正式入口)+ 終端機懶觸發(未登入時執行 push/clone 直接啟動 Device Flow) |
| 指令範圍 | **B:傳輸集 + 分支基礎** — `init status add commit log remote push pull clone branch checkout merge(ff-only)` |
| git 引擎 | **X:libgit2** — 嵌入式 C 函式庫,GitHub Desktop 等皆用;與 CPython/Codex 相同的「C 庫 + 薄橋接」模式 |

## 架構

```
終端機 `git …` ──► ShellServices.runGit ──► GitRuntime.swift(指令解析/輸出格式化)
                                             │
                                             ▼
                                   libgit2(xcframework;TLS 用系統 SecureTransport)
                                             │  credential callback
                                             ▼
                                   GitHubAccount.swift(token ← Keychain)
                                             ▲
設定頁 Accounts ──► Device Flow / PAT ───────┘
「建立遠端 repo」──► GitHub REST API(POST /user/repos,URLSession)
codex 的工具呼叫 ──► host-exec ──► LocalShell ──►(同一條 runGit 路徑,零額外工作)
```

## 元件

1. **`scripts/build_libgit2.sh`** — 比照 `fetch_python.sh`/`build_codex.sh`:下載釘版 libgit2 原始碼,CMake 交叉編譯 device+simulator 靜態庫到 `ThirdParty/libgit2/`(不進 git)。組態:`USE_HTTPS=SecureTransport`、關 libssh2/測試,體積預估 < 3 MB。
2. **`PocketCode/Sources/LocalShell/GitRuntime.swift`** — `runGit` service。解析 `git <sub> [args]`,呼叫 libgit2 C API(bridging header 引入 `git2.h`),輸出貼近 git CLI 慣例(status porcelain 風格、push/pull 進度行)。所有路徑經 workspace 沙盒檢查(與其他指令同規)。
3. **`PocketCode/Sources/GitHubAccount.swift`** — Device Flow(`POST login/device/code` → 顯示 user code + 開 `github.com/login/device` → 輪詢 `login/oauth/access_token`)、PAT 輸入;token 存 **Keychain**;登入狀態/登出;`createRepo(name, private:)` 走 REST。Client ID 內嵌(Device Flow 不需 secret,需在 GitHub 註冊 OAuth App 並勾選 Enable Device Flow — 產品負責人一次性作業,步驟另附)。
4. **設定頁 Accounts 區** — 「Sign in with GitHub」/ 已登入顯示帳號與登出;並預留 Codex 登入狀態顯示(統一帳號區)。
5. **libgit2 credential callback** — HTTPS remote 要求認證時回 `x-access-token:<token>`;未登入 → 丟特定錯誤,GitRuntime 轉為啟動終端機內 Device Flow 後重試一次。

## 關鍵資料流

- **push(首推)**:`git push` → 無 remote →提示 `git remote add origin …` 或直接 `git push --create`(擴充:自動 createRepo + set remote + push,v1 提供)→ credential callback 取 token → libgit2 smart HTTPS。
- **clone**:`git clone https://github.com/user/repo` → 目的地限 workspace 內 → 進度回報(objects/deltas)。
- **merge**:僅 fast-forward;否則輸出「發生分歧,請在電腦解決(git pull --rebase 或 merge)」並保持 repo 乾淨。

## 錯誤處理

- 網路/401:明確訊息 + 重新登入指引;token 失效自動清 Keychain 狀態。
- 非 ff merge、衝突:中止、不留半套狀態、給電腦端指令建議。
- 大 repo clone:進度 + Ctrl-C 可中止(libgit2 progress callback 檢查取消旗標)。

## 安全

- Token 僅存 Keychain(不落檔案、不印 log);scope 要求 `repo`(私有 repo 需要)。
- 所有 git 操作限 workspace 沙盒;URL 僅允許 https://github.com/。

## 測試計畫

- 單元:GitRuntime 各子指令(本機 init/add/commit/log/branch/checkout/merge-ff 可完全離線測)。
- 整合(手動/實機):Device Flow 登入 → createRepo → push → 電腦 clone 驗證 → 電腦改動 push → 手機 pull。
- codex 協作驗收:對 codex 說「commit 並推上 GitHub」→ 工具呼叫經 LocalShell 執行 git 成功。

## 里程碑

1. libgit2 建置腳本 + 離線子指令(init/status/add/commit/log)+ 單元測試
2. branch/checkout/merge-ff + remote 管理
3. GitHub 登入(Device Flow + PAT + Keychain)+ 設定頁
4. push/pull/clone + createRepo + 終端機懶登入
5. 實機端到端驗收(手機↔電腦往返)→ 之後才做 Explorer 一鍵按鈕(另案)

# PocketCode 開發計畫

> 給下一階段（Opus 5.5）執行用。每項任務都附驗收標準與相關檔案。
> 專案現況：Explorer / Editor / Terminal 三大功能已在模擬器與兩台真實主機
>（Mac「CRA」：SFTP＋終端機全通；Synology「JP Nas」：終端機通、SFTP 未開）驗證過。

## 現況摘要（2026-11-16）

- 技術棧：SwiftUI + Citadel 0.12.0（SSH/SFTP）+ SwiftTerm 1.18.0（終端機）+ Runestone 0.5.2（編輯器）。套件全部鎖定確切版本，`project.yml` 用 XcodeGen 產生專案。
- 已修完的重大 bug：SFTP 不回應導致整個 app 卡死（現為 10 秒逾時＋純終端機模式）、快速輸入字元亂序（改為 InputBox 序列化管線）、功能鍵列壓到 Home 條（改為版面內固定鍵列）。
- 金鑰／密碼存 Keychain（模擬器需 ad-hoc 簽章 `CODE_SIGN_IDENTITY="-"`，否則 Keychain 回 -34018）。
- 主機金鑰採 TOFU（首連記住、變更即拒絕）。

## Phase 0 — 收尾與基礎建設（半天）✅ 已完成 2026-11-16

| # | 任務 | 驗收標準 | 檔案 |
|---|------|---------|------|
| ✅ 0.1 | `git init`＋初始 commit，建立 `main` 分支 | `git log` 有含全部原始碼的 commit | 專案根目錄 |
| ✅ 0.2 | Explorer 在 SFTP 不可用時顯示說明文字而非永遠轉圈 | 連 JP Nas 後 Explorer 顯示「未提供 SFTP…」訊息與重試鈕 | [ExplorerView.swift](PocketCode/Sources/ExplorerView.swift)、`UnavailableFileSystem` |
| ✅ 0.3 | 發佈組態移除偵錯紀錄（pwlen 等），改用 `#if DEBUG` | Release build 的 log 無密碼長度等敏感欄位 | [SSHConnection.swift](PocketCode/Sources/SSHConnection.swift) |
| ✅ 0.4 | 連線進度文字（連線中→認證中→開啟 SFTP）取代純轉圈 | 主機列顯示目前階段文字 | [HomeView.swift](PocketCode/Sources/HomeView.swift) |

另外順手修了：主機表單在「私鑰」驗證但金鑰欄空白時不能存檔（以前會存進空金鑰、連線才報錯）；SFTP 不可用時 Explorer 頂部按鈕變灰。

## Phase 1 — 穩定性（1–2 天）

| # | 任務 | 驗收標準 |
|---|------|---------|
| 1.1 | 背景→前景斷線自動重連：SSH 連線層加 health check，斷線時重建 client、SFTP、終端機提示「已重連」 | 鎖屏 1 分鐘回來，Explorer 操作與新終端機正常 |
| 1.2 | 終端機 session 斷線後按鈕重啟（已有 `start()`）補測與 UI 完善 | kill -9 遠端 shell 後可一鍵重開 |
| 1.3 | 大檔案保護：>5MB 文字檔先問、>50MB 拒開 | 開大檔不再無限等待 |
| 1.4 | 語法高亮首次載入 2–3 秒 → 背景預載常用語言或顯示骨架 | 第二次開同語言 <0.5 秒 |
| 1.5 | 單元測試：PathUtil、normalizedOpenSSHKey、LanguageInfo.detect | `xcodebuild test` 全綠 |

## Phase 2 — 功能補齊（3–5 天）

| # | 任務 | 驗收標準 |
|---|------|---------|
| 2.1 | 全專案搜尋（Explorer 加搜尋頁；遠端用 `grep -rn` over SSH exec，本機用檔案走訪） | 搜尋結果可點擊跳到該檔該行 |
| 2.2 | Git 狀態：在遠端跑 `git status --porcelain`，Explorer 檔名著色（M/A/U）、狀態列顯示分支 | 開 git 專案可見分支與變更標記 |
| 2.3 | 檔案上傳/下載：Explorer 長按→分享（下載到 Files）；工具列＋→從 Files 匯入上傳 | 雙向傳檔成功 |
| 2.4 | 終端機長按選單：複製、貼上、清除畫面；字型大小設定 | 功能可用且不與選取手勢衝突 |
| 2.5 | 設定頁：編輯器字級、縮排(空格數/Tab)、終端機字級、功能鍵列開關、隱藏檔預設值 | 設定持久化並即時生效 |
| 2.6 | 編輯器符號鍵列與終端機鍵列統一成同一元件（版面式，非鍵盤附件） | 兩處外觀一致、實體鍵盤下不懸浮 |
| 2.7 | 私鑰支援 ECDSA（P-256/384/521，Citadel 已有 API）與 OpenSSH 加密金鑰測試 | 三種金鑰可登入 |

## Phase 3 — 商品化（3–5 天）

| # | 任務 | 驗收標準 |
|---|------|---------|
| 3.1 | App 圖示＋啟動畫面（注意：不得使用/近似 VS Code 商標） | 全尺寸圖示齊備 |
| 3.2 | 開源授權頁（Citadel/SwiftTerm/Runestone/TreeSitter* 等 MIT/Apache 條款全文） | 設定頁可開啟授權清單 |
| 3.3 | 主機金鑰變更警示 UI：顯示新舊指紋、讓使用者選擇信任或拒絕（取代只能去設定頁 Forget） | 模擬金鑰變更有清楚對話框 |
| 3.4 | 真機測試（Developer 帳號、自動簽章、TestFlight 內測） | 實體 iPhone 跑通三大功能 |
| 3.5 | App Store 素材：截圖、描述（中英）、隱私標示（資料不離裝置） | 可送審狀態 |
| 3.6 | iPad 分割版面打磨：側欄寬度記憶、⌘ 快捷鍵完整清單、游標支援 | iPad 實測體驗順暢 |

## Phase 4 — 進階（選做）

- mosh 式連線韌性（或 SSH keepalive + 自動重試佇列）
- 多工作區同時開啟（TabView 或場景）
- 編輯器多游標、符號跳轉（tree-sitter query）
- Port forwarding（Citadel 已有 DirectTCPIP）＋內建簡易 Web 預覽
- iCloud 同步主機清單（密碼仍留本機 Keychain）

## 已知地雷（執行前必讀）

1. **Citadel 鎖 0.12.0**：0.12.1 把 swift-nio-ssh 換成第三方 fork（供應鏈風險），升版前先審。
2. **SwiftTerm 鎖 1.18.0**：1.19+ 引入 build plugin，CI/本機編譯會要求信任；如需升版改用 `-skipPackagePluginValidation` 並審 plugin 原始碼。
3. **模擬器 Keychain**：必須 `CODE_SIGN_IDENTITY="-"`（ad-hoc），`CODE_SIGNING_ALLOWED=NO` 會導致存取靜默失敗（-34018）。
4. **NAS 類主機**：SSH 通不代表 SFTP 有開；`openSFTP` 可能永不回應——`SSHConnection.openSFTP(_:timeoutSeconds:)` 的 race 寫法是刻意的，勿改回 task group（group 會等掛死子任務）。
5. **終端機輸入順序**：所有寫入都必須走 `TerminalSession.InputBox`（同步 yield 保序），不要新開 per-key Task。
6. **編譯指令**：`xcodegen generate && xcodebuild -project PocketCode.xcodeproj -scheme PocketCode -destination 'id=<sim-udid>' -clonedSourcePackagesDirPath .spm -derivedDataPath .build CODE_SIGN_IDENTITY="-" build`

## 測試主機備忘

- CRA（Mac, 10.0.1.201, jlmx）：全功能驗證基準。
- JP Nas（Synology, 10.0.1.108/nas.jappai.tw, codex）：SSH＋SFTP 皆已開啟並驗證（Explorer 顯示共用資料夾）。
- M1U（10.0.1.198, soulfyai）：帳密待確認（該機 `whoami` 核對短名）；app 內其密碼當初在未簽章版存入、Keychain 實際為空，需重新輸入。
- 測「SFTP 不可用」畫面：在本機起一個不含 `Subsystem sftp` 的 sshd（127.0.0.1 限定、金鑰登入）即可重現。

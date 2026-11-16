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

## Phase 1 — 穩定性（1–2 天）✅ 已完成 2026-11-16

| # | 任務 | 驗收標準 | 實作 |
|---|------|---------|------|
| ✅ 1.1 | 背景→前景斷線自動重連 | 回前景時連線死掉 → 自動重登、Explorer 與終端機恢復 | `Workspace.ensureConnected()`（scenePhase .active 觸發）→ `SSHConnection.isHealthy()`（5 秒 round-trip 探測，SFTP realpath 或 exec `true`）→ `reconnect()`（同憑證、沿用首次連線的主機金鑰）→ 換 fs、`TerminalSession.reattach(client:)`。狀態列顯示 Checking/Reconnecting/「Disconnected · Retry」 |
| ✅ 1.2 | 終端機 session 結束後一鍵重開 | kill -9 遠端 shell 後可一鍵重開 | 終端機下方 Restart 橫幅（取代鍵列）；`Workspace.restart` 先檢查連線再 `start()`；`runID` 防止舊 task 覆蓋新狀態；重開不 `clear`，保留捲動紀錄 |
| ✅ 1.3 | 大檔案保護 | >5MB 先問、>50MB 拒開 | `FileSystemProvider.fileSize`；`EditorDocument.softLimit/hardLimit`；>2MB 自動關閉語法高亮 |
| ✅ 1.4 | 語法高亮首次載入延遲 | 第二次開同語言 <0.5 秒 | 實測：首次建立高亮狀態有約 0.9 秒「全域一次性」成本（與語言無關），之後任何語言都 <0.1 秒 → app 啟動時背景 `warmUpHighlighting()`；實機 log：開 .py 0.03 秒 |
| ✅ 1.5 | 單元測試 | `xcodebuild test` 全綠 | `PocketCodeTests`（13 項）：PathUtil、normalizedOpenSSHKey（含智慧破折號、斷行、CRLF）、LanguageInfo.detect、高亮計時診斷 |

## Phase 2 — 功能補齊（3–5 天）✅ 已完成 2026-11-16

| # | 任務 | 驗收標準 | 實作 |
|---|------|---------|------|
| ✅ 2.1 | 全專案搜尋 | 結果可點擊跳到該檔該行 | 底部新增「Search」分頁（iPad 側欄、⌘⇧F）。遠端 `grep -rnI --null` over SSH exec（排除 .git/node_modules 等，上限 2000 筆），本機背景走訪；大小寫／全字／正規式切換；點結果 → `open(path, line:)` 選取該行 |
| ✅ 2.2 | Git 狀態 | 可見分支與變更標記 | `GitSnapshot`：`git rev-parse --show-toplevel` + `git status --porcelain=v1 -b -z`；檔名著色＋M/A/U/D/R/! 字母，含變更的資料夾顯示圓點；狀態列顯示分支（有變更加 *，點擊重新整理）。存檔／新增／刪除／重連後自動更新。本機工作區（iOS 無 git）不顯示 |
| ✅ 2.3 | 上傳／下載 | 雙向傳檔成功 | 長按檔案「Download…」→ 暫存 → 分享單（存到檔案、AirDrop）；Explorer 頂部與資料夾長按「Upload Files Here…」→ Files 多選匯入；同名檔詢問「取代／只傳新檔」；上限 100MB；底部進度膠囊 |
| ✅ 2.4 | 終端機選單＋字級 | 不與選取手勢衝突 | 長按沿用 SwiftTerm 原生選單（Select／Copy／Paste，已測可複製）；終端機標頭「⋯」：Paste、Select All、Clear、字級±；雙指縮放調字級 |
| ✅ 2.5 | 設定頁 | 持久化並即時生效 | `AppSettings`（UserDefaults）：編輯器字級、空格／Tab 與寬度、自動換行、終端機字級、鍵列開關、隱藏檔預設。首頁齒輪與工作區「⋯ → Settings…」進入；改動即時套用到已開啟的編輯器與終端機，狀態列顯示「Spaces: N」 |
| ✅ 2.6 | 鍵列統一 | 兩處一致、實體鍵盤下不懸浮 | 共用 `KeyRow` 元件（版面內、42pt）；編輯器鍵列只在編輯中出現，移除 inputAccessoryView |
| ✅ 2.7 | ECDSA 與加密金鑰 | 三種金鑰可登入 | `PrivateKeyParser`：先讀 openssh-key-v1 判斷型別；ECDSA P-256/384/521（Citadel 無解析器，自行解析）、PEM `EC PRIVATE KEY`（CryptoKit 不吃 ssh-keygen 格式，自寫 SEC1 讀取）、加密 ed25519／RSA（含錯誤密語提示）。實測 ECDSA 金鑰登入成功。未支援：加密 ECDSA、舊式 PEM RSA → 給出 `ssh-keygen -p` 轉換指示 |

順手修正：iPhone 上隱藏中的終端機／編輯器仍會吃到長按手勢（Explorer 長按跳出終端機選單）→ 以 `panelActive` 環境值關閉非前景面板的 UIKit 互動；搜尋結果跨檔同行號列空白；狀態列窄螢幕被截斷（`ViewThatFits` 依序省略 UTF-8、縮排）。單元測試增至 26 項。

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
5. **重連**：`SSHConnection.client` 會被換掉，任何地方都不要快取舊 client；終端機一律經 `reattach` 換綁。`ensureConnected()` 已做併發合併（同時多次呼叫共用一個 task）。
6. **終端機輸入順序**：所有寫入都必須走 `TerminalSession.InputBox`（同步 yield 保序），不要新開 per-key Task。
7. **遠端指令**：一律用 `SSHConnection.run(script)`（包成 `sh -c '…' 2>/dev/null; true`）。Citadel 的 `executeCommand` 遇非零結束碼或任何 stderr 都會 throw。
8. **iPhone 面板疊放**：三個面板在 ZStack 裡以 opacity 切換，`allowsHitTesting(false)` 擋不住 UIKit 手勢；新的 UIKit 面板要讀 `@Environment(\.panelActive)` 自行關閉互動。
9. **編譯/測試指令**：`xcodegen generate && xcodebuild -project PocketCode.xcodeproj -scheme PocketCode -destination 'id=<sim-udid>' -clonedSourcePackagesDirPath .spm -derivedDataPath .build CODE_SIGN_IDENTITY="-" build`（測試把 `build` 換成 `test`）

## 測試主機備忘

- CRA（Mac, 10.0.1.201, jlmx）：全功能驗證基準。
- JP Nas（Synology, 10.0.1.108/nas.jappai.tw, codex）：SSH＋SFTP 皆已開啟並驗證（Explorer 顯示共用資料夾）。
- M1U（10.0.1.198, soulfyai）：帳密待確認（該機 `whoami` 核對短名）；app 內其密碼當初在未簽章版存入、Keychain 實際為空，需重新輸入。
- 測重連：本機 sshd（127.0.0.1:2222）連上後，對該連線的 `sshd-session` 行程 `kill -STOP`（模擬背景後 socket 假活），按 Home 再開回 app → 約 5 秒後自動重連；再把 listener 也停掉可看到「Disconnected · Retry」。
- 測「SFTP 不可用」畫面：在本機起一個不含 `Subsystem sftp` 的 sshd（127.0.0.1 限定、金鑰登入）即可重現。

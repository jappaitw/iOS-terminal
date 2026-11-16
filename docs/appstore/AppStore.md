# App Store 上架素材 / App Store Listing

> 草稿，送審前請再確認。標示 ⚠️ 的項目需要你本人決定或提供。

## 基本資料

| 欄位 | 內容 |
|------|------|
| App 名稱 | PocketCode ⚠️（先在 App Store Connect 確認名稱未被占用） |
| 副標題（30 字元內） | EN: `SSH Terminal & Code Editor` · 繁中: `SSH 終端機與程式碼編輯器` |
| 類別 | 主要：開發者工具（Developer Tools）· 次要：公用程式（Utilities） |
| 年齡分級 | 4+（無不當內容；可連線到使用者自訂的伺服器） |
| 價格 | ⚠️ 未定 |
| Bundle ID | `com.jlmxstudio.pocketcode` |
| 版本 | 1.0 (1) |
| 支援網址 | ⚠️ 需要一個網頁（可用 GitHub Pages） |
| 隱私權政策網址 | ⚠️ 需要一個網頁，內容可用下方「隱私權政策草稿」 |

**商標注意**：描述、關鍵字、截圖都不要出現「VS Code」「Visual Studio Code」或其圖示。設定頁已加註「PocketCode is not affiliated with or endorsed by Microsoft or Visual Studio Code.」

## 關鍵字（100 字元內，逗號分隔、不要空格）

EN: `ssh,terminal,sftp,code editor,git,server,shell,remote,developer,linux,raspberry pi,nas,devops`

繁中: `ssh,終端機,sftp,程式碼,編輯器,git,伺服器,遠端,開發者,linux,樹莓派,nas,shell`

## 推廣文字（170 字元內，可隨時改）

EN: Your servers in your pocket. A real SSH terminal, a syntax-highlighting editor and a file explorer with Git status — built for iPhone and iPad.

繁中: 把伺服器放進口袋。真正的 SSH 終端機、支援語法高亮的編輯器，加上顯示 Git 狀態的檔案總管，專為 iPhone 與 iPad 打造。

## 描述 — English

PocketCode brings the three tools you reach for most — a terminal, a code editor and a file explorer — to iPhone and iPad, connected to your own machines over SSH.

TERMINAL
• Full xterm-256color terminal over SSH: run vim, htop, git, tmux and anything else
• Extra key row with esc, ctrl, tab, arrows and symbols
• Multiple terminals, pinch to zoom, copy & paste
• Reconnects automatically when you come back to the app

EDITOR
• Syntax highlighting for 20+ languages (Swift, Python, JavaScript/TypeScript, Go, Rust, C/C++, Java, Ruby, PHP, HTML/CSS, JSON, YAML, Markdown, SQL and more)
• Line numbers, find & replace, undo/redo, configurable indentation and word wrap
• Edit and save files directly on the server

EXPLORER
• Browse remote folders over SFTP, or files on your device and in iCloud Drive
• Git branch and per-file status (modified, added, untracked…) at a glance
• Search across a whole project and jump straight to the line
• Create, rename, delete, upload from Files and download to Files

SECURE BY DESIGN
• Password, ED25519, ECDSA and RSA keys (including passphrase-protected keys)
• Passwords and keys are stored only in the iOS Keychain on this device
• Server fingerprints are verified on first connect, and you're warned if one ever changes
• No accounts, no tracking, no data collection — PocketCode talks only to the servers you add

iPAD
• Sidebar, editor and terminal side by side, resizable
• Hardware keyboard shortcuts and pointer support

PocketCode is an independent app and is not affiliated with Microsoft or Visual Studio Code.

## 描述 — 繁體中文

PocketCode 把你最常用的三樣工具——終端機、程式碼編輯器、檔案總管——帶到 iPhone 與 iPad，透過 SSH 直接連到你自己的電腦與伺服器。

終端機
• 完整的 xterm-256color SSH 終端機：vim、htop、git、tmux 都能用
• 額外按鍵列：esc、ctrl、tab、方向鍵與常用符號
• 多個終端機分頁、雙指縮放字級、複製貼上
• 回到 App 時自動重新連線

編輯器
• 20 多種語言的語法高亮（Swift、Python、JavaScript/TypeScript、Go、Rust、C/C++、Java、Ruby、PHP、HTML/CSS、JSON、YAML、Markdown、SQL 等）
• 行號、尋找與取代、復原／重做、可設定縮排與自動換行
• 直接編輯並儲存伺服器上的檔案

檔案總管
• 透過 SFTP 瀏覽遠端資料夾，也能開啟裝置上與 iCloud 雲碟的檔案
• 一眼看出 Git 分支與每個檔案的狀態（已修改、新增、未追蹤…）
• 全專案搜尋，點一下直接跳到該行
• 新增、重新命名、刪除，從「檔案」App 上傳、下載到「檔案」App

安全設計
• 支援密碼、ED25519、ECDSA、RSA 金鑰（含有密語保護的金鑰）
• 密碼與金鑰只存在這台裝置的 iOS 鑰匙圈
• 首次連線會核對伺服器指紋，指紋變更時會警告你
• 不需註冊帳號、不追蹤、不蒐集任何資料——PocketCode 只會連線到你自己加入的伺服器

iPad
• 側欄、編輯器、終端機並排，大小可調
• 支援實體鍵盤快捷鍵與游標

PocketCode 為獨立開發的 App，與 Microsoft 或 Visual Studio Code 無關。

## 截圖

已用乾淨的模擬器（無個人主機資料、提示字元為 `dev@server`）產生，放在 `docs/appstore/screenshots/`：

| 裝置 | 尺寸 | 檔案 |
|------|------|------|
| iPhone 6.9"（iPhone 16 Pro Max） | 1320 × 2868 | `iphone-6.9/01-editor.png`、`02-explorer-git.png`、`03-search.png`、`04-terminal.png` |
| iPad 13"（iPad Pro 13" M4） | 2064 × 2752 | `ipad-13/01-workspace.png`、`02-search.png` |

這些是原始畫面；若要加上標語與外框，建議用 Figma／Keynote 另外排版（尺寸不變）。

## App 隱私（App Store Connect「App 隱私權」問卷）

- **資料收集**：選「否，我們不會從此 App 收集資料」（Data Not Collected）。
- 理由：主機清單與設定存在本機 UserDefaults；密碼／金鑰存在本機鑰匙圈；檔案只在裝置與使用者自訂的 SSH 伺服器之間傳輸，開發者沒有任何伺服器、沒有分析或廣告 SDK。
- `PrivacyInfo.xcprivacy` 已加入（NSPrivacyTracking = false；宣告 UserDefaults CA92.1、檔案時間戳 C617.1 / 3B52.1）。

## 隱私權政策草稿（可直接放到網頁）

> **PocketCode 隱私權政策**
>
> PocketCode 不會蒐集、儲存或傳送任何個人資料給開發者。
>
> - 你輸入的主機資訊與 App 設定只儲存在你的裝置上。
> - 密碼、私鑰與密語只儲存在你裝置的 iOS 鑰匙圈中，不會離開裝置（除了在登入時以 SSH 協定送往你指定的伺服器）。
> - 你開啟、編輯、上傳或下載的檔案，只在你的裝置與你自行設定的伺服器之間傳輸。
> - App 不含廣告、分析或追蹤工具，也不使用任何第三方伺服器。
>
> 如有疑問請聯絡：⚠️（你的聯絡信箱）

## 審查備註（App Review Information）⚠️

審查人員必須能實際測試核心功能。建議：

1. **提供一台示範 SSH 主機**（雲端小主機即可），開一個受限帳號（例：`reviewer`，只有自己的家目錄、可用 git），在「審查備註」填入主機、埠號、帳號與密碼。
2. 備註內容範例：
   > PocketCode is an SSH client. To test: tap "Add SSH Host…", enter host `<demo-host>`, port `22`, username `reviewer`, password `<…>`, tap Save, then tap the host. Tap "Trust and Connect" when the fingerprint appears. Explorer, Editor, Search and Terminal tabs are at the bottom. Without a server, "On My iPhone" opens a sample project to try the editor.
3. 若不提供主機，審查很可能因「無法測試主要功能」被退件。

## 出口合規（Export Compliance）⚠️

PocketCode 使用加密（SSH：金鑰交換、AES/ChaCha20 加密、簽章），實作來自 Apple CryptoKit 與開源的 SwiftNIO SSH / Swift Crypto，沒有自創加密演算法。上傳建置時 App Store Connect 會詢問是否使用加密以及是否符合豁免條件；這屬於法律判斷，請你依 Apple 的說明（App Store Connect Help → Export compliance）與美國 EAR 規定自行決定並作答。決定後可在 `project.yml` 的 Info.plist 加入 `ITSAppUsesNonExemptEncryption`，之後每次上傳就不必重答。

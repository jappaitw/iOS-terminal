# PocketCode 本機執行與 AI Agent 可行性評估

> 狀態：Phase 0 初版（2026-11-16）。Phase 1b、Phase 2 完成後會補上實測數據。凡標「待驗證」者尚無實機證據。

## 1. 平台限制（決定一切的前提）

- **iOS 禁止 App 產生新程序**（沒有 `fork`/`exec`/`posix_spawn` 可用於任意執行檔），也不能下載並執行原生程式碼（App Review Guideline 2.5.2）。因此不可能有真正的 bash/zsh、`pip install` 原生套件、或直接執行官方 Codex CLI 的 binary。
- 可行的路徑只有：**在 App 自己的行程內**執行程式（Swift 實作、嵌入式直譯器、或以函式庫形式連結的 Rust/C 程式碼），且所有程式碼都必須在送審時就包含在 App 裡。

## 2. 本機指令：ios_system vs 自寫 Swift 直譯器

| 項目 | ios_system（a-Shell 所用） | 自寫 Swift 直譯器（採用） |
|------|---------------------------|--------------------------|
| 指令數 | 約百個真實 BSD 指令（grep、sed、awk、curl、tar…） | 先做文件要求的 15 個＋常用輔助（wc、sort…） |
| 授權 | 本體 BSD-3；每個附帶指令各自授權（BSD、MIT、curl 授權…），需逐一稽核與附註 | 全為自有程式碼 |
| 體積 | 每個指令一個 framework，合計數十 MB | 數百 KB |
| 整合成本 | 需改寫 `system()`／stdio 綁定，與 SwiftTerm 對接；要追上游版本 | 直接用 `FileManager`，與工作區沙箱整合容易 |
| App Store | a-Shell 已上架，證明可行 | 無原生程式碼載入問題 |

**結論**：Phase 1 先用自寫直譯器滿足驗收；若之後需要 `sed`/`awk`/`tar` 等再評估引入 ios_system 的子集（屆時需另做授權稽核）。

## 3. Python：官方 CPython iOS XCframework（採用）

證據：
- CPython 自 3.13 起 iOS 為官方支援平台（PEP 730）；python.org 提供預編譯的 `python-3.15.2-iOS-XCframework.tar.gz`（86,187,886 bytes，有 sigstore 簽章）。
- 官方文件（docs.python.org/3/using/ios.html）列出嵌入步驟：Embed `Python.xcframework`、Run Script 呼叫 `install_python`（把 `.so` 擴充模組轉成獨立 framework，符合 App Store「所有二進位都在 Frameworks、一個 framework 一個 binary」的規定）、設定 `PYTHONHOME`/`PYTHONPATH`、UTF-8 mode、關閉 buffered stdio 與 bytecode 寫入。
- 官方建置已套用 `app-store-compliance.patch`（移除已知會被 App Store 自動檢查誤判的程式碼）。
- 授權：PSF License（寬鬆、可閉源商用，需附授權全文）。內含的 OpenSSL（Apache-2.0）、libffi（MIT）、bzip2、xz、zlib 等也需列入授權頁——Phase 1b 會逐一列出實際包含者。

限制（文件中須如實告知使用者）：
- 只有標準函式庫（iOS 上部分模組不可用，如 `subprocess` 無法產生程序、`multiprocessing`、`curses` 等）。
- **不支援任意 `pip install`**：純 Python 套件理論上可複製進工作區使用；含原生擴充的套件（numpy 等）必須在送審前預先編譯打包，執行期不可下載。
- 一個 App 行程只有一個直譯器；腳本之間共用全域狀態的風險以「每次執行前重設 `__main__`、清除使用者模組」緩解（待驗證）。

預估體積影響：裝置用 slice ＋ 標準函式庫約 **+40–60 MB**（未壓縮，待 Phase 1b 實測）；App Store 下載大小會因壓縮較小。

## 4. 官方 Codex CLI 在 iOS 上的可行性（Phase 2 研究題目）

已知事實（待原始碼稽核確認細節）：
- `openai/codex` 主要實作為 Rust（`codex-rs`），Apache-2.0。
- CLI 依賴：子程序執行（執行 shell 指令是 Agent 的核心工具）、PTY、作業系統沙箱（macOS Seatbelt／Linux Landlock）、終端 UI、網路、OAuth 本機回呼伺服器。
- 在 iOS 上：**子程序與 PTY 不可用**、OS 沙箱機制不同、執行任意 shell 指令違反平台限制。因此「完整官方 CLI 原封不動在 iOS 執行」預期不可行；可能可行的是**編譯與網路／協定／工具描述相關的部分 crate** 為 iOS 函式庫，搭配 PocketCode 自己的工具執行器（read/write/patch/run_python）。

Phase 2 的交付會區分三者，並在 UI 與行銷文字中嚴格區分：
1. **官方 Codex CLI**：只透過 SSH 在遠端主機執行（現已可用）。
2. **改編的 Codex Core**：若能把部分 crate 編為 iOS 函式庫，屬「改編版」，不可稱為官方 CLI。
3. **PocketCode Native AI Agent**：PocketCode 自有 Agent，透過使用者自備的 API key 呼叫模型。

## 5. 認證（Phase 4）

- 不假設 ChatGPT 訂閱可授權第三方 App 使用 API。若官方認證無法在改編環境使用，提供「自備 API key」模式，金鑰存 Keychain、絕不寫入 log、不內建任何供應商金鑰。

## 6. App Store 與商業風險（需記錄，不假設通過）

| 風險 | 說明 | 等級 |
|------|------|------|
| Guideline 2.5.2（下載／執行程式碼） | 嵌入直譯器執行「使用者自己撰寫」的程式碼，前例：Pythonista、Pyto、a-Shell、Juno 均已上架。但不得下載會改變 App 功能的程式碼（例如從網路抓 Python 套件自動執行）。 | 中 |
| 4.2／描述準確性 | 必須清楚寫出：本機 Python 只有標準函式庫、非 bash、AI 需網路與自備金鑰 | 低（文案控制） |
| 出口合規 | 已有 SSH 加密議題；加入 OpenSSL 不改變性質 | 既有 |
| 授權義務 | PSF、OpenSSL Apache-2.0 NOTICE 等需附在授權頁 | 低（流程控制） |

## 7. 需要產品負責人決定的事項（目前）

- 無。Phase 1 的技術選擇（自寫指令直譯器＋官方 CPython）依上述證據決定；三項下載已於 2026-11-16 取得同意。

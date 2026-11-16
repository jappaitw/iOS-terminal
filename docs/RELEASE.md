# 真機測試與 TestFlight 發佈步驟（PLAN 3.4）

這一步需要你的 Apple Developer 帳號與實體 iPhone，無法在模擬器代勞。以下是照做就能完成的清單。

## 0. 前置

- 已加入 Apple Developer Program（年費）。
- Xcode 已用該 Apple ID 登入：Xcode → Settings → Accounts。
- 在 [developer.apple.com](https://developer.apple.com/account) 查到你的 **Team ID**（10 碼英數）。

## 1. 設定簽章

把 Team ID 填進 `project.yml`，然後重新產生專案：

```yaml
settings:
  base:
    DEVELOPMENT_TEAM: "ABCDE12345"   # ← 你的 Team ID
    CODE_SIGN_STYLE: Automatic
```

```bash
xcodegen generate
```

自動簽章會在第一次建置時建立 App ID `com.jlmxstudio.pocketcode` 與開發用描述檔。若此 Bundle ID 已被別人註冊，改成你自己的反向網域（同時改 `PRODUCT_BUNDLE_IDENTIFIER`）。

## 2. 實機跑起來

1. iPhone 用線接上 Mac（或同網路配對），iPhone 上開啟 **設定 → 隱私權與安全性 → 開發者模式**。
2. `open PocketCode.xcodeproj`，上方裝置選你的 iPhone，按 ▶︎ Run。
3. 驗收清單（PLAN 3.4「實體 iPhone 跑通三大功能」）：
   - [ ] 新增主機 → 首次連線出現指紋確認 → 信任後進入 Explorer
   - [ ] Explorer 瀏覽、開檔、編輯、存檔；Git 標記與分支顯示正確
   - [ ] 搜尋跳行
   - [ ] 終端機輸入、快速打字不亂序、vim / htop 正常、鍵列可用
   - [ ] 鎖屏 1 分鐘後回來：自動重連（狀態列短暫顯示 Reconnecting…）
   - [ ] 上傳（從「檔案」選檔）、下載（分享單 → 儲存到檔案）
   - [ ] 實體鍵盤（若有）：按住 ⌘ 出現快捷鍵清單；⌘S、⌘⇧F、⌃` 正常
   - [ ] 真實 Wi‑Fi／行動網路下切換網路後的重連行為

## 3. 上傳 TestFlight

1. Xcode 上方裝置選 **Any iOS Device (arm64)**。
2. **Product → Archive**，完成後 Organizer 會打開。
3. 選剛才的 archive → **Distribute App → App Store Connect → Upload**（保持自動簽章）。
4. 到 [App Store Connect](https://appstoreconnect.apple.com)：
   - 第一次需要先 **新增 App**（名稱、主要語言、Bundle ID、SKU）。
   - 建置處理完成（約 10–30 分鐘）後，回答 **出口合規** 問題（見 `docs/appstore/AppStore.md`）。
   - **TestFlight → 內部測試**：加入自己與團隊成員的 Apple ID，即可在 TestFlight App 安裝。
   - 外部測試需要先通過 Beta App Review。

每次重新上傳前，把 `project.yml` 的 `CURRENT_PROJECT_VERSION` 加 1（版本號 `MARKETING_VERSION` 只有發新版時才改），再 `xcodegen generate`。

## 4. 送審前最後確認

- [ ] 截圖、描述、關鍵字、隱私權政策網址、支援網址都已填（`docs/appstore/AppStore.md`）
- [ ] 審查用示範主機可連、帳密已寫入審查備註
- [ ] App 隱私問卷：Data Not Collected
- [ ] 開源授權頁內容與實際相依套件一致（升級套件後跑 `python3 scripts/gen_acknowledgements.py`）
- [ ] Tree-sitter 文法授權：確認 `scripts/gen_acknowledgements.py` 裡 `GRAMMARS` 的每個上游 repo 仍為 MIT，必要時補上各自的著作權人

## 附錄：SSH 連接埠轉送整合測試

`PocketCodeTests/PortForwardIntegrationTests` 平常會自動略過；要實測 `LocalPortForward`，先在本機起一個只聽 127.0.0.1 的 sshd（金鑰登入、`AllowTcpForwarding yes`）和一個 HTTP 伺服器（回應內容含 `PORT_FORWARD_OK`），再執行：

```bash
TEST_RUNNER_PC_SSH_KEY=<私鑰路徑> TEST_RUNNER_PC_SSH_USER=$(whoami) TEST_RUNNER_PC_SSH_PORT=2222 TEST_RUNNER_PC_HTTP_PORT=18455 xcodebuild test -project PocketCode.xcodeproj -scheme PocketCode -destination 'id=<模擬器 UDID>' -clonedSourcePackagesDirPath .spm -derivedDataPath .build CODE_SIGN_IDENTITY="-" -only-testing:PocketCodeTests/PortForwardIntegrationTests
```

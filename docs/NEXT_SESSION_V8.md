# 下個 Session 主線:V8 從源碼編譯(iOS)— 解鎖 gpt-6 旗艦

## 為什麼

雲端 Codex / gpt-6 是主流、旗艦後端,其工具呼叫走 **code-mode(V8 編排 JS)**。V8 在 iOS 卡在 snapshot `magic_number mismatch`。**已診斷確定**(見 `ON_DEVICE_AI_CLI_FEASIBILITY.md`):問題是 denoland iOS 預編庫 vs rusty_v8 crate 配置不符,**不是 codex 用法**(隔離 smoketest `pc_v8_smoketest` 在零 codex 下仍 crash)。

## 正解:V8_FROM_SOURCE=1

rusty_v8 官方文件:iOS 必須自編。自編後 snapshot 由我們控制,magic 必然一致。

### 步驟(下個 session 從這裡開始)

1. **工具鏈**:安裝 depot_tools(`git clone https://chromium.googlesource.com/chromium/tools/depot_tools`,加 PATH)、ninja、gn。確認 `LIBCLANG_PATH`。
2. **編譯 rusty_v8 from source**(先 simulator,較快驗證):
   ```
   cd native/pocket-codex
   V8_FROM_SOURCE=1 cargo build --release --target aarch64-apple-ios-sim -vv
   ```
   device 版:`--target aarch64-apple-ios`(**jitless**,V8JitMode::Disabled)。
3. **預期**:首次下載 V8 源碼(數 GB)+ 編譯數小時。可能要調 GN args(iOS 相關 flags 見 rusty_v8 build.rs 的 `target_os="ios"` 分支)。
4. **驗證**:重跑 `V8SmokeTests`(`pc_v8_smoketest`)→ 期待 rc=0(不再 magic mismatch)。
5. 通過後:重跑 CodexE2ETests(雲端 gpt,TEST_RUNNER_POCODE_E2E=1 + 真 key)→ 工具呼叫應該動了 → `POCODE_OK`。
6. **device jitless 注意**:iOS 裝置禁 JIT,V8 必須 jitless 建 + `--jitless` 執行;模擬器可非 jitless。兩 slice 設定不同。

### 風險 / 備案

- V8 源碼編譯環境繁瑣(depot_tools、python、ninja 版本)。若卡住,備案:找有人預編好的 iOS rusty_v8 archive(`RUSTY_V8_ARCHIVE` 指定),或 l-shell-ios 等專案的 V8 iOS 產物。
- 編好的 `libv8` 要併進 `scripts/build_codex.sh` 的流程(取代 denoland 預抓的那份)。

## 已就緒的資產

- `pc_v8_smoketest`(隔離測試,一行判定 V8 是否活)
- `V8SmokeTests.swift`
- code-mode host 接線(`pocket-codex` in-process gRPC)已完成,只等 V8 能跑
- 三引擎連結成功(CPython + Codex + llama.cpp),V8 補上即全通

## 這條線完成 = gpt-6 旗艦的工具迴圈打通,與本機模型(已運作)並列。

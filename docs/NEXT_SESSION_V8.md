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

### 2026-11-18 進度與踩到的牆(重要)

depot_tools 已裝(`~/depot_tools`,gn/ninja 就緒)。`V8_FROM_SOURCE=1 cargo build -p v8 --target aarch64-apple-ios-sim` 會自動下載 V8 源碼 + Chromium clang + rust-toolchain(不需手動 gclient)。踩到兩道牆:

1. **缺 `third_party/icu/ios/icudtl.dat`** → 已解:從 `third_party/icu/flutter_desktop/icudtl.dat` 複製到 `ios/`(1.7MB)。
2. **缺 vendored Rust ICU crates**(`third_party/rust/chromium_crates_io/vendor/icu_calendar_data-v2/` 等,整個 vendor 目錄是空的)→ **未解**。根因:**crates.io 發佈的 v8 套件是精簡版,不含 i18n host 工具鏈需要的 vendored Rust crates**。BUILD.gn 引用它們但源碼不在。

**正確解法(下次從這裡開始):** 不要用 crates.io 的精簡 v8 套件,改用**完整的 chromium gclient checkout**:
```
# 用 depot_tools 取完整 V8 源碼樹(含所有 vendored crates)
fetch v8   # 或 gclient config + gclient sync,約 20GB
# 然後讓 rusty_v8 指向它,或在該樹內建 lib
```
或:手動 vendor 缺的 Rust ICU crates(icu_calendar_data-v2 等)到 `chromium_crates_io/vendor/`(`cargo vendor` 或從 chromium 源取)。
或(備案,**已試,發現死路**):修預編庫的 magic mismatch。調查結果:
- `nm` denoland iOS `release` lib → **有 sandbox 符號**(`IsSandboxEnabled`、`SandboxableThread`、`src/sandbox/*`)→ lib 是 **sandbox + pointer compression** 編的。
- 但 denoland **只發 `release`(非 sandbox)命名的 binding** for iOS,不發 `ptrcomp_sandbox_release` binding。
- 試:啟用 `v8_enable_sandbox` feature + 把 `release` 的 binding/lib 別名成 `ptrcomp_sandbox_release` 快取檔 → 編譯連結成功,但 smoketest **仍 magic mismatch**,且預編庫報 `Embedder-vs-V8 build configuration mismatch`。
- **結論:denoland iOS 預編包的 binding(非 sandbox 佈局)與 lib(sandbox 編)本身不一致,無法靠 feature 對齊**。→ 備案死路,**必須走 full-source build**。

**所以下次唯一正解 = full chromium gclient V8 checkout**(見下),把缺的 vendored Rust ICU crates 一起帶進來。crates.io 精簡包不夠。

### 風險 / 備案

- V8 源碼編譯環境繁瑣(depot_tools、python、ninja 版本)。若卡住,備案:找有人預編好的 iOS rusty_v8 archive(`RUSTY_V8_ARCHIVE` 指定),或 l-shell-ios 等專案的 V8 iOS 產物。
- 編好的 `libv8` 要併進 `scripts/build_codex.sh` 的流程(取代 denoland 預抓的那份)。

## 已就緒的資產

- `pc_v8_smoketest`(隔離測試,一行判定 V8 是否活)
- `V8SmokeTests.swift`
- code-mode host 接線(`pocket-codex` in-process gRPC)已完成,只等 V8 能跑
- 三引擎連結成功(CPython + Codex + llama.cpp),V8 補上即全通

## 這條線完成 = gpt-6 旗艦的工具迴圈打通,與本機模型(已運作)並列。

---

## 2026-11-18 夜 — 重大突破:依賴迷宮全通,卡點前移到 Rust std 工具鏈

**推翻了「必須 20GB full chromium」的舊結論。** 實際只需 **V8 standalone gclient checkout**(~4.3GB),關鍵是**版本要對齊**。

### 打通的關卡鏈(依序)
1. crates.io 的 rusty_v8 **精簡包把整個 `third_party/rust/chromium_crates_io/` 子樹拔掉** → 從 gclient v8 樹複製回來。
2. ICU4X data crate 在 chromium 樹裡是 **`is_placeholder = true` 空殼**(chromium 自己產 ICU 資料)→ 用 cargo registry 的真 crate 覆蓋(`scripts/v8_populate_icu.sh`,動態讀每個 placeholder 的 name@version 去抓)。
3. 缺 `third_party/icu/common/icudtl.dat` → 從 gclient 樹複製(10.7MB)。
4. **版本不符(最關鍵):** 一開始 `fetch v8` 抓到 HEAD(V8 16.0,diplomat 0.16),但 rusty_v8 **152.2.0 綁的是 V8 15.2.124.1**(diplomat 0.15)。vendor 樹的 diplomat/ICU 版本必須和 crate 的 BUILD.gn 完全吻合。
   → `cd ~/v8src/v8 && git fetch --depth 1 origin refs/tags/15.2.124.1 && git checkout 15.2.124.1 && (cd ~/v8src && gclient sync --no-history -D -R)`。

### 做完 1–4 後,build 一路過 gen + 開始編 C++(2194 步),現卡在:
```
error: multiple input filenames provided
  (first two: .../rust-toolchain/.../library/core/src/lib.rs
   and .../build/clang/lib/clang/23/lib/darwin/libclang_rt.osx.a)
ERROR: rustc exited with non-zero
```
**成因:** ios-sim 非 rusty_v8 官方支援 target → 它從源碼現編 Rust std(core/profiler_builtins),而該 GN 模板把 clang compiler-rt 的 `.a` 誤當成 rustc 位置參數。也混進了 `libclang_rt.osx.a`(macOS)到 sim 編譯。

### 下一步(從這裡開始)
- **先試 device target `aarch64-apple-ios`**(我們真正出貨的 slice,sim 只驗證用)—— 可能走不同、可用的 std 路徑。
- 若 device 同樣卡:研究 GN arg 讓 rust 用 host prebuilt std 而非現編,或修 rustc 呼叫模板(把 `.a` 改成 `-Clink-arg`/`-L`)。V8 15.2 的 ICU4X 綁定需要 rust,無法整個關掉。
- 可重現腳本:`scripts/v8_populate_icu.sh`(含複製對齊樹 + 填 ICU + icudtl + 重編)。前提:`~/v8src/v8` 已 checkout 到 15.2.124.1。

**狀態:從「死路」變成「一個明確的工具鏈 arg bug」。** 本機模型 + Claude 後端(build 9)都不需 V8,已出貨。

### 2026-11-18 夜(續)— device target 確認:同一個 Rust-std 工具鏈 bug
`aarch64-apple-ios`(device,真正出貨 slice)跑出**完全相同**的錯,只是 `libclang_rt.ios.a` 取代 `.iossim.a`。→ **target 無關**,是 GN rust-std-from-source 對非官方 Apple target 的模板問題:本該是 final-link 的 compiler-rt `ldflags` 洩漏進 std rlib 的 rustc 編譯命令,rustc 把 `.a` 當成位置輸入源碼 → `multiple input filenames provided`。

**最可能的解法(下次優先試,依序):**
1. **別從源碼編 std**:下載的 rust-toolchain 沒有 apple target 的 prebuilt std 才會現編。用我們 rustup 已裝的 `aarch64-apple-ios` std(`build_codex.sh` 已 `rustup target add`),透過 GN arg 指向該 sysroot,讓 GN 跳過 std-from-source。查 chromium GN:`rust_sysroot_absolute` / `rustc_version` / `added_rust_targets` 附近。
2. 若無法跳過:修 rust 編譯模板,把 compiler-rt 從 std rlib 的 rustc 命令移除(它屬於 final link,不該進 rlib 編譯)。在 gn_out 的 `toolchain.ninja` / rust templates 找 `libclang_rt` 的注入點。
3. 備案:試不同 rusty_v8 patch 版(152.x)是否已修 iOS,但要顧及與 codex 的相容。

**距離終點:** 依賴全通,只差這個工具鏈 arg。真正的 V8 C++ 原始碼已開始編(2194 步),std 一過就能連結出 `librusty_v8.a`。

### 2026-11-18 深夜 — 兩個精準根因:空格 bug(已解)→ lld/SDK 版本落差
**(A) Rust-std 的「multiple input filenames」真因 = 專案路徑有空格。**
`core.rsp` 裡 `-Clink-arg=/Users/soulfyai/Documents/iphone vscode/.../libclang_rt.osx.a` 的路徑在 `iphone vscode` 的空格處被拆成兩段,後半成了裸參數,rustc 當成輸入源碼。
**解法(已驗證有效):** 把 cargo 輸出目錄設到無空格路徑 —— `CARGO_TARGET_DIR=$HOME/pcv8target`。設了之後 std 錯誤歸零,build 從 step 14 一路推進到 **step 101/3960**。
→ **出貨腳本要確保 `native/pocket-codex` 建置在無空格路徑**(專案在 `Documents/iphone vscode/` 本身有空格)。

**(B) 下一個牆:host 工具連結失敗 = Chromium 綁的 lld 太舊,讀不懂 macOS 27.2 SDK 的 .tbd。**
```
ld64.lld: error: could not load TAPI file .../MacOSX27.2.sdk/usr/lib/libSystem.tbd: malformed file
  libSystem.tbd:4:20: error: unknown target
→ undefined symbol: opendir / strlen / pthread_* / _Unwind_* …
```
本機 macOS 27.2(Darwin 27.2)是極新 SDK,rusty_v8 152.2.0 綁的 clang/23 lld 的 TAPI parser 不認得其 tbd 的 target 格式。host build tools(arm64-apple-macos)連結不到 libSystem。
**下次試法(依序):**
1. GN arg 讓 host 工具鏈用**系統 Xcode 的 ld**(能讀自家 SDK)而非 downloaded lld;但要連帶處理 lld 專屬 flag(`-Wl,--icf=all`、`--strict-auto-link`、`--read-workers` 等)。
2. 或讓 rusty_v8 下載**較新的 Chromium clang**(認得 27.2 SDK),但要顧 V8 15.2 相容。
3. 或指向**較舊的 macOS SDK**(若機器上有)給 host 工具。
4. 終極:在**較舊 macOS 的 CI/機器**上編(toolchain 與 SDK 匹配),產出 `librusty_v8.a` 後以 `RUSTY_V8_ARCHIVE` 餵給 pocket-codex。

**進度本質:** 依賴迷宮 + Rust-std 全通,只差 host 工具鏈與超新 SDK 的版本匹配。離 `librusty_v8.a` 很近了。

### 2026-11-19 — ✅ V8 FROM SOURCE 編成功(iOS device)!
最後一塊拼圖:**Chromium 綁的 lld 太舊 → 換 homebrew modern lld(LLVM 23.1.6)**。CLI 相容、能讀 macOS 27.2 SDK 的 .tbd。
```
brew install lld
# 把 $CARGO_TARGET_DIR/<target>/release/build/clang/bin/{ld64.lld,ld.lld,lld,lld-link}
# 全部 symlink 到 /opt/homebrew/opt/lld/bin/lld
```
**結果:** `cargo build -p v8 --release --target aarch64-apple-ios` → step [3875/3875] exit 0 → `librusty_v8.a` 57MB。
接著 `cargo build --release --target aarch64-apple-ios`(完整 pocket-codex)→ exit 0 → **`libpocket_codex.a` 606MB,含 from-source V8**。

### 完整可重現配方(scripts/v8_populate_icu.sh 已編碼)
1. gclient V8 checkout **pin 到 15.2.124.1**(= rusty_v8 152.2.0 綁的版本):`~/v8src/v8`。
2. 複製其 `third_party/rust/chromium_crates_io` 進 crate;用 cargo registry 真 crate 填掉 `is_placeholder` 的 ICU/diplomat crate;複製 `icudtl.dat`。
3. **`CARGO_TARGET_DIR` 設無空格路徑**(repo 路徑 `iphone vscode` 有空格會破壞 rustc -Clink-arg 轉義)。
4. **換 modern lld**(macOS 27.x SDK 需要)。
5. `V8_FROM_SOURCE=1 cargo build -p v8 --target <t>` 然後完整 build。

### 剩下
- [ ] sim slice 同法編(smoketest 在模擬器跑)
- [ ] 跑 `pc_v8_smoketest` / V8SmokeTests → 確認 magic_number 過(from-source 理論上必過,binding+lib 自洽)
- [ ] 把 libpocket_codex.a 併進 ThirdParty/codex/{device,simulator},出含 code-mode 的 build
- [ ] device 是 jitless:確認 V8JitMode::Disabled + `--jitless`(rusty_v8 target_os=ios 分支應已處理)

### 2026-11-19 — smoketest 判定:編得出來,但 runtime snapshot magic 不符(jitless)
把 from-source sim 庫換進 ThirdParty 跑 `pc_v8_smoketest`(已確認有重連新庫,非快取):
```
# Fatal error: Check failed: magic_number_ == SerializedData::kMagicNumber.
```
**和預編庫同一個錯** → 問題不是「庫內部不一致」,而是 **V8 snapshot 的 jitless 交叉編譯設定**。
target args.gn:`v8_jitless=true`、`v8_enable_turbofan/sparkplug/maglev=false`、`v8_enable_webassembly=false`、sandbox/ptrcomp=false。
**診斷:** startup snapshot 由 host mksnapshot 產生;若 host mksnapshot 用非 jitless(含 turbofan/wasm)設定,其外部參考表大小 ≠ jitless target 的 → `kMagicNumber` 不符 → `Isolate::new` 反序列化 abort。這也解釋為何預編庫(非 jitless snapshot)在 jitless-ish 載入時同樣 magic 不符。

**修法候選(依序):**
1. **驗證中:** sim 不禁 JIT → 把 sim 建成**非 jitless**(turbofan/wasm 開)使之與 host mksnapshot 一致 → smoketest 應過,證明 from-source V8 本體健全。
2. **device 真解:** 讓 `v8_snapshot_toolchain` 的 host mksnapshot 以**和 target 相同的 jitless flags** 建置並產生 snapshot。rusty_v8 的 iOS 分支沒正確接這條,是下個深入點。
3. **備案:** 無 snapshot 建置(Isolate 從零初始化,免反序列化、免 magic 檢查;啟動較慢但 jitless 可行)。
4. 若 device snapshot-toolchain 太難:sim(開發/驗證)用非 jitless 跑通 code-mode,device 等 toolchain 修好。

**本質進度:** V8 從源碼**編得出 iOS device + sim 庫**(死路已破);剩 runtime 的 jitless-snapshot 對齊。

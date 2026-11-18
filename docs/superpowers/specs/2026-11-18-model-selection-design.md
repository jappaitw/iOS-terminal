# 模型選擇設計(Pocode — 模型中立平台)

日期:2026-11-18。狀態:策略定案,設計待實作。

## 核心定位

**Codex(OpenAI gpt)是內建基本盤;用戶可自選切換 AI 後端。** 不綁定單一供應商 —— 這是核心賣點,也同時繞過 OpenAI 帳號限制與 iOS V8 code-mode 困局。

## 三種後端

| 後端 | 怎麼接 | 碰 V8? | 狀態 |
|---|---|---|---|
| Codex / gpt-6(訂閱) | 內建引擎,ChatGPT OAuth | ⚠️ 是(code-mode) | 登入/對話已通,工具待 V8 |
| 本機模型(Qwen 等) | 嵌 llama.cpp,codex model_provider 指向本機 OpenAI 相容端點 | ❌ 否 | 待做 PoC |
| 雲端相容端點(DeepSeek/Claude/Gemini…) | API key + base_url,OpenAI 相容 | ❌ 否 | 協定已支援(modelProvider/config/write) |

關鍵洞察:**本機與相容端點兩條路都走 classic chat/completions,不經 code-mode** → 它們天然避開了今天卡住訂閱 gpt-6 的 V8 snapshot 問題。

## 設定頁:AI Model

```
Settings → AI Model
┌─ Active: [ Codex (GPT) ▾ ]              ← 目前使用的後端
├─ Codex (built-in)          Signed in ✓   預設,ChatGPT 或 API key 登入
├─ Local model                             下載選一個 GGUF:
│    • Qwen2.5-Coder 0.5B   (~0.4 GB)       離線 · 免費 · 隱私
│    • Qwen2.5-Coder 1.5B   (~1 GB)
│    • Qwen3 4B             (~2.5 GB)       12GB 機型建議
│    [ Download ] / [ Active ]
└─ Custom endpoint           + Add         名稱 / Base URL / API key(Keychain)
                                           DeepSeek、Claude 相容、Gemini、自架…
```

## 架構

```
用戶選的後端
   │
   ├─ Codex gpt         → 內建 pocket-codex 引擎(現有)
   ├─ 本機模型           → llama.cpp server(in-process, /v1/chat/completions on 127.0.0.1)
   │                       └ codex model_provider → http://127.0.0.1:PORT/v1
   └─ 自訂雲端端點        → codex model_provider → <base_url>,key 走 bearer(Keychain)
```

codex 引擎的 `[model_providers.*]` + `thread/start { model, modelProvider }` 已支援多 provider;切換後端 = 寫 config + 新 thread 用對應 provider。

## 元件

1. **llama.cpp 嵌入**(`scripts/build_llama.sh` + `ThirdParty/llama/`,同 CPython/V8 模式):CMake 交叉編譯 Metal 版 device+sim 靜態庫;`pocket-llama` FFI 起 in-process server(或直接呼叫 llama API 提供 chat/completions)。
2. **模型下載管理**(`ModelStore.swift`):GGUF 從 HuggingFace 下載到 Documents(可見於檔案 App),顯示大小/進度/刪除;依機型 RAM 建議尺寸(8GB→≤1.7B 建議、12GB→≤4B)。
3. **後端切換**(`ModelBackend.swift` + 設定頁):寫 codex config 的 model_provider,active backend 存 UserDefaults;終端機 `codex` 與 GUI 共用。
4. **自訂端點**:名稱 / base_url / key(Keychain),寫入 `[model_providers.<name>]`。

## 候選本機 coding 模型

Qwen2.5-Coder(Apache-2.0,首選)、DeepSeek-Coder-V2-Lite(MIT)、CodeGemma/Gemma3(省記憶體)、Phi-4-mini(MIT)、SmolLM3(極小備援)。

## 里程碑

1. llama.cpp iOS 建置 + `pocket-llama` in-process server + 單一內建小模型(Qwen2.5-Coder 0.5B)PoC → codex 接本機端點跑一輪
2. 模型下載管理 GUI + 多尺寸 + RAM 建議
3. 自訂雲端端點(DeepSeek 等)+ Keychain key
4. 設定頁後端切換整合 + 終端機 `codex` 尊重選擇
5. 記憶體/發燙/速度實機調校(背景卸載、context 上限)

## 風險

- 本機 coding 品質有硬天花板(≤4B);UI 要誠實標示「本機=輕量/離線,複雜任務建議雲端」。
- 記憶體:iOS app 可用約物理 RAM 半數;超量 jetsam。載入前檢查可用記憶體。
- 授權:各模型授權不同(Qwen/Phi/SmolLM Apache/MIT 乾淨;Gemma 有條款)— 內建前逐一確認。

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

## 多模型平台(不限 Qwen)

嵌入的是 **llama.cpp 引擎本身**,非綁定單一模型 → 支援整個 GGUF 生態。Qwen 只是第一個驗證管線的樣本與首批推薦之一。

| 家族 | coding | 授權 | tool-call |
|---|---|---|---|
| Qwen 2.5 / 3 | 強 | Apache-2.0 | **Instruct ✅ / Coder ✗** |
| DeepSeek-Coder / R1-Distill | 很強 | MIT | 待測 |
| Llama 3.2 (1B/3B) | 中 | Llama 授權 | 待測 |
| Gemma 3 / CodeGemma | 中 | Gemma 授權 | 待測 |
| Phi-4-mini | 中 | MIT | 待測 |
| SmolLM3 | 弱(極小) | Apache-2.0 | 有限 |
| 用戶自訂 GGUF | — | — | 看模型 |

### Tool-calling 實測結果(2026-11-18,模擬器探針)

| 模型 | template | 結果 | 入選 |
|---|---|---|---|
| Qwen2.5-Instruct 1.5B/3B | qwen2.5 | ✅ 結構化 function_call | ✅ |
| Llama 3.2 3B Instruct | llama3 | ✅ 結構化 function_call | ✅ |
| DeepSeek-R1-Distill-Qwen 1.5B | deepseek-r1 | ❌ 自創 `<｜tool｜…｜>` 格式、幻想路徑(推理蒸餾版) | ✗ |
| Phi-4-mini-instruct | 內嵌 | ❌ 純文字(內嵌 template 無工具段) | ✗(待專屬 template 調校) |

精選清單首批:Qwen2.5-Instruct(1.5B/3B)+ Llama 3.2 3B。bundled templates:`qwen2.5.jinja`、`llama3.jinja`、`deepseek-r1.jinja`。

**精選清單選模標準 = tool-calling 實測可靠 + 授權乾淨 + 配好 chat template**,非名氣。每個模型家族工具格式不同,需逐一實測並備好對應 template(`PocketCode/Resources/llama-templates/`)。自訂下載的模型放「進階」,標示「工具呼叫可能不穩」。

## 決策:模型一律按需下載,不預裝(2026-11-18)

**app 內建的只有 llama.cpp 引擎(數十 MB);本機模型一律由用戶自選下載。** 理由:預裝 1–2GB 模型會讓 App Store 下載巨大(傷轉換、觸發 WiFi-only 限制)、綁死單一模型、懲罰不用本機的用戶。不下載任何模型也完全可用(走 Codex 雲端 / API key)。

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

## 關鍵發現(2026-11-18):codex 只講 Responses API

codex 引擎已移除 Chat API,**只收 `/v1/responses`**(連 Ollama 整合都 `ensure_responses_supported`)。但實際世界(DeepSeek、Claude、llama.cpp server、多數 Ollama)都講 `/v1/chat/completions`。因此「貼 key 就能用」不成立,中間必須一層格式轉換。

**解法:一個 in-process「Responses ↔ Chat 轉接器」,一次解鎖本機 + 所有相容雲端。**

```
codex ─Responses→ ★ Pocode 轉接器 ★ ─Chat→ ┬ 本機 llama.cpp
                  (loopback, 雙向翻譯)       ├ DeepSeek / Claude / Gemini(key)
                                            └ 任何 Chat API 服務
```

兩端皆由我們掌控,欄位對應公開已知 → 確定性工程,非未知風險。V8/code-mode 不影響此路(走 classic responses,無需 JS 編排)。

## 轉接器不需要了(2026-11-18 查證)

**llama.cpp server 已原生支援 `/v1/responses`,commit 標題明寫 "Codex CLI compatibility"**(PR #19720、#21174)。Ollama / LM Studio / vLLM 亦然。→ **codex 直接接 llama.cpp 的 responses 端點,零翻譯層。** 自寫 Responses↔Chat 轉接器取消。

雲端相容端點(DeepSeek 等)若只講 Chat 而不講 Responses,屆時才需要輕量轉接(或找講 Responses 的供應商);但本機路線已無此需求。

## ✅ 本機 AI AGENT 在 iPhone 上運作(2026-11-18 晚)

**Qwen2.5-Instruct（非 coder）在模擬器上完整驅動 codex 工具迴圈** —— 結構化 function_call、連續多次工具呼叫、看到錯誤後自我修正重試。完全離線、零帳號、零雲端(模型推論全在機內)。

決定性證據(rollout):
- 探針:`{"type":"function_call","name":"write_file",...}` ← 真·結構化工具呼叫(非文字)
- codex 完整輪:`exec_command`(格式正確)、`write_stdin`、`function_call_output`、自我修正重試

**選模原則確立**:Qwen2.5-**Instruct** 能可靠 tool-call;Qwen2.5-**Coder** 不行(coder 版為補全調校,把工具 JSON 包成 ```json 不加標籤)→ 精選清單用 Instruct/Qwen3,coder 版僅供純補全。

**唯一未竟**:3B 模型在此任務「策略笨拙」—— 第一個 `exec_command` 格式正確,但接著改用 `write_stdin` 配一個幻想的 64-bit session_id(codex schema 宣告 i32 → 溢位解析失敗),反覆重試未收斂。這是 **3B 模型能力問題,非架構 bug**;4B/Qwen3 或雲端模型會直接用 exec_command 完成。產品預設本機模型建議 ≥4B(12GB 機型)或選 Qwen3;8GB 機型本機適合簡單任務,複雜任務導向雲端。

**結論:完全離線的 iPhone AI agent 已實證運作。** 三引擎(CPython + Codex + llama.cpp)同程序共存、本機模型驅動工具執行到 LocalShell/Python,全部跑通。剩餘是模型選型與能力分級的產品工作,不是技術可行性問題。

---

## (舊)本機 E2E 進度 — 全鏈路通,僅剩工具解析一行級缺口

模擬器實測(Qwen2.5-Coder 0.5B/1.5B/3B，皆 Q4）：

- ✅ **llama.cpp server 在 app 內啟動、載入 GGUF、`/v1/responses` 健康**。
- ✅ **codex 引擎接受本機 provider**(`[model_providers.pocodelocal]`, wire_api=responses），`thread/start` 成功，整輪在 `127.0.0.1` 完成，**零雲端、零帳號**。
- ✅ 速度亮眼:3B 在模擬器 prompt 380 tok/s。
- ✅ **模型產生了正確的工具呼叫意圖**:直接探針(responses 與 chat 兩路)都回 `{"name":"write_file","arguments":{"path":"hello.py","content":"print(\"POCODE_OK\")"}}`。
- ❌ **唯一缺口**:該 JSON 包在 `content` 文字裡,未被解析成結構化 `tool_calls` → codex 收到「純文字回覆」,不執行工具。根因:`--jinja` 的通用模板沒認出 Qwen2.5-Coder 的工具輸出格式(模型吐 ```json 而非 `<tool_call>` 標籤)。

**這不是架構問題,是 llama.cpp 的 tool-parser / 模型指令遵循問題。** 已嘗試:注入 llama.cpp 內建的 Qwen2.5-7B-Instruct tool-aware template(`--chat-template-file`,含 9 處 `<tool_call>` 標籤,打包進 `PocketCode/Resources/llama-templates/qwen2.5.jinja`)。結果:template 有載入,但 **3B coder 模型仍把工具 JSON 包成 ```json 區塊、不加 `<tool_call>` 標籤** → llama 解析器偵測不到 → 歸為純文字。根因是 Qwen2.5-**Coder** 的指令遵循弱(coder 版為補全調校)。

修法候選(下一輪,由穩到實驗):
1. **薄抽取層(最穩,我們掌控)**:patch server-chat 或 pocket-llama 回應路徑,偵測 content 裡的工具 JSON(`{"name":...,"arguments":...}`)→ 轉成結構化 tool_calls / responses function_call。模型一致地吐這個格式(0.5B/1.5B/3B 皆然),抽取規則確定。
2. **grammar 約束**:llama.cpp 支援 `tool_choice:required` + grammar 強制 `<tool_call>` 輸出。
3. **換模型**:Qwen3 或 Qwen2.5-**Instruct**(非 coder)原生 tool-calling 較強。精選清單應以「tool-calling 可靠」為選模標準,coder 版留給純補全。

結論:**完全離線的 iPhone AI agent 架構已證實可行**(模型在機內、工具在機內、無網路依賴),剩下是 llama.cpp 工具格式對齊的調校。

## 進度(2026-11-18)

- ✅ llama.cpp iOS + Metal 編譯(device + simulator),`scripts/build_llama.sh` → `ThirdParty/llama/`
- ✅ 上游 server 已函式庫化:`llama-server-impl` 匯出 `llama_server(argc, argv)`(註解明寫 "reusable by app"),`/v1/responses` 路由含在內
- ✅ `native/pocket-llama/`:`pll_start(model_path, port, ctx)` 於執行緒以假 argv 啟動完整 server
- ⬜ 下一步:app target 連結 + 模型下載(Qwen2.5-Coder GGUF)+ codex `[model_providers.local]` 接線 + E2E

## 執行順序(修正後 — 直線,無轉接器)

1. **本機 llama.cpp PoC** — 嵌 llama.cpp(含 `/v1/responses` + Metal),in-process server,codex base_url 指向它,Qwen2.5-Coder 直接驅動工具。llama.cpp 嵌 iOS 為成熟技術。
2. 模型下載管理 GUI + 多尺寸 + RAM 建議。
3. 雲端相容端點(視供應商 Responses 支援度,必要時加輕量轉接)。
4. **回來解 V8 code-mode**(Codex/gpt-6 旗艦,必須)。

架構(無轉接器):
```
Pocode 嵌 llama.cpp(/v1/responses, Metal) → in-process 127.0.0.1:PORT
   → codex [model_providers.local] base_url=http://127.0.0.1:PORT/v1, wire_api=responses
   → Qwen 驅動工具 → host-exec → LocalShell → 內嵌 Python
```

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

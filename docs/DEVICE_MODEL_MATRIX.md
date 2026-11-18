# 機型 × 本機模型對照表(Pocode)

用途:app 內給用戶的選型指引 + 行銷素材。本表只談**本機模型**(離線跑);雲端後端(Codex / API key / 相容端點)不受手機硬體限制,任何機型品質一致。

## 前提:iOS 的記憶體天花板

iOS 不讓單一 app 用滿實體 RAM —— 超過約 **一半** 就被系統(jetsam)終止。所以模型 + context 的實際可用空間,是下表的「App 可用」欄,不是總 RAM。

## 機型規格與可用模型

| 機型 | 晶片 | RAM | App 可用~ | 建議本機模型(4-bit) | 速度~ |
|---|---|---|---|---|---|
| iPhone 16 / 16 Plus | A18 | 8GB | ~3.5GB | Qwen2.5-Coder 0.5B–1.5B | 20–35 tok/s |
| iPhone 16 Pro / Pro Max | A18 Pro | 8GB | ~3.5GB | Qwen2.5-Coder 1.5B;4B 吃緊 | 25–40 |
| iPhone 17 | A19 | 8GB | ~3.5GB | Qwen2.5-Coder 1.5B | 25–40 |
| iPhone Air | A19 Pro | 12GB | ~6GB | Qwen3 4B 順 | 40–55 |
| iPhone 17 Pro / Pro Max | A19 Pro | 12GB | ~6GB | **Qwen3 4B 順;7–8B 勉強** | 45–60 |
| iPhone 18 Pro / Pro Max | A20 Pro(2nm) | 12GB | ~6GB | **Qwen3 4B 流暢;7–8B 可試** | 50–65 |
| iPhone Duo(折疊) | A20 Pro(2nm,+50% 記憶體頻寬) | 12GB | ~6GB | **Qwen3 4B 流暢;7–8B 可試** | 50–70 |

> 註:8GB 機型(16/16Pro/17)本機只適合輕量 agent 與補全;**12GB 機型(Air/17Pro/18Pro/Duo)才是本機 coding 甜蜜點**。舊機型(15 及以前)可跑 0.5B 聊天級,但不建議當 coding agent。

## 能力分級(本機)

| 本機模型 | 能做 | 不建議 |
|---|---|---|
| 0.5–1.5B | 補全、單檔小改、問答、離線查詢 | 多步驟 agent、跨檔重構 |
| 4B | 簡單 coding agent(建檔/改檔/跑測試)、摘要 | 大 codebase 理解、複雜除錯 |
| 7–8B(僅 12GB 機型勉強) | 更穩的 agent,但 context 受限、較耗電 | 長對話、大專案 |

## 選型建議(給用戶的一句話)

- **想離線 / 重隱私 / 免費** → 本機模型(看上表選尺寸)
- **要最強 coding、複雜任務** → 雲端:Codex(訂閱)或 Claude/DeepSeek(API key)
- **8GB 機型做認真開發** → 直接用雲端,本機當輔助

## 待辦

- 數值為依公開 benchmark(apple-silicon-llm-bench 等)與 RAM 推估,**產品發佈前以實機實測校正每一格**。
- Duo 折疊展開/折疊時的記憶體行為另測。
- 本表之後做成 app 內「首次選模型」精靈的資料來源(依裝置自動推薦)。

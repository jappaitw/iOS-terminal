# Terminal App Icon · H 摺帶提示符 `>_` 規格

## 檔案結構

| 資料夾 | 內容 | 用途 |
|---|---|---|
| `01_Source_SVG/` | `AppIcon-light.svg`、`AppIcon-dark.svg`、`AppIcon-tinted.svg` | 向量母檔，之後改色、重出圖都從這裡 |
| `02_Xcode/AppIcon.appiconset/` | 1024 PNG × 3 + `Contents.json` | 整個資料夾直接拖進 `Assets.xcassets` 取代原本的 AppIcon |
| `03_PNG_Sizes/` | 20–1024 px 共 13 個尺寸 | 舊版 Xcode、網站、文件、TestFlight 截圖等其他用途 |
| `04_IconComposer_Layers/` | 背景、下臂、上臂、游標 4 層 SVG | iOS 26 Liquid Glass：匯入 Icon Composer 分層，玻璃質感與陰影由系統產生，所以這幾層不含陰影 |

## 畫布與輸出

- 畫布：1024 × 1024 px，正方形、**不要自己加圓角**，系統會套遮罩
- 主圖（light）：sRGB、不透明、無 alpha（App Store 審核要求）
- Dark / Tinted：透明背景，背景由系統提供
- Tinted 是灰階圖，系統依亮度套上使用者選的色調

## 色彩

| 部位 | Light | Dark | Tinted |
|---|---|---|---|
| 背景 | `#FFFFFF` | 透明 | 透明 |
| 上臂＋游標（亮面，左上→右下漸層） | `#3BAEF8` → `#1286DE` | `#6CC4FF` → `#2E9DF2` | `#FFFFFF` → `#E6E6E6` |
| 下臂（暗面，左下→右上漸層） | `#0059A0` → `#0A72C6` | `#0B62B4` → `#1A84DA` | `#8C8C8C` → `#ABABAB` |
| 投影 | `#00264D` 30% | `#000000` 45% | `#000000` 35% |

投影：`dy 8px`、模糊 `16px`，只加在上臂和游標上，做出「上臂壓在下臂上」的摺疊感。

## 幾何（以 1024 畫布計）

- `>` 箭頭外框：x 162 → 571、y 254 → 771（寬 409、高 517）
- 帶寬：約 137 px（畫布的 13.4%），端點與尖角圓角約 14 px
- 兩臂在尖端沿水平中線（y = 512）切開，上臂在上
- `_` 游標：x 611、y 633.5、250 × 137，圓角 24
- `>` 與 `_` 間距 40 px；`_` 底邊對齊 `>` 下臂末端
- 整組左右留白各約 162 px，光學置中

## Xcode 匯入

1. 打開 `Assets.xcassets`，刪除原本的 `AppIcon`
2. 把 `02_Xcode/AppIcon.appiconset` 整個資料夾拖進去
3. Target → General → App Icons 確認選的是 `AppIcon`
4. 模擬器長按主畫面 → 編輯 → 自訂，就能切換 淺色／深色／著色 預覽

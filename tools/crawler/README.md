# 安心圈警報爬蟲

這個目錄是目前部署到 Mac Mini 的唯一正式腳本來源；`tools/news-crawler/`
是舊版備份，不應再從那裡部署。機器上的金鑰與 `.env` 不進版控。

## 公開資訊來源

| 腳本 | 來源 | 排程 | App 信任層 |
|---|---|---:|---|
| `fetch_ncdr.py` | NCDR 民生示警平台 | 每 1 分鐘 | 官方 |
| `fetch_nfa.py` | 內政部消防署全國災情訊息 | 每 2 分鐘 | 官方 |
| `fetch_taichung_fire.py` | 台中市消防局即時災情 | 每 2 分鐘 | 官方 |
| `fetch_city_fire.py` | 全台縣市消防局即時派遣（台南／高雄／雲林／苗栗／基隆／新竹市／宜蘭／澎湖／台北／台中／桃園／南投／彰化／嘉義／屏東／新北，共 16 縣市） | 每 2 分鐘 | 官方 |
| `fetch_freeway.py` | 高速公路事故／壅塞即時資訊 | 每 2 分鐘 | 官方 |
| `fetch_news.py` | 中央社、自由時報、ETtoday、公視、Newtalk、記者新聞網、聯合報、TVBS 公開 RSS／分類頁 | 每 15 分鐘 | 未驗證；多來源一致才升級 |
| `fetch_aqi.py` | 環境部空氣品質監測 | 每小時 | 官方 |
| `fetch_crime.py` | 內政部警政署刑案統計 | 每月 | 統計參考，不是即時警報 |
| `fetch_cwa.py` | 中央氣象署地震公開資料 | 每 5 分鐘 | 備援資料，App 目前以 NCDR 地震示警為主 |

新聞爬蟲只處理 24 小時內的資料，每個 feed 有硬上限；AI 每輪最多分類 20 則，
遇額度或網路錯誤會立即開啟熔斷，保留待重試項目，不再讓一輪卡住十幾分鐘。

## Gemini 免費／付費隔離

Gemini 分成兩個完全不同的 key pool，任何一層耗盡或失敗都不會把 key 混用：

1. `ProxyCLI`：現有免費路徑，依 `OpenAI → Gemini → Claude` 優先序使用；前一個
   provider 額度不足或不可用才會改試下一個。模型可用 `NEWS_PROXY_*_MODEL` 環境值覆蓋。
2. 免費 Gemini：必須使用專屬、未啟用 Gemini 付費帳務的 Google 專案；key 僅能放在
   `free_gemini_keys.txt`（權限 `600`）。啟用 `FREE_GEMINI_ENABLED=1` 並設定
   `FREE_GEMINI_DAILY_CALL_LIMIT` 後，才會在 ProxyCLI 失敗時使用。每日到達本機上限後
   fail closed，交回規則分類。預設模型為 `gemini-2.5-flash`。
3. 付費 Gemini：只有前兩層失敗後，且明確開啟付費開關與預算時才會使用。

Google Gemini 付費池與 RSS、ProxyCLI 憑證完全分開，預設不會花錢：

- 金鑰只能放在 `paid_gemini_keys.txt`，一行一把，檔案權限必須是 `600`。
- `.env` 只放開關與上限，不放金鑰；必須同時設定
  `PAID_GEMINI_ENABLED=1` 與大於 0 的 `PAID_GEMINI_MONTHLY_LIMIT_USD` 才可能呼叫。
- 現有 ProxyCLI 永遠先用；只有它失敗才會使用付費池。
- 每次呼叫前先按最大輸出量預扣成本，所有付費金鑰共用
  `paid_gemini_usage.json` 月帳本；達上限即 fail closed，不會改拿另一把 key 繞過。
- 標題最多送 300 字、描述最多送 1,200 字，避免異常 RSS 內容把單次 token 成本撐大。
- 預設模型為 `gemini-2.5-flash-lite`，價格假設為 input US$0.10／百萬 token、
  output US$0.40／百萬 token。換模型時必須同步調整價格環境值。

目前正式環境維持免費 Gemini 關閉、`PAID_GEMINI_ENABLED=0`、月費上限 `0`。任何已貼在聊天、
Issue 或 commit 的金鑰都視為外洩，不可放入任一正式金鑰檔，必須先在 AI Studio 撤銷重發。

## 驗證

```bash
/usr/bin/python3 -m unittest discover -s tools/crawler -p 'test_*.py' -v
php -l website/apns/_fcm_lib.php
php -l website/apns/cron_check.php
```

部署時先在遠端保留時間戳備份，再上傳暫存檔、跑語法檢查，通過後才原子替換；
cron 每輪重新執行腳本，不需重啟服務。

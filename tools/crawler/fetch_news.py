#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fetch_news.py — 「安心圈」新聞重大事故爬蟲

用途：
    在官方示警（NCDR）之外，用新聞 RSS 補「事發到官方發布」的時間差。
    產出的事件先進 App 的「持續確認中」信任層（trust = media-report），
    是否提醒由 App 的可信度、生活圈與使用者通知設定統一決定。
    每則事件都帶清楚的來源標示（sourceName + sourceURL）。

設計慣例（與既有 NCDR 爬蟲相同）：
    - Python 3 純標準函式庫，不裝任何 pip 套件
    - 例外：LLM 分類走 ProxyCLI REST API（urllib 呼叫）；
      token 從環境變數 AI_PROXY_TOKEN 讀，沒有 token 自動退回規則式分類，絕不 crash
    - 單一 feed 失敗記 log 後繼續跑其他 feed，不 silent fail
    - 2026-10 新增兩個來源：Google 新聞關鍵字 RSS（聚合各家媒體，媒體名拆自標題尾巴）、
      PTT 八卦版［爆卦］／［新聞］（社群爆料，一律「未經證實」，見 PTT 區塊說明）
    - 建議由 cron 每 15 分鐘跑一次（各 feed ttl 皆 <= 15 分鐘，不會過度抓取）

輸出：
    latest.json — 本次新發現的事故事件（UTF-8、ensure_ascii=False）
    seen.json   — 已處理過的 item id（滾動上限 2000 筆），重跑不重複產出
"""

import concurrent.futures
import difflib
import email.utils
import fcntl
import hashlib
import json
import os
import re
import socket
import sys
import threading
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone, timedelta

# ---------------------------------------------------------------------------
# 基本設定
# ---------------------------------------------------------------------------

# 台北時區（爬蟲機可能是 UTC，所有時間戳統一 +08:00）
TZ_TAIPEI = timezone(timedelta(hours=8))

# 抓取用 User-Agent（部分新聞站會擋預設的 Python-urllib）
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
)

# 抓取逾時（秒）
FETCH_TIMEOUT = 20

# LLM（ProxyCLI）設定：token 由環境變數提供，沒有就走純規則路徑。
# 2026-08-02：舊位址 http://cli.twloop.com:8080/api/chat 已停止服務（實測連線
# 逾時、curl 回 HTTP 000），導致每輪數十則新聞卡在「待重試」、只能靠規則式判讀，
# 抽不出縣市的一律被 App 端丟棄——這是「事件看不到」的隱形殺手之一。
# 改指向現行的 https://clip.twloop.com/api/chat，並開放環境變數覆蓋，
# 日後服務再搬遷只要改 .env，不必動程式碼。
AI_PROXY_URL = os.environ.get("AI_PROXY_URL", "https://clip.twloop.com/api/chat").strip()
AI_PROXY_TOKEN = os.environ.get("AI_PROXY_TOKEN", "").strip()
AI_PROXY_PROJECT = os.environ.get("AI_PROXY_PROJECT", "harry-HavenCircle").strip()
# 2026-08-02 實測：真實分類 prompt 約 703 字，claude-haiku-4-5 要 14.2 秒、
# gpt-4o-mini 要 23.8 秒才回得完（短 prompt 只要 0.3 秒，所以用短句測會誤判成正常）。
# 舊設定預設 10 秒、硬上限 20 秒，等於每一則都必定 DEADLINE_EXCEEDED；而只要有一則
# 失敗，後續整輪就改走 skip_proxy 直接落到已損壞的免費 Gemini 池而熔斷——
# 這就是新聞每輪數十則卡在「待重試」、只能靠規則判讀的真正原因。
# 2026-08-02 規則優先＋LLM補位改造：預設值再從 30 提高到 60（硬上限也是 60）。
# 實測改成 8 執行緒並行呼叫後，單次呼叫在並行負載下約需 25 秒，30 秒的舊預設值
# 太緊、容易把原本會成功的請求也判定逾時而白白計入失敗率。
try:
    PROXY_LLM_TIMEOUT = max(3, min(60, int(os.environ.get("NEWS_PROXY_LLM_TIMEOUT", "60"))))
except ValueError:
    PROXY_LLM_TIMEOUT = 60
# ProxyCLI 傳輸方式：rest（預設，能讀 actual_provider/actual_model）或 sdk（gRPC）
PROXY_TRANSPORT = os.environ.get("NEWS_PROXY_TRANSPORT", "rest").strip().lower()
# 新聞分類的 ProxyCLI 優先序；模型名稱可由 .env 覆蓋，避免新模型推出時必須
# 更新 App 或爬蟲程式。
#
# 2026-08-02 實測（從爬蟲機直接打 clip.twloop.com，同一句 prompt）：
#   claude-haiku-4-5  → 0.2〜2.4 秒
#   gpt-4o-mini       → 22.7 秒
#   gemini-2.5-flash  → 21.4 秒，且回應顯示 actual_provider=openai
#                       （proxy 端 gemini 不可用，已 fallback 到 openai）
# PROXY_LLM_TIMEOUT 上限是 20 秒，所以舊的 openai → gemini → claude 順序，
# 前兩條必定逾時，每則新聞都要先浪費兩次等待才輪到唯一能用的 claude；
# 累積起來整輪 LLM 被判定全滅，日誌顯示「分類路徑皆不可用」。
# 改為 claude 優先，另外兩條留作備援（真的復活時仍可接手）。
#
# 2026-10-10 依 hdw-proxycli 官方說明與實測改版：
#   gemini（不指定 model）→ proxy 預設 gemini-3.5-flash，約 1.5 秒（claude-haiku-4-5
#   在真實 prompt 要 9〜20 秒；舊路由的 gemini-2.5-flash 則回「授權已過期」）。
#   指定 Gemini Pro 會被 proxy 靜默換成別家，所以 gemini 一律不送 model 欄位。
# model 為空字串＝不送 model 欄位，交給 proxy 依 provider 選預設模型；
# 可用 NEWS_PROXY_GEMINI_MODEL / NEWS_PROXY_CLAUDE_MODEL / NEWS_PROXY_OPENAI_MODEL 覆蓋。
# 順序：gemini（便宜快）→ claude（不指定＝訂閱 CLI 預設，額度有日上限，只當備援）→ openai。
PROXY_LLM_ROUTE = (
    ("gemini", os.environ.get("NEWS_PROXY_GEMINI_MODEL", "").strip()),
    ("claude", os.environ.get("NEWS_PROXY_CLAUDE_MODEL", "").strip()),
    ("openai", os.environ.get("NEWS_PROXY_OPENAI_MODEL", "gpt-4o-mini").strip()),
)
# 各 provider 的逾時（秒）。gemini 實測約 1.5 秒（真實 703 字 prompt 也只需數秒），
# 20 秒已留 10 倍以上餘裕；再長只是替壞掉的通道多等，拖慢備援接手。
# claude／openai 較慢（9〜24 秒），維持 30 秒。皆不超過全域上限 PROXY_LLM_TIMEOUT。
PROXY_PROVIDER_TIMEOUT = {"gemini": 20, "claude": 30, "openai": 30}

# Gemini 免費層也與 ProxyCLI、付費 Gemini 完全隔離。免費 key 必須屬於沒有啟用
# Gemini 付費帳務的專案；程式不從環境變數讀 key、不會拿免費 key 放進付費池。
# 預設關閉，且有每日本機呼叫上限，避免來源突增把免費額度瞬間吃完。
FREE_GEMINI_ENABLED = os.environ.get("FREE_GEMINI_ENABLED", "0").strip() == "1"
FREE_GEMINI_MODEL = os.environ.get(
    "FREE_GEMINI_MODEL", "gemini-2.5-flash"
).strip()
FREE_GEMINI_KEYS_PATH = os.environ.get(
    "FREE_GEMINI_KEYS_PATH",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "free_gemini_keys.txt"),
)
FREE_GEMINI_USAGE_PATH = os.environ.get(
    "FREE_GEMINI_USAGE_PATH",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "free_gemini_usage.json"),
)
try:
    FREE_GEMINI_DAILY_CALL_LIMIT = max(
        0, int(os.environ.get("FREE_GEMINI_DAILY_CALL_LIMIT", "200"))
    )
except ValueError:
    FREE_GEMINI_DAILY_CALL_LIMIT = 0
FREE_GEMINI_MAX_OUTPUT_TOKENS = max(
    64, min(1024, int(os.environ.get("FREE_GEMINI_MAX_OUTPUT_TOKENS", "512")))
)
# 2.5 Flash 預設會把輸出額度分給 thinking；新聞分類只需要固定 JSON，關閉 thinking
# 才不會在輸出欄位中途被截斷。若換成需要推理的模型，必須重新評估這個設定與成本。
FREE_GEMINI_THINKING_BUDGET = 0

# Google Gemini 付費路徑必須與免費池、ProxyCLI 憑證、免費 RSS 完全分離。
# 預設關閉且月費上限為 0；只有前兩條免費路徑失敗，且兩個設定都明確開啟、
# 獨立金鑰檔也存在時，才會使用。金鑰永遠不進 .env、不進 repo、不寫 log。
PAID_GEMINI_ENABLED = os.environ.get("PAID_GEMINI_ENABLED", "0").strip() == "1"
try:
    PAID_GEMINI_MONTHLY_LIMIT_USD = max(
        0.0, float(os.environ.get("PAID_GEMINI_MONTHLY_LIMIT_USD", "0"))
    )
except ValueError:
    PAID_GEMINI_MONTHLY_LIMIT_USD = 0.0
PAID_GEMINI_MODEL = os.environ.get(
    "PAID_GEMINI_MODEL", "gemini-2.5-flash-lite"
).strip()
PAID_GEMINI_KEYS_PATH = os.environ.get(
    "PAID_GEMINI_KEYS_PATH",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "paid_gemini_keys.txt"),
)
PAID_GEMINI_USAGE_PATH = os.environ.get(
    "PAID_GEMINI_USAGE_PATH",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "paid_gemini_usage.json"),
)
# Gemini 2.5 Flash-Lite Standard（2026-07-09 官方價格）：每百萬 input $0.10、
# output（含 thinking）$0.40。若換模型必須連同這兩個環境值一起改，不能低估成本。
PAID_GEMINI_INPUT_USD_PER_M = max(
    0.0, float(os.environ.get("PAID_GEMINI_INPUT_USD_PER_M", "0.10"))
)
PAID_GEMINI_OUTPUT_USD_PER_M = max(
    0.0, float(os.environ.get("PAID_GEMINI_OUTPUT_USD_PER_M", "0.40"))
)
PAID_GEMINI_MAX_OUTPUT_TOKENS = max(
    64, min(1024, int(os.environ.get("PAID_GEMINI_MAX_OUTPUT_TOKENS", "512")))
)

# ProxyCLI gRPC SDK（把 proxy.py＋aiproxy_pb2*.py 放進同目錄即自動啟用）。
# 實測 REST 8080 從外部連不到（防火牆），gRPC 443/TLS 才是通的路；
# SDK 缺檔或缺 grpcio 時自動退回 REST，再不行退規則分類，絕不 crash。
try:
    from proxy import ai as _sdk_ai
except Exception:
    _sdk_ai = None

# 簡轉繁保險（opencc-python-reimplemented，純 Python）：LLM 偶爾無視「禁止簡體」指令，
# prompt 押不住就用機械轉換兜底；沒裝 opencc 時照常運作（只少這層保護，不 crash）
try:
    from opencc import OpenCC
    _s2twp = OpenCC("s2twp")  # 簡體 → 台灣正體（含慣用詞轉換）
except Exception:
    _s2twp = None


def to_traditional(text):
    """LLM 產出的中文欄位過一遍簡轉繁；opencc 未安裝或輸入非字串時原樣返回"""
    if _s2twp is None or not isinstance(text, str):
        return text
    return _s2twp.convert(text)


LLM_TIMEOUT = 30
LLM_MIN_CONFIDENCE = 0.6  # LLM 信心低於此值 → 丟棄 LLM 結果、退回規則結果
LLM_MAX_TITLE_CHARS = 300
LLM_MAX_DESCRIPTION_CHARS = 1_200
# 單輪最多呼叫幾則 LLM。避免新來源第一次上線或 feed 突然回傳大量歷史項目時，
# 一輪吃光每日額度並卡住下一個 cron。超過預算的事件不寫入 seen，下輪繼續補分類。
# 2026-08-02：原本 20 遠低於單輪實際規則命中量（約 80-100 則規則通過的事故候選），
# 造成後段來源的事故被永遠排在預算外、只能退回規則結果（無縣市時直接被 App 丟棄）。
# 調高到 120 讓單輪足以覆蓋目前規則命中量的上界；預設路徑固定走免費的 ProxyCLI
# （見檔頭 README／本檔「Gemini 免費／付費隔離」段落），呼叫數變多不會產生費用——
# 只有 ProxyCLI 與免費 Gemini 都失敗、且明確打開 PAID_GEMINI_ENABLED／設定月費上限
# 才可能落到付費層，現行正式環境兩者皆為關閉，故本次調整不影響任何費用。
LLM_MAX_CALLS_PER_RUN = max(0, int(os.environ.get("NEWS_LLM_MAX_CALLS_PER_RUN", "120")))

# 2026-08-02 規則優先＋LLM補位改造：LLM 只對「規則抽不到 county 或 district」的
# 待補清單呼叫，且改用 concurrent.futures.ThreadPoolExecutor 並行送出，不再逐則
# 排隊序列呼叫（序列呼叫 79 次要 1780 秒；實測 8 執行緒並行 8 個請求全部成功、
# 總耗時約等於單次的 25 秒，是安全且有效的加速）。並行度可由環境變數覆蓋，
# 預設 8 是實測值，調高前請先確認 ProxyCLI 端能承受對應的併發量。
try:
    NEWS_LLM_CONCURRENCY = max(1, int(os.environ.get("NEWS_LLM_CONCURRENCY", "8")))
except ValueError:
    NEWS_LLM_CONCURRENCY = 8

# 只處理仍有即時價值的新聞。Oracle 最多保留 24 小時，爬蟲端先擋舊聞可避免把
# 數百筆歷史 RSS 全送進規則與 LLM。
NEWS_MAX_AGE_HOURS = max(1, int(os.environ.get("NEWS_MAX_AGE_HOURS", "24")))
DEFAULT_FEED_ITEM_LIMIT = max(10, int(os.environ.get("NEWS_FEED_ITEM_LIMIT", "80")))

# 事件發布超過幾小時就不得標 is_ongoing=true。選 2 小時：cron 每 5 分鐘、媒體從事發到
# 上稿通常 <1 小時，LLM 重試與延後最多再差幾輪，2 小時足以涵蓋「還算即時」的報導；
# 超過就是事後報導，伺服器推播若照發只會變成「晚了半天的警報」。
ONGOING_MAX_AGE_HOURS = max(1, int(os.environ.get("NEWS_ONGOING_MAX_AGE_HOURS", "2")))

# seen.json 滾動上限
SEEN_MAX = 2000

# 資料來源。RSS 2.0 為預設；format="atom" 走 parse_atom（公視）；format="tvbs_html" 走
# parse_tvbs_local（TVBS 沒有可用 RSS，改直接爬 /local 分類頁 astro-island 的即時清單 props）。
# 2026-07-26：實測三立官網為前端 JS 動態渲染，簡單 HTML 爬取抓不到內容，暫不支援
# （需要無頭瀏覽器等級的技術投入，非目前爬蟲架構的量級，故不強做）。
FEEDS = [
    {"name": "中央社", "feed": "社會", "url": "https://feeds.feedburner.com/rsscna/social"},
    {"name": "中央社", "feed": "地方", "url": "https://feeds.feedburner.com/rsscna/local"},
    {"name": "中央社", "feed": "生活", "url": "https://feeds.feedburner.com/rsscna/lifehealth"},
    {"name": "自由時報", "feed": "社會", "url": "https://news.ltn.com.tw/rss/society.xml"},
    {"name": "自由時報", "feed": "地方", "url": "https://news.ltn.com.tw/rss/local.xml"},
    {"name": "ETtoday", "feed": "社會", "url": "https://feeds.feedburner.com/ettoday/society"},
    {"name": "公視", "feed": "新聞", "url": "https://news.pts.org.tw/xml/newsfeed.xml", "format": "atom"},
    # 下列兩站提供可直接驗證的公開 RSS；只取近期有限筆，避免全站 feed 放大 LLM 成本。
    {"name": "Newtalk新聞", "feed": "即時", "url": "https://newtalk.tw/rss/all", "max_items": 60},
    {"name": "記者新聞網", "feed": "社會", "url": "https://newsdaily.tw/rss/society.xml", "max_items": 60},
    # UDN 從海外 IP 實測回「合法 RSS 外殼但 item 全空」（疑地區過濾）；
    # 爬蟲機在台灣網路，掛著觀察——若仍為空殼，空 items 會被標題過濾自然略過，無害
    # UDN 目前一次會回約 700 筆；必須加硬上限並先過 24 小時新鮮度閘門。
    {"name": "聯合報", "feed": "社會", "url": "https://udn.com/news/rssfeed/6639", "max_items": 60},
    {"name": "TVBS", "feed": "社會", "url": "https://news.tvbs.com.tw/local", "format": "tvbs_html", "max_items": 60},
]


# ---------------------------------------------------------------------------
# 擴充來源 A：Google 新聞關鍵字 RSS
# ---------------------------------------------------------------------------
# 用「OR」把關鍵字併成 5 組查詢（每輪 5 個 HTTP 請求，而非 10+ 個），並加 when:1d
# 只取近 24 小時。Google 的 item 標題格式為「標題 - 媒體名」，媒體名同時放在 <source>。
# 這些來源排在 FEEDS 最後面：既有 feed 先用掉 LLM 預算，新來源只能吃「額外預算」。
# 治安暴力放最前面：extra 來源共用一份額外 LLM 預算，先掃的先花，家人最在意的治安優先。
# 拆 2 組避免單組過長；不放「失蹤」「詐騙」（失蹤量大且多為協尋、詐騙無地點威脅）。
GOOGLE_NEWS_QUERIES = [
    ("治安暴力", "持刀 OR 砍人 OR 隨機傷人 OR 殺人 OR 槍擊 OR 開槍 OR 搶劫 OR 搶奪 OR 擄人 OR 綁架"),
    ("治安犯罪", "可疑男子 OR 性騷擾 OR 偷拍 OR 竊盜 OR 入室 OR 闖空門 OR 縱火 OR 恐嚇 OR 鬥毆 OR 通緝犯"),
    ("火災爆炸", "火災 OR 失火 OR 氣爆 OR 爆炸"),
    ("交通事故", "車禍 OR 追撞 OR 翻車"),
    ("天災", "地震 OR 淹水 OR 土石流 OR 豪雨"),
    ("民生", "停電 OR 停水"),
]
GOOGLE_NEWS_ENABLED = os.environ.get("NEWS_GOOGLE_ENABLED", "1").strip() != "0"

# Google 的媒體名稱 → App 端一線媒體名單（Swift MainstreamMedia.tier1）使用的名稱。
# App 用 sourceName「包含比對」判斷信任等級，所以正規化後 Google 轉載的一線媒體報導
# 自動升為「主流媒體報導」；也讓同一家媒體不會因寫法不同（聯合新聞網 vs 聯合報）
# 被誤算成兩個來源而灌水 corroboration。不在表內的媒體維持原名 → App 視為「持續確認中」。
GOOGLE_MEDIA_CANONICAL = [
    ("中央社", "中央社"),
    ("公視", "公視"),
    ("公共電視", "公視"),
    ("TVBS", "TVBS"),
    ("聯合新聞網", "聯合報"),
    ("聯合報", "聯合報"),
    ("自由時報", "自由時報"),
    ("ETtoday", "ETtoday"),
    ("Newtalk", "Newtalk新聞"),
    ("記者新聞網", "記者新聞網"),
]

# 入口網站／聚合平台只是轉載別家內容（Yahoo 轉中央社、LINE TODAY 轉各家…），
# 若算成獨立來源會灌水 corroboration、假造「多來源交叉驗證」。這類來源與既有事件
# 重複時直接丟棄、不合併；沒有重複時照常當作單一未知來源輸出。
AGGREGATOR_MEDIA = ("Yahoo", "LINE TODAY", "MSN", "新浪", "奇摩", "Google")

# 新來源（Google／PTT）每輪最多額外花幾次 LLM；同時仍受 LLM_MAX_CALLS_PER_RUN 總量限制。
# 超過的項目不寫 seen、也不輸出（無地點的事件 App 會丟棄），下一輪再補。
try:
    EXTRA_LLM_MAX_CALLS_PER_RUN = max(0, int(os.environ.get("NEWS_EXTRA_LLM_MAX_CALLS", "10")))
except ValueError:
    EXTRA_LLM_MAX_CALLS_PER_RUN = 10


def google_news_url(query):
    """Google 新聞搜尋 RSS 網址（繁中台灣版，限近 1 天）"""
    q = urllib.parse.quote(query + " when:1d")
    return "https://news.google.com/rss/search?q={}&hl=zh-TW&gl=TW&ceid=TW:zh-Hant".format(q)


if GOOGLE_NEWS_ENABLED:
    for _label, _query in GOOGLE_NEWS_QUERIES:
        FEEDS.append({
            "name": "Google新聞", "feed": _label, "url": google_news_url(_query),
            "format": "google_news", "max_items": 60 if _label.startswith("治安") else 40, "extra": True,
        })

# ---------------------------------------------------------------------------
# 擴充來源 B：PTT 八卦版（社群爆料，一律未經證實）
# ---------------------------------------------------------------------------
# 產品守則：社群資訊視為未經證實。做法（三道鎖，缺一不可）：
#   1. sourceName 用「PTT八卦版」，不含任何一線媒體字樣 → App 端 trustLevel 只會給
#      「持續確認中」（詳情頁顯示「這是未驗證線索…不會自動通知家人」）。
#   2. corroboration 固定 1，且與媒體事件重複時直接丟棄 PTT、不合併 → PTT 不會替任何
#      事件「灌」交叉驗證。
#   3. 不呼叫 LLM、severity 固定 low、is_ongoing 固定 False → 伺服器 cron_check.php 的
#      process_news／news_wake_signature 要求「is_ongoing=true 且 severity 為 high/medium」，
#      永遠不符，不會觸發推播。
# 只放八卦版：地方版（Taoyuan、Kaohsiung…）發文量低、事故貼文多為求助或閒聊，
# 噪音比高且各版 [爆卦] 慣例不一，先不放；日後要加只需在 PTT_BOARDS 補一行。
PTT_ENABLED = os.environ.get("NEWS_PTT_ENABLED", "1").strip() != "0"
PTT_BOARDS = [
    {"board": "Gossiping", "name": "PTT八卦版", "url": "https://www.ptt.cc/atom/Gossiping.xml"},
]
PTT_TRUST = "community-unverified"
PTT_TITLE_RE = re.compile(r"^\s*\[(爆卦|新聞)\]\s*(.+)$")
PTT_SUMMARY_PREFIX = "網友爆料（未證實）："
PTT_DETAIL = "PTT 網友發文，未經官方或媒體證實，請勿當作確定消息；有立即危險請撥 110 或 119。"

# ---------------------------------------------------------------------------
# 分類詞庫（第一段：規則式，永遠執行）
# ---------------------------------------------------------------------------

# 排除詞：司法後續、政治攻防、追悼紀念——這些不是「進行中的現場事故」。
# 注意：只比對「標題」。事故報導的內文常出現「依公共危險罪嫌起訴」之類字眼，
# 若連內文一起排除會誤殺大量真事故。
EXCLUDE_WORDS = [
    # 司法流程
    "判決", "判刑", "判處", "宣判", "判賠", "求刑", "起訴", "定讞", "上訴",
    "偵結", "收押", "羈押", "交保", "抗告", "緩刑", "開庭", "聲請", "二審", "三審",
    # 政治與輿論後續
    "彈劾", "質詢", "民調", "罷免",
    # 追悼紀念
    "追思", "紀念", "告別式", "公祭",
    # 治安關鍵字會撈到的雜訊：政論節目、選舉、電玩試玩（「鬥毆」「偷拍」「恐嚇」常出現在這些標題）
    "討論牆", "九合一", "TGS", "試玩",
]

# 酒駕本身可能是剛發生的道路風險，但「罰鍰／轉介戒酒」是裁罰或後續輔導，
# 不是需要即時反應的事故。不能把「酒駕」整個排掉，否則會漏掉正在發生的
# 碰撞或危險駕駛；只在酒駕命中時用這組更精準的事後處置詞攔下。
TRAFFIC_AFTERCARE_TERMS = [
    "罰款", "罰鍰", "轉介", "戒酒", "欠費", "欠款", "繳納",
    "行政執行", "執行分署", "裁罰", "罰單",
]

# 納入詞：依 App 分類（火災/交通/天災/公共安全/民生）分組，
# 依序比對，第一個命中的組別即為 category。
# 比對範圍：標題＋描述（描述常補足標題沒寫的事故詞）。
INCLUDE_CATEGORIES = [
    ("火災", ["火警", "火災", "失火", "起火", "縱火", "爆炸", "氣爆", "閃燃"]),
    ("交通", ["車禍", "追撞", "自撞", "對撞", "擦撞", "翻覆", "翻車", "酒駕",
              "逆向", "撞", "出軌", "落軌", "墜機", "迫降", "連環撞"]),
    ("天災", ["淹水", "地震", "土石流", "落石", "山崩", "走山", "斷橋",
              "暴雨", "豪雨", "溢流", "潰堤", "海嘯"]),
    ("民生", ["停電", "斷電", "停水", "斷水", "跳電", "瓦斯外洩"]),
    ("公共安全", ["坍塌", "倒塌", "崩塌", "溺水", "溺斃", "墜樓", "墜谷", "墜落",
                  "砍", "刺傷", "傷人", "槍擊", "開槍", "掃射", "衝鋒槍", "步槍", "手槍", "槍手", "亂槍", "開火", "持槍", "中彈", "挾持", "隨機",
                  "外洩", "毒氣", "命案", "失蹤", "尋獲", "疏散", "封閉",
                  "警戒", "爆裂物", "鬥毆", "襲擊", "恐嚇", "獵殺", "獵捕", "槍枝", "通緝", "逮捕", "落網",
                  "持刀", "殺人", "行兇", "砍殺", "搶劫", "搶奪", "強盜", "擄人", "綁架", "可疑男子",
                  "性騷擾", "偷拍", "竊盜", "入室", "闖空門", "分屍"]),
]

# 治安強訊號：標題命中就直接歸「公共安全」，不讓「持刀砍人後駕車逃逸撞傷警」被「撞」搶成交通。
# 縱火不放這裡（維持歸火災，需疏散）。
CRIME_PRIORITY_TERMS = ["持刀", "砍人", "砍殺", "殺人", "行兇", "槍擊", "開槍", "持槍", "搶劫", "搶奪",
                        "強盜", "擄人", "綁架", "挾持", "隨機傷人", "刺傷", "分屍"]

# 這些公共安全詞即使只出現在描述也算（明確的暴力／犯罪詞）；其餘泛用詞須在標題出現
CRIME_DESC_OK_TERMS = set(CRIME_PRIORITY_TERMS) | {"命案", "爆裂物", "亂槍", "中彈", "槍手", "掃射", "襲擊"}

# 地標 → 縣市：標題只寫地標、沒寫縣市時用（Google 描述不可信，見 main 的地點抽取）
LANDMARK_COUNTY = {"東大門夜市": "花蓮縣", "逢甲夜市": "台中市", "六合夜市": "高雄市", "花園夜市": "台南市",
                   "士林夜市": "台北市", "饒河夜市": "台北市", "寧夏夜市": "台北市", "廟口夜市": "基隆市"}


def county_from_landmark(text):
    for k, v in LANDMARK_COUNTY.items():
        if k in (text or ""):
            return v
    return None

# 純金錢詐騙：沒有人身／地點威脅，標題帶這些詞且沒有暴力詞就不當事件（避免推播）。
FRAUD_TERMS = ["詐騙", "詐欺", "詐團", "車手", "詐財", "詐貸", "釣魚簡訊", "假投資", "洗錢", "人頭帳戶"]
VIOLENCE_TERMS = ["持刀", "砍", "槍", "擄", "綁架", "挾持", "刺傷", "傷人", "殺", "搶", "毆", "恐嚇", "命案"]

# 事後報導詞：已逮捕／落網／到案等代表危險已解除，不得標 is_ongoing（規則層 clamp，LLM 也適用）。
AFTERMATH_TERMS = ["逮捕", "落網", "逮獲", "逮到", "遭逮", "被捕", "遭捕", "到案", "歸案", "送辦", "移送",
                   "查獲", "破獲", "起訴", "判刑", "判決", "羈押", "收押", "交保", "聲押", "聲請羈押", "具保", "地檢署", "認罪", "獲判", "偵結"]
# 通緝本身是背景資訊；但「通緝犯持刀逃逸」這類現場仍在進行的不 clamp
LIVE_DANGER_TERMS = ["逃逸", "逃亡", "追捕", "在逃", "持刀", "持槍", "挾持", "圍捕", "對峙", "擴大搜索", "搜捕"]


def is_aftermath_report(title):
    """True＝標題是事後報導（逮捕／落網／起訴…），不可標 is_ongoing"""
    title = title or ""
    if any(w in title for w in AFTERMATH_TERMS):
        return True
    return "通緝" in title and not any(w in title for w in LIVE_DANGER_TERMS)


# 治安推播閘門（2026-10-10）：只有「暴力且進行中」才推。詞表刻意保守，竊盜／詐騙／偷拍／
# 性騷擾等不在其中，一律維持 is_ongoing=False。
VIOLENT_HIGH_TERMS = ["槍擊", "開槍", "持槍", "亂槍", "掃射", "槍手", "持刀", "揮刀", "揮砍", "追砍",
                      "砍人", "砍殺", "隨機攻擊", "隨機傷人", "隨機砍人", "隨機殺人"]
VIOLENT_MEDIUM_TERMS = ["擄人", "挾持", "縱火", "行兇", "刺傷", "砍傷", "搶劫", "強盜", "殺人"]
# 回顧／司法／家屬後續報導（AFTERMATH_TERMS 之外，僅治安閘門使用）
CRIME_RETROSPECT_TERMS = ["重建", "遺族", "悼念", "檢方", "檢察官", "法院", "被告", "嫌犯已", "訊後", "偵訊"]
# 非暴力治安詞：即使 LLM 標了 is_ongoing 也壓回 False（除非同時命中暴力詞）
NONVIOLENT_CRIME_TERMS = ["竊盜", "偷竊", "詐騙", "詐欺", "偷拍", "性騷擾", "入室", "闖空門", "可疑男子", "恐嚇"]
CRIME_PUSH_CONFIDENCE = 0.6


def violent_ongoing_severity(title):
    """標題命中暴力詞且非事後報導 → 'high'／'medium'；否則 None"""
    title = title or ""
    if is_aftermath_report(title) or any(w in title for w in CRIME_RETROSPECT_TERMS):
        return None
    if any(w in title for w in VIOLENT_HIGH_TERMS):
        return "high"
    if any(w in title for w in VIOLENT_MEDIUM_TERMS):
        return "medium"
    return None


def is_pure_fraud(title):
    title = title or ""
    return any(w in title for w in FRAUD_TERMS) and not any(w in title for w in VIOLENCE_TERMS)


# 誤判防護：這些較短的納入詞若出現在下列慣用語中，不算命中
# （例：「撞名」「砍價」不是事故）
FALSE_HIT_GUARDS = {
    "撞": ["撞名", "撞臉", "撞衫", "撞期", "撞色"],
    "砍": ["砍價", "砍單", "砍預算", "砍半", "砍掉", "砍樹", "砍伐", "砍除", "砍柴", "砍頭價"],
    "封閉": ["封閉式", "封閉性"],
}

# ---------------------------------------------------------------------------
# 縣市正規化（電頭與標題抽取共用）
# ---------------------------------------------------------------------------

# key = 電頭/標題可能出現的地名 token，value = 正規化縣市名
# 比對時依 key 長度由長到短（「新竹市」要先於「新竹」命中）
COUNTY_NORMALIZE = {
    "台北": "台北市", "臺北": "台北市",
    "新北": "新北市",
    "桃園": "桃園市",
    "台中": "台中市", "臺中": "台中市",
    "台南": "台南市", "臺南": "台南市",
    "高雄": "高雄市",
    "基隆": "基隆市",
    "新竹市": "新竹市", "新竹縣": "新竹縣", "新竹": "新竹市",
    "苗栗": "苗栗縣",
    "彰化": "彰化縣",
    "南投": "南投縣",
    "雲林": "雲林縣",
    "嘉義市": "嘉義市", "嘉義縣": "嘉義縣", "嘉義": "嘉義市",
    "屏東": "屏東縣",
    "宜蘭": "宜蘭縣",
    "花蓮": "花蓮縣",
    "台東": "台東縣", "臺東": "台東縣",
    "澎湖": "澎湖縣",
    "金門": "金門縣",
    "連江": "連江縣", "馬祖": "連江縣",
}
# 由長到短排序的 token 清單（供 endswith / 掃描使用）
COUNTY_TOKENS = sorted(COUNTY_NORMALIZE.keys(), key=len, reverse=True)

# ---------------------------------------------------------------------------
# 行政區反查縣市（縣市 token 沒中時的最後防線）
# ---------------------------------------------------------------------------
#
# 資料來源：HavenCircle/Resources/TaiwanDistricts.json（App 端地圖用的鄉鎮市區
# 邊界資料，county/town 屬性即權威行政區劃分）。這裡只取 (county, town) 對照，
# 不含幾何座標，故直接內嵌成常數，不在執行期讀取那個 340KB 的 GeoJSON
# （爬蟲機不保證有 checkout 到 App 的 Resources 目錄，內嵌才能獨立運作）。
#
# 重新產生的一行指令（若 TaiwanDistricts.json 有行政區劃更新才需要重跑）：
#   /usr/bin/python3 -c "
#   import json
#   from collections import defaultdict
#   d = json.load(open('HavenCircle/Resources/TaiwanDistricts.json', encoding='utf-8'))
#   pairs = {(f['properties']['county'], f['properties']['town'])
#            for f in d['features'] if '(' not in f['properties']['town']}
#   by_town = defaultdict(set)
#   for c, t in pairs: by_town[t].add(c)
#   print(sorted(t for t, cs in by_town.items() if len(cs) == 1))"
#
# 鐵律：**同名行政區故意不收進這張表**，寧可查不到、留空 county，也不要用機率
# 亂猜是哪個縣市——猜錯會讓 App 把事件釘在錯的地圖位置，比沒有位置更誤導人。
# 已知同名（2026-08-02 由上述來源實測列出，共 8 組，故意排除）：
#   中山區／中正區／信義區（台北市、基隆市都有）
#   大安區（台中市、台北市都有）
#   北區（台中市、台南市、新竹市都有）
#   南區（台中市、台南市都有）
#   東區（台中市、台南市、嘉義市、新竹市都有）
#   西區（台中市、嘉義市都有）
# 「(海)」字樣的條目是 GeoJSON 裡的海域邊界變體（如「小港區(海)」），
# 新聞不會這樣寫地名，來源已先過濾掉，不會出現在這張表。
DISTRICT_TO_COUNTY = {
    "七堵區": "基隆市", "七美鄉": "澎湖縣", "七股區": "台南市", "三地門鄉": "屏東縣",
    "三峽區": "新北市", "三星鄉": "宜蘭縣", "三民區": "高雄市", "三灣鄉": "苗栗縣",
    "三義鄉": "苗栗縣", "三芝區": "新北市", "三重區": "新北市", "下營區": "台南市",
    "中和區": "新北市", "中埔鄉": "嘉義縣", "中壢區": "桃園市",
    "中寮鄉": "南投縣", "中西區": "台南市", "九如鄉": "屏東縣", "二崙鄉": "雲林縣",
    "二林鎮": "彰化縣", "二水鄉": "彰化縣", "五峰鄉": "新竹縣", "五結鄉": "宜蘭縣",
    "五股區": "新北市", "仁德區": "台南市", "仁愛區": "基隆市", "仁愛鄉": "南投縣",
    "仁武區": "高雄市", "伸港鄉": "彰化縣", "佳冬鄉": "屏東縣", "佳里區": "台南市",
    "來義鄉": "屏東縣", "信義鄉": "南投縣", "元長鄉": "雲林縣", "光復鄉": "花蓮縣",
    "內埔鄉": "屏東縣", "內湖區": "台北市", "內門區": "高雄市", "八德區": "桃園市",
    "八里區": "新北市", "公館鄉": "苗栗縣", "六甲區": "台南市", "六腳鄉": "嘉義縣",
    "六龜區": "高雄市", "冬山鄉": "宜蘭縣", "前金區": "高雄市", "前鎮區": "高雄市",
    "北埔鄉": "新竹縣", "北屯區": "台中市", "北投區": "台北市", "北斗鎮": "彰化縣",
    "北港鎮": "雲林縣", "北竿鄉": "連江縣", "北門區": "台南市", "卑南鄉": "台東縣",
    "卓溪鄉": "花蓮縣", "卓蘭鎮": "苗栗縣", "南化區": "台南市", "南屯區": "台中市",
    "南州鄉": "屏東縣", "南庄鄉": "苗栗縣", "南投市": "南投縣", "南港區": "台北市",
    "南澳鄉": "宜蘭縣", "南竿鄉": "連江縣", "口湖鄉": "雲林縣", "古坑鄉": "雲林縣",
    "台東市": "台東縣", "台西鄉": "雲林縣", "吉安鄉": "花蓮縣", "名間鄉": "南投縣",
    "后里區": "台中市", "和平區": "台中市", "和美鎮": "彰化縣", "員山鄉": "宜蘭縣",
    "員林市": "彰化縣", "善化區": "台南市", "四湖鄉": "雲林縣", "國姓鄉": "南投縣",
    "土城區": "新北市", "土庫鎮": "雲林縣", "坪林區": "新北市", "埔心鄉": "彰化縣",
    "埔里鎮": "南投縣", "埔鹽鄉": "彰化縣", "埤頭鄉": "彰化縣", "士林區": "台北市",
    "壯圍鄉": "宜蘭縣", "壽豐鄉": "花蓮縣", "外埔區": "台中市", "大內區": "台南市",
    "大同區": "台北市", "大同鄉": "宜蘭縣", "大園區": "桃園市", "大城鄉": "彰化縣",
    "大埔鄉": "嘉義縣", "大埤鄉": "雲林縣", "大寮區": "高雄市", "大村鄉": "彰化縣",
    "大林鎮": "嘉義縣", "大樹區": "高雄市", "大武鄉": "台東縣", "大湖鄉": "苗栗縣",
    "大溪區": "桃園市", "大甲區": "台中市", "大社區": "高雄市", "大肚區": "台中市",
    "大里區": "台中市", "大雅區": "台中市", "太保市": "嘉義縣", "太平區": "台中市",
    "太麻里鄉": "台東縣", "學甲區": "台南市", "安南區": "台南市", "安定區": "台南市",
    "安平區": "台南市", "安樂區": "基隆市", "官田區": "台南市", "宜蘭市": "宜蘭縣",
    "富里鄉": "花蓮縣", "寶山鄉": "新竹縣", "將軍區": "台南市", "小港區": "高雄市",
    "尖石鄉": "新竹縣", "屏東市": "屏東縣", "山上區": "台南市", "岡山區": "高雄市",
    "峨眉鄉": "新竹縣", "崁頂鄉": "屏東縣", "崙背鄉": "雲林縣", "左營區": "高雄市",
    "左鎮區": "台南市", "布袋鎮": "嘉義縣", "平溪區": "新北市", "平鎮區": "桃園市",
    "延平鄉": "台東縣", "彌陀區": "高雄市", "彰化市": "彰化縣", "後壁區": "台南市",
    "後龍鎮": "苗栗縣", "復興區": "桃園市", "恆春鎮": "屏東縣", "成功鎮": "台東縣",
    "文山區": "台北市", "斗六市": "雲林縣", "斗南鎮": "雲林縣", "新化區": "台南市",
    "新園鄉": "屏東縣", "新城鄉": "花蓮縣", "新埔鎮": "新竹縣", "新埤鄉": "屏東縣",
    "新屋區": "桃園市", "新市區": "台南市", "新店區": "新北市", "新港鄉": "嘉義縣",
    "新營區": "台南市", "新社區": "台中市", "新興區": "高雄市", "新莊區": "新北市",
    "新豐鄉": "新竹縣", "旗山區": "高雄市", "旗津區": "高雄市", "春日鄉": "屏東縣",
    "暖暖區": "基隆市", "望安鄉": "澎湖縣", "朴子市": "嘉義縣", "杉林區": "高雄市",
    "東勢區": "台中市", "東勢鄉": "雲林縣", "東山區": "台南市", "東引鄉": "連江縣",
    "東河鄉": "台東縣", "東港鎮": "屏東縣", "東石鄉": "嘉義縣", "松山區": "台北市",
    "板橋區": "新北市", "枋寮鄉": "屏東縣", "枋山鄉": "屏東縣", "林內鄉": "雲林縣",
    "林口區": "新北市", "林園區": "高雄市", "林邊鄉": "屏東縣", "柳營區": "台南市",
    "桃園區": "桃園市", "桃源區": "高雄市", "梅山鄉": "嘉義縣", "梓官區": "高雄市",
    "梧棲區": "台中市", "楊梅區": "桃園市", "楠梓區": "高雄市", "楠西區": "台南市",
    "樹林區": "新北市", "橋頭區": "高雄市", "橫山鄉": "新竹縣", "歸仁區": "台南市",
    "民雄鄉": "嘉義縣", "水上鄉": "嘉義縣", "水林鄉": "雲林縣", "水里鄉": "南投縣",
    "永和區": "新北市", "永安區": "高雄市", "永康區": "台南市", "永靖鄉": "彰化縣",
    "汐止區": "新北市", "池上鄉": "台東縣", "沙鹿區": "台中市", "泰安鄉": "苗栗縣",
    "泰山區": "新北市", "泰武鄉": "屏東縣", "海端鄉": "台東縣", "淡水區": "新北市",
    "深坑區": "新北市", "清水區": "台中市", "湖內區": "高雄市", "湖口鄉": "新竹縣",
    "湖西鄉": "澎湖縣", "溪口鄉": "嘉義縣", "溪州鄉": "彰化縣", "溪湖鎮": "彰化縣",
    "滿州鄉": "屏東縣", "潭子區": "台中市", "潮州鎮": "屏東縣", "烈嶼鄉": "金門縣",
    "烏來區": "新北市", "烏日區": "台中市", "燕巢區": "高雄市", "牡丹鄉": "屏東縣",
    "獅子鄉": "屏東縣", "獅潭鄉": "苗栗縣", "玉井區": "台南市", "玉里鎮": "花蓮縣",
    "琉球鄉": "屏東縣", "瑞穗鄉": "花蓮縣", "瑞芳區": "新北市", "瑪家鄉": "屏東縣",
    "田中鎮": "彰化縣", "田寮區": "高雄市", "田尾鄉": "彰化縣", "甲仙區": "高雄市",
    "番路鄉": "嘉義縣", "白沙鄉": "澎湖縣", "白河區": "台南市", "石岡區": "台中市",
    "石碇區": "新北市", "石門區": "新北市", "礁溪鄉": "宜蘭縣", "社頭鄉": "彰化縣",
    "神岡區": "台中市", "福興鄉": "彰化縣", "秀林鄉": "花蓮縣", "秀水鄉": "彰化縣",
    "竹北市": "新竹縣", "竹南鎮": "苗栗縣", "竹塘鄉": "彰化縣", "竹山鎮": "南投縣",
    "竹崎鄉": "嘉義縣", "竹東鎮": "新竹縣", "竹田鄉": "屏東縣", "綠島鄉": "台東縣",
    "線西鄉": "彰化縣", "羅東鎮": "宜蘭縣", "美濃區": "高雄市", "義竹鄉": "嘉義縣",
    "芎林鄉": "新竹縣", "芬園鄉": "彰化縣", "花壇鄉": "彰化縣", "花蓮市": "花蓮縣",
    "芳苑鄉": "彰化縣", "苑裡鎮": "苗栗縣", "苓雅區": "高雄市", "苗栗市": "苗栗縣",
    "茂林區": "高雄市", "茄萣區": "高雄市", "草屯鎮": "南投縣", "莒光鄉": "連江縣",
    "莿桐鄉": "雲林縣", "萬丹鄉": "屏東縣", "萬巒鄉": "屏東縣", "萬榮鄉": "花蓮縣",
    "萬華區": "台北市", "萬里區": "新北市", "蘆洲區": "新北市", "蘆竹區": "桃園市",
    "蘇澳鎮": "宜蘭縣", "蘭嶼鄉": "台東縣", "虎尾鎮": "雲林縣", "褒忠鄉": "雲林縣",
    "西屯區": "台中市", "西嶼鄉": "澎湖縣", "西港區": "台南市", "西湖鄉": "苗栗縣",
    "西螺鎮": "雲林縣", "觀音區": "桃園市", "豐原區": "台中市", "豐濱鄉": "花蓮縣",
    "貢寮區": "新北市", "路竹區": "高雄市", "車城鄉": "屏東縣", "通霄鎮": "苗栗縣",
    "造橋鄉": "苗栗縣", "達仁鄉": "台東縣", "里港鄉": "屏東縣", "金城鎮": "金門縣",
    "金寧鄉": "金門縣", "金山區": "新北市", "金峰鄉": "台東縣", "金沙鎮": "金門縣",
    "金湖鎮": "金門縣", "銅鑼鄉": "苗栗縣", "長治鄉": "屏東縣", "長濱鄉": "台東縣",
    "關山鎮": "台東縣", "關廟區": "台南市", "關西鎮": "新竹縣", "阿蓮區": "高雄市",
    "阿里山鄉": "嘉義縣", "集集鎮": "南投縣", "雙溪區": "新北市", "霧台鄉": "屏東縣",
    "霧峰區": "台中市", "頭份市": "苗栗縣", "頭城鎮": "宜蘭縣", "頭屋鄉": "苗栗縣",
    "香山區": "新竹市", "馬公市": "澎湖縣", "高樹鄉": "屏東縣", "魚池鄉": "南投縣",
    "鳥松區": "高雄市", "鳳山區": "高雄市", "鳳林鎮": "花蓮縣", "鶯歌區": "新北市",
    "鹽埔鄉": "屏東縣", "鹽埕區": "高雄市", "鹽水區": "台南市", "鹿港鎮": "彰化縣",
    "鹿草鄉": "嘉義縣", "鹿谷鄉": "南投縣", "鹿野鄉": "台東縣", "麟洛鄉": "屏東縣",
    "麥寮鄉": "雲林縣", "麻豆區": "台南市", "鼓山區": "高雄市", "龍井區": "台中市",
    "龍崎區": "台南市", "龍潭區": "桃園市", "龜山區": "桃園市",
}
# 「中區」只有台中市有、理論上不算同名，但長度只有 2 字，實務上容易撞上不相干詞
# （如「集中區域」）造成誤判，故意不放進表裡；寧可漏掉，也不要製造假縣市。
assert "中區" not in DISTRICT_TO_COUNTY
# 由長到短排序（供 find() 掃描時，同位置優先取較長、較精確的行政區名）
DISTRICT_TOKENS = sorted(DISTRICT_TO_COUNTY.keys(), key=len, reverse=True)

# 中央社電頭格式：「（中央社記者王淑芬高雄16日電）」或「（中央社台北16日電）」
# 抽出「記者名（可無）＋地名」到「N日」之間的片段，再用縣市 token 從尾端比對
CNA_DATELINE_RE = re.compile(r"[（(]中央社(?:記者)?([^）)]{0,30}?)(\d{1,2})日[^）)]{0,15}?電[）)]")


def log(msg):
    """統一 log 格式（stderr，帶台北時間戳），cron 可導向 log 檔"""
    ts = datetime.now(TZ_TAIPEI).strftime("%Y-%m-%d %H:%M:%S")
    print("[{}] {}".format(ts, msg), file=sys.stderr)


# ---------------------------------------------------------------------------
# LLM 失敗原因彙總（不再 silent fail）
# ---------------------------------------------------------------------------
# 2026-10-10 查證：log 長期顯示「LLM 呼叫 10（失敗 8）」，但爬蟲機實測 ProxyCLI
# 與免費 Gemini 都正常。「失敗」其實是把「LLM 有回、但低信心／分類不在白名單／
# 非 JSON」也算進去，且這些路徑多半不寫 log，看起來就像 80% 通道壞掉。
# 現在：傳輸層失敗（逾時、HTTP、授權過期…）與「回了但不採用」分開計數，
# 每輪結束各印一行彙總。_LLM_REASONS 為跨執行緒共用，以 lock 保護。
_LLM_REASON_LOCK = threading.Lock()
_LLM_FAIL_REASONS = {}      # 整則最終失敗（三條路徑都不通）的原因
_LLM_UNUSABLE_REASONS = {}  # LLM 有回應、但內容不採用的原因
_LLM_PROVIDER_ERRORS = {}   # 單一 provider 出錯的原因（即使後來由備援救回）；
                            # 也記「gemini→openai 靜默替換」（proxy ok:true 卻換了別家）
_LLM_ACTUAL_MODELS = {}     # 每輪實際回答的 provider/model 次數（每輪 log 一行）


def _bump(table, reason):
    with _LLM_REASON_LOCK:
        table[reason] = table.get(reason, 0) + 1


def reset_llm_reasons():
    with _LLM_REASON_LOCK:
        _LLM_FAIL_REASONS.clear()
        _LLM_UNUSABLE_REASONS.clear()
        _LLM_PROVIDER_ERRORS.clear()
        _LLM_ACTUAL_MODELS.clear()


def describe_llm_error(error):
    """把例外壓成簡短、穩定、可彙總的標籤（逾時／HTTP 狀態碼／gRPC 狀態／訊息前 40 字）。"""
    if error is None:
        return "未知"
    if isinstance(error, FreeGeminiUnavailable) and not error.__cause__:
        return str(error)[:40]
    cause = error.__cause__ if isinstance(error, FreeGeminiUnavailable) else error
    if isinstance(cause, urllib.error.HTTPError):
        return "HTTP {}".format(cause.code)
    if isinstance(cause, (TimeoutError, socket.timeout)):
        return "timeout"
    if isinstance(cause, urllib.error.URLError):
        reason = getattr(cause, "reason", None)
        if isinstance(reason, (TimeoutError, socket.timeout)):
            return "timeout"
        return "連線失敗:{}".format(type(reason).__name__ if reason else "URLError")
    code = getattr(cause, "code", None)
    if callable(code):  # grpc.RpcError：code() 回傳 StatusCode
        try:
            name = getattr(code(), "name", None)
            if name:
                return "gRPC {}".format(name).replace("DEADLINE_EXCEEDED", "timeout")
        except Exception:
            pass
    text = re.sub(r"AIza[0-9A-Za-z_\-]{10,}|Bearer\s+\S+", "<隱藏>", str(cause)).strip()
    text = re.sub(r"\s+", " ", text)
    if "DEADLINE_EXCEEDED" in text or "timed out" in text.lower():
        return "timeout"
    return (type(cause).__name__ + ":" + text[:40]) if text else type(cause).__name__


def format_llm_reasons(table):
    return "、".join("{}×{}".format(k, v) for k, v in sorted(table.items(), key=lambda kv: -kv[1]))


# ---------------------------------------------------------------------------
# 抓取與解析
# ---------------------------------------------------------------------------

def fetch_url(url, timeout=FETCH_TIMEOUT):
    """抓取 URL，回傳 bytes；失敗丟例外（由呼叫端決定要不要繼續）"""
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def strip_html(text):
    """去掉描述裡的 HTML 標籤與多餘空白（自由時報/ETtoday 描述常夾 <img> 等）"""
    text = re.sub(r"<[^>]+>", " ", text or "")
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def parse_rss(data):
    """
    解析 RSS 2.0，回傳 item 的 dict 清單。
    CDATA 由 ElementTree 自動處理（自由時報 title 是 CDATA 也沒問題）。
    """
    root = ET.fromstring(data)
    items = []
    for item in root.iter("item"):
        def text_of(tag):
            node = item.find(tag)
            return (node.text or "").strip() if node is not None and node.text else ""

        items.append({
            "title": strip_html(text_of("title")),
            "description": strip_html(text_of("description")),
            "link": text_of("link"),
            "guid": text_of("guid"),
            "pubDate": text_of("pubDate"),
        })
    # 沒有標題的 item（如 UDN 對海外 IP 的空殼 feed）直接濾掉，不進 seen 也不進分類
    return [i for i in items if i["title"]]


ATOM_NS = {"atom": "http://www.w3.org/2005/Atom"}


def parse_atom(data):
    """解析 Atom feed（公視用），輸出與 parse_rss 相同形狀的 dict 清單。"""
    root = ET.fromstring(data)
    items = []
    for entry in root.findall("atom:entry", ATOM_NS):
        def text_of(tag):
            node = entry.find(f"atom:{tag}", ATOM_NS)
            return (node.text or "").strip() if node is not None and node.text else ""

        # Atom 的 link 是屬性不是內文；rel 省略或 alternate 才是文章網址
        link = ""
        for node in entry.findall("atom:link", ATOM_NS):
            if node.get("rel") in (None, "alternate"):
                link = node.get("href") or ""
                break
        items.append({
            "title": strip_html(text_of("title")),
            "description": strip_html(text_of("summary") or text_of("content")),
            "link": link,
            "guid": text_of("id"),
            "pubDate": text_of("published") or text_of("updated"),
        })
    return [i for i in items if i["title"]]


TVBS_ISLAND_RE = re.compile(r'<astro-island\b[^>]*?\bcomponent-url="[^"]*RealTimeArticle[^"]*"[^>]*?\bprops="([^"]*)"')


def _astro_unwrap(v):
    """Astro island props 的序列化格式：純量包成 [0, value]、陣列包成 [1, [...]]。"""
    if isinstance(v, list) and len(v) == 2 and v[0] in (0, 1):
        return _astro_unwrap(v[1]) if v[0] == 0 else [_astro_unwrap(x) for x in v[1]]
    if isinstance(v, dict):
        return {k: _astro_unwrap(x) for k, x in v.items()}
    return v


def parse_tvbs_local(html):
    """
    TVBS 沒有可用的公開 RSS，直接爬 /local 分類頁。網站 2026-10 改為 Astro 架構：
    「社會即時新聞」清單不再是 <li><a href="/local/..."> 純 HTML，而是每則一個
    <astro-island component-url=".../RealTimeArticle...js" props="{HTML 跳脫的 JSON}">，
    props 內含 articleId/title/articleUrl/firstParagraph/publishedAt(epoch 秒)。
    這裡解析這些 island 的 props，輸出與 parse_rss 相同形狀的 dict 清單，
    讓下游分類/去重/LLM 完全共用一套邏輯。
    """
    import html as html_lib
    items = []
    seen = set()
    for m in TVBS_ISLAND_RE.finditer(html):
        try:
            props = json.loads(html_lib.unescape(m.group(1)))
            art = _astro_unwrap(props.get("article"))
        except (ValueError, AttributeError):
            continue
        if not isinstance(art, dict):
            continue
        article_id = str(art.get("articleId") or "")
        title = strip_html(art.get("title") or "").strip()
        if not article_id or not title or article_id in seen:
            continue
        seen.add(article_id)
        ts = art.get("publishedAt")
        if isinstance(ts, (int, float)) and ts > 0:
            pub_date = datetime.fromtimestamp(ts, TZ_TAIPEI).isoformat()
        else:
            pub_date = datetime.now(TZ_TAIPEI).isoformat()
        items.append({
            "title": title,
            "description": strip_html(art.get("firstParagraph") or "").strip(),
            "link": art.get("articleUrl") or f"https://news.tvbs.com.tw/local/{article_id}",
            "guid": article_id,
            "pubDate": pub_date,
        })
    return items


def canonical_media_name(name):
    """Google 的媒體名 → App 一線媒體名單用的名稱；不在表內就維持原名（App 視為持續確認中）"""
    name = (name or "").replace("、", " ").strip()
    if name.upper() == "UDN":  # 只認完全相等，避免「udn房地產」之類子站被誤升為一線媒體
        return "聯合報"
    for key, canonical in GOOGLE_MEDIA_CANONICAL:
        if key.lower() in name.lower():
            return canonical
    return name[:30]


def split_google_title(title, source=""):
    """
    Google 新聞標題「標題 - 媒體名」→ (乾淨標題, 媒體名)。
    優先用 <source> 的媒體名去掉尾巴；沒有 <source> 才退回以最後一個「 - 」切開。
    """
    title = (title or "").strip()
    source = (source or "").strip()
    if source and title.endswith(" - " + source):
        return title[: -len(source) - 3].strip(), source
    if not source and " - " in title:
        head, tail = title.rsplit(" - ", 1)
        if head.strip() and 0 < len(tail.strip()) <= 30:
            return head.strip(), tail.strip()
    return title, source


def parse_google_news_rss(data):
    """
    解析 Google 新聞 RSS，輸出與 parse_rss 相同形狀，另帶 source_name（已正規化的媒體名）。
    description 是「相關報導」的 HTML 清單，不是內文，一律清空，避免誤觸規則詞。
    """
    root = ET.fromstring(data)
    items = []
    for item in root.iter("item"):
        def text_of(tag):
            node = item.find(tag)
            return (node.text or "").strip() if node is not None and node.text else ""

        title, source = split_google_title(strip_html(text_of("title")), text_of("source"))
        items.append({
            "title": title,
            "description": "",
            "link": text_of("link"),
            "guid": text_of("guid"),
            "pubDate": text_of("pubDate"),
            "source_name": canonical_media_name(source) or "Google新聞",
        })
    return [i for i in items if i["title"]]


def ptt_clean_title(title):
    """PTT 標題只收［爆卦］或［新聞］開頭（Re: 回文自然排除）；回傳去掉標籤的標題，否則 None"""
    m = PTT_TITLE_RE.match(title or "")
    return m.group(2).strip() if m else None


def stable_id(item):
    """以 guid（優先）或 link 產生穩定雜湊 id"""
    key = item.get("guid") or item.get("link") or item.get("title", "")
    return hashlib.sha1(key.encode("utf-8")).hexdigest()[:16]


def parse_pubdate_datetime(s):
    """RFC 822（RSS）或 ISO8601（Atom）→ 台北時區 datetime；解析失敗回 None。"""
    try:
        dt = email.utils.parsedate_to_datetime(s)
    except Exception:
        try:
            dt = datetime.fromisoformat((s or "").replace("Z", "+00:00"))
        except Exception:
            return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=TZ_TAIPEI)
    return dt.astimezone(TZ_TAIPEI)


def parse_pubdate(s):
    """新聞時間統一成台北時區 ISO8601；無法解析時保守使用抓取當下。"""
    dt = parse_pubdate_datetime(s) or datetime.now(TZ_TAIPEI)
    return dt.isoformat()


def prepare_feed_items(items, max_items=DEFAULT_FEED_ITEM_LIMIT, now=None):
    """
    在分類前先做新鮮度與數量閘門。

    回傳 (可處理項目, 指標)。無法解析時間的項目仍保留，但受 max_items 限制；
    明確超過 24 小時或比現在超前 2 小時以上的資料直接丟棄，避免舊聞/壞時間觸發提醒。
    """
    now = now or datetime.now(TZ_TAIPEI)
    cutoff = now - timedelta(hours=NEWS_MAX_AGE_HOURS)
    future_limit = now + timedelta(hours=2)
    eligible = []
    stale_dropped = 0
    future_dropped = 0

    for item in items:
        published = parse_pubdate_datetime(item.get("pubDate"))
        if published is not None and published < cutoff:
            stale_dropped += 1
            continue
        if published is not None and published > future_limit:
            future_dropped += 1
            continue
        eligible.append(item)

    limit = max(1, int(max_items))
    capped_dropped = max(0, len(eligible) - limit)
    return eligible[:limit], {
        "rawItems": len(items),
        "eligibleItems": min(len(eligible), limit),
        "staleDropped": stale_dropped,
        "futureDropped": future_dropped,
        "cappedDropped": capped_dropped,
    }


# ---------------------------------------------------------------------------
# 縣市抽取
# ---------------------------------------------------------------------------

def county_from_cna_dateline(description):
    """
    從中央社電頭抽縣市（規則路徑的金礦）。
    例：「（中央社記者王淑芬高雄16日電）」→ 片段「王淑芬高雄」→ 尾端命中「高雄」→ 高雄市
    """
    m = CNA_DATELINE_RE.search(description or "")
    if not m:
        return None
    fragment = m.group(1)  # 記者名（可無）＋地名
    for token in COUNTY_TOKENS:  # 長 token 優先（新竹市 > 新竹）
        if fragment.endswith(token):
            return COUNTY_NORMALIZE[token]
    return None


def county_from_text(text):
    """
    從標題/描述掃縣市 token（非中央社來源的退路）。
    取最靠前的命中；同位置長 token 優先。
    """
    best_pos, best_token = None, None
    for token in COUNTY_TOKENS:
        pos = (text or "").find(token)
        if pos == -1:
            continue
        if best_pos is None or pos < best_pos:
            best_pos, best_token = pos, token
    return COUNTY_NORMALIZE[best_token] if best_token else None


def district_from_text(text):
    """
    縣市 token 掃不到時的最後防線：從標題/描述掃行政區名，反查所屬縣市。
    例：「文山區KTV惡火」沒寫「台北市」→ 命中「文山區」→ 回傳 (文山區, 台北市)。

    取最靠前的命中；同位置長 token 優先（DISTRICT_TOKENS 已由長到短排序）。
    同名行政區（中正區、東區…）已在 DISTRICT_TO_COUNTY 建表時排除，這裡查不到
    就是查不到，回傳 (None, None)——寧可讓 App 端因缺縣市丟棄這則，也不要猜錯地圖位置。
    """
    best_pos, best_token = None, None
    text = scrub_non_place(text or "")
    for token in DISTRICT_TOKENS:
        pos = (text or "").find(token)
        if pos == -1:
            continue
        if best_pos is None or pos < best_pos:
            best_pos, best_token = pos, token
    if best_token is None:
        return None, None
    return best_token, DISTRICT_TO_COUNTY[best_token]


# ---------------------------------------------------------------------------
# 行政區抽取強化版（2026-08-02 規則優先＋LLM補位改造）
# ---------------------------------------------------------------------------
#
# district_from_text() 只比對完整行政區名（「文山區」），但新聞標題常簡寫成
# 「高雄仁武車禍」「台南新市火警」而省略「區/鄉/鎮/市」尾字，完整名比對抓不到。
# 這裡另外建一張「去後綴索引」（仁武區→仁武）補上這個缺口；規格與理由見下方
# 各函式的 docstring。實測行政區覆蓋率從 13/83 提升到 25/83（誤判 2 則）。

_DISTRICT_SUFFIXES = ("區", "鄉", "鎮", "市")


def _build_district_stripped_index():
    """
    建立「去後綴索引」：把 DISTRICT_TO_COUNTY（347 筆）行政區名尾端的
    「區/鄉/鎮/市」拿掉當 key（仁武區→仁武、水上鄉→水上）。

    兩條防呆規則，寧可少收也不要製造假地名：
    - 去後綴後長度 < 2 的一律跳過（例如「中區」若被收進表會變成「中」，
      這種單字 key 太容易在無關詞裡亂命中）。
    - 去後綴後撞名的一律排除、不猜（例如「仁愛區」「仁愛鄉」都會變成「仁愛」，
      無法判斷是哪個縣市，寧可查不到也不要猜錯）。
    """
    grouped = {}
    for full, county in DISTRICT_TO_COUNTY.items():
        stripped = full[:-1] if full[-1] in _DISTRICT_SUFFIXES else full
        grouped.setdefault(stripped, []).append((full, county))
    return {
        stripped: pairs[0]
        for stripped, pairs in grouped.items()
        if len(stripped) >= 2 and len(pairs) == 1
    }


# stripped 行政區名 → (完整行政區名, 縣市)；已排除太短與撞名的 key。
DISTRICT_STRIPPED_INDEX = _build_district_stripped_index()

# 完整名＋去後綴別名合併成一張比對表（別名若剛好與某完整名字串相同，以完整名
# 的對照為準，用 setdefault 避免覆蓋），供 district_from_text_v2 使用；
# 依 token 長度由長到短排序，確保同一位置命中時「新竹市」優先於「新竹」
# （長詞優先，也讓完整名優先於自己的去後綴別名）。
DISTRICT_MATCH_TABLE = {}
for _full, _county in DISTRICT_TO_COUNTY.items():
    DISTRICT_MATCH_TABLE[_full] = (_full, _county)
for _stripped, (_full, _county) in DISTRICT_STRIPPED_INDEX.items():
    DISTRICT_MATCH_TABLE.setdefault(_stripped, (_full, _county))
DISTRICT_MATCH_TOKENS = sorted(DISTRICT_MATCH_TABLE.keys(), key=len, reverse=True)

# 去後綴別名多是兩字通名，很容易嵌在河川／山岳／道路的名字裡：
# 實測「花蓮萬里溪堰塞湖」命中新北「萬里」而把事件釘到一百多公里外。
# 命中後若緊接下列地物字，一律不採信——完整行政區名後面不會接這些字
#（沒有「萬里區溪」這種地名），所以這條規則不會誤傷正常命中。
DISTRICT_FALSE_TAIL = set("溪川江河山嶺峰湖潭埤圳港灣島嶼路街道橋隧線")

# 非地名詞表：比對行政區前先整段剝除。這些詞裡藏著行政區名的子字串，會把國外或
# 無關新聞釘到台灣某區（2026-10 實測的兩個誤判）：
#   - 「東太平洋／太平洋海嘯」含「太平」→ 台中市太平區
#   - 「法新社／中新社」含「新社」→ 台中市新社區（標題沒事，是內文的通訊社署名）
# 通訊社、海洋名都不可能是台灣行政區，剝除不會誤傷正常地名（「太平區」「新社區」
# 本身不受影響：只剝「太平洋」「法新社」這種完整詞，不剝「太平」「新社」）。
NON_PLACE_TERMS = sorted([
    "太平洋", "大西洋", "印度洋", "北冰洋", "南冰洋",
    "法新社", "中新社", "新華社", "共同社", "美聯社", "路透社", "彭博社", "合眾社",
    "塔斯社", "俄新社", "安納杜魯", "半島電視台",
    "中國信託", "中國時報", "中國石油", "中國鋼鐵", "中國醫藥", "中國文化",
], key=len, reverse=True)


_NON_PLACE_RE = re.compile("(?:" + "|".join(map(re.escape, NON_PLACE_TERMS)) + ")(?!區)")


def scrub_non_place(text):
    """剝除非地名詞（見 NON_PLACE_TERMS），供行政區比對使用"""
    # 後面緊接「區」的不剝：「台中新社區」含「中新社」，那是真的行政區（新社區）
    return _NON_PLACE_RE.sub(" ", text)


def _county_core(county):
    """縣市全名去掉尾字「市」或「縣」，供從文本剝除縣市核心字使用（彰化縣→彰化）"""
    if not county:
        return None
    if county[-1] in ("市", "縣"):
        return county[:-1]
    return county


def district_from_text_v2(text, county=None):
    """
    強化版行政區抽取（比 district_from_text 多三件事）：

    1. 用去後綴索引（DISTRICT_STRIPPED_INDEX），讓「高雄仁武車禍」這種簡寫
       也能命中（仁武 → 仁武區 → 高雄市）。
    2. 若呼叫端已經知道 county（例如標題裡已掃到「彰化」→ 彰化縣），比對前
       先把該縣市的核心字從文本剝除，再做行政區比對。理由：實測「彰化秀水
       翁失聯」會先撞到「彰化」（彰化市的去後綴別名，在文本裡位置比「秀水」
       更靠前）而誤判成彰化市，正確答案是後面的「秀水鄉」——縣治所在地與
       縣市同名（彰化市/彰化縣、南投市/南投縣…）是主要誤判來源，剝除後
       「秀水」才會浮上來。
    3. 若已知 county，比對到的行政區必須屬於同一個 county，否則不採信、
       整個回傳 (None, None)——寧可少填一個欄位，也不要讓地圖釘錯位置
       （實測加了這條約束後，誤判從 10 則降到 2 則）。

    取「最靠前」命中；同位置由長到短比對（DISTRICT_MATCH_TOKENS 已排序），
    長 token 優先。抓不到、或抓到但與已知 county 衝突，一律回傳 (None, None)，
    呼叫端要自行保留原本已知的 county，不要拿這裡的 None 去覆蓋它。
    """
    haystack = scrub_non_place(text or "")
    core = _county_core(county)
    if core:
        haystack = haystack.replace(core, "")

    best_pos, best_token = None, None
    for token in DISTRICT_MATCH_TOKENS:
        pos = haystack.find(token)
        while pos != -1:
            # 緊接地物字的命中是假的（萬里溪／大同路／信義街…），往後再找同一個
            # token 的下一個出現位置——同一篇報導裡地名常同時以河川名與行政區名
            # 出現，只看第一個位置會整個放棄這個 token
            if haystack[pos + len(token): pos + len(token) + 1] in DISTRICT_FALSE_TAIL:
                pos = haystack.find(token, pos + 1)
                continue
            break
        if pos == -1:
            continue
        if best_pos is None or pos < best_pos:
            best_pos, best_token = pos, token
    if best_token is None:
        return None, None

    full_district, matched_county = DISTRICT_MATCH_TABLE[best_token]
    if county and matched_county != county:
        return None, None
    return full_district, matched_county


# ---------------------------------------------------------------------------
# 摘要與詳述（2026-08-02 起改規則式產生，不再呼叫 AI）
# ---------------------------------------------------------------------------
#
# 版權與 App Store 第三方內容審查的紅線：這支爬蟲只能把新聞當「事故發生的
# 訊號」，不能變成新聞轉載服務。summary 直接用原標題（App 端 NewsEventProvider
# 本來就是 summary 缺值時退回 title，這裡直接填也不影響既有行為）；detail
# 只取新聞原文描述的前 120 字摘錄，超過就截斷加「…」，絕對不可輸出全文、
# 也不做任何 AI 改寫／二次創作——這是規則路徑（這裡）與 LLM 路徑
# （build_llm_prompt 已移除 summary/detail 的產出需求）共同遵守的長度上限。
NEWS_DETAIL_EXCERPT_CHARS = 120


# ---------------------------------------------------------------------------
# 國外事件排除（2026-10 實測：巴拿馬地震、杜拜機師被釘到台中市）
# ---------------------------------------------------------------------------
# 規則：標題出現國外國名／大城市，或標題帶「| 國際」頻道標記，
# 而且標題沒有台灣縣市 token、描述也沒有縣市「全名」（台中市／宜蘭縣…）→ 判定為
# 非台灣事件，不輸出。有台灣縣市就保留（「日本遊客在台中車禍」）。
# 描述只認縣市全名，是因為「台北時間」「台灣」這類詞常出現在國外新聞內文。
FOREIGN_PLACES = [
    "日本", "東京", "大阪", "京都", "北海道", "沖繩", "福島", "韓國", "南韓", "北韓", "首爾", "釜山",
    "中國大陸", "中國", "大陸", "北京", "上海", "廣州", "深圳", "重慶", "成都", "香港", "澳門", "新疆", "西藏",
    "美國", "紐約", "洛杉磯", "舊金山", "加州", "德州", "佛州", "華盛頓", "夏威夷", "阿拉斯加",
    "加拿大", "墨西哥", "巴拿馬", "哥斯大黎加", "瓜地馬拉", "宏都拉斯", "古巴", "海地", "牙買加",
    "秘魯", "智利", "巴西", "阿根廷", "哥倫比亞", "委內瑞拉", "厄瓜多", "玻利維亞",
    "英國", "倫敦", "法國", "巴黎", "德國", "柏林", "義大利", "羅馬", "西班牙", "葡萄牙", "希臘",
    "荷蘭", "比利時", "瑞士", "瑞典", "挪威", "芬蘭", "丹麥", "波蘭", "奧地利", "捷克", "匈牙利",
    "俄羅斯", "烏克蘭", "莫斯科", "基輔", "土耳其", "伊朗", "伊拉克", "以色列", "巴勒斯坦", "加薩",
    "黎巴嫩", "敘利亞", "葉門", "約旦", "沙烏地", "阿聯", "杜拜", "阿布達比", "卡達", "科威特", "特拉維夫",
    "埃及", "南非", "奈及利亞", "肯亞", "衣索比亞", "摩洛哥", "非洲", "歐洲", "中東", "南美", "中美洲", "北美",
    "印度", "巴基斯坦", "孟加拉", "尼泊爾", "斯里蘭卡", "阿富汗", "泰國", "曼谷", "越南", "河內", "胡志明",
    "菲律賓", "馬尼拉", "印尼", "雅加達", "峇里", "馬來西亞", "吉隆坡", "新加坡", "緬甸", "柬埔寨", "寮國",
    "美軍", "全美", "麻州", "佛蒙特", "胡德堡", "五角大樓", "萬斯", "戰爭部", "琉球", "河北", "英男", "法輪功", "賓州", "俄亥俄", "密西根", "紐澤西", "德克薩斯", "芝加哥", "費城", "邁阿密", "底特律", "休士頓", "亞特蘭大", "拉斯維加斯", "西雅圖", "波特蘭", "奧蘭多", "曼徹斯特", "悉尼", "布里斯本", "德里", "孟買", "喀布爾",
    "蒙古", "澳洲", "雪梨", "墨爾本", "紐西蘭", "巴布亞", "斐濟", "東加", "萬那杜",
]
# 「國際」頻道標記：只認明確的頻道格式，不認「國際機場」「國際賽事」這類內文用詞
FOREIGN_CHANNEL_RE = re.compile(r"[|｜]\s*(?:國際|全球|世界)\s*$|^\s*[【\[]?(?:國際|全球)[】\]|｜／:：]")
_FOREIGN_ADJECTIVE_RE = re.compile(
    "(?:" + "|".join(map(re.escape, FOREIGN_PLACES)) + ")(?:籍|僑|裔|料理|移工|外勞|看護|配偶|新娘|新住民|留學生)")
COUNTY_FULL_NAMES = sorted(set(COUNTY_NORMALIZE.values()), key=len, reverse=True)


def is_foreign_news(title, description=""):
    """True＝判定為非台灣事件（見上方規則說明）"""
    title = title or ""
    if county_from_text(scrub_non_place(title)):
        return False
    desc_full = scrub_non_place(description or "")
    if any(name in desc_full for name in COUNTY_FULL_NAMES):
        return False
    if FOREIGN_CHANNEL_RE.search(title):
        return True
    # 國外地名只看標題（描述常提到「越南籍移工」這類台灣事件的當事人國籍）；
    # 再剝掉「越南籍／日本料理／泰籍移工」這類形容在台人事物的用法
    head = scrub_non_place(title)
    head = _FOREIGN_ADJECTIVE_RE.sub(" ", head)
    return any(place in head for place in FOREIGN_PLACES)


def build_detail_excerpt(description):
    """新聞原文摘錄：只取前 120 字，超過就截斷加「…」；描述為空回傳 None。"""
    text = (description or "").strip()
    if not text:
        return None
    if len(text) <= NEWS_DETAIL_EXCERPT_CHARS:
        return text
    return text[:NEWS_DETAIL_EXCERPT_CHARS] + "…"


# ---------------------------------------------------------------------------
# 第一段：規則式分類（永遠執行）
# ---------------------------------------------------------------------------

def rules_classify(title, description):
    """
    回傳 (是否事故, category, 命中詞)。
    - 排除詞只看標題（內文常出現「起訴」等字眼，看內文會誤殺真事故）
    - 納入詞看標題＋描述
    """
    for word in EXCLUDE_WORDS:
        if word in title:
            return False, None, word

    if is_pure_fraud(title):
        return False, None, "純詐騙"

    haystack = title + " " + description
    for word in CRIME_PRIORITY_TERMS:
        if word in title:
            return True, "公共安全", word
    for category, words in INCLUDE_CATEGORIES:
        for word in words:
            if word not in haystack:
                continue
            # 誤判防護：命中的若全是慣用語（撞名/砍價…）就不算
            guards = FALSE_HIT_GUARDS.get(word)
            if guards:
                stripped = haystack
                for g in guards:
                    stripped = stripped.replace(g, "")
                if word not in stripped:
                    continue
            # 公共安全的泛用詞（封閉／疏散／警戒／隨機…）只認標題：Google 的描述是
            # 一串相關標題，國慶車潮稿的描述就曾夾帶「封閉」而被歸成公共安全。
            if category == "公共安全" and word not in title and word not in CRIME_DESC_OK_TERMS:
                continue
            if category == "交通" and word == "酒駕" and any(
                term in title for term in TRAFFIC_AFTERCARE_TERMS
            ):
                return False, None, "酒駕事後處置"
            return True, category, word

    return False, None, None


# ---------------------------------------------------------------------------
# 第二段：LLM 分類（有 AI_PROXY_TOKEN 才跑）
# ---------------------------------------------------------------------------

# 2026-08-02 規則優先＋LLM補位改造：不再要求 LLM 產出 summary/detail。
# 原因有二：① 版權／App Store 第三方內容審查紅線——摘要與詳述改由規則式
# 產生（原標題＋原文前 120 字摘錄，見 build_detail_excerpt），不讓 LLM 對
# 新聞內容做二次創作或整篇改寫；② 少兩個輸出欄位能明顯縮短回應 token，
# 對「LLM 只補地點缺口」這種講求速度的呼叫更划算。
LLM_PROMPT_TEMPLATE = """你是災害事故新聞分類器。判斷下面這則台灣新聞是否為「正在發生或剛發生的現場事故/災害」（司法判決、起訴、政治攻防、紀念活動都不算）。

標題：{title}
描述：{description}

只回覆一行 JSON，不要任何其他文字，格式：
{{"is_incident": true或false, "county": "縣市全名（如 台中市）或null", "district": "鄉鎮市區或null", "place": "地點簡述或null", "category": "火災|交通|天災|公共安全|民生 其中之一", "confidence": 0到1的數字, "severity": "high或medium或low 其中之一（high＝立即致命或需疏散，如大火困人、氣爆、槍擊或天災正在發生；medium＝局部危險需注意；low＝輕微、已受控或影響很小）", "is_ongoing": true或false（事件是否仍在發生或剛發生、需要人即時反應；已撲滅／已獲救／已落幕／純事後回顧或司法後續都為 false；嫌犯已逮捕／落網／到案／移送、通緝公告也為 false；純金錢詐騙無人身威脅則 is_incident 為 false）}}"""


class PaidGeminiUnavailable(RuntimeError):
    """付費路徑未啟用、無金鑰、達上限或呼叫失敗；訊息絕不包含金鑰。"""


class FreeGeminiUnavailable(RuntimeError):
    """免費路徑未啟用、無金鑰、達呼叫上限或呼叫失敗；訊息絕不包含金鑰。"""


def build_llm_prompt(title, description):
    """限制送進任何 LLM 的文字量，讓 token 成本與最壞情況都具有上界。"""
    return LLM_PROMPT_TEMPLATE.format(
        title=(title or "")[:LLM_MAX_TITLE_CHARS],
        description=(description or "")[:LLM_MAX_DESCRIPTION_CHARS],
    )


def paid_month_key(now=None):
    now = now or datetime.now(TZ_TAIPEI)
    return now.strftime("%Y-%m")


def free_day_key(now=None):
    now = now or datetime.now(TZ_TAIPEI)
    return now.strftime("%Y-%m-%d")


def load_free_keys():
    """只從獨立 600 權限檔讀免費 Gemini key，絕不混入付費 key 檔。"""
    if not os.path.isfile(FREE_GEMINI_KEYS_PATH):
        return []
    try:
        mode = os.stat(FREE_GEMINI_KEYS_PATH).st_mode & 0o777
        if mode & 0o077:
            raise FreeGeminiUnavailable("免費 Gemini 金鑰檔權限必須是 600")
        with open(FREE_GEMINI_KEYS_PATH, encoding="utf-8") as file:
            keys = [line.strip() for line in file if line.strip()]
    except OSError as error:
        raise FreeGeminiUnavailable("無法讀取免費 Gemini 金鑰檔") from error
    valid = [key for key in keys if key.startswith("AQ.")]
    if len(valid) != len(keys):
        raise FreeGeminiUnavailable("免費 Gemini 金鑰檔含有非 AQ 格式資料")
    return valid


def _read_free_usage_unlocked():
    if not os.path.isfile(FREE_GEMINI_USAGE_PATH):
        return {"days": {}}
    try:
        with open(FREE_GEMINI_USAGE_PATH, encoding="utf-8") as file:
            value = json.load(file)
        return value if isinstance(value, dict) and isinstance(value.get("days"), dict) else {"days": {}}
    except (OSError, ValueError):
        # 只要本機計數器失效就停用免費層，避免失控重試或誤以為仍有額度。
        raise FreeGeminiUnavailable("免費 Gemini 用量帳本無法讀取")


def _write_free_usage_unlocked(usage):
    directory = os.path.dirname(os.path.abspath(FREE_GEMINI_USAGE_PATH))
    os.makedirs(directory, exist_ok=True)
    temp_path = FREE_GEMINI_USAGE_PATH + ".tmp"
    with open(temp_path, "w", encoding="utf-8") as file:
        json.dump(usage, file, ensure_ascii=False, indent=2)
        file.flush()
        os.fsync(file.fileno())
    os.chmod(temp_path, 0o600)
    os.replace(temp_path, FREE_GEMINI_USAGE_PATH)


def with_free_usage_lock(callback):
    lock_path = FREE_GEMINI_USAGE_PATH.rsplit(".", 1)[0] + ".lock"
    directory = os.path.dirname(os.path.abspath(lock_path))
    os.makedirs(directory, exist_ok=True)
    with open(lock_path, "a+", encoding="utf-8") as lock_file:
        os.chmod(lock_path, 0o600)
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        return callback()


def free_request_reservation(key_count):
    """呼叫前先記一筆免費額度，程序中斷也不會靠重跑穿透每日上限。"""
    day = free_day_key()

    def reserve():
        usage = _read_free_usage_unlocked()
        row = usage["days"].setdefault(day, {"calls": 0, "reservedFailures": 0})
        calls = int(row.get("calls") or 0)
        if calls >= FREE_GEMINI_DAILY_CALL_LIMIT:
            raise FreeGeminiUnavailable("免費 Gemini 已達本機每日呼叫上限")
        row["calls"] = calls + 1
        row["reservedFailures"] = int(row.get("reservedFailures") or 0) + 1
        _write_free_usage_unlocked(usage)
        return day, calls % key_count

    return with_free_usage_lock(reserve)


def reconcile_free_usage(day):
    def reconcile():
        usage = _read_free_usage_unlocked()
        row = usage["days"].setdefault(day, {"calls": 0, "reservedFailures": 0})
        row["reservedFailures"] = max(0, int(row.get("reservedFailures") or 0) - 1)
        _write_free_usage_unlocked(usage)

    with_free_usage_lock(reconcile)


def free_gemini_status():
    status = {
        "enabled": FREE_GEMINI_ENABLED,
        "model": FREE_GEMINI_MODEL,
        "dailyCallLimit": FREE_GEMINI_DAILY_CALL_LIMIT,
        "callsToday": 0,
    }
    try:
        usage = _read_free_usage_unlocked()
        row = usage["days"].get(free_day_key(), {})
        status["callsToday"] = int(row.get("calls") or 0)
    except FreeGeminiUnavailable:
        status["ledgerError"] = True
    return status


def call_free_gemini(prompt):
    """只使用獨立免費池，額度或網路失敗時交給下一層 fallback，絕不改用付費 key。"""
    if not FREE_GEMINI_ENABLED:
        raise FreeGeminiUnavailable("免費 Gemini 未啟用")
    if FREE_GEMINI_DAILY_CALL_LIMIT <= 0:
        raise FreeGeminiUnavailable("免費 Gemini 每日呼叫上限為 0")
    keys = load_free_keys()
    if not keys:
        raise FreeGeminiUnavailable("沒有可用的免費 Gemini 金鑰")

    day, key_index = free_request_reservation(len(keys))
    body = json.dumps({
        "contents": [{"role": "user", "parts": [{"text": prompt}]}],
        "generationConfig": {
            "temperature": 0,
            "maxOutputTokens": FREE_GEMINI_MAX_OUTPUT_TOKENS,
            "responseMimeType": "application/json",
            "thinkingConfig": {
                "thinkingBudget": FREE_GEMINI_THINKING_BUDGET,
            },
        },
    }).encode("utf-8")
    endpoint = (
        "https://generativelanguage.googleapis.com/v1beta/models/"
        + urllib.parse.quote(FREE_GEMINI_MODEL, safe="-._")
        + ":generateContent"
    )
    request = urllib.request.Request(
        endpoint,
        data=body,
        headers={
            "x-goog-api-key": keys[key_index],
            "Content-Type": "application/json",
            "User-Agent": USER_AGENT,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=LLM_TIMEOUT) as response:
            result = json.loads(response.read().decode("utf-8"))
    except Exception as error:
        # 失敗請求保留額度，避免 quota/網路錯誤造成無限重試。
        raise FreeGeminiUnavailable("免費 Gemini 呼叫失敗（{}）".format(describe_llm_error(error))) from error

    try:
        text = result["candidates"][0]["content"]["parts"][0]["text"]
    except (KeyError, IndexError, TypeError) as error:
        raise FreeGeminiUnavailable("免費 Gemini 回應缺少文字") from error
    reconcile_free_usage(day)
    return text


def load_paid_keys():
    """只從獨立 600 權限檔讀 Gemini 金鑰；不接受環境變數內混放的 key pool。"""
    if not os.path.isfile(PAID_GEMINI_KEYS_PATH):
        return []
    try:
        mode = os.stat(PAID_GEMINI_KEYS_PATH).st_mode & 0o777
        if mode & 0o077:
            raise PaidGeminiUnavailable("付費 Gemini 金鑰檔權限必須是 600")
        with open(PAID_GEMINI_KEYS_PATH, encoding="utf-8") as file:
            keys = [line.strip() for line in file if line.strip()]
    except OSError as error:
        raise PaidGeminiUnavailable("無法讀取付費 Gemini 金鑰檔") from error
    valid = [key for key in keys if key.startswith("AQ.")]
    if len(valid) != len(keys):
        raise PaidGeminiUnavailable("付費 Gemini 金鑰檔含有非 AQ 格式資料")
    return valid


def _read_usage_unlocked():
    if not os.path.isfile(PAID_GEMINI_USAGE_PATH):
        return {"months": {}}
    try:
        with open(PAID_GEMINI_USAGE_PATH, encoding="utf-8") as file:
            value = json.load(file)
        return value if isinstance(value, dict) and isinstance(value.get("months"), dict) else {"months": {}}
    except (OSError, ValueError):
        # 計費帳本壞掉時必須 fail closed；視為已達上限，而不是歸零繼續花錢。
        raise PaidGeminiUnavailable("付費 Gemini 用量帳本無法讀取")


def _write_usage_unlocked(usage):
    directory = os.path.dirname(os.path.abspath(PAID_GEMINI_USAGE_PATH))
    os.makedirs(directory, exist_ok=True)
    temp_path = PAID_GEMINI_USAGE_PATH + ".tmp"
    with open(temp_path, "w", encoding="utf-8") as file:
        json.dump(usage, file, ensure_ascii=False, indent=2)
        file.flush()
        os.fsync(file.fileno())
    os.chmod(temp_path, 0o600)
    os.replace(temp_path, PAID_GEMINI_USAGE_PATH)


def with_paid_usage_lock(callback):
    lock_path = PAID_GEMINI_USAGE_PATH.rsplit(".", 1)[0] + ".lock"
    directory = os.path.dirname(os.path.abspath(lock_path))
    os.makedirs(directory, exist_ok=True)
    with open(lock_path, "a+", encoding="utf-8") as lock_file:
        os.chmod(lock_path, 0o600)
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        return callback()


def paid_request_reservation(prompt, key_count):
    """
    呼叫前先以「UTF-8 byte 數視為 input token 上界＋最大 output token」預扣。
    因此即使程序在回應後 crash，也只會把額度算多、不會漏算並穿透月費上限。
    """
    estimated_input_tokens = max(1, len(prompt.encode("utf-8")))
    reserved_cost = (
        estimated_input_tokens * PAID_GEMINI_INPUT_USD_PER_M
        + PAID_GEMINI_MAX_OUTPUT_TOKENS * PAID_GEMINI_OUTPUT_USD_PER_M
    ) / 1_000_000
    month = paid_month_key()

    def reserve():
        usage = _read_usage_unlocked()
        row = usage["months"].setdefault(month, {
            "estimatedCostUSD": 0.0,
            "inputTokens": 0,
            "outputTokens": 0,
            "calls": 0,
            "reservedFailures": 0,
        })
        current = float(row.get("estimatedCostUSD") or 0)
        if current + reserved_cost > PAID_GEMINI_MONTHLY_LIMIT_USD:
            raise PaidGeminiUnavailable("付費 Gemini 已達本機月費硬上限")
        call_index = int(row.get("calls") or 0)
        row["estimatedCostUSD"] = round(current + reserved_cost, 8)
        row["calls"] = call_index + 1
        row["reservedFailures"] = int(row.get("reservedFailures") or 0) + 1
        _write_usage_unlocked(usage)
        return month, call_index % key_count, reserved_cost

    return with_paid_usage_lock(reserve)


def reconcile_paid_usage(month, reserved_cost, input_tokens, output_tokens):
    actual_cost = (
        input_tokens * PAID_GEMINI_INPUT_USD_PER_M
        + output_tokens * PAID_GEMINI_OUTPUT_USD_PER_M
    ) / 1_000_000

    def reconcile():
        usage = _read_usage_unlocked()
        row = usage["months"].setdefault(month, {})
        current = float(row.get("estimatedCostUSD") or 0)
        row["estimatedCostUSD"] = round(max(0.0, current - reserved_cost + actual_cost), 8)
        row["inputTokens"] = int(row.get("inputTokens") or 0) + input_tokens
        row["outputTokens"] = int(row.get("outputTokens") or 0) + output_tokens
        row["reservedFailures"] = max(0, int(row.get("reservedFailures") or 0) - 1)
        _write_usage_unlocked(usage)

    with_paid_usage_lock(reconcile)


def paid_gemini_status():
    status = {
        "enabled": PAID_GEMINI_ENABLED,
        "model": PAID_GEMINI_MODEL,
        "monthlyLimitUSD": PAID_GEMINI_MONTHLY_LIMIT_USD,
        "estimatedCostUSD": 0.0,
        "calls": 0,
    }
    try:
        usage = _read_usage_unlocked()
        row = usage["months"].get(paid_month_key(), {})
        status["estimatedCostUSD"] = float(row.get("estimatedCostUSD") or 0)
        status["calls"] = int(row.get("calls") or 0)
    except PaidGeminiUnavailable:
        status["ledgerError"] = True
    return status


def call_paid_gemini(prompt):
    """使用獨立付費池呼叫 Gemini native API；永遠在現有 ProxyCLI 失敗後才會走到這裡。"""
    if not PAID_GEMINI_ENABLED:
        raise PaidGeminiUnavailable("付費 Gemini 未啟用")
    if PAID_GEMINI_MONTHLY_LIMIT_USD <= 0:
        raise PaidGeminiUnavailable("付費 Gemini 月費上限為 0")
    keys = load_paid_keys()
    if not keys:
        raise PaidGeminiUnavailable("沒有可用的付費 Gemini 金鑰")

    month, key_index, reserved_cost = paid_request_reservation(prompt, len(keys))
    body = json.dumps({
        "contents": [{"role": "user", "parts": [{"text": prompt}]}],
        "generationConfig": {
            "temperature": 0,
            "maxOutputTokens": PAID_GEMINI_MAX_OUTPUT_TOKENS,
            "responseMimeType": "application/json",
        },
    }).encode("utf-8")
    endpoint = (
        "https://generativelanguage.googleapis.com/v1beta/models/"
        + urllib.parse.quote(PAID_GEMINI_MODEL, safe="-._")
        + ":generateContent"
    )
    request = urllib.request.Request(
        endpoint,
        data=body,
        headers={
            "x-goog-api-key": keys[key_index],
            "Content-Type": "application/json",
            "User-Agent": USER_AGENT,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=LLM_TIMEOUT) as response:
            result = json.loads(response.read().decode("utf-8"))
    except Exception as error:
        # 失敗請求保留預扣額度，寧可少用也不讓錯誤重試穿透花費上限。
        raise PaidGeminiUnavailable("付費 Gemini 呼叫失敗") from error

    try:
        text = result["candidates"][0]["content"]["parts"][0]["text"]
    except (KeyError, IndexError, TypeError) as error:
        raise PaidGeminiUnavailable("付費 Gemini 回應缺少文字") from error
    metadata = result.get("usageMetadata") or {}
    input_tokens = int(metadata.get("promptTokenCount") or 0)
    output_tokens = int(metadata.get("candidatesTokenCount") or 0)
    reconcile_paid_usage(month, reserved_cost, input_tokens, output_tokens)
    return text


def _proxy_rest_call(prompt, provider, model, timeout):
    """
    呼叫 ProxyCLI REST /api/chat，回傳 (文字, actual_provider, actual_model)。
    走 REST 而非 gRPC SDK 的原因：SDK 的 ai() 只回文字、看不到 actual_provider /
    actual_model，無法偵測 proxy「ok:true 卻悄悄換別家」；SDK 在 model 空白時還會
    在本機自動路由挑模型，與「不指定 model」的意圖不符。
    """
    payload = {
        "prompt": prompt,
        "provider": provider,
        "project": AI_PROXY_PROJECT,
        "group": "news-crawler",  # ProxyCLI 儀表板依此分項統計用量
    }
    if model:  # 空字串＝不送 model 欄位，由 proxy 選該 provider 的預設模型
        payload["model"] = model
    req = urllib.request.Request(
        AI_PROXY_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": "Bearer " + AI_PROXY_TOKEN,
            "Content-Type": "application/json",
            "User-Agent": USER_AGENT,
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode("utf-8", errors="replace")
    try:
        parsed = json.loads(raw)
    except (ValueError, TypeError):
        return raw, None, None
    if not isinstance(parsed, dict):
        return (parsed if isinstance(parsed, str) else raw), None, None
    if parsed.get("ok") is False:
        # error_code 與 error 訊息都可能含「授權已過期」等可辨識字樣，不含 token
        raise RuntimeError("{}：{}".format(parsed.get("error_code") or "proxy_error",
                                          str(parsed.get("error") or "")[:60]))
    actual_provider = parsed.get("actual_provider")
    actual_model = parsed.get("actual_model")
    for key in ("content", "response", "message", "text", "result", "answer", "output"):
        val = parsed.get(key)
        if isinstance(val, str) and val.strip():
            return val, actual_provider, actual_model
    return raw, actual_provider, actual_model  # dict 但找不到已知 key → 上層試著抽 JSON


def _record_actual_model(provider, model, actual_provider, actual_model):
    """彙總實際回答的模型；被 proxy 靜默換成別家（或換了指定的模型）要計入原因。"""
    if actual_provider or actual_model:
        _bump(_LLM_ACTUAL_MODELS, "{}/{}".format(actual_provider or "?", actual_model or "?"))
    if actual_provider and actual_provider != provider:
        _bump(_LLM_PROVIDER_ERRORS, "{}→{} 靜默替換".format(provider, actual_provider))
    elif model and actual_model and actual_model != model:
        _bump(_LLM_PROVIDER_ERRORS, "{}:{}→{} 模型被換".format(provider, model, actual_model))


def call_proxy_llm(prompt):
    """
    依 PROXY_LLM_ROUTE（gemini → claude → openai）呼叫 ProxyCLI，取得純文字回應。
    每個 provider 失敗才試下一個；三者皆不可用才交給獨立 Gemini 池／規則分類。
    預設走 REST（回應含 actual_provider/actual_model，可偵測靜默替換）；
    NEWS_PROXY_TRANSPORT=sdk 才改用 gRPC SDK（看不到 actual_*）。
    不把 provider error 細節寫進 log。
    """
    failures = []
    for provider, model in PROXY_LLM_ROUTE:
        timeout = min(PROXY_LLM_TIMEOUT, PROXY_PROVIDER_TIMEOUT.get(provider, PROXY_LLM_TIMEOUT))
        try:
            if PROXY_TRANSPORT == "sdk" and _sdk_ai is not None:
                kwargs = dict(provider=provider, project=AI_PROXY_PROJECT,
                              group="news-crawler", timeout=timeout)
                if model:
                    kwargs["model"] = model
                return _sdk_ai(prompt, **kwargs)
            text, actual_provider, actual_model = _proxy_rest_call(prompt, provider, model, timeout)
            _record_actual_model(provider, model, actual_provider, actual_model)
            return text
        except Exception as provider_error:
            label = describe_llm_error(provider_error)
            _bump(_LLM_PROVIDER_ERRORS, "{}:{}".format(provider, label))
            failures.append("{}={}".format(provider, label))
            continue
    raise RuntimeError("ProxyCLI 分類路徑皆不可用：{}".format(
        "；".join(failures) or "未設定模型"))


def llm_classify(title, description, skip_proxy=False):
    """
    對規則通過的單則新聞問 LLM。
    回傳 (result, retry_later, disable_for_run, transport_provider)：
    - result：解析成功且 confidence >= 門檻的 dict，否則 None
    - retry_later：本次是網路/額度等暫時性失敗，不應寫入 seen
    - disable_for_run：本輪後續不要再呼叫 LLM，避免每則各卡一次逾時
    - transport_provider：這次實際成功回應的 LLM 路徑；即使內容低信心也回傳，
      讓同一輪後續新聞能略過已失敗的 ProxyCLI。
    """
    prompt = build_llm_prompt(title, description)
    provider = None
    if skip_proxy:
        try:
            answer = call_free_gemini(prompt)
            provider = "gemini-free"
        except FreeGeminiUnavailable as free_error:
            try:
                answer = call_paid_gemini(prompt)
                provider = "gemini-paid"
                log("免費 LLM 路徑暫時失敗，本則改用受月費上限保護的 Gemini 付費池")
            except PaidGeminiUnavailable as paid_error:
                _bump(_LLM_FAIL_REASONS, "免費池:{}".format(describe_llm_error(free_error)))
                log("LLM 呼叫失敗（本輪停用並保留待重試）：免費池：{}；付費池：{}".format(
                    free_error, paid_error
                ))
                return None, True, True, None
    else:
        try:
            answer = call_proxy_llm(prompt)
            provider = "proxy"
        except Exception as proxy_error:
            try:
                answer = call_free_gemini(prompt)
                provider = "gemini-free"
                log("ProxyCLI 暫時失敗，本則改用獨立免費 Gemini 池；本輪後續直接使用免費池")
            except FreeGeminiUnavailable as free_error:
                try:
                    answer = call_paid_gemini(prompt)
                    provider = "gemini-paid"
                    log("免費 LLM 路徑暫時失敗，本則改用受月費上限保護的 Gemini 付費池")
                except PaidGeminiUnavailable as paid_error:
                    _bump(_LLM_FAIL_REASONS, "ProxyCLI全滅({})／免費池:{}".format(
                        str(proxy_error).split("：", 1)[-1][:80], describe_llm_error(free_error)))
                    log("LLM 呼叫失敗（本輪停用並保留待重試）：ProxyCLI：{}；免費池：{}；付費池：{}".format(
                        proxy_error, free_error, paid_error
                    ))
                    return None, True, True, None

    # 從回應中抽第一段 {...}（LLM 偶爾會多話）
    m = re.search(r"\{.*\}", answer, re.DOTALL)
    if not m:
        _bump(_LLM_UNUSABLE_REASONS, "回應無JSON")
        log("LLM 回應無 JSON（退回規則結果）：{}".format(answer[:120]))
        return None, False, False, provider
    try:
        result = json.loads(m.group(0))
    except ValueError:
        _bump(_LLM_UNUSABLE_REASONS, "JSON解析失敗")
        log("LLM JSON 解析失敗（退回規則結果）：{}".format(m.group(0)[:120]))
        return None, False, False, provider

    if not isinstance(result, dict) or "is_incident" not in result:
        _bump(_LLM_UNUSABLE_REASONS, "缺少is_incident")
        log("LLM 回應缺少 is_incident（退回規則結果）")
        return None, False, False, provider

    try:
        confidence = float(result.get("confidence") or 0)
    except (TypeError, ValueError):
        confidence = 0.0
    if confidence < LLM_MIN_CONFIDENCE:
        _bump(_LLM_UNUSABLE_REASONS, "低信心(<{})".format(LLM_MIN_CONFIDENCE))
        log("LLM confidence {} < {}（退回規則結果）".format(confidence, LLM_MIN_CONFIDENCE))
        return None, False, False, provider

    result["confidence"] = confidence
    # county 若非 null 也順手正規化（LLM 可能回「台中」而非「台中市」）
    county = result.get("county")
    if isinstance(county, str) and county:
        for token in COUNTY_TOKENS:
            if county.startswith(token):
                result["county"] = COUNTY_NORMALIZE[token]
                break
    else:
        result["county"] = None
    valid_categories = {c for c, _ in INCLUDE_CATEGORIES}
    if result.get("category") not in valid_categories:
        _bump(_LLM_UNUSABLE_REASONS, "分類不在白名單")
        return None, False, False, provider  # 分類不在白名單 → 不可信，退回規則
    # 地點欄位過簡轉繁（LLM 抽的 district/place 也可能混簡體）；summary/detail 已不
    # 要求 LLM 產出（見 LLM_PROMPT_TEMPLATE 上方說明），這裡不再消毒這兩個欄位。
    for key in ("district", "place"):
        if isinstance(result.get(key), str):
            result[key] = to_traditional(result[key])
    # 嚴重度與是否進行中（推播分級用）：只收白名單值，其餘給保守預設，不讓壞值誤觸推播
    sev = str(result.get("severity", "")).strip().lower()
    result["severity"] = sev if sev in ("high", "medium", "low") else "low"
    ongoing = result.get("is_ongoing")
    result["is_ongoing"] = ongoing is True or (isinstance(ongoing, str) and ongoing.strip().lower() == "true")
    result["_llm_provider"] = provider
    return result, False, False, provider


def _llm_classify_safe(title, description):
    """
    llm_classify() 的並行呼叫包裝：main() 用 ThreadPoolExecutor 對「待補清單」
    並行送出這個函式，任何一則丟出未預期例外都不能讓整個執行緒池掛掉、拖累
    其他則的判讀——一律接住、記 log，轉成「本則失敗」讓呼叫端退回規則結果，
    這正是「單則失敗就單則放棄，不要因為個別失敗就停用整輪」的體現。

    llm_classify() 本身已經把 ProxyCLI／免費／付費三條路徑的已知例外都接住了，
    這裡是最後一層防線，理論上不該真的被觸發。
    """
    try:
        return llm_classify(title, description)
    except Exception as error:  # noqa: BLE001 — 並行呼叫的最後防線，什麼例外都要接住
        _bump(_LLM_FAIL_REASONS, "未預期例外:{}".format(describe_llm_error(error)))
        log("LLM 並行呼叫發生未預期例外（本則放棄，退回規則結果）：{}".format(error))
        return None, True, False, None


# ---------------------------------------------------------------------------
# 去重
# ---------------------------------------------------------------------------

def normalize_title(title):
    """標題正規化：去掉標點、空白、全形符號，只留中英數字，供跨來源比對"""
    # NFKC 統一全半形；先剝掉「| 國際」這類頻道後綴與「 - 媒體」尾巴，再去標點空白
    text = unicodedata.normalize("NFKC", title or "")
    text = re.sub(r"\s*[|｜]\s*[^|｜]{1,8}$", "", text)
    text = re.sub(r"\s+-\s+[^-]{1,20}$", "", text)
    return re.sub(r"[^\w一-鿿]+", "", text).lower()


def find_duplicate(event, accepted):
    """
    跨來源找同一事件：正規化標題「前 12 字相同」或 difflib ratio > 0.6。
    回傳命中的既有 event，找不到回 None。
    """
    norm_new = normalize_title(event["title"])
    for old in accepted:
        norm_old = normalize_title(old["title"])
        if norm_new[:12] and norm_new[:12] == norm_old[:12]:
            return old
        if difflib.SequenceMatcher(None, norm_new, norm_old).ratio() > 0.6:
            return old
    return None


def merge_duplicate(existing, new_event):
    """合併重複事件：僅真正新增媒體來源才提高 corroboration。"""
    names = [n.strip() for n in existing["sourceName"].split("、")]
    if new_event["sourceName"] not in names:
        existing["sourceName"] = existing["sourceName"] + "、" + new_event["sourceName"]
        existing["corroboration"] += 1
    # 既有欄位缺值時，用新來源的值補上（縣市/地點/摘要/詳述越齊越好）
    for key in ("county", "district", "place", "summary", "detail"):
        if not existing.get(key) and new_event.get(key):
            existing[key] = new_event[key]
    # 嚴重度取較高、是否進行中取「任一為真」：多來源中以最嚴重、最即時者為準
    _order = {"low": 0, "medium": 1, "high": 2}
    if _order.get(new_event.get("severity", "low"), 0) > _order.get(existing.get("severity", "low"), 0):
        existing["severity"] = new_event["severity"]
    if new_event.get("is_ongoing"):
        existing["is_ongoing"] = True


# ---------------------------------------------------------------------------
# 跨輪去重（recent_titles.json）
# ---------------------------------------------------------------------------
# find_duplicate 只比對「本輪」新事件；Google 會在後續輪次再報同一則既有媒體的新聞，
# 所以另存近 24 小時已輸出事件的正規化標題，僅供新來源（Google）擋重複用。
RECENT_TITLES_MAX = 600


def load_recent_titles(path, now=None):
    """讀近 24 小時已輸出標題（正規化後）；檔案不存在或壞掉回空清單"""
    now = now or datetime.now(TZ_TAIPEI)
    cutoff = now.timestamp() - NEWS_MAX_AGE_HOURS * 3600
    try:
        with open(path, "r", encoding="utf-8") as f:
            rows = json.load(f).get("items", [])
        return [r for r in rows if isinstance(r, dict) and r.get("n") and r.get("t", 0) >= cutoff]
    except (OSError, ValueError, AttributeError):
        return []


def save_recent_titles(path, rows):
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"items": rows[-RECENT_TITLES_MAX:]}, f, ensure_ascii=False)


def is_recent_duplicate(title, rows):
    """與 find_duplicate 同一套門檻（前 12 字相同或 ratio > 0.6），比對跨輪標題紀錄"""
    norm_new = normalize_title(title)
    if not norm_new:
        return False
    for row in rows:
        norm_old = row["n"]
        if norm_new[:12] == norm_old[:12]:
            return True
        matcher = difflib.SequenceMatcher(None, norm_new, norm_old)
        if matcher.real_quick_ratio() > 0.6 and matcher.ratio() > 0.6:
            return True
    return False


# ---------------------------------------------------------------------------
# 狀態檔（seen.json）
# ---------------------------------------------------------------------------

def load_seen(path):
    """讀已處理 id 清單；檔案不存在或壞掉都回空（壞掉要記 log）"""
    if not os.path.exists(path):
        return []
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        ids = data.get("ids", [])
        return ids if isinstance(ids, list) else []
    except (ValueError, OSError) as e:
        log("seen.json 讀取失敗（視為全新狀態）：{}".format(e))
        return []


def save_seen(path, ids):
    """存已處理 id，滾動只留最後 SEEN_MAX 筆"""
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"ids": ids[-SEEN_MAX:]}, f, ensure_ascii=False)


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

INGEST_URL = "https://havencircle.looptw.com/crawler/api/ingest_news.php"


def push_to_oracle(output, out_dir):
    """
    推送本輪結果到 Oracle 中繼站（與 NCDR 爬蟲同機制：X-Ingest-Key 驗證）。
    就算 0 筆新事件也推——Oracle 端在 ingest 時才做 24 小時淘汰，
    空推等於幫存檔保鮮。失敗只警告不中斷：本機檔案寫成功才是基本盤。
    """
    key_path = os.path.join(out_dir, "ingest_key.txt")
    if not os.path.exists(key_path):
        log("找不到 ingest_key.txt，跳過推送 Oracle")
        return
    with open(key_path, encoding="utf-8") as f:
        key = f.read().strip()
    body = json.dumps(output, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        INGEST_URL,
        data=body,
        headers={
            "Content-Type": "application/json; charset=utf-8",
            "X-Ingest-Key": key,
            "User-Agent": USER_AGENT,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            log("Oracle 已接收：{}".format(resp.read().decode("utf-8")))
    except Exception as e:
        log("推送 Oracle 失敗（不中斷）：{}".format(e))


def main(feeds=None, out_dir=None, ptt_boards=None):
    # PTT 只在「正式跑（沒指定 feeds）」時預設啟用；測試或手動指定 feeds 時不會
    # 偷偷連 PTT，除非明確傳入 ptt_boards。
    if ptt_boards is None:
        ptt_boards = PTT_BOARDS if (PTT_ENABLED and feeds is None) else []
    feeds = feeds if feeds is not None else FEEDS
    out_dir = out_dir or os.path.dirname(os.path.abspath(__file__))
    latest_path = os.path.join(out_dir, "latest.json")
    seen_path = os.path.join(out_dir, "seen.json")
    recent_path = os.path.join(out_dir, "recent_titles.json")

    use_llm = bool(AI_PROXY_TOKEN) or (
        FREE_GEMINI_ENABLED and FREE_GEMINI_DAILY_CALL_LIMIT > 0
    ) or (
        PAID_GEMINI_ENABLED and PAID_GEMINI_MONTHLY_LIMIT_USD > 0
    )
    log("啟動：LLM 分類 {}（ProxyCLI {}／免費 Gemini {}／付費 Gemini {}，並行度 {}）".format(
        "開啟" if use_llm else "關閉，走純規則路徑",
        "已設定" if AI_PROXY_TOKEN else "未設定",
        "啟用" if FREE_GEMINI_ENABLED and FREE_GEMINI_DAILY_CALL_LIMIT > 0 else "關閉",
        "啟用" if PAID_GEMINI_ENABLED and PAID_GEMINI_MONTHLY_LIMIT_USD > 0 else "關閉",
        NEWS_LLM_CONCURRENCY))

    seen_ids = load_seen(seen_path)
    seen_set = set(seen_ids)
    recent_titles = load_recent_titles(recent_path)

    sources_report = []
    events = []
    total_fetched = 0
    total_eligible = 0
    skipped_seen = 0
    dropped_by_rules = 0
    dropped_by_llm = 0
    llm_calls = 0            # 實際送出的 LLM 呼叫數（只算「規則缺地點」的待補清單）
    llm_failed = 0           # 呼叫了、但 ProxyCLI／免費／付費三條路徑全部失敗（傳輸層）的則數
    llm_unusable = 0         # LLM 有回應、但低信心／非JSON／分類不合法而不採用的則數（不是通道故障）
    reset_llm_reasons()
    llm_retry_pending = 0    # 超出單輪呼叫預算、完全沒機會呼叫、留給下一輪的則數
    stale_dropped = 0
    future_dropped = 0
    capped_dropped = 0
    extra_llm_calls = 0      # 新來源（Google）已花掉的額外 LLM 預算
    extra_deferred = 0       # 新來源因額外預算用完而留待下輪的則數
    dropped_recent_dup = 0   # 新來源因與近 24 小時已輸出事件重複而丟棄
    ptt_report = {"items": 0, "candidates": 0, "events": 0}
    foreign_dropped = 0
    foreign_titles = []      # 供 dry-run 檢視被排除的國外事件（只留前 20 則標題）
    stale_ongoing_cleared = 0
    aftermath_cleared = 0     # 事後報導（逮捕／落網…）被壓成非進行中的則數

    def mark_seen(item_id):
        if item_id in seen_set:
            return
        seen_set.add(item_id)
        seen_ids.append(item_id)

    def resolve_and_file(event, item_id, title, source_name):
        """收尾共用邏輯：跨來源去重、記錄合併 log、併入 events。"""
        dup = find_duplicate(event, events)
        if dup is not None and any(a.lower() in source_name.lower() for a in AGGREGATOR_MEDIA):
            log("轉載平台重複事件（不合併、不計來源）：「{}」({})".format(title[:20], source_name))
        elif dup is not None:
            merge_duplicate(dup, event)
            log("合併重複事件：「{}」({}) → 「{}」".format(
                title[:20], source_name, dup["title"][:20]))
        else:
            events.append(event)

    # 待補清單：規則跑完仍缺 county 或 district 的事故則，稍後統一並行呼叫 LLM
    # 補位（改動 3）。用 list 收集、等全部 feed 掃完再一次送進執行緒池，是為了
    # 用 ThreadPoolExecutor.map() 保證「回傳順序＝送入順序」，即使個別呼叫完成
    # 的先後順序被網路延遲打亂，也不會把 A 則的結果錯接到 B 則上。
    pending = []  # 每筆：{"event", "item_id", "title", "description", "source_name"}

    for feed in feeds:
        # 單一 feed 失敗：記 log、標 ok=false，繼續跑其他 feed
        try:
            data = fetch_url(feed["url"])
            fmt = feed.get("format")
            if fmt == "atom":
                raw_items = parse_atom(data)
            elif fmt == "google_news":
                raw_items = parse_google_news_rss(data)
            elif fmt == "tvbs_html":
                raw_items = parse_tvbs_local(data.decode("utf-8", errors="replace"))
            else:
                raw_items = parse_rss(data)
            items, preparation = prepare_feed_items(
                raw_items,
                max_items=feed.get("max_items", DEFAULT_FEED_ITEM_LIMIT),
            )
        except Exception as e:
            log("feed 抓取/解析失敗（跳過此 feed）：{} {} — {}".format(
                feed["name"], feed["feed"], e))
            sources_report.append({
                "name": feed["name"], "feed": feed["feed"], "url": feed["url"],
                "ok": False, "items": 0, "error": str(e),
            })
            continue

        sources_report.append({
            "name": feed["name"], "feed": feed["feed"], "url": feed["url"],
            "ok": True, "items": len(items), **preparation,
        })
        total_fetched += preparation["rawItems"]
        total_eligible += len(items)
        stale_dropped += preparation["staleDropped"]
        future_dropped += preparation["futureDropped"]
        capped_dropped += preparation["cappedDropped"]
        log("feed OK：{} {} — 原始 {}／近期可處理 {} 則".format(
            feed["name"], feed["feed"], preparation["rawItems"], len(items)))

        for item in items:
            item_id = stable_id(item)
            if item_id in seen_set:
                skipped_seen += 1
                continue

            title, description = item["title"], item["description"]
            # 聚合來源（Google）每則自帶真正的媒體名；一般 feed 用 feed 名稱
            source_name = item.get("source_name") or feed["name"]
            is_extra = bool(feed.get("extra"))

            # 第一段：規則式（永遠執行）
            is_incident, category, hit_word = rules_classify(title, description)
            if not is_incident:
                dropped_by_rules += 1
                mark_seen(item_id)
                continue

            # 國外事件：沒有台灣縣市卻出現國外地名／國際頻道標記 → 不輸出
            if is_foreign_news(title, description):
                foreign_dropped += 1
                if len(foreign_titles) < 20:
                    foreign_titles.append(title)
                mark_seen(item_id)
                continue

            # 新來源：與近 24 小時（含前幾輪）已輸出事件重複的直接丟棄，
            # 避免 Google 把既有 5 家媒體早已報過的新聞再輸出一次。
            if is_extra and is_recent_duplicate(title, recent_titles):
                dropped_recent_dup += 1
                mark_seen(item_id)
                continue

            # 規則路徑的縣市＋行政區抽取：中央社電頭優先，其次掃標題／描述的縣市
            # token；不論縣市是否已知，都再用強化版行政區抽取（去後綴簡寫、剝除
            # 縣市核心字、限同縣市，見 district_from_text_v2）補行政區——這是跟
            # 舊版最大的差異：舊版只在縣市「還沒抓到」時才找行政區，等於放棄了
            # 「縣市已知、只缺行政區」這一大塊（行政區覆蓋率 13/83 → 25/83 的
            # 提升有一部分正是來自這裡）。
            county = county_from_cna_dateline(description) or county_from_text(title) \
                or county_from_landmark(title)
            district, matched_county = district_from_text_v2(title, county=county)
            # Google 的 description 是一串「相關報導標題」，常夾帶別縣市地名（花蓮事件冒出
            # 台北市中山區）；聚合來源的描述不用來推地點，缺的交給 LLM 或略過。
            if not district and not is_extra:
                district, matched_county = district_from_text_v2(description, county=county)
            if not county:
                county = matched_county

            # 摘要／詳述改規則式產生，不再呼叫 AI（見 build_detail_excerpt 上方
            # 的版權說明）：summary 直接用原標題；detail 只取原文前 120 字摘錄。
            event = {
                "id": item_id,
                "title": title,
                "publishedAt": parse_pubdate(item["pubDate"]),
                "sourceName": source_name,
                "sourceURL": item["link"],
                "county": county,
                "district": district,
                "place": None,
                "category": category,
                "confidence": 0.5,          # 規則路徑的預設信心值
                "summary": title,
                "detail": build_detail_excerpt(description),
                "extraction": "rules",
                "trust": "media-report",    # 媒體報導層
                "corroboration": 1,
                "severity": "low",          # 嚴重度（推播分級用）；規則路徑保守給 low，不會觸發推播
                "is_ongoing": False,        # 是否仍在發生需即時反應；規則路徑保守給 False
            }

            # 第二段：LLM 只補規則沒抽到的欄位（改動 3）。規則已抽到完整地點的
            # 一律不呼叫 LLM——這正是「全用 AI」表現較差的原因（LLM 覆蓋掉更準
            # 的規則地點）。需要補位又還在本輪呼叫預算內的，先收進待補清單，
            # 稍後統一並行處理；預算用完的直接標記待重試，留給下一輪。
            needs_llm = (not county) or (not district)
            # 新來源超出額外預算：不呼叫、不寫 seen、不輸出（沒縣市的事件 App 會丟棄），
            # 下一輪再補；已有縣市的照常輸出（只缺行政區，不需要為它花 LLM）。
            if is_extra and use_llm and needs_llm and extra_llm_calls >= EXTRA_LLM_MAX_CALLS_PER_RUN:
                extra_deferred += 1
                if county:
                    mark_seen(item_id)
                    resolve_and_file(event, item_id, title, source_name)
                continue
            if use_llm and needs_llm and llm_calls < LLM_MAX_CALLS_PER_RUN:
                llm_calls += 1
                if is_extra:
                    extra_llm_calls += 1
                pending.append({
                    "event": event,
                    "item_id": item_id,
                    "title": title,
                    "description": description,
                    "source_name": source_name,
                    "extra": is_extra,
                })
                continue  # 是否 mark_seen／去重都留到並行階段結束後統一處理

            if use_llm and needs_llm:
                # 超出本輪呼叫預算：完全沒機會呼叫，保留規則結果、不寫 seen，
                # 讓下一輪重試（跟「呼叫了但失敗」不同，那些已經定案不必重試）。
                llm_retry_pending += 1
            else:
                mark_seen(item_id)

            if is_extra and not county:
                # 新來源無縣市（規則抽不到、又沒有 LLM 可補）：輸出也會被 App 丟棄，不收
                mark_seen(item_id)
                continue
            resolve_and_file(event, item_id, title, source_name)

    # 並行補位：對待補清單統一用 ThreadPoolExecutor 並行呼叫 LLM。並行區塊只
    # 呼叫純函式 _llm_classify_safe（內部呼叫的用量帳本已用 fcntl.flock 保護），
    # 不觸碰 events／seen_set／各計數器等共享狀態；等 executor.map() 收集完全部
    # 結果（保證順序＝送入順序）才回到主執行緒依序處理，天生沒有 race condition，
    # 不需要額外加鎖。
    if pending:
        log("待補清單 {} 則，並行度 {}".format(len(pending), NEWS_LLM_CONCURRENCY))
        with concurrent.futures.ThreadPoolExecutor(max_workers=NEWS_LLM_CONCURRENCY) as executor:
            results = list(executor.map(
                lambda task: _llm_classify_safe(task["title"], task["description"]),
                pending,
            ))

        for task, (llm, retry_later, _disable_for_run, _transport_provider) in zip(pending, results):
            event = task["event"]
            item_id = task["item_id"]
            title = task["title"]

            if llm is None:
                # 熔斷邏輯改造（改動 3）：單則失敗就單則放棄，保留規則結果即可，
                # 不要因為個別失敗就停用整輪——舊邏輯是任一則失敗就整輪停用 LLM，
                # 在實測 43% 的失敗率下等於每輪必熔斷，這正是新聞長期卡在「待
                # 重試」、只能靠規則判讀的根本原因。
                # retry_later=True 才是真正的通道失敗；其餘是 LLM 有回、但內容不採用
                if retry_later:
                    llm_failed += 1
                else:
                    llm_unusable += 1
                mark_seen(item_id)
            elif not llm.get("is_incident"):
                # 改動 4：只有「因缺地點而呼叫 LLM」的則才會走到這個過濾——
                # 規則地點已完整、沒呼叫 LLM 的則不受影響，維持規則判定。
                dropped_by_llm += 1
                mark_seen(item_id)
                continue
            else:
                # 只補規則沒抽到的欄位；規則已抽到的以規則為準，不讓 LLM
                # 覆蓋掉更準的規則地點（county/district 皆是，理由同上）。
                merged_county = event["county"] or llm.get("county")
                merged_district = event["district"] or llm.get("district")
                # 但兩邊各出一半時可能湊出不存在的組合：規則對裸寫的「嘉義」
                # 一律預設嘉義市，LLM 卻補上屬於嘉義縣的水上鄉，併起來就成了
                # 「嘉義市水上鄉」，地圖會釘到錯的地方。行政區比縣市 specific，
                # 衝突時以行政區反推縣市為準。
                if merged_district and merged_county:
                    owner = DISTRICT_TO_COUNTY.get(merged_district)
                    if owner and owner != merged_county:
                        merged_county = owner
                event.update({
                    "county": merged_county,
                    "district": merged_district,
                    "place": llm.get("place") or None,
                    "category": llm["category"],
                    "confidence": llm["confidence"],
                    "extraction": {
                        "gemini-free": "llm-gemini-free",
                        "gemini-paid": "llm-gemini-paid",
                    }.get(llm.get("_llm_provider"), "llm"),
                    "severity": llm.get("severity", "low"),
                    "is_ongoing": bool(llm.get("is_ongoing")),
                })
                mark_seen(item_id)

            if task.get("extra") and not event.get("county"):
                continue  # 新來源 LLM 也補不出縣市：App 會丟棄，不輸出（已視情況寫入 seen）
            resolve_and_file(event, item_id, title, task["source_name"])

    # PTT（社群爆料，未經證實）：必須在所有媒體事件都定案後才處理，才能確保
    # 「與媒體事件重複 → 丟 PTT」的方向；PTT 永遠不呼叫 LLM、不參與 corroboration。
    for board in ptt_boards:
        try:
            ptt_items, ptt_prep = prepare_feed_items(
                parse_atom(fetch_url(board["url"])), max_items=60)
        except Exception as e:
            log("PTT 抓取/解析失敗（跳過）：{} — {}".format(board["name"], e))
            sources_report.append({
                "name": board["name"], "feed": "爆卦/新聞", "url": board["url"],
                "ok": False, "items": 0, "error": str(e),
            })
            continue
        sources_report.append({
            "name": board["name"], "feed": "爆卦/新聞", "url": board["url"],
            "ok": True, "items": len(ptt_items), **ptt_prep,
        })
        total_fetched += ptt_prep["rawItems"]
        total_eligible += len(ptt_items)
        stale_dropped += ptt_prep["staleDropped"]
        future_dropped += ptt_prep["futureDropped"]
        capped_dropped += ptt_prep["cappedDropped"]
        ptt_report["items"] += len(ptt_items)
        log("PTT OK：{} — 原始 {}／近期可處理 {} 則".format(
            board["name"], ptt_prep["rawItems"], len(ptt_items)))

        for item in ptt_items:
            item_id = stable_id(item)
            if item_id in seen_set:
                skipped_seen += 1
                continue
            clean = ptt_clean_title(item["title"])
            if clean is None:
                continue  # 非爆卦/新聞標籤（閒聊、問卦、回文）：不入 seen，免得 seen 被灌爆
            ptt_report["candidates"] += 1
            # 只用標題分類與抽地點：PTT 內文含個資與閒聊，不拿來比對、也不輸出
            is_incident, category, _hit = rules_classify(clean, "")
            if not is_incident:
                dropped_by_rules += 1
                mark_seen(item_id)
                continue
            county = county_from_text(clean)
            district, matched_county = district_from_text_v2(clean, county=county)
            county = county or matched_county
            event = {
                "id": item_id,
                "title": clean,
                "publishedAt": parse_pubdate(item["pubDate"]),
                "sourceName": board["name"],
                "sourceURL": item["link"],
                "county": county,
                "district": district,
                "place": None,
                "category": category,
                "confidence": 0.3,
                # App 端 summary 會當標題顯示：把「未證實」直接寫進文字，不靠顏色
                "summary": PTT_SUMMARY_PREFIX + clean,
                "detail": PTT_DETAIL,
                "extraction": "rules",
                "trust": PTT_TRUST,
                "corroboration": 1,
                "severity": "low",       # 鎖死 low／False：不符 cron_check 推播條件
                "is_ongoing": False,
            }
            if not county:
                mark_seen(item_id)  # 無縣市 App 會丟棄，不輸出
                continue
            if find_duplicate(event, events) is not None or is_recent_duplicate(clean, recent_titles):
                dropped_recent_dup += 1  # 已有媒體報導：丟 PTT，不合併、不灌 corroboration
                mark_seen(item_id)
                continue
            mark_seen(item_id)
            events.append(event)
            ptt_report["events"] += 1

    # 時效閘門（對所有來源）：發布超過 ONGOING_MAX_AGE_HOURS 的事件，is_ongoing 一律
    # 壓成 False。cron_check.php 沒有自己的時間窗，只看 is_ongoing；LLM 會把「昨晚的火警」
    # 判成 is_ongoing=true，首次上線或 Google 回頭撈到舊聞時就會晚 9~14 小時才推播。
    # 事件仍輸出，App 列表照常顯示，只是不再被當成「正在發生」。
    gate_now = datetime.now(TZ_TAIPEI)
    for e in events:
        published = parse_pubdate_datetime(e.get("publishedAt"))
        too_old = published is None or (gate_now - published) > timedelta(hours=ONGOING_MAX_AGE_HOURS)
        if e.get("is_ongoing") and is_aftermath_report(e.get("title")):
            e["is_ongoing"] = False
            aftermath_cleared += 1
        elif e.get("is_ongoing") and too_old:
            e["is_ongoing"] = False
            stale_ongoing_cleared += 1
        elif e.get("is_ongoing") and any(w in (e.get("title") or "") for w in NONVIOLENT_CRIME_TERMS) \
                and violent_ongoing_severity(e.get("title")) is None:
            e["is_ongoing"] = False  # 竊盜／詐騙／偷拍等非暴力治安：不推
        # 暴力且進行中治安事件升級（PTT 等非 media-report 來源永不升級）
        if (e.get("trust") == "media-report" and not too_old
                and e.get("category") in ("公共安全", "火災")
                and e.get("county") and e.get("district")):
            sev = violent_ongoing_severity(e.get("title"))
            if sev and (e.get("category") == "公共安全" or "縱火" in (e.get("title") or "")):
                e["is_ongoing"] = True
                if e.get("severity") != "high":
                    e["severity"] = sev
                e["confidence"] = max(float(e.get("confidence") or 0), CRIME_PUSH_CONFIDENCE)

    # 是否「本輪 LLM 大規模失效」的健康指標：待補清單裡確實呼叫過、且全部失敗
    # 才算——單則失敗已經退回規則結果、不影響其他則，不算真正的降級。
    llm_circuit_open = llm_calls > 0 and llm_failed == llm_calls

    # 輸出 latest.json
    output = {
        "fetchedAt": datetime.now(TZ_TAIPEI).isoformat(),
        "sources": sources_report,
        "totalFetched": total_fetched,
        "totalEligible": total_eligible,
        "skippedSeen": skipped_seen,
        "incidentCount": len(events),
        "droppedByRules": dropped_by_rules,
        "droppedByLLM": dropped_by_llm,
        "pipelineHealth": {
            "staleDropped": stale_dropped,
            "futureDropped": future_dropped,
            "cappedDropped": capped_dropped,
            "llmEnabled": use_llm,
            "llmCalls": llm_calls,
            "llmMaxCallsPerRun": LLM_MAX_CALLS_PER_RUN,
            "llmConcurrency": NEWS_LLM_CONCURRENCY,
            "llmFailed": llm_failed,
            "llmUnusable": llm_unusable,
            "llmFailReasons": dict(_LLM_FAIL_REASONS),
            "llmUnusableReasons": dict(_LLM_UNUSABLE_REASONS),
            "llmProviderErrors": dict(_LLM_PROVIDER_ERRORS),
            "llmActualModels": dict(_LLM_ACTUAL_MODELS),
            # 欄位名稱沿用舊版，供 App 端 AlertSourceHealthService 既有的健康
            # 面板判斷式繼續讀取；語意已從「整輪停用」改成「本輪 LLM 大規模
            # 失效」（見上方 llm_circuit_open 的計算方式）。
            "llmCircuitOpen": llm_circuit_open,
            "pendingLLMRetry": llm_retry_pending,
            "foreignDropped": foreign_dropped,
            "foreignTitles": foreign_titles,
            "staleOngoingCleared": stale_ongoing_cleared,
            "aftermathOngoingCleared": aftermath_cleared,
            "extraLLMMaxCalls": EXTRA_LLM_MAX_CALLS_PER_RUN,
            "extraSourceDeferred": extra_deferred,
            "droppedRecentDuplicate": dropped_recent_dup,
            "ptt": ptt_report,
            "freeGemini": free_gemini_status(),
            "paidGemini": paid_gemini_status(),
        },
        "events": events,
    }
    with open(latest_path, "w", encoding="utf-8") as f:
        json.dump(output, f, ensure_ascii=False, indent=2)
    save_seen(seen_path, seen_ids)
    # 跨輪標題紀錄只收「非社群」事件，PTT 標題不入帳，否則會反過來擋掉日後的媒體報導
    now_ts = datetime.now(TZ_TAIPEI).timestamp()
    save_recent_titles(recent_path, recent_titles + [
        {"t": now_ts, "n": normalize_title(e["title"])}
        for e in events if e.get("trust") != PTT_TRUST and normalize_title(e["title"])
    ])

    log("完成：原始 {}／近期 {} 則（略過已見 {}）→ 事故 {} 則｜規則排除 {}｜"
        "LLM 呼叫 {}（失敗 {}、回應不採用 {}）｜LLM 排除 {}｜待重試 {}".format(
            total_fetched, total_eligible, skipped_seen, len(events), dropped_by_rules,
            llm_calls, llm_failed, llm_unusable, dropped_by_llm, llm_retry_pending))
    if _LLM_FAIL_REASONS:
        log("LLM 失敗原因：{}".format(format_llm_reasons(_LLM_FAIL_REASONS)))
    if _LLM_UNUSABLE_REASONS:
        log("LLM 回應不採用原因：{}".format(format_llm_reasons(_LLM_UNUSABLE_REASONS)))
    if _LLM_ACTUAL_MODELS:
        log("LLM 實際回答模型：{}".format(format_llm_reasons(_LLM_ACTUAL_MODELS)))
    if _LLM_PROVIDER_ERRORS:
        log("LLM 單一通道錯誤（含已由備援救回）：{}".format(format_llm_reasons(_LLM_PROVIDER_ERRORS)))
    log("輸出：{}".format(latest_path))

    push_to_oracle(output, out_dir)

    # 全部 feed 都掛才算失敗（exit code 給 cron 監控用）
    all_failed = bool(feeds) and all(not s["ok"] for s in sources_report)
    return 1 if all_failed else 0


if __name__ == "__main__":
    sys.exit(main())

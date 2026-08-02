#!/usr/bin/env python3
"""全台各縣市消防局「即時派遣案件」統一爬蟲。

角色：fetch_taichung_fire.py 只涵蓋台中、只收火災；fetch_nfa.py 是消防署「初(結)報」，
只有站方主動發布的重大案件。這支才是真正逐案級、涵蓋多數縣市 119 派遣系統的爬蟲，
目的是接住現行系統完全漏掉的「車禍」——使用者最在意但沒有任何官方管道會單獨發布的類別。

資料來源分三種型態（2026-08-02 上午逐一實測，詳見各 parser 註解）：
  A. DTS 系統：POST https://{host}/DTS/caselist/xml，無 body、無 cookie、無 token，回傳 XML。
     台南、高雄、雲林、苗栗、基隆、新竹市、宜蘭、澎湖共用同一套系統，只是 host 不同。
  B. 台北市 service119：POST（GET 會 500）https://service119.tfd.gov.tw/service119/citizenCase/caseList，
     body {}，回傳 JSON。資料視窗只有最近約 1 小時，漏接風險最高；且案別欄位
     （csCodeName）實測全數為空字串，無法判斷「車禍」子類，故台北市只會收到「火災」。
  C. 各站自有 HTML 頁面（台中／桃園／南投／彰化／嘉義／屏東），結構互不相同，各自一個
     parser；屏東頁面沒有「案別」欄位，同樣只能收到案類本身在白名單內的（火災／災害搶救），
     車禍無法從屏東判斷。
  D. 新北市獨立端點：GET https://e.ntpc.gov.tw/v3/api/map/dynamic/layer/rescue
     （備援 e1.ntpc.gov.tw），裸請求、無 UA/Referer/cookie/token 需求。回應是雙層 JSON——
     外層 data 欄位是字串化的 GeoJSON，要 parse 兩次。救護案件（type=AmbulanceBack）的
     endPointInfo 只有送醫醫院名稱、沒有案類與地點欄位，故只收火災（type 開頭 Fire）；
     這點與台北市 service119 情況相同。payload 完全沒有時間欄位，occurredAt 用
     seen.json 記錄「首次看到這個 featureId 的時間」兜底。案件結束後約 5 分鐘就從清單
     消失，視窗是所有來源裡最短的之一，建議獨立跑 60 秒輪詢（現行 cron 是 2 分鐘，
     漏接風險偏高）。難得自帶精確經緯度（lat/lng），優先於行政區推定用於生活圈比對。

去重／狀態更新：DTS 有原生 CS_NO，用 {縣市}|{CS_NO} 當鍵；沒有原生案號的站用
{縣市}|{發生時間}|{地點}。同一案的 STATUS 會隨時間變化（已派遣→已出動→已返隊），
狀態故意不放進鍵——每輪都輸出「本次掃到的完整快照」（比照 fetch_taichung_fire.py／
fetch_freeway.py 的做法，不是只輸出新增的），下游拿到的永遠是最新狀態。
seen.json 只用來計算「本次新增幾件」的 log 數字，不影響輸出內容。

純標準函式庫，無外部依賴。任何一個縣市失敗只記錄在 sources[] 裡（ok:false + 錯誤訊息），
不拖垮其他縣市；本機檔案寫成功是基本盤，Oracle 波動不該讓整支失敗。
"""

import html as html_lib
import json
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

TZ_TAIPEI = timezone(timedelta(hours=8))
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) HavenCircle-crawler/1.0"

# ============================================================
# 產品決策：案類過濾規則（務必維持這份註解，改規則前先想一下理由）
# ============================================================
# 收：案類「火災」「災害搶救」全部；案類「緊急救護」但案別「車禍」的（現行系統
#     完全漏掉、使用者最在意的類別）。
# 不收：一般救護（急病、創傷、路倒、OHCA、患者服務…）——屬個人醫療、涉個資，
#     不是鄰里安全事件。
# 不收：捕蜂、捉蛇——這類案件在所有站的案類都是「其他」而非「緊急救護」，
#     天然被下面的白名單擋掉，不需要額外黑名單。
FULL_ACCEPT_CASE_TYPES = {"火災", "災害搶救"}
# 各站用詞不一致：DTS／多數 HTML 站用「緊急救護」，台北市 service119 用「救護」
AMBULANCE_CASE_TYPES = {"緊急救護", "救護"}
CAR_ACCIDENT_SUBTYPES = {"車禍"}

# 苗栗清單裡卡著 5 月的舊案，其他站也可能有類似殘留，一律用時間窗擋掉
MAX_AGE_HOURS = 24


def is_relevant(case_type, case_sub):
    if case_type in FULL_ACCEPT_CASE_TYPES:
        return True
    if case_type in AMBULANCE_CASE_TYPES and case_sub in CAR_ACCIDENT_SUBTYPES:
        return True
    return False


OUTPUT_PATH = Path(__file__).parent / "latest_city_fire.json"
SEEN_PATH = Path(__file__).parent / "seen_city_fire.json"
SEEN_TTL_DAYS = 3

INGEST_URL = "https://havencircle.looptw.com/crawler/api/ingest.php?dataset=cityfire"
INGEST_KEY_PATH = Path(__file__).parent / "ingest_key.txt"

# 台中沿用 fetch_taichung_fire.py 已驗證的分頁邏輯：救護量遠大於火災，
# 火災會很快被擠出第 1 頁，多掃幾頁再靠去重收斂，避免漏接。
TAICHUNG_PAGES_PER_RUN = 6


# ============================================================
# SOURCES：全部縣市集中在這一張表，新增縣市只要加一行 + 對應 type 已存在的話
# 完全不用寫新函式；type 不存在才需要新增一個 parser（見下方 HANDLERS）。
# ============================================================
SOURCES = [
    # --- 型態 A：DTS 系統（POST /DTS/caselist/xml）---
    {"county": "台南市", "type": "dts", "scheme": "https", "host": "119dts.tncfd.gov.tw",
     "sourceName": "台南市消防局", "enabled": True,
     "note": "個資特例：官方 HTML 版只顯示到行政區，這支比照只留 district，捨棄路名"},
    {"county": "高雄市", "type": "dts", "scheme": "https", "host": "119dts.fdkc.gov.tw",
     "sourceName": "高雄市消防局", "enabled": True},
    {"county": "雲林縣", "type": "dts", "scheme": "https", "host": "119.ylfire.gov.tw",
     "sourceName": "雲林縣消防局", "enabled": True},
    {"county": "苗栗縣", "type": "dts", "scheme": "https", "host": "119mlfire.mlfd.gov.tw",
     "sourceName": "苗栗縣消防局", "enabled": True,
     "note": "清單裡混大量捕蜂捉蛇（案類＝其他）與舊案，靠白名單+時間窗過濾"},
    {"county": "基隆市", "type": "dts", "scheme": "https", "host": "klc-dt.klfd.klcg.gov.tw",
     "sourceName": "基隆市消防局", "enabled": True},
    {"county": "新竹市", "type": "dts", "scheme": "https", "host": "119.hcfd.gov.tw",
     "sourceName": "新竹市消防局", "enabled": True},
    {"county": "宜蘭縣", "type": "dts", "scheme": "https", "host": "nfa119.e-land.gov.tw",
     "sourceName": "宜蘭縣消防局", "enabled": True},
    {"county": "澎湖縣", "type": "dts", "scheme": "http", "host": "210.241.42.144:8080",
     "sourceName": "澎湖縣消防局", "enabled": True,
     "note": "裸 IP、純 HTTP 非 HTTPS；2026-08-02 實測連線正常（當下案件數為 0）"},

    # --- 型態 B：台北市 service119（POST JSON）---
    {"county": "台北市", "type": "taipei",
     "url": "https://service119.tfd.gov.tw/service119/citizenCase/caseList",
     "sourceName": "台北市消防局", "enabled": True,
     "note": "資料視窗僅約近 1 小時；案別欄位（csCodeName）實測恆為空字串，"
             "無法判斷車禍子類，只能收到火災"},

    # --- 型態 C：各站自有 HTML 頁面 ---
    {"county": "台中市", "type": "taichung",
     "url": "https://www.fire.taichung.gov.tw/caselist/index.asp?Parser=99,8,226",
     "sourceName": "台中市消防局", "enabled": True},
    {"county": "桃園市", "type": "tyfd",
     "url": "https://www.tyfd.gov.tw/cht/index.php?act=caselist",
     "sourceName": "桃園市政府消防局", "enabled": True},
    {"county": "南投縣", "type": "ntfd",
     "url": "https://www.ntfd.gov.tw/index.php?act=caselist",
     "sourceName": "南投縣政府消防局", "enabled": True},
    {"county": "彰化縣", "type": "chfd",
     "url": "https://www.chfd.gov.tw/RealInfo/index.aspx?Parser=99,3,29",
     "sourceName": "彰化縣消防局", "enabled": True,
     "note": "文件警告有 IP 白名單風險；2026-08-02 從本機實測可正常抓取，"
             "若日後從固定機器（如 Mac Mini）改抓失敗，很可能就是踩到白名單"},
    {"county": "嘉義縣", "type": "cyfd",
     "url": "https://cycfb.cyhg.gov.tw/DisasterPrevent.aspx?n=5F10482409025004&sms=ED4E0CDDC2EA92E6",
     "sourceName": "嘉義縣消防局", "enabled": True,
     "note": "受理時間為民國年（115-08-02 = 2026-08-02），parser 內已 +1911 轉換"},
    {"county": "屏東縣", "type": "pthg",
     "url": "https://pteoc.pthg.gov.tw/News119",
     "sourceName": "屏東縣消防局", "enabled": True,
     "note": "頁面無案別欄位，只能收到案類在白名單內的（火災／災害搶救），"
             "車禍無法從屏東判斷；內容為 HTML entity 編碼，parser 內已 unescape"},

    # --- 型態 D：新北市（獨立端點，雙層 JSON GeoJSON，自帶精確座標）---
    {"county": "新北市", "type": "ntpc",
     "sourceName": "新北市消防局", "enabled": True,
     "note": "端點無案別/時間欄位；救護案件（type=AmbulanceBack）的 endPointInfo "
             "只有送醫醫院名稱、沒有案類與地點欄位，無法判斷車禍也無法判斷事發地點，"
             "與台北市 service119 情況相同，故只收火災（type 開頭 Fire）；"
             "occurredAt 用 seen.json 記錄「首次看到 featureId 的時間」兜底；"
             "案件結束後約 5 分鐘就從清單消失，視窗是所有來源裡最短的之一，"
             "建議獨立跑 60 秒輪詢（現行 cron 是 2 分鐘，漏接風險偏高）"},
]


def log(msg):
    ts = datetime.now(TZ_TAIPEI).strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def http_get(url, timeout=25):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode("utf-8", errors="replace")


def http_post(url, data=b"", headers=None, timeout=25):
    hdrs = {"User-Agent": USER_AGENT}
    if headers:
        hdrs.update(headers)
    req = urllib.request.Request(url, data=data, headers=hdrs, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode("utf-8", errors="replace")


# ============================================================
# 共用：時間解析、行政區擷取、記錄組裝
# ============================================================

# 各站時間格式不一：DTS/台北/彰化用「YYYY/MM/DD HH:MM[:SS]」，
# 南投/桃園用「YYYY-MM-DD HH:MM」，嘉義用民國年（另外處理，見 parse_roc_datetime）。
_DATETIME_RE = re.compile(
    r"^(\d{4})[/-](\d{2})[/-](\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?"
)
# 嘉義：民國年「115-08-02 11:11:06」
_ROC_DATETIME_RE = re.compile(
    r"^(\d{2,3})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?"
)


def parse_datetime(text):
    """西元年時間字串 → aware datetime；解析失敗回 None（呼叫端就地丟棄該筆）。"""
    if not text:
        return None
    m = _DATETIME_RE.match(text.strip())
    if not m:
        return None
    y, mo, d, h, mi, s = m.groups()
    try:
        return datetime(int(y), int(mo), int(d), int(h), int(mi), int(s or 0), tzinfo=TZ_TAIPEI)
    except ValueError:
        return None


def parse_roc_datetime(text):
    """民國年時間字串（115-08-02 11:11:06）→ 西元 aware datetime；+1911。"""
    if not text:
        return None
    m = _ROC_DATETIME_RE.match(text.strip())
    if not m:
        return None
    roc_y, mo, d, h, mi, s = m.groups()
    try:
        return datetime(int(roc_y) + 1911, int(mo), int(d), int(h), int(mi), int(s or 0),
                         tzinfo=TZ_TAIPEI)
    except ValueError:
        return None


def build_record(raw, source):
    """把單一 parser 產出的原始欄位（見各 parse_* 函式）組成統一輸出 schema。

    raw 需含：caseType, caseSub, location, district, unit, status,
              occurredAt（已是 aware datetime）, nativeId（可為 None）。
              latitude / longitude 為選填（僅新北市 ntpc 這條線自帶座標），
              沒有的來源用 dict.get 拿 None，不會報錯。
    回傳 None 代表這筆該丟棄（不符案類白名單，或超過時間窗）。
    """
    if raw["occurredAt"] is None:
        return None
    now = datetime.now(TZ_TAIPEI)
    if now - raw["occurredAt"] > timedelta(hours=MAX_AGE_HOURS):
        return None
    if not is_relevant(raw["caseType"], raw["caseSub"]):
        return None

    county = source["county"]
    location = raw["location"]
    if county == "台南市":
        # 個資特例（合規要求）：台南官方 HTML 頁面明寫「因民眾個資考量，
        # 救護案件發生地點只顯示至行政區」，但 XML 端點會吐出完整路名。
        # 這裡刻意只保留 district、捨棄路名，尊重站方自己選擇的個資遮罩。
        location = raw["district"]

    if raw["nativeId"]:
        source_id = f"{county}|{raw['nativeId']}"
    else:
        source_id = f"{county}|{raw['occurredAt'].isoformat()}|{location}"

    return {
        "county": county,
        "district": raw["district"],
        "location": location,
        "caseType": raw["caseType"],
        "caseSub": raw["caseSub"],
        "occurredAt": raw["occurredAt"].isoformat(),
        "unit": raw["unit"],
        "status": raw["status"],
        "sourceId": source_id,
        "sourceName": source["sourceName"],
        "latitude": raw.get("latitude"),
        "longitude": raw.get("longitude"),
    }


# ============================================================
# 型態 A：DTS 系統
# ============================================================

_DTS_CASE_RE = re.compile(r"<case>(.*?)</case>", re.DOTALL)


def _dts_field(block, tag):
    # PERSION_COUNT / CAR_COUNT 這兩欄是站方 bug（回傳未執行的 SQL 字串），
    # 刻意不放進要抽取的欄位清單裡，完全不解析、不輸出。
    m = re.search(fr"<{tag}>([^<]*)</{tag}>", block)
    return m.group(1).strip() if m else ""


def parse_dts_xml(xml_text, county):
    """純解析函式（不碰網路），方便單元測試；fetch_dts 只負責把 HTTP 回應丟進來。"""
    rows = []
    for m in _DTS_CASE_RE.finditer(xml_text):
        block = m.group(1)
        district = _dts_field(block, "TOWN_NAME")
        addr = _dts_field(block, "ADDR")
        rows.append({
            "nativeId": _dts_field(block, "CS_NO"),
            "caseType": _dts_field(block, "KIND"),
            "caseSub": _dts_field(block, "CS_CODE"),
            "location": addr or f"{county}{district}",
            "district": district,
            "unit": _dts_field(block, "DEPT_NAME"),
            "status": _dts_field(block, "STATUS"),
            "occurredAt": parse_datetime(_dts_field(block, "IN_TIME")),
        })
    return rows


def fetch_dts(source):
    url = f"{source['scheme']}://{source['host']}/DTS/caselist/xml"
    xml_text = http_post(url, data=b"")
    return parse_dts_xml(xml_text, source["county"])


# ============================================================
# 型態 B：台北市 service119
# ============================================================

# 「臺北市」「台北市」兩種寫法都要吃，正則裡放兩個字元
_TAIPEI_DISTRICT_RE = re.compile(r"[台臺]北市([一-鿿]{1,3}區)")


def parse_taipei_json(data):
    """純解析函式；data 是已經 json.loads 過的 dict。"""
    rows = []
    for r in data.get("rows", []):
        place = r.get("csPlace") or r.get("csPlaceFuzzy") or ""
        dist_m = _TAIPEI_DISTRICT_RE.search(place)
        rows.append({
            "nativeId": None,  # 台北無原生案號，用時間+地點合成鍵
            "caseType": (r.get("csKindName") or "").strip(),
            "caseSub": (r.get("csCodeName") or "").strip(),
            "location": place,
            "district": dist_m.group(1) if dist_m else "",
            "unit": "",  # 這支端點沒有回傳分隊資訊
            "status": (r.get("caseStatus") or "").strip(),
            "occurredAt": parse_datetime(r.get("inTime", "")),
        })
    return rows


def fetch_taipei(source):
    body = http_post(source["url"], data=b"{}", headers={"Content-Type": "application/json"})
    return parse_taipei_json(json.loads(body))


# ============================================================
# 型態 C-1：台中市（沿用 fetch_taichung_fire.py 已驗證的分頁 parser）
# ============================================================

_TC_PAGE_SUFFIX = ",,,,,,,,{page}"
_TC_FIELD_RE = {
    "acceptedAt": r'data-th="受理時間："[^>]*>([^<]+)<',
    "caseType": r'data-th="案類："[^>]*>([^<]+)<',
    "caseSub": r'data-th="案別[："]?[^>]*>([^<]+)<',
    "unit": r'data-th="派遣分隊："[^>]*>([^<]+)<',
    "status": r'data-th="執行狀況："[^>]*>([^<]+)<',
}
_TC_ADDR_RE = re.compile(r'js_addr="([^"]+)"')
_TC_DISTRICT_RE = re.compile(r"台中市([一-鿿]{1,3}區)")


def parse_taichung_page(page_html):
    """純解析函式：單一頁面的 HTML → rows。"""
    rows = []
    for chunk in re.split(r"<li\b", page_html):
        if "list_word" not in chunk:
            continue
        fields = {}
        for key, pattern in _TC_FIELD_RE.items():
            m = re.search(pattern, chunk)
            fields[key] = m.group(1).strip() if m else ""
        if not fields["acceptedAt"] or not fields["caseType"]:
            continue
        addr_m = _TC_ADDR_RE.search(chunk)
        location = addr_m.group(1).strip() if addr_m else ""
        dist_m = _TC_DISTRICT_RE.search(location)
        rows.append({
            "nativeId": None,  # 台中頁面無原生案號，用時間+地點合成鍵
            "caseType": fields["caseType"],
            "caseSub": fields["caseSub"],
            "location": location,
            "district": dist_m.group(1) if dist_m else "",
            "unit": fields["unit"],
            "status": fields["status"],
            "occurredAt": parse_datetime(fields["acceptedAt"]),
        })
    return rows


def fetch_taichung(source):
    rows = []
    pages_fetched = 0
    for page in range(1, TAICHUNG_PAGES_PER_RUN + 1):
        url = source["url"] + _TC_PAGE_SUFFIX.format(page=page)
        try:
            page_html = http_get(url)
        except (urllib.error.URLError, TimeoutError) as e:
            log(f"[警告] 台中市第 {page} 頁抓取失敗（略過）：{e}")
            continue
        pages_fetched += 1
        rows.extend(parse_taichung_page(page_html))
    log(f"[台中市] 掃了 {pages_fetched}/{TAICHUNG_PAGES_PER_RUN} 頁")
    return rows


# ============================================================
# 型態 C-2：桃園市
# ============================================================

_TYFD_DISTRICT_RE = re.compile(r"桃園市([一-鿿]{1,3}區)")


def parse_tyfd_html(page_html):
    """純解析函式。"""
    rows = []
    # 站方每筆案件是一個 <div class="tr">…</div>，欄位名內嵌在
    # <span class="title">案類</span> 這種標籤裡；用 split 切塊比正則配對巢狀 div 穩定
    # （比照 fetch_taichung_fire.py 用 <li 切塊的做法）。第一塊是表頭（只有 th 沒有 td），跳過。
    for chunk in page_html.split('<div class="tr">')[1:]:
        if 'class="td' not in chunk:
            continue
        time_m = re.search(r'<span class="title">發生時間</span><date>([^<]+)</date>', chunk)
        case_type_m = re.search(r'<span class="title">案類</span>([^<]*)', chunk)
        case_sub_m = re.search(r'<span class="title">案別</span>([^<]*)', chunk)
        location_m = re.search(r'<span class="title">發生地點</span>([^<]*)', chunk)
        unit_m = re.search(r'<span class="title">派遣分隊</span>([^<]*)', chunk)
        status_m = re.search(r'class="[^"]*\bstate\b[^"]*">([^<]*)</span>', chunk)
        location = location_m.group(1).strip() if location_m else ""
        dist_m = _TYFD_DISTRICT_RE.search(location)
        rows.append({
            "nativeId": None,
            "caseType": case_type_m.group(1).strip() if case_type_m else "",
            "caseSub": case_sub_m.group(1).strip() if case_sub_m else "",
            "location": location,
            "district": dist_m.group(1) if dist_m else "",
            "unit": unit_m.group(1).strip() if unit_m else "",
            "status": status_m.group(1).strip() if status_m else "",
            "occurredAt": parse_datetime(time_m.group(1)) if time_m else None,
        })
    return rows


def fetch_tyfd(source):
    page_html = http_get(source["url"])
    return parse_tyfd_html(page_html)


# ============================================================
# 型態 C-3：南投縣
# ============================================================

_NTFD_FIELD_RE = {
    "timeText": r'data-th="受理案件"[^>]*>([^<]+)<',
    "caseType": r'data-th="案類"[^>]*>([^<]+)<',
    "caseSub": r'data-th="案別"[^>]*>([^<]*)<',
    "location": r'data-th="發生地點"[^>]*>([^<]*)<',
    "unit": r'data-th="派遣分隊"[^>]*>([^<]*)<',
}
_NTFD_STATUS_RE = re.compile(r'data-th="執行狀況"[^>]*>.*?<span[^>]*>([^<]*)</span>', re.DOTALL)
_NTFD_DISTRICT_RE = re.compile(r"南投縣([一-鿿]{1,3}(?:鄉|鎮|市))")


def parse_ntfd_html(page_html):
    """純解析函式。"""
    rows = []
    for chunk in page_html.split("<tr>")[1:]:
        if 'data-th="受理案件"' not in chunk:
            continue
        fields = {}
        for key, pattern in _NTFD_FIELD_RE.items():
            m = re.search(pattern, chunk)
            fields[key] = m.group(1).strip() if m else ""
        status_m = _NTFD_STATUS_RE.search(chunk)
        dist_m = _NTFD_DISTRICT_RE.search(fields["location"])
        rows.append({
            "nativeId": None,
            "caseType": fields["caseType"],
            "caseSub": fields["caseSub"],
            "location": fields["location"],
            "district": dist_m.group(1) if dist_m else "",
            "unit": fields["unit"],
            "status": status_m.group(1).strip() if status_m else "",
            "occurredAt": parse_datetime(fields["timeText"]),
        })
    return rows


def fetch_ntfd(source):
    page_html = http_get(source["url"])
    return parse_ntfd_html(page_html)


# ============================================================
# 型態 C-4：彰化縣（跟台中同一套 CMS 慣例：<li> + data-th span）
# ============================================================

_CHFD_FIELD_RE = {
    "timeText": r'data-th="受理時間："[^>]*>(?:<span[^>]*>[^<]*</span>)?([^<]*)<',
    "caseType": r'data-th="案類："[^>]*>(?:<span[^>]*>[^<]*</span>)?([^<]*)<',
    "caseSub": r'data-th="案別："[^>]*>(?:<span[^>]*>[^<]*</span>)?([^<]*)<',
    "unit": r'data-th="派遣分隊："[^>]*>(?:<span[^>]*>[^<]*</span>)?([^<]*)<',
    "status": r'data-th="執行狀況："[^>]*>(?:<span[^>]*>[^<]*</span>)?([^<]*)<',
}
# 發生地點欄多包一層 <a class="map_btn">文字 <img…></a>，跳過 sr-only span 後再吃 <a> 內文字
_CHFD_LOCATION_RE = re.compile(
    r'data-th="發生地點："[^>]*>(?:<span[^>]*>[^<]*</span>)?<a[^>]*>([^<]+)'
)
# 彰化頁面地點文字不帶縣名（例：「芬園鄉彰南路四段」），直接從字首比對鄉鎮市
_CHFD_DISTRICT_RE = re.compile(r"^([一-鿿]{1,3}(?:區|鄉|鎮|市))")


def parse_chfd_html(page_html, county):
    """純解析函式；location 前要補的縣名由呼叫端傳入（頁面本身不帶縣名）。"""
    rows = []
    for chunk in re.split(r"<li\b", page_html):
        if "list_date" not in chunk:
            continue
        fields = {}
        for key, pattern in _CHFD_FIELD_RE.items():
            m = re.search(pattern, chunk)
            fields[key] = m.group(1).strip() if m else ""
        loc_m = _CHFD_LOCATION_RE.search(chunk)
        location = loc_m.group(1).strip() if loc_m else ""
        dist_m = _CHFD_DISTRICT_RE.match(location)
        if not fields["timeText"] or not fields["caseType"]:
            continue
        rows.append({
            "nativeId": None,
            "caseType": fields["caseType"],
            "caseSub": fields["caseSub"],
            "location": f"{county}{location}" if location else "",
            "district": dist_m.group(1) if dist_m else "",
            "unit": fields["unit"],
            "status": fields["status"],
            "occurredAt": parse_datetime(fields["timeText"]),
        })
    return rows


def fetch_chfd(source):
    page_html = http_get(source["url"])
    return parse_chfd_html(page_html, source["county"])


# ============================================================
# 型態 C-5：嘉義縣（民國年 + 「案類-細項」合併欄）
# ============================================================

_CYFD_ROW_RE = re.compile(
    r"<tr>\s*<td>\s*<p>([^<]*)</p>\s*</td>\s*"          # 受理時間（民國年）
    r"<td>\s*<p>([^<]*)</p>\s*</td>\s*"                  # 案類-細項
    r"<td[^>]*>\s*<p>([^<]*)</p>\s*</td>\s*"             # 案發地點
    r"<td>\s*<p>([^<]*)</p>\s*</td>\s*"                  # 派遣分隊
    r"<td>\s*<p>([^<]*)</p>\s*</td>\s*</tr>",            # 案件狀態
    re.DOTALL,
)
_CYFD_DISTRICT_RE = re.compile(r"嘉義縣([一-鿿]{1,3}(?:鄉|鎮|市))")


def parse_cyfd_html(page_html):
    """純解析函式。"""
    rows = []
    for m in _CYFD_ROW_RE.finditer(page_html):
        time_text, type_sub, location, unit, status = (g.strip() for g in m.groups())
        # 案類欄是「緊急救護-車禍」這種合併格式，用第一個「-」拆開；
        # 沒有「-」的（理論上不會發生，保險起見）整段當案類、案別留空
        if "-" in type_sub:
            case_type, case_sub = type_sub.split("-", 1)
        else:
            case_type, case_sub = type_sub, ""
        dist_m = _CYFD_DISTRICT_RE.search(location)
        rows.append({
            "nativeId": None,
            "caseType": case_type.strip(),
            "caseSub": case_sub.strip(),
            "location": location,
            "district": dist_m.group(1) if dist_m else "",
            "unit": unit,
            "status": status,
            "occurredAt": parse_roc_datetime(time_text),
        })
    return rows


def fetch_cyfd(source):
    page_html = http_get(source["url"])
    return parse_cyfd_html(page_html)


# ============================================================
# 型態 C-6：屏東縣（HTML entity 編碼、無案別欄位）
# ============================================================

_PTHG_ROW_RE = re.compile(
    r"<tr>\s*<td>\s*([^<]*)\s*</td>\s*"                  # 案類
    r'<td class="text-start">\s*([^<]*)\s*</td>\s*'      # 發生地點
    r"<td>\s*([^<]*)\s*</td>\s*"                          # 派遣分隊
    r"<td>\s*([^<]*)\s*</td>\s*"                          # 執行狀況
    r"<td>\s*([^<]*)\s*</td>\s*</tr>",                    # 受理時間
    re.DOTALL,
)
_PTHG_DISTRICT_RE = re.compile(r"屏東縣([一-鿿]{1,3}(?:區|鄉|鎮|市))")


def parse_pthg_html(page_html):
    """純解析函式；呼叫端要自己先 html.unescape 過再傳進來（見 fetch_pthg）。"""
    rows = []
    for m in _PTHG_ROW_RE.finditer(page_html):
        case_type, location, unit, status, time_text = (g.strip() for g in m.groups())
        dist_m = _PTHG_DISTRICT_RE.search(location)
        rows.append({
            "nativeId": None,
            "caseType": case_type,
            "caseSub": "",  # 屏東頁面沒有案別欄位，車禍無法從這個來源判斷
            "location": location,
            "district": dist_m.group(1) if dist_m else "",
            "unit": unit,
            "status": status,
            "occurredAt": parse_datetime(time_text),
        })
    return rows


def fetch_pthg(source):
    # 整頁是 HTML entity 編碼（&#x7DCA;&#x6025;… 這種數值字元參照），要先 unescape
    # 才看得到中文；html.unescape 對 &#xHHHH; / &#DDDD; / &amp; 這些都能正確解碼。
    page_html = html_lib.unescape(http_get(source["url"]))
    return parse_pthg_html(page_html)


# ============================================================
# 型態 D：新北市（獨立端點，雙層 JSON GeoJSON，自帶座標，無時間欄位）
# ============================================================

# 主機＋備援，裸請求（實測不需要 UA/Referer/cookie/token，連打 15 次無限流）
NTPC_HOSTS = ("e.ntpc.gov.tw", "e1.ntpc.gov.tw")
_NTPC_DISTRICT_RE = re.compile(r"新北市([一-鿿]{1,3}區)")


def parse_ntpc_geojson(outer_text):
    """純解析函式（不碰網路、不碰 seen.json）。

    回應是雙層 JSON：外層 {"status":200,"data":"...字串化的 GeoJSON..."}，
    data 欄位要再 json.loads 一次才是真正的 FeatureCollection。

    只收 type 以 Fire 開頭的案件（FireV2 等）；救護案件（AmbulanceBack）的
    endPointInfo 只有送醫醫院名稱，沒有案類/地點欄位，無法判斷車禍也無法判斷
    事發地點，收進來只會是醫院名稱洗版且涉個資，直接濾掉。

    caseType 正規化成白名單裡的「火災」讓既有過濾規則自動放行；細分
    （一般火警／大型火警）放進 caseSub。occurredAt 這裡先留 None，
    由 fetch_ntpc 用 seen.json 的首見時間補上（payload 完全沒有時間欄位）。
    """
    outer = json.loads(outer_text)
    try:
        geojson = json.loads(outer.get("data") or "{}")
    except (json.JSONDecodeError, TypeError):
        geojson = {}

    rows = []
    for feature in geojson.get("features", []):
        props = feature.get("properties") or {}
        case_type = props.get("type") or ""
        if not case_type.startswith("Fire"):
            continue

        location = props.get("endPointInfo") or ""
        dist_m = _NTPC_DISTRICT_RE.search(location)
        case_list = props.get("caseList") or []
        unit = "、".join(
            c.get("startPointInfo", "") for c in case_list if c.get("startPointInfo")
        )
        lat = props.get("lat")
        lng = props.get("lng")

        rows.append({
            "nativeId": props.get("featureId"),
            "caseType": "火災",
            "caseSub": props.get("fireType") or "",
            "location": location,
            "district": dist_m.group(1) if dist_m else "",
            "unit": unit,
            "status": "",  # 端點沒有獨立狀態欄位
            "occurredAt": None,  # fetch_ntpc 用首見時間補上
            "latitude": float(lat) if lat is not None else None,
            "longitude": float(lng) if lng is not None else None,
        })
    return rows


def _fill_ntpc_first_seen(rows, seen, now_iso):
    """用 seen.json 記錄「首次看到這個 featureId 的時間」當作 occurredAt 兜底。

    純函式（不做磁碟 I/O）方便單元測試；seen 是呼叫端傳入、就地修改的 dict，
    key 刻意加 "ntpc-first-seen|" 字首，避免跟主程式用來計算「本次新增幾件」
    的 {縣市}|{nativeId} 鍵混在同一個命名空間。回傳 seen 是否被修改，
    呼叫端據此決定要不要寫回檔案。
    """
    changed = False
    for raw in rows:
        feature_id = raw["nativeId"]
        if not feature_id:
            continue
        key = f"ntpc-first-seen|{feature_id}"
        if key not in seen:
            seen[key] = now_iso
            changed = True
        raw["occurredAt"] = datetime.fromisoformat(seen[key])
    return changed


def fetch_ntpc(source):
    last_error = None
    outer_text = None
    for host in NTPC_HOSTS:
        url = f"https://{host}/v3/api/map/dynamic/layer/rescue"
        try:
            outer_text = http_get(url)
            break
        except (urllib.error.URLError, TimeoutError) as e:
            last_error = e
            continue
    if outer_text is None:
        raise last_error

    rows = parse_ntpc_geojson(outer_text)

    seen = load_seen()
    now_iso = datetime.now(TZ_TAIPEI).isoformat()
    if _fill_ntpc_first_seen(rows, seen, now_iso):
        save_seen(seen)
    return rows


HANDLERS = {
    "dts": fetch_dts,
    "taipei": fetch_taipei,
    "taichung": fetch_taichung,
    "tyfd": fetch_tyfd,
    "ntfd": fetch_ntfd,
    "chfd": fetch_chfd,
    "cyfd": fetch_cyfd,
    "pthg": fetch_pthg,
    "ntpc": fetch_ntpc,
}


def load_seen():
    if not SEEN_PATH.exists():
        return {}
    try:
        return json.loads(SEEN_PATH.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}


def save_seen(seen):
    cutoff = (datetime.now(TZ_TAIPEI) - timedelta(days=SEEN_TTL_DAYS)).isoformat()
    pruned = {k: v for k, v in seen.items() if v >= cutoff}
    SEEN_PATH.write_text(json.dumps(pruned, ensure_ascii=False), encoding="utf-8")


def push_to_oracle(output):
    """失敗只警告不中斷：本機寫檔是基本盤，Oracle 波動不該讓 cron 整支失敗。"""
    if not INGEST_KEY_PATH.exists():
        log(f"[警告] 找不到 {INGEST_KEY_PATH.name}，跳過推送 Oracle")
        return
    key = INGEST_KEY_PATH.read_text(encoding="utf-8").strip()
    body = json.dumps(output, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        INGEST_URL,
        data=body,
        headers={"Content-Type": "application/json", "X-Ingest-Key": key},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            log(f"[推送] Oracle 已接收：{resp.read().decode('utf-8')}")
    except urllib.error.URLError as e:
        log(f"[警告] 推送 Oracle 失敗（不中斷）：{e}")


def main():
    seen = load_seen()
    now_iso = datetime.now(TZ_TAIPEI).isoformat()

    sources_report = []
    uniq = {}  # key -> record；同一 key 後面覆蓋前面，天然完成「狀態更新」

    for source in SOURCES:
        county = source["county"]
        if not source.get("enabled", True):
            sources_report.append({
                "county": county, "sourceName": source["sourceName"],
                "ok": False, "count": 0,
                "error": f"已停用：{source.get('note', '')}",
            })
            log(f"[跳過] {county}（已停用）：{source.get('note', '')}")
            continue

        handler = HANDLERS[source["type"]]
        try:
            raw_rows = handler(source)
        except (urllib.error.URLError, TimeoutError, ValueError) as e:
            # 單一縣市失敗不能拖垮整支：記錄錯誤、繼續下一個縣市
            sources_report.append({
                "county": county, "sourceName": source["sourceName"],
                "ok": False, "count": 0, "error": str(e),
            })
            log(f"[警告] {county} 抓取失敗（略過，不影響其他縣市）：{e}")
            continue

        kept = 0
        for raw in raw_rows:
            record = build_record(raw, source)
            if record is None:
                continue
            uniq[record["sourceId"]] = record
            kept += 1
        sources_report.append({
            "county": county, "sourceName": source["sourceName"],
            "ok": True, "count": kept,
        })
        log(f"[完成] {county}：掃到 {len(raw_rows)} 筆，符合條件 {kept} 筆")

    # 新北（ntpc）的 handler 在上面迴圈中途會自行 load_seen/save_seen 寫入
    # 「首次看到 featureId 的時間」；這裡重新讀一次檔案撿最新內容，避免下面
    # save_seen 用迴圈開始前的舊快照覆蓋掉那些寫入（其他縣市的 key 命名空間
    # 跟 ntpc 的 "ntpc-first-seen|" 字首不會撞在一起，重讀不影響既有邏輯）。
    seen = load_seen()
    fresh_keys = [k for k in uniq if k not in seen]
    for k in uniq:
        seen[k] = now_iso

    events = sorted(uniq.values(), key=lambda r: r["occurredAt"], reverse=True)
    car_accident_count = sum(1 for r in events if r["caseSub"] in CAR_ACCIDENT_SUBTYPES)

    output = {
        "fetchedAt": now_iso,
        "source": "全台縣市消防局-即時派遣",
        "sources": sources_report,
        "events": events,
    }
    OUTPUT_PATH.write_text(
        json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    save_seen(seen)

    ok_counties = [s["county"] for s in sources_report if s["ok"]]
    failed_counties = [s["county"] for s in sources_report if not s["ok"]]
    log(
        f"[完成] {len(ok_counties)}/{len(SOURCES)} 個縣市成功，共 {len(events)} 件"
        f"（本次新增 {len(fresh_keys)} 件，其中車禍 {car_accident_count} 件）→ {OUTPUT_PATH}"
    )
    if failed_counties:
        log(f"[完成] 失敗縣市：{'、'.join(failed_counties)}")
    push_to_oracle(output)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001 — cron 守門：任何未預期例外都印出而非讓排程靜默死掉
        log(f"[錯誤] 未預期例外：{e}")
        sys.exit(1)

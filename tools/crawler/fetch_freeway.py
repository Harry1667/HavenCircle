#!/usr/bin/env python3
"""高速公路局「即時路況事件」爬蟲：抓國道即時交通事故。

角色：NCDR／消防局兩支爬蟲都拿不到國道路況——國道事故（車禍、翻覆）是
獨立示警來源，跟壅塞、施工、特殊管制等「非事故」事件混在同一份 feed 裡，
需要靠 EventType 篩選。

資料來源：https://tisvcloud.freeway.gov.tw/history/motc20/LiveEvents.xml
  純 XML（UTF-8）、免金鑰、站方每 60 秒更新一次（UpdateInterval 欄位可驗證）。
  實測延遲僅 32 秒，故輪詢間隔建議 60-90 秒即可跟上（太短只是浪費站方頻寬，
  站方本來就沒那麼快更新）。

去重：以 EventID 為鍵（seen.json 持久化，近 3 天內不重複輸出「新增」計數；
本次快照仍會完整輸出全部事件，供 Oracle 端保有近況）。

第二來源（2026-10 加入）：警廣「即時路況」開放資料（rtr.pbs.gov.tw），民眾通報
（srcdetail=熱心聽眾）或各單位登錄的事故，帶經緯度、分鐘級更新，轉成同一種事件
格式併入本資料集輸出——App 已上架且只認 freeway 這個資料集的欄位，所以不新增資料集。
詳見 fetch_pbs() / parse_pbs_records()。

純標準函式庫，無外部依賴（比照 fetch_taichung_fire.py）。任何一步失敗只印
錯不 crash，讓 cron 下次重試；本機檔案寫成功是基本盤，Oracle 波動不該讓整
支失敗。
"""

import json
import re
import sys
import unicodedata
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from pathlib import Path

TZ_TAIPEI = timezone(timedelta(hours=8))

URL = "https://tisvcloud.freeway.gov.tw/history/motc20/LiveEvents.xml"
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) HavenCircle-crawler/1.0"

# EventType 代碼對照（2026-08-02 實測今日出現 2/3/4/8，未出現 1）。
# 目前只收「1＝交通事故」；壅塞／施工／管制屬交通資訊而非鄰里安全事件。
# 日後若要放寬（例如納入散落物、故障車），只需把代碼加進 RELEVANT_EVENT_TYPES，
# 不必更動解析邏輯。
EVENT_TYPE_TABLE = {
    "1": "交通事故",
    "2": "施工事件",
    "3": "壅塞事件",
    "4": "特殊管制事件",
    "8": "其他異常告警（含散落物、故障車）",
}
RELEVANT_EVENT_TYPES = {"1"}

# ── 警廣即時路況（第二來源）──────────────────────────────────────────────
PBS_URL = "https://rtr.pbs.gov.tw/NMP103_PbsWS/resources/roadData/opendata"
# 只收「事故」「災變」。「交通障礙」（紙箱、故障車、散落物）屬交通資訊而非安全事件，
# 且 App 端會把本資料集所有事件的標題統一寫成「…交通事故」，收進來會誤導使用者；
# 阻塞／施工／管制／號誌故障同理不收。
PBS_RELEVANT_TYPES = {"事故", "災變"}
# 警廣事件超過這個時數就不輸出（與 App 端 3 小時 TTL 一致，避免舊事故被當成新事件）
PBS_MAX_AGE_HOURS = 3
# 事件時間比現在還晚超過這個分鐘數視為資料異常（實測 feed 出現過未來日期），丟棄
PBS_MAX_FUTURE_MINUTES = 10
# comment 含這些字樣＝已排除／已結束，不可當成進行中（App 沒有「已結束」欄位，直接不輸出）
PBS_RESOLVED_KEYWORDS = ("排除", "自行駛離", "已駛離", "已離開", "已撤離", "已清除", "已解除", "恢復通行")
# 「未排除／尚未排除」含「排除」二字，但其實仍在進行中，要先剔除再判斷
PBS_NOT_RESOLVED_PATTERNS = ("未排除", "尚未排除", "無法排除", "未駛離", "尚未駛離")
PBS_DISCLAIMER = "【警廣即時路況，未經官方確認】"
PBS_DISCLAIMER_CITIZEN = "【警廣即時路況・民眾通報，未經官方確認】"

OUTPUT_PATH = Path(__file__).parent / "latest_freeway.json"
SEEN_PATH = Path(__file__).parent / "seen_freeway.json"
# 去重記憶只保留近 3 天，避免 seen.json 無限膨脹
SEEN_TTL_DAYS = 3

INGEST_URL = "https://havencircle.looptw.com/crawler/api/ingest.php?dataset=freeway"
INGEST_KEY_PATH = Path(__file__).parent / "ingest_key.txt"


def log(msg):
    ts = datetime.now(TZ_TAIPEI).strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def fetch_xml():
    req = urllib.request.Request(URL, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=25) as resp:
        return resp.read()


def parse_position(text):
    """解析 WKT 格式 `POINT(經度 緯度)`。

    注意：括號內是「經度在前、緯度在後」，跟一般 (lat, lon) 口語順序相反；
    寫反的話整批座標會落到錯誤位置（緯經互換，地圖上會偏移到不合理的地方）。
    """
    if not text or not text.startswith("POINT("):
        return None, None
    inner = text[len("POINT(") : text.rindex(")")]
    parts = inner.split()
    if len(parts) != 2:
        return None, None
    lon, lat = parts  # 順序：經度、緯度
    try:
        return float(lat), float(lon)
    except ValueError:
        return None, None


def parse_records(xml_bytes):
    """解析 LiveEventList，只回傳 EventType 在白名單內（目前只有交通事故）的事件。"""
    root = ET.fromstring(xml_bytes)
    records = []
    for ev in root.findall("./LiveEvents/LiveEvent"):
        event_type = (ev.findtext("EventType") or "").strip()
        if event_type not in RELEVANT_EVENT_TYPES:
            continue

        event_id = (ev.findtext("EventID") or "").strip()
        if not event_id:
            continue  # 沒有唯一鍵就無法去重，跳過

        highway = ev.find("./Location/FreeExpressHighway")
        road = highway.findtext("Road", "").strip() if highway is not None else ""
        direction = highway.findtext("Direction", "").strip() if highway is not None else ""
        start_km = highway.findtext("StartKM", "").strip() if highway is not None else ""
        section_start = highway.findtext("SectionStart", "").strip() if highway is not None else ""
        section_end = highway.findtext("SectionEnd", "").strip() if highway is not None else ""
        section = f"{section_start}-{section_end}" if section_start or section_end else ""

        lat, lon = parse_position(ev.findtext("Positions", ""))

        records.append(
            {
                "eventId": event_id,
                "road": road,
                "direction": direction,
                "km": start_km,
                "section": section,
                "description": (ev.findtext("Description") or "").strip(),
                "latitude": lat,
                "longitude": lon,
                "occurredAt": (ev.findtext("EffectiveTime") or "").strip(),
                "eventType": event_type,
            }
        )
    return records


def fetch_pbs():
    """抓警廣即時路況 JSON。回傳 {"result": [...]} 解開後的 list。"""
    req = urllib.request.Request(
        PBS_URL, headers={"User-Agent": USER_AGENT, "Accept": "application/json, */*"}
    )
    with urllib.request.urlopen(req, timeout=25) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
    # 實測外層是 {"result": [...]}；也容忍直接回陣列
    rows = payload.get("result") if isinstance(payload, dict) else payload
    if not isinstance(rows, list):
        raise ValueError("警廣回傳格式異常：找不到 result 陣列")
    return rows


def _pbs_is_resolved(comment):
    """comment 是否表示已排除／已結束。"""
    text = comment
    for pat in PBS_NOT_RESOLVED_PATTERNS:
        text = text.replace(pat, "")
    return any(k in text for k in PBS_RESOLVED_KEYWORDS)


def _pbs_occurred_at(row):
    """happendate + happentime（台灣時間）→ aware datetime；格式異常回 None。"""
    date_s = (row.get("happendate") or "").strip()
    time_s = (row.get("happentime") or "").strip().split(".")[0]
    try:
        naive = datetime.strptime(f"{date_s} {time_s}", "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return None
    return naive.replace(tzinfo=TZ_TAIPEI)


def parse_pbs_records(rows, now=None):
    """把警廣原始資料轉成與國道事件相同欄位的 dict（eventType 固定 "1"，App 才收）。

    過濾：roadtype 白名單、座標有效、UID 去重、超時、未來時間、已排除。
    """
    now = now or datetime.now(TZ_TAIPEI)
    records = []
    seen_uid = set()
    for row in rows:
        if (row.get("roadtype") or "").strip() not in PBS_RELEVANT_TYPES:
            continue
        uid = (row.get("UID") or "").strip()
        if not uid or uid in seen_uid:
            continue
        try:
            lat = float(row.get("y1"))
            lon = float(row.get("x1"))
        except (TypeError, ValueError):
            continue  # 沒座標無法定位，寧可丟棄
        if not (21.5 <= lat <= 26.5 and 118 <= lon <= 123):
            continue  # 不在台澎金馬範圍內，視為壞資料
        occurred = _pbs_occurred_at(row)
        if occurred is None:
            continue
        if occurred > now + timedelta(minutes=PBS_MAX_FUTURE_MINUTES):
            continue
        if now - occurred > timedelta(hours=PBS_MAX_AGE_HOURS):
            continue
        comment = (row.get("comment") or "").strip()
        if _pbs_is_resolved(comment):
            continue
        seen_uid.add(uid)

        # areaNm 格式：「中山高速公路-國道１號」「(八里新店)-台64線」「高雄市-岡山區」
        # 全形數字先 NFKC 正規化成半形（國道１號 → 國道1號）
        area = unicodedata.normalize("NFKC", (row.get("areaNm") or "").strip())
        head, _, tail = area.rpartition("-")
        if re.search(r"(國道|台\d|省道|快速|線$)", tail):
            road = tail  # 國道／省道／快速道路：取路名
        else:
            road = area.replace("-", "")  # 市區道路：用「縣市行政區」當定位名稱
        m = re.search(r"在([\d.]+)公里", comment)
        km = f"{m.group(1)}K" if m else ""

        citizen = "聽眾" in (row.get("srcdetail") or "")
        kind = (row.get("roadtype") or "").strip()
        # App 把標題統一寫成「…交通事故（section）」且來源名稱寫死為「高速公路局」，
        # 所以把真實來源與性質放進 section（會顯示在標題括號內），讓使用者看得到
        section = ("警廣民眾通報" if citizen else "警廣即時路況") + ("・災變" if kind == "災變" else "")
        disclaimer = PBS_DISCLAIMER_CITIZEN if citizen else PBS_DISCLAIMER
        records.append(
            {
                "eventId": f"pbs-{uid}",
                "road": road,
                "direction": (row.get("direction") or "").strip(),
                "km": km,
                "section": section,
                "description": f"{disclaimer}{comment}",
                "latitude": lat,
                "longitude": lon,
                "occurredAt": occurred.isoformat(),
                "eventType": "1",
            }
        )
    return records


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


def main(dry_run=False):
    seen = load_seen()
    now_iso = datetime.now(TZ_TAIPEI).isoformat()

    try:
        xml_bytes = fetch_xml()
    except (urllib.error.URLError, TimeoutError) as e:
        log(f"[警告] 抓取失敗：{e}")
        return

    try:
        events = parse_records(xml_bytes)
    except ET.ParseError as e:
        log(f"[警告] XML 解析失敗（站方回傳格式異常，略過本輪）：{e}")
        return

    # 警廣為額外來源：失敗只警告不中斷，國道原本的部分照常輸出與推送
    pbs_events = []
    try:
        pbs_events = parse_pbs_records(fetch_pbs())
    except (urllib.error.URLError, TimeoutError, ValueError, OSError) as e:
        log(f"[警告] 警廣抓取失敗（不中斷，僅輸出國道）：{e}")
    except Exception as e:  # noqa: BLE001 — 額外來源的任何意外都不得拖垮國道
        log(f"[警告] 警廣處理例外（不中斷，僅輸出國道）：{e}")
    events = events + pbs_events

    fresh = [row for row in events if row["eventId"] not in seen]
    for row in events:
        seen[row["eventId"]] = now_iso

    events_sorted = sorted(events, key=lambda r: r["occurredAt"], reverse=True)
    output = {
        "fetchedAt": now_iso,
        "source": "高速公路局-即時路況事件＋警廣即時路況（民眾通報）",
        "eventTypes": EVENT_TYPE_TABLE,
        "relevantEventTypes": sorted(RELEVANT_EVENT_TYPES),
        "events": events_sorted,
    }
    if dry_run:
        log(f"[dry-run] 國道 {len(events) - len(pbs_events)} 件、警廣 {len(pbs_events)} 件；不寫檔、不推送")
        for row in events_sorted[:5]:
            print(json.dumps(row, ensure_ascii=False))
        return
    OUTPUT_PATH.write_text(
        json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    save_seen(seen)
    log(
        f"[完成] 事故 {len(events_sorted)} 件（國道 {len(events_sorted) - len(pbs_events)}、警廣 {len(pbs_events)}；本次新增 {len(fresh)} 件）→ {OUTPUT_PATH}"
    )
    push_to_oracle(output)


if __name__ == "__main__":
    try:
        main(dry_run="--dry-run" in sys.argv)
    except Exception as e:  # noqa: BLE001 — cron 守門：任何未預期例外都印出而非讓排程靜默死掉
        log(f"[錯誤] 未預期例外：{e}")
        sys.exit(1)

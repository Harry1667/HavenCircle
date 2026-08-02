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

純標準函式庫，無外部依賴（比照 fetch_taichung_fire.py）。任何一步失敗只印
錯不 crash，讓 cron 下次重試；本機檔案寫成功是基本盤，Oracle 波動不該讓整
支失敗。
"""

import json
import sys
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

    fresh = [row for row in events if row["eventId"] not in seen]
    for row in events:
        seen[row["eventId"]] = now_iso

    events_sorted = sorted(events, key=lambda r: r["occurredAt"], reverse=True)
    output = {
        "fetchedAt": now_iso,
        "source": "高速公路局-即時路況事件",
        "eventTypes": EVENT_TYPE_TABLE,
        "relevantEventTypes": sorted(RELEVANT_EVENT_TYPES),
        "events": events_sorted,
    }
    OUTPUT_PATH.write_text(
        json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    save_seen(seen)
    log(
        f"[完成] 交通事故 {len(events_sorted)} 件（本次新增 {len(fresh)} 件）→ {OUTPUT_PATH}"
    )
    push_to_oracle(output)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001 — cron 守門：任何未預期例外都印出而非讓排程靜默死掉
        log(f"[錯誤] 未預期例外：{e}")
        sys.exit(1)

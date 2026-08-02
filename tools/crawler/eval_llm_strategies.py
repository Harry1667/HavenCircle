#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
eval_llm_strategies.py — 量化比較新聞爬蟲三種 LLM 使用策略的效果

這是分析工具，不是產品程式碼；不會被 fetch_news.py 匯入，也不會被排程執行。
不改動 fetch_news.py，直接 import 它的函式來跑三種策略，確保跟正式爬蟲行為
100% 一致（規則詞庫、地點抽取、去重合併都共用同一份實作，不重寫一份可能跑歪的複製品）。

三種策略（定義見任務說明，務必照這個定義）：
    A. 不用 AI  —— 只跑 rules_classify()，完全不呼叫 LLM。
    B. 半用 AI（補位）—— 先跑 rules_classify()；只有當規則抽不出 county 或抽不出
       district 時，才對那一則呼叫 LLM，且只用 LLM 結果「補上缺的欄位」
       （county/district/place/summary/detail 逐一补，規則已有值的欄位不覆蓋）。
       B 刻意不用 LLM 的 is_incident 去推翻規則已判定的事故——B 的呼叫時機只跟
       「地點缺不缺」有關，不是重新分類，這點跟 C 不同，請見下方 run_strategy()。
    C. 全用 AI（現況）—— 每則規則初篩通過的候選都呼叫 LLM，並以 LLM 結果為準
       （完全比照 fetch_news.py main() 現行行為，含 LLM 判定非事故就丟棄）。

公平性設計：
    - 三策略讀同一份 fixture（capture 產生，只抓一次 RSS），不各自重抓。
    - 不讀寫 seen.json / latest.json，也不呼叫 push_to_oracle——這支程式從頭到尾
      只 import 純函式，從不呼叫 fetch_news.main()，結構上就不可能碰到 Oracle。
    - 建議在隔離工作目錄執行（例如 /tmp/eval_llm/），且該目錄不放 ingest_key.txt。

用法：
    步驟 1：擷取一次 fixture（三策略共用，不要重抓）
        .venv/bin/python3 eval_llm_strategies.py capture --out fixture.json

    步驟 2：對同一份 fixture 分別跑三種策略（各自獨立輸出）
        .venv/bin/python3 eval_llm_strategies.py run --strategy A --fixture fixture.json --out results_A.json
        .venv/bin/python3 eval_llm_strategies.py run --strategy B --fixture fixture.json --out results_B.json
        .venv/bin/python3 eval_llm_strategies.py run --strategy C --fixture fixture.json --out results_C.json
        # C 較慢（每則 LLM 約 14 秒），建議 nohup 背景執行：
        #   nohup .venv/bin/python3 eval_llm_strategies.py run --strategy C \
        #       --fixture fixture.json --out results_C.json > run_C.log 2>&1 &

    步驟 3：彙整成三欄對比表
        .venv/bin/python3 eval_llm_strategies.py report \
            --a results_A.json --b results_B.json --c results_C.json \
            --districts TaiwanDistricts.json
"""

import argparse
import json
import math
import os
import sys
import time
import unicodedata
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fetch_news as fn  # noqa: E402  （刻意晚 import，先把路徑加進 sys.path）


# ---------------------------------------------------------------------------
# 步驟 1：擷取 fixture（只抓一次 RSS，三策略共用）
# ---------------------------------------------------------------------------

def capture(out_path, feeds=None):
    """
    抓所有 feed，套用跟 fetch_news.py 完全相同的新鮮度／數量閘門（prepare_feed_items），
    輸出還沒經過 rules_classify 的完整候選清單（title/description/source/link/published）。
    刻意不在這裡跑 rules_classify——三種策略的差異只在「LLM 怎麼用」，rules_classify
    要在 run() 裡對每個策略各跑一次（雖然結果必然相同，但這樣三策略在程式碼路徑上
    完全對稱，不會有「規則階段的產物被 A 偷跑過的快取污染」這種可疑之處）。
    """
    feeds = feeds if feeds is not None else fn.FEEDS
    fixture_items = []
    sources_report = []

    for feed in feeds:
        try:
            data = fn.fetch_url(feed["url"])
            fmt = feed.get("format")
            if fmt == "atom":
                raw_items = fn.parse_atom(data)
            elif fmt == "tvbs_html":
                raw_items = fn.parse_tvbs_local(data.decode("utf-8", errors="replace"))
            else:
                raw_items = fn.parse_rss(data)
            items, prep = fn.prepare_feed_items(
                raw_items, max_items=feed.get("max_items", fn.DEFAULT_FEED_ITEM_LIMIT)
            )
        except Exception as e:
            print(f"[capture] feed 失敗，跳過：{feed['name']} {feed['feed']} — {e}", file=sys.stderr)
            sources_report.append({
                "name": feed["name"], "feed": feed["feed"], "url": feed["url"],
                "ok": False, "error": str(e),
            })
            continue

        sources_report.append({
            "name": feed["name"], "feed": feed["feed"], "url": feed["url"],
            "ok": True, **prep,
        })
        for item in items:
            fixture_items.append({
                "id": fn.stable_id(item),
                "title": item["title"],
                "description": item["description"],
                "link": item["link"],
                "pubDate": item["pubDate"],
                "sourceName": feed["name"],
                "sourceFeed": feed["feed"],
            })
        print(f"[capture] {feed['name']} {feed['feed']}：原始 {prep['rawItems']} → 可處理 {len(items)}",
              file=sys.stderr)

    fixture = {
        "capturedAt": datetime.now(fn.TZ_TAIPEI).isoformat(),
        "totalItems": len(fixture_items),
        "sources": sources_report,
        "items": fixture_items,
    }
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(fixture, f, ensure_ascii=False, indent=2)
    print(f"[capture] 完成，共 {len(fixture_items)} 則候選寫入 {out_path}", file=sys.stderr)


# ---------------------------------------------------------------------------
# 步驟 2：對 fixture 跑指定策略
# ---------------------------------------------------------------------------

def extract_location(title, description):
    """跟 fetch_news.py main() 裡的規則地點抽取順序完全一致：
    中央社電頭 → 標題縣市 token → 標題行政區反查 → 描述行政區反查。"""
    county = fn.county_from_cna_dateline(description) or fn.county_from_text(title)
    district = None
    if not county:
        district, county = fn.district_from_text(title)
        if not county:
            district, county = fn.district_from_text(description)
    return county, district


def build_rule_event(item):
    """規則式分類 + 地點抽取。不是事故回傳 None（呼叫端計入 droppedByRules）。"""
    title, description = item["title"], item["description"]
    is_incident, category, _hit_word = fn.rules_classify(title, description)
    if not is_incident:
        return None
    county, district = extract_location(title, description)
    return {
        "id": item["id"],
        "title": title,
        "sourceName": item["sourceName"],
        "sourceURL": item["link"],
        "publishedAt": fn.parse_pubdate(item["pubDate"]),
        "county": county,
        "district": district,
        "place": None,
        "category": category,
        "confidence": 0.5,
        "summary": None,
        "detail": None,
        "severity": "low",
        "is_ongoing": False,
        "extraction": "rules",
        "corroboration": 1,  # merge_duplicate() 會讀寫這個欄位，跟 fetch_news.py main() 的 event 形狀對齊
    }


def run_strategy(strategy, items, log=print):
    """
    對同一批 items（來自 fixture）跑指定策略，回傳含事件清單與統計數字的 dict。

    LLM 熔斷：跟 fetch_news.py 一樣，一旦 llm_classify 回傳 disable_for_run，
    本輪後續就不再真的打 LLM（proxy 明顯掛掉時，硬打 80 次逾時只是浪費 20 分鐘），
    但仍把「原本該打」的則數計進 llmFailures，如實反映策略在服務不穩時的代價。
    """
    events = []
    llm_calls = 0
    llm_failures = 0
    dropped_by_rules = 0
    dropped_by_llm = 0
    llm_circuit_open = False
    t0 = time.monotonic()

    for item in items:
        event = build_rule_event(item)
        if event is None:
            dropped_by_rules += 1
            continue

        if strategy == "A":
            need_llm = False
        elif strategy == "B":
            # 只補位：規則已經抽到完整地點（county 與 district 皆有）就不呼叫 LLM
            need_llm = (not event["county"]) or (not event["district"])
        elif strategy == "C":
            need_llm = True
        else:
            raise ValueError(f"未知策略：{strategy}")

        if need_llm:
            llm_calls += 1
            if llm_circuit_open:
                llm_failures += 1
            else:
                llm_result, _retry_later, disable_for_run, _provider = fn.llm_classify(
                    item["title"], item["description"]
                )
                if disable_for_run:
                    llm_circuit_open = True
                if llm_result is None:
                    llm_failures += 1
                    # 失敗就退回規則結果，跟 production 行為一致（不因 LLM 掛掉丟事件）
                elif strategy == "C":
                    if not llm_result.get("is_incident"):
                        dropped_by_llm += 1
                        continue
                    # 完全比照 fetch_news.py main() 的 event.update(...)：LLM 結果為準
                    event.update({
                        "county": llm_result.get("county") or event["county"],
                        "district": llm_result.get("district") or None,
                        "place": llm_result.get("place") or None,
                        "category": llm_result["category"],
                        "confidence": llm_result["confidence"],
                        "summary": llm_result.get("summary"),
                        "detail": llm_result.get("detail"),
                        "severity": llm_result.get("severity", "low"),
                        "is_ongoing": bool(llm_result.get("is_ongoing")),
                        "extraction": "llm",
                    })
                elif strategy == "B":
                    # 只補「缺」的欄位；規則已有值的欄位不覆蓋、也不用 LLM 的
                    # is_incident 去否決規則已判定的事故（B 的呼叫時機只跟地點缺不缺
                    # 有關，見檔頭說明）
                    backfilled = False
                    for key in ("county", "district", "place", "summary", "detail"):
                        if not event.get(key) and llm_result.get(key):
                            event[key] = llm_result[key]
                            backfilled = True
                    if backfilled:
                        event["extraction"] = "rules+llm-backfill"

        events.append(event)

    # 跨來源去重：沿用 production 的 find_duplicate/merge_duplicate，確保三策略在
    # 「同一批新聞」上做完全一致的後處理，只有 LLM 使用方式這一個變因。
    deduped = []
    for event in events:
        dup = fn.find_duplicate(event, deduped)
        if dup is not None:
            fn.merge_duplicate(dup, event)
            log(f"[{strategy}] 合併重複事件：「{event['title'][:20]}」({event['sourceName']}) → 「{dup['title'][:20]}」")
        else:
            deduped.append(event)

    elapsed = time.monotonic() - t0
    result = {
        "strategy": strategy,
        "elapsedSeconds": round(elapsed, 2),
        "totalItemsInFixture": len(items),
        "droppedByRules": dropped_by_rules,
        "droppedByLLM": dropped_by_llm,
        "llmCalls": llm_calls,
        "llmFailures": llm_failures,
        "llmCircuitOpen": llm_circuit_open,
        "incidentCount": len(deduped),
        "events": deduped,
    }
    log(f"[{strategy}] 完成：{len(items)} 則候選 → {len(deduped)} 則事故｜"
        f"LLM 呼叫 {llm_calls} 次（失敗 {llm_failures}）｜耗時 {result['elapsedSeconds']} 秒")
    return result


def run_cmd(args):
    with open(args.fixture, encoding="utf-8") as f:
        fixture = json.load(f)
    items = fixture["items"]
    if args.limit:
        items = items[: args.limit]
        print(f"[run] --limit {args.limit}：只取前 {len(items)} 則做測試", file=sys.stderr)

    result = run_strategy(args.strategy, items, log=lambda m: print(m, file=sys.stderr))
    result["fixturePath"] = os.path.abspath(args.fixture)
    result["ranAt"] = datetime.now(fn.TZ_TAIPEI).isoformat()
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)
    print(f"[run] 策略 {args.strategy} 結果寫入 {args.out}", file=sys.stderr)


# ---------------------------------------------------------------------------
# 步驟 3：定位精度與生活圈情境（複刻 NewsEventProvider.swift / AlertPolicy.swift）
# ---------------------------------------------------------------------------

# 跟 NewsEventProvider.swift 的 countyCenters 逐字對照（21 縣市代表點）
COUNTY_CENTERS = {
    "台北市": (25.0375, 121.5637),
    "新北市": (25.0124, 121.4625),
    "桃園市": (24.9937, 121.3010),
    "台中市": (24.1477, 120.6736),
    "台南市": (22.9999, 120.2270),
    "高雄市": (22.6273, 120.3014),
    "基隆市": (25.1276, 121.7392),
    "新竹市": (24.8138, 120.9675),
    "新竹縣": (24.8387, 121.0177),
    "苗栗縣": (24.5602, 120.8214),
    "彰化縣": (24.0518, 120.5161),
    "南投縣": (23.9609, 120.9719),
    "雲林縣": (23.7092, 120.4313),
    "嘉義市": (23.4801, 120.4491),
    "嘉義縣": (23.4518, 120.2555),
    "屏東縣": (22.5519, 120.5487),
    "宜蘭縣": (24.7021, 121.7378),
    "花蓮縣": (23.9872, 121.6016),
    "台東縣": (22.7583, 121.1444),
    "澎湖縣": (23.5712, 119.5793),
    "金門縣": (24.4321, 118.3171),
    "連江縣": (26.1505, 119.9499),
}


def normalize_county(name):
    """跟 NewsEventProvider.normalize()：只做「臺→台」置換，不砍字尾"""
    return (name or "").replace("臺", "台")


def load_district_rings(districts_path):
    """
    複刻 DistrictBoundaries 的解析＋NewsEventProvider.locate() 用到的 rings.first：
    - Polygon：取 coordinates[0]（外框，忽略洞）
    - MultiPolygon：每個子多邊形的外框各算一個 ring，取清單第一筆
      （對應 Swift `candidates.first(where: county 相符)` 或退一步 `candidates.first`
      時所用的 `match.rings.first`——都是「該 (county, town) 這筆 District 的第一個 ring」）
    回傳 {town: [(county, ring), ...]}，ring 為 [(lon, lat), ...]。
    """
    with open(districts_path, encoding="utf-8") as f:
        data = json.load(f)
    by_town = {}
    for feat in data["features"]:
        county = feat["properties"]["county"]
        town = feat["properties"]["town"]
        geom = feat["geometry"]
        rings = []
        if geom["type"] == "Polygon":
            coords = geom.get("coordinates") or []
            if coords:
                rings.append(coords[0])
        elif geom["type"] == "MultiPolygon":
            for poly in geom.get("coordinates") or []:
                if poly:
                    rings.append(poly[0])
        rings = [r for r in rings if len(r) >= 4]
        if not rings:
            continue
        by_town.setdefault(town, []).append((county, rings[0]))
    return by_town


def ring_center(ring):
    lons = [c[0] for c in ring]
    lats = [c[1] for c in ring]
    return ((min(lats) + max(lats)) / 2, (min(lons) + max(lons)) / 2)


def locate(county, district, district_rings):
    """
    逐字複刻 NewsEventProvider.locate(county:district:)：
    1. district 有值：縣市對得上就用該 ring 中心；對不上（或沒給 county）就退一步
       用第一筆同名 district 的 ring 中心。
    2. 上面都落空，county 有值就用縣市代表點（含缺字尾容錯：「台中」→「台中市」）。
    3. 全部落空回傳 None——對應 App 端「無法定位、直接丟棄」。

    注意：precisionMeters 在 App 端是「district 欄位是否非空」決定的 3000/15000，
    跟這裡走哪條路徑找到 anchor 是兩件事（即使 district 沒查到真實邊界、退回縣市
    代表點，只要 district 欄位本身非空，App 仍會標 3000 公尺）——這裡刻意不「修正」
    這個落差，因為本腳本要量測的是「App 實際會顯示什麼」，不是理想行為。
    """
    if district:
        candidates = district_rings.get(district, [])
        if county:
            for c, ring in candidates:
                if normalize_county(c) == normalize_county(county):
                    return ring_center(ring)
        if candidates:
            return ring_center(candidates[0][1])
    if county:
        key = normalize_county(county)
        if key in COUNTY_CENTERS:
            return COUNTY_CENTERS[key]
        if not key.endswith("市") and not key.endswith("縣"):
            return COUNTY_CENTERS.get(key + "市") or COUNTY_CENTERS.get(key + "縣")
    return None


def precision_meters(event):
    """逐字複刻 precisionMeters 公式：district 欄位非空 → 3000，否則 15000。"""
    return 3000 if (event.get("district") or "").strip() else 15000


def haversine_meters(p1, p2):
    lat1, lon1 = p1
    lat2, lon2 = p2
    r = 6_371_000.0
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def compute_metrics(result, district_rings, user_circle_center, user_radius_meters=1000):
    events = result["events"]
    total = len(events)
    county_count = sum(1 for e in events if e.get("county"))
    district_count = sum(1 for e in events if e.get("district"))
    summary_count = sum(1 for e in events if e.get("summary"))
    detail_count = sum(1 for e in events if e.get("detail"))

    tier_district = 0     # 有 district → 3000m
    tier_county_only = 0  # 只有 county → 15000m
    tier_dropped = 0      # 兩者皆無法定位 → App 端丟棄

    circle_hits = 0
    circle_true_wenshan = 0
    circle_false_same_city = 0   # 台北市其他區（誤報）
    circle_false_other_county = 0  # 連縣市都不對（另一種誤報）

    for e in events:
        anchor = locate(e.get("county"), e.get("district"), district_rings)
        if anchor is None:
            tier_dropped += 1
            continue
        pm = precision_meters(e)
        if pm == 3000:
            tier_district += 1
        else:
            tier_county_only += 1

        distance = haversine_meters(user_circle_center, anchor)
        if distance <= user_radius_meters + pm:
            circle_hits += 1
            county_norm = normalize_county(e.get("county"))
            if county_norm == "台北市" and e.get("district") == "文山區":
                circle_true_wenshan += 1
            elif county_norm == "台北市":
                circle_false_same_city += 1
            else:
                circle_false_other_county += 1

    def pct(n):
        return round(100.0 * n / total, 1) if total else 0.0

    return {
        "strategy": result["strategy"],
        "incidentCount": total,
        "countyCount": county_count,
        "countyPct": pct(county_count),
        "districtCount": district_count,
        "districtPct": pct(district_count),
        "tierDistrict3000m": tier_district,
        "tierDistrict3000mPct": pct(tier_district),
        "tierCountyOnly15000m": tier_county_only,
        "tierCountyOnly15000mPct": pct(tier_county_only),
        "tierDroppedByApp": tier_dropped,
        "tierDroppedByAppPct": pct(tier_dropped),
        "summaryCount": summary_count,
        "summaryPct": pct(summary_count),
        "detailCount": detail_count,
        "detailPct": pct(detail_count),
        "llmCalls": result["llmCalls"],
        "llmFailures": result["llmFailures"],
        "elapsedSeconds": result["elapsedSeconds"],
        "droppedByRules": result["droppedByRules"],
        "droppedByLLM": result["droppedByLLM"],
        "wenshanCircleHits": circle_hits,
        "wenshanCircleTrue": circle_true_wenshan,
        "wenshanCircleFalseSameCity": circle_false_same_city,
        "wenshanCircleFalseOtherCounty": circle_false_other_county,
    }


# ---------------------------------------------------------------------------
# 對比表輸出（等寬終端機表格，CJK 寬度感知對齊）
# ---------------------------------------------------------------------------

def _display_width(s):
    return sum(2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1 for ch in s)


def _pad(s, width):
    return s + " " * max(0, width - _display_width(s))


def render_table(rows, headers):
    widths = [max(_display_width(h), *(_display_width(r[i]) for r in rows)) for i, h in enumerate(headers)]
    lines = []
    lines.append(" | ".join(_pad(h, w) for h, w in zip(headers, widths)))
    lines.append("-+-".join("-" * w for w in widths))
    for row in rows:
        lines.append(" | ".join(_pad(c, w) for c, w in zip(row, widths)))
    return "\n".join(lines)


def report_cmd(args):
    with open(args.a, encoding="utf-8") as f:
        result_a = json.load(f)
    with open(args.b, encoding="utf-8") as f:
        result_b = json.load(f)
    with open(args.c, encoding="utf-8") as f:
        result_c = json.load(f)

    district_rings = load_district_rings(args.districts)
    wenshan_candidates = district_rings.get("文山區", [])
    wenshan_ring = next((ring for county, ring in wenshan_candidates if normalize_county(county) == "台北市"), None)
    if wenshan_ring is None:
        raise SystemExit("找不到台北市文山區的邊界資料，無法計算生活圈情境")
    user_center = ring_center(wenshan_ring)

    metrics = [
        compute_metrics(result_a, district_rings, user_center),
        compute_metrics(result_b, district_rings, user_center),
        compute_metrics(result_c, district_rings, user_center),
    ]

    def row(label, key, fmt="{}", pct_key=None):
        cells = [label]
        for m in metrics:
            v = fmt.format(m[key])
            if pct_key:
                v += f"（{m[pct_key]}%）"
            cells.append(v)
        return cells

    headers = ["指標", "A 不用AI", "B 半用AI(補位)", "C 全用AI(現況)"]
    rows = [
        row("判定為事故的則數", "incidentCount"),
        row("有 county 的則數", "countyCount", pct_key="countyPct"),
        row("有 district 的則數", "districtCount", pct_key="districtPct"),
        row("定位精度：district級(3000m)", "tierDistrict3000m", pct_key="tierDistrict3000mPct"),
        row("定位精度：僅county級(15000m)", "tierCountyOnly15000m", pct_key="tierCountyOnly15000mPct"),
        row("定位精度：App端丟棄", "tierDroppedByApp", pct_key="tierDroppedByAppPct"),
        row("有 summary 的則數", "summaryCount", pct_key="summaryPct"),
        row("有 detail 的則數", "detailCount", pct_key="detailPct"),
        row("LLM 實際呼叫次數", "llmCalls"),
        row("LLM 呼叫失敗次數", "llmFailures"),
        row("總耗時（秒）", "elapsedSeconds"),
        row("規則階段排除則數", "droppedByRules"),
        row("LLM 階段排除則數(僅C實際生效)", "droppedByLLM"),
        row("[情境] 文山區1km生活圈命中則數", "wenshanCircleHits"),
        row("[情境] 其中真正在文山區", "wenshanCircleTrue"),
        row("[情境] 其中台北市其他區(誤報)", "wenshanCircleFalseSameCity"),
        row("[情境] 其中根本不同縣市(誤報)", "wenshanCircleFalseOtherCounty"),
    ]

    table = render_table(rows, headers)
    print(table)

    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump({
                "userCircle": {"county": "台北市", "district": "文山區",
                               "centerLat": user_center[0], "centerLon": user_center[1],
                               "radiusMeters": 1000},
                "metrics": metrics,
            }, f, ensure_ascii=False, indent=2)
        print(f"\n[report] 明細已寫入 {args.out}", file=sys.stderr)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_capture = sub.add_parser("capture", help="抓一次所有 feed，寫成三策略共用的 fixture")
    p_capture.add_argument("--out", required=True)

    p_run = sub.add_parser("run", help="對 fixture 跑指定策略（A/B/C）")
    p_run.add_argument("--strategy", required=True, choices=["A", "B", "C"])
    p_run.add_argument("--fixture", required=True)
    p_run.add_argument("--out", required=True)
    p_run.add_argument("--limit", type=int, default=0, help="只取 fixture 前 N 則（測試用）")

    p_report = sub.add_parser("report", help="彙整三策略結果成對比表")
    p_report.add_argument("--a", required=True)
    p_report.add_argument("--b", required=True)
    p_report.add_argument("--c", required=True)
    p_report.add_argument("--districts", required=True, help="TaiwanDistricts.json 路徑")
    p_report.add_argument("--out", default="", help="另存明細 JSON（選填）")

    args = parser.parse_args()
    if args.cmd == "capture":
        capture(args.out)
    elif args.cmd == "run":
        run_cmd(args)
    elif args.cmd == "report":
        report_cmd(args)


if __name__ == "__main__":
    main()

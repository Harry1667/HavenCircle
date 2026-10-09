import importlib.util
import json
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("fetch_city_fire.py")
SPEC = importlib.util.spec_from_file_location("fetch_city_fire_under_test", MODULE_PATH)
cf = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cf)


def _dts_xml(*cases):
    return "<Data>" + "".join(cases) + "</Data>"


class DTSParsingTests(unittest.TestCase):
    """型態 A：DTS 系統的 XML 解析（高雄／台南等縣市共用同一套格式）。"""

    def test_parses_all_fields_and_ignores_broken_count_fields(self):
        # PERSION_COUNT / CAR_COUNT 是站方 bug（回傳未執行的 SQL 字串），
        # parser 刻意不理會這兩欄，這裡驗證即使出現也不影響其他欄位解析、也不會被輸出。
        xml_text = _dts_xml(
            "<case><CS_NO>20260802110744006</CS_NO><CS_KIND>02</CS_KIND>"
            "<KIND>緊急救護</KIND><CS_CODE>車禍</CS_CODE>"
            "<IN_TIME>2026/08/02 11:07:46</IN_TIME><COUNTRY_NAME>高雄市</COUNTRY_NAME>"
            "<TOWN_NAME>梓官區</TOWN_NAME><ADDR>高雄市梓官區大舍南路</ADDR>"
            "<DEPT_NAME>梓官分隊</DEPT_NAME>"
            "<PERSION_COUNT>SELECT COUNT(*) FROM ...</PERSION_COUNT>"
            "<CAR_COUNT>SELECT COUNT(*) FROM ...</CAR_COUNT>"
            "<STATUS>已派遣</STATUS><CS_NO_ID/></case>"
        )
        rows = cf.parse_dts_xml(xml_text, "高雄市")
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual(row["nativeId"], "20260802110744006")
        self.assertEqual(row["caseType"], "緊急救護")
        self.assertEqual(row["caseSub"], "車禍")
        self.assertEqual(row["district"], "梓官區")
        self.assertEqual(row["location"], "高雄市梓官區大舍南路")
        self.assertEqual(row["unit"], "梓官分隊")
        self.assertEqual(row["status"], "已派遣")
        self.assertEqual(
            row["occurredAt"], datetime(2026, 8, 2, 11, 7, 46, tzinfo=cf.TZ_TAIPEI)
        )
        self.assertNotIn("PERSION_COUNT", row)
        self.assertNotIn("CAR_COUNT", row)

    def test_falls_back_to_county_plus_district_when_addr_missing(self):
        # 部分案件 ADDR 是空的自我閉合標籤（<ADDR/>），此時用縣市+行政區湊出可讀地點
        xml_text = _dts_xml(
            "<case><CS_NO>1</CS_NO><KIND>火災</KIND><CS_CODE>一般住宅</CS_CODE>"
            "<IN_TIME>2026/08/02 09:00:00</IN_TIME><TOWN_NAME>北區</TOWN_NAME>"
            "<ADDR/><DEPT_NAME>北區分隊</DEPT_NAME><STATUS>已派遣</STATUS></case>"
        )
        rows = cf.parse_dts_xml(xml_text, "新竹市")
        self.assertEqual(rows[0]["location"], "新竹市北區")

    def test_multiple_cases_all_parsed(self):
        xml_text = _dts_xml(
            "<case><CS_NO>1</CS_NO><KIND>其他</KIND><CS_CODE>捕蜂</CS_CODE>"
            "<IN_TIME>2026/08/02 09:00:00</IN_TIME><TOWN_NAME>頭份市</TOWN_NAME>"
            "<ADDR>苗栗縣頭份市中華路</ADDR><DEPT_NAME>頭份分隊</DEPT_NAME>"
            "<STATUS>已派遣</STATUS></case>",
            "<case><CS_NO>2</CS_NO><KIND>火災</KIND><CS_CODE>工廠</CS_CODE>"
            "<IN_TIME>2026/08/02 09:05:00</IN_TIME><TOWN_NAME>竹南鎮</TOWN_NAME>"
            "<ADDR>苗栗縣竹南鎮中正路</ADDR><DEPT_NAME>竹南分隊</DEPT_NAME>"
            "<STATUS>已派遣</STATUS></case>",
        )
        rows = cf.parse_dts_xml(xml_text, "苗栗縣")
        self.assertEqual(len(rows), 2)
        self.assertEqual([r["nativeId"] for r in rows], ["1", "2"])


class FilterRuleTests(unittest.TestCase):
    """產品規則：火災/災害搶救全收；緊急救護只收車禍；一般救護/捕蜂捉蛇一律濾掉。"""

    def test_fire_is_always_relevant(self):
        self.assertTrue(cf.is_relevant("火災", ""))
        self.assertTrue(cf.is_relevant("火災", "一般(集合)住宅"))

    def test_disaster_rescue_is_always_relevant(self):
        self.assertTrue(cf.is_relevant("災害搶救", ""))

    def test_ambulance_car_accident_is_relevant(self):
        self.assertTrue(cf.is_relevant("緊急救護", "車禍"))
        # 台北市 service119 用「救護」而非「緊急救護」，也要吃得到
        self.assertTrue(cf.is_relevant("救護", "車禍"))

    def test_ambulance_general_illness_is_filtered_out(self):
        # 使用者要求排除的一般救護：急病、創傷、路倒、OHCA、患者服務…都不是車禍
        for sub in ("急病", "創傷", "路倒", "OHCA", "患者服務"):
            self.assertFalse(
                cf.is_relevant("緊急救護", sub), f"caseSub={sub} 不應被收進來"
            )

    def test_bee_and_snake_catching_is_filtered_out(self):
        # 苗栗清單裡大量的捕蜂/捉蛇，站方案類是「其他」，天然被白名單擋掉
        self.assertFalse(cf.is_relevant("其他", "捕蜂"))
        self.assertFalse(cf.is_relevant("其他", "捉蛇"))

    def test_ambulance_without_car_accident_subtype_is_filtered_out(self):
        # 案別為空（如台北市 csCodeName 恆空、屏東頁面無案別欄位）時，
        # 緊急救護／救護不能被誤判成車禍
        self.assertFalse(cf.is_relevant("緊急救護", ""))
        self.assertFalse(cf.is_relevant("救護", ""))


class TainanPrivacyMaskingTests(unittest.TestCase):
    """合規要求：台南比照官方 HTML 頁面，只留行政區、捨棄路名。"""

    def test_tainan_location_is_masked_to_district_only(self):
        source = {"county": "台南市", "sourceName": "台南市消防局"}
        raw = {
            "nativeId": "20260802105946008",
            "caseType": "緊急救護",
            "caseSub": "車禍",
            "location": "台南市安南區某某路123號",  # XML 端點吐出的完整路名
            "district": "安南區",
            "unit": "安南分隊",
            "status": "送醫中",
            "occurredAt": datetime.now(cf.TZ_TAIPEI),
        }
        record = cf.build_record(raw, source)
        self.assertIsNotNone(record)
        self.assertEqual(record["location"], "安南區")
        self.assertEqual(record["district"], "安南區")

    def test_other_counties_keep_full_location(self):
        source = {"county": "高雄市", "sourceName": "高雄市消防局"}
        raw = {
            "nativeId": "1",
            "caseType": "緊急救護",
            "caseSub": "車禍",
            "location": "高雄市梓官區大舍南路",
            "district": "梓官區",
            "unit": "梓官分隊",
            "status": "已派遣",
            "occurredAt": datetime.now(cf.TZ_TAIPEI),
        }
        record = cf.build_record(raw, source)
        self.assertEqual(record["location"], "高雄市梓官區大舍南路")


class RocDatetimeTests(unittest.TestCase):
    """嘉義縣用民國年（115-08-02 = 2026-08-02），需要 +1911 轉換。"""

    def test_roc_year_converts_to_western_year(self):
        dt = cf.parse_roc_datetime("115-08-02 11:11:06")
        self.assertEqual(dt, datetime(2026, 8, 2, 11, 11, 6, tzinfo=cf.TZ_TAIPEI))

    def test_roc_year_without_seconds(self):
        dt = cf.parse_roc_datetime("113-01-01 00:05")
        self.assertEqual(dt, datetime(2024, 1, 1, 0, 5, 0, tzinfo=cf.TZ_TAIPEI))

    def test_invalid_text_returns_none(self):
        self.assertIsNone(cf.parse_roc_datetime("不是時間字串"))
        self.assertIsNone(cf.parse_roc_datetime(""))

    def test_western_year_text_is_not_roc_parsed(self):
        # 防呆：西元年格式（4 位數年份）不該被 ROC parser 誤吃成民國 2026 年
        self.assertIsNone(cf.parse_roc_datetime("2026-08-02 11:11:06"))


class GenericDatetimeParsingTests(unittest.TestCase):
    """DTS／台北／彰化用斜線＋秒，南投／桃園用連字號、無秒。"""

    def test_slash_format_with_seconds(self):
        dt = cf.parse_datetime("2026/08/02 11:07:46")
        self.assertEqual(dt, datetime(2026, 8, 2, 11, 7, 46, tzinfo=cf.TZ_TAIPEI))

    def test_dash_format_without_seconds(self):
        dt = cf.parse_datetime("2026-08-02 10:41")
        self.assertEqual(dt, datetime(2026, 8, 2, 10, 41, 0, tzinfo=cf.TZ_TAIPEI))

    def test_invalid_text_returns_none(self):
        self.assertIsNone(cf.parse_datetime("不是時間字串"))
        self.assertIsNone(cf.parse_datetime(""))


class MaxAgeFilterTests(unittest.TestCase):
    """苗栗清單卡著數月前的舊案，要用 MAX_AGE_HOURS 擋掉。"""

    def test_stale_record_is_dropped(self):
        source = {"county": "苗栗縣", "sourceName": "苗栗縣消防局"}
        stale_time = datetime.now(cf.TZ_TAIPEI) - timedelta(hours=cf.MAX_AGE_HOURS + 1)
        raw = {
            "nativeId": "old-1",
            "caseType": "火災",
            "caseSub": "",
            "location": "苗栗縣頭份市中華路",
            "district": "頭份市",
            "unit": "",
            "status": "已結案",
            "occurredAt": stale_time,
        }
        self.assertIsNone(cf.build_record(raw, source))

    def test_fresh_record_is_kept(self):
        source = {"county": "苗栗縣", "sourceName": "苗栗縣消防局"}
        raw = {
            "nativeId": "new-1",
            "caseType": "火災",
            "caseSub": "",
            "location": "苗栗縣頭份市中華路",
            "district": "頭份市",
            "unit": "",
            "status": "已派遣",
            "occurredAt": datetime.now(cf.TZ_TAIPEI),
        }
        self.assertIsNotNone(cf.build_record(raw, source))

    def test_missing_occurred_at_is_dropped(self):
        source = {"county": "苗栗縣", "sourceName": "苗栗縣消防局"}
        raw = {
            "nativeId": "no-time", "caseType": "火災", "caseSub": "",
            "location": "", "district": "", "unit": "", "status": "",
            "occurredAt": None,
        }
        self.assertIsNone(cf.build_record(raw, source))


class SourceIdKeyTests(unittest.TestCase):
    """去重鍵：有原生案號用 {縣市}|{CS_NO}；沒有的站用 {縣市}|{時間}|{地點}，狀態不進鍵。"""

    def test_native_id_key_format(self):
        source = {"county": "台南市", "sourceName": "台南市消防局"}
        occurred = datetime.now(cf.TZ_TAIPEI).replace(microsecond=0) - timedelta(hours=1)
        raw = {
            "nativeId": "20260802105946008", "caseType": "火災", "caseSub": "",
            "location": "台南市安南區x路", "district": "安南區", "unit": "",
            "status": "已派遣", "occurredAt": occurred,
        }
        record = cf.build_record(raw, source)
        self.assertEqual(record["sourceId"], "台南市|20260802105946008")

    def test_synthetic_key_when_no_native_id(self):
        source = {"county": "台中市", "sourceName": "台中市消防局"}
        occurred = datetime.now(cf.TZ_TAIPEI).replace(microsecond=0) - timedelta(hours=1)
        raw = {
            "nativeId": None, "caseType": "火災", "caseSub": "",
            "location": "台中市觀音區新富路", "district": "觀音區", "unit": "",
            "status": "處理中", "occurredAt": occurred,
        }
        record = cf.build_record(raw, source)
        self.assertEqual(
            record["sourceId"], f"台中市|{occurred.isoformat()}|台中市觀音區新富路"
        )

    def test_status_change_does_not_change_key(self):
        # 同一案從「已派遣」變「已返隊」，sourceId 必須不變，
        # 這樣主程式才能用同一個 key 覆蓋更新既有記錄的狀態
        source = {"county": "台南市", "sourceName": "台南市消防局"}
        occurred = datetime.now(cf.TZ_TAIPEI).replace(microsecond=0) - timedelta(hours=1)
        base_raw = {
            "nativeId": "20260802105946008", "caseType": "火災", "caseSub": "",
            "location": "台南市安南區x路", "district": "安南區", "unit": "",
            "occurredAt": occurred,
        }
        r1 = cf.build_record({**base_raw, "status": "已派遣"}, source)
        r2 = cf.build_record({**base_raw, "status": "已返隊"}, source)
        self.assertEqual(r1["sourceId"], r2["sourceId"])
        self.assertNotEqual(r1["status"], r2["status"])


class TaipeiParsingTests(unittest.TestCase):
    """型態 B：台北市 service119。案別欄位實測恆空，故緊急救護一律收不到車禍。"""

    def test_fire_kept_ambulance_without_subtype_dropped_by_filter(self):
        data = {
            "rows": [
                {"inTime": "2026/08/02 11:01:12", "csKindName": "火災",
                 "csCodeName": "", "caseStatus": "到達現場",
                 "csPlaceFuzzy": "臺北市中正區汀州路"},
                {"inTime": "2026/08/02 11:07:25", "csKindName": "救護",
                 "csCodeName": "", "caseStatus": "已出勤",
                 "csPlaceFuzzy": "臺北市士林區仰德大"},
            ]
        }
        rows = cf.parse_taipei_json(data)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["district"], "中正區")
        self.assertTrue(cf.is_relevant(rows[0]["caseType"], rows[0]["caseSub"]))
        self.assertFalse(cf.is_relevant(rows[1]["caseType"], rows[1]["caseSub"]))

    def test_handles_traditional_and_simplified_taipei_prefix(self):
        # 「臺北市」「台北市」兩種寫法都要能抓出行政區
        data = {"rows": [
            {"inTime": "2026/08/02 11:00:00", "csKindName": "火災", "csCodeName": "",
             "caseStatus": "到達現場", "csPlaceFuzzy": "台北市大安區忠孝東路"},
        ]}
        rows = cf.parse_taipei_json(data)
        self.assertEqual(rows[0]["district"], "大安區")


def _ntpc_outer(*features):
    """組出新北市端點的雙層 JSON：外層 data 欄位是「字串化的 GeoJSON」。"""
    geojson = {"type": "FeatureCollection", "features": list(features)}
    return json.dumps({
        "status": 200, "message": "successful",
        "data": json.dumps(geojson, ensure_ascii=False),
    }, ensure_ascii=False)


def _ntpc_fire_feature(feature_id="260802133039", fire_type="一般火警",
                        location="新北市三重區五華街", lat=25.08450512, lng=121.48975490):
    return {
        "type": "Feature",
        "properties": {
            "featureId": feature_id,
            "type": "FireV2",
            "fireType": fire_type,
            "endPointInfo": location,
            "lat": lat,
            "lng": lng,
            "caseList": [{"startPointInfo": "三重11"}],
            "dataSource": "EDPW資料倉儲",
        },
    }


def _ntpc_ambulance_feature(feature_id="260802140011"):
    # 救護案件沒有案類/地點欄位，endPointInfo 只是送醫醫院名稱
    return {
        "type": "Feature",
        "properties": {
            "featureId": feature_id,
            "type": "AmbulanceBack",
            "endPointInfo": "亞東紀念醫院",
            "lat": 25.0123,
            "lng": 121.4567,
        },
    }


class NtpcDoubleJsonParsingTests(unittest.TestCase):
    """型態 D：新北市端點的雙層 JSON 解析（外層 data 是字串化的 GeoJSON，要 parse 兩次）。"""

    def test_double_json_is_parsed_and_fire_fields_extracted(self):
        outer_text = _ntpc_outer(_ntpc_fire_feature())
        rows = cf.parse_ntpc_geojson(outer_text)
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual(row["nativeId"], "260802133039")
        self.assertEqual(row["caseType"], "火災")
        self.assertEqual(row["caseSub"], "一般火警")
        self.assertEqual(row["location"], "新北市三重區五華街")
        self.assertEqual(row["district"], "三重區")
        self.assertEqual(row["unit"], "三重11")
        self.assertAlmostEqual(row["latitude"], 25.08450512)
        self.assertAlmostEqual(row["longitude"], 121.48975490)
        # payload 本身沒有時間欄位，parser 階段先留 None，交給 fetch_ntpc 補上
        self.assertIsNone(row["occurredAt"])

    def test_empty_feature_collection_returns_empty_list(self):
        # 案件空窗期端點回 features:[]，這是正常狀態，不該報錯
        outer_text = _ntpc_outer()
        self.assertEqual(cf.parse_ntpc_geojson(outer_text), [])

    def test_malformed_inner_data_string_does_not_crash(self):
        outer_text = json.dumps({"status": 200, "message": "successful", "data": "not json"})
        self.assertEqual(cf.parse_ntpc_geojson(outer_text), [])


class NtpcFireOnlyFilterTests(unittest.TestCase):
    """只收火災（type 開頭 Fire），不收救護（AmbulanceBack 只有醫院名稱、無案類/地點）。"""

    def test_ambulance_back_is_dropped(self):
        outer_text = _ntpc_outer(_ntpc_ambulance_feature())
        self.assertEqual(cf.parse_ntpc_geojson(outer_text), [])

    def test_fire_kept_ambulance_dropped_when_mixed(self):
        outer_text = _ntpc_outer(_ntpc_fire_feature(), _ntpc_ambulance_feature())
        rows = cf.parse_ntpc_geojson(outer_text)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["caseType"], "火災")

    def test_large_fire_subtype_is_kept_as_case_sub(self):
        outer_text = _ntpc_outer(_ntpc_fire_feature(fire_type="大型火警"))
        rows = cf.parse_ntpc_geojson(outer_text)
        self.assertEqual(rows[0]["caseSub"], "大型火警")


class NtpcDistrictExtractionTests(unittest.TestCase):
    def test_district_extracted_from_full_address(self):
        outer_text = _ntpc_outer(_ntpc_fire_feature(location="新北市板橋區文化路二段"))
        rows = cf.parse_ntpc_geojson(outer_text)
        self.assertEqual(rows[0]["district"], "板橋區")

    def test_no_district_match_falls_back_to_empty_string(self):
        outer_text = _ntpc_outer(_ntpc_fire_feature(location="不含縣市字樣的地點"))
        rows = cf.parse_ntpc_geojson(outer_text)
        self.assertEqual(rows[0]["district"], "")


class NtpcFirstSeenFallbackTests(unittest.TestCase):
    """payload 沒有時間欄位，occurredAt 用 seen.json 記錄的「首次看到時間」兜底。"""

    def test_new_feature_id_is_stamped_with_now_and_marks_seen_changed(self):
        outer_text = _ntpc_outer(_ntpc_fire_feature(feature_id="new-1"))
        rows = cf.parse_ntpc_geojson(outer_text)
        seen = {}
        now_iso = "2026-08-02T13:30:00+08:00"
        changed = cf._fill_ntpc_first_seen(rows, seen, now_iso)
        self.assertTrue(changed)
        self.assertEqual(seen["ntpc-first-seen|new-1"], now_iso)
        self.assertEqual(rows[0]["occurredAt"], datetime.fromisoformat(now_iso))

    def test_previously_seen_feature_id_reuses_stored_time_not_now(self):
        # 第二輪抓到同一個 featureId：不能把 occurredAt 改寫成本輪的「現在」，
        # 否則案件會被永遠判定成剛發生
        first_seen_iso = "2026-08-02T13:00:00+08:00"
        seen = {"ntpc-first-seen|existing-1": first_seen_iso}
        outer_text = _ntpc_outer(_ntpc_fire_feature(feature_id="existing-1"))
        rows = cf.parse_ntpc_geojson(outer_text)
        changed = cf._fill_ntpc_first_seen(rows, seen, "2026-08-02T13:30:00+08:00")
        self.assertFalse(changed)
        self.assertEqual(rows[0]["occurredAt"], datetime.fromisoformat(first_seen_iso))
        self.assertEqual(seen["ntpc-first-seen|existing-1"], first_seen_iso)

    def test_key_namespace_does_not_collide_with_county_source_id(self):
        # seen.json 同時被主程式（{縣市}|{nativeId} 算「本次新增」）與 ntpc 首見時間
        # 共用；字首要能避免撞在一起
        seen = {}
        outer_text = _ntpc_outer(_ntpc_fire_feature(feature_id="260802133039"))
        rows = cf.parse_ntpc_geojson(outer_text)
        cf._fill_ntpc_first_seen(rows, seen, "2026-08-02T13:30:00+08:00")
        self.assertIn("ntpc-first-seen|260802133039", seen)
        self.assertNotIn("新北市|260802133039", seen)

    def test_missing_feature_id_is_skipped_without_crashing(self):
        rows = [{
            "nativeId": None, "caseType": "火災", "caseSub": "",
            "location": "", "district": "", "unit": "", "status": "",
            "occurredAt": None, "latitude": None, "longitude": None,
        }]
        seen = {}
        changed = cf._fill_ntpc_first_seen(rows, seen, "2026-08-02T13:30:00+08:00")
        self.assertFalse(changed)
        self.assertIsNone(rows[0]["occurredAt"])
        self.assertEqual(seen, {})


class CoordinateFieldTests(unittest.TestCase):
    """schema 新增的選填座標欄位：新北自帶座標，其他縣市沒有座標時要輸出 None 而不是報錯。"""

    def test_ntpc_record_carries_coordinates(self):
        source = {"county": "新北市", "sourceName": "新北市消防局"}
        raw = {
            "nativeId": "260802133039", "caseType": "火災", "caseSub": "一般火警",
            "location": "新北市三重區五華街", "district": "三重區", "unit": "三重11",
            "status": "", "occurredAt": datetime.now(cf.TZ_TAIPEI),
            "latitude": 25.08450512, "longitude": 121.48975490,
        }
        record = cf.build_record(raw, source)
        self.assertEqual(record["latitude"], 25.08450512)
        self.assertEqual(record["longitude"], 121.48975490)

    def test_county_without_coordinates_outputs_none_not_error(self):
        # 既有的其他縣市 raw dict 完全不帶 latitude/longitude 鍵，
        # build_record 要能安全用 .get 拿到 None，不能 KeyError
        source = {"county": "高雄市", "sourceName": "高雄市消防局"}
        raw = {
            "nativeId": "1", "caseType": "火災", "caseSub": "",
            "location": "高雄市梓官區大舍南路", "district": "梓官區", "unit": "",
            "status": "已派遣", "occurredAt": datetime.now(cf.TZ_TAIPEI),
        }
        record = cf.build_record(raw, source)
        self.assertIsNone(record["latitude"])
        self.assertIsNone(record["longitude"])


# ============================================================
# 2026-10-10 新增：台東／連江（DTS）、嘉義市、新竹縣
# ============================================================

# 台東縣 dt.ttfd.gov.tw 2026-10-10 實抓回應（3 筆原樣，未改動）
_TTFD_REAL_XML = (
    "<Data><case><CS_NO>20261010062151007</CS_NO><CS_KIND>02</CS_KIND><KIND>緊急救護</KIND>"
    "<CS_CODE>空跑</CS_CODE><IN_TIME>2026/10/10 06:21:51</IN_TIME><COUNTRY_NAME>台東縣</COUNTRY_NAME>"
    "<TOWN_NAME>台東市</TOWN_NAME><ADDR>台東縣台東市中興路</ADDR><DEPT_NAME>台東分隊</DEPT_NAME>"
    "<PERSION_COUNT>共1人</PERSION_COUNT><CAR_COUNT>共1車</CAR_COUNT><STATUS>已返隊</STATUS><CS_NO_ID/></case>"
    "<case><CS_NO>20261010053529009</CS_NO><CS_KIND>02</CS_KIND><KIND>緊急救護</KIND>"
    "<CS_CODE>急病</CS_CODE><IN_TIME>2026/10/10 05:35:29</IN_TIME><COUNTRY_NAME>台東縣</COUNTRY_NAME>"
    "<TOWN_NAME>台東市</TOWN_NAME><ADDR>台東縣台東市中興路三段401巷11弄</ADDR><DEPT_NAME>豐田分隊</DEPT_NAME>"
    "<PERSION_COUNT>共1人</PERSION_COUNT><CAR_COUNT>共1車</CAR_COUNT><STATUS>已返隊</STATUS><CS_NO_ID/></case>"
    "<case><CS_NO>20261009101327007</CS_NO><CS_KIND>01</CS_KIND><KIND>火災</KIND>"
    "<CS_CODE>雜草(含廢棄物、墓地)</CS_CODE><IN_TIME>2026/10/09 10:13:27</IN_TIME><COUNTRY_NAME>台東縣</COUNTRY_NAME>"
    "<TOWN_NAME>綠島鄉</TOWN_NAME><ADDR>台東縣綠島鄉</ADDR><DEPT_NAME>綠島分隊</DEPT_NAME>"
    "<PERSION_COUNT>共1人</PERSION_COUNT><CAR_COUNT>共1車</CAR_COUNT><STATUS>已出動</STATUS><CS_NO_ID/></case></Data>"
)


class NewDtsCountiesTests(unittest.TestCase):
    def test_taitung_real_xml_parses_three_cases(self):
        rows = cf.parse_dts_xml(_TTFD_REAL_XML, "台東縣")
        self.assertEqual(len(rows), 3)
        self.assertEqual(rows[2]["caseType"], "火災")
        self.assertEqual(rows[2]["district"], "綠島鄉")

    def test_taitung_filter_keeps_only_fire(self):
        source = next(x for x in cf.SOURCES if x["county"] == "台東縣")
        # 時間窗 24h 會把 10/09 的舊 fixture 擋掉，這裡把時間改成現在只驗過濾規則
        rows = cf.parse_dts_xml(_TTFD_REAL_XML, "台東縣")
        for r in rows:
            r["occurredAt"] = datetime.now(cf.TZ_TAIPEI)
        kept = [cf.build_record(r, source) for r in rows]
        kept = [k for k in kept if k]
        self.assertEqual([k["caseType"] for k in kept], ["火災"])
        self.assertEqual(kept[0]["sourceId"], "台東縣|20261009101327007")

    def test_lienchiang_empty_data_returns_no_rows(self):
        # dt.lcfd.gov.tw 實測回應就是自我閉合的 <Data/>
        self.assertEqual(cf.parse_dts_xml("<Data/>", "連江縣"), [])

    def test_sources_registered_with_dts_host(self):
        hosts = {x["county"]: x.get("host") for x in cf.SOURCES}
        self.assertEqual(hosts["台東縣"], "dt.ttfd.gov.tw")
        self.assertEqual(hosts["連江縣"], "dt.lcfd.gov.tw")


# 嘉義市 /Common/Getfdcaselist.ashx 實測空回應（表頭為真實，只有 0 筆）
_CYCITY_EMPTY = (
    '<table border="0" cellpadding="1" cellspacing="1" class="disaster_form" style="width:100%; text-align: center;">'
    "\n\t<tbody>\n\t\t<tr>\n\t\t\t<th scope=\"col\">受理時間</th>\n\t\t\t<th scope=\"col\">案類-細項</th>\n"
    "\t\t\t<th scope=\"col\">案發地點</th>\n\t\t\t<th scope=\"col\">派遣分隊</th>\n"
    "\t\t\t<th scope=\"col\">案件狀態</th>\n\t\t</tr>\n\t</tbody>\n</table>"
)
# 資料列：站方尚無資料可抓，依嘉義縣同款 CMS 欄位順序合成（非真實資料）
_CYCITY_ROWS = _CYCITY_EMPTY.replace(
    "</tbody>",
    "<tr><td><p>115-10-10 08:15:30</p></td><td><p>火災-建築物</p></td>"
    "<td><p>東區中山路</p></td><td><p>東區分隊</p></td><td><p>已出動</p></td></tr>"
    "<tr><td>2026/10/10 08:20:00</td><td>火警</td><td>嘉義市西區民權路</td>"
    "<td>西區分隊</td><td>已返隊</td></tr></tbody>",
)


class CiayiCityTests(unittest.TestCase):
    def test_empty_table_yields_no_rows(self):
        self.assertEqual(cf.parse_cycity_html(_CYCITY_EMPTY), [])

    def test_rows_parsed_roc_and_western_time_and_county_prefix(self):
        rows = cf.parse_cycity_html(_CYCITY_ROWS)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["caseType"], "火災")
        self.assertEqual(rows[0]["caseSub"], "建築物")
        self.assertEqual(rows[0]["location"], "嘉義市東區中山路")
        self.assertEqual(rows[0]["district"], "東區")
        self.assertEqual(rows[0]["occurredAt"],
                         datetime(2026, 10, 10, 8, 15, 30, tzinfo=cf.TZ_TAIPEI))
        # 「火警」正規化為白名單內的「火災」；西元年時間也吃
        self.assertEqual(rows[1]["caseType"], "火災")
        self.assertEqual(rows[1]["district"], "西區")
        self.assertEqual(rows[1]["occurredAt"].hour, 8)


# 新竹縣 fire.hsinchu.gov.tw 即時災情列表（2026-10-10 實抓，取其中 3 則）
def _hccfd_item(article_id, title, date):
    return (
        '<div class="newlist caselist col-md-6">\n'
        f'<a href="https://fire.hsinchu.gov.tw/cht/index.php?code=list&flag=detail&ids=262&article_id={article_id}" '
        f'class="d-flex" title="{title}" >\n<div class="newc w-100"><div class="news_date">'
        f'<span class="mon"><i class="far fa-calendar-alt"></i><span class="sr-only">發佈日期</span>{date}</span>'
        '<div class="hot"><i class="fas fa-caret-right"></i><span class="sr-only">發佈單位</span>勤務指揮科</div>'
        f'</div><div class="act_t">{title}</div></div></a></div>\n'
    )


_HCCFD_LIST = (
    _hccfd_item(60939, "火災－新竹縣新豐鄉忠孝路附近", "2026-10-04")
    + _hccfd_item(60098, "瓦斯味－新竹縣芎林鄉文衡路周邊", "2026-09-16")
    + _hccfd_item(1, "\u200b火災－竹北市華興街附近", "2026-10-03")
    + _hccfd_item(2, "新豐鄉建興路二段附近不明氣體噴出", "2026-10-02")
    + _hccfd_item(3, "車禍-新竹縣湖口鄉中正路附近", "2026-10-01")
)
_HCCFD_DETAIL = (
    '<div class="col-12 article-content">\n    新竹縣新豐鄉忠孝路附近於22時42分發生住宅火警<br />\n'
    "新竹縣政府消防局獲報後，派遣山崎、新豐及工業車組前往搶救。</div>"
)


class HsinchuCountyTests(unittest.TestCase):
    def test_list_parsed_title_split_and_county_prefix(self):
        rows = cf.parse_hccfd_list(_HCCFD_LIST)
        self.assertEqual(len(rows), 5)
        self.assertEqual(rows[0]["nativeId"], "60939")
        self.assertEqual(rows[0]["caseType"], "火災")
        self.assertEqual(rows[0]["location"], "新竹縣新豐鄉忠孝路附近")
        self.assertEqual(rows[0]["district"], "新豐鄉")
        self.assertEqual(rows[0]["date"], "2026-10-04")
        self.assertEqual(rows[1]["caseType"], "瓦斯味")
        # 標題缺縣名會補；零寬空白會清掉
        self.assertEqual(rows[2]["location"], "新竹縣竹北市華興街附近")
        self.assertEqual(rows[2]["district"], "竹北市")
        self.assertEqual(rows[2]["caseType"], "火災")
        # 無分隔符 → 案類空，會被白名單擋掉
        self.assertEqual(rows[3]["caseType"], "")
        # 車禍轉成 緊急救護＋車禍
        self.assertEqual((rows[4]["caseType"], rows[4]["caseSub"]), ("緊急救護", "車禍"))
        self.assertTrue(cf.is_relevant(rows[4]["caseType"], rows[4]["caseSub"]))
        self.assertFalse(cf.is_relevant(rows[1]["caseType"], rows[1]["caseSub"]))
        self.assertFalse(cf.is_relevant(rows[3]["caseType"], rows[3]["caseSub"]))

    def test_detail_time_combined_with_list_date(self):
        self.assertEqual(
            cf.parse_hccfd_detail_time(_HCCFD_DETAIL, "2026-10-04"),
            datetime(2026, 10, 4, 22, 42, tzinfo=cf.TZ_TAIPEI),
        )

    def test_detail_without_time_returns_none_not_fabricated(self):
        self.assertIsNone(cf.parse_hccfd_detail_time("<div>無時間</div>", "2026-10-04"))

    def test_record_without_time_is_dropped_by_build_record(self):
        source = next(x for x in cf.SOURCES if x["county"] == "新竹縣")
        raw = cf.parse_hccfd_list(_HCCFD_LIST)[0]
        self.assertIsNone(cf.build_record(raw, source))  # occurredAt 為 None

    def test_build_record_for_fresh_hsinchu_county_case(self):
        source = next(x for x in cf.SOURCES if x["county"] == "新竹縣")
        raw = cf.parse_hccfd_list(_HCCFD_LIST)[0]
        raw["occurredAt"] = datetime.now(cf.TZ_TAIPEI)
        rec = cf.build_record(raw, source)
        self.assertEqual(rec["sourceId"], "新竹縣|60939")
        self.assertEqual(rec["location"], "新竹縣新豐鄉忠孝路附近")
        self.assertIsNone(rec["latitude"])


if __name__ == "__main__":
    unittest.main()

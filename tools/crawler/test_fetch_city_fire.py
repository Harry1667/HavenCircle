import importlib.util
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
        occurred = datetime(2026, 8, 2, 10, 59, 46, tzinfo=cf.TZ_TAIPEI)
        raw = {
            "nativeId": "20260802105946008", "caseType": "火災", "caseSub": "",
            "location": "台南市安南區x路", "district": "安南區", "unit": "",
            "status": "已派遣", "occurredAt": occurred,
        }
        record = cf.build_record(raw, source)
        self.assertEqual(record["sourceId"], "台南市|20260802105946008")

    def test_synthetic_key_when_no_native_id(self):
        source = {"county": "台中市", "sourceName": "台中市消防局"}
        occurred = datetime(2026, 8, 2, 10, 41, 0, tzinfo=cf.TZ_TAIPEI)
        raw = {
            "nativeId": None, "caseType": "火災", "caseSub": "",
            "location": "台中市觀音區新富路", "district": "觀音區", "unit": "",
            "status": "處理中", "occurredAt": occurred,
        }
        record = cf.build_record(raw, source)
        self.assertEqual(
            record["sourceId"], "台中市|2026-08-02T10:41:00+08:00|台中市觀音區新富路"
        )

    def test_status_change_does_not_change_key(self):
        # 同一案從「已派遣」變「已返隊」，sourceId 必須不變，
        # 這樣主程式才能用同一個 key 覆蓋更新既有記錄的狀態
        source = {"county": "台南市", "sourceName": "台南市消防局"}
        occurred = datetime(2026, 8, 2, 10, 59, 46, tzinfo=cf.TZ_TAIPEI)
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


if __name__ == "__main__":
    unittest.main()

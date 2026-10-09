import importlib.util
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).with_name("fetch_freeway.py")
SPEC = importlib.util.spec_from_file_location("fetch_freeway_under_test", MODULE_PATH)
fw = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fw)

TZ = fw.TZ_TAIPEI
NOW = datetime(2026, 10, 10, 12, 0, 0, tzinfo=TZ)


def row(**kw):
    base = {
        "srcdetail": "熱心聽眾0919", "happendate": "2026-10-10",
        "happentime": "11:30:00.0000000", "roadtype": "事故", "UID": "U1",
        "road": "", "areaNm": "中山高速公路-國道１號", "y1": "22.7", "x1": "120.3",
        "comment": "北上在359.1公里近楠梓 事故", "region": "S", "direction": "北上",
    }
    base.update(kw)
    return base


class PbsParsingTests(unittest.TestCase):
    def parse(self, *rows):
        return fw.parse_pbs_records(list(rows), now=NOW)

    def test_converts_to_freeway_event_shape(self):
        ev = self.parse(row())[0]
        self.assertEqual(
            set(ev),
            {"eventId", "road", "direction", "km", "section", "description",
             "latitude", "longitude", "occurredAt", "eventType"},
        )
        self.assertEqual(ev["eventId"], "pbs-U1")
        self.assertEqual(ev["road"], "國道1號")  # 全形數字正規化
        self.assertEqual(ev["km"], "359.1K")
        self.assertEqual(ev["eventType"], "1")
        self.assertEqual(ev["occurredAt"], "2026-10-10T11:30:00+08:00")
        self.assertIn("民眾通報", ev["section"])
        self.assertIn("未經官方確認", ev["description"])

    def test_only_accident_and_disaster(self):
        out = self.parse(
            row(UID="a", roadtype="交通障礙"), row(UID="b", roadtype="阻塞"),
            row(UID="c", roadtype="道路施工"), row(UID="d", roadtype="災變"),
            row(UID="e"),
        )
        self.assertEqual({e["eventId"] for e in out}, {"pbs-d", "pbs-e"})

    def test_resolved_comments_dropped(self):
        for text in ("*2051北控:排除*.大園前", "已排除", "*2131中分局:事故車自行駛離*"):
            self.assertEqual(self.parse(row(comment=text)), [], text)

    def test_not_resolved_phrase_kept(self):
        self.assertEqual(len(self.parse(row(comment="尚未排除 2自小"))), 1)

    def test_old_and_future_events_dropped(self):
        self.assertEqual(self.parse(row(happentime="08:59:00.0000000")), [])
        self.assertEqual(len(self.parse(row(happentime="09:01:00.0000000"))), 1)
        self.assertEqual(self.parse(row(happendate="2026-10-12")), [])

    def test_dedup_by_uid_and_bad_coordinates(self):
        out = self.parse(row(), row(), row(UID="x", y1="", x1=""), row(UID="y", y1="0", x1="0"))
        self.assertEqual(len(out), 1)

    def test_city_road_uses_area_name_and_non_citizen_label(self):
        ev = self.parse(row(srcdetail="", areaNm="高雄市-岡山區", direction="",
                            comment="民有路68號 事故"))[0]
        self.assertEqual(ev["road"], "高雄市岡山區")
        self.assertEqual(ev["km"], "")
        self.assertNotIn("民眾", ev["section"])

    def test_provincial_road(self):
        ev = self.parse(row(areaNm="(八里新店)-台64線", direction="東向", comment="東向在6公里 自撞"))[0]
        self.assertEqual((ev["road"], ev["km"]), ("台64線", "6K"))


class MainFailureIsolationTests(unittest.TestCase):
    def test_pbs_failure_does_not_block_freeway_push(self):
        freeway_ev = {"eventId": "F1", "occurredAt": "2026-10-10T11:00:00+08:00"}
        pushed = []
        with mock.patch.object(fw, "fetch_xml", return_value=b""), \
             mock.patch.object(fw, "parse_records", return_value=[freeway_ev]), \
             mock.patch.object(fw, "fetch_pbs", side_effect=OSError("boom")), \
             mock.patch.object(fw, "load_seen", return_value={}), \
             mock.patch.object(fw, "save_seen"), \
             mock.patch.object(fw, "push_to_oracle", side_effect=pushed.append), \
             mock.patch.object(fw.OUTPUT_PATH.__class__, "write_text"):
            fw.main()
        self.assertEqual(len(pushed), 1)
        self.assertEqual(pushed[0]["events"], [freeway_ev])

    def test_dry_run_does_not_write_or_push(self):
        with mock.patch.object(fw, "fetch_xml", return_value=b""), \
             mock.patch.object(fw, "parse_records", return_value=[]), \
             mock.patch.object(fw, "fetch_pbs", return_value=[]), \
             mock.patch.object(fw, "load_seen", return_value={}), \
             mock.patch.object(fw, "save_seen") as save, \
             mock.patch.object(fw, "push_to_oracle") as push:
            fw.main(dry_run=True)
        save.assert_not_called()
        push.assert_not_called()


if __name__ == "__main__":
    unittest.main()

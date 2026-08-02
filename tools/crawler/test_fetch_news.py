import importlib.util
import json
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).with_name("fetch_news.py")
SPEC = importlib.util.spec_from_file_location("fetch_news_under_test", MODULE_PATH)
news = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(news)


def rss(items):
    rows = []
    for item in items:
        rows.append(
            "<item>"
            f"<title>{item['title']}</title>"
            f"<description>{item.get('description', '')}</description>"
            f"<link>{item['link']}</link>"
            f"<guid>{item['guid']}</guid>"
            f"<pubDate>{item['pubDate']}</pubDate>"
            "</item>"
        )
    return ("<rss><channel>" + "".join(rows) + "</channel></rss>").encode()


class NewsCrawlerTests(unittest.TestCase):
    def test_rules_rejects_dui_aftercare_but_keeps_live_collision(self):
        self.assertEqual(
            news.rules_classify(
                "雲林男酒駕拒測欠18.9萬罰款 嘉義分署轉介助戒酒", ""
            ),
            (False, None, "酒駕事後處置"),
        )
        self.assertEqual(
            news.rules_classify("酒駕自撞護欄 警消到場處理", "道路一度受阻"),
            (True, "交通", "自撞"),
        )

    def test_merge_duplicate_requires_a_distinct_source_for_corroboration(self):
        existing = {
            "sourceName": "自由時報",
            "corroboration": 1,
            "severity": "low",
            "is_ongoing": False,
        }
        same_source = {
            "sourceName": "自由時報",
            "severity": "low",
            "is_ongoing": False,
        }
        distinct_source = {
            "sourceName": "中央社",
            "severity": "medium",
            "is_ongoing": True,
        }

        news.merge_duplicate(existing, same_source)
        self.assertEqual(existing["corroboration"], 1)
        news.merge_duplicate(existing, distinct_source)
        self.assertEqual(existing["corroboration"], 2)
        self.assertEqual(existing["sourceName"], "自由時報、中央社")
        self.assertEqual(existing["severity"], "medium")
        self.assertTrue(existing["is_ongoing"])

    def test_prepare_feed_items_drops_stale_future_and_caps(self):
        now = datetime(2026, 7, 26, 12, 0, tzinfo=news.TZ_TAIPEI)

        def item(identifier, published):
            return {
                "title": identifier,
                "description": "",
                "link": f"https://example.test/{identifier}",
                "guid": identifier,
                "pubDate": published.isoformat(),
            }

        items = [
            item("fresh-1", now - timedelta(minutes=5)),
            item("fresh-2", now - timedelta(minutes=10)),
            item("fresh-3", now - timedelta(minutes=15)),
            item("stale", now - timedelta(hours=news.NEWS_MAX_AGE_HOURS + 1)),
            item("future", now + timedelta(hours=3)),
        ]
        eligible, metrics = news.prepare_feed_items(items, max_items=2, now=now)

        self.assertEqual([row["title"] for row in eligible], ["fresh-1", "fresh-2"])
        self.assertEqual(metrics["staleDropped"], 1)
        self.assertEqual(metrics["futureDropped"], 1)
        self.assertEqual(metrics["cappedDropped"], 1)

    def test_llm_transport_error_opens_circuit_and_requests_retry(self):
        with mock.patch.object(news, "call_proxy_llm", side_effect=TimeoutError("quota")), \
                mock.patch.object(news, "FREE_GEMINI_ENABLED", False), \
                mock.patch.object(news, "PAID_GEMINI_ENABLED", False):
            result, retry_later, disable_for_run, provider = news.llm_classify(
                "台中工廠火警", "消防人員持續搶救"
            )

        self.assertIsNone(result)
        self.assertTrue(retry_later)
        self.assertTrue(disable_for_run)
        self.assertIsNone(provider)

    def test_proxy_prefers_claude_then_gemini_then_openai(self):
        """優先序 claude → gemini → openai。

        2026-08-02 實測 openai/gemini 皆需 20 秒以上、超過 PROXY_LLM_TIMEOUT 上限，
        claude 只要 2 秒；舊的 openai 優先順序會讓每則新聞先撞兩次逾時而全滅。
        這裡讓最後一個（openai）才成功，藉此驗證整條 fallback 鏈的先後次序。
        """
        providers = []

        def proxy_stub(*_args, **kwargs):
            providers.append(kwargs["provider"])
            if kwargs["provider"] != "openai":
                raise TimeoutError("quota")
            return "{\"is_incident\":false}"

        with mock.patch.object(news, "_sdk_ai", side_effect=proxy_stub):
            answer = news.call_proxy_llm("測試")

        self.assertEqual(answer, "{\"is_incident\":false}")
        self.assertEqual(providers, ["claude", "gemini", "openai"])

    def test_proxy_stops_at_claude_when_it_succeeds(self):
        """claude 成功時不應再往下試——否則等於白等 openai 的 20 秒逾時。"""
        providers = []

        def proxy_stub(*_args, **kwargs):
            providers.append(kwargs["provider"])
            return "{\"is_incident\":false}"

        with mock.patch.object(news, "_sdk_ai", side_effect=proxy_stub):
            news.call_proxy_llm("測試")

        self.assertEqual(providers, ["claude"])

    def test_free_pool_is_disabled_with_zero_daily_limit(self):
        with mock.patch.object(news, "FREE_GEMINI_ENABLED", True), \
                mock.patch.object(news, "FREE_GEMINI_DAILY_CALL_LIMIT", 0):
            with self.assertRaises(news.FreeGeminiUnavailable):
                news.call_free_gemini("測試")

    def test_free_pool_rejects_insecure_key_file(self):
        with tempfile.TemporaryDirectory() as directory:
            key_path = Path(directory, "free_gemini_keys.txt")
            key_path.write_text("AQ.placeholder\n")
            key_path.chmod(0o644)
            with mock.patch.object(news, "FREE_GEMINI_KEYS_PATH", str(key_path)):
                with self.assertRaises(news.FreeGeminiUnavailable):
                    news.load_free_keys()

    def test_free_call_uses_separate_key_file_and_daily_ledger(self):
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = json.dumps({
            "candidates": [{"content": {"parts": [{"text": "{\"is_incident\":false}"}]}}],
        }).encode()

        with tempfile.TemporaryDirectory() as directory:
            key_path = Path(directory, "free_gemini_keys.txt")
            usage_path = Path(directory, "free_gemini_usage.json")
            key_path.write_text("AQ.placeholder\n")
            key_path.chmod(0o600)
            with mock.patch.object(news, "FREE_GEMINI_ENABLED", True), \
                    mock.patch.object(news, "FREE_GEMINI_DAILY_CALL_LIMIT", 2), \
                    mock.patch.object(news, "FREE_GEMINI_KEYS_PATH", str(key_path)), \
                    mock.patch.object(news, "FREE_GEMINI_USAGE_PATH", str(usage_path)), \
                    mock.patch.object(news.urllib.request, "urlopen", return_value=response) as urlopen:
                text = news.call_free_gemini("測試")
                usage = json.loads(usage_path.read_text())
                request_body = json.loads(urlopen.call_args.args[0].data)

        self.assertEqual(text, "{\"is_incident\":false}")
        day = news.free_day_key()
        self.assertEqual(usage["days"][day]["calls"], 1)
        self.assertEqual(usage["days"][day]["reservedFailures"], 0)
        self.assertEqual(request_body["generationConfig"]["thinkingConfig"]["thinkingBudget"], 0)

    def test_proxy_failure_uses_free_pool_before_paid_pool(self):
        with mock.patch.object(news, "call_proxy_llm", side_effect=TimeoutError("quota")), \
                mock.patch.object(
                    news,
                    "call_free_gemini",
                    return_value=(
                        "{\"is_incident\":true,\"county\":\"台中市\","
                        "\"district\":\"西屯區\",\"place\":null,\"category\":\"火災\","
                        "\"confidence\":0.9,\"summary\":\"台中火警\","
                        "\"detail\":\"消防人員持續搶救\",\"severity\":\"medium\","
                        "\"is_ongoing\":true}"
                    )
                ), \
                mock.patch.object(news, "call_paid_gemini") as paid:
            result, retry_later, disable_for_run, provider = news.llm_classify("台中火警", "消防搶救")

        self.assertIsNotNone(result)
        self.assertEqual(result["_llm_provider"], "gemini-free")
        self.assertEqual(provider, "gemini-free")
        self.assertFalse(retry_later)
        self.assertFalse(disable_for_run)
        paid.assert_not_called()

    def test_preferred_free_pool_skips_proxy_after_its_first_failure(self):
        with mock.patch.object(news, "call_proxy_llm") as proxy, \
                mock.patch.object(
                    news,
                    "call_free_gemini",
                    return_value=(
                        "{\"is_incident\":true,\"county\":\"台中市\","
                        "\"district\":\"西屯區\",\"place\":null,\"category\":\"火災\","
                        "\"confidence\":0.9,\"summary\":\"台中火警\","
                        "\"detail\":\"消防人員持續搶救\",\"severity\":\"medium\","
                        "\"is_ongoing\":true}"
                    )
                ):
            result, retry_later, disable_for_run, provider = news.llm_classify(
                "台中火警", "消防搶救", skip_proxy=True
            )

        self.assertIsNotNone(result)
        self.assertEqual(provider, "gemini-free")
        self.assertFalse(retry_later)
        self.assertFalse(disable_for_run)
        proxy.assert_not_called()

    def test_paid_pool_is_disabled_with_zero_limit(self):
        with mock.patch.object(news, "PAID_GEMINI_ENABLED", True), \
                mock.patch.object(news, "PAID_GEMINI_MONTHLY_LIMIT_USD", 0):
            with self.assertRaises(news.PaidGeminiUnavailable):
                news.call_paid_gemini("測試")

    def test_llm_prompt_has_bounded_news_text(self):
        prompt = news.build_llm_prompt("標" * 500, "述" * 2_000)
        self.assertIn("標" * news.LLM_MAX_TITLE_CHARS, prompt)
        self.assertNotIn("標" * (news.LLM_MAX_TITLE_CHARS + 1), prompt)
        self.assertIn("述" * news.LLM_MAX_DESCRIPTION_CHARS, prompt)
        self.assertNotIn("述" * (news.LLM_MAX_DESCRIPTION_CHARS + 1), prompt)

    def test_paid_pool_rejects_insecure_key_file(self):
        with tempfile.TemporaryDirectory() as directory:
            key_path = Path(directory, "paid_gemini_keys.txt")
            key_path.write_text("AQ.placeholder\n")
            key_path.chmod(0o644)
            with mock.patch.object(news, "PAID_GEMINI_KEYS_PATH", str(key_path)):
                with self.assertRaises(news.PaidGeminiUnavailable):
                    news.load_paid_keys()

    def test_paid_reservation_hard_stops_at_monthly_limit(self):
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(
                    news, "PAID_GEMINI_USAGE_PATH",
                    str(Path(directory, "paid_gemini_usage.json"))
                ), \
                mock.patch.object(news, "PAID_GEMINI_MONTHLY_LIMIT_USD", 0.000001):
            with self.assertRaises(news.PaidGeminiUnavailable):
                news.paid_request_reservation("會超過上限", 1)

    def test_paid_call_uses_separate_key_file_and_records_cost(self):
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = json.dumps({
            "candidates": [{"content": {"parts": [{"text": "{\"is_incident\":false}"}]}}],
            "usageMetadata": {"promptTokenCount": 10, "candidatesTokenCount": 20},
        }).encode()

        with tempfile.TemporaryDirectory() as directory:
            key_path = Path(directory, "paid_gemini_keys.txt")
            usage_path = Path(directory, "paid_gemini_usage.json")
            key_path.write_text("AQ.placeholder\n")
            key_path.chmod(0o600)
            with mock.patch.object(news, "PAID_GEMINI_ENABLED", True), \
                    mock.patch.object(news, "PAID_GEMINI_MONTHLY_LIMIT_USD", 1.0), \
                    mock.patch.object(news, "PAID_GEMINI_KEYS_PATH", str(key_path)), \
                    mock.patch.object(news, "PAID_GEMINI_USAGE_PATH", str(usage_path)), \
                    mock.patch.object(news.urllib.request, "urlopen", return_value=response):
                text = news.call_paid_gemini("測試")
                usage = json.loads(usage_path.read_text())

        self.assertEqual(text, "{\"is_incident\":false}")
        month = news.paid_month_key()
        self.assertEqual(usage["months"][month]["calls"], 1)
        self.assertEqual(usage["months"][month]["inputTokens"], 10)
        self.assertEqual(usage["months"][month]["outputTokens"], 20)
        self.assertEqual(usage["months"][month]["reservedFailures"], 0)

    def test_transient_llm_failure_is_not_written_to_seen(self):
        now = datetime.now(news.TZ_TAIPEI)
        feed_bytes = rss(
            [
                {
                    "title": "台中工廠火警消防持續搶救",
                    "description": "台中市西屯區工廠起火",
                    "link": "https://example.test/fire",
                    "guid": "fire-1",
                    "pubDate": now.isoformat(),
                },
                {
                    "title": "一般生活新聞",
                    "description": "與事故無關",
                    "link": "https://example.test/life",
                    "guid": "life-1",
                    "pubDate": now.isoformat(),
                },
            ]
        )
        feeds = [{"name": "測試新聞", "feed": "社會", "url": "memory://feed"}]

        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(news, "AI_PROXY_TOKEN", "test-token"), \
                mock.patch.object(news, "FREE_GEMINI_ENABLED", False), \
                mock.patch.object(news, "fetch_url", return_value=feed_bytes), \
                mock.patch.object(news, "call_proxy_llm", side_effect=TimeoutError("quota")):
            exit_code = news.main(feeds=feeds, out_dir=directory)
            output = json.loads(Path(directory, "latest.json").read_text())
            seen = json.loads(Path(directory, "seen.json").read_text())["ids"]

        self.assertEqual(exit_code, 0)
        self.assertEqual(output["incidentCount"], 1)
        self.assertTrue(output["pipelineHealth"]["llmCircuitOpen"])
        self.assertEqual(output["pipelineHealth"]["pendingLLMRetry"], 1)
        self.assertNotIn(news.stable_id(news.parse_rss(feed_bytes)[0]), seen)
        self.assertIn(news.stable_id(news.parse_rss(feed_bytes)[1]), seen)

    def test_district_from_text_recovers_county_when_city_name_absent(self):
        # 標題常省略縣市，只寫行政區（如「文山區KTV惡火」），要能反查回台北市
        self.assertEqual(
            news.district_from_text("文山區KTV惡火 消防搶救中"),
            ("文山區", "台北市"),
        )

    def test_district_from_text_leaves_ambiguous_district_names_unresolved(self):
        # 中正區／東區等同名行政區故意不建表，寧可查不到也不要猜錯縣市
        self.assertEqual(news.district_from_text("中正區傳出火警"), (None, None))
        self.assertEqual(news.district_from_text("東區某大樓驚傳氣爆"), (None, None))
        self.assertNotIn("中正區", news.DISTRICT_TO_COUNTY)
        self.assertNotIn("東區", news.DISTRICT_TO_COUNTY)
        # 「中區」雖只有台中市一個，但因太短容易誤判也故意排除
        self.assertNotIn("中區", news.DISTRICT_TO_COUNTY)

    def test_district_from_text_prefers_earliest_and_longest_match(self):
        # 同一句若有多個行政區，取「最靠前」命中的那個
        district, county = news.district_from_text("板橋區與新店區同步豪雨積淹水")
        self.assertEqual((district, county), ("板橋區", "新北市"))

    def test_rules_path_recovers_county_via_district_when_title_omits_city(self):
        now = datetime.now(news.TZ_TAIPEI)
        feed_bytes = rss(
            [
                {
                    "title": "文山區KTV傳出火警 多人受困",
                    "description": "消防局獲報後派遣多輛雲梯車搶救",
                    "link": "https://example.test/ktv-fire",
                    "guid": "ktv-fire-1",
                    "pubDate": now.isoformat(),
                },
            ]
        )
        feeds = [{"name": "測試新聞", "feed": "社會", "url": "memory://feed"}]

        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(news, "AI_PROXY_TOKEN", ""), \
                mock.patch.object(news, "fetch_url", return_value=feed_bytes):
            exit_code = news.main(feeds=feeds, out_dir=directory)
            output = json.loads(Path(directory, "latest.json").read_text())

        self.assertEqual(exit_code, 0)
        self.assertEqual(output["incidentCount"], 1)
        event = output["events"][0]
        self.assertEqual(event["county"], "台北市")
        self.assertEqual(event["district"], "文山區")

    def test_new_public_feeds_are_registered(self):
        urls = {feed["url"] for feed in news.FEEDS}
        self.assertIn("https://newtalk.tw/rss/all", urls)
        self.assertIn("https://newsdaily.tw/rss/society.xml", urls)
        self.assertIn("https://feeds.feedburner.com/rsscna/local", urls)
        self.assertIn("https://news.ltn.com.tw/rss/local.xml", urls)


if __name__ == "__main__":
    unittest.main()

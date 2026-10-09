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

    def test_single_llm_failure_falls_back_to_rules_and_still_marks_seen(self):
        """
        2026-08-02 熔斷邏輯改造：單則 LLM 失敗只放棄該則、退回規則結果，不再讓
        整輪停用 LLM（舊邏輯是任一則失敗就整輪停用，實測 43% 失敗率下等於每輪
        必熔斷）。這則規則抓不到地點（標題／描述都沒有縣市或行政區字樣），又
        剛好 LLM 失敗，仍要正常輸出＋標記已讀，不再靠「不寫 seen」硬等下一輪。
        """
        now = datetime.now(news.TZ_TAIPEI)
        feed_bytes = rss(
            [
                {
                    "title": "工廠火警數十人受困",
                    "description": "消防局獲報後派遣多輛雲梯車搶救",
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
        event = output["events"][0]
        self.assertIsNone(event["county"])
        self.assertEqual(event["summary"], "工廠火警數十人受困")  # summary 改用原標題
        self.assertEqual(output["pipelineHealth"]["llmFailed"], 1)
        self.assertTrue(output["pipelineHealth"]["llmCircuitOpen"])
        self.assertEqual(output["pipelineHealth"]["pendingLLMRetry"], 0)
        fire_id = news.stable_id(news.parse_rss(feed_bytes)[0])
        life_id = news.stable_id(news.parse_rss(feed_bytes)[1])
        self.assertIn(fire_id, seen)   # 舊行為是 assertNotIn；新行為是失敗也定案、標記已讀
        self.assertIn(life_id, seen)

    def test_llm_budget_exceeded_defers_item_without_marking_seen(self):
        """超出單輪呼叫預算的則完全沒機會呼叫 LLM，要保留規則結果且不可寫入
        seen，才能讓下一輪重試；跟「呼叫了但失敗」的則不同——那些已經定案。"""
        now = datetime.now(news.TZ_TAIPEI)
        feed_bytes = rss(
            [
                {
                    "title": "工廠火警數十人受困",
                    "description": "消防局獲報後派遣多輛雲梯車搶救",
                    "link": "https://example.test/fire",
                    "guid": "fire-budget-1",
                    "pubDate": now.isoformat(),
                },
            ]
        )
        feeds = [{"name": "測試新聞", "feed": "社會", "url": "memory://feed"}]

        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(news, "AI_PROXY_TOKEN", "test-token"), \
                mock.patch.object(news, "LLM_MAX_CALLS_PER_RUN", 0), \
                mock.patch.object(news, "fetch_url", return_value=feed_bytes), \
                mock.patch.object(news, "call_proxy_llm") as proxy:
            exit_code = news.main(feeds=feeds, out_dir=directory)
            output = json.loads(Path(directory, "latest.json").read_text())
            seen = json.loads(Path(directory, "seen.json").read_text())["ids"]

        self.assertEqual(exit_code, 0)
        proxy.assert_not_called()
        self.assertEqual(output["pipelineHealth"]["pendingLLMRetry"], 1)
        self.assertEqual(output["pipelineHealth"]["llmCalls"], 0)
        fire_id = news.stable_id(news.parse_rss(feed_bytes)[0])
        self.assertNotIn(fire_id, seen)

    def test_single_item_llm_failure_does_not_affect_other_items_in_the_batch(self):
        """並行批次裡某一則 LLM 全部路徑都失敗，不能拖累同批其他則的判讀結果。

        兩則標題刻意選得完全不像（不同類別關鍵字、不同開頭字），避免觸發
        find_duplicate() 的跨來源去重合併，才能各自獨立驗證結果。
        """
        now = datetime.now(news.TZ_TAIPEI)
        titles = ["甲廠房火警濃煙密布", "乙路口車輛追撞多人受傷"]
        feed_bytes = rss(
            [
                {
                    "title": t,
                    "description": "消防局獲報後到場處理",
                    "link": f"https://example.test/batch-{i}",
                    "guid": f"batch-{i}",
                    "pubDate": now.isoformat(),
                }
                for i, t in enumerate(titles)
            ]
        )
        feeds = [{"name": "測試新聞", "feed": "社會", "url": "memory://feed"}]

        def proxy_stub(prompt, **_kwargs):
            if "甲廠房火警濃煙密布" in prompt:
                raise TimeoutError("boom")
            return json.dumps({
                "is_incident": True, "county": "高雄市", "district": None, "place": None,
                "category": "交通", "confidence": 0.9, "severity": "medium", "is_ongoing": True,
            })

        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(news, "AI_PROXY_TOKEN", "test-token"), \
                mock.patch.object(news, "FREE_GEMINI_ENABLED", False), \
                mock.patch.object(news, "fetch_url", return_value=feed_bytes), \
                mock.patch.object(news, "call_proxy_llm", side_effect=proxy_stub):
            exit_code = news.main(feeds=feeds, out_dir=directory)
            output = json.loads(Path(directory, "latest.json").read_text())

        self.assertEqual(exit_code, 0)
        by_title = {e["title"]: e for e in output["events"]}
        self.assertIsNone(by_title["甲廠房火警濃煙密布"]["county"])       # 這則 LLM 失敗，退回規則結果
        self.assertEqual(by_title["乙路口車輛追撞多人受傷"]["county"], "高雄市")  # 不受另一則失敗影響
        self.assertEqual(output["pipelineHealth"]["llmFailed"], 1)

    def test_parallel_llm_results_map_back_to_the_correct_item(self):
        """
        並行結果正確對應回原本的則（順序不能錯亂）：用 ThreadPoolExecutor.map()
        保證回傳順序＝送入順序，即使個別呼叫完成的先後順序被刻意打亂（用不同
        sleep 時間模擬網路延遲），結果仍要對應回正確的則，不能把 A 則的地點
        蓋到 B 則上。並行度刻意設成 2（< 3 則候選），逼執行緒重複使用。
        """
        import time as time_module

        now = datetime.now(news.TZ_TAIPEI)
        # 三則標題刻意選得完全不像（不同類別關鍵字、不同開頭字），避免觸發
        # find_duplicate() 的跨來源去重合併，才能各自獨立驗證對應關係。
        titles = ["甲廠房火警濃煙密布", "乙路口車輛追撞多人受傷", "丙處淹水道路一度封閉"]
        feed_bytes = rss(
            [
                {
                    "title": t,
                    "description": "消防局獲報後到場處理",
                    "link": f"https://example.test/parallel-{i}",
                    "guid": f"parallel-{i}",
                    "pubDate": now.isoformat(),
                }
                for i, t in enumerate(titles)
            ]
        )
        feeds = [{"name": "測試新聞", "feed": "社會", "url": "memory://feed"}]

        county_by_title = {
            "甲廠房火警濃煙密布": "台北市",
            "乙路口車輛追撞多人受傷": "高雄市",
            "丙處淹水道路一度封閉": "台南市",
        }
        # 刻意讓完成順序被打亂：乙最快、丙次之、甲最慢
        sleep_by_title = {"甲廠房火警濃煙密布": 0.06, "乙路口車輛追撞多人受傷": 0.0, "丙處淹水道路一度封閉": 0.03}

        def proxy_stub(prompt, **_kwargs):
            matched = next(t for t in titles if t in prompt)
            time_module.sleep(sleep_by_title[matched])
            return json.dumps({
                "is_incident": True, "county": county_by_title[matched], "district": None,
                "place": None, "category": "火災", "confidence": 0.9,
                "severity": "medium", "is_ongoing": True,
            })

        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(news, "AI_PROXY_TOKEN", "test-token"), \
                mock.patch.object(news, "FREE_GEMINI_ENABLED", False), \
                mock.patch.object(news, "NEWS_LLM_CONCURRENCY", 2), \
                mock.patch.object(news, "fetch_url", return_value=feed_bytes), \
                mock.patch.object(news, "call_proxy_llm", side_effect=proxy_stub):
            exit_code = news.main(feeds=feeds, out_dir=directory)
            output = json.loads(Path(directory, "latest.json").read_text())

        self.assertEqual(exit_code, 0)
        result_county_by_title = {e["title"]: e["county"] for e in output["events"]}
        self.assertEqual(result_county_by_title, county_by_title)

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

    # -- district_from_text_v2（2026-08-02 規則優先＋LLM補位改造新增）--------

    def test_district_stripped_index_excludes_short_and_colliding_names(self):
        # 仁愛區(基隆市)／仁愛鄉(南投縣) 去後綴後都變成「仁愛」，撞名排除、不猜
        self.assertNotIn("仁愛", news.DISTRICT_STRIPPED_INDEX)
        # 大同區(台北市)／大同鄉(宜蘭縣)、東勢區(台中市)／東勢鄉(雲林縣) 同理
        self.assertNotIn("大同", news.DISTRICT_STRIPPED_INDEX)
        self.assertNotIn("東勢", news.DISTRICT_STRIPPED_INDEX)
        # 「仁武」只有仁武區（高雄市）一個來源，不撞名，應該收進索引
        self.assertEqual(news.DISTRICT_STRIPPED_INDEX["仁武"], ("仁武區", "高雄市"))
        # 去後綴長度 < 2 的一律不收（目前真實資料沒有這種案例，但規則要在）
        self.assertTrue(all(len(key) >= 2 for key in news.DISTRICT_STRIPPED_INDEX))

    def test_district_from_text_v2_matches_suffix_stripped_shorthand(self):
        # 新聞標題常簡寫「高雄仁武車禍」而非「高雄市仁武區車禍」，全名比對
        # （district_from_text）抓不到，去後綴索引才能命中「仁武」。
        self.assertEqual(
            news.district_from_text_v2("高雄仁武車禍多車追撞"),
            ("仁武區", "高雄市"),
        )

    def test_district_from_text_v2_ambiguous_alias_stays_unresolved(self):
        # 撞名的去後綴別名（仁愛）不在比對表裡，沒有「區/鄉」尾字就抓不到，
        # 寧可查不到也不要猜錯是仁愛區還是仁愛鄉。
        self.assertEqual(news.district_from_text_v2("仁愛發生火警"), (None, None))
        # 但完整名（含尾字）本來就不受影響，兩邊都查得到
        self.assertEqual(news.district_from_text_v2("仁愛區發生火警"), ("仁愛區", "基隆市"))
        self.assertEqual(news.district_from_text_v2("仁愛鄉發生火警"), ("仁愛鄉", "南投縣"))

    def test_district_from_text_v2_strips_county_core_before_matching(self):
        """
        2026-08-02 實測踩坑重現：「彰化秀水翁失聯」不先剝除已知 county 的核心字，
        會在「彰化」（彰化市的去後綴別名，位置比「秀水」更靠前）誤判成彰化市；
        正確答案是後面的「秀水鄉」。傳入已知 county 後，函式要先把「彰化」從
        文本剝除，「秀水」才會浮上來成為最靠前的命中。
        """
        # 不知道 county 時（或沒有剝除邏輯時）會被「彰化」這個別名先攔截
        self.assertEqual(
            news.district_from_text_v2("彰化秀水翁失聯", county=None),
            ("彰化市", "彰化縣"),
        )
        # 傳入已知 county="彰化縣" 後，剝除核心字「彰化」，正確找到「秀水鄉」
        self.assertEqual(
            news.district_from_text_v2("彰化秀水翁失聯", county="彰化縣"),
            ("秀水鄉", "彰化縣"),
        )

    def test_district_from_text_v2_rejects_cross_county_match(self):
        # 限同縣市：已知 county 是台北市，文本裡卻只找到屬於高雄市的「左營區」，
        # 不採信、整個回傳 (None, None)，不要讓地圖釘錯位置。
        self.assertEqual(
            news.district_from_text_v2("台北出差路過左營區", county="台北市"),
            (None, None),
        )
        # 沒有已知 county 時不受此限制，正常抓到左營區/高雄市
        self.assertEqual(
            news.district_from_text_v2("路過左營區", county=None),
            ("左營區", "高雄市"),
        )

    def test_district_from_text_v2_prefers_longest_token_on_tie(self):
        """
        長詞優先：同一起始位置若有長短兩個候選 token，取長的那個。真實的 347
        筆行政區資料裡剛好沒有「短 token 是長 token 前綴、但對應到不同行政區」
        的案例（已用程式驗證過），這裡用合成資料直接測演算法本身的 tie-break
        分支，不依賴巧合的真實地名。
        """
        # 合成地名刻意避開地物字（溪／路／山…）：那些字會被 DISTRICT_FALSE_TAIL
        # 正確地當成河川或路名排除，會蓋掉這裡要測的 tie-break 分支
        fake_table = {
            "民生東": ("民生東區", "台北市"),
            "民生": ("民生區", "高雄市"),  # 合成地名，僅用於驗證比對邏輯
        }
        fake_tokens = sorted(fake_table.keys(), key=len, reverse=True)
        with mock.patch.object(news, "DISTRICT_MATCH_TABLE", fake_table), \
                mock.patch.object(news, "DISTRICT_MATCH_TOKENS", fake_tokens):
            self.assertEqual(news.district_from_text_v2("民生東發生車禍"), ("民生東區", "台北市"))

    def test_district_from_text_v2_rejects_geographic_feature_names(self):
        """
        兩字簡稱嵌在河川／道路名裡的假命中要擋掉。實測「花蓮萬里溪堰塞湖」
        會命中新北「萬里」，把事件釘到一百多公里外的錯誤位置。
        """
        self.assertEqual(
            news.district_from_text_v2("花蓮萬里溪堰塞湖溢流警戒", county="花蓮縣"),
            (None, None),
        )
        self.assertEqual(
            news.district_from_text_v2("台中市大同路發生車禍", county="台中市"),
            (None, None),
        )
        # 真正的行政區不受影響——沒有「萬里區溪」這種地名
        self.assertEqual(
            news.district_from_text_v2("新北市萬里區發生火警", county="新北市"),
            ("萬里區", "新北市"),
        )

    def test_district_from_text_v2_finds_later_real_hit_after_fake_one(self):
        """同一篇同時出現河川名與行政區名時，跳過假命中後要能抓到後面那個真的。"""
        self.assertEqual(
            news.district_from_text_v2("萬里溪暴漲 萬里區發布警戒", county="新北市"),
            ("萬里區", "新北市"),
        )

    # -- build_detail_excerpt（2026-08-02 摘要／詳述改規則式產生，不再呼叫 AI）--

    def test_build_detail_excerpt_truncates_at_120_chars_with_ellipsis(self):
        short = "消防局獲報後派遣搶救"
        self.assertEqual(news.build_detail_excerpt(short), short)

        long_text = "字" * 150
        excerpt = news.build_detail_excerpt(long_text)
        self.assertEqual(excerpt, "字" * 120 + "…")
        self.assertEqual(len(excerpt), 121)

        self.assertIsNone(news.build_detail_excerpt(""))
        self.assertIsNone(news.build_detail_excerpt(None))
        self.assertIsNone(news.build_detail_excerpt("   "))

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


    # ------------------------------------------------------------------
    # 2026-10 新增來源：Google 新聞關鍵字 RSS、PTT 八卦版
    # ------------------------------------------------------------------

    def google_rss(self, rows):
        """組 Google 新聞 RSS：rows = [(標題含媒體尾巴, 媒體名, guid, pubDate)]"""
        body = "".join(
            f"<item><title>{t}</title><link>https://news.google.com/rss/articles/{g}</link>"
            f"<guid isPermaLink=\"false\">{g}</guid><pubDate>{d}</pubDate>"
            f"<description>&lt;a href=\"x\"&gt;{t}&lt;/a&gt;</description>"
            f"<source url=\"https://example.test\">{src}</source></item>"
            for t, src, g, d in rows
        )
        return ("<rss><channel>" + body + "</channel></rss>").encode()

    def ptt_atom(self, rows):
        entries = "".join(
            f"<entry><title>{t}</title><id>{g}</id>"
            f"<link rel=\"alternate\" href=\"https://www.ptt.cc/bbs/Gossiping/{g}.html\"/>"
            f"<updated>{d}</updated><summary>內文</summary></entry>"
            for t, g, d in rows
        )
        return ("<feed xmlns=\"http://www.w3.org/2005/Atom\">" + entries + "</feed>").encode()

    def test_google_title_split_extracts_media_and_normalizes_tier1_names(self):
        now = datetime.now(news.TZ_TAIPEI)
        data = self.google_rss([
            ("台中市北屯區工廠火警 - 聯合新聞網", "聯合新聞網", "g1", now.strftime("%a, %d %b %Y %H:%M:%S +0800")),
            ("桃園市中壢區車禍 - 某某地方報", "某某地方報", "g2", now.strftime("%a, %d %b %Y %H:%M:%S +0800")),
        ])
        items = news.parse_google_news_rss(data)
        self.assertEqual(items[0]["title"], "台中市北屯區工廠火警")
        self.assertEqual(items[0]["source_name"], "聯合報")  # 對齊 App 一線媒體名單
        self.assertEqual(items[0]["description"], "")
        self.assertEqual(items[1]["source_name"], "某某地方報")  # 未知媒體維持原名
        # 沒有 <source> 時退回以最後一個「 - 」切
        self.assertEqual(news.split_google_title("標題 - 自由時報"), ("標題", "自由時報"))
        # 標題本身含「 - 」且有 <source>：只拿掉尾巴那一段
        self.assertEqual(news.split_google_title("A - B事件 - 公視", "公視"), ("A - B事件", "公視"))
        self.assertEqual(news.canonical_media_name("ETtoday新聞雲"), "ETtoday")

    def test_google_item_dedupes_against_regular_feed_without_fake_corroboration(self):
        now = datetime.now(news.TZ_TAIPEI)
        pub = now.strftime("%a, %d %b %Y %H:%M:%S +0800")
        regular = rss([{
            "title": "台中市北屯區工廠火警 多人受困", "link": "https://udn.test/1",
            "guid": "u1", "pubDate": pub,
        }])
        google = self.google_rss([
            # 同一家媒體（聯合新聞網 → 聯合報）：合併但 corroboration 不增加
            ("台中市北屯區工廠火警 多人受困 - 聯合新聞網", "聯合新聞網", "g1", pub),
            # 另一家媒體報同一事件：合併且 corroboration +1
            ("台中市北屯區工廠火警 多人受困 - 民視新聞網", "民視新聞網", "g2", pub),
        ])
        feeds = [
            {"name": "聯合報", "feed": "社會", "url": "memory://regular"},
            {"name": "Google新聞", "feed": "火災", "url": "memory://google", "format": "google_news", "extra": True},
        ]
        fetch = lambda url, *a, **k: regular if "regular" in url else google
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(news, "AI_PROXY_TOKEN", ""), \
                mock.patch.object(news, "FREE_GEMINI_ENABLED", False), \
                mock.patch.object(news, "fetch_url", side_effect=fetch):
            news.main(feeds=feeds, out_dir=directory)
            output = json.loads(Path(directory, "latest.json").read_text())
        self.assertEqual(output["incidentCount"], 1)
        event = output["events"][0]
        self.assertEqual(event["sourceName"], "聯合報、民視新聞網")
        self.assertEqual(event["corroboration"], 2)

    def test_google_item_matching_earlier_run_is_dropped_via_recent_titles(self):
        now = datetime.now(news.TZ_TAIPEI)
        pub = now.strftime("%a, %d %b %Y %H:%M:%S +0800")
        feeds = [{"name": "Google新聞", "feed": "火災", "url": "memory://google",
                  "format": "google_news", "extra": True}]
        google = self.google_rss([("高雄市左營區民宅火警 - 某某報", "某某報", "g9", pub)])
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(news, "AI_PROXY_TOKEN", ""), \
                mock.patch.object(news, "FREE_GEMINI_ENABLED", False), \
                mock.patch.object(news, "fetch_url", return_value=google):
            Path(directory, "recent_titles.json").write_text(json.dumps({"items": [
                {"t": now.timestamp(), "n": news.normalize_title("高雄市左營區民宅火警")}
            ]}))
            news.main(feeds=feeds, out_dir=directory)
            output = json.loads(Path(directory, "latest.json").read_text())
        self.assertEqual(output["incidentCount"], 0)
        self.assertEqual(output["pipelineHealth"]["droppedRecentDuplicate"], 1)

    def test_extra_source_llm_budget_is_capped_and_deferred_without_seen(self):
        now = datetime.now(news.TZ_TAIPEI)
        pub = now.strftime("%a, %d %b %Y %H:%M:%S +0800")
        rows = [(f"工廠火警第{i}號 - 某報", "某報", f"gx{i}", pub) for i in range(5)]
        feeds = [{"name": "Google新聞", "feed": "火災", "url": "memory://google",
                  "format": "google_news", "extra": True}]
        llm = {"is_incident": True, "county": "台北市", "district": "大安區", "place": None,
               "category": "火災", "confidence": 0.9, "severity": "low", "is_ongoing": False}
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(news, "AI_PROXY_TOKEN", "t"), \
                mock.patch.object(news, "FREE_GEMINI_ENABLED", False), \
                mock.patch.object(news, "EXTRA_LLM_MAX_CALLS_PER_RUN", 2), \
                mock.patch.object(news, "fetch_url", return_value=self.google_rss(rows)), \
                mock.patch.object(news, "_llm_classify_safe", return_value=(llm, False, False, None)):
            news.main(feeds=feeds, out_dir=directory)
            output = json.loads(Path(directory, "latest.json").read_text())
            seen = json.loads(Path(directory, "seen.json").read_text())["ids"]
        health = output["pipelineHealth"]
        self.assertEqual(health["llmCalls"], 2)
        self.assertEqual(health["extraSourceDeferred"], 3)
        self.assertEqual(len(seen), 2)  # 被延後的 3 則沒寫 seen，下輪可再補

    def test_aggregator_reposts_do_not_inflate_corroboration(self):
        now = datetime.now(news.TZ_TAIPEI)
        pub = now.strftime("%a, %d %b %Y %H:%M:%S +0800")
        regular = rss([{"title": "台中市大雅區工廠火警 多人受困", "link": "https://cna.test/1",
                        "guid": "c1", "pubDate": pub}])
        google = self.google_rss([("台中市大雅區工廠火警 多人受困 - Yahoo新聞", "Yahoo新聞", "g1", pub)])
        feeds = [{"name": "中央社", "feed": "社會", "url": "memory://regular"},
                 {"name": "Google新聞", "feed": "火災", "url": "memory://google",
                  "format": "google_news", "extra": True}]
        fetch = lambda url, *a, **k: regular if "regular" in url else google
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(news, "AI_PROXY_TOKEN", ""), \
                mock.patch.object(news, "FREE_GEMINI_ENABLED", False), \
                mock.patch.object(news, "fetch_url", side_effect=fetch):
            news.main(feeds=feeds, out_dir=directory)
            output = json.loads(Path(directory, "latest.json").read_text())
        self.assertEqual(output["events"][0]["sourceName"], "中央社")
        self.assertEqual(output["events"][0]["corroboration"], 1)
        self.assertEqual(news.canonical_media_name("你的公共電視"), "公視")
        self.assertEqual(news.canonical_media_name("UDN"), "聯合報")

    def test_ptt_title_filter_only_accepts_baogua_and_news_tags(self):
        self.assertEqual(news.ptt_clean_title("[爆卦] 台中大雅火警"), "台中大雅火警")
        self.assertEqual(news.ptt_clean_title("[新聞] 高雄車禍"), "高雄車禍")
        self.assertIsNone(news.ptt_clean_title("[問卦] 為什麼火災這麼多"))
        self.assertIsNone(news.ptt_clean_title("Re: [爆卦] 台中大雅火警"))
        self.assertIsNone(news.ptt_clean_title("[閒聊] 今天車禍"))

    def test_ptt_events_are_unverified_never_llm_never_pushable_and_dedupe_to_media(self):
        now = datetime.now(news.TZ_TAIPEI)
        pub = now.strftime("%a, %d %b %Y %H:%M:%S +0800")
        iso = now.isoformat()
        regular = rss([{"title": "台中市大雅區工廠火警", "link": "https://udn.test/1",
                        "guid": "u1", "pubDate": pub}])
        ptt = self.ptt_atom([
            ("[爆卦] 台中市大雅區工廠火警 濃煙", "p1", iso),        # 與媒體重複 → 丟 PTT
            ("[爆卦] 高雄市左營區氣爆 多人受傷", "p2", iso),         # 保留，未證實
            ("[爆卦] 今天股市大漲", "p3", iso),                       # 非事故
            ("[問卦] 台北市車禍好多", "p4", iso),                     # 非爆卦/新聞標籤
            ("[爆卦] 某處發生火警", "p5", iso),                       # 無縣市 → 不輸出
        ])
        feeds = [{"name": "聯合報", "feed": "社會", "url": "memory://regular"}]
        boards = [{"board": "Gossiping", "name": "PTT八卦版", "url": "memory://ptt"}]
        fetch = lambda url, *a, **k: regular if "regular" in url else ptt
        llm = mock.Mock()
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(news, "AI_PROXY_TOKEN", "t"), \
                mock.patch.object(news, "FREE_GEMINI_ENABLED", False), \
                mock.patch.object(news, "fetch_url", side_effect=fetch), \
                mock.patch.object(news, "_llm_classify_safe", llm):
            news.main(feeds=feeds, out_dir=directory, ptt_boards=boards)
            output = json.loads(Path(directory, "latest.json").read_text())
            recent = json.loads(Path(directory, "recent_titles.json").read_text())["items"]
        ptt_events = [e for e in output["events"] if e["trust"] == news.PTT_TRUST]
        self.assertEqual(len(ptt_events), 1)
        event = ptt_events[0]
        self.assertEqual(event["sourceName"], "PTT八卦版")
        for tier1 in ("中央社", "公視", "TVBS", "聯合報", "自由時報", "ETtoday"):
            self.assertNotIn(tier1, event["sourceName"])     # App 不會升為主流媒體
        self.assertEqual(event["corroboration"], 1)
        self.assertEqual(event["severity"], "low")           # cron_check 要 high/medium
        self.assertIs(event["is_ongoing"], False)            # cron_check 要 true
        self.assertTrue(event["summary"].startswith("網友爆料（未證實）"))
        self.assertEqual(event["county"], "高雄市")
        self.assertEqual(llm.call_count, 0)                  # PTT 與其他規則完整的事件都不呼叫 LLM
        media = [e for e in output["events"] if e["trust"] != news.PTT_TRUST]
        self.assertEqual(len(media), 1)
        self.assertEqual(media[0]["corroboration"], 1)       # PTT 沒有替媒體事件灌 corroboration
        self.assertNotIn("PTT", media[0]["sourceName"])
        # PTT 標題不寫入跨輪紀錄，避免擋掉日後的媒體報導
        self.assertTrue(all("氣爆" not in r["n"] for r in recent))

    def test_ptt_failure_does_not_break_other_sources(self):
        now = datetime.now(news.TZ_TAIPEI)
        regular = rss([{"title": "台中市大雅區工廠火警", "link": "https://udn.test/1",
                        "guid": "u1", "pubDate": now.strftime("%a, %d %b %Y %H:%M:%S +0800")}])

        def fetch(url, *a, **k):
            if "ptt" in url:
                raise TimeoutError("boom")
            return regular

        feeds = [{"name": "聯合報", "feed": "社會", "url": "memory://regular"}]
        boards = [{"board": "Gossiping", "name": "PTT八卦版", "url": "memory://ptt"}]
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(news, "AI_PROXY_TOKEN", ""), \
                mock.patch.object(news, "FREE_GEMINI_ENABLED", False), \
                mock.patch.object(news, "fetch_url", side_effect=fetch):
            code = news.main(feeds=feeds, out_dir=directory, ptt_boards=boards)
            output = json.loads(Path(directory, "latest.json").read_text())
        self.assertEqual(code, 0)
        self.assertEqual(output["incidentCount"], 1)
        self.assertFalse(output["sources"][-1]["ok"])

    def test_google_queries_registered_and_bounded(self):
        google = [f for f in news.FEEDS if f.get("format") == "google_news"]
        self.assertEqual(len(google), len(news.GOOGLE_NEWS_QUERIES))
        self.assertLessEqual(len(google), 6)
        self.assertTrue(all("news.google.com/rss/search" in f["url"] and f.get("extra") for f in google))


    # ------------------------------------------------------------------
    # 2026-10 上線後修正：國外新聞誤判、區名子字串、標題去重、is_ongoing 時效
    # ------------------------------------------------------------------

    def test_real_foreign_samples_are_excluded_and_not_pinned_to_taiwan_districts(self):
        panama = "巴拿馬7.7淺層強震！東太平洋沿岸拉海嘯警報 建築受損民眾急撤"
        pacific = "太平洋海嘯預警中心發佈巴拿馬地震海嘯預警"
        dubai = "阿聯檢方：杜拜航空副機師企圖自殺式撞機 目標特拉維夫機場"
        dubai_desc = "阿拉伯聯合大公國檢察長今天表示，這名副機師原本計劃撞向以色列特拉維夫的機場。 法新社報導，根據阿聯官方媒體公布的調查結果"
        for title, desc in ((panama, ""), (pacific, ""), (dubai, dubai_desc)):
            self.assertTrue(news.is_foreign_news(title, desc), title)
        # 根因：「東太平洋」含「太平」、「法新社」含「新社」；剝除非地名詞後不再命中
        self.assertEqual(news.district_from_text_v2(panama), (None, None))
        self.assertEqual(news.district_from_text_v2(pacific), (None, None))
        self.assertEqual(news.district_from_text_v2(dubai_desc), (None, None))
        self.assertEqual(news.district_from_text(panama), (None, None))
        # 真正的太平區／新社區不受影響
        self.assertEqual(news.district_from_text_v2("台中太平區民宅火警")[0], "太平區")
        self.assertEqual(news.district_from_text_v2("台中新社區車禍")[0], "新社區")
        # 頻道標記
        self.assertTrue(news.is_foreign_news("某地發生意外 | 國際", ""))
        # 國際機場不是頻道標記
        self.assertFalse(news.is_foreign_news("桃園國際機場停車場火警", ""))

    def test_foreign_visitor_accident_in_taiwan_is_kept(self):
        self.assertFalse(news.is_foreign_news("日本遊客在台中車禍 送醫", ""))
        self.assertEqual(news.county_from_text("日本遊客在台中車禍"), "台中市")
        self.assertFalse(news.is_foreign_news("日本旅客車禍 送醫", "事故發生在宜蘭縣蘇澳鎮"))

    def test_foreign_news_is_dropped_by_main_but_taiwan_event_survives(self):
        now = datetime.now(news.TZ_TAIPEI)
        pub = now.strftime("%a, %d %b %Y %H:%M:%S +0800")
        feed = rss([
            {"title": "巴拿馬7.7淺層強震！東太平洋沿岸拉海嘯警報", "link": "l1", "guid": "a", "pubDate": pub},
            {"title": "日本遊客在台中車禍 送醫", "link": "l2", "guid": "b", "pubDate": pub},
        ])
        feeds = [{"name": "測試新聞", "feed": "社會", "url": "memory://f"}]
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(news, "AI_PROXY_TOKEN", ""), \
                mock.patch.object(news, "FREE_GEMINI_ENABLED", False), \
                mock.patch.object(news, "fetch_url", return_value=feed):
            news.main(feeds=feeds, out_dir=directory)
            output = json.loads(Path(directory, "latest.json").read_text())
        self.assertEqual(output["pipelineHealth"]["foreignDropped"], 1)
        self.assertEqual([e["county"] for e in output["events"]], ["台中市"])

    def test_normalize_title_ignores_spacing_channel_suffix_and_width(self):
        a = "巴拿馬7.7淺層強震！東太平洋沿岸拉海嘯警報 | 國際"
        b = "巴拿馬７．７淺層強震！東太平洋沿岸拉海嘯警報"
        c = "巴拿馬7.7淺層強震！ 東太平洋沿岸拉海嘯警報 - 新聞媒體"
        self.assertEqual(news.normalize_title(a), news.normalize_title(b))
        self.assertEqual(news.normalize_title(a), news.normalize_title(c))
        self.assertIsNotNone(news.find_duplicate({"title": a}, [{"title": b}]))

    def test_old_fire_is_never_ongoing_even_when_llm_says_so(self):
        """9 小時前的火警：LLM 判 is_ongoing=true 也必須被壓成 false（cron_check 只看這欄）"""
        now = datetime.now(news.TZ_TAIPEI)
        fmt = "%a, %d %b %Y %H:%M:%S +0800"
        feed = rss([
            {"title": "工廠火警 多人受困", "link": "l1", "guid": "old",
             "pubDate": (now - timedelta(hours=9)).strftime(fmt)},
            {"title": "倉庫火警 濃煙竄出", "link": "l2", "guid": "new",
             "pubDate": (now - timedelta(minutes=30)).strftime(fmt)},
        ])
        llm = {"is_incident": True, "county": "台北市", "district": "大安區", "place": None,
               "category": "火災", "confidence": 0.9, "severity": "high", "is_ongoing": True}
        feeds = [{"name": "測試新聞", "feed": "社會", "url": "memory://f"}]
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(news, "AI_PROXY_TOKEN", "t"), \
                mock.patch.object(news, "FREE_GEMINI_ENABLED", False), \
                mock.patch.object(news, "fetch_url", return_value=feed), \
                mock.patch.object(news, "_llm_classify_safe", return_value=(llm, False, False, None)):
            news.main(feeds=feeds, out_dir=directory)
            output = json.loads(Path(directory, "latest.json").read_text())
        by_title = {e["title"]: e for e in output["events"]}
        self.assertIs(by_title["工廠火警 多人受困"]["is_ongoing"], False)
        self.assertIs(by_title["倉庫火警 濃煙竄出"]["is_ongoing"], True)
        self.assertEqual(output["pipelineHealth"]["staleOngoingCleared"], 1)

    def test_parse_tvbs_local_reads_astro_island_props(self):
        import html as html_lib

        def island(aid, title, ts, comp="RealTimeArticle.CrZuDnKD.js"):
            props = json.dumps({"article": [0, {
                "articleId": [0, aid],
                "title": [0, title],
                "articleUrl": [0, f"https://news.tvbs.com.tw/local/{aid}"],
                "firstParagraph": [0, "內文第一段"],
                "publishedAt": [0, ts],
            }], "isShowCategory": [0, False]}, ensure_ascii=False)
            return (
                f'<astro-island uid="X" component-url="https://news.tvbs.com.tw/assets/{comp}" '
                f'props="{html_lib.escape(props)}" ssr client="visible"></astro-island>'
            )

        page = (
            island(4034057, "快訊／東大門夜市男持刀追砍遊客", 1791558259)
            + island(4034057, "快訊／東大門夜市男持刀追砍遊客", 1791558259)  # 重複
            + island(4034055, "基隆監獄2管理員涉傷害致死", 1791557841)
            + island(1, "不是即時清單", 1791557841, comp="Topic.BPqc.js")
        )
        items = news.parse_tvbs_local(page)
        self.assertEqual([i["guid"] for i in items], ["4034057", "4034055"])
        self.assertEqual(items[0]["link"], "https://news.tvbs.com.tw/local/4034057")
        self.assertEqual(items[0]["description"], "內文第一段")
        self.assertEqual(items[0]["pubDate"], "2026-10-09T23:04:19+08:00")
        self.assertEqual(news.parse_tvbs_local("<html>舊版頁面</html>"), [])


if __name__ == "__main__":
    unittest.main()

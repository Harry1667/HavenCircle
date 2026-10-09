<?php
// 新警報偵測（cron 每 1 分鐘＋ingest 觸發）：比對上次看過的 id，有新的危險事件
// → 透過 FCM 主題無聲喚醒 App。可見通知一律由裝置端套用生活圈與使用者設定後建立。
//
// 每個來源都只送「新出現或由不可播報升級成可播報」的狀態變化：
//   1) NCDR 官方（latest.json）：全區有感（地震/海嘯/颱風）→ 喚醒全台主題 hc_all；
//      地區性危險（火災/土石流）→ 喚醒事件行政區對應主題。
//   2) 新聞（latest_news.json）：只推「危險類型（火災/天災/公共安全）＋信心度≥0.75＋有縣市區」的，
//      喚醒該區主題，由 App 拉取後仍以「未驗證／多來源驗證」文字標示。
//   3) 消防署、台中消防、氣象署地震、AQI：官方資料一有新狀態就無聲喚醒；
//      顯示通知仍永遠由裝置端依生活圈、距離與使用者設定決定。
//
// 分級目的：危險（不論官方或新聞）即時通知到相關的人；瑣事（停水/車禍/民生）不推，避免通知疲勞。
// 隱私：訂閱關係（誰關心哪區）存在 FCM/Google，本伺服器不掌握——被駭也洩不出。
//
// crontab（ubuntu 使用者）：
//   * * * * * sudo -n -u www php /www/wwwroot/havencircle.looptw.com/apns/cron_check.php
if (php_sapi_name() !== 'cli') {
    http_response_code(404);
    exit;
}
require __DIR__ . '/_apns_lib.php';
require __DIR__ . '/_fcm_lib.php';
require __DIR__ . '/region_topic.php';

if (!defined('CRON_CHECK_LIB_ONLY')) {
    process_ncdr();
    process_cwa();
    process_nfa();
    process_taichung_fire();
    process_aqi();
    process_news();
}

/// NCDR 官方危險事件 → FCM（全台或按區）
function process_ncdr(): void {
    $file = __DIR__ . '/../crawler/data/latest.json';
    if (!file_exists($file)) { return; }
    $events = json_decode(file_get_contents($file), true)['data']['events'] ?? [];
    $currentIds = array_values(array_filter(array_map(fn($e) => $e['identifier'] ?? null, $events)));
    $fresh = seen_diff(APNS_PRIVATE_DIR . '/seen_identifiers.json', $currentIds);
    if (empty($fresh)) { return; }

    $byId = [];
    foreach ($events as $e) { if (isset($e['identifier'])) { $byId[$e['identifier']] = $e; } }

    $wideArea = ['地震', '海嘯', '颱風']; // 全區有感 → 全台廣播
    $sent = 0;
    foreach ($fresh as $id) {
        $event = $byId[$id] ?? null;
        if ($event === null) { continue; }
        $payload = apns_danger_payload($event); // null＝非危險級或已結案
        if ($payload === null) { continue; }
        $title = $payload['aps']['alert']['title'];
        $body  = $payload['aps']['alert']['body'];
        $kind  = (string)($event['category'] ?? $event['event'] ?? '');

        $isWide = false;
        foreach ($wideArea as $w) { if (strpos($kind, $w) !== false) { $isWide = true; break; } }

        if ($isWide) {
            $r = fcm_send_wake(
                ['topic' => REGION_TOPIC_ALL],
                ['identifier' => $id, 'kind' => 'official', 'reason' => 'new-alert']
            );
            apns_log(sprintf('cron_check[NCDR]: 全台 [%s] %s → %s', $id, $title, fcm_result($r)));
        } else {
            $topics = region_topics_from_area((string)($event['areaDesc'] ?? ''));
            if (empty($topics)) {
                apns_log(sprintf('cron_check[NCDR]: 無行政區資訊，未推 [%s] %s', $id, $title));
                continue;
            }
            $r = fcm_send_wake(
                ['condition' => topics_condition($topics)],
                ['identifier' => $id, 'kind' => 'official', 'reason' => 'new-alert']
            );
            apns_log(sprintf('cron_check[NCDR]: 地區 [%s] %s 區數=%d → %s', $id, $title, min(count($topics), 5), fcm_result($r)));
        }
        if (++$sent >= 5) { break; }
    }
}

/// 中央氣象署地震報告 → 全台無聲喚醒。
/// 受影響區域的精準比對留在 App 的 CWARegionAlertProvider，伺服器不保存生活圈資料。
function process_cwa(): void {
    $file = __DIR__ . '/../crawler/data/latest_cwa.json';
    if (!is_file($file)) { return; }
    $root = json_decode(file_get_contents($file), true);
    $datasets = $root['data']['datasets'] ?? [];
    $quakes = array_merge(
        $datasets['localQuakes']['Earthquake'] ?? [],
        $datasets['significantQuakes']['Earthquake'] ?? []
    );

    $states = [];
    $eligible = [];
    foreach ($quakes as $quake) {
        $number = (string)($quake['EarthquakeNo'] ?? '');
        $origin = (string)($quake['EarthquakeInfo']['OriginTime'] ?? '');
        if ($number === '' || $origin === '') { continue; }
        $areas = $quake['Intensity']['ShakingArea'] ?? [];
        $isRecent = is_recent_timestamp($origin, 3 * 3600);
        $isEligible = $isRecent && !empty($areas);
        // 同一份地震報告的文字／震度資料可能後續修訂；只要仍是同一場可播報地震，
        // 不應再次吵醒使用者。首次從不可播報轉成可播報才是狀態轉換。
        $states[$number] = $isEligible ? 'eligible' : 'not-eligible';
        if ($isEligible) { $eligible[$number] = $quake; }
    }

    $changed = state_diff(APNS_PRIVATE_DIR . '/cwa_wake_state_v2.json', $states);
    $sent = 0;
    foreach ($changed as $number) {
        if (!isset($eligible[$number])) { continue; }
        $r = fcm_send_wake(
            ['topic' => REGION_TOPIC_ALL],
            ['id' => 'cwa-quake-' . $number, 'kind' => 'cwa-earthquake', 'reason' => 'state-change']
        );
        apns_log(sprintf('cron_check[CWA]: 地震 [%s] → %s', $number, fcm_result($r)));
        if (++$sent >= 3) { break; }
    }
}

/// 消防署初報／續報 → 有效生活圈行政區的無聲喚醒。
function process_nfa(): void {
    $file = __DIR__ . '/../crawler/data/latest_nfa.json';
    if (!is_file($file)) { return; }
    $events = json_decode(file_get_contents($file), true)['data']['events'] ?? [];
    $states = [];
    $eligible = [];
    foreach ($events as $event) {
        $id = (string)($event['id'] ?? '');
        if ($id === '') { continue; }
        $county = trim((string)($event['county'] ?? ''));
        $district = trim((string)($event['district'] ?? ''));
        $active = ($event['isResolved'] ?? false) !== true
            && is_recent_timestamp((string)($event['occurredAt'] ?? ''), 12 * 3600)
            && $county !== '' && $district !== '';
        // 初報／續報的文案變動不能重複推播；案件第一次成為進行中才喚醒。
        $states[$id] = $active ? 'eligible' : 'not-eligible';
        if ($active) { $eligible[$id] = $event; }
    }
    $changed = state_diff(APNS_PRIVATE_DIR . '/nfa_wake_state_v2.json', $states);
    send_changed_regional_events('NFA', $changed, $eligible, 'nfa', 5);
}

/// 台中消防局即時災情 → 台中各行政區的無聲喚醒。
function process_taichung_fire(): void {
    $file = __DIR__ . '/../crawler/data/latest_taichung_fire.json';
    if (!is_file($file)) { return; }
    $events = json_decode(file_get_contents($file), true)['data']['events'] ?? [];
    $states = [];
    $eligible = [];
    foreach ($events as $event) {
        $acceptedAt = (string)($event['acceptedAt'] ?? '');
        $district = trim((string)($event['district'] ?? ''));
        $caseSub = (string)($event['caseSub'] ?? '');
        $id = sha1($acceptedAt . '|' . $district . '|' . $caseSub);
        $status = (string)($event['status'] ?? '');
        $caseType = (string)($event['caseType'] ?? '');
        $isResolved = str_contains($status, '返隊') || str_contains($status, '結束') || str_contains($status, '解除');
        $active = $acceptedAt !== '' && $district !== '' && !$isResolved
            && is_recent_timestamp($acceptedAt, 6 * 3600)
            && (str_contains($caseType, '火災') || str_contains($caseSub, '火'));
        // 消防局會持續更新 status（例如派遣、返隊）；進行中→進行中不是新風險。
        $states[$id] = $active ? 'eligible' : 'not-eligible';
        if ($active) {
            $event['_county'] = '台中市';
            $event['_district'] = $district;
            $eligible[$id] = $event;
        }
    }
    $changed = state_diff(APNS_PRIVATE_DIR . '/taichung_fire_wake_state_v2.json', $states);
    send_changed_regional_events('台中消防', $changed, $eligible, 'taichung-fire', 5);
}

/// AQI 突破門檻 → 環境主題無聲喚醒。
/// 測站只提供縣市，不能把它偽裝成精確行政區；App 重新拉取後才以生活圈距離決定是否顯示。
function process_aqi(): void {
    $file = __DIR__ . '/../crawler/data/latest_aqi.json';
    if (!is_file($file)) { return; }
    $stations = json_decode(file_get_contents($file), true)['data']['stations'] ?? [];
    $states = [];
    $eligibleCount = 0;
    foreach ($stations as $station) {
        $id = (string)($station['siteId'] ?? $station['name'] ?? '');
        if ($id === '') { continue; }
        $aqi = (int)($station['aqi'] ?? 0);
        $published = (string)($station['publishTime'] ?? '');
        $isEligible = $aqi >= 150 && is_recent_timestamp($published, 3 * 3600);
        // AQI 在門檻以上的每小時新數值不是新的警報，只在跨越門檻時喚醒一次；
        // 若之後降回門檻下再上升，not-eligible→eligible 會正確再次觸發。
        $states[$id] = $isEligible ? 'eligible' : 'not-eligible';
        if ($isEligible) { ++$eligibleCount; }
    }
    $changed = state_diff(APNS_PRIVATE_DIR . '/aqi_wake_state_v2.json', $states);
    $hasEligibleChange = array_filter($changed, fn($id) => ($states[$id] ?? 'not-eligible') !== 'not-eligible');
    if (empty($hasEligibleChange)) { return; }
    $r = fcm_send_wake(
        ['topic' => REGION_TOPIC_ENVIRONMENT],
        ['kind' => 'aqi', 'reason' => 'threshold-crossed', 'stationCount' => (string)$eligibleCount]
    );
    apns_log(sprintf('cron_check[AQI]: %d 個測站達警戒門檻 → %s', $eligibleCount, fcm_result($r)));
}

/// 將官方點狀事件送往已訂閱的行政區。沒有有效區名時寧可不推，避免全台誤喚醒。
function send_changed_regional_events(string $source, array $changed, array $eligible, string $kind, int $max): void {
    $sent = 0;
    foreach ($changed as $id) {
        $event = $eligible[$id] ?? null;
        if ($event === null) { continue; }
        $county = trim((string)($event['_county'] ?? $event['county'] ?? ''));
        $district = trim((string)($event['_district'] ?? $event['district'] ?? ''));
        $topics = news_region_topics($county, $district);
        if (empty($topics)) {
            apns_log(sprintf('cron_check[%s]: 無法對應有效行政區，未推 [%s] %s%s', $source, $id, $county, $district));
            continue;
        }
        $target = count($topics) === 1
            ? ['topic' => $topics[0]]
            : ['condition' => topics_condition($topics)];
        $r = fcm_send_wake($target, ['id' => $id, 'kind' => $kind, 'reason' => 'state-change']);
        apns_log(sprintf('cron_check[%s]: [%s] %s%s 區數=%d → %s',
            $source, $id, $county, $district, count($topics), fcm_result($r)));
        if (++$sent >= $max) { break; }
    }
}

/// 危險新聞 → FCM（按區）。只推高信心度、危險類型、有地點者，並標明「·新聞」。
function process_news(): void {
    $file = __DIR__ . '/../crawler/data/latest_news.json';
    if (!file_exists($file)) { return; }
    $events = json_decode(file_get_contents($file), true)['data']['events'] ?? [];

    // 推播分級改由新聞爬蟲的 AI 判斷把關（比純規則準）：
    //   類別（火災/天災/公共安全）為底線，再要求 AI 判定 is_ongoing=true 且 severity 夠高。
    //   這解決了「已獲救/已撲滅的事後報導」與「大小事不分級」的問題。交通/民生類仍不推。
    $dangerCats = ['火災' => '🔥 火災', '天災' => '🌪️ 天災', '公共安全' => '⚠️ 公共安全'];
    $pushSeverities = ['high', 'medium']; // 要推的嚴重度（可調；只留 high 會更保守）
    $minConfidence = 0.6;                 // 信心度地板（保險，擋 AI 明顯不確定的）
    $cooldownSeconds = 2 * 3600;          // 同區同類 2 小時內只推一次，收斂重複報導

    // 冷卻紀錄：{ "主題|類型": 上次推播時間 }。載入時順手清掉過期項。
    $cooldownFile = APNS_PRIVATE_DIR . '/news_push_cooldown.json';
    $now = time();
    $cooldown = is_file($cooldownFile) ? (json_decode(file_get_contents($cooldownFile), true) ?: []) : [];
    $cooldown = array_filter($cooldown, fn($ts) => ($now - (int)$ts) < $cooldownSeconds);

    // 不再只以「第一次看到這個 id」作為是否送出的依據：規則降級的新聞會先以
    // 同一個 id 落地，等 AI 重試成功才變成高風險；舊 seen_news_ids 做法會把這次
    // 升級永久吃掉。現在保存的是「此 id 目前是否可播報，以及其播報判斷指紋」。
    $byId = [];
    $states = [];
    foreach ($events as $e) {
        $id = (string)($e['id'] ?? '');
        if ($id === '') { continue; }
        $byId[$id] = $e;
        $states[$id] = news_wake_signature($e) ?? 'not-eligible';
    }
    $changedIds = state_diff(APNS_PRIVATE_DIR . '/news_wake_state_v2.json', $states);
    if (empty($changedIds)) { return; }

    $sent = 0;
    $changed = false;
    foreach ($changedIds as $id) {
        $e = $byId[$id] ?? null;
        if ($e === null) { continue; }
        if (($states[$id] ?? 'not-eligible') === 'not-eligible') { continue; }
        $cat = (string)($e['category'] ?? '');
        if (!isset($dangerCats[$cat])) { continue; }                       // 非危險類別（底線）
        if (($e['is_ongoing'] ?? false) !== true) { continue; }            // AI 判定已結束/事後報導 → 不推
        $severity = strtolower(trim((string)($e['severity'] ?? '')));
        if (!in_array($severity, $pushSeverities, true)) { continue; }     // AI 判定嚴重度不足 → 不推
        if ((float)($e['confidence'] ?? 0) < $minConfidence) { continue; } // 信心度過低（保險）
        $county = trim((string)($e['county'] ?? ''));
        $district = trim((string)($e['district'] ?? ''));
        if ($county === '' || $district === '') { continue; }              // 無地點：不廣播地方新聞

        // 正規化成「與 App 訂閱一致」的有效區名主題（補後綴、拆多區）；對不上就不推
        $topics = news_region_topics($county, $district);
        if (empty($topics)) {
            apns_log(sprintf('cron_check[news]: 無法對應有效行政區，未推 [%s] %s %s%s', $id, $cat, $county, $district));
            continue;
        }
        sort($topics);
        $cdKey = implode('+', $topics) . '|' . $cat;
        if (isset($cooldown[$cdKey])) {                                    // 同區同類冷卻中：收斂重複報導
            apns_log(sprintf('cron_check[news]: 同區同類冷卻中，略過 [%s] %s %s%s', $id, $cat, $county, $district));
            continue;
        }

        $target = count($topics) === 1 ? ['topic' => $topics[0]] : ['condition' => topics_condition($topics)];
        $r = fcm_send_wake($target, [
            'id' => $id, 'kind' => 'news', 'reason' => 'eligible-or-updated',
        ]);
        apns_log(sprintf('cron_check[news]: [%s] %s conf=%s %s%s 區數=%d → %s',
            $id, $cat, (string)($e['confidence'] ?? ''), $county, $district, count($topics), fcm_result($r)));
        if ($r['ok']) { $cooldown[$cdKey] = $now; $changed = true; }
        if (++$sent >= 5) { break; }
    }

    if ($changed) {
        file_put_contents($cooldownFile, json_encode($cooldown), LOCK_EX);
    }
}

/// 新聞是否已達到「可喚醒」門檻；回傳判斷指紋代表可播報，null 代表不可播報。
/// 這只決定是否讓 App 重抓資料，裝置端仍會檢查生活圈、通知權限、安靜時段與頻率。
function news_wake_signature(array $event): ?string {
    $dangerCategories = ['火災', '天災', '公共安全'];
    $category = (string)($event['category'] ?? '');
    if (!in_array($category, $dangerCategories, true)) { return null; }
    if (($event['is_ongoing'] ?? false) !== true) { return null; }
    // 只推「發布 2 小時內」的新聞：防止舊聞（例如首次抓到前一天的報導）被當即時事件推播
    if (!is_recent_timestamp((string)($event['publishedAt'] ?? ''), 2 * 3600)) { return null; }
    $severity = strtolower(trim((string)($event['severity'] ?? '')));
    if (!in_array($severity, ['high', 'medium'], true)) { return null; }
    if ((float)($event['confidence'] ?? 0) < 0.6) { return null; }
    $county = trim((string)($event['county'] ?? ''));
    $district = trim((string)($event['district'] ?? ''));
    if ($county === '' || $district === '') { return null; }
    $topics = news_region_topics($county, $district);
    if (empty($topics)) { return null; }
    sort($topics);
    // 信心度只負責跨過門檻；在門檻之上的小幅數值修正不應重新喚醒。
    // 嚴重度或行政區改變才視為可能需要重新判斷的風險升級。
    return state_signature([$category, $severity, $county, $district, $topics]);
}

// MARK: - 小工具

/// 讀 seen 檔、算出新 id、更新累積 seen（上限 1000）。首次執行只記錄不推（回空陣列）。
function seen_diff(string $seenFile, array $currentIds): array {
    if (!file_exists($seenFile)) {
        file_put_contents($seenFile, json_encode($currentIds), LOCK_EX);
        return []; // 首次部署：只記錄現有，不對存量狂轟
    }
    $seen = json_decode(file_get_contents($seenFile), true);
    if (!is_array($seen)) { $seen = []; }
    $fresh = array_values(array_diff($currentIds, $seen));
    $merged = array_slice(array_values(array_unique(array_merge($seen, $currentIds))), -1000);
    file_put_contents($seenFile, json_encode($merged), LOCK_EX);
    return $fresh;
}

/// 以「目前判斷狀態」而非單純 id 做差異偵測。
/// 首次建立檔案只寫入基線、不發送，避免部署時把 24 小時內的舊資料全數喚醒。
/// state 的 key 是來源 id，value 是可播報指紋或 not-eligible；同一事件從規則降級
/// 變成 AI 確認時，指紋會改變，因而能再次進入本輪的通知漏斗。
function state_diff(string $stateFile, array $currentStates): array {
    $currentStates = array_slice($currentStates, -1000, null, true);
    $lock = @fopen($stateFile . '.lock', 'c+');
    if ($lock === false || !flock($lock, LOCK_EX)) {
        if (is_resource($lock)) { fclose($lock); }
        apns_log('cron_check: 無法鎖定狀態帳本，為避免重複推播本輪略過');
        return [];
    }
    try {
        if (!file_exists($stateFile)) {
            file_put_contents($stateFile, json_encode($currentStates, JSON_UNESCAPED_UNICODE), LOCK_EX);
            return [];
        }
        $previous = json_decode(file_get_contents($stateFile), true);
        // 帳本壞掉時不能把它當成空檔，否則下一輪會把所有現存事件重新推送。
        if (!is_array($previous)) {
            apns_log('cron_check: 狀態帳本格式錯誤，為避免重複推播本輪略過');
            return [];
        }
        $changed = [];
        foreach ($currentStates as $id => $state) {
            if (!array_key_exists($id, $previous) || $previous[$id] !== $state) {
                $changed[] = $id;
            }
        }
        file_put_contents($stateFile, json_encode($currentStates, JSON_UNESCAPED_UNICODE), LOCK_EX);
        return $changed;
    } finally {
        flock($lock, LOCK_UN);
        fclose($lock);
    }
}

/// 將會影響播報與重複抑制的欄位壓成穩定雜湊；絕不把內容或地址寫進狀態檔。
function state_signature(array $fields): string {
    return sha1(json_encode($fields, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
}

/// API 資料帶時區時照原值解析；沒有時區的台灣政府時間一律視為 Asia/Taipei，
/// 避免 Oracle 主機以 UTC 解讀而平白多出八小時誤差。
function is_recent_timestamp(string $raw, int $windowSeconds): bool {
    if (trim($raw) === '') { return false; }
    try {
        $hasTimezone = (bool)preg_match('/(?:Z|[+-]\d\d:?\d\d)$/', $raw);
        $date = $hasTimezone
            ? new DateTimeImmutable($raw)
            : new DateTimeImmutable($raw, new DateTimeZone('Asia/Taipei'));
        $age = time() - $date->getTimestamp();
        return $age >= -10 * 60 && $age <= $windowSeconds;
    } catch (Exception $error) {
        return false;
    }
}

/// 多區用 FCM condition（OR），上限 5 個主題
function topics_condition(array $topics): string {
    $subset = array_slice($topics, 0, 5);
    return implode(' || ', array_map(fn($t) => "'" . $t . "' in topics", $subset));
}

function fcm_result(array $r): string {
    return $r['ok'] ? ('ok ' . $r['name']) : ('FAIL ' . $r['error']);
}

<?php
// 接收 Mac Mini 爬蟲推送的最新示警資料，寫入 data/latest.json（原子寫入，避免讀寫競態）。
require __DIR__ . '/_config.php';

header('Content-Type: application/json; charset=utf-8');

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    echo json_encode(['error' => 'method not allowed']);
    exit;
}

$key = $_SERVER['HTTP_X_INGEST_KEY'] ?? '';
if (!hash_equals(INGEST_KEY, $key)) {
    http_response_code(403);
    echo json_encode(['error' => 'forbidden']);
    exit;
}

// 多資料集：ncdr（預設，災害示警）與 aqi（環境部空品）各存一份檔案
$dataset = $_GET['dataset'] ?? 'ncdr';
if (!in_array($dataset, ['ncdr', 'aqi', 'crime', 'cwa', 'taichung_fire', 'nfa', 'cityfire', 'freeway'], true)) {
    http_response_code(400);
    echo json_encode(['error' => 'unknown dataset']);
    exit;
}

$raw = file_get_contents('php://input');
$data = json_decode($raw, true);
if (json_last_error() !== JSON_ERROR_NONE || !is_array($data)) {
    http_response_code(400);
    echo json_encode(['error' => 'invalid json']);
    exit;
}

$dataDir = __DIR__ . '/../data';
if (!is_dir($dataDir)) {
    mkdir($dataDir, 0775, true);
}

$items = $data['events'] ?? $data['stations'] ?? $data['districts'] ?? $data['alerts'] ?? null;
$nowIso = gmdate('Y-m-d\TH:i:s\Z');
$payload = [
    'received_at' => $nowIso,
    'ingested_at' => $nowIso, // 延遲量測用：與 received_at 同一時刻，語意上標記「管線落地時間」
    'count'       => is_array($items) ? count($items) : null,
    'data'        => $data,
];

$basename  = ['ncdr' => 'latest', 'aqi' => 'latest_aqi', 'crime' => 'latest_crime', 'cwa' => 'latest_cwa', 'taichung_fire' => 'latest_taichung_fire', 'nfa' => 'latest_nfa', 'cityfire' => 'latest_city_fire', 'freeway' => 'latest_freeway'][$dataset] ?? 'latest';
$tmpFile   = $dataDir . '/' . $basename . '.json.tmp';
$finalFile = $dataDir . '/' . $basename . '.json';

if (file_put_contents($tmpFile, json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT)) === false) {
    http_response_code(500);
    echo json_encode(['error' => 'write failed']);
    exit;
}
rename($tmpFile, $finalFile); // 同檔案系統內 rename 是原子操作，讀取端不會讀到寫一半的檔案

// 延遲量測：只增不改邏輯。放在 exec() 觸發之前，確保即使下面那段因環境限制
// （disable_functions 停用 exec）而拋 Fatal Error，這行也已經寫完，不會漏記。
// 只對已埋點的 ncdr / cwa 兩個 dataset 寫，其餘 dataset 沒有 source_published_at/fetched_at
// 欄位可取，寫了也是空值，不寫比較乾淨。
if ($dataset === 'ncdr' || $dataset === 'cwa') {
    $sourcePublishedAt = '';
    $fetchedAt = '';
    if ($dataset === 'ncdr') {
        $events = $data['events'] ?? [];
        foreach ($events as $e) {
            $sp = $e['source_published_at'] ?? '';
            if ($sp !== '' && $sp > $sourcePublishedAt) {
                $sourcePublishedAt = $sp; // CAP sent 皆含 +08:00 時區，字串序即可比出本批最新一筆
            }
        }
        $fetchedAt = $data['fetched_at'] ?? ($events[0]['fetched_at'] ?? '');
    } else { // cwa
        $latency = $data['latency'] ?? [];
        foreach ($latency as $entry) {
            $sp = $entry['source_published_at'] ?? '';
            if ($sp !== '' && $sp > $sourcePublishedAt) {
                $sourcePublishedAt = $sp;
            }
        }
        $fetchedAt = $data['fetched_at'] ?? '';
    }
    if ($sourcePublishedAt !== '' || $fetchedAt !== '') {
        $latencyLine = implode("\t", [$nowIso, $dataset, $sourcePublishedAt, $fetchedAt, $nowIso]) . "\n";
        @file_put_contents(__DIR__ . '/../latency.log', $latencyLine, FILE_APPEND | LOCK_EX);
    }
}

// 即時來源一落地就立刻觸發無聲喚醒檢查（背景、不阻塞回應），
// 讓推播不必等 cron 每分鐘輪詢——把警報偵測延遲砍到接近爬蟲間隔。
// crime 是週／月統計參考圖層，不屬於即時警報，故不觸發。
// 部分主機會在 PHP disable_functions 停用 exec（直接呼叫會變 Fatal Error），
// 這時由 crontab 的每分鐘 cron_check 兜底，不影響正確性。
if (in_array($dataset, ['ncdr', 'cwa', 'nfa', 'taichung_fire', 'aqi', 'cityfire', 'freeway'], true)) {
    if (function_exists('exec')) {
        @exec('php ' . escapeshellarg(__DIR__ . '/../../apns/cron_check.php') . ' > /dev/null 2>&1 &');
    } else {
        error_log('HavenCircle ingest: exec unavailable; scheduled cron_check will handle this update');
    }
}

echo json_encode([
    'status'      => 'ok',
    'received_at' => $payload['received_at'],
    'count'       => $payload['count'],
]);

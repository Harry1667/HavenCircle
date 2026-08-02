<?php
// 給 App／任何客戶端拉取最新示警資料，直接讀 data/latest.json 原封輸出。
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-cache, max-age=0');
header('Access-Control-Allow-Origin: *');

$dataset = $_GET['dataset'] ?? 'ncdr';
$basename = ['ncdr' => 'latest', 'aqi' => 'latest_aqi', 'crime' => 'latest_crime', 'news' => 'latest_news', 'cwa' => 'latest_cwa', 'taichung_fire' => 'latest_taichung_fire', 'nfa' => 'latest_nfa', 'cityfire' => 'latest_city_fire', 'freeway' => 'latest_freeway'][$dataset] ?? 'latest';
$file = __DIR__ . '/../data/' . $basename . '.json';
if (!file_exists($file)) {
    http_response_code(404);
    echo json_encode(['error' => 'no data yet']);
    exit;
}

readfile($file);

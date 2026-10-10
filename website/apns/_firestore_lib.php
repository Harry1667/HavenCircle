<?php
// Firestore REST 共用函式庫（服務帳號換 datastore token → 讀寫 Firestore）。
// 被 firestore_cleanup.php、family_push.php 引用；本檔只定義函式，不執行任何動作。
// 沿用 _fcm_lib.php 的服務帳號（fcm_service_account()、fcm_base64url()）。

if (PHP_SAPI !== 'cli') { http_response_code(404); exit; } // 函式庫不可被 HTTP 直接存取

require_once __DIR__ . '/_fcm_lib.php';

const FS_PROJECT  = 'havencircle-a48c2';
const FS_DATABASE = 'default';
const FS_BASE     = 'https://firestore.googleapis.com/v1/projects/' . FS_PROJECT . '/databases/' . FS_DATABASE . '/documents';

function fs_log(string $msg): void {
    echo '[' . date('Y-m-d H:i:s') . '] ' . $msg . "\n";
}

// 以服務帳號換 datastore 範圍的 OAuth token（FCM 那支只有 messaging 範圍）
function fs_access_token(): string {
    $sa = fcm_service_account();
    if (!$sa) throw new RuntimeException('讀不到服務帳號檔');
    $now = time();
    $header = fcm_base64url(json_encode(['alg' => 'RS256', 'typ' => 'JWT']));
    $claims = fcm_base64url(json_encode([
        'iss'   => $sa['client_email'],
        'scope' => 'https://www.googleapis.com/auth/datastore',
        'aud'   => 'https://oauth2.googleapis.com/token',
        'iat'   => $now,
        'exp'   => $now + 3600,
    ]));
    $sig = '';
    if (!openssl_sign("$header.$claims", $sig, $sa['private_key'], 'sha256WithRSAEncryption')) {
        throw new RuntimeException('JWT 簽章失敗');
    }
    $jwt = "$header.$claims." . fcm_base64url($sig);
    $res = fs_http('POST', 'https://oauth2.googleapis.com/token', null, http_build_query([
        'grant_type' => 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        'assertion'  => $jwt,
    ]), 'application/x-www-form-urlencoded');
    if (empty($res['access_token'])) throw new RuntimeException('換 token 失敗：' . json_encode($res));
    return $res['access_token'];
}

function fs_http(string $method, string $url, ?string $token, ?string $body = null, string $type = 'application/json'): array {
    $ch = curl_init($url);
    $headers = ["Content-Type: $type"];
    if ($token) $headers[] = "Authorization: Bearer $token";
    curl_setopt_array($ch, [
        CURLOPT_CUSTOMREQUEST  => $method,
        CURLOPT_HTTPHEADER     => $headers,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 30,
    ]);
    if ($body !== null) curl_setopt($ch, CURLOPT_POSTFIELDS, $body);
    $raw = curl_exec($ch);
    $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $err = curl_error($ch);
    curl_close($ch);
    if ($raw === false) throw new RuntimeException("HTTP 失敗：{$err}");
    $data = json_decode($raw, true) ?? [];
    if ($code >= 400) throw new RuntimeException("HTTP {$code}：" . substr($raw, 0, 300));
    return $data;
}

// Firestore 型別值 → PHP 值（只處理本專案會用到的型別）
function fs_value(array $v) {
    if (isset($v['stringValue'])) return $v['stringValue'];
    if (isset($v['timestampValue'])) return strtotime($v['timestampValue']);
    if (isset($v['integerValue'])) return (int)$v['integerValue'];
    if (isset($v['doubleValue'])) return (float)$v['doubleValue'];
    if (isset($v['booleanValue'])) return (bool)$v['booleanValue'];
    if (isset($v['nullValue'])) return null;
    // map 欄位（例如 pings 的 ack：uid → 名字）→ 關聯陣列；空 map 沒有 fields 鍵
    if (isset($v['mapValue'])) {
        $m = [];
        foreach ($v['mapValue']['fields'] ?? [] as $mk => $mv) $m[$mk] = fs_value($mv);
        return $m;
    }
    return null;
}

// 文件 → ['_name'=>完整名稱, '_id'=>文件ID, '_family'=>家庭ID 或 null, 欄位…]（timestamp 轉 unix 秒）
function fs_decode_doc(array $doc): array {
    $out = ['_name' => $doc['name'], '_id' => basename($doc['name']), '_family' => null];
    if (preg_match('#/documents/families/([^/]+)/#', $doc['name'], $m)) $out['_family'] = $m[1];
    foreach ($doc['fields'] ?? [] as $k => $v) $out[$k] = fs_value($v);
    return $out;
}

// 列出某集合底下的所有文件（解碼後），例如 families/abc/members
function fs_list_docs(string $token, string $collectionPath): array {
    $docs = [];
    $pageToken = '';
    do {
        $url = FS_BASE . '/' . $collectionPath . '?pageSize=300'
            . ($pageToken !== '' ? '&pageToken=' . urlencode($pageToken) : '');
        $res = fs_http('GET', $url, $token);
        foreach ($res['documents'] ?? [] as $doc) $docs[] = fs_decode_doc($doc);
        $pageToken = $res['nextPageToken'] ?? '';
    } while ($pageToken !== '');
    return $docs;
}

// collection group 查詢（跨所有家庭一次撈，省讀取次數）。
// $sinceField 有值就加 `欄位 >= $sinceTs` 過濾（需要該欄位的 collection group 索引）；
// 索引未建（FAILED_PRECONDITION）時自動退回「不過濾」並由呼叫端在 PHP 內篩。
function fs_group_query(string $token, string $collectionId, ?string $sinceField = null, ?int $sinceTs = null, ?bool &$usedFallback = null): array {
    $usedFallback = false;
    $url = FS_BASE . ':runQuery';
    $build = function (bool $filtered) use ($collectionId, $sinceField, $sinceTs) {
        $q = ['from' => [['collectionId' => $collectionId, 'allDescendants' => true]], 'limit' => 5000];
        if ($filtered && $sinceField !== null) {
            $q['where'] = ['fieldFilter' => [
                'field' => ['fieldPath' => $sinceField],
                'op'    => 'GREATER_THAN_OR_EQUAL',
                'value' => ['timestampValue' => gmdate('Y-m-d\TH:i:s\Z', $sinceTs)],
            ]];
        }
        return json_encode(['structuredQuery' => $q]);
    };
    try {
        $rows = fs_http('POST', $url, $token, $build(true));
    } catch (RuntimeException $e) {
        if ($sinceField === null || strpos($e->getMessage(), 'index') === false) throw $e;
        $usedFallback = true;
        $rows = fs_http('POST', $url, $token, $build(false));
    }
    $docs = [];
    foreach ($rows as $row) {
        if (!empty($row['document'])) $docs[] = fs_decode_doc($row['document']);
    }
    return $docs;
}


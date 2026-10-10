<?php
// Firestore 過期資料清理（取代需付費方案的 TTL policy）
// 刪除 expireAt 已過的：families/{id}/locations/{uid}/trail、families/{id}/arrivals、families/{id}/locationRequests
// 用法：php firestore_cleanup.php [--dry-run]；由 cron 每小時以 www 身分執行
// 只允許命令列執行：這個檔案放在網站目錄內，不能被 HTTP 觸發

if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }

require_once __DIR__ . '/_fcm_lib.php'; // 借用 fcm_service_account()、fcm_base64url()

const FS_PROJECT  = 'havencircle-a48c2';
const FS_DATABASE = 'default';
const FS_BASE     = 'https://firestore.googleapis.com/v1/projects/' . FS_PROJECT . '/databases/' . FS_DATABASE . '/documents';

$dryRun = in_array('--dry-run', $argv, true);

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
    if ($raw === false) throw new RuntimeException("HTTP 失敗：$err");
    $data = json_decode($raw, true) ?? [];
    if ($code >= 400) throw new RuntimeException("HTTP $code：" . substr($raw, 0, 300));
    return $data;
}

// 列出某個集合的所有文件名稱（分頁）
function fs_list_names(string $token, string $collectionPath): array {
    $names = [];
    $pageToken = '';
    do {
        $url = FS_BASE . '/' . $collectionPath . '?pageSize=300&mask.fieldPaths=__name__'
            . ($pageToken !== '' ? '&pageToken=' . urlencode($pageToken) : '');
        $res = fs_http('GET', $url, $token);
        foreach ($res['documents'] ?? [] as $doc) $names[] = $doc['name'];
        $pageToken = $res['nextPageToken'] ?? '';
    } while ($pageToken !== '');
    return $names;
}

// 查 parent 底下某子集合中 expireAt < 現在 的文件
function fs_expired(string $token, string $parentName, string $collectionId): array {
    $parentPath = substr($parentName, strpos($parentName, '/documents/') + strlen('/documents/'));
    $url = FS_BASE . '/' . $parentPath . ':runQuery';
    $query = ['structuredQuery' => [
        'from'   => [['collectionId' => $collectionId]],
        'where'  => ['fieldFilter' => [
            'field' => ['fieldPath' => 'expireAt'],
            'op'    => 'LESS_THAN',
            'value' => ['timestampValue' => gmdate('Y-m-d\TH:i:s\Z')],
        ]],
        'select' => ['fields' => [['fieldPath' => '__name__']]],
        'limit'  => 2000,
    ]];
    $rows = fs_http('POST', $url, $token, json_encode($query));
    $names = [];
    foreach ($rows as $row) {
        if (!empty($row['document']['name'])) $names[] = $row['document']['name'];
    }
    return $names;
}

function fs_delete_all(string $token, array $names): int {
    $deleted = 0;
    foreach (array_chunk($names, 400) as $chunk) {
        $writes = array_map(fn($n) => ['delete' => $n], $chunk);
        $url = 'https://firestore.googleapis.com/v1/projects/' . FS_PROJECT . '/databases/' . FS_DATABASE . '/documents:batchWrite';
        $res = fs_http('POST', $url, $token, json_encode(['writes' => $writes]));
        foreach ($res['status'] ?? [] as $st) {
            if (($st['code'] ?? 0) === 0) $deleted++;
        }
    }
    return $deleted;
}

try {
    $token = fs_access_token();
    $families = fs_list_names($token, 'families');
    $expired = ['trail' => [], 'arrivals' => [], 'locationRequests' => []];
    foreach ($families as $family) {
        $familyPath = substr($family, strpos($family, '/documents/') + strlen('/documents/'));
        $expired['arrivals'] = array_merge($expired['arrivals'], fs_expired($token, $family, 'arrivals'));
        $expired['locationRequests'] = array_merge($expired['locationRequests'], fs_expired($token, $family, 'locationRequests'));
        foreach (fs_list_names($token, $familyPath . '/locations') as $loc) {
            $expired['trail'] = array_merge($expired['trail'], fs_expired($token, $loc, 'trail'));
        }
    }
    $summary = [];
    foreach ($expired as $kind => $names) {
        $n = $dryRun ? count($names) : fs_delete_all($token, $names);
        $summary[] = "$kind " . ($dryRun ? "待刪" : "已刪") . " $n";
    }
    fs_log('家庭 ' . count($families) . ' 個｜' . implode('｜', $summary) . ($dryRun ? '（試跑，未刪除）' : ''));
} catch (Throwable $e) {
    fs_log('清理失敗：' . $e->getMessage());
    exit(1);
}

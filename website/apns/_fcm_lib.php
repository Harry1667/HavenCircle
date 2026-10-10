<?php
// FCM HTTP v1 發送函式庫：用服務帳戶私鑰簽 RS256 JWT → 換 OAuth2 access token → 對「主題」發推播。
// 服務帳戶檔 _fcm_service_account.json 只存伺服器（gitignore），此檔本身是程式碼、可進 git。
// 被 cron_check.php 引用：全台有感事件發 REGION_TOPIC_ALL，地區性事件發對應行政區主題。
// 走 FCM 的好處：訂閱關係（誰關心哪一區）存在 Google，這台伺服器完全不掌握，被駭也洩不出。

function fcm_service_account(): ?array {
    $f = __DIR__ . '/_fcm_service_account.json';
    if (!is_file($f)) { return null; }
    $j = json_decode(file_get_contents($f), true);
    return is_array($j) ? $j : null;
}

function fcm_base64url(string $raw): string {
    return rtrim(strtr(base64_encode($raw), '+/', '-_'), '=');
}

/// 取得 OAuth2 access token（服務帳戶 JWT 換取，快取到過期前）。失敗回 null。
function fcm_access_token(): ?string {
    $sa = fcm_service_account();
    if ($sa === null || empty($sa['client_email']) || empty($sa['private_key'])) { return null; }

    $cacheFile = __DIR__ . '/data/fcm_token_cache.json';
    if (is_file($cacheFile)) {
        $c = json_decode(file_get_contents($cacheFile), true);
        if (is_array($c) && isset($c['exp'], $c['token']) && time() < ($c['exp'] - 60)) {
            return $c['token'];
        }
    }

    $now = time();
    $header = fcm_base64url(json_encode(['alg' => 'RS256', 'typ' => 'JWT']));
    $claims = fcm_base64url(json_encode([
        'iss'   => $sa['client_email'],
        'scope' => 'https://www.googleapis.com/auth/firebase.messaging',
        'aud'   => 'https://oauth2.googleapis.com/token',
        'iat'   => $now,
        'exp'   => $now + 3600,
    ]));
    $input = $header . '.' . $claims;
    $key = openssl_pkey_get_private($sa['private_key']);
    if ($key === false) { return null; }
    if (!openssl_sign($input, $sig, $key, OPENSSL_ALGO_SHA256)) { return null; }
    $jwt = $input . '.' . fcm_base64url($sig);

    $ch = curl_init('https://oauth2.googleapis.com/token');
    curl_setopt_array($ch, [
        CURLOPT_POST           => true,
        CURLOPT_POSTFIELDS     => http_build_query([
            'grant_type' => 'urn:ietf:params:oauth:grant-type:jwt-bearer',
            'assertion'  => $jwt,
        ]),
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 15,
    ]);
    $resp = curl_exec($ch);
    $status = curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
    curl_close($ch);
    if ($resp === false) { return null; }
    $data = json_decode($resp, true);
    if ($status !== 200 || !isset($data['access_token'])) { return null; }

    $token = $data['access_token'];
    $exp = $now + (int)($data['expires_in'] ?? 3600);
    @file_put_contents($cacheFile, json_encode(['exp' => $exp, 'token' => $token]), LOCK_EX);
    return $token;
}

/// 對主題或 condition 發可見推播。
/// $target = ['topic' => 'hc_all'] 或 ['condition' => "'hc_r_x' in topics || 'hc_r_y' in topics"]。
/// 回 ['ok' => bool, 'status' => int, 'name' => ?string, 'error' => ?string]。
/// $opts：
///  - collapseId：APNs 會拿它當通知識別碼。與 App 本機通知用同一個識別碼時，兩則會合併成一則（避免重複）
///  - interruptionLevel：預設 time-sensitive；一般訊息（例如家人報平安）傳 'active'，不穿透專注模式
function fcm_send(array $target, string $title, string $body, array $data = [], array $opts = []): array {
    $headers = ['apns-priority' => '10'];
    if (($opts['collapseId'] ?? '') !== '') { $headers['apns-collapse-id'] = substr((string)$opts['collapseId'], 0, 64); }
    $message = [
        'notification' => ['title' => $title, 'body' => $body],
        'apns' => [
            'headers' => $headers,
            'payload' => ['aps' => ['sound' => 'default', 'interruption-level' => $opts['interruptionLevel'] ?? 'time-sensitive']],
        ],
    ];
    if (!empty($data)) { $message['data'] = array_map('strval', $data); }
    $message = fcm_apply_target($message, $target);
    if ($message === null) {
        return ['ok' => false, 'status' => 0, 'name' => null, 'error' => 'no-target'];
    }
    return fcm_send_message($message);
}

/// 對主題發「無聲資料更新」而非可見通知。
/// iOS 喚醒 App 後，由 EventPipeline 在裝置端套用生活圈、提醒時段、可信度與暫停設定，
/// 命中才建立本機通知。這避免伺服器可見推播繞過使用者的「暫停提醒」。
function fcm_send_wake(array $target, array $data = []): array {
    $message = [
        'data' => array_map('strval', $data),
        'apns' => [
            'headers' => [
                'apns-priority' => '5',
                'apns-push-type' => 'background',
            ],
            'payload' => ['aps' => ['content-available' => 1]],
        ],
    ];
    $message = fcm_apply_target($message, $target);
    if ($message === null) {
        return ['ok' => false, 'status' => 0, 'name' => null, 'error' => 'no-target'];
    }
    return fcm_send_message($message);
}

/// 套用 token/topic/condition；無有效目標回 null。
function fcm_apply_target(array $message, array $target): ?array {
    if (isset($target['token'])) {
        $message['token'] = $target['token']; // 單一裝置（家人推播：依 uid 取得的 FCM 註冊權杖）
    } elseif (isset($target['topic'])) {
        $message['topic'] = $target['topic'];
    } elseif (isset($target['condition'])) {
        $message['condition'] = $target['condition'];
    } else {
        return null;
    }
    return $message;
}

/// 送出已完成的 FCM HTTP v1 message。
function fcm_send_message(array $message): array {
    $sa = fcm_service_account();
    $token = fcm_access_token();
    if ($sa === null || $token === null) {
        return ['ok' => false, 'status' => 0, 'name' => null, 'error' => 'no-token'];
    }
    $url = 'https://fcm.googleapis.com/v1/projects/' . $sa['project_id'] . '/messages:send';
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_POST           => true,
        CURLOPT_POSTFIELDS     => json_encode(['message' => $message], JSON_UNESCAPED_UNICODE),
        CURLOPT_HTTPHEADER     => ['Authorization: Bearer ' . $token, 'Content-Type: application/json'],
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 15,
    ]);
    $resp = curl_exec($ch);
    $status = curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
    curl_close($ch);
    $decoded = json_decode($resp ?: '', true);
    if ($status === 200 && isset($decoded['name'])) {
        return ['ok' => true, 'status' => 200, 'name' => $decoded['name'], 'error' => null];
    }
    return ['ok' => false, 'status' => $status, 'name' => null,
            'error' => $decoded['error']['message'] ?? ($resp ?: 'unknown')];
}

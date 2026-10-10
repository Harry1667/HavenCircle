<?php
// 家庭推播：由 cron 每分鐘執行（Firebase 未開付費方案，不能用 Cloud Functions，所以改由這裡輪詢 Firestore）
//  1) arrivals：家人到達／離開守護地點（source=region、最近 10 分鐘）→ 推播給同家庭「其他成員」
//  2) locationRequests：家人按「更新位置」→ 對被請求者發靜默 data message {type:locationRequest}
// 收件裝置的 FCM 權杖來自 families/{fid}/members/{uid}.fcmToken（App 端自行登記）。
// 已處理的事件記在 data/family_push_seen.json（保留 48 小時），同一事件不重送。
// 用法：php family_push.php [--dry-run]（只列出會發什麼，不真的發、也不寫 seen）
// 只允許命令列執行：此檔位於網站目錄內，不能被 HTTP 觸發。

if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }

require_once __DIR__ . '/_firestore_lib.php';

const FP_ARRIVAL_WINDOW = 600;      // 只看最近 10 分鐘的到達事件
const FP_REQUEST_WINDOW = 600;      // 更新位置請求超過 10 分鐘就不再喚醒（App 端也會視為過期）
const FP_SEEN_KEEP      = 48 * 3600;
const FP_SEEN_FILE      = __DIR__ . '/data/family_push_seen.json';

$dryRun = in_array('--dry-run', $argv, true);

function fp_load_seen(): array {
    if (!is_file(FP_SEEN_FILE)) return [];
    $j = json_decode((string)file_get_contents(FP_SEEN_FILE), true);
    return is_array($j) ? $j : [];
}

function fp_save_seen(array $seen): void {
    $cut = time() - FP_SEEN_KEEP;
    $seen = array_filter($seen, fn($t) => $t >= $cut);
    if (file_put_contents(FP_SEEN_FILE, json_encode($seen), LOCK_EX) === false) {
        throw new RuntimeException('寫入 seen 檔失敗：' . FP_SEEN_FILE);
    }
}

// 取得某家庭成員 uid => ['token'=>…, 'name'=>…]（快取，同一輪同家庭只讀一次）
function fp_members(string $token, string $familyId): array {
    static $cache = [];
    if (!isset($cache[$familyId])) {
        $m = [];
        foreach (fs_list_docs($token, "families/$familyId/members") as $d) {
            $m[$d['_id']] = ['token' => $d['fcmToken'] ?? '', 'name' => $d['displayName'] ?? ''];
        }
        $cache[$familyId] = $m;
    }
    return $cache[$familyId];
}

// 暫時性錯誤（網路、429、5xx）才值得下一輪重試；權杖失效等永久錯誤直接放棄
function fp_transient(array $r): bool {
    return $r['status'] === 0 || $r['status'] === 429 || $r['status'] >= 500;
}

$stat = ['arr' => 0, 'arrSent' => 0, 'req' => 0, 'reqSent' => 0, 'skipNoToken' => 0, 'fail' => 0];
$exit = 0;

try {
    $token = fs_access_token();
    $seen = fp_load_seen();
    $now = time();
    $changed = false;

    // ---- 1) 到達／離開 ----
    $fallback = false;
    $arrivals = fs_group_query($token, 'arrivals', 'createdAt', $now - FP_ARRIVAL_WINDOW, $fallback);
    if ($fallback) fs_log('提示：arrivals 的 collection group 索引（createdAt）未建，改為全撈後在 PHP 篩選；建議部署 firestore.indexes.json 以省讀取');
    foreach ($arrivals as $a) {
        $fid = $a['_family'];
        if ($fid === null || ($a['source'] ?? '') !== 'region') continue;
        $created = $a['createdAt'] ?? 0;
        if ($created < $now - FP_ARRIVAL_WINDOW) continue;
        if (($a['expireAt'] ?? PHP_INT_MAX) < $now) continue;
        $stat['arr']++;
        $kindWord = ($a['kind'] ?? '') === 'leave' ? '離開' : '到達';
        $who = trim((string)($a['name'] ?? '')) !== '' ? $a['name'] : '家人';
        $place = trim((string)($a['placeName'] ?? '')) !== '' ? $a['placeName'] : '守護地點';
        $title = "{$who}{$kindWord}{$place}";
        $members = fp_members($token, $fid);
        foreach ($members as $uid => $m) {
            if ($uid === ($a['uid'] ?? '')) continue; // 不通知本人
            $key = "arr/$fid/{$a['_id']}/$uid";
            if (isset($seen[$key])) continue;
            if ($m['token'] === '') {
                $stat['skipNoToken']++;
                fs_log("略過（成員尚未登記權杖）：family={$fid} uid={$uid} 事件={$title}");
                $seen[$key] = $now; $changed = true; // 沒權杖補不回來，不用每分鐘重看
                continue;
            }
            if ($dryRun) {
                fs_log("[試跑] 會推播：family={$fid} → uid={$uid}｜{$title}｜安心圈");
                continue;
            }
            $r = fcm_send(['token' => $m['token']], $title, '安心圈', ['type' => 'familyArrival']);
            if ($r['ok']) {
                $stat['arrSent']++;
                $seen[$key] = $now; $changed = true;
            } else {
                $stat['fail']++;
                fs_log("推播失敗：family={$fid} uid={$uid} status={$r['status']} 原因={$r['error']}");
                if (!fp_transient($r)) { $seen[$key] = $now; $changed = true; }
            }
        }
    }

    // ---- 2) 更新位置請求 ----
    $requests = fs_group_query($token, 'locationRequests');
    foreach ($requests as $q) {
        $fid = $q['_family'];
        if ($fid === null) continue;
        $reqAt = $q['requestedAt'] ?? ($q['createdAt'] ?? 0);
        if ($reqAt < $now - FP_REQUEST_WINDOW) continue;
        if (($q['expireAt'] ?? PHP_INT_MAX) < $now) continue;
        $target = $q['_id']; // 文件 ID = 被請求者 uid
        $stat['req']++;
        $key = "req/$fid/$target/$reqAt"; // 帶 requestedAt：同一人再次請求算新請求
        if (isset($seen[$key])) continue;
        $m = fp_members($token, $fid)[$target] ?? null;
        if ($m === null || $m['token'] === '') {
            $stat['skipNoToken']++;
            fs_log("略過（被請求者尚未登記權杖）：family={$fid} uid={$target}");
            $seen[$key] = $now; $changed = true;
            continue;
        }
        if ($dryRun) {
            fs_log("[試跑] 會靜默喚醒：family={$fid} → uid={$target}｜{type:locationRequest}（請求者 " . ($q['requesterUid'] ?? '?') . "）");
            continue;
        }
        $r = fcm_send_wake(['token' => $m['token']], ['type' => 'locationRequest']);
        if ($r['ok']) {
            $stat['reqSent']++;
            $seen[$key] = $now; $changed = true;
        } else {
            $stat['fail']++;
            fs_log("喚醒失敗：family={$fid} uid={$target} status={$r['status']} 原因={$r['error']}");
            if (!fp_transient($r)) { $seen[$key] = $now; $changed = true; }
        }
    }

    if (!$dryRun && $changed) fp_save_seen($seen);
    if ($stat['fail'] > 0) $exit = 1;
} catch (Throwable $e) {
    fs_log('家庭推播失敗：' . $e->getMessage());
    exit(1);
}

fs_log(sprintf('到達事件 %d（已推 %d）｜更新位置請求 %d（已喚醒 %d）｜無權杖略過 %d｜失敗 %d%s',
    $stat['arr'], $stat['arrSent'], $stat['req'], $stat['reqSent'], $stat['skipNoToken'], $stat['fail'],
    $dryRun ? '｜試跑，未發送' : ''));
exit($exit);

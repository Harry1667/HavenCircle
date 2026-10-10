#!/bin/bash
# 用法：tools/uitest/with_device_lock.sh <UDID> <指令...>
# 同一台實機同時只能跑一個 xcodebuild test；用 mkdir 當鎖，搶不到就等（最多 20 分鐘）
UDID="${1:?需要 UDID}"; shift
LOCK="/tmp/hc-uitest-lock-$UDID"
for _ in $(seq 1 600); do
  if mkdir "$LOCK" 2>/dev/null; then
    trap 'rmdir "$LOCK" 2>/dev/null' EXIT
    "$@"; exit $?
  fi
  sleep 2
done
echo "等不到裝置鎖：$LOCK（可能有殘留，確認沒有測試在跑後 rmdir 它）" >&2
exit 1

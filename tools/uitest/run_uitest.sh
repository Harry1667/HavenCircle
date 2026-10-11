#!/bin/bash
# 用法：tools/uitest/run_uitest.sh <裝置UDID> <測試名> [INVITE_CODE]
# 例：tools/uitest/run_uitest.sh 084A57E9-6DF1-4965-9CAD-2B82239FD729 testFamilyTour
set -u
UDID="${1:?需要裝置 UDID}"; TEST="${2:?需要測試名}"; CODE="${3:-}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/build/uitest-shots/${TEST}-${STAMP}"
RESULT="$ROOT/build/uitest-results/${TEST}-${STAMP}.xcresult"
mkdir -p "$OUT" "$(dirname "$RESULT")"
cd "$ROOT" || exit 1

export TEST_RUNNER_INVITE_CODE="$CODE"
# 可用環境變數 DD 指定獨立的 DerivedData，避免和其他同時進行的建置互搶鎖
DD_ARGS=(); [ -n "${DD:-}" ] && DD_ARGS=(-derivedDataPath "$DD")
xcodebuild test -project HavenCircle.xcodeproj -scheme HavenCircle \
  -destination "id=$UDID" -allowProvisioningUpdates ${DD_ARGS[@]+"${DD_ARGS[@]}"} \
  -only-testing:"HavenCircleUITests/HavenCircleUITests/$TEST" \
  -resultBundlePath "$RESULT" 2>&1 | tail -n 40
RC=${PIPESTATUS[0]}

# 匯出所有 attachment（含 manifest.json），再依測試內命名改檔名
xcrun xcresulttool export attachments --path "$RESULT" --output-path "$OUT" >/dev/null 2>&1
/usr/bin/python3 - "$OUT" <<'PY'
import json, os, sys, shutil
out = sys.argv[1]
mf = os.path.join(out, "manifest.json")
if not os.path.exists(mf):
    print("（沒有 manifest.json，未匯出附件）"); sys.exit()
for test in json.load(open(mf)):
    for a in test.get("attachments", []):
        src = os.path.join(out, a["exportedFileName"])
        name = a.get("suggestedHumanReadableName", a["exportedFileName"])
        base = name.split("_")[0] if "_" in name else name
        ext = os.path.splitext(a["exportedFileName"])[1]
        dst = os.path.join(out, base + ext)
        if os.path.exists(src):
            os.replace(src, dst)
        if base.startswith(("invite-code","missing-elements","location-permission")):
            print("== %s ==" % base); print(open(dst).read())
PY
# 測試會重裝 App 並在結束時關掉它；背景定位要 App 跑起來才會恢復，所以測完一律重新啟動
xcrun devicectl device process launch --device "$UDID" com.gomiigo.HavenCircleApp >/dev/null 2>&1 \
  || xcrun simctl launch "$UDID" com.gomiigo.HavenCircleApp >/dev/null 2>&1 || true
echo "截圖目錄：${OUT}（$(ls "$OUT" | grep -c '\.png') 張 png）"
exit $RC

#!/bin/bash
# 用法：tools/uitest/run_audit.sh <UDID> <裝置標籤:iphone16|ipad> <測試名> <流程資料夾名> [--clean]
# 跑單一 UX 稽核測試，把截圖整理到 build/ux-audit/<裝置>/<流程>/NN-畫面名.png，
# 並把盤點行寫到 build/ux-audit/<裝置>/<流程>/inventory.txt（之後由 build_inventory.py 合併成 inventory.md）。
# 獨立 derivedData（build/dd-uitest），不影響平常的建置。
set -u
UDID="${1:?UDID}"; DEV="${2:?裝置標籤}"; TEST="${3:?測試名}"; FLOW="${4:?流程名}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT" || exit 1
STAMP="$(date +%Y%m%d-%H%M%S)"
RAW="$ROOT/build/ux-audit/_raw/${DEV}-${TEST}-${STAMP}"
RESULT="$RAW/result.xcresult"
DEST="$ROOT/build/ux-audit/$DEV/$FLOW"
mkdir -p "$RAW"; rm -rf "$DEST"; mkdir -p "$DEST"
xcodebuild test -project HavenCircle.xcodeproj -scheme HavenCircle \
  -destination "id=$UDID" -allowProvisioningUpdates -derivedDataPath "$ROOT/build/dd-uitest" \
  -only-testing:"HavenCircleUITests/HavenCircleUITests/$TEST" \
  -resultBundlePath "$RESULT" 2>&1 | tail -n 15
RC=${PIPESTATUS[0]}
xcrun xcresulttool export attachments --path "$RESULT" --output-path "$RAW/att" >/dev/null 2>&1
/usr/bin/python3 - "$RAW/att" "$DEST" <<'PY'
import json, os, sys, shutil
att, dest = sys.argv[1], sys.argv[2]
mf = os.path.join(att, "manifest.json")
if not os.path.exists(mf): print("沒有 manifest.json"); sys.exit()
n = 0
for test in json.load(open(mf)):
    for a in test.get("attachments", []):
        src = os.path.join(att, a["exportedFileName"])
        name = a.get("suggestedHumanReadableName", a["exportedFileName"])
        base = name.split("_")[0]
        ext = os.path.splitext(a["exportedFileName"])[1]
        if not (base[:1].isdigit() or base in ("inventory", "onboarding-summary", "missing-elements")):
            continue  # 略過 XCTest 自動附件（UI Snapshot / Synthesized Event 等）
        if ext == ".png":
            shutil.copy(src, os.path.join(dest, base + ".png")); n += 1
        else:
            shutil.copy(src, os.path.join(dest, base + ".txt"))
print("已整理 %d 張 png -> %s" % (n, dest))
PY
exit $RC

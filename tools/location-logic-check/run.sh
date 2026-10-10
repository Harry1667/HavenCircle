#!/bin/zsh
# 位置追蹤純函式自我檢查（靜止偵測、上傳節流、24 小時軌跡、圍欄挑選、狀態文字、橫幅篩選、請求冷卻）
# 用法：tools/location-logic-check/run.sh   （不需要模擬器、不碰 Firebase）
set -e
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
swiftc -o "$out/run" tools/location-logic-check/main.swift \
  HavenCircle/Models/LocationTracking.swift HavenCircle/Models/LiveLocationPresence.swift
TZ=Asia/Taipei "$out/run"

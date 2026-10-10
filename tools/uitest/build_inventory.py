#!/usr/bin/env python3
"""合併 build/ux-audit/<裝置>/<流程>/inventory.txt → build/ux-audit/inventory.md"""
import os, glob
root = os.path.join(os.path.dirname(__file__), "..", "..", "build", "ux-audit")
root = os.path.abspath(root)
out = ["# HavenCircle UX 稽核盤點", "",
       "點擊數＝從該流程起點（啟動 App）到達此畫面的累計點擊（含系統彈窗、滑動不算）。`--` 列是未成功到達/略過的備註。", ""]
rows = 0
for dev in sorted(d for d in os.listdir(root) if not d.startswith("_") and os.path.isdir(os.path.join(root, d))):
    out += ["## 裝置：" + dev, ""]
    for flow in sorted(os.listdir(os.path.join(root, dev))):
        inv = os.path.join(root, dev, flow, "inventory.txt")
        pngs = len(glob.glob(os.path.join(root, dev, flow, "*.png")))
        out += ["### %s（%d 張）" % (flow, pngs), "",
                "| 流程 | 畫面 | 截圖 | 點擊數 | 備註 | 可點元素 |", "|---|---|---|---|---|---|"]
        if os.path.exists(inv):
            for line in open(inv, encoding="utf-8").read().splitlines():
                p = line.split("|")
                if len(p) < 6: continue
                f, nn, name, clicks, note, items = p[0], p[1], p[2], p[3], p[4], "|".join(p[5:])
                shot = "%s/%s/%s-%s.png" % (dev, flow, nn, name) if nn != "--" else "—"
                items = items.replace("|", "／").replace(" ¦ ", "<br>")
                out.append("| %s | %s | %s | %s | %s | %s |" % (f or "—", name, shot, clicks, note, items))
                rows += 1
        else:
            out.append("| %s | （無 inventory.txt）| | | | |" % flow)
        out.append("")
open(os.path.join(root, "inventory.md"), "w", encoding="utf-8").write("\n".join(out))
print("inventory.md 寫入完成，%d 列" % rows)

#!/usr/bin/env python3
"""把鄉鎮區 GeoJSON 合併成縣市外框 GeoJSON（地圖金色高光用）。
用法：python3 tools/geo/build_counties.py
需要 shapely。輸出：HavenCircle/Resources/TaiwanCounties.json
"""
import json
from pathlib import Path
from collections import defaultdict
from shapely.geometry import shape, Polygon, MultiPolygon, mapping
from shapely.ops import unary_union

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "HavenCircle/Resources/TaiwanDistricts.json"
DST = ROOT / "HavenCircle/Resources/TaiwanCounties.json"

GAP = 0.0008        # 先外擴再收回，消除簡化造成的縫隙
SIMPLIFY = 0.002    # 約 200m
MIN_AREA = 0.0002   # 小於此面積（平方度，約 2 平方公里）的碎島捨棄

by_county = defaultdict(list)
for f in json.loads(SRC.read_text())["features"]:
    county = f["properties"]["county"].replace("臺", "台")
    by_county[county].append(shape(f["geometry"]).buffer(0))

features = []
for county, geoms in sorted(by_county.items()):
    merged = unary_union([g.buffer(GAP) for g in geoms]).buffer(-GAP)
    polys = list(merged.geoms) if isinstance(merged, MultiPolygon) else [merged]
    outers = []
    for p in polys:
        if p.area < MIN_AREA:
            continue
        s = Polygon(p.exterior).simplify(SIMPLIFY, preserve_topology=True)
        if not s.is_empty and s.geom_type == "Polygon":
            outers.append(s)
    if not outers:  # 全是小島時至少留最大塊
        outers = [Polygon(max(polys, key=lambda p: p.area).exterior)]
    geom = outers[0] if len(outers) == 1 else MultiPolygon(outers)
    m = mapping(geom)
    m = json.loads(json.dumps(m))
    def rnd(c):
        return [round(c[0], 4), round(c[1], 4)] if isinstance(c[0], float) else [rnd(x) for x in c]
    m["coordinates"] = rnd(m["coordinates"])
    features.append({"type": "Feature", "properties": {"county": county}, "geometry": m})

DST.write_text(json.dumps({"type": "FeatureCollection", "features": features},
                          ensure_ascii=False, separators=(",", ":")))
print(f"{len(features)} 縣市, {DST.stat().st_size/1024:.1f} KB")

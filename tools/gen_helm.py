"""
Generates allrecipes' HELM data (harvesting, excavation, logging, mining) from a Phoenix
(LandSandBoat fork) checkout:

    data/helm.lua  each kind's tool and rules, and for each zone its success and break rates, its
                   drops with their weights and the retail-captured positions of its points
                   (scripts/globals/hobbies/helm/data.lua)

    python tools/gen_helm.py [--phoenix C:\\code\\Phoenix]

How the server uses it (scripts/globals/hobbies/helm/logic.lua): an attempt finds something
obtainRate% of the time, then picks a drop by weight; separately the tool breaks breakRate% of
the time. Gear only lowers the break chance: each point of the kind's NQ mod (Field gear)
multiplies it by 0.893 and each point of its HQ mod (Worker gear) by 0.843. Excavation has no gear.

Phoenix's era module (modules/era/lua/globals/helm/helm_adjustments.lua) takes out drops added
after its era (WotG and Abyssea); they're taken out here too. Zones from Abyssea on are left out.
"""

import argparse
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DATA = HERE.parent / "data"

KINDS = ["HARVESTING", "EXCAVATION", "LOGGING", "MINING"]
# The gear mods (sql/item_mods.sql, docs/mods_by_id.txt): NQ (Field gear) and HQ (Worker gear).
GEAR_MODS = {"HARVESTING": (513, 1212), "LOGGING": (514, 1213), "MINING": (515, 300), "EXCAVATION": None}
# Gear with those mods from after the era (Seekers of Adoulin): Field Torque and Field Rope.
LATER_GEAR = {10926, 11769}
WOTG_ZONES = set(range(80, 100)) | {136, 137, 138, 155, 156, 164, 171, 175, 182}
ABYSSEA = {15, 45, 132, 215, 216, 217, 218, 253, 254, 255}
# Points that only show in some weather (scripts/zones/*/Zone.lua onZoneWeatherChange).
WEATHER = {("HARVESTING", "YHOATOR_JUNGLE"): "rain", ("HARVESTING", "YUHTUNGA_JUNGLE"): "rain"}


def zone_ids(phoenix):
    """xi.zone's names (zone_settings' names, upper case, runs of other characters as _)."""
    ids = {}
    for m in re.finditer(r"^INSERT INTO `zone_settings` VALUES \((\d+),'[^']*',\d+,'([^']*)'", (phoenix / "sql" / "zone_settings.sql").read_text(encoding="utf-8"), re.M):
        name = re.sub(r"[^A-Z0-9]+", "_", m.group(2).upper()).strip("_")
        ids[name] = int(m.group(1))
    return ids


def item_ids(phoenix):
    text = (phoenix / "scripts" / "enum" / "item.lua").read_text(encoding="utf-8")
    return {m.group(1): int(m.group(2)) for m in re.finditer(r"^\s*([A-Z0-9_]+)\s*=\s*(\d+),", text, re.M)}


def block(text, start):
    """The text of the { ... } that opens at or after start (comments already gone), and where
    it ends."""
    i = text.index("{", start)
    depth = 0
    for j in range(i, len(text)):
        c = text[j]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return text[i + 1:j], j + 1
    sys.exit("helm data: unbalanced braces")


def strip_comments(text):
    return re.sub(r"--[^\n]*", "", text)


def gear(phoenix, items):
    """{ kind: [ [item id, nq, hq], ... ] } from sql/item_mods.sql."""
    mods = {}
    for m in re.finditer(r"^INSERT INTO `item_mods` VALUES \((\d+),(\d+),(-?\d+)\)", (phoenix / "sql" / "item_mods.sql").read_text(encoding="utf-8"), re.M):
        mods.setdefault(int(m.group(1)), {})[int(m.group(2))] = int(m.group(3))
    out = {}
    for kind, pair in GEAR_MODS.items():
        rows = []
        if pair:
            for item, ms in sorted(mods.items()):
                if item in LATER_GEAR:
                    continue
                nq, hq = ms.get(pair[0], 0), ms.get(pair[1], 0)
                if nq or hq:
                    rows.append([item, nq, hq])
        out[kind] = rows
    return out


def removals(phoenix, items, zones):
    """{ (kind, zone id): set(item ids) } from the era module."""
    text = strip_comments((phoenix / "modules" / "era" / "lua" / "globals" / "helm" / "helm_adjustments.lua").read_text(encoding="utf-8"))
    body, _ = block(text, text.index("removalsByContent"))
    out = {}
    for km in re.finditer(r"\[xi\.helmType\.([A-Z]+)\]\s*=", body):
        kbody, _ = block(body, km.end())
        for zm in re.finditer(r"\[xi\.zone\.([A-Z0-9_]+)\]\s*=", kbody):
            zbody, _ = block(kbody, zm.end())
            ids = {items[n] for n in re.findall(r"xi\.item\.([A-Z0-9_]+)", zbody)}
            out.setdefault((km.group(1), zones[zm.group(1)]), set()).update(ids)
    if not out:
        sys.exit("helm_adjustments.lua: no removals found; the module changed")
    return out


def lua_num(v):
    return ("%.3f" % v).rstrip("0").rstrip(".") if isinstance(v, float) else str(v)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--phoenix", default=r"C:\code\Phoenix")
    args = ap.parse_args()
    phoenix = Path(args.phoenix)
    zones, items = zone_ids(phoenix), item_ids(phoenix)
    text = strip_comments((phoenix / "scripts" / "globals" / "hobbies" / "helm" / "data.lua").read_text(encoding="utf-8"))
    remove = removals(phoenix, items, zones)
    worn = gear(phoenix, items)

    out = [
        "-- Generated by tools/gen_helm.py from Phoenix's HELM data. Don't edit by hand.",
        "-- [kind] = { tool, relocate %, respawn s, camp multiplier, gear = { { item, nq, hq }, ... },",
        "--            zones = { { zone id, obtain %, break %, min level, weather, tag,",
        "--                        drops = { { weight, item, daily cap or 0, depleting 0/1 }, ... },",
        "--                        points = { { x, y, z }, ... }, depletion max }, ... } }",
        "return {",
    ]
    total_zones = total_points = 0
    for kind in KINDS:
        m = re.search(r"\[xi\.helmType\.%s\]\s*=" % kind, text)
        kbody, _ = block(text, m.end())
        def field(name):
            f = re.search(r"\b%s\s*=\s*([^,\n]+)," % name, kbody)
            return f.group(1).strip()
        tool = items[field("tool").split(".")[-1]]
        zstart = re.search(r"\bzone\s*=", kbody)
        zbody, _ = block(kbody, zstart.end())
        rows = []
        for zm in re.finditer(r"\[xi\.zone\.([A-Z0-9_]+)\]\s*=", zbody):
            name = zm.group(1)
            if name not in zones:
                sys.exit("helm data: no zone called %s" % name)
            zid = zones[name]
            body, end = block(zbody, zm.end())
            if zid in ABYSSEA or zid >= 256:
                continue
            def num(key, default=None):
                f = re.search(r"\b%s\s*=\s*([\d.]+)" % key, body)
                return float(f.group(1)) if f else default
            caps = {}
            cm = re.search(r"\bdailyCap\s*=", body)
            if cm:
                cbody, _ = block(body, cm.end())
                caps = {items[n]: int(v) for n, v in re.findall(r"\[xi\.item\.([A-Z0-9_]+)\]\s*=\s*(\d+)", cbody)}
            pool, dmax = set(), 0
            dm = re.search(r"\bdepletion\s*=", body)
            if dm:
                dbody, _ = block(body, dm.end())
                dmax = int(re.search(r"\bmax\s*=\s*(\d+)", dbody).group(1))
                pool = {items[n] for n in re.findall(r"xi\.item\.([A-Z0-9_]+)", dbody)}
            drops_m = re.search(r"\bdrops\s*=", body)
            dbody, _ = block(body, drops_m.end())
            gone = remove.get((kind, zid), set())
            drops = []
            for w, n in re.findall(r"\{\s*(\d+)\s*,\s*xi\.item\.([A-Z0-9_]+)\s*\}", dbody):
                if n not in items:
                    sys.exit("helm data: no item called %s" % n)
                iid = items[n]
                if iid not in gone:
                    drops.append((int(w), iid, caps.get(iid, 0), 1 if iid in pool else 0))
            pm = re.search(r"\bpoints\s*=", body)
            pbody, _ = block(body, pm.end())
            points = [tuple(float(v) for v in p) for p in re.findall(r"\{\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*\}", pbody)]
            tag = "WOTG" if zid in WOTG_ZONES else "COP" if 1 <= zid <= 44 else "TOAU" if 46 <= zid <= 79 else ""
            rows.append((zid, num("obtainRate"), num("breakRate"), int(num("minLevel", 0)), WEATHER.get((kind, name), ""), tag, drops, points, dmax))
        out.append("    [%d] = {" % (KINDS.index(kind) + 1))
        out.append("        name = %s, tool = %d, relocate = %s, respawn = %s, camp = %s," % (
            '"%s"' % kind.title(), tool, field("relocateRate"), field("respawnTime"), field("campMultiplier")))
        out.append("        gear = { %s }," % ", ".join("{ %d, %d, %d }" % tuple(g) for g in worn[kind]))
        out.append("        zones = {")
        for zid, ob, br, lvl, weather, tag, drops, points, dmax in sorted(rows):
            out.append('            { %d, %s, %s, %d, "%s", "%s",' % (zid, lua_num(ob), lua_num(br), lvl, weather, tag))
            out.append("              { %s }," % ", ".join("{ %d, %d, %d, %d }" % d for d in drops))
            out.append("              { %s }, %d }," % (", ".join("{ %s, %s, %s }" % tuple(lua_num(v) for v in p) for p in points), dmax))
            total_points += len(points)
        out.append("        },")
        out.append("    },")
        total_zones += len(rows)
        print("%s: %d zones, gear %s" % (kind.title(), len(rows), [g[0] for g in worn[kind]]))
    out.append("}")
    (DATA / "helm.lua").write_text("\n".join(out) + "\n", encoding="utf-8")
    print("data/helm.lua: %d zones, %d points" % (total_zones, total_points))


if __name__ == "__main__":
    main()

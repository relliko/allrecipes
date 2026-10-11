"""
Generates allrecipes' fishing data from a Phoenix (LandSandBoat fork) checkout:

    data/fish.lua  every fish and item that can be fished up, with its skill level, where it's
                   caught (sql/fishing_catch.sql, fishing_group.sql, fishing_area.sql) and the
                   bait and lures that work on it (fishing_bait_affinity.sql); and the era's
                   rods (fishing_rod.sql, with Phoenix's module changes to their ranks)

    python tools/gen_fish.py [--phoenix C:\\code\\Phoenix] [--report]

A fish's skill_level is the level fishing it stops giving skill-ups (FishingSkillup in
src/map/utils/fishingutils.cpp: only fish over your level give them, up to 50 over). Disabled
fish, and fish no area of an era zone has, are left out. Zones 1-44 are tagged CoP and 46-79
ToAU; a fish found anywhere else is untagged.
"""

import argparse
import csv
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DATA = HERE.parent / "data"

FISH_COLUMNS = 29
ABYSSEA = {15, 45, 132, 215, 216, 217, 218, 253, 254, 255}
# Rods left out: the GM's Judge's Rod, the goldfish-scooping basket, and the Maze Monger rod and
# the +1 Ebisu and Lu Shang's, which came after the era.
LATER_RODS = {17012, 17013, 19319, 19320, 19321}
# Fishing gear left out as after the era: Fisher's Torque and the Fisherman's Smock.
LATER_GEAR = {10925, 11337}
MOD_ROD = re.compile(r"^UPDATE `?fishing_rod`? SET `?(max_rank|min_rank)`? = (\d+) where `?name`? = '((?:[^'\\]|\\.)*)';", re.I)


def rows_of(path, table, columns):
    prefix = "INSERT INTO `%s` VALUES (" % table
    rows, inserts = [], 0
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.startswith(prefix):
            continue
        inserts += 1
        body = line.strip()[len(prefix):]
        body = body[:body.rindex(");")]
        rows.append(next(csv.reader([body], quotechar="'", escapechar="\\", skipinitialspace=True)))
    if len(rows) != inserts or any(len(r) != columns for r in rows):
        sys.exit("%s: parsed %d of %d rows; the table layout changed" % (path.name, len(rows), inserts))
    return rows


def era_tag(zone):
    if 1 <= zone <= 44:
        return "COP"
    if 46 <= zone <= 79:
        return "TOAU"
    return ""


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def read_rods(phoenix):
    """The era's rods from sql/fishing_rod.sql, with Phoenix's module changes to their ranks."""
    rods = {}
    for r in rows_of(phoenix / "sql" / "fishing_rod.sql", "fishing_rod", 22):
        n = [int(x) if x.isdigit() else x for x in r]
        if n[0] in LATER_RODS:
            continue
        rods[r[1]] = {"id": n[0], "name": r[1], "size": n[3], "min": n[5], "max": n[6],
                      "breakable": n[17], "legendary": n[20], "rating": n[21]}
    for path in sorted((phoenix / "modules").rglob("*.sql")):
        for line in path.read_text(encoding="utf-8-sig").splitlines():
            if not re.match(r"\s*UPDATE `?fishing_rod`?", line, re.I):
                continue
            m = MOD_ROD.match(line.strip())
            if m is None:
                sys.exit("%s: a change to the rods this script doesn't understand:\n  %s" % (path, line))
            name = m.group(3).replace("\\'", "'")
            if name in rods:
                rods[name]["min" if m.group(1).lower() == "min_rank" else "max"] = int(m.group(2))
    return sorted(rods.values(), key=lambda r: (-r["rating"], r["name"]))


def read_gear(phoenix):
    """Gear that adds fishing skill (mod 127, FISH): (item id, skill, slot bits), era only."""
    skill = {}
    for m in re.finditer(r"^INSERT INTO `item_mods` VALUES \((\d+),127,(-?\d+)\)", (phoenix / "sql" / "item_mods.sql").read_text(encoding="utf-8"), re.M):
        if int(m.group(1)) not in LATER_GEAR:
            skill[int(m.group(1))] = int(m.group(2))
    slots = {}
    for m in re.finditer(r"^INSERT INTO `item_equipment` VALUES \((\d+),'[^']*',\d+,\d+,\d+,\d+,\d+,\d+,(\d+),", (phoenix / "sql" / "item_equipment.sql").read_text(encoding="utf-8"), re.M):
        slots[int(m.group(1))] = int(m.group(2))
    return sorted((i, v, slots.get(i, 0)) for i, v in skill.items() if v > 0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--phoenix", default=r"C:\code\Phoenix")
    ap.add_argument("--report", action="store_true")
    args = ap.parse_args()
    sql = Path(args.phoenix) / "sql"

    fish = {}
    for r in rows_of(sql / "fishing_fish.sql", "fishing_fish", FISH_COLUMNS):
        n = [int(x) if x.isdigit() else x for x in r]
        if n[28]:  # disabled
            continue
        fish[n[0]] = {
            "id": n[0], "name": r[1], "skill": n[2], "ranking": n[8], "size": n[9], "legendary": n[18], "item": n[20],
            "rarity": n[22], "keyitem": n[23], "quest": n[26], "contest": n[27],
            "where": set(), "bait": {},
        }

    zones = {int(r[0]): r[1].replace("_", " ") for r in rows_of(sql / "fishing_zone.sql", "fishing_zone", 3)}
    areas = {(int(r[0]), int(r[1])): r[2] for r in rows_of(sql / "fishing_area.sql", "fishing_area", 10)}
    groups = {}
    for r in rows_of(sql / "fishing_group.sql", "fishing_group", 5):
        groups.setdefault(int(r[0]), []).append(int(r[1]))
    for r in rows_of(sql / "fishing_catch.sql", "fishing_catch", 3):
        zone, area, group = int(r[0]), int(r[1]), int(r[2])
        if zone in ABYSSEA or zone >= 256:
            continue
        for fid in groups.get(group, []):
            if fid in fish:
                fish[fid]["where"].add((zone, areas.get((zone, area), "")))
    for r in rows_of(sql / "fishing_bait_affinity.sql", "fishing_bait_affinity", 3):
        fid = int(r[1])
        if fid in fish:
            fish[fid]["bait"][int(r[0])] = int(r[2])

    rods = read_rods(Path(args.phoenix))

    kept = [f for f in fish.values() if f["where"]]
    kept.sort(key=lambda f: (f["skill"], f["name"]))
    used_zones = sorted({z for f in kept for z, _ in f["where"]})

    out = [
        "-- Generated by tools/gen_fish.py from Phoenix's fishing tables. Don't edit by hand.",
        "-- fish: { item id, name, skill level, large (0/1), item not fish (0/1), legendary (0/1),",
        "--         key item needed (0 none), quest only (0/1), tag, { { zone, area }, ... },",
        "--         { bait item id, power (1-3), ... }, ranking }",
        "-- rods: { item id, name, large (0/1), min rank, max rank, breakable (0/1), legendary (0/1), rating }",
        "return {",
        "    rods = {",
    ]
    for r in rods:
        out.append("        { %d, %s, %d, %d, %d, %d, %d, %d }," % (
            r["id"], lua_str(r["name"]), r["size"], r["min"], r["max"], r["breakable"], r["legendary"], r["rating"]))
    out += ["    },", "    -- gear: { item id, fishing skill, equipment slot bits }", "    gear = {"]
    for g in read_gear(Path(args.phoenix)):
        out.append("        { %d, %d, %d }," % g)
    out += ["    },", "    zones = {"]
    for z in used_zones:
        out.append("        [%d] = %s," % (z, lua_str(zones.get(z, "Zone %d" % z))))
    out.append("    },")
    out.append("    fish = {")
    for f in kept:
        where = sorted(f["where"])
        tags = {era_tag(z) for z, _ in where}
        tag = "" if "" in tags else ("COP" if "COP" in tags else "TOAU")
        bait = sorted(f["bait"].items(), key=lambda kv: (-kv[1], kv[0]))
        out.append("        { %d, %s, %d, %d, %d, %d, %d, %d, %s, { %s }, { %s }, %d }," % (
            f["id"], lua_str(f["name"]), f["skill"], 1 if f["size"] else 0, 1 if f["item"] else 0,
            1 if f["legendary"] else 0, f["keyitem"], 1 if f["quest"] else 0, lua_str(tag),
            ", ".join("{ %d, %s }" % (z, lua_str(a)) for z, a in where),
            ", ".join("%d, %d" % kv for kv in bait), f["ranking"]))
    out.append("    },")
    out.append("}")
    (DATA / "fish.lua").write_text("\n".join(out) + "\n", encoding="utf-8")

    print("data/fish.lua: %d of %d fish (%d zones)" % (len(kept), len(fish), len(used_zones)))
    if args.report:
        for f in fish.values():
            if not f["where"]:
                print("  left out, nowhere to catch it: %s (%d)" % (f["name"], f["skill"]))


if __name__ == "__main__":
    main()

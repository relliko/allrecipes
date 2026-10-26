"""
Generates allrecipes' treasure chest and coffer data from a Phoenix (LandSandBoat fork) checkout:

    data/treasure.lua  for each zone with a chest or coffer: its level, key, map key item, what it
                       gives (gil or items, by weight out of 1000), the quest key items it gives
                       instead and the spots it moves between (scripts/globals/treasure.lua), plus
                       the odds of opening one with thief's tools, living keys and skeleton keys

    python tools/gen_treasure.py [--phoenix C:\\code\\Phoenix]

How the server uses it (xi.treasure.onTrade): the zone's key always opens it; a THF (main job)
can try thief's tools, a living key or a skeleton key instead, with odds that drop 5% a level
the chest is over you. Opened, it gives the zone's map key item first if you don't have it, else
gil (weight of xi.item.NONE) or an item, then hides for 180 seconds and comes back at one of its
spots. After a regular opening a chest is an illusion for 15-60 minutes.
"""

import argparse
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DATA = HERE.parent / "data"

WOTG_ZONES = set(range(80, 100)) | {136, 137, 138, 155, 156, 164, 171, 175, 182}
KINDS = {"CHEST": 1, "COFFER": 2}
KEYS = ["ZONE_KEY", "THIEF_TOOLS", "LIVING_KEY", "SKELETON_KEY"]
# The quests the chests' own scripts (scripts/zones/*/npcs/Treasure_C*.lua) hand a key item out
# for: by the quest named in the condition, else by the character variable it checks.
QUEST_VARS = {"UnderOathCS": "Under Oath", "trueWillCS": "True Will", "KnightStalker_Progress": "Knight Stalker"}
SMALL = {"of", "the", "in", "a", "an", "to", "and", "for", "on", "at"}


def zone_ids(phoenix):
    """xi.zone's names (zone_settings' names, upper case, runs of other characters as _)."""
    ids = {}
    for m in re.finditer(r"^INSERT INTO `zone_settings` VALUES \((\d+),'[^']*',\d+,'([^']*)'", (phoenix / "sql" / "zone_settings.sql").read_text(encoding="utf-8"), re.M):
        name = re.sub(r"[^A-Z0-9]+", "_", m.group(2).upper()).strip("_")
        ids[name] = int(m.group(1))
    return ids


def enum_ids(path):
    text = path.read_text(encoding="utf-8")
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
    sys.exit("treasure.lua: unbalanced braces")


def strip_comments(text):
    return re.sub(r"--[^\n]*", "", text)


def table(text, name):
    m = re.search(r"^local %s\s*=" % name, text, re.M)
    if not m:
        sys.exit("treasure.lua: no table %s; the script changed" % name)
    return block(text, m.end())[0]


def by_zone(body, zones):
    """[(zone id, zone name, body)] for each [xi.zone.X] = ... in a table's body."""
    out = []
    for zm in re.finditer(r"\[xi\.zone\.([A-Z0-9_]+)\s*\]\s*=", body):
        name = zm.group(1)
        if name not in zones:
            sys.exit("treasure.lua: no zone called %s" % name)
        out.append((zones[name], name, block(body, zm.end())[0]))
    return out


def pair(body, ids, prefix):
    """{ a, b } of xi.<prefix>.NAME or 0."""
    vals = []
    for v in [x.strip() for x in body.split(",") if x.strip()]:
        if v == "0":
            vals.append(0)
        else:
            m = re.fullmatch(r"xi\.%s\.([A-Z0-9_]+)" % prefix, v)
            if not m or m.group(1) not in ids:
                sys.exit("treasure.lua: can't read %s" % v)
            vals.append(ids[m.group(1)])
    if len(vals) != 2:
        sys.exit("treasure.lua: expected a pair, got %s" % body)
    return vals


def title(name):
    words = name.lower().split("_")
    return " ".join(w if (i > 0 and w in SMALL) else w.capitalize() for i, w in enumerate(words))


def quests(phoenix, zones, keyitems):
    """{ (zone id, kind): [ (key item, quest name), ... ] } from the chests' own scripts."""
    out = {}
    for path in sorted((phoenix / "scripts" / "zones").glob("*/npcs/Treasure_C*.lua")):
        kind = 1 if path.stem == "Treasure_Chest" else 2
        text = strip_comments(path.read_text(encoding="utf-8"))
        zm = re.search(r"!zone (\d+)", path.read_text(encoding="utf-8"))
        if not zm:
            continue
        zid = int(zm.group(1))
        # Each `if/elseif <condition> then xi.treasure.onTrade(player, npc, trade, 2, KI)`.
        for m in re.finditer(r"(?:if|elseif)(.*?)then\s*xi\.treasure\.onTrade\(player, npc, trade, ([12]), xi\.(keyItem|item)\.([A-Z0-9_]+)\)", text, re.S):
            cond, how, space, name = m.groups()
            if how != "2" or space != "keyItem":
                sys.exit("%s: a quest item from a chest, which allrecipes doesn't show yet" % path)
            q = re.search(r"xi\.quest\.id\.[a-z]+\.([A-Z0-9_]+)", cond)
            if q:
                quest = title(q.group(1))
            else:
                v = re.search(r"getCharVar\('([^']+)'\)", cond)
                if not v or v.group(1) not in QUEST_VARS:
                    sys.exit("%s: can't tell the quest for %s" % (path, name))
                quest = QUEST_VARS[v.group(1)]
            out.setdefault((zid, kind), []).append((keyitems[name], quest))
    return out


def illusion(phoenix):
    text = (phoenix / "settings" / "default" / "main.lua").read_text(encoding="utf-8")
    def num(name):
        return int(re.search(r"\b%s\s*=\s*(\d+)" % name, text).group(1))
    return [num("CHEST_MIN_ILLUSION_TIME"), num("CHEST_MAX_ILLUSION_TIME"), num("COFFER_MIN_ILLUSION_TIME"), num("COFFER_MAX_ILLUSION_TIME")]


def key_item_ids(phoenix):
    """xi.keyItem's names (data/enums/key_item.yaml, upper case)."""
    text = (phoenix / "data" / "enums" / "key_item.yaml").read_text(encoding="utf-8")
    return {m.group(1).upper(): int(m.group(2)) for m in re.finditer(r"^\s+([a-z0-9_]+):\s+(\d+)\s*$", text, re.M)}


def lua_num(v):
    return ("%.3f" % v).rstrip("0").rstrip(".") if isinstance(v, float) else str(v)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--phoenix", default=r"C:\code\Phoenix")
    args = ap.parse_args()
    phoenix = Path(args.phoenix)
    zones = zone_ids(phoenix)
    items = enum_ids(phoenix / "scripts" / "enum" / "item.lua")
    keyitems = key_item_ids(phoenix)
    text = strip_comments((phoenix / "scripts" / "globals" / "treasure.lua").read_text(encoding="utf-8"))

    thief = {}
    for km in re.finditer(r"\[keyType\.([A-Z_]+)\s*\]\s*=", table(text, "thiefKeyInfo")):
        body = block(table(text, "thiefKeyInfo"), km.end())[0]
        rows = [[int(x) for x in re.findall(r"\d+", r)] for r in re.findall(r"\{([^{}]*)\}", body)]
        if len(rows) != 2 or any(len(r) != 4 or sum(r) != 100 for r in rows):
            sys.exit("treasure.lua: thiefKeyInfo %s isn't { { 4 } x2 } adding to 100" % km.group(1))
        thief[km.group(1)] = rows
    respawn = {m.group(1): int(m.group(2)) for m in re.finditer(r"([A-Z]+)\s*=\s*(\d+)", table(text, "respawnType"))}

    keys = {z: pair(b, items, "item") for z, _, b in by_zone(table(text, "keyTable"), zones)}
    maps = {z: pair(b, keyitems, "keyItem") for z, _, b in by_zone(table(text, "mapTable"), zones)}
    levels = {z: [int(x) for x in re.findall(r"\d+", b)] for z, _, b in by_zone(table(text, "levelTable"), zones)}
    spots, loot = {}, {}
    for z, _, body in by_zone(table(text, "posTable"), zones):
        for km in re.finditer(r"\[treasureType\.([A-Z]+)\]\s*=", body):
            kbody = block(body, km.end())[0]
            spots[(z, KINDS[km.group(1)])] = [tuple(float(v) for v in p) for p in re.findall(r"\{\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*,\s*-?\d+\s*\}", kbody)]
    for z, _, body in by_zone(table(text, "lootTable"), zones):
        for km in re.finditer(r"\[treasureType\.([A-Z]+)\]\s*=", body):
            kbody = block(body, km.end())[0]
            rows = []
            for n, w in re.findall(r"\{\s*xi\.item\.([A-Z0-9_]+)\s*,\s*(\d+)\s*\}", kbody):
                if n not in items:
                    sys.exit("treasure.lua: no item called %s" % n)
                rows.append((items[n], int(w)))
            if sum(w for _, w in rows) != 1000:
                sys.exit("treasure.lua: %s weights add to %d, not 1000" % (z, sum(w for _, w in rows)))
            loot[(z, KINDS[km.group(1)])] = rows
    quest = quests(phoenix, zones, keyitems)

    out = [
        "-- Generated by tools/gen_treasure.py from Phoenix's scripts/globals/treasure.lua. Don't edit by hand.",
        "-- thief[key] = { chest { success, fail, trap, mimic }, coffer { ... } } in %, for keys zone key,",
        "--   thief's tools, living key, skeleton key; keys = their item ids (the zone key's is the box's own);",
        "-- illusion = { chest min, max, coffer min, max } seconds; respawn = { after opening, after a mimic };",
        "-- boxes = { { zone id, kind (1 chest, 2 coffer), level, key item, map key item or 0, tag,",
        "--             loot = { { item (0 gil), weight of 1000 }, ... }, quests = { { key item, quest }, ... },",
        "--             spots = { { x, y, z }, ... } }, ... }",
        "return {",
        "    thief = { %s }," % ", ".join("{ { %s }, { %s } }" % (", ".join(map(str, thief[k][0])), ", ".join(map(str, thief[k][1]))) for k in KEYS),
        "    keys = { 0, %d, %d, %d }," % (items["SET_OF_THIEFS_TOOLS"], items["LIVING_KEY"], items["SKELETON_KEY"]),
        "    illusion = { %s }," % ", ".join(map(str, illusion(phoenix))),
        "    respawn = { %d, %d }," % (respawn["REGULAR"], respawn["IMMEDIATE"]),
        "    boxes = {",
    ]
    count = 0
    for (z, kind) in sorted(loot):
        key, level, mapki = keys[z][kind - 1], levels[z][kind - 1], maps[z][kind - 1]
        if key == 0 or level == 0 or (z, kind) not in spots:
            sys.exit("treasure.lua: zone %d kind %d has loot but no key, level or spots" % (z, kind))
        tag = "WOTG" if z in WOTG_ZONES else "COP" if 1 <= z <= 44 else "TOAU" if 46 <= z <= 79 else ""
        out.append('        { %d, %d, %d, %d, %d, "%s",' % (z, kind, level, key, mapki, tag))
        out.append("          { %s }," % ", ".join("{ %d, %d }" % (0 if i == items["NONE"] else i, w) for i, w in loot[(z, kind)]))
        out.append("          { %s }," % ", ".join('{ %d, "%s" }' % q for q in quest.get((z, kind), [])))
        out.append("          { %s } }," % ", ".join("{ %s, %s, %s }" % tuple(lua_num(v) for v in p) for p in spots[(z, kind)]))
        count += 1
    out.append("    },")
    out.append("}")
    (DATA / "treasure.lua").write_text("\n".join(out) + "\n", encoding="utf-8", newline="\n")
    print("data/treasure.lua: %d boxes (%d chests, %d coffers), %d spots, %d quest key items" % (
        count, sum(1 for k in loot if k[1] == 1), sum(1 for k in loot if k[1] == 2), sum(len(spots[k]) for k in loot),
        sum(len(v) for v in quest.values())))


if __name__ == "__main__":
    main()

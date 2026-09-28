"""
Generates allrecipes' data from a Phoenix (LandSandBoat fork) checkout:

    data/recipes.lua  the era recipes from sql/synth_recipes.sql
    data/npc.lua      what an NPC shop pays for each item in them (sql/item_basic.sql, BaseSell)
    data/stacks.lua   how many of an item make a stack, for every item that stacks
    data/loss.lua     materials that break more or less often than half the time
                      (materialLossRates in src/map/utils/synthutils.cpp)

Phoenix changes the item table in its own module (modules/*/sql): stack sizes (ores, logs and
the like don't stack), sell prices (the pre-RMT reverts) and flags. Those changes are applied
before anything is written, and the script stops if a module changes the table in a way it
doesn't understand.

    python tools/gen_recipes.py [--phoenix C:\\code\\Phoenix] [--report]

Only recipes from the original game and the RoZ, CoP, ToAU and WotG expansions are kept (the
content_tag column); Abyssea and everything after it are left out. Rows asking for skill 255 in
a craft can never be synthesized (the server cancels anything more than 15 levels over you) and
are left out too. The server looks recipes up by crystal and ingredients, and when two rows share
them the last one loaded wins, so the rows it can never reach are dropped the same way.
"""

import argparse
import csv
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DATA = HERE.parent / "data"

ERA_TAGS = {"NULL": "", "ROTZ": "ROTZ", "COP": "COP", "TOAU": "TOAU", "WOTG": "WOTG"}
LATER_TAGS = {"ABYSSEA", "SOA", "ROV", "TVR"}
COLUMNS = 31  # ID .. content_tag

RECIPE_PREFIX = "INSERT INTO `synth_recipes` VALUES ("
ITEM_PREFIX = "INSERT INTO `item_basic` VALUES ("
LOSS_ROW = re.compile(r"\{\s*(\d+)\s*,\s*(\d+)\s*\}")

# The item table changes a module can make, one item at a time.
MOD_STACK = re.compile(r"^UPDATE `?item_basic`? SET `?stackSize`? = (\d+) WHERE `?itemid`? = (\d+);", re.I)
MOD_SELL = re.compile(r"^UPDATE `?item_basic`? SET `?baseSell`? = (\d+) WHERE `?itemid`? = (\d+);", re.I)
MOD_FLAGS = re.compile(r"^UPDATE `?item_basic`? SET `?flags`? = `?flags`? ([|&]) (.+?) WHERE `?itemid`? = (\d+);", re.I)
MOD_OTHER = re.compile(r"^UPDATE `?item_basic`?", re.I)


def rows_of(path, prefix):
    """The value lists of every INSERT row in a dump, and how many INSERTs there were."""
    rows, inserts = [], 0
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.startswith(prefix):
            continue
        inserts += 1
        body = line.strip()[len(prefix):]
        body = body[:body.rindex(");")]
        rows.append(next(csv.reader([body], quotechar="'", escapechar="\\", skipinitialspace=True)))
    return rows, inserts


def read_recipes(phoenix):
    rows, inserts = rows_of(phoenix / "sql" / "synth_recipes.sql", RECIPE_PREFIX)
    if len(rows) != inserts or any(len(r) != COLUMNS for r in rows):
        sys.exit("synth_recipes.sql: parsed %d of %d rows; the table layout changed" % (len(rows), inserts))
    recipes = []
    for r in rows:
        n = [int(x) if x.lstrip("-").isdigit() else x for x in r]
        recipes.append({
            "id": n[0], "desynth": n[1], "keyitem": n[2], "skills": n[3:11], "crystal": n[11],
            "ingredients": [x for x in n[13:21] if x != 0],
            "results": [n[21], n[25], n[22], n[26], n[23], n[27], n[24], n[28]],
            "name": r[29], "tag": r[30],
        })
    return recipes


def read_items(phoenix):
    """[item id] = [sell, nosale, stack] from sql/item_basic.sql."""
    rows, inserts = rows_of(phoenix / "sql" / "item_basic.sql", ITEM_PREFIX)
    if len(rows) != inserts or any(len(r) != 10 for r in rows):
        sys.exit("item_basic.sql: parsed %d of %d rows; the table layout changed" % (len(rows), inserts))
    return {int(r[0]): [int(r[9]), "@FLAG_NOSALE" in r[7], int(r[6])] for r in rows}


def apply_modules(phoenix, items):
    """Apply the modules' changes to the item table; returns how many of each kind."""
    counts = {"stack sizes": 0, "sell prices": 0, "no-sale flags": 0}
    for path in sorted((phoenix / "modules").rglob("*.sql")):
        for n, line in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1):
            line = line.strip()
            if not MOD_OTHER.match(line):
                continue
            where = "%s:%d" % (path.relative_to(phoenix), n)
            m = MOD_STACK.match(line)
            if m:
                items.setdefault(int(m.group(2)), [0, False, 1])[2] = int(m.group(1))
                counts["stack sizes"] += 1
                continue
            m = MOD_SELL.match(line)
            if m:
                items.setdefault(int(m.group(2)), [0, False, 1])[0] = int(m.group(1))
                counts["sell prices"] += 1
                continue
            m = MOD_FLAGS.match(line)
            if m:
                op, expr, itemid = m.group(1), m.group(2), int(m.group(3))
                if "@FLAG_NOSALE" in expr:
                    items.setdefault(itemid, [0, False, 1])[1] = op == "|" and "~" not in expr
                    counts["no-sale flags"] += 1
                continue
            if re.search(r"baseSell|stackSize|NOSALE", line, re.I):
                sys.exit("%s: a change to the item table this script doesn't understand:\n  %s" % (where, line))
    return counts


def read_loss(phoenix):
    src = (phoenix / "src" / "map" / "utils" / "synthutils.cpp").read_text(encoding="utf-8")
    m = re.search(r"materialLossRates\s*=\s*\{(.*?)\n\};", src, re.S)
    if m is None:
        sys.exit("synthutils.cpp: materialLossRates not found; the code changed")
    return {int(a): int(b) for a, b in LOSS_ROW.findall(m.group(1))}


def pick(recipes):
    """The recipes the server can use in the era, and a count of what was left out and why."""
    dropped = {"later content": 0, "skill 255": 0, "shadowed": 0, "unknown tag": 0}
    last = {}
    for r in recipes:  # the server loads every row, a later one replacing an earlier with the same key
        last[(r["crystal"], tuple(r["ingredients"]))] = r["id"]
    keep = []
    for r in recipes:
        if last[(r["crystal"], tuple(r["ingredients"]))] != r["id"]:
            dropped["shadowed"] += 1
        elif r["tag"] in LATER_TAGS:
            dropped["later content"] += 1
        elif r["tag"] not in ERA_TAGS:
            dropped["unknown tag"] += 1
        elif 255 in r["skills"]:
            dropped["skill 255"] += 1
        else:
            keep.append(r)
    if dropped["unknown tag"]:
        sys.exit("synth_recipes.sql: a content_tag this script doesn't know; add it to ERA_TAGS or LATER_TAGS")
    return keep, dropped


def collapse(ingredients):
    """[a, a, b] -> [a, 2, b, 1], in the order they're listed."""
    out = []
    for item in ingredients:
        if out and out[-2] == item:
            out[-1] += 1
        else:
            out += [item, 1]
    return out


def lua_list(values):
    return "{" + ",".join(str(v) for v in values) + "}"


def write_recipes(recipes, out):
    lines = [
        "-- The era synthesis and desynthesis recipes for allrecipes, generated by tools/gen_recipes.py",
        "-- from Phoenix's sql/synth_recipes.sql. Do not edit; run the script again instead.",
        "-- { id, desynth (1/0), key item (0 = none), { woodworking, smithing, goldsmithing, clothcraft,",
        "--   leathercraft, bonecraft, alchemy, cooking }, crystal, { item, count, ... },",
        "--   { nq, count, hq1, count, hq2, count, hq3, count }, expansion ('' = original game) }",
        "-- A desynthesis recipe's one ingredient is the item broken up; its results are what comes out.",
        "return {",
    ]
    for r in recipes:
        lines.append("{%d,%d,%d,%s,%d,%s,%s,'%s'}," % (
            r["id"], r["desynth"], r["keyitem"], lua_list(r["skills"]), r["crystal"],
            lua_list(collapse(r["ingredients"])), lua_list(r["results"]), ERA_TAGS[r["tag"]]))
    lines.append("}")
    out.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")


def write_npc(recipes, items, out):
    ids = set()
    for r in recipes:
        ids.add(r["crystal"])
        ids.update(r["ingredients"])
        ids.update(r["results"][0::2])
    entries = []
    for itemid in sorted(ids):
        if itemid in items:
            sell, nosale, _stack = items[itemid]
            entries.append("[%d]=%s" % (itemid, "false" if nosale else sell))
    lines = [
        "-- What an NPC shop pays for the items in allrecipes' recipes, generated by tools/gen_recipes.py",
        "-- from Phoenix's sql/item_basic.sql (BaseSell). Do not edit; run the script again instead.",
        "-- [item id] = gil for one before fame (0 = nothing), or false when shops won't buy it.",
        "return {",
    ]
    for i in range(0, len(entries), 16):
        lines.append(",".join(entries[i:i + 16]) + ",")
    lines.append("}")
    out.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    return len(entries)


def write_stacks(items, out):
    entries = ["[%d]=%d" % (itemid, items[itemid][2]) for itemid in sorted(items) if items[itemid][2] > 1]
    lines = [
        "-- How many of an item make a stack on Phoenix, for every item that stacks, generated by",
        "-- tools/gen_recipes.py from sql/item_basic.sql and the modules' changes to it. Do not edit.",
        "-- [item id] = stack size; an item not listed doesn't stack.",
        "return {",
    ]
    for i in range(0, len(entries), 16):
        lines.append(",".join(entries[i:i + 16]) + ",")
    lines.append("}")
    out.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    return len(entries)


def write_loss(loss, out):
    lines = [
        "-- Materials that a failed synthesis loses more or less often than half the time, generated by",
        "-- tools/gen_recipes.py from materialLossRates in Phoenix's src/map/utils/synthutils.cpp.",
        "-- [item id] = percent chance it's lost when the synthesis breaks.",
        "return {",
    ]
    lines += ["[%d]=%d," % (k, v) for k, v in sorted(loss.items())]
    lines.append("}")
    out.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--phoenix", type=Path, default=Path(r"C:\code\Phoenix"), help="Phoenix server checkout")
    ap.add_argument("--out", type=Path, default=DATA)
    ap.add_argument("--report", action="store_true", help="print a few sample recipes")
    args = ap.parse_args(argv)

    recipes = read_recipes(args.phoenix)
    keep, dropped = pick(recipes)
    items = read_items(args.phoenix)
    changed = apply_modules(args.phoenix, items)
    loss = read_loss(args.phoenix)

    args.out.mkdir(parents=True, exist_ok=True)
    write_recipes(keep, args.out / "recipes.lua")
    priced = write_npc(keep, items, args.out / "npc.lua")
    stacking = write_stacks(items, args.out / "stacks.lua")
    write_loss(loss, args.out / "loss.lua")

    synth = sum(1 for r in keep if r["desynth"] == 0)
    print("read %d recipes; kept %d (%d synthesis, %d desynthesis)" % (len(recipes), len(keep), synth, len(keep) - synth))
    print("left out: " + ", ".join("%d %s" % (v, k) for k, v in dropped.items() if v))
    print("Phoenix's modules change: " + ", ".join("%d %s" % (v, k) for k, v in changed.items()))
    print("wrote %s: %d NPC prices, %d items that stack, %d break-rate exceptions" % (args.out, priced, stacking, len(loss)))
    if args.report:
        for rid in (1001, 523, 20):
            for r in keep:
                if r["id"] == rid:
                    print("  %5d %-24s %s %s %s -> %s" % (rid, r["name"], r["tag"], r["skills"], collapse(r["ingredients"]), r["results"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())

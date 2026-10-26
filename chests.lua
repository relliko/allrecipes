--[[
* allrecipes - chests
* Treasure chests and coffers: each zone's level, key, map, what one gives and how often, and the
* spots it moves between (data/treasure.lua, from Phoenix's scripts/globals/treasure.lua;
* tools/gen_treasure.py). The way Phoenix works it out (xi.treasure.onTrade):
*   - the zone's key always opens it. A THF (main job) can try thief's tools, a living key or a
*     skeleton key instead: each has its odds of opening it, failing, a trap (Weakness) and, for
*     coffers, a mimic; the odds of opening drop 5% a level the box is over you (to the fail);
*   - opened, it gives the zone's map key item if you don't have it yet, else gil or an item by
*     weight out of 1000. A quest that needs a key item from it gives that instead;
*   - gil: each player in the zone gets floor(n x L x (L + r) / players), L the box's level, r from
*     0 to L, n = 1 + the alliance members in the zone (you too) + trusts, at most 6;
*   - then it hides for 180 seconds and comes back at one of its spots (maybe the same one). For
*     15-60 minutes after a regular opening it's an illusion: a trade only moves it (the key's kept).
--]]

local chests = {
    boxes = nil,   -- { id, kind, level, key, map, tag, gil, loot = { { id, chance } }, quests, points }
    thief = nil,   -- [key type][kind] = { success, fail, trap, mimic } (fractions)
    keys = nil,    -- [key type] = item id (1: the box's own key)
    illusion = nil,
    respawn = nil,
    error = nil,
    cache = nil,   -- { key, rows }
};

chests.TAB = 14;
chests.KIND = { 'Chest', 'Coffer' };
chests.KEY_NAMES = { 'its key', 'thief\'s tools', 'living key', 'skeleton key' };
chests.OUTCOMES = { 'opens', 'fails', 'trap', 'mimic' };

function chests.load()
    local f, why = loadfile(('%s\\data\\treasure.lua'):fmt(addon.path));
    if (f == nil) then
        chests.error = tostring(why);
        return false;
    end
    setfenv(f, { });
    local ok, t = pcall(f);
    if (not ok or type(t) ~= 'table' or type(t.boxes) ~= 'table') then
        chests.error = ok and 'data/treasure.lua did not return the boxes' or tostring(t);
        return false;
    end
    chests.thief = { };
    for k, kinds in ipairs(t.thief) do
        chests.thief[k] = { };
        for kind, row in ipairs(kinds) do
            chests.thief[k][kind] = { row[1] / 100, row[2] / 100, row[3] / 100, row[4] / 100 };
        end
    end
    chests.keys, chests.illusion, chests.respawn = t.keys, t.illusion, t.respawn;
    chests.boxes = { };
    for _, b in ipairs(t.boxes) do
        local box = { id = b[1], kind = b[2], level = b[3], key = b[4], map = b[5], tag = b[6] ~= '' and b[6] or nil,
                      gil = 0, loot = { }, quests = { }, points = b[9] };
        for _, l in ipairs(b[7]) do
            if (l[1] == 0) then
                box.gil = box.gil + l[2] / 1000;
            else
                box.loot[#box.loot + 1] = { id = l[1], chance = l[2] / 1000 };
            end
        end
        for _, q in ipairs(b[8]) do
            box.quests[#box.quests + 1] = { ki = q[1], quest = q[2] };
        end
        chests.boxes[#chests.boxes + 1] = box;
    end
    chests.error, chests.cache = nil, nil;
    return true;
end

-- The key item used by a key type for a box: its own key, or the THF one.
function chests.key_item(box, k)
    return k == 1 and box.key or chests.keys[k];
end

--[[
* The odds of each outcome with key type k for a THF of `level` (main job): { opens, fails, trap,
* mimic }. The zone key always opens it. Under the box's level the chance of opening drops 5% a
* level, to the fail.
--]]
function chests.odds(box, k, level)
    local r = chests.thief[k][box.kind];
    if (k == 1) then
        return { r[1], r[2], r[3], r[4] };
    end
    local penalty = math.min(math.max(0.05 * (box.level - (level or 0)), 0), r[1]);
    return { r[1] - penalty, r[2] + penalty, r[3], r[4] };
end

--[[
* The gil each player gets when it gives gil, with `players` players of the alliance in the zone
* (you too) and `trusts` trusts: the least, the most and the average.
--]]
function chests.gil(box, players, trusts)
    players = math.max(players or 1, 1);
    local n = math.min(1 + players + (trusts or 0), 6);
    local L = box.level;
    local lo = math.floor(n * L * L / players);
    local hi = math.floor(n * L * (L + L) / players);
    return lo, hi, n * L * (L + L / 2) / players, n;
end

--[[
* What an opening is worth, at worth(id) gil for one of an item and `gil` for the average gil: {
* items = the items' worth (each by its chance; nil when none is priced), priced, count, gil (its
* chance times the average), total = gil + items }. The map key item isn't counted.
--]]
function chests.worth(box, worth, gil)
    local out = { priced = 0, count = #box.loot, gil = box.gil * gil };
    for _, l in ipairs(box.loot) do
        local v = worth(l.id);
        if (v ~= nil) then
            out.items = (out.items or 0) + l.chance * v;
            out.priced = out.priced + 1;
        end
    end
    out.total = out.gil + (out.items or 0);
    return out;
end

--[[
* The rows the list shows: { box, name, find, value, net } for each box that passes the filters (an
* item searched for: boxes that give it, with its chance as `find`), sorted as `s` says. value is
* chests.worth's; net takes off the key's price (key(id) gil, nil when it has none).
--]]
local SORTS = {
    zone  = function (a) return a.name; end,
    level = function (a) return a.box.level; end,
    spots = function (a) return #a.box.points; end,
    find  = function (a) return a.find or 0; end,
    gil   = function (a) return a.net or a.value.total; end,
};

function chests.rows(s, names, zone_name, price)
    local key = table.concat({ s.search or '', s.chestsort or 'zone', s.chestdir or 1, s.expansions.COP and 1 or 0,
        s.expansions.TOAU and 1 or 0, s.expansions.WOTG and 1 or 0, price.players, price.trusts, tostring(price.stamp) }, ',');
    if (chests.cache ~= nil and chests.cache.key == key) then
        return chests.cache.rows;
    end
    local search = (s.search or ''):lower();
    local out = { };
    for _, b in ipairs(chests.boxes) do
        if (b.tag == nil or s.expansions[b.tag]) then
            local find = nil;
            if (search ~= '') then
                for _, l in ipairs(b.loot) do
                    if (names(l.id):lower():find(search, 1, true) ~= nil) then
                        find = (find or 0) + l.chance;
                    end
                end
                if (('gil'):find(search, 1, true) == 1 and b.gil > 0) then
                    find = (find or 0) + b.gil;
                end
            end
            local name = zone_name(b.id);
            if (search == '' or find ~= nil or name:lower():find(search, 1, true) ~= nil
                    or chests.KIND[b.kind]:lower():find(search, 1, true) ~= nil) then
                local _, _, avg = chests.gil(b, price.players, price.trusts);
                local value = chests.worth(b, price.worth, avg);
                local k = price.key(b.key);
                out[#out + 1] = { box = b, name = name, find = find, value = value, net = k ~= nil and value.total - k or nil };
            end
        end
    end
    local sort = s.chestsort or 'zone';
    if (sort == 'find' and search == '') then
        sort = 'zone';
    end
    local by, dir = SORTS[sort] or SORTS.zone, (s.chestdir or 1) < 0 and -1 or 1;
    table.sort(out, function (a, b)
        local x, y = by(a), by(b);
        if (x ~= y) then
            if (dir > 0) then return x < y; end
            return x > y;
        end
        if (a.name ~= b.name) then
            return a.name < b.name;
        end
        return a.box.kind < b.box.kind;
    end);
    chests.cache = { key = key, rows = out };
    return out;
end

return chests;

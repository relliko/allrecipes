--[[
* allrecipes - helm
* Harvesting, excavation, logging and mining: each zone's points, what they give and how often
* (data/helm.lua, from Phoenix's HELM table; tools/gen_helm.py). The way Phoenix works it out
* (scripts/globals/hobbies/helm/logic.lua):
*   - a try finds something obtain% of the time, and then a drop by its weight;
*   - the tool breaks break% of the time, whatever's found; gear only changes that: each point of
*     the kind's NQ mod (Field gear) multiplies it by 0.893, each of its HQ mod (Worker gear) by
*     0.843. Excavation has no gear;
*   - a point moves after relocate% of finds (gone for respawn seconds). If one moves away from
*     under you and later comes back to the same spot, tools break camp times as often there;
*   - some zones give nothing under a level (the tool can still break), some drops have a daily
*     cap (each one makes the next rarer; reset after midnight in Japan, on zoning) and some get
*     rarer with each one of a pool until you zone;
*   - Red Rock stands for the day's coloured rock.
--]]

local helm = {
    kinds = nil,   -- [1..4] = { name, tool, relocate, respawn, camp, gear, zones }
    error = nil,
};

helm.FIRST = 10;              -- the tabs: 10 harvesting, 11 excavation, 12 logging, 13 mining
helm.NQ, helm.HQ = 0.893, 0.843;
helm.RED_ROCK = 769;
helm.SHORT = { 'Harvest', 'Excavate', 'Log', 'Mine' };
helm.TOOL = { 'sickle', 'pickaxe', 'hatchet', 'pickaxe' };
-- The gear's slots (Ashita's equipment slots): body, hands, legs, feet.
helm.SLOTS = { 5, 6, 7, 8 };

function helm.load()
    local f, why = loadfile(('%s\\data\\helm.lua'):fmt(addon.path));
    if (f == nil) then
        helm.error = tostring(why);
        return false;
    end
    setfenv(f, { });
    local ok, t = pcall(f);
    if (not ok or type(t) ~= 'table' or t[1] == nil) then
        helm.error = ok and 'data/helm.lua did not return the HELM kinds' or tostring(t);
        return false;
    end
    helm.kinds = { };
    for k = 1, 4 do
        local src = t[k];
        local kind = { name = src.name, tool = src.tool, relocate = src.relocate, respawn = src.respawn, camp = src.camp,
                       gear = src.gear or { }, zones = { }, index = { } };
        for _, z in ipairs(src.zones) do
            local zone = { id = z[1], obtain = z[2] / 100, brk = z[3] / 100, level = z[4], weather = z[5] ~= '' and z[5] or nil,
                           tag = z[6] ~= '' and z[6] or nil, drops = { }, points = z[8], depletion = z[9] or 0, sum = 0 };
            for _, d in ipairs(z[7]) do
                zone.drops[#zone.drops + 1] = { weight = d[1], id = d[2], cap = d[3], pool = d[4] == 1 };
                zone.sum = zone.sum + d[1];
            end
            kind.zones[#kind.zones + 1] = zone;
            kind.index[zone.id] = zone;
        end
        helm.kinds[k] = kind;
    end
    helm.error = nil;
    return true;
end

-- A drop's chance a try: found, then picked by weight (fresh: no daily cap or pool used yet).
function helm.chance(zone, d)
    return zone.sum > 0 and zone.obtain * d.weight / zone.sum or 0;
end

-- The break chance with nq and hq points of gear.
function helm.break_with(zone, nq, hq)
    return zone.brk * helm.NQ ^ math.max(nq or 0, 0) * helm.HQ ^ math.max(hq or 0, 0);
end

-- The most a kind's gear gives, by set: { nq, hq } for 'field' (all NQ) and 'worker' (all HQ).
function helm.sets(kind)
    local nq, hq = 0, 0;
    for _, g in ipairs(kind.gear) do
        nq, hq = nq + g[2], hq + g[3];
    end
    return { field = { nq, 0 }, worker = { 0, hq } };
end

--[[
* The kind's gear you're wearing: nq, hq and the pieces' item ids. Equipment slots hold an index
* (container * 256 + slot) into your bags.
--]]
function helm.worn(kind)
    local inv = AshitaCore:GetMemoryManager():GetInventory();
    if (inv == nil) then
        return 0, 0, { };
    end
    local mods = { };
    for _, g in ipairs(kind.gear) do
        mods[g[1]] = g;
    end
    local nq, hq, pieces = 0, 0, { };
    for slot = 0, 15 do
        local e = inv:GetEquippedItem(slot);
        local index = e ~= nil and e.Index or 0;
        if (index ~= 0) then
            local it = inv:GetContainerItem(bit.rshift(bit.band(index, 0xFF00), 8), bit.band(index, 0xFF));
            local g = it ~= nil and mods[it.Id] or nil;
            if (g ~= nil) then
                nq, hq = nq + g[2], hq + g[3];
                pieces[#pieces + 1] = g[1];
            end
        end
    end
    return nq, hq, pieces;
end

--[[
* The rows the zone list shows for a kind: { z, items } for each zone that passes the filters (an
* item searched for: zones that give it, with its chance a try as `find`), sorted as `s` says.
--]]
local SORTS = {
    zone   = function (a) return a.name; end,
    obtain = function (a) return a.z.obtain; end,
    brk    = function (a) return a.z.brk; end,
    points = function (a) return #a.z.points; end,
    find   = function (a) return a.find or 0; end,
};

function helm.rows(s, k, names, zone_name)
    local kind = helm.kinds[k];
    local search = (s.search or ''):lower();
    local out = { };
    for _, z in ipairs(kind.zones) do
        if (z.tag == nil or s.expansions[z.tag]) then
            local find = nil;
            if (search ~= '') then
                for _, d in ipairs(z.drops) do
                    if (names(d.id):lower():find(search, 1, true) ~= nil) then
                        find = (find or 0) + helm.chance(z, d);
                    end
                end
            end
            local name = zone_name(z.id);
            if (search == '' or find ~= nil or name:lower():find(search, 1, true) ~= nil) then
                out[#out + 1] = { z = z, name = name, find = find };
            end
        end
    end
    local sort = s.helmsort or 'zone';
    if (sort == 'find' and search == '') then
        sort = 'zone';
    end
    local by, dir = SORTS[sort] or SORTS.zone, (s.helmdir or 1) < 0 and -1 or 1;
    table.sort(out, function (a, b)
        local x, y = by(a), by(b);
        if (x ~= y) then
            if (dir > 0) then return x < y; end
            return x > y;
        end
        return a.name < b.name;
    end);
    return out;
end

return helm;

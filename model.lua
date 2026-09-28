--[[
* allrecipes - model
* The recipe data, the list the window shows for a craft (filtered, worked out and sorted), and
* the names of things. The list is only worked out again when something it depends on changes.
--]]

local odds   = require('odds');
local prices = require('prices');

local model = {
    recipes = nil,  -- data/recipes.lua
    npc     = { },  -- [item id] = what an NPC pays, false when it won't buy
    stacks  = { },  -- [item id] = how many make a stack on Phoenix (not listed: it doesn't stack)
    error   = nil,  -- why the data didn't load
    by      = nil,  -- [desynth 0/1][craft] = the recipes that use the craft
    names   = { },  -- [item id] = name, from the game
    cache   = { stamp = nil, rows = nil },
};

-- The expansions recipes can come from (the data's tags), in order, as they're shown.
model.EXPANSIONS = { { tag = 'ROTZ', name = 'RoZ' }, { tag = 'COP', name = 'CoP' }, { tag = 'TOAU', name = 'ToAU' }, { tag = 'WOTG', name = 'WotG' } };
local SHORT_TAG = { ROTZ = 'RoZ', COP = 'CoP', TOAU = 'ToAU', WOTG = 'WotG' };

local function load_data(name)
    local f, why = loadfile(('%s\\data\\%s.lua'):fmt(addon.path, name));
    if (f == nil) then
        return nil, why;
    end
    setfenv(f, { });  -- data only
    local ok, t = pcall(f);
    if (not ok or type(t) ~= 'table') then
        return nil, ok and ('data/%s.lua did not return a table'):fmt(name) or t;
    end
    return t;
end

function model.load()
    local recipes, why = load_data('recipes');
    local npc, why2 = load_data('npc');
    local loss, why3 = load_data('loss');
    local stacks, why4 = load_data('stacks');
    if (recipes == nil or npc == nil or loss == nil or stacks == nil) then
        model.error = tostring(why or why2 or why3 or why4);
        return false;
    end
    model.recipes, model.npc, odds.loss, model.stacks, model.error = recipes, npc, loss, stacks, nil;
    model.by = { [0] = { }, [1] = { } };
    for m = 0, 1 do
        for c = 1, 8 do
            model.by[m][c] = { };
        end
    end
    model.index = { };
    for _, r in ipairs(recipes) do
        model.index[r[1]] = r;
        for c = 1, 8 do
            if (r[4][c] > 0) then
                table.insert(model.by[r[2]][c], r);
            end
        end
    end
    model.cache.stamp = nil;
    return true;
end

-- An item's name as the game has it.
function model.name(id)
    local n = model.names[id];
    if (n == nil) then
        local res = AshitaCore:GetResourceManager():GetItemById(id);
        n = res ~= nil and res.Name ~= nil and res.Name[1] or '';
        if (n == '') then
            n = ('Item %d'):fmt(id);
        end
        model.names[id] = n;
    end
    return n;
end

-- What the list calls a recipe: what it makes (with how many), or the item it breaks up.
function model.title(r)
    if (r[2] == 1) then
        return model.name(r[6][1]);
    end
    local count = r[7][2];
    return count > 1 and ('%s x%d'):fmt(model.name(r[7][1]), count) or model.name(r[7][1]);
end

-- The craft a recipe belongs to: the one it needs most (the server's own rule, startSynth).
function model.main_craft(r)
    local best, level = 1, -1;
    for c = 1, 8 do
        if (r[4][c] > level) then
            best, level = c, r[4][c];
        end
    end
    return best;
end

function model.tag(r)
    return SHORT_TAG[r[8]];
end

-- Everything the list depends on, as one string.
local function stamp(s, you, craft)
    local parts = { craft, s.desynth and 1 or 0, s.skillups and 1 or 0, s.sell, s.sub and 1 or 0, s.keyitems and 1 or 0,
                    s.sort, s.dir, s.search or '', prices.version };
    for _, e in ipairs(model.EXPANSIONS) do
        parts[#parts + 1] = s.expansions[e.tag] and 1 or 0;
    end
    for c = 1, 8 do
        parts[#parts + 1] = ('%d/%d/%d/%s'):fmt(you.level[c], you.bonus[c], you.rank[c], tostring(you.capped[c]));
    end
    return table.concat(parts, ',');
end

local SORTS = {
    lv     = function (a) return a.lv; end,
    name   = function (a) return a.title; end,
    ok     = function (a) return a.p; end,
    hq     = function (a) return a.hq; end,
    profit = function (a) return a.profit or -math.huge; end,
};

--[[
* The rows for a craft: { r, lv, title, band, p (success), hq (chance of an HQ a try), up
* (skill-up chance), profit (a try, for the chosen buyer, or nil), sub, tag, ki } for every recipe
* that passes the filters in `s`, sorted the way `s` says.
--]]
function model.rows(s, you, craft)
    local key = stamp(s, you, craft);
    if (model.cache.stamp == key) then
        return model.cache.rows;
    end
    local out = { };
    local search = (s.search or ''):lower();
    for _, r in ipairs(model.by[s.desynth and 1 or 0][craft]) do
        local tag = r[8];
        local sub = model.main_craft(r) ~= craft;
        if ((tag == '' or s.expansions[tag]) and (s.sub or not sub) and (s.keyitems or r[3] == 0)) then
            local title = model.title(r);
            local up = odds.skillup(r, craft, you);
            if ((search == '' or title:lower():find(search, 1, true) ~= nil) and (not s.skillups or up > 0)) then
                local o = odds.odds(r, you);
                out[#out + 1] = {
                    r = r, lv = r[4][craft], title = title, band = odds.band(r, you), p = o.p,
                    hq = o.tiers[2] + o.tiers[3] + o.tiers[4], up = up, sub = sub, tag = model.tag(r), ki = r[3] ~= 0,
                    profit = odds.profit(r, you, prices.view, s.sell, model.npc),
                };
            end
        end
    end
    local by, dir = SORTS[s.sort] or SORTS.lv, s.dir < 0 and -1 or 1;
    table.sort(out, function (a, b)
        local x, y = by(a), by(b);
        if (x ~= y) then
            if (dir > 0) then return x < y; end
            return x > y;
        end
        if (a.lv ~= b.lv) then return a.lv < b.lv; end
        if (a.title ~= b.title) then return a.title < b.title; end
        return a.r[1] < b.r[1];
    end);
    model.cache.stamp, model.cache.rows = key, out;
    return out;
end

--[[
* 1234567 -> '1,234,567'; with sign, '+1,234' / '-1,234'.
--]]
function model.gil(n, sign)
    local s = tostring(math.floor(math.abs(n) + 0.5)):reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '');
    if (not sign) then
        return (n < 0 and '-' or '') .. s;
    end
    return (n < 0 and '-' or '+') .. s;
end

-- A short signed amount for the list: +210, -1.2k, +35k.
function model.short(n)
    local a, sign = math.abs(n), n < 0 and '-' or '+';
    if (a >= 9999.5) then
        return ('%s%dk'):fmt(sign, math.floor(a / 1000 + 0.5));
    elseif (a >= 999.5) then
        return ('%s%.1fk'):fmt(sign, a / 1000);
    end
    return ('%s%d'):fmt(sign, math.floor(a + 0.5));
end

-- A chance as a percentage: 95%, 6.25%, 1.56%, 5%, <0.01%.
function model.pct(x)
    local v = x * 100;
    if (v <= 0) then
        return '0%';
    elseif (v < 0.005) then
        return '<0.01%';
    elseif (v < 10) then
        local s = ('%.2f'):fmt(v):gsub('0+$', ''):gsub('%.$', '');
        return s .. '%';
    end
    return ('%d%%'):fmt(math.floor(v + 0.5));
end

return model;

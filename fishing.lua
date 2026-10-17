--[[
* allrecipes - fishing
* The fishing atlas: every fish (and item) Phoenix lets you fish up, the level to start it and the
* level it stops giving skill-ups, where it bites and on what. data/fish.lua comes from Phoenix's
* fishing tables (tools/gen_fish.py); the skill-up odds are FishingSkillup's
* (src/map/utils/fishingutils.cpp):
*   - only a fish over your level gives skill-ups, and only up to 50 over: its level is its cap;
*   - the chance is a bell around 11 over (5 levels either way), never under 4, out of a roll of
*     90, less 10 outside a town and less (20 - level / 3) under level 50;
*   - items and monsters never give skill-ups.
* Phoenix runs its own fishing patch over that (modules/temp_patch/phoenix-fishing.patch): no
* moon in skill-ups, and its own rules for fish getting away, lines snapping and rods breaking
* (fishing.rod).
* A fish more than 7 levels over you can get away for lack of skill (0.8% a level past 7), so it's
* worth starting 20 under its level: from there the chance climbs off its floor and fewer than 1
* in 10 get away for it.
*
* And the fish you catch today, counted from your own "<you> caught <fish>!" lines and reset at
* midnight in Japan (when the game's own daily limits reset). The 0x027 packet the line comes
* from names the item, so each fish is counted too. Only read.
--]]

local fishing = {
    list   = nil,   -- data/fish.lua's fish, as rows
    index  = { },   -- [item id] = row
    zones  = { },   -- [zone id] = name (the data's, the game's where it has one)
    error  = nil,
    cache  = { stamp = nil, rows = nil },
    recent = nil,   -- { id, count, at } the last catch packet, for the line that follows it
    dirty  = false, -- the day's count changed and should be saved
};

fishing.START = 20;     -- worth starting this many levels under a fish
fishing.BEST = 11;      -- where the skill-up chance peaks
fishing.REACH = 50;     -- no skill-ups from a fish more than this over you
fishing.LOSE_FROM = 7;  -- over you by more than this, it can get away for lack of skill
fishing.CAP = 100;      -- fishing's skill cap on Phoenix
fishing.SKILL = 9;      -- fishing's place in the skill tables (after the eight crafts)
fishing.JST = 9 * 3600;

local function load_data()
    local f, why = loadfile(('%s\\data\\fish.lua'):fmt(addon.path));
    if (f == nil) then
        return nil, why;
    end
    setfenv(f, { });
    local ok, t = pcall(f);
    if (not ok or type(t) ~= 'table' or type(t.fish) ~= 'table') then
        return nil, ok and 'data/fish.lua did not return the fish' or t;
    end
    return t;
end

function fishing.load()
    local t, why = load_data();
    if (t == nil) then
        fishing.error = tostring(why);
        return false;
    end
    local res = AshitaCore:GetResourceManager();
    fishing.zones = { };
    for id, name in pairs(t.zones or { }) do
        local game = res:GetString('zones.names', id);
        fishing.zones[id] = (game ~= nil and game ~= '') and game or name;
    end
    fishing.list, fishing.index = { }, { };
    for _, f in ipairs(t.fish) do
        local item = res:GetItemById(f[1]);
        local name = item ~= nil and item.Name ~= nil and item.Name[1] or '';
        local row = {
            id = f[1], name = name ~= '' and name or f[2], lv = f[3], large = f[4] == 1, item = f[5] == 1,
            legendary = f[6] == 1, ki = f[7], quest = f[8] == 1, tag = f[9] ~= '' and f[9] or nil,
            where = f[10], bait = f[11], rank = f[12] or 0,
        };
        row.start = math.max(0, row.lv - fishing.START);
        row.log = (item ~= nil and item.LogNameSingular ~= nil and item.LogNameSingular[1] or ''):lower();
        row.logs = (item ~= nil and item.LogNamePlural ~= nil and item.LogNamePlural[1] or ''):lower();
        fishing.list[#fishing.list + 1] = row;
        fishing.index[row.id] = row;
    end
    fishing.rods = { };
    for _, r in ipairs(t.rods or { }) do
        local item = res:GetItemById(r[1]);
        local name = item ~= nil and item.Name ~= nil and item.Name[1] or '';
        fishing.rods[#fishing.rods + 1] = { id = r[1], name = name ~= '' and name or r[2], large = r[3] == 1, min = r[4], max = r[5],
                                            breakable = r[6] == 1, legendary = r[7] == 1, rating = r[8] };
    end
    fishing.gear = t.gear or { };
    fishing.error, fishing.cache.stamp = nil, nil;
    return true;
end

--[[
* Gear. Fishing skill from gear (the FISH mod: Fisherman's and Angler's pieces +1, Waders +2)
* counts in everything about landing a fish, but not in skill-ups, which go by your own level
* (GetFishingSkill vs FishingSkillup). A Pelican Ring's effect (up to two at once) gives a catch
* one more skill-up roll each.
--]]

-- The most skill the era's gear gives: the best piece in each slot.
function fishing.full_gear()
    local best = { };
    for _, g in ipairs(fishing.gear or { }) do
        best[g[3]] = math.max(best[g[3]] or 0, g[2]);
    end
    local n = 0;
    for _, v in pairs(best) do
        n = n + v;
    end
    return n;
end

-- The fishing skill on what you wear, and the pieces.
function fishing.worn_gear()
    local inv = AshitaCore:GetMemoryManager():GetInventory();
    if (inv == nil) then
        return 0, { };
    end
    local by = { };
    for _, g in ipairs(fishing.gear or { }) do
        by[g[1]] = g[2];
    end
    local n, pieces = 0, { };
    for slot = 0, 15 do
        local e = inv:GetEquippedItem(slot);
        local index = e ~= nil and e.Index or 0;
        if (index ~= 0) then
            local it = inv:GetContainerItem(bit.rshift(bit.band(index, 0xFF00), 8), bit.band(index, 0xFF));
            local v = it ~= nil and by[it.Id] or nil;
            if (v ~= nil) then
                n = n + v;
                pieces[#pieces + 1] = it.Id;
            end
        end
    end
    return n, pieces;
end

-- What the numbers assume, from the settings: skill from gear and skill-up rolls a catch.
function fishing.setup(s)
    local bonus = 0;
    if (s.fishgear == 'full') then
        bonus = fishing.full_gear();
    elseif (s.fishgear == 'worn') then
        bonus = fishing.worn_gear();
    end
    return { bonus = bonus, rolls = 1 + math.max(0, math.min(2, s.fishpelican or 0)) };
end

--[[
* How a rod does with a fish at fishing skill `sk` (your level and gear), by Phoenix's rules
* (its fishing patch, modules/temp_patch/phoenix-fishing.patch, over fishingutils.cpp's
* CalculateLoseChance, CalculateSnapChance, CalculateBreakChance and CalculateHookChance). A
* fish's ranking is how strong it is; a rod holds rankings up to its max_rank.
*   lose  - it gets away: too big for the rod ('big': 50% less 1 a level you're over the fish),
*           too small ('small': a large-fish rod lets a small fish go 1.8% a level of the fish, up
*           to 90%) or for lack of skill ('skill': 0.8% a level past 7 over you, and every time
*           50 or more over); the biggest of these;
*   snap  - the line snaps: 19% a rank over what the rod holds (2 less with a small-fish rod on a
*           large fish, 3 less for a legendary fish, 1 more with a legendary rod), up to 55%;
*   brk   - the rod breaks: 10% a rank over (plus those penalties), up to 20%;
*   hook  - bites lost to the wrong size of rod (3 for a fish smaller than it, 5 for bigger).
* They're rolled in that order, each only if the last didn't happen; risk is one of them, own
* the same leaving out a loss for lack of skill (which no rod changes).
--]]
function fishing.rod(row, rod, sk)
    local fs, rs = row.large and 1 or 0, rod.large and 1 or 0;
    local out = { lose = 0, why = nil, snap = 0, brk = 0, hook = 0 };
    local big, small = 0, 0;
    if (not rod.legendary) then
        if (fs > rs and row.rank > rod.max) then
            big = math.max(0, math.min(50, 50 - (sk - row.lv)));
        elseif (fs < rs) then
            small = math.min(90, math.floor(row.lv * 1.8));
        end
        out.hook = fs < rs and 3 or rs < fs and 5 or 0;
    end
    local low = row.item and 0 or math.floor(fishing.lose(row, sk) * 100 + 0.5);
    if (big > 0 and big > low) then
        out.lose, out.why = big, 'big';
    elseif (small > 0 and small > low) then
        out.lose, out.why = small, 'small';
    elseif (low > 0) then
        out.lose, out.why = low, 'skill';
    end
    local pen = (not rod.legendary and fs > rs) and 2 or 0;
    local bonus = 0;
    if (row.legendary) then
        if (rod.legendary) then bonus = 1; else pen = pen + 3; end
    end
    local hold = rod.max + bonus - pen;
    if (row.rank > hold) then
        out.snap = math.min(55, (row.rank - hold) * 19) / 100;
    end
    if (rod.breakable) then
        local bpen = (not rod.legendary and fs > rs) and 2 or 0;
        local bbonus = (rod.legendary and fs == 1) and 1 or 0;
        if (not rod.legendary and row.legendary) then
            bpen = 5;
        end
        local over = row.rank - (rod.max + bbonus);
        if (over > 0) then
            out.brk = math.min(20, (over + bpen) * 10) / 100;
        end
    end
    out.lose = out.lose / 100;
    out.risk = 1 - (1 - out.lose) * (1 - out.snap) * (1 - out.brk);
    -- What's down to the rod (a loss for lack of skill is the same with any rod).
    out.own = 1 - (1 - (out.why == 'skill' and 0 or out.lose)) * (1 - out.snap) * (1 - out.brk);
    return out;
end

-- Every rod with how it does (fishing.rod): the ones that hold it first, the plainest of those
-- first (the least rod it needs), then the rest by how often they lose it.
function fishing.rods_for(row, sk)
    local out = { };
    for _, rod in ipairs(fishing.rods or { }) do
        local r = fishing.rod(row, rod, sk);
        r.rod = rod;
        out[#out + 1] = r;
    end
    table.sort(out, function (a, b)
        if (a.own ~= b.own) then return a.own < b.own; end
        if (a.hook ~= b.hook) then return a.hook < b.hook; end
        if (a.rod.rating ~= b.rod.rating) then return a.rod.rating < b.rod.rating; end
        return a.rod.name < b.rod.name;
    end);
    return out;
end

--[[
* The chance a catch gives at least one skill-up at whole level `lv` (outside a town) with
* `rolls` rolls (a Pelican Ring's effect adds one), the tenths a skill-up gives on average, and
* the skill-ups a catch gives on average. 0 for an item, a fish at or under you, or one over 50
* above. (Phoenix's patch took out the moon's effect on skill-ups.)
--]]
function fishing.skillup(row, lv, rolls)
    rolls = rolls or 1;
    local d = row.lv - lv;
    if (row.item or d <= 0 or d > fishing.REACH or lv >= fishing.CAP) then
        return 0, 0, 0;
    end
    local norm = math.exp(-0.5 * math.log(2 * math.pi) - math.log(5) - (d - 11) ^ 2 / 50);
    local chance = math.max(4, math.floor(norm * 200) + math.floor((100 - lv) / 10) - math.floor(lv / 10));
    local roll = 90 - 10;
    if (lv < 50) then
        roll = roll - (20 - math.floor(lv / 3));
    end
    -- A bonus, 1 in 8, is 1 to max - 1 more tenths (the server's roll leaves max out).
    local most = math.min(1 + math.floor(d / 5), 3);
    local gain = 1 + (most == 3 and 0.5 / 8 or 0);
    local p = math.min(1, chance / roll);
    return 1 - (1 - p) ^ rolls, gain, p * rolls;
end

-- The chance it gets away for lack of skill at fishing skill `sk` (lowSkillChance, as Phoenix
-- has it): 0.8% a level past 7 over you, and always when it's 50 or more over.
function fishing.lose(row, sk)
    if (row.item) then
        return 0;
    end
    if (sk + fishing.REACH <= row.lv) then
        return 1;
    end
    local over = row.lv - (sk + fishing.LOSE_FROM);
    return over > 0 and math.floor(over * 0.8) / 100 or 0;
end

--[[
* About how many catches from skill `tenths` to the next level and to where it stops (its level,
* or your rank's cap first), with `rolls` skill-up rolls a catch. nil where it gives no
* skill-ups.
--]]
function fishing.catches(row, tenths, rank, rolls)
    local cap = math.min(row.lv, (rank + 1) * 10, fishing.CAP) * 10;
    if (row.item or tenths >= cap) then
        return nil;
    end
    local total, next_at, nxt = 0, (math.floor(tenths / 10) + 1) * 10, nil;
    local t = tenths;
    while (t < cap) do
        local lv = math.floor(t / 10);
        local _, gain, ups = fishing.skillup(row, lv, rolls);
        if (ups <= 0) then
            return nil;
        end
        local upto = math.min((lv + 1) * 10, cap);
        total = total + (upto - t) / (ups * gain);
        t = upto;
        if (t == next_at) then
            nxt = total;
        end
    end
    return { next = nxt or total, cap = total, cap_level = cap / 10 };
end

-- How hard it is for you: safe (no skill-ups), good (skill-ups, it stays on), risky, hard, cant.
function fishing.band(row, lv)
    if (row.item) then
        return 'cant';
    end
    local d = row.lv - lv;
    if (d <= 0) then
        return 'safe';
    elseif (d <= fishing.START) then
        return 'good';
    elseif (d <= 35) then
        return 'risky';
    elseif (d <= fishing.REACH) then
        return 'hard';
    end
    return 'zero';
end

-- Where it bites: { { zone name, 'area, area' }, ... } by zone name.
function fishing.places(row)
    if (row.places ~= nil) then
        return row.places;
    end
    local by, order = { }, { };
    for _, w in ipairs(row.where) do
        local name = fishing.zones[w[1]] or ('Zone %d'):fmt(w[1]);
        if (by[name] == nil) then
            by[name] = { };
            order[#order + 1] = name;
        end
        if (w[2] ~= '' and w[2] ~= 'Whole Zone') then
            table.insert(by[name], w[2]);
        end
    end
    table.sort(order);
    local out = { };
    for _, name in ipairs(order) do
        out[#out + 1] = { name, table.concat(by[name], ', ') };
    end
    row.places = out;
    return out;
end

local SORTS = {
    start = function (a) return a.start; end,
    cap   = function (a) return a.lv; end,
    name  = function (a) return a.name; end,
    up    = function (a) return a.up; end,
    gil   = function (a) return a.gil or -1; end,
    today = function (a) return a.today; end,
};

--[[
* The rows the list shows: { f, up (skill-up chance a catch), band, today, gil } for each fish
* that passes the filters in `s` (fishsort, fishdir, fishups, fishitems, search, expansions).
* gil is what one sells for (worth(id), nil when it isn't known); worth_stamp changes whenever
* that could.
--]]
function fishing.rows(s, lv, day, rolls, worth, worth_stamp)
    rolls = rolls or 1;
    local key = table.concat({ lv, rolls, s.fishsort, s.fishdir, s.fishups and 1 or 0, s.fishitems and 1 or 0, s.search or '',
        s.expansions.COP and 1 or 0, s.expansions.TOAU and 1 or 0, day.count, day.day, tostring(worth_stamp) }, ',');
    if (fishing.cache.stamp == key) then
        return fishing.cache.rows;
    end
    local out = { };
    local search = (s.search or ''):lower();
    for _, f in ipairs(fishing.list or { }) do
        local up = fishing.skillup(f, lv, rolls);
        if ((f.tag == nil or s.expansions[f.tag]) and (s.fishitems or not f.item) and (not s.fishups or up > 0)
            and (search == '' or f.name:lower():find(search, 1, true) ~= nil)) then
            out[#out + 1] = { f = f, up = up, band = fishing.band(f, lv), today = day.fish[tostring(f.id)] or 0,
                              gil = worth ~= nil and worth(f.id) or nil };
        end
    end
    local by, dir = SORTS[s.fishsort] or SORTS.cap, s.fishdir < 0 and -1 or 1;
    table.sort(out, function (a, b)
        local x, y = by(a), by(b);
        if (x ~= y) then
            if (dir > 0) then return x < y; end
            return x > y;
        end
        if (a.f.lv ~= b.f.lv) then return a.f.lv < b.f.lv; end
        return a.f.name < b.f.name;
    end);
    fishing.cache.stamp, fishing.cache.rows = key, out;
    return out;
end

--[[
* The day's catches. The day is Japan's: it turns at midnight JST (15:00 UTC). `day` is kept in
* the character's settings: { day = days since 1970 in JST, count, fish = { [item id] = n } }.
--]]
function fishing.today()
    return math.floor((os.time() + fishing.JST) / 86400);
end

-- Seconds until the count starts over.
function fishing.until_reset()
    return 86400 - (os.time() + fishing.JST) % 86400;
end

--[[
* What the day's catches are worth at worth(id) gil each: the total, how many catches that
* counts, and how many kinds caught today have no price.
--]]
function fishing.day_worth(day, worth)
    local total, counted, unpriced = 0, 0, 0;
    for k, n in pairs(day.fish or { }) do
        local id = tonumber(k);
        local v = id ~= nil and worth(id) or nil;
        if (v ~= nil) then
            total, counted = total + v * n, counted + n;
        else
            unpriced = unpriced + 1;
        end
    end
    return total, counted, unpriced;
end

function fishing.roll(day)
    local d = fishing.today();
    if (day.day ~= d) then
        day.day, day.count, day.fish, fishing.dirty = d, 0, { }, true;
    end
end

local function byte_at(s, o) return s:byte(o + 1) or 0; end
local function u16(s, o) return byte_at(s, o) + byte_at(s, o + 1) * 256; end
local function u32(s, o) return u16(s, o) + u16(s, o + 2) * 65536; end

--[[
* A 0x027 (a message with a number, data as a string) about you that names something you can
* fish up: remember it, for the "caught" line it comes with.
--]]
function fishing.packet(data, me, now)
    if (type(data) ~= 'string' or #data < 0x18 or me == nil or me == 0 or u32(data, 0x04) ~= me) then
        return;
    end
    local id = u32(data, 0x10);
    if (fishing.index[id] ~= nil) then
        fishing.recent = { id = id, count = u32(data, 0x14), at = now };
    end
end

-- The chat line without the game's colour and auto-translate codes.
local function plain(text)
    return (text:gsub('\30.', ''):gsub('\31.', ''):gsub('\127.', ''):gsub('[\239][\39\40]', ''));
end

--[[
* A line of chat: "<you> caught a <fish>!" or "<you> caught 3 <fish>!" counts a catch (not
* "caught a monster", nor a catch you couldn't carry and let go). True when it counted.
--]]
function fishing.line(day, text, me, now)
    if (type(text) ~= 'string' or me == nil or me == '') then
        return false;
    end
    local line = plain(text);
    local what = line:match('^' .. me:gsub('%p', '%%%0') .. ' caught (.-)!%s*$');
    if (what == nil or what:find(', but', 1, true) or what:lower():find('monster', 1, true)) then
        return false;
    end
    fishing.roll(day);
    day.count = day.count + 1;
    local id = nil;
    local r = fishing.recent;
    if (r ~= nil and now - r.at < 3) then
        id = r.id;
    else
        -- No packet seen: match the name.
        local name = what:lower():gsub('^an? ', ''):gsub('^the ', ''):gsub('^%d+ ', '');
        for _, f in ipairs(fishing.list or { }) do
            if (f.log == name or f.logs == name or f.name:lower() == name) then
                id = f.id;
                break;
            end
        end
    end
    fishing.recent = nil;
    if (id ~= nil) then
        local k = tostring(id);
        day.fish[k] = (day.fish[k] or 0) + 1;
    end
    fishing.dirty = true;
    return true;
end

return fishing;

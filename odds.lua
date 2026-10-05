--[[
* allrecipes - odds
* What a synthesis or desynthesis does at your skill, as Phoenix works it out
* (src/map/utils/synthutils.cpp; line numbers are from the live branch), and what it's worth.
*
* A recipe is a row of data/recipes.lua: { id, desynth, key item, { 8 craft levels }, crystal,
* { item, count, ... }, { nq, count, hq1, count, hq2, count, hq3, count }, expansion }.
* `you` is { level = { 8 }, bonus = { 8 }, rank = { 8 }, capped = { 8 } } in the same craft
* order, woodworking to cooking: level is your real level, bonus what image support, gear and
* moghancements add to it.
--]]

local odds = { };

-- Server settings, as Phoenix runs them ("Crafting ... rates are all 1.0x ToAU era").
odds.HQ_MULTIPLIER      = 1.0;  -- map.CRAFT_HQ_CHANCE_MULTIPLIER
odds.SKILLUP_MULTIPLIER = 1.0;  -- map.CRAFT_CHANCE_MULTIPLIER
local HQ_CAP        = 0.80;     -- calculateSynthResult: chanceHQ = min(chanceHQ, 80)
local TOO_HARD      = 15;       -- resolveRecipe: cancelled when you're more than 15 levels under
local LOSS          = 50;       -- materialLossRate: a material breaks half the time...
odds.loss = { };                -- ...except these (data/loss.lua)

-- HQ brackets by how far over the recipe you are (:538): chance of a success being HQ, and how
-- that splits into HQ1/HQ2/HQ3 (one 25% upgrade roll at 11 over, two from 31, :636).
local BRACKETS = {
    { over = 0,  chance = 1 / 64, split = { 1, 0, 0 } },
    { over = 11, chance = 1 / 16, split = { 0.75, 0.25, 0 } },
    { over = 31, chance = 1 / 4,  split = { 0.75, 0.1875, 0.0625 } },
    { over = 51, chance = 1 / 2,  split = { 0.75, 0.1875, 0.0625 } },
};
-- Desynthesis: 60% of successes are HQ, and those come out 1/2 HQ1, 1/3 HQ2, 1/6 HQ3 (:718).
local DESYNTH_HQ, DESYNTH_SPLIT = 0.60, { 0.5, 1 / 3, 1 / 6 };

--[[
* The crafts a recipe uses: { craft, need, d } with d = recipe level - (your level + bonus),
* the difficulty the server rolls against (getSynthDifficulty, :424).
--]]
function odds.difficulty(r, you)
    local out = { };
    for c = 1, 8 do
        local need = r[4][c];
        if (need > 0) then
            out[#out + 1] = { craft = c, need = need, d = need - (you.level[c] + (you.bonus[c] or 0)) };
        end
    end
    return out;
end

--[[
* Whether the server lets you start it: your real level in every craft within 15 of the recipe
* (:412, skill < need * 10 - 150 cancels; your level is your skill with the tenths dropped).
* Also the first craft you're too low in, when you can't.
--]]
function odds.can_try(r, you)
    for c = 1, 8 do
        local need = r[4][c];
        if (need > 0 and you.level[c] < need - TOO_HARD) then
            return false, c;
        end
    end
    return true;
end

-- One craft's chance to hold together, 0-1 (synthesis :528, desynthesis :673).
local function rate(d, desynth)
    local pct;
    if (desynth) then
        pct = d <= 0 and 40 or d <= 7 and 40 - 5 * (d - 1) or 10 - 10 * (d - 7) / 3;
    else
        pct = d <= 0 and 95 or d <= 3 and 95 - 5 * d or 80 - 10 * (d - 3);
        pct = math.min(pct, 99);
    end
    return math.max(0, math.min(100, pct)) / 100;
end

local function bracket_of(d)
    local over, found = -d, 1;
    for i, b in ipairs(BRACKETS) do
        if (over >= b.over) then
            found = i;
        end
    end
    return found;
end

--[[
* HQ at your skill: { possible, chance (of a success), split = { hq1, hq2, hq3 } (of HQs),
* bracket (1-4), limit (the craft that sets the bracket), next = { chance, needs = { { craft,
* level } } } (what the next bracket takes, in levels with your bonus counted), below (the craft
* you're under the recipe in, when HQ isn't possible) }.
--]]
function odds.hq_info(r, you)
    local desynth = r[2] == 1;
    if (not odds.can_try(r, you)) then
        return { possible = false, chance = 0, split = { 0, 0, 0 } };
    end
    if (desynth) then
        return { possible = true, chance = math.min(DESYNTH_HQ * odds.HQ_MULTIPLIER, HQ_CAP), split = DESYNTH_SPLIT };
    end
    local ds = odds.difficulty(r, you);
    local worst = ds[1];
    for _, x in ipairs(ds) do
        if (x.d > worst.d) then
            worst = x;
        end
    end
    if (worst.d > 0) then
        return { possible = false, chance = 0, split = { 0, 0, 0 }, below = worst.craft };
    end
    local b = bracket_of(worst.d);
    local info = {
        possible = true, bracket = b, limit = worst.craft, split = BRACKETS[b].split,
        chance = math.min(BRACKETS[b].chance * odds.HQ_MULTIPLIER, HQ_CAP),
    };
    local nb = BRACKETS[b + 1];
    if (nb ~= nil) then
        local needs = { };
        for _, x in ipairs(ds) do
            if (-x.d < nb.over) then
                needs[#needs + 1] = { craft = x.craft, level = x.need + nb.over };
            end
        end
        info.next = { chance = math.min(nb.chance * odds.HQ_MULTIPLIER, HQ_CAP), needs = needs };
    end
    return info;
end

--[[
* The odds of one try: { p = success, hq = chance a success is HQ, tiers = { nq, hq1, hq2, hq3 }
* as chances of the whole try }. Every craft is rolled on its own, so their chances multiply.
--]]
function odds.odds(r, you)
    if (not odds.can_try(r, you)) then
        return { p = 0, hq = 0, tiers = { 0, 0, 0, 0 } };
    end
    local desynth = r[2] == 1;
    local p = 1;
    for _, x in ipairs(odds.difficulty(r, you)) do
        p = p * rate(x.d, desynth);
    end
    local info = odds.hq_info(r, you);
    local h, s = info.chance, info.split;
    return { p = p, hq = h, tiers = { p * (1 - h), p * h * s[1], p * h * s[2], p * h * s[3] } };
end

--[[
* The chance one try raises `craft` (doSynthSkillUp, :929, the era rules): only when the recipe is
* above your real level and you aren't capped; 60% under level 50, 25% from 50, 5% for
* desynthesis; a broken synthesis gives half of that (desynthesis all of it), and only when the
* recipe is 1-5 levels above you.
--]]
function odds.skillup(r, craft, you)
    local need, level = r[4][craft], you.level[craft];
    if (need == 0 or you.capped[craft] or level >= (you.rank[craft] + 1) * 10 or not odds.can_try(r, you)) then
        return 0;
    end
    local over = need - level;
    if (over < 1) then
        return 0;
    end
    local desynth = r[2] == 1;
    local k = (desynth and 0.05 or level < 50 and 0.60 or 0.25) * odds.SKILLUP_MULTIPLIER;
    local p = odds.odds(r, you).p;
    local on_break = over <= 5 and (desynth and k or k / 2) or 0;
    return p * k + (1 - p) * on_break;
end

-- How much a skill-up gives, in tenths, by how many levels the recipe is over you (0-14+):
-- chances of 0.1 to 0.5 (skillUpAmountWeights, :910). From skill 60.0 it's always 0.1.
local AMOUNTS = {
    [0] = { 85, 15 }, { 85, 15 }, { 85, 15 }, { 80, 20 }, { 80, 20 }, { 70, 30 }, { 70, 30 },
    { 60, 40 }, { 60, 40 }, { 50, 40, 10 }, { 40, 40, 20 }, { 40, 40, 20 }, { 15, 45, 30, 10 },
    { 10, 40, 25, 25 }, { 0, 40, 30, 20, 10 },
};

--[[
* How many tries of a recipe it takes on average to raise `craft`: to the next level, and to the
* level where the recipe stops giving skill-ups (its own level, or your rank's cap if that comes
* first). Your skill is somewhere in lo..hi (tenths, as skill.range gives); every value in it is
* taken as equally likely. Each try's chance and amount are worked out at the skill you'd be at
* then, so the chance to succeed rises as you do. { next, cap, cap_level }, each nil when it
* can't be reached; nil when the recipe gives no skill-ups now.
--]]
function odds.synths(r, craft, you, lo, hi)
    if (odds.skillup(r, craft, you) <= 0) then
        return nil;
    end
    local need, max = r[4][craft], (you.rank[craft] + 1) * 100;
    local top = math.min(need * 10, max);
    -- At skill x: the chance a try raises it, and the chances of each amount.
    local at = { level = { }, bonus = you.bonus, rank = you.rank, capped = { } };
    for c = 1, 8 do
        at.level[c], at.capped[c] = you.level[c], false;
    end
    local q, w = { }, { };
    for x = lo, top - 1 do
        at.level[craft] = math.floor(x / 10);
        q[x] = odds.skillup(r, craft, at);
        w[x] = x < 600 and AMOUNTS[math.max(0, math.min(14, need - at.level[craft]))] or { 100 };
    end
    -- Tries from skill x to reach `goal`: E(x) = (1 + q * sum of w(a) * E(x + a)) / q.
    local function from(goal)
        local e = { };
        for x = goal - 1, lo, -1 do
            if (q[x] <= 0) then
                e[x] = math.huge;
            else
                local sum = 0;
                for a, weight in ipairs(w[x]) do
                    if (weight > 0 and x + a < goal) then
                        sum = sum + weight / 100 * e[x + a];
                    end
                end
                e[x] = (1 + q[x] * sum) / q[x];
            end
        end
        local total = 0;
        for x = lo, hi do
            total = total + (x < goal and e[x] or 0);
        end
        total = total / (hi - lo + 1);
        return total < math.huge and total or nil;
    end
    return { next = from(math.min((math.floor(lo / 10) + 1) * 10, top)), cap = from(top), cap_level = math.floor(top / 10) };
end

-- How often a failed try loses a material, 0-1 (handleMaterialLoss, :825).
function odds.loss_rate(item)
    local base = odds.loss[item] or LOSS;
    if (base == 0) then
        return 0;
    end
    return math.max(20, math.min(100, base)) / 100;
end

-- A result's worth each: your AH price, or what an NPC pays (0 when it won't buy). nil unknown.
local function worth(item, mode, prices, npc)
    if (mode == 'NPC') then
        local v = npc[item];
        if (v == false) then
            return 0;
        end
        return v;
    end
    return prices[item];
end

-- The crystal and materials: what they cost all together, and on average when a try breaks.
local function spend(r, prices)
    local crystal = prices[r[5]];
    if (crystal == nil) then
        return nil;
    end
    local all, broken = crystal, crystal;
    local m = r[6];
    for i = 1, #m, 2 do
        local price = prices[m[i]];
        if (price == nil) then
            return nil;
        end
        all = all + m[i + 1] * price;
        broken = broken + m[i + 1] * price * odds.loss_rate(m[i]);
    end
    return all, broken;
end

-- What a try costs on average: the crystal always, each material in full on a success and at
-- its loss rate on a break. nil when a price is missing.
function odds.cost(r, you, prices)
    local all, broken = spend(r, prices);
    if (all == nil) then
        return nil;
    end
    local p = odds.odds(r, you).p;
    local crystal = prices[r[5]];
    return crystal + (all - crystal) * p + (broken - crystal) * (1 - p);
end

-- What a try brings back on average, selling on the AH or to an NPC. nil when a price is missing.
function odds.back(r, you, prices, mode, npc)
    local t = odds.odds(r, you).tiers;
    local res, sum = r[7], 0;
    for k = 1, 4 do
        if (t[k] > 0) then
            local v = worth(res[k * 2 - 1], mode, prices, npc);
            if (v == nil) then
                return nil;
            end
            sum = sum + t[k] * res[k * 2] * v;
        end
    end
    return sum;
end

-- The average profit of a try at your odds, or nil when a price is missing or you can't try it.
function odds.profit(r, you, prices, mode, npc)
    if (not odds.can_try(r, you)) then
        return nil;
    end
    local c = odds.cost(r, you, prices);
    local b = c ~= nil and odds.back(r, you, prices, mode, npc) or nil;
    return b ~= nil and b - c or nil;
end

--[[
* Each way a try can go, with its chance and what you make: { kind ('nq', 'hq1', 'hq2', 'hq3',
* 'break'), chance, item, count, gil } for the ones that can happen, then the average. gil is nil
* when a price it needs is missing, and so is the average then. The chances times the gil add up
* to the average, which is odds.profit. Nothing when you can't start it (nothing is used up).
--]]
function odds.outcomes(r, you, prices, mode, npc)
    if (not odds.can_try(r, you)) then
        return { }, nil;
    end
    local o = odds.odds(r, you);
    local all, broken = spend(r, prices);
    local res, out, avg = r[7], { }, 0;
    local KINDS = { 'nq', 'hq1', 'hq2', 'hq3' };
    for k = 1, 4 do
        if (o.tiers[k] > 0) then
            local item, count = res[k * 2 - 1], res[k * 2];
            local v = worth(item, mode, prices, npc);
            local gil = (v ~= nil and all ~= nil) and count * v - all or nil;
            out[#out + 1] = { kind = KINDS[k], chance = o.tiers[k], item = item, count = count, gil = gil };
            avg = (avg ~= nil and gil ~= nil) and avg + o.tiers[k] * gil or nil;
        end
    end
    if (o.p < 1) then
        local gil = broken ~= nil and -broken or nil;
        out[#out + 1] = { kind = 'break', chance = 1 - o.p, gil = gil };
        avg = (avg ~= nil and gil ~= nil) and avg + (1 - o.p) * gil or nil;
    end
    return out, avg;
end

--[[
* How hard it is for you, for colouring its name: 'cant' (you can't start it), 'zero' (always
* breaks), 'hard', 'risky', 'good', 'safe' (at or over the recipe in every craft), or 'hq' (11 or
* more over: better HQ). Going by your chance to succeed, so several crafts add up.
--]]
function odds.band(r, you)
    if (not odds.can_try(r, you)) then
        return 'cant';
    end
    local desynth = r[2] == 1;
    local worst = -math.huge;
    for _, x in ipairs(odds.difficulty(r, you)) do
        worst = math.max(worst, x.d);
    end
    if (worst <= 0) then
        return (not desynth and worst <= -11) and 'hq' or 'safe';
    end
    local p = odds.odds(r, you).p;
    if (p <= 0) then
        return 'zero';
    end
    if (desynth) then
        return p >= 0.275 and 'good' or p >= 0.15 and 'risky' or 'hard';
    end
    return p >= 0.775 and 'good' or p >= 0.45 and 'risky' or 'hard';
end

return odds;

--[[
* allrecipes - player
* Your crafts as the game knows them: level, rank and cap (the server sends level * 32 + rank,
* plus 0x8000 once capped; charutils.cpp), image support, and your key items.
--]]

local player = {
    imagery = { },  -- [craft] = { since = os.clock() first seen, power = 1 or 3 }
};

-- Woodworking to cooking, in the recipe data's order; skill is the game's skill id (fishing 48),
-- imagery the status effect image support gives for it (data/status_effects.yaml).
player.CRAFTS = {
    { name = 'Woodworking',  short = 'Wood',    skill = 49, imagery = 236 },
    { name = 'Smithing',     short = 'Smith',   skill = 50, imagery = 237 },
    { name = 'Goldsmithing', short = 'Gold',    skill = 51, imagery = 238 },
    { name = 'Clothcraft',   short = 'Cloth',   skill = 52, imagery = 239 },
    { name = 'Leathercraft', short = 'Leather', skill = 53, imagery = 240 },
    { name = 'Bonecraft',    short = 'Bone',    skill = 54, imagery = 241 },
    { name = 'Alchemy',      short = 'Alchemy', skill = 55, imagery = 242 },
    { name = 'Cooking',      short = 'Cook',    skill = 56, imagery = 243 },
};

player.RANKS = { [0] = 'Amateur', 'Recruit', 'Initiate', 'Novice', 'Apprentice', 'Journeyman', 'Craftsman',
                 'Artisan', 'Adept', 'Veteran', 'Expert', 'Authority' };

-- Free image support is +1 for 2 minutes; advanced support and the guild belts are +3 for 8
-- (image_support.lua, items/*_belt.lua). So one still up 2 minutes after it's first seen is +3.
local FREE_LASTS = 125;

-- The game's craft skill: level, rank and capped for one craft.
local function craft_skill(c)
    local p = AshitaCore:GetMemoryManager():GetPlayer();
    local s = p ~= nil and p:GetCraftSkill(player.CRAFTS[c].skill - 48) or nil;
    if (s == nil) then
        return 0, 0, false;
    end
    return s:GetSkill() or 0, s:GetRank() or 0, s:IsCapped() == true;
end

-- Keep track of image support: which craft has it, since when, and how strong it is.
function player.update(now)
    local p = AshitaCore:GetMemoryManager():GetPlayer();
    local buffs = p ~= nil and p:GetBuffs() or { };
    local up = { };
    for _, id in pairs(buffs) do
        for c, craft in ipairs(player.CRAFTS) do
            if (id == craft.imagery) then
                up[c] = true;
            end
        end
    end
    for c = 1, #player.CRAFTS do
        local im = player.imagery[c];
        if (not up[c]) then
            player.imagery[c] = nil;
        elseif (im == nil) then
            player.imagery[c] = { since = now, power = 1 };
        elseif (not im.set and im.power == 1 and now - im.since > FREE_LASTS) then
            im.power = 3;
        end
    end
end

-- Say how strong the image support on a craft is (clicking it in the window cycles 1 and 3).
function player.set_imagery(c, power)
    local im = player.imagery[c];
    if (im ~= nil) then
        im.power, im.set = power, true;
    end
end

-- What odds.lua works with: { level, bonus, rank, capped }, bonus being image support plus the
-- gear bonus you set for each craft.
function player.you(gear)
    local you = { level = { }, bonus = { }, rank = { }, capped = { } };
    for c = 1, #player.CRAFTS do
        you.level[c], you.rank[c], you.capped[c] = craft_skill(c);
        local im = player.imagery[c];
        you.bonus[c] = (im ~= nil and im.power or 0) + (gear and gear[c] or 0);
    end
    return you;
end

-- Your server id (0 at the character screen).
function player.id()
    local party = AshitaCore:GetMemoryManager():GetParty();
    return party ~= nil and party:GetMemberServerId(0) or 0;
end

-- The eight crystals, in the game's order; each element's cluster is 8 on, its HQ crystal
-- (Inferno ..., used the same in a synth, synthutils.cpp) 142 on. rgb stands in for the icon.
player.CRYSTALS = {
    { id = 4096, element = 'Fire',      rgb = { 232, 86, 64 } },
    { id = 4097, element = 'Ice',       rgb = { 120, 196, 240 } },
    { id = 4098, element = 'Wind',      rgb = { 104, 208, 120 } },
    { id = 4099, element = 'Earth',     rgb = { 214, 172, 82 } },
    { id = 4100, element = 'Lightning', rgb = { 176, 118, 232 } },
    { id = 4101, element = 'Water',     rgb = { 76, 132, 236 } },
    { id = 4102, element = 'Light',     rgb = { 244, 244, 236 } },
    { id = 4103, element = 'Dark',      rgb = { 128, 108, 152 } },
};
player.CLUSTER, player.HQ = 8, 142;

local held = { counts = { }, at = nil };
local EVERY = 0.5;   -- seconds between looks through the inventory

-- How many of each crystal, cluster and HQ crystal are in your inventory: [item id] = count.
function player.crystals(now)
    if (held.at ~= nil and now - held.at < EVERY and now >= held.at) then
        return held.counts;
    end
    local counts = { };
    local inv = AshitaCore:GetMemoryManager():GetInventory();
    local max = inv ~= nil and (inv:GetContainerCountMax(0) or 0) or 0;
    for i = 1, math.min(max, 80) do
        local it = inv:GetContainerItem(0, i);
        local id = it ~= nil and it.Id or 0;
        if ((id >= 4096 and id <= 4111) or (id >= 4238 and id <= 4245)) then
            counts[id] = (counts[id] or 0) + (it.Count or 0);
        end
    end
    held.counts, held.at = counts, now;
    return counts;
end

function player.has_key_item(id)
    local p = AshitaCore:GetMemoryManager():GetPlayer();
    return p ~= nil and p:HasKeyItem(id) == true;
end

function player.key_item_name(id)
    local name = AshitaCore:GetResourceManager():GetString('keyitems.names', id);
    return (name ~= nil and name ~= '') and name or ('key item %d'):fmt(id);
end

return player;

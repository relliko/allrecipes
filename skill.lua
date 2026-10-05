--[[
* allrecipes - skill
* Your craft skill to the tenth. The server keeps skill in tenths but only tells the client whole
* levels (0x062). Every skill-up it does tell, though, in a battle message (0x029, synthutils.cpp):
*   38  SkillGain     "<skill> skill rises 0.X points"   (param the skill, value the tenths)
*   53  SkillLevelUp  "<skill> skill reaches level X"    (sent when a gain crosses a level)
*   310 SkillDrop     "<skill> skill drops 0.X points"   (another craft over the specialization cap)
* From those and the whole level, the tenths are kept as a range, lo..hi, that each skill-up
* narrows: a gain moves it, reaching a level (or not) cuts it to that level. It's exact once a
* level is crossed by a 0.1 gain, or when you're capped (the server stops a gain at the cap).
* The range is kept per character, in the settings. Only read from packets the game gets anyway.
--]]

local skill = {
    pending = { },   -- [craft] = when its last message came (os.clock)
    seen    = { },   -- [craft] = { level, since } the client's whole level and since when
    after   = nil,   -- the craft whose skill just dropped (its level message is wrong, see below)
    dirty   = false, -- a range changed and should be saved
};

skill.GAIN, skill.LEVEL, skill.DROP = 38, 53, 310;
local SETTLE = 3;    -- seconds for the client's whole level to catch up with a message

-- Skill ids 49 (woodworking) to 56 (cooking) are the crafts 1 to 8.
local function craft_of(id)
    return (id >= 49 and id <= 56) and id - 48 or nil;
end

local function byte_at(s, o) return s:byte(o + 1) or 0; end
local function u16(s, o) return byte_at(s, o) + byte_at(s, o + 1) * 256; end
local function u32(s, o) return u16(s, o) + u16(s, o + 2) * 65536; end

-- The range a whole level allows: capped, the skill is the cap exactly.
local function span(level, capped)
    return level * 10, capped and level * 10 or level * 10 + 9;
end

local function set(t, c, lo, hi)
    if (t.lo[c] ~= lo or t.hi[c] ~= hi) then
        t.lo[c], t.hi[c], skill.dirty = lo, hi, true;
    end
end

-- Start a craft's range from its whole level, if it has none.
local function start(t, c, you)
    if ((t.lo[c] or -1) < 0 or (t.hi[c] or -1) < t.lo[c]) then
        set(t, c, span(you.level[c], you.capped[c]));
    end
end

-- Forget the timing (a new character).
function skill.reset()
    skill.pending, skill.seen, skill.after = { }, { }, nil;
end

--[[
* A 0x029 packet (its data as a string). me is your server id; t the character's ranges
* ({ lo = { }, hi = { } }, in tenths, -1 not known); you the whole levels as player.you gives.
* True when it was one of your craft messages.
--]]
function skill.packet(t, data, me, you, now)
    if (type(data) ~= 'string' or #data < 0x1A or me == nil or me == 0) then
        return false;
    end
    local actor, target = u32(data, 0x04), u32(data, 0x08);
    local c, value, msg = craft_of(u32(data, 0x0C)), u32(data, 0x10), u16(data, 0x18);
    if (actor ~= me or target ~= me or c == nil or (msg ~= skill.GAIN and msg ~= skill.LEVEL and msg ~= skill.DROP)) then
        return false;
    end
    start(t, c, you);
    local lo, hi = t.lo[c], t.hi[c];
    if (msg == skill.GAIN) then
        local cap = (you.rank[c] + 1) * 100;   -- a gain stops at the cap (synthutils.cpp)
        set(t, c, math.min(lo + value, cap), math.min(hi + value, cap));
    elseif (msg == skill.DROP) then
        set(t, c, math.max(0, lo - value), math.max(0, hi - value));
    elseif (skill.after ~= c) then
        -- Reached a level: the skill is in it. (After a drop the server works the level out
        -- from the skill less the drop twice, so that one's left to the client's level.)
        local a, b = span(value, false);
        if (math.max(lo, a) <= math.min(hi, b)) then
            set(t, c, math.max(lo, a), math.min(hi, b));
        else
            set(t, c, a, b);
        end
    end
    skill.after = msg == skill.DROP and c or nil;
    skill.pending[c] = now;
    return true;
end

--[[
* Each frame: hold the ranges to the client's whole levels. Right after a message the client
* may not have its new level yet, so a craft waits SETTLE seconds from its last one; and a range
* the level rules out entirely is only started over once the level has held that long (the
* client reads 0 for everything at the character screen, which is skipped).
--]]
function skill.sync(t, you, now)
    local any = false;
    for c = 1, 8 do
        any = any or you.level[c] > 0 or you.rank[c] > 0;
    end
    if (not any) then
        return;
    end
    for c = 1, 8 do
        local level = you.level[c];
        local seen = skill.seen[c];
        if (seen == nil or seen[1] ~= level) then
            seen = { level, now };
            skill.seen[c] = seen;
        end
        if ((t.lo[c] or -1) < 0 or (t.hi[c] or -1) < t.lo[c]) then
            start(t, c, you);
        elseif (now - (skill.pending[c] or -math.huge) >= SETTLE) then
            local a, b = span(level, you.capped[c]);
            local lo, hi = math.max(t.lo[c], a), math.min(t.hi[c], b);
            if (lo <= hi) then
                set(t, c, lo, hi);
            elseif (now - seen[2] >= SETTLE) then
                set(t, c, a, b);
            end
        end
    end
end

-- A craft's skill in tenths, lo and hi, within its whole level.
function skill.range(t, c, you)
    local a, b = span(you.level[c], you.capped[c]);
    local lo, hi = math.max(t.lo[c] or -1, a), math.min(t.hi[c] or -1, b);
    if ((t.lo[c] or -1) < 0 or lo > hi) then
        return a, b;
    end
    return lo, hi;
end

-- Tenths as text: 224 is '22.4'.
function skill.fmt(v)
    return ('%d.%d'):format(math.floor(v / 10), v % 10);
end

-- What the range says: 'exact', 'some' (narrowed) or 'none' (only the whole level).
function skill.known(lo, hi)
    return lo == hi and 'exact' or (hi - lo < 9) and 'some' or 'none';
end

return skill;

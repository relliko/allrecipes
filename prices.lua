--[[
* allrecipes - prices
* The prices you've typed in, in gil for one of an item. Every recipe that uses an item shares its
* price, and so does every character: they're kept in <Ashita>/config/addons/allrecipes/prices.lua.
* Price lists can be shared as JSON with /ar prices export and /ar prices import.
* Where you haven't typed one, prices.view falls back to what the AH history says (ahhistory.lua).
--]]

local json = require('json');

local prices = {
    list     = { },    -- [item id] = gil each
    version  = 0,      -- goes up with every change, so views know to work things out again
    dirty    = false,  -- changed since the last save
    saved    = 0,      -- when it was last saved (os.clock)
    error    = nil,    -- why the file didn't load
    moved    = nil,    -- where a file that wasn't ours was moved to
    estimate = nil,    -- function (id): gil each from the AH history, or nil
};

local SAVE_EVERY = 5;
local MAX_PRICE = 999999999;

-- Your price for an item, or else the AH history's: what the odds are worked out with.
prices.view = setmetatable({ }, { __index = function (_, id)
    local v = prices.list[id];
    if (v ~= nil) then
        return v;
    end
    return prices.estimate ~= nil and prices.estimate(id) or nil;
end });

-- Something a price depends on changed (the AH history).
function prices.touch()
    prices.version = prices.version + 1;
end

function prices.dir()
    return (('%s/config/addons/allrecipes'):fmt(AshitaCore:GetInstallPath()):gsub('\\', '/'));
end

local function file()
    return prices.dir() .. '/prices.lua';
end

-- A path for import/export: as given when absolute, otherwise in the addon's config folder.
function prices.path(name)
    if (name:match('^%a:[\\/]') or name:match('^[\\/]')) then
        return name;
    end
    return prices.dir() .. '/' .. name;
end

-- A price as a whole number of gil, or nil when it isn't one.
local function gil(v)
    v = tonumber(v);
    if (v == nil or v ~= v or v < 0 or v > MAX_PRICE) then
        return nil;
    end
    return math.floor(v);
end

-- Reads one of allrecipes' saved data files: the table it returns, or nil and why it couldn't be read.
-- A file there that isn't one of ours (it doesn't start with our header, like a copy of the addon's
-- own code from unzipping into the config folder) is moved aside to <name>.bak and read as empty;
-- moved is then the .bak's path, so the player can be told.
function prices.read(path)
    local f = io.open(path, 'r');
    if (f == nil) then
        return nil;
    end
    local first = f:read('*l') or '';
    f:close();
    if (not first:match('^%-%- allrecipes:')) then
        local bak = path .. '.bak';
        os.remove(bak);
        os.rename(path, bak);
        return nil, nil, bak;
    end
    local chunk, why = loadfile(path);
    if (chunk == nil) then
        return nil, tostring(why);
    end
    setfenv(chunk, { });  -- data only
    local ok, t = pcall(chunk);
    if (not ok) then
        return nil, tostring(t);
    end
    if (type(t) ~= 'table') then
        return nil, path:match('[^/\\]+$') .. ' did not return a table';
    end
    return t;
end

function prices.load()
    prices.list, prices.dirty, prices.error = { }, false, nil;
    prices.version = prices.version + 1;
    local t, why, moved = prices.read(file());
    prices.moved = moved;
    if (t == nil) then
        prices.error = why;
        return;
    end
    for id, v in pairs(t) do
        id, v = tonumber(id), gil(v);
        if (id ~= nil and v ~= nil) then
            prices.list[id] = v;
        end
    end
end

function prices.save()
    if (not ashita.fs.exists(prices.dir())) then
        ashita.fs.create_dir(prices.dir());
    end
    local ids = { };
    for id in pairs(prices.list) do
        ids[#ids + 1] = id;
    end
    table.sort(ids);
    local lines = { '-- allrecipes: the prices you typed in, [item id] = gil for one. Shared by every character.', 'return {' };
    for _, id in ipairs(ids) do
        lines[#lines + 1] = ('[%d]=%d,'):fmt(id, prices.list[id]);
    end
    lines[#lines + 1] = '}';
    local f = io.open(file(), 'w');
    if (f == nil) then
        return false;
    end
    f:write(table.concat(lines, '\n') .. '\n');
    f:close();
    prices.dirty, prices.saved = false, os.clock();
    return true;
end

function prices.get(id)
    return prices.list[id];
end

-- Set an item's price, or clear it with nil.
function prices.set(id, v)
    v = v ~= nil and gil(v) or nil;
    if (prices.list[id] ~= v) then
        prices.list[id], prices.dirty = v, true;
        prices.version = prices.version + 1;
    end
end

-- Save what changed, at most every few seconds (called each frame).
function prices.tick(now)
    if (prices.dirty and now - prices.saved >= SAVE_EVERY) then
        prices.save();
    end
end

--[[
* Merge a JSON price list: an object of item id to price ({"4098": 90}) or an array of objects
* with an id (itemId, id or item_id) and a price (price or value). Returns how many prices were
* added, changed and skipped, or nil and why.
--]]
function prices.import(name)
    local f = io.open(prices.path(name), 'r');
    if (f == nil) then
        return nil, 'no file ' .. prices.path(name);
    end
    local text = f:read('*a');
    f:close();
    local ok, t = pcall(json.decode, text);
    if (not ok or type(t) ~= 'table') then
        return nil, 'not a JSON object or array';
    end
    local pairs_in = { };
    if (#t > 0) then
        for _, e in ipairs(t) do
            if (type(e) == 'table') then
                pairs_in[#pairs_in + 1] = { e.itemId or e.id or e.item_id, e.price or e.value };
            else
                pairs_in[#pairs_in + 1] = { };
            end
        end
    else
        for k, v in pairs(t) do
            pairs_in[#pairs_in + 1] = { k, v };
        end
    end
    local added, changed, skipped = 0, 0, 0;
    for _, kv in ipairs(pairs_in) do
        local id, v = tonumber(kv[1]), gil(kv[2]);
        if (id == nil or id ~= math.floor(id) or id <= 0 or id > 65535 or v == nil) then
            skipped = skipped + 1;
        elseif (prices.list[id] == nil) then
            prices.list[id], added = v, added + 1;
        elseif (prices.list[id] ~= v) then
            prices.list[id], changed = v, changed + 1;
        end
    end
    if (added + changed > 0) then
        prices.dirty = true;
        prices.version = prices.version + 1;
        prices.save();
    end
    return added, changed, skipped;
end

-- Write every price as a JSON object of item id to price. Returns how many, or nil and why.
function prices.export(name)
    local ids = { };
    for id in pairs(prices.list) do
        ids[#ids + 1] = id;
    end
    table.sort(ids);
    local rows = { };
    for _, id in ipairs(ids) do
        rows[#rows + 1] = ('  "%d": %d'):fmt(id, prices.list[id]);
    end
    if (not ashita.fs.exists(prices.dir())) then
        ashita.fs.create_dir(prices.dir());
    end
    local f = io.open(prices.path(name), 'w');
    if (f == nil) then
        return nil, 'can\'t write ' .. prices.path(name);
    end
    f:write('{\n' .. table.concat(rows, ',\n') .. (#rows > 0 and '\n' or '') .. '}\n');
    f:close();
    return #ids;
end

return prices;

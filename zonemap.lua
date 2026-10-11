--[[
* allrecipes - zonemap
* The game's own zone maps, for the HELM tabs: which picture each zone and floor has
* (data/maps.lua, from the game's map table; tools/gen_maps.py), the picture itself read from the
* game's DAT files and made into a texture, and where a world point falls on it. The same as
* facelift's map window (its core/zonemap.lua).
*
* A world point (x, z: the ground axes; Phoenix's x and z, Ashita's X and Y) is at picture pixel
* (int(x * s / 5 + 0.5) - offset x, -int(z * s / 5 + 0.5) - offset y), s = |scale|. The picture is
* DAT 0x14C0 + picture (kinds & 0xF = 0), 0xD02F + (1) or 0xD417 + (2): one 512 x 512 image,
* 8-bit with a palette (flag 0xB1/0x91, rows bottom-up) or DXT3 (0xA1).
*
* Which floor a point is on is the game's own lookup (a ray down the zone's collision, map.floor
* 0x1811D0), so it can only be asked in the zone you're in. The answers are kept in
* config/addons/allrecipes/floors.lua, so a zone's points sort onto its floors once you've been
* there. Nothing is sent to the server.
--]]

local ffi = require('ffi');

local zonemap = {
    maps  = nil,   -- data/maps.lua
    error = nil,
    why   = nil,   -- why the last picture couldn't be made
    floors = { },  -- ['zone:x:z'] = floor, the game's answers (kept)
    dirty = false,
};

local FILE_BASE = { [0] = 0x14C0, [1] = 0xD02F, [2] = 0xD417 };
local SIZE = 512;

function zonemap.load()
    local f, why = loadfile(('%s\\data\\maps.lua'):fmt(addon.path));
    if (f == nil) then
        zonemap.error = tostring(why);
        return false;
    end
    setfenv(f, { });
    local ok, t = pcall(f);
    if (not ok or type(t) ~= 'table') then
        zonemap.error = ok and 'data/maps.lua did not return a table' or tostring(t);
        return false;
    end
    zonemap.maps, zonemap.error = t, nil;
    zonemap.read_floors();
    return true;
end

-- A zone's maps: { { floor, kinds, scale, key, pic, ox, oy } as r.floor ... }, in the game's order.
function zonemap.of(zone)
    local out = { };
    for _, m in ipairs((zonemap.maps or { })[zone] or { }) do
        if (m[4] >= 0) then
            out[#out + 1] = { floor = m[1], kinds = m[2], scale = m[3], key = m[4], pic = m[5], ox = m[6], oy = m[7] };
        end
    end
    return out;
end

-- World point (x, z) on map r's picture (0-512).
function zonemap.to_map(r, x, z)
    local k = math.abs(r.scale) / 5;
    return math.floor(x * k + 0.5) - r.ox, -math.floor(z * k + 0.5) - r.oy;
end

local function file_of(r)
    local b = FILE_BASE[r.kinds % 16];
    return b ~= nil and b + r.pic or nil;
end

-- The game's folder (where FFXiMain.dll is), ending in a slash, or nil.
local game_dir = nil;
local function dir()
    if (zonemap.game_dir ~= nil) then
        return zonemap.game_dir;  -- (set by the tests)
    end
    if (game_dir == nil) then
        local ok, d = pcall(function ()
            pcall(ffi.cdef, [[
                void* __stdcall GetModuleHandleA(const char* name);
                uint32_t __stdcall GetModuleFileNameA(void* module, char* out, uint32_t size);
            ]]);
            local m = ffi.C.GetModuleHandleA('FFXiMain.dll');
            if (m == nil) then
                return nil;
            end
            local buf = ffi.new('char[520]');
            local n = ffi.C.GetModuleFileNameA(m, buf, 520);
            if (n == 0 or n >= 520) then
                return nil;
            end
            return (ffi.string(buf, n):gsub('[^\\/]*$', ''));
        end);
        game_dir = (ok and d) or false;
    end
    return game_dir or nil;
end
zonemap.dir = dir;

local function read(path)
    local f = io.open(path, 'rb');
    if (f == nil) then
        return nil;
    end
    local s = f:read('*a');
    f:close();
    return s;
end

-- A DAT's path: VTABLE.DAT says which ROM it's in (1 the main one, n ROMn), and that ROM's
-- FTABLE gives its folder * 128 + file.
local tables = { };
local function rom_path(id)
    local d = dir();
    if (d == nil) then
        return nil;
    end
    tables.v = tables.v or read(d .. 'VTABLE.DAT');
    local v = tables.v;
    if (v == nil or #v <= id) then
        return nil;
    end
    local rom = v:byte(id + 1);
    if (rom == 0) then
        return nil;
    end
    local key = 'f' .. rom;
    if (tables[key] == nil) then
        tables[key] = (rom == 1 and read(d .. 'FTABLE.DAT') or read(('%sROM%d/FTABLE%d.DAT'):fmt(d, rom, rom))) or false;
    end
    local f = tables[key];
    if (not f or #f < id * 2 + 2) then
        return nil;
    end
    local e = f:byte(id * 2 + 1) + f:byte(id * 2 + 2) * 256;
    local folder = rom == 1 and 'ROM' or ('ROM%d'):fmt(rom);
    return ('%s%s/%d/%d.DAT'):fmt(d, folder, bit.rshift(e, 7), bit.band(e, 0x7F));
end
zonemap.rom_path = rom_path;

-- The 128-byte DDS header of a 32-bit BGRA w x h image.
local function header(buf, w, h)
    local function put(o, v)
        buf[o], buf[o + 1], buf[o + 2], buf[o + 3] = v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256;
    end
    for i = 0, 127 do
        buf[i] = 0;
    end
    buf[0], buf[1], buf[2], buf[3] = 0x44, 0x44, 0x53, 0x20;
    put(4, 124); put(8, 0x100F); put(12, h); put(16, w); put(20, w * 4);
    put(76, 32); put(80, 0x41); put(88, 32);
    put(92, 0x00FF0000); put(96, 0x0000FF00); put(100, 0x000000FF); put(104, 0xFF000000);
    put(108, 0x1000);
end

-- Map r's picture as a DDS file in memory, or nil and why.
function zonemap.picture(r)
    local id = file_of(r);
    local path = id ~= nil and rom_path(id) or nil;
    if (path == nil) then
        return nil, 'no file for the map';
    end
    local s = read(path);
    if (s == nil) then
        return nil, 'can\'t read ' .. path;
    end
    -- The first image resource (type 0x20). Each starts with a name (4) and a dword with the type
    -- in its low 7 bits and its size / 16 in the next 19.
    local o = 0;
    while (o + 16 <= #s) do
        local h = s:byte(o + 5) + s:byte(o + 6) * 256 + s:byte(o + 7) * 65536 + s:byte(o + 8) * 16777216;
        local typ, size = h % 128, math.floor(h / 128) % 0x80000 * 16;
        if (typ == 0x20) then
            break;
        end
        if (size <= 0) then
            return nil, 'no picture in ' .. path;
        end
        o = o + size;
    end
    local p = o + 16;
    if (p + 60 > #s) then
        return nil, 'no picture in ' .. path;
    end
    local src = ffi.cast('const uint8_t*', s);
    local flag = src[p];
    local function u32(at) return src[at] + src[at + 1] * 256 + src[at + 2] * 65536 + src[at + 3] * 16777216; end
    local w, h = u32(p + 21), u32(p + 25);
    if (w ~= SIZE or h ~= SIZE) then
        return nil, 'the picture isn\'t 512 x 512';
    end
    local q = p + 17 + 40;
    local buf = ffi.new('uint8_t[?]', 128 + w * h * 4);
    header(buf, w, h);
    if ((flag == 0xB1 or flag == 0x91) and q + 1024 + w * h <= #s) then
        local pal, px = q, q + 1024;
        for y = 0, h - 1 do
            local from = px + (h - 1 - y) * w;
            for x = 0, w - 1 do
                local c = pal + src[from + x] * 4;
                local at = 128 + (y * w + x) * 4;
                buf[at], buf[at + 1], buf[at + 2], buf[at + 3] = src[c], src[c + 1], src[c + 2], 255;
            end
        end
    elseif (flag == 0xA1 and s:sub(q + 1, q + 4) == '3TXD' and q + 12 + w * h <= #s) then
        local blocks = q + 12;
        local c = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } };
        local function rgb565(v, t)
            local r5, g6, b5 = bit.rshift(v, 11), bit.band(bit.rshift(v, 5), 63), bit.band(v, 31);
            t[1], t[2], t[3] = r5 * 8 + bit.rshift(r5, 2), g6 * 4 + bit.rshift(g6, 4), b5 * 8 + bit.rshift(b5, 2);
        end
        local n = 0;
        for by = 0, h - 4, 4 do
            for bx = 0, w - 4, 4 do
                local b = blocks + n * 16;
                n = n + 1;
                rgb565(src[b + 8] + src[b + 9] * 256, c[1]);
                rgb565(src[b + 10] + src[b + 11] * 256, c[2]);
                for i = 1, 3 do
                    c[3][i] = math.floor((2 * c[1][i] + c[2][i]) / 3);
                    c[4][i] = math.floor((c[1][i] + 2 * c[2][i]) / 3);
                end
                local idx = src[b + 12] + src[b + 13] * 256 + src[b + 14] * 65536 + src[b + 15] * 16777216;
                for i = 0, 15 do
                    local col = c[bit.band(bit.rshift(idx, i * 2), 3) + 1];
                    local at = 128 + ((by + bit.rshift(i, 2)) * w + bx + bit.band(i, 3)) * 4;
                    buf[at], buf[at + 1], buf[at + 2], buf[at + 3] = col[3], col[2], col[1], 255;
                end
            end
        end
    else
        return nil, ('the picture\'s format (0x%02X) isn\'t one allrecipes reads'):fmt(flag);
    end
    return ffi.string(buf, 128 + w * h * 4);
end

-- A texture from a DDS file in memory, on the game's device, or nil.
local function make(dds)
    local d3d = require('d3d8');
    local C = ffi.C;
    local data = ffi.new('uint8_t[?]', #dds);
    ffi.copy(data, dds, #dds);
    local ptr = ffi.new('IDirect3DTexture8*[1]');
    if (C.D3DXCreateTextureFromFileInMemoryEx(d3d.get_device(), data, #dds, 0xFFFFFFFF, 0xFFFFFFFF, 1, 0,
            C.D3DFMT_A8R8G8B8, C.D3DPOOL_MANAGED, 1, 1, 0, nil, nil, ptr) ~= C.S_OK) then
        return nil;
    end
    return d3d.gc_safe_release(ffi.cast('IDirect3DTexture8*', ptr[0]));
end

local made, keep, order = { }, { }, { };  -- [file id] = ImGui texture or false; the textures; newest last
local KEEP = 6;

-- Map r's picture as an ImGui texture, or nil (zonemap.why says why).
function zonemap.texture(r)
    local id = file_of(r);
    if (id == nil) then
        zonemap.why = 'no file for the map';
        return nil;
    end
    local t = made[id];
    if (t == nil) then
        local dds, why = zonemap.picture(r);
        local tex = nil;
        if (dds ~= nil) then
            local ok, x = pcall(make, dds);
            tex = ok and x or nil;
            why = tex == nil and 'the texture couldn\'t be made' or nil;
        end
        zonemap.why = why;
        if (tex ~= nil) then
            keep[id] = tex;
            t = tonumber(ffi.cast('uint32_t', tex));
            order[#order + 1] = id;
            if (#order > KEEP) then
                local old = table.remove(order, 1);
                made[old], keep[old] = nil, nil;
            end
        else
            t = false;
        end
        made[id] = t;
    end
    return t or nil;
end

function zonemap.unload()
    made, keep, order = { }, { }, { };
end

--[[
* Floors. The game's lookup, found by pattern (facelift's core/sigdefs: map.floor and
* ray.renderer); nil when it isn't found or you're not in the zone.
--]]
local floor_fn, renderer_slot = nil, nil;
local function lookup()
    if (floor_fn == nil) then
        local a = ashita.memory.find('FFXiMain.dll', 0, '8B542408568D4424108BF18B4C2410508B44240C68000020415152508BCEE8', 0, 0) or 0;
        local r = ashita.memory.find('FFXiMain.dll', 0, '8B0D????????8D94248C0000008D6F44528D4424605550E8????????84C07517', 2, 0) or 0;
        if (a == 0 or r == 0) then
            floor_fn = false;
        else
            floor_fn = ffi.cast('uint32_t(__thiscall*)(uintptr_t, float, float, float)', a);
            renderer_slot = ashita.memory.read_uint32(r);
        end
    end
    return floor_fn or nil;
end

-- The floor under a point (Phoenix's x, height y, z) in the zone you're in, or nil.
local function ask(x, y, z)
    local f = lookup();
    if (f == nil or renderer_slot == nil or renderer_slot == 0) then
        return nil;
    end
    local rg = ashita.memory.read_uint32(renderer_slot);
    if (rg == nil or rg == 0) then
        return nil;
    end
    local ok, v = pcall(f, rg, x, y, z);
    v = ok and tonumber(v) or nil;
    return (v ~= nil and v < 128) and v or nil;
end

local function key(zone, p)
    return ('%d:%d:%d'):fmt(zone, math.floor(p[1] + 0.5), math.floor(p[3] + 0.5));
end

-- The floor a point is on: kept, or asked now when you're in its zone (`here`); nil unknown.
local asked = { };  -- [key] = true: asked this session (a point the game has no floor for isn't asked again)
function zonemap.floor_of(zone, p, here)
    local k = key(zone, p);
    local f = zonemap.floors[k];
    if (f == nil and here and not asked[k]) then
        asked[k] = true;
        -- (From half a yalm over the point: the game's height grows downwards.)
        f = ask(p[1], p[2] - 0.5, p[3]);
        if (f ~= nil) then
            zonemap.floors[k], zonemap.dirty = f, true;
        end
    end
    return f;
end

-- Where you are, and your zone: x, z (the ground axes), zone; nil at the character screen.
function zonemap.you()
    local mm = AshitaCore:GetMemoryManager();
    local party, ent = mm:GetParty(), mm:GetEntity();
    if (party == nil or ent == nil) then
        return nil;
    end
    local zone = party:GetMemberZone(0) or 0;
    local idx = party:GetMemberTargetIndex(0) or 0;
    if (zone == 0 or idx == 0) then
        return nil;
    end
    return ent:GetLocalPositionX(idx), ent:GetLocalPositionY(idx), zone;
end

local function floors_path()
    return ('%s/config/addons/allrecipes/floors.lua'):fmt(AshitaCore:GetInstallPath()):gsub('\\', '/');
end

function zonemap.read_floors()
    zonemap.floors = { };
    local f = loadfile(floors_path());
    if (f ~= nil) then
        setfenv(f, { });
        local ok, t = pcall(f);
        if (ok and type(t) == 'table') then
            for k, v in pairs(t) do
                if (type(k) == 'string' and type(v) == 'number') then
                    zonemap.floors[k] = v;
                end
            end
        end
    end
end

function zonemap.save_floors()
    if (not zonemap.dirty) then
        return;
    end
    local path = floors_path();
    ashita.fs.create_directory(path:gsub('/[^/]*$', ''));
    local f = io.open(path, 'w');
    if (f == nil) then
        return;
    end
    local keys = { };
    for k in pairs(zonemap.floors) do
        keys[#keys + 1] = k;
    end
    table.sort(keys);
    f:write('-- allrecipes: the floor of each HELM point, from the game, as you\'ve visited the zones.\nreturn {\n');
    for _, k in ipairs(keys) do
        f:write(('    [%q] = %d,\n'):fmt(k, zonemap.floors[k]));
    end
    f:write('};\n');
    f:close();
    zonemap.dirty = false;
end

return zonemap;

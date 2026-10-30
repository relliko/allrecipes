--[[
* allrecipes - ahhistory
* Keeps the AH price history of every item you look at on the auction house, so its prices can be
* used without typing them in.
*
* The history comes from the search server (Phoenix src/search/packets/auction_history.cpp) over
* its own connection, so no packet event sees it. The game keeps the packet in its memory once it
* has decrypted it, though, and its layout is known:
*   0x08 u16 length (0x20 + 40 a sale), 0x0A 0x80, 0x0B 0x85, 0x10 and 0x18 the item, 0x1A how
*   many are on sale, then up to 10 sales of 40 bytes: price (u32), date (u32, unix), two names.
* The AH item lists come the same way (auction_list.cpp): 0x0B 0x95, 0x0E how many items, and
* from 0x18 10 bytes an item: id (u16), singles on sale (u32), stacks on sale (u32). They say
* whether a history was for singles or stacks: the history's count on sale matches one of them.
*
* When you open the auction house (0x04C Open from the server), the addon looks through the
* game's memory for either layout (an AH list arrives as soon as you browse a category), FFXiMain's
* own data first, until it finds where the game keeps these packets, and then only watches those
* places. It only ever reads, and always through
* ReadProcessMemory on its own process, which fails cleanly on memory the game has freed instead
* of crashing the game (reading such memory directly takes the addon down with it).
--]]

require('common');
local prices = require('prices');

local ah = {
    enabled = true,
    stacks  = nil,     -- [item id] = stack size on Phoenix (data/stacks.lua); nil: ask the game
    npc     = nil,     -- [item id] = what an NPC pays (data/npc.lua), to guess singles from stacks
    prefer  = 'single',-- where an item has both, which its price comes from ('single' or 'stack')
    data    = { },     -- [item id] = { at = when, single = { { price, date }, ... }, stack = { ... },
                       --   unknown = { ... }, use = 'single' or 'stack' when you picked one for it }
    counts  = { },     -- [item id] = { single, stack }: on sale, from the last AH list that had it
    spots   = { },     -- where packets were found (the address of their 0x0A byte)
    seen    = { },     -- [spot] = what was there last time
    armed   = 0,       -- watch until then (os.clock): you're at the auction house
    scans   = 0,       -- looks through memory this visit
    next_scan = 0,
    last    = nil,     -- the last history kept: { id, kind, n }
    dirty   = false,
    saved   = 0,
    error   = nil,
};

-- Bytes 0x0A-0x17 of a history packet: 80 85 ?? ?? 00 00 <id> 00 00 00 00 00 00 (a Lua pattern).
ah.PATTERN = '\128\133..%z%z..%z%z%z%z%z%z';
-- Bytes 0x0A-0x17 of the last (or only) packet of an AH list: 80 95 00 00 <count> 00 x8.
ah.LIST_PATTERN = '\128\149%z%z..%z%z%z%z%z%z%z%z';
local CHUNK   = 0x100000;  -- memory is copied and searched this much at a time
local OVERLAP = 0x20;      -- chunks overlap so a packet across a boundary isn't missed
local SPAN    = 2 + 0x16 + 40 * 10;  -- the most a packet takes from its 0x08 byte
-- What's looked for: the first two bytes, found plainly (fast), then the whole pattern there.
local LOOK_FOR = { { '\128\133', '^' .. ah.PATTERN }, { '\128\149', '^' .. ah.LIST_PATTERN } };
local SLICE   = 0x40000;               -- read at a time while looking in the background
local FRAME_BUDGET = 0.0005;           -- seconds of looking a frame, so it doesn't cost frame rate
local ARM_FOR     = 600;   -- seconds after the auction house opens
local POLL_EVERY  = 0.2;
local SCAN_EVERY  = 5;
local SCANS       = 30;    -- at most, a visit (looking goes on in the background)
local RESCAN_EVERY = 10;   -- while watching, look again this often: the game moves where it keeps them
local MAX_SPOTS   = 48;    -- watched at most; the oldest go first
local SAVE_EVERY  = 10;
local KEEP_DAYS   = 180;   -- sales older than this aren't kept

local win = nil;
-- The Windows calls this uses, declared once.
local function kernel()
    if (win == nil) then
        local ffi = require('ffi');
        pcall(ffi.cdef, [[
            typedef struct { void* BaseAddress; void* AllocationBase; uint32_t AllocationProtect; size_t RegionSize;
                             uint32_t State; uint32_t Protect; uint32_t Type; } ar_mbi_t;
            size_t __stdcall VirtualQuery(const void* address, ar_mbi_t* info, size_t length);
            void* __stdcall GetCurrentProcess(void);
            int __stdcall ReadProcessMemory(void* process, const void* address, void* buffer, size_t size, size_t* read);
            int __stdcall QueryPerformanceCounter(int64_t* count);
            int __stdcall QueryPerformanceFrequency(int64_t* freq);
            typedef struct { uint32_t attributes; uint32_t created[2]; uint32_t accessed[2]; uint32_t written[2];
                             uint32_t size_high; uint32_t size_low; } ar_fileinfo_t;
            int __stdcall GetFileAttributesExA(const char* name, int level, ar_fileinfo_t* info);
        ]]);
        win = { ffi = ffi, buf = ffi.new('uint8_t[?]', CHUNK), got = ffi.new('size_t[1]'), process = ffi.C.GetCurrentProcess(),
                qpc = ffi.new('int64_t[1]') };
        ffi.C.QueryPerformanceFrequency(win.qpc);
        win.freq = tonumber(win.qpc[0]);
    end
    return win;
end

-- Seconds, finely (os.clock only goes in milliseconds on Windows).
function ah.timer()
    local k = kernel();
    k.ffi.C.QueryPerformanceCounter(k.qpc);
    return tonumber(k.qpc[0]) / k.freq;
end

--[[
* n bytes of the game's memory at addr as a string, or nil when any of it can't be read. Never
* touches the memory itself, so memory the game has just freed can't crash it.
--]]
function ah.read(addr, n)
    if (n <= 0 or n > CHUNK) then
        return nil;
    end
    local k = kernel();
    local ffi = k.ffi;
    if (ffi.C.ReadProcessMemory(k.process, ffi.cast('const void*', addr), k.buf, n, k.got) == 0 or tonumber(k.got[0]) ~= n) then
        return nil;
    end
    return ffi.string(k.buf, n);
end

--[[
* A packet at spot m (its 0x0A byte), as the bytes from its 0x08 byte on: the header, then as
* much more as its length says. nil when it can't be read.
--]]
local function snapshot(m)
    local head = ah.read(m - 2, 2 + 0x18);
    if (head == nil) then
        return nil;
    end
    local len = head:byte(1) + head:byte(2) * 256;
    local want = math.min(SPAN, 2 + math.max(0, len - 0x0A));
    if (want <= #head) then
        return head;
    end
    return ah.read(m - 2, want) or head;
end

-- Numbers in a snapshot, at offsets from the spot (its 0x0A byte).
local function b(s, o) return s:byte(o + 3) or 0; end
local function w(s, o) return b(s, o) + b(s, o + 1) * 256; end
local function d(s, o) return w(s, o) + w(s, o + 2) * 65536; end

--[[
* Where to look, image data first: { { base, size }, ... } of committed read/write memory.
--]]
function ah.regions()
    local k = kernel();
    local ffi = k.ffi;
    local image, private = { }, { };
    local mbi = ffi.new('ar_mbi_t');
    local size = ffi.sizeof(mbi);
    local addr = 0x10000;
    while (addr < 0xFFFE0000) do
        if (ffi.C.VirtualQuery(ffi.cast('const void*', addr), mbi, size) == 0) then
            break;
        end
        local base, len = tonumber(ffi.cast('uintptr_t', mbi.BaseAddress)), tonumber(mbi.RegionSize);
        if (len == 0) then
            break;
        end
        local writable = mbi.Protect == 0x04 or mbi.Protect == 0x40;  -- read/write, execute/read/write
        if (mbi.State == 0x1000 and writable) then                     -- committed, no guard or no-access bits
            if (mbi.Type == 0x1000000) then
                image[#image + 1] = { base, len, image = true };
            elseif (mbi.Type == 0x20000) then
                private[#private + 1] = { base, len };
            end
        end
        addr = base + len;
    end
    for _, r in ipairs(private) do
        image[#image + 1] = r;
    end
    return image;
end

-- A history packet at spot m (its 0x0A byte): { id, amount, sales = { { price, date } } }, or nil.
function ah.history_at(m, s)
    s = s or snapshot(m);
    if (s == nil or b(s, 0) ~= 0x80 or b(s, 1) ~= 0x85) then
        return nil;
    end
    local id = w(s, 0x06);
    if (id == 0 or id ~= w(s, 0x0E)) then
        return nil;
    end
    local len = w(s, -0x02);
    local n = 0;
    if (len ~= 0) then
        if (len < 0x20 or (len - 0x20) % 40 ~= 0) then
            return nil;
        end
        n = (len - 0x20) / 40;
        if (n > 10) then
            return nil;
        end
    end
    if (#s < 2 + 0x16 + 40 * n) then
        return nil;
    end
    local now = os.time();
    local sales = { };
    for i = 0, n - 1 do
        local e = 0x16 + 40 * i;
        local price, date = d(s, e), d(s, e + 4);
        if (price == 0 or price > 999999999 or date < 1000000000 or date > now + 2 * 86400) then
            return nil;
        end
        sales[#sales + 1] = { price, date };
    end
    return { id = id, amount = d(s, 0x10), sales = sales };
end

-- An AH item list at spot m: { { id, single, stack }, ... }, or nil.
function ah.list_at(m, s)
    s = s or snapshot(m);
    if (s == nil) then
        return nil;
    end
    local flags = b(s, 0);
    if (b(s, 1) ~= 0x95 or (flags ~= 0x80 and flags ~= 0x00)) then
        return nil;
    end
    local len = w(s, -0x02);
    if (len < 0x18 or (len - 0x18) % 10 ~= 0 or (len - 0x18) / 10 > 20 or #s < 2 + len - 0x0A) then
        return nil;
    end
    local out = { };
    for i = 0, (len - 0x18) / 10 - 1 do
        local e = 0x0E + 10 * i;
        local id = w(s, e);
        if (id == 0) then
            return nil;
        end
        out[#out + 1] = { id, d(s, e + 2), d(s, e + 6) };
    end
    return out;
end

local function median(sales)
    local p = { };
    for i, s in ipairs(sales) do
        p[i] = s[1];
    end
    table.sort(p);
    local n = #p;
    if (n == 0) then
        return nil;
    end
    return n % 2 == 1 and p[(n + 1) / 2] or (p[n / 2] + p[n / 2 + 1]) / 2;
end
ah.median = median;

-- How many make a stack on Phoenix (its own item table, which unstacks ores, logs and more);
-- the game's item data only when that isn't loaded.
local function stack_size(id)
    if (ah.stacks ~= nil) then
        return ah.stacks[id] or 1;
    end
    local res = AshitaCore:GetResourceManager():GetItemById(id);
    local n = res ~= nil and tonumber(res.StackSize) or 1;
    return (n ~= nil and n > 1) and n or 1;
end
ah.stack_size = stack_size;

--[[
* Whether a history was for singles or stacks: an item that doesn't stack is singles; otherwise
* its count on sale matches the singles or the stacks of the last AH list that had it; failing
* that, its prices are compared with a history already kept (a stack sells for about as many times
* a single as it holds). nil when there's no telling.
--]]
function ah.kind_of(h)
    local size = stack_size(h.id);
    if (size <= 1) then
        return 'single';
    end
    local c = ah.counts[h.id];
    if (c ~= nil) then
        if (h.amount == c[2] and h.amount ~= c[1]) then
            return 'stack';
        elseif (h.amount == c[1] and h.amount ~= c[2]) then
            return 'single';
        end
    end
    local m = median(h.sales);
    local d = ah.data[h.id];
    if (m ~= nil and d ~= nil) then
        local s, t = d.single and median(d.single), d.stack and median(d.stack);
        if (s ~= nil) then
            return m >= s * size / 2 and 'stack' or 'single';
        elseif (t ~= nil) then
            return m <= t / size * 2 and 'single' or 'stack';
        end
    end
    return nil;
end

local function newest(sales)
    local t = 0;
    for _, s in ipairs(sales or { }) do
        t = math.max(t, s[2]);
    end
    return t;
end

-- Keep a history (the newest 10 sales the server sends, less any older than KEEP_DAYS). One older
-- than what's kept (a stale copy left in the game's memory) is passed over.
function ah.keep(h)
    local kind = ah.kind_of(h) or 'unknown';
    local cutoff = os.time() - KEEP_DAYS * 86400;
    local sales = { };
    for _, s in ipairs(h.sales) do
        if (s[2] >= cutoff) then
            sales[#sales + 1] = s;
        end
    end
    local d = ah.data[h.id] or { };
    if (newest(h.sales) < newest(d[kind])) then
        return;
    end
    d[kind], d.at = sales, os.time();
    ah.data[h.id] = d;
    ah.last = { id = h.id, kind = kind, n = #sales };
    ah.dirty = true;
    prices.touch();
end

local function has(d, kind)
    return d ~= nil and d[kind] ~= nil and #d[kind] > 0;
end

--[[
* Whether a history whose kind wasn't known is more likely singles or stacks: by which of the item's
* kept histories its prices are nearer, else by what an NPC pays (a single rarely sells for more
* than 9 times that, a stack rarely for less than 9 singles' worth). nil when there's no telling.
--]]
function ah.guess(id, sales)
    local size = stack_size(id);
    if (size <= 1) then
        return 'single';
    end
    local m = median(sales);
    if (m == nil or m <= 0) then
        return nil;
    end
    local d = ah.data[id];
    local s = has(d, 'single') and median(d.single) or nil;
    local t = has(d, 'stack') and median(d.stack) or nil;
    if (s ~= nil and t ~= nil) then
        return math.abs(math.log(m / s)) <= math.abs(math.log(m / t)) and 'single' or 'stack';
    elseif (s ~= nil) then
        return m >= s * size / 2 and 'stack' or 'single';
    elseif (t ~= nil) then
        return m <= t / size * 2 and 'single' or 'stack';
    end
    local npc = ah.npc ~= nil and tonumber(ah.npc[id]) or nil;
    if (npc ~= nil and npc > 0) then
        return m >= npc * size * 0.75 and 'stack' or 'single';
    end
    return nil;
end

--[[
* An item's histories as they're used: { single = sales, stack = sales, guessed = kind }. A history
* of unknown kind stands in, as its guessed kind, for one the item doesn't have.
--]]
local function used(id)
    local d = ah.data[id];
    if (d == nil) then
        return nil;
    end
    local u = { single = has(d, 'single') and d.single or nil, stack = has(d, 'stack') and d.stack or nil };
    if (has(d, 'unknown')) then
        local g = ah.guess(id, d.unknown);
        if (g ~= nil and u[g] == nil) then
            u[g], u.guessed = d.unknown, g;
        end
    end
    return u;
end

--[[
* Which history an item's price comes from: the one you picked for it, else where it has both the
* one preferred in the settings (ah.prefer), else the one it has. nil without either.
--]]
function ah.basis(id)
    local d = used(id);
    if (d == nil) then
        return nil;
    end
    local picked = ah.data[id].use;
    if (picked ~= nil and has(d, picked)) then
        return picked;
    end
    if (has(d, 'single') and has(d, 'stack')) then
        return ah.prefer == 'stack' and 'stack' or 'single';
    end
    return has(d, 'single') and 'single' or has(d, 'stack') and 'stack' or nil;
end

-- Whether an item has both a singles and a stacks history to choose between.
function ah.both(id)
    local d = used(id);
    return has(d, 'single') and has(d, 'stack');
end

-- Switch an item between its singles and stacks price (when it has both).
function ah.toggle(id)
    if (not ah.both(id)) then
        return false;
    end
    local d = ah.data[id];
    d.use = ah.basis(id) == 'stack' and 'single' or 'stack';
    ah.dirty = true;
    prices.touch();
    return true;
end

--[[
* What one of an item goes for on the AH, from its history (ah.basis): the middle sale of singles,
* or of stacks divided by the stack. nil without a history of either.
--]]
function ah.estimate(id)
    local basis = ah.basis(id);
    if (basis == nil) then
        return nil;
    end
    local m = median(used(id)[basis]);
    if (basis == 'stack') then
        m = m / stack_size(id);
    end
    return math.floor(m + 0.5);
end

-- Lines describing an item's history, for a tooltip.
function ah.describe(id, gil)
    local d = ah.data[id];
    if (d == nil) then
        return nil;
    end
    local lines, now, size = { }, os.time(), stack_size(id);
    local basis, u = ah.basis(id), used(id);
    local function line(label, sales, per, kind)
        if (sales == nil or #sales == 0) then
            return;
        end
        local newest = 0;
        for _, s in ipairs(sales) do
            newest = math.max(newest, s[2]);
        end
        local days = math.floor((now - newest) / 86400);
        local m = median(sales);
        local text = ('%s: middle of %d sales %s'):fmt(label, #sales, gil(m));
        if (per) then
            text = text .. (' (%s each)'):fmt(gil(m / size));
        end
        text = text .. (days <= 0 and ', newest today' or (', newest %d day%s ago'):fmt(days, days == 1 and '' or 's'));
        lines[#lines + 1] = (kind ~= nil and kind == basis) and (text .. '  <- used') or text;
    end
    line('AH singles', d.single, false, 'single');
    line(('AH stacks of %d'):fmt(size), d.stack, true, 'stack');
    if (u.guessed ~= nil) then
        line(('AH, likely %s (unsure)'):fmt(u.guessed == 'stack' and ('stacks of %d'):fmt(size) or 'singles'), d.unknown, u.guessed == 'stack', u.guessed);
    else
        line('AH, singles or stacks unknown', d.unknown, false, nil);
    end
    if (ah.both(id)) then
        lines[#lines + 1] = ('Right-click: use the %s price instead'):fmt(basis == 'stack' and 'singles' or 'stack');
    end
    return #lines > 0 and lines or nil;
end

-- Read what's at the spots now, keeping new histories and lists. Spots that can't be read any
-- more (the game freed them) are dropped.
function ah.poll()
    local still = { };
    for _, m in ipairs(ah.spots) do
        local s = snapshot(m);
        if (s ~= nil) then
            still[#still + 1] = m;
            if (ah.seen[m] ~= s) then
                ah.seen[m] = s;
                local list = ah.list_at(m, s);
                if (list ~= nil) then
                    for _, e in ipairs(list) do
                        ah.counts[e[1]] = { e[2], e[3] };
                    end
                else
                    local h = ah.history_at(m, s);
                    if (h ~= nil) then
                        ah.keep(h);
                    end
                end
            end
        else
            ah.seen[m] = nil;
        end
    end
    ah.spots = still;
end

--[[
* A look through the game's memory for history or AH list packets: { regions, ri (the region
* at), off (how far into it), found, known }. It goes FRAME_BUDGET a frame so the game doesn't stall.
--]]
local function job_start()
    local ok, regions = pcall(ah.regions);
    if (not ok) then
        ah.error = tostring(regions);
        return nil;
    end
    ah.scans = ah.scans + 1;
    return { regions = regions, ri = 1, off = 0, found = { }, known = { } };
end

-- Look through more of memory, until `deadline` (ah.timer) when there is one; true when the look
-- is over. At least one slice is looked through each time.
local function job_step(job, deadline)
    local first = true;
    while (first or deadline == nil or ah.timer() < deadline) do
        first = false;
        local r = job.regions[job.ri];
        if (r == nil or #job.found >= 32) then
            return true;
        end
        local n = math.min(deadline ~= nil and SLICE or CHUNK, r[2] - job.off);
        local chunk = n > 0 and ah.read(r[1] + job.off, n) or nil;
        if (chunk ~= nil) then
            for _, look in ipairs(LOOK_FOR) do
                local at = 1;
                while (true) do
                    local i = chunk:find(look[1], at, true);
                    if (i == nil) then
                        break;
                    end
                    if (chunk:find(look[2], i) ~= nil) then
                        local a = r[1] + job.off + i - 1;
                        if (not job.known[a] and (ah.history_at(a) ~= nil or ah.list_at(a) ~= nil)) then
                            job.known[a] = true;
                            job.found[#job.found + 1] = a;
                        end
                    end
                    at = i + 1;
                end
            end
        end
        if (job.off + n >= r[2]) then
            job.ri, job.off = job.ri + 1, 0;
        else
            job.off = job.off + n - OVERLAP;
        end
    end
    return false;
end

-- Watch what a look found as well as what's watched already (the newest first, MAX_SPOTS at most).
local function job_finish(job)
    if (#job.found > 0) then
        local spots, known = { }, { };
        for _, list in ipairs({ job.found, ah.spots }) do
            for _, m in ipairs(list) do
                if (not known[m] and #spots < MAX_SPOTS) then
                    known[m] = true;
                    spots[#spots + 1] = m;
                end
            end
        end
        for m in pairs(ah.seen) do
            if (not known[m]) then
                ah.seen[m] = nil;
            end
        end
        ah.spots = spots;
        ah.poll();
    end
    return #job.found;
end

--[[
* Look through the game's memory now, all at once, and watch where history packets are. Returns
* how many places were found.
--]]
function ah.scan()
    ah.job = nil;
    local job = job_start();
    if (job == nil) then
        return 0;
    end
    job_step(job, nil);
    return job_finish(job);
end

-- The auction house opened: watch for histories for a while.
function ah.arm(now)
    if (now > ah.armed) then
        ah.scans, ah.next_scan = 0, now + 1;
    end
    ah.armed = now + ARM_FOR;
end

-- Called every frame.
function ah.tick(now)
    if (not ah.enabled or now > ah.armed) then
        return;
    end
    -- Look through memory until something's found, then again every so often while watching it,
    -- as the game may keep the next history somewhere else (a look goes on over many frames).
    if (ah.job == nil and now >= ah.next_scan and (#ah.spots > 0 or ah.scans < SCANS)) then
        ah.job = job_start();
    end
    if (ah.job ~= nil and job_step(ah.job, ah.timer() + FRAME_BUDGET)) then
        local job = ah.job;
        ah.job = nil;
        job_finish(job);
        ah.next_scan = now + (#ah.spots > 0 and RESCAN_EVERY or SCAN_EVERY);
    end
    if (#ah.spots > 0 and now >= (ah.next_poll or 0)) then
        ah.next_poll = now + POLL_EVERY;
        ah.poll();
    end
    if (ah.dirty and now - ah.saved >= SAVE_EVERY) then
        ah.save();
    end
end

local function file()
    return prices.dir() .. '/ahhistory.lua';
end

-- The history file's last write and size as a string (nil when there's none), to notice another
-- addon (ahweb) writing it.
local function stamp(path)
    local k = kernel();
    local info = k.ffi.new('ar_fileinfo_t');
    if (k.ffi.C.GetFileAttributesExA(path, 0, info) == 0) then
        return nil;
    end
    return ('%d.%d.%d'):fmt(info.written[1], info.written[0], info.size_low);
end

-- What the history file holds, as ah.data does, or nil and why.
local function read_file()
    local t, why, moved = prices.read(file());
    if (t == nil) then
        return nil, why, moved;
    end
    local data = { };
    for id, d in pairs(t) do
        id = tonumber(id);
        if (id ~= nil and type(d) == 'table') then
            local keep = { at = tonumber(d.at) or 0, use = (d.use == 'single' or d.use == 'stack') and d.use or nil };
            for _, kind in ipairs({ 'single', 'stack', 'unknown' }) do
                if (type(d[kind]) == 'table') then
                    keep[kind] = { };
                    for _, s in ipairs(d[kind]) do
                        if (type(s) == 'table' and tonumber(s[1]) and tonumber(s[2])) then
                            keep[kind][#keep[kind] + 1] = { tonumber(s[1]), tonumber(s[2]) };
                        end
                    end
                end
            end
            data[id] = keep;
        end
    end
    return data;
end

function ah.load()
    ah.data, ah.error = { }, nil;
    local data, why, moved = read_file();
    ah.moved = moved;
    ah.stamp = stamp(file());
    if (data == nil) then
        ah.error = why;
        return;
    end
    ah.data = data;
    prices.touch();
end

--[[
* Takes in what another addon (ahweb, from the website) wrote to the history file: an item's
* sales on disk replace those kept here when they're newer, and items only there are added.
--]]
function ah.merge_disk()
    ah.stamp = stamp(file());
    local data = read_file();
    if (data == nil) then
        return;
    end
    local changed = false;
    for id, d in pairs(data) do
        local mine = ah.data[id];
        if (mine == nil) then
            ah.data[id], changed = d, true;
        else
            for _, kind in ipairs({ 'single', 'stack', 'unknown' }) do
                if (d[kind] ~= nil and newest(d[kind]) > newest(mine[kind])) then
                    mine[kind], mine.at, changed = d[kind], math.max(mine.at or 0, d.at or 0), true;
                end
            end
            mine.use = mine.use or d.use;
        end
    end
    if (changed) then
        prices.touch();
    end
end

-- Called every frame: reads the history file again when something else has changed it.
function ah.watch(now)
    if (now < (ah.next_watch or 0)) then
        return;
    end
    ah.next_watch = now + 3;
    local st = stamp(file());
    if (st ~= nil and st ~= ah.stamp) then
        ah.merge_disk();
    end
end

function ah.save()
    if (not ashita.fs.exists(prices.dir())) then
        ashita.fs.create_dir(prices.dir());
    end
    -- What another addon wrote since it was read isn't lost.
    local st = stamp(file());
    if (st ~= nil and st ~= ah.stamp) then
        ah.merge_disk();
    end
    local ids = { };
    for id in pairs(ah.data) do
        ids[#ids + 1] = id;
    end
    table.sort(ids);
    local lines = { '-- allrecipes: AH price history read at the auction house, [item id] = { at, single/stack/unknown = { { gil, date } } }.', 'return {' };
    for _, id in ipairs(ids) do
        local d = ah.data[id];
        local parts = { ('at=%d'):fmt(d.at or 0) };
        if (d.use ~= nil) then
            parts[#parts + 1] = ("use='%s'"):fmt(d.use);
        end
        for _, kind in ipairs({ 'single', 'stack', 'unknown' }) do
            if (d[kind] ~= nil) then
                local sales = { };
                for _, s in ipairs(d[kind]) do
                    sales[#sales + 1] = ('{%d,%d}'):fmt(s[1], s[2]);
                end
                parts[#parts + 1] = ('%s={%s}'):fmt(kind, table.concat(sales, ','));
            end
        end
        lines[#lines + 1] = ('[%d]={%s},'):fmt(id, table.concat(parts, ','));
    end
    lines[#lines + 1] = '}';
    local f = io.open(file(), 'w');
    if (f == nil) then
        return false;
    end
    f:write(table.concat(lines, '\n') .. '\n');
    f:close();
    ah.stamp = stamp(file());
    ah.dirty, ah.saved = false, os.clock();
    return true;
end

function ah.count()
    local n = 0;
    for _ in pairs(ah.data) do
        n = n + 1;
    end
    return n;
end

return ah;

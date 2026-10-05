--[[
* allrecipes - ui
* The window, in scouter's look (style.lua): craft chips, your level (to the tenth where it's
* known), the crystals you have, the recipe list and the chosen recipe's materials, odds and
* prices; and a settings window.
--]]

local imgui  = require('imgui');
local odds   = require('odds');
local prices = require('prices');
local player = require('player');
local model  = require('model');
local style  = require('style');
local ah     = require('ahhistory');
local tray   = require('tray');
local skill  = require('skill');
local icons  = require('icons');

local ui = {
    reset   = false,  -- put the window back where it starts next frame
    moved   = false,  -- the window was moved or resized and should be saved
    dirty   = false,  -- a setting changed and should be saved
    bufs    = { },    -- [input] = { text } for the price boxes
    editing = nil,    -- the price box being typed in
    search  = { '' },
    fit     = { },    -- [title] = { width, title cut to fit }
    opened  = nil,    -- the last item opened on ffxiah.com
    note    = nil,    -- a line for the settings window (export done, ...)
};

ui.URL = 'https://www.ffxiah.com/item/%d';

-- How hard a recipe is, hardest first, and what that means for synthesis and desynthesis.
local BANDS = { 'cant', 'zero', 'hard', 'risky', 'good', 'safe', 'hq' };
local LEGEND = {
    [0] = { cant = 'can\'t try', zero = '0%', hard = '10-40%', risky = '50-70%', good = '80-90%', safe = '95%', hq = '95%, better HQ' },
    [1] = { cant = 'can\'t try', zero = '0%', hard = 'under 15%', risky = '15-25%', good = '30-40%', safe = '40%' },
};
local OVER = { '0-10', '11-30', '31-50', '51+' };
local SPLIT = { 'all HQ1', '3/4 HQ1, 1/4 HQ2', '3/4 HQ1, 3/16 HQ2, 1/16 HQ3', '3/4 HQ1, 3/16 HQ2, 1/16 HQ3' };
local KIND = { [0] = { nq = 'NQ', hq1 = 'HQ', hq2 = 'HQ2', hq3 = 'HQ3', ['break'] = 'Break' },
               [1] = { nq = 'NQ', hq1 = 'HQ1', hq2 = 'HQ2', hq3 = 'HQ3', ['break'] = 'Break' } };
local KIND_KEY = { nq = 'text', hq1 = 'hq', hq2 = 'hq', hq3 = 'hq', ['break'] = 'bad' };

function ui.band_key(band)
    return 'band_' .. band;
end

function ui.open_item(id)
    ui.opened = id;
    ashita.misc.open_url(ui.URL:fmt(id));
end

-- Ctrl+click on the item drawn last opens it on ffxiah.com.
local function linkable(id)
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Ctrl+click: open on ffxiah.com');
        if (imgui.IsItemClicked(ImGuiMouseButton_Left) and imgui.GetIO().KeyCtrl) then
            ui.open_item(id);
        end
    end
end

local function link(id, text, key)
    imgui.TextColored(style.f(key or 'text'), text);
    linkable(id);
end

local function dim(text)
    imgui.TextColored(style.f('dim'), text);
end

-- A price box for an item. What's typed is the price for one, shared with every recipe.
local function price_box(key, id, width)
    local buf = ui.bufs[key];
    if (buf == nil) then
        buf = { '' };
        ui.bufs[key] = buf;
    end
    if (ui.editing ~= key) then
        local v = prices.get(id);
        buf[1] = v ~= nil and tostring(v) or '';
    end
    -- Without your price, the AH history's shows faintly (and is what's used), marked when it
    -- comes from stacks.
    local est = ah.estimate(id);
    local hint = est ~= nil and ('~' .. model.gil(est) .. (ah.basis(id) == 'stack' and ' stk' or '')) or 'gil';
    imgui.PushItemWidth(width);
    if (imgui.InputTextWithHint('##' .. key, hint, buf, 12, ImGuiInputTextFlags_CharsDecimal)) then
        local text = (buf[1] or ''):gsub('%s', '');
        prices.set(id, text ~= '' and tonumber(text) or nil);
    end
    imgui.PopItemWidth();
    if (imgui.IsItemActive()) then
        ui.editing = key;
    elseif (ui.editing == key) then
        ui.editing = nil;
    end
    if (imgui.IsItemHovered()) then
        if (imgui.IsMouseClicked(ImGuiMouseButton_Right)) then
            ah.toggle(id);
        end
        local lines = ah.describe(id, function (n) return model.gil(n); end);
        if (lines ~= nil) then
            if (prices.get(id) ~= nil) then
                lines[#lines + 1] = 'Your price is used; empty the box to use the AH\'s.';
            end
            imgui.SetTooltip(table.concat(lines, '\n'));
        else
            imgui.SetTooltip('No AH history yet: look at its price history at the auction house.');
        end
    end
end

-- Whether a recipe's profit leans on AH history for a price you haven't typed.
local function uses_history(r, you, mode)
    local function from_ah(id)
        return prices.get(id) == nil and ah.estimate(id) ~= nil;
    end
    if (from_ah(r[5])) then
        return true;
    end
    for i = 1, #r[6], 2 do
        if (from_ah(r[6][i])) then
            return true;
        end
    end
    if (mode == 'AH') then
        local t = odds.odds(r, you).tiers;
        for k = 1, 4 do
            if (t[k] > 0 and from_ah(r[7][k * 2 - 1])) then
                return true;
            end
        end
    end
    return false;
end

local function right_text(x_right, key, text)
    local w = imgui.CalcTextSize(text);
    imgui.SameLine(x_right - w);
    imgui.TextColored(style.f(key), text);
end

-- A title cut to fit a width, with '..' when cut.
local function fit(title, width)
    local f = ui.fit[title];
    if (f ~= nil and f[1] == width) then
        return f[2];
    end
    local text = title;
    if (imgui.CalcTextSize(text) > width) then
        while (#text > 1 and imgui.CalcTextSize(text .. '..') > width) do
            text = text:sub(1, -2);
        end
        text = text .. '..';
    end
    ui.fit[title] = { width, text };
    return text;
end

-- Chips in a row, with a gap before each group.
local function chip(id, text, on, key, gap)
    imgui.SameLine(0, gap or 4);
    return style.chip(id, text, on, key);
end

-- What the tenths of a craft's skill show as, and say when hovered.
local function tenths(c, lo, hi)
    local name = player.CRAFTS[c].name;
    local how = 'The game only tells your client whole levels; allrecipes works out the tenths from\nyour skill-up messages ("rises 0.3 points", "reaches level 23").';
    local known = skill.known(lo, hi);
    if (known == 'exact') then
        return ('.%d'):fmt(lo % 10), 'accent', ('%s %s.\n%s'):fmt(name, skill.fmt(lo), how);
    elseif (known == 'some') then
        return ('.%d-.%d'):fmt(lo % 10, hi % 10), 'dim',
            ('%s is between %s and %s: each skill-up narrows it down.\n%s'):fmt(name, skill.fmt(lo), skill.fmt(hi), how);
    end
    return '.?', 'dim', ('The tenths of %s aren\'t known yet.\n%s\nThey show after a skill-up or two.'):fmt(name, how);
end

-- The crystals in your inventory: an icon and a count for each of the eight, the one the recipe
-- shown needs picked out. Hovered, what's there (clusters and HQ crystals too).
local CELL_GAP = 10;
local function crystal_cells(s)
    local counts = player.crystals(os.clock());
    local sel = model.index ~= nil and model.index[s.selected] or nil;
    local need = sel ~= nil and sel[5] or nil;
    local size = math.floor(imgui.GetFontSize() + 4);
    local cells = { };
    for _, e in ipairs(player.CRYSTALS) do
        local n = counts[e.id] or 0;
        local text = tostring(n);
        local tw = imgui.CalcTextSize(text);
        cells[#cells + 1] = { e = e, n = n, text = text, w = size + 3 + tw, size = size, need = e.id == need,
                              cluster = counts[e.id + player.CLUSTER] or 0, hq = counts[e.id + player.HQ] or 0 };
    end
    return cells;
end

-- A crystal where no icon can be had: a long diamond in its element's colour.
local function crystal_shape(dl, x, y, size, rgb)
    local col = 0xFF000000 + rgb[3] * 65536 + rgb[2] * 256 + rgb[1];
    local cx, hw = x + size / 2, size * 0.26;
    local top, mid, bottom = y + size * 0.08, y + size * 0.45, y + size * 0.92;
    dl:AddTriangleFilled({ cx, top }, { cx - hw, mid }, { cx, bottom }, col);
    dl:AddTriangleFilled({ cx, top }, { cx, bottom }, { cx + hw, mid }, bit.bor(bit.band(col, 0x00FFFFFF), 0x99000000));
end

local function crystal_cell(dl, x, y, cell)
    local size = cell.size;
    if (cell.need) then
        dl:AddRectFilled({ x - 3, y - 2 }, { x + cell.w + 3, y + size + 2 }, style.col('accent', 40), 4, ImDrawFlags_RoundCornersAll);
        dl:AddRect({ x - 3, y - 2 }, { x + cell.w + 3, y + size + 2 }, style.col('accent', 150), 4, ImDrawFlags_RoundCornersAll, 1);
    end
    local tex = icons.get(cell.e.id);
    if (tex ~= nil) then
        dl:AddImage(tex, { x, y }, { x + size, y + size });
    else
        crystal_shape(dl, x, y, size, cell.e.rgb);
    end
    local _, th = imgui.CalcTextSize(cell.text);
    local key = cell.n > 0 and 'text' or (cell.need and 'bad' or 'dim');
    dl:AddText({ x + size + 3, y + (size - th) / 2 }, style.col(key), cell.text);
    imgui.SetCursorScreenPos({ x, y });
    imgui.InvisibleButton('##ar_crystal_' .. cell.e.element, { cell.w, size });
    if (imgui.IsItemHovered()) then
        local name = model.name(cell.e.id);
        local lines = { ('%s: %d in your inventory'):fmt(name, cell.n) };
        if (cell.cluster > 0) then
            lines[#lines + 1] = ('and %d %s (%d more when broken up)'):fmt(cell.cluster, model.name(cell.e.id + player.CLUSTER), cell.cluster * 12);
        end
        if (cell.hq > 0) then
            lines[#lines + 1] = ('and %d %s (synthesizes the same)'):fmt(cell.hq, model.name(cell.e.id + player.HQ));
        end
        if (cell.need) then
            lines[#lines + 1] = cell.n > 0 and 'The recipe shown uses one.' or 'The recipe shown needs one.';
        end
        imgui.SetTooltip(table.concat(lines, '\n'));
    end
end

-- The row, from (x, y), in rows of `per`; returns its width and height.
local function crystal_row(dl, cells, x, y, per, draw)
    local widths = { };
    for i, cell in ipairs(cells) do
        local col = (i - 1) % per + 1;
        widths[col] = math.max(widths[col] or 0, cell.w);
    end
    local total = -CELL_GAP;
    for _, w in ipairs(widths) do
        total = total + w + CELL_GAP;
    end
    local rows = math.ceil(#cells / per);
    local step = cells[1].size + 6;
    if (draw) then
        for i, cell in ipairs(cells) do
            local col, row = (i - 1) % per + 1, math.floor((i - 1) / per);
            local cx = x;
            for k = 1, col - 1 do
                cx = cx + widths[k] + CELL_GAP;
            end
            crystal_cell(dl, cx, y + row * step, cell);
        end
    end
    return total, rows * step - 6;
end

-- The crystals at the top right of the level block: in one row where there's room beside it,
-- two of four where not, and under it in a narrow window.
local function crystals(s, left, top, right, group_right)
    local dl = imgui.GetWindowDrawList();
    local cells = crystal_cells(s);
    local back_x, back_y = imgui.GetCursorScreenPos();
    for _, per in ipairs({ 8, 4 }) do
        local w = crystal_row(dl, cells, 0, 0, per, false);
        if (right - w >= group_right + 16) then
            crystal_row(dl, cells, right - w, top, per, true);
            imgui.SetCursorScreenPos({ back_x, back_y });
            ui.crystal_place = per == 8 and 'row' or 'two rows';
            return;
        end
    end
    local _, h = crystal_row(dl, cells, left, back_y + 2, 4, true);
    imgui.SetCursorScreenPos({ back_x, back_y + h + 6 });
    imgui.Dummy({ 1, 0 });
    ui.crystal_place = 'under';
end

-- The craft chips, and your level in the craft (to the tenth where it's known): rank, cap,
-- image support, gear; and the crystals you have.
local function header(s, you)
    for c, craft in ipairs(player.CRAFTS) do
        if (c > 1) then
            imgui.SameLine(0, 4);
        end
        local lo, hi = skill.range(s.skill, c, you);
        local level = lo == hi and skill.fmt(lo) or tostring(you.level[c]);
        if (style.chip(('##ar_craft%d'):fmt(c), ('%s %s'):fmt(craft.short, level), s.craft == c)) then
            s.craft, ui.scroll_top, ui.dirty = c, true, true;
        end
    end

    local c = s.craft;
    local level, rank = you.level[c], you.rank[c];
    local cap = (rank + 1) * 10;
    local lo, hi = skill.range(s.skill, c, you);
    imgui.Spacing();
    local left, top = imgui.GetCursorScreenPos();
    local right = left + imgui.GetContentRegionAvail();
    style.big(tostring(level), style.col('accent'), 30);
    imgui.SameLine(0, 1);
    local frac, key, tip = tenths(c, lo, hi);
    style.big(frac, style.col(key), 18, 30);
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip(tip);
    end
    imgui.SameLine(0, 10);
    imgui.BeginGroup();
    imgui.TextColored(style.f('text'), player.CRAFTS[c].name);
    imgui.SameLine();
    dim(('%s, cap %d'):fmt(player.RANKS[rank] or '?', cap));
    local capped = you.capped[c] or level >= cap;
    style.bar(160, capped and 1 or (lo / 10 - rank * 10) / 10, capped and 'hq' or 'accent');
    local im = player.imagery[c];
    if (im ~= nil) then
        if (style.chip('##ar_img', ('image support +%d'):fmt(im.power), true, 'hq')) then
            player.set_imagery(c, im.power == 1 and 3 or 1);
        end
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip('Free image support is +1, advanced support and guild belts +3.\nIt turns +3 by itself when it lasts over 2 minutes; click to change it.');
        end
    else
        dim('no image support');
    end
    if ((s.gear[c] or 0) > 0) then
        imgui.SameLine(0, 6);
        style.tag(('gear +%d'):fmt(s.gear[c]), 'hq');
    end
    if (capped) then
        imgui.SameLine(0, 6);
        style.tag('capped', 'hq');
    end
    imgui.EndGroup();
    local group_right = imgui.GetItemRectMax();
    crystals(s, left, top, right, group_right);
end

local function toolbar(s)
    if (style.chip('##ar_synth', 'synthesis', not s.desynth)) then s.desynth, ui.dirty = false, true; end
    if (chip('##ar_desynth', 'desynthesis', s.desynth)) then s.desynth, ui.dirty = true, true; end
    if (chip('##ar_all', 'all recipes', not s.skillups, nil, 16)) then s.skillups, ui.dirty = false, true; end
    if (chip('##ar_ups', 'skill-ups', s.skillups, 'good')) then s.skillups, ui.dirty = true, true; end
    if (chip('##ar_ah', 'sell on AH', s.sell == 'AH', nil, 16)) then s.sell, ui.dirty = 'AH', true; end
    if (chip('##ar_npc', 'sell to NPC', s.sell == 'NPC')) then s.sell, ui.dirty = 'NPC', true; end
    imgui.SameLine(0, 16);
    imgui.PushItemWidth(150);
    ui.search[1] = ui.search[1] or '';
    if (imgui.InputTextWithHint('##ar_search', 'search recipes', ui.search, 48)) then
        s.search = ui.search[1];
    end
    imgui.PopItemWidth();
    if (chip('##ar_cfg', 'settings', s.cfg, nil, 8)) then s.cfg, ui.dirty = not s.cfg, true; end
end

-- The list of recipes, drawn only where it's scrolled to.
local function list(s, you, rows, width, height)
    local profit_r = width - 24;
    local third_r = profit_r - 60;
    local ok_r = third_r - 48;
    local tag_x = ok_r - 44 - 88;
    local third = s.skillups and 'up' or 'hq';

    -- Column heads: click to sort, again to reverse.
    local function head(label, key, x, right, first)
        local on = s.sort == key;
        local shown = on and (label .. (s.dir > 0 and ' ^' or ' v')) or label;
        local at = right and x - imgui.CalcTextSize(shown) or x;
        if (first) then
            imgui.SetCursorPosX(at);
        else
            imgui.SameLine(at);
        end
        imgui.TextColored(style.f(on and 'accent' or 'dim'), shown);
        if (imgui.IsItemClicked(ImGuiMouseButton_Left)) then
            if (on) then
                s.dir = -s.dir;
            else
                s.sort, s.dir = key, (key == 'lv' or key == 'name') and 1 or -1;
            end
            ui.dirty = true;
        end
    end
    head('Lv', 'lv', 8, false, true);
    head('Recipe', 'name', 36);
    head('OK', 'ok', ok_r, true);
    head(s.skillups and 'Up' or 'HQ', third, third_r, true);
    head(s.sell == 'AH' and 'AH' or 'NPC', 'profit', profit_r, true);

    imgui.BeginChild('ar_list', { width, height }, ImGuiChildFlags_Borders);
    if (ui.scroll_top) then
        imgui.SetScrollY(0);
        ui.scroll_top = false;
    end
    if (#rows == 0) then
        dim(s.skillups and 'Nothing here gives you a skill-up.' or 'No recipes match.');
    end
    local rowh = imgui.GetTextLineHeightWithSpacing();
    local top = imgui.GetCursorPosY();
    local first = math.max(0, math.floor((imgui.GetScrollY() - top) / rowh));
    local last = math.min(#rows, first + math.ceil(imgui.GetWindowHeight() / rowh) + 1);
    local dl = imgui.GetWindowDrawList();
    local mx = imgui.GetMousePos();
    for i = first + 1, last do
        local row = rows[i];
        local r = row.r;
        imgui.SetCursorPosY(top + (i - 1) * rowh);
        local x0, y0 = imgui.GetCursorScreenPos();
        if (imgui.Selectable(('##ar%d'):fmt(r[1]), s.selected == r[1])) then
            if (imgui.GetIO().KeyCtrl) then
                ui.open_item(r[2] == 1 and r[6][1] or r[7][1]);
            else
                s.selected = r[1];
            end
        end
        local hovered = imgui.IsItemHovered();
        local function text(x, col, t)
            dl:AddText({ x0 + x, y0 }, col, t);
        end
        local function rtext(x, col, t)
            text(x - imgui.CalcTextSize(t), col, t);
        end
        text(8, style.col('dim'), tostring(row.lv));
        local title = fit(row.title, tag_x - 42);
        local col = style.col(ui.band_key(row.band));
        text(36, col, title);
        if (row.band == 'cant') then
            local tw, th = imgui.CalcTextSize(title);
            dl:AddLine({ x0 + 36, y0 + th / 2 + 1 }, { x0 + 36 + tw, y0 + th / 2 + 1 }, col, 1);
        end
        -- Small tags: sub-craft, expansion, key item.
        local tx = tag_x;
        local function tag(t, key)
            local tw, th = imgui.CalcTextSize(t);
            dl:AddRectFilled({ x0 + tx - 3, y0 }, { x0 + tx + tw + 3, y0 + th }, style.col(key, 40), th / 2, ImDrawFlags_RoundCornersAll);
            text(tx, style.col(key, 220), t);
            tx = tx + tw + 9;
        end
        if (row.sub) then tag('sub', 'dim'); end
        if (row.tag) then tag(row.tag, 'dim'); end
        if (row.ki) then tag('KI', 'warn'); end
        local can = row.band ~= 'cant';
        rtext(ok_r, style.col('dim'), can and model.pct(row.p) or '-');
        local v3 = s.skillups and row.up or row.hq;
        rtext(third_r, style.col(s.skillups and 'good' or 'hq'), (can and v3 > 0) and model.pct(v3) or '-');
        if (row.profit ~= nil) then
            rtext(profit_r, style.col(row.profit >= 0 and 'good' or 'bad'), model.short(row.profit));
        else
            rtext(profit_r, style.col('dim', 160), '-');
        end
        if (hovered) then
            if (mx >= x0 + third_r + 4 and row.profit ~= nil) then
                ui.profit_tooltip(r, you, s.sell);
            elseif (imgui.GetIO().KeyCtrl) then
                imgui.SetTooltip('Click: open ' .. model.name(r[2] == 1 and r[6][1] or r[7][1]) .. ' on ffxiah.com');
            end
        end
    end
    imgui.SetCursorPosY(top + #rows * rowh);
    imgui.Dummy({ 1, 0 });
    imgui.EndChild();
end

-- The ways a try can go and what each makes: { kind, label, chance, gil }, and the average.
function ui.outcome_lines(r, you, mode)
    local out, avg = odds.outcomes(r, you, prices.view, mode, model.npc);
    local lines = { };
    for _, o in ipairs(out) do
        local label = KIND[r[2]][o.kind];
        if (o.kind ~= 'break' and o.count ~= nil) then
            label = ('%s %dx %s'):fmt(label, o.count, model.name(o.item));
        end
        lines[#lines + 1] = { kind = o.kind, label = ('%s (%s)'):fmt(label, model.pct(o.chance)), chance = o.chance, gil = o.gil };
    end
    return lines, avg;
end

local function gil_key(v)
    return v == nil and 'dim' or v >= 0 and 'good' or 'bad';
end

function ui.profit_tooltip(r, you, mode)
    local lines, avg = ui.outcome_lines(r, you, mode);
    imgui.BeginTooltip();
    dim(mode == 'AH' and 'Selling on the AH, a try:' or 'Selling to an NPC, a try:');
    for _, l in ipairs(lines) do
        imgui.TextColored(style.f('text'), l.label);
        imgui.SameLine(260);
        imgui.TextColored(style.f(gil_key(l.gil)), l.gil ~= nil and model.gil(l.gil, true) or '?');
    end
    if (avg ~= nil) then
        imgui.TextColored(style.f('accent'), 'Average');
        imgui.SameLine(260);
        imgui.TextColored(style.f(gil_key(avg)), model.gil(avg, true));
    end
    imgui.EndTooltip();
end

-- What still needs a price before the profit can be worked out.
local function missing(r, you, mode)
    local need, seen = { }, { };
    local function add(id)
        if (not seen[id]) then
            seen[id] = true;
            need[#need + 1] = model.name(id);
        end
    end
    if (prices.view[r[5]] == nil) then add(r[5]); end
    for i = 1, #r[6], 2 do
        if (prices.view[r[6][i]] == nil) then add(r[6][i]); end
    end
    local t = odds.odds(r, you).tiers;
    for k = 1, 4 do
        local id = r[7][k * 2 - 1];
        if (t[k] > 0 and ((mode == 'AH' and prices.view[id] == nil) or (mode == 'NPC' and model.npc[id] == nil))) then
            add(id);
        end
    end
    return need;
end

-- The last synths estimate (odds.synths) and what it was for, so it isn't worked out every frame.
local synths_key, synths_val = nil, nil;

local function detail(s, you, r)
    local craft = s.craft;
    local desynth = r[2] == 1;
    local w = imgui.GetContentRegionAvail();
    local box_x, npc_r, chance_r = w - 84, w - 96, w - 160;
    local band = odds.band(r, you);
    local bkey = ui.band_key(band);

    -- What it is.
    if (desynth) then
        dim('desynthesize');
    end
    local item = desynth and r[6][1] or r[7][1];
    style.big(model.name(item), style.col(bkey), 22);
    linkable(item);
    if (not desynth and r[7][2] > 1) then
        imgui.SameLine(0, 8);
        dim(('x%d'):fmt(r[7][2]));
    end
    local can, short = odds.can_try(r, you);
    for i, x in ipairs(odds.difficulty(r, you)) do
        if (i > 1) then imgui.SameLine(0, 10); end
        local key = you.level[x.craft] < x.need - 15 and 'bad' or x.d > 0 and 'warn' or 'text';
        imgui.TextColored(style.f(key), ('%s %d'):fmt(player.CRAFTS[x.craft].name, x.need));
        imgui.SameLine(0, 4);
        local b = you.bonus[x.craft];
        dim(b > 0 and ('(you %d+%d)'):fmt(you.level[x.craft], b) or ('(you %d)'):fmt(you.level[x.craft]));
    end
    local tag = model.tag(r);
    local tagged = false;
    if (tag ~= nil) then
        style.tag(('%s recipe'):fmt(tag), 'dim');
        tagged = true;
    end
    if (r[3] ~= 0) then
        local have = player.has_key_item(r[3]);
        if (tagged) then imgui.SameLine(0, 6); end
        style.tag(('needs %s'):fmt(player.key_item_name(r[3])), have and 'dim' or 'warn');
        imgui.SameLine(0, 6);
        dim(have and '(you have it)' or '(you don\'t have it)');
    end

    -- The odds.
    local o = odds.odds(r, you);
    imgui.Spacing();
    if (not can) then
        imgui.TextColored(style.f('bad'), ('You can\'t start it yet: it needs %s %d or more.'):fmt(player.CRAFTS[short].name, r[4][short] - 15));
    else
        style.tag(('success %s'):fmt(model.pct(o.p)), bkey);
        local h = odds.hq_info(r, you);
        imgui.SameLine(0, 6);
        style.tag(h.possible and ('HQ %s'):fmt(model.pct(h.chance)) or 'no HQ', h.possible and 'hq' or 'dim');
        local up = odds.skillup(r, craft, you);
        imgui.SameLine(0, 6);
        style.tag(up > 0 and ('%s skill-up %s'):fmt(player.CRAFTS[craft].short, model.pct(up)) or 'no skill-ups', up > 0 and 'good' or 'dim');
        if (desynth) then
            dim('HQ is 60% of successes: 1/2 HQ1, 1/3 HQ2, 1/6 HQ3');
        elseif (h.possible) then
            local line = ('HQ of successes, %s over: %s'):fmt(OVER[h.bracket], SPLIT[h.bracket]);
            if (h.next ~= nil) then
                local needs = { };
                for _, n in ipairs(h.next.needs) do
                    needs[#needs + 1] = ('%s %d'):fmt(player.CRAFTS[n.craft].name, n.level);
                end
                line = line .. ('. %s from %s'):fmt(model.pct(h.next.chance), table.concat(needs, ' and '));
            end
            dim(line);
        else
            dim(('No HQ: you\'re under the recipe in %s.'):fmt(player.CRAFTS[h.below].name));
        end
        local cap = (you.rank[craft] + 1) * 10;
        if (up <= 0) then
            if (you.capped[craft] or you.level[craft] >= cap) then
                dim(('No skill-ups: capped at %d until you rank up.'):fmt(cap));
            elseif (r[4][craft] <= you.level[craft]) then
                dim('No skill-ups: you\'re at or over it.');
            else
                dim('No skill-ups: too hard to succeed.');
            end
        else
            local lo, hi = skill.range(s.skill, craft, you);
            local key = ('%s:%d:%d:%d'):fmt(tostring(r[1]), craft, lo, hi);
            for c = 1, 8 do
                key = key .. (':%d+%d'):fmt(you.level[c] or 0, you.bonus[c] or 0);
            end
            if (synths_key ~= key) then
                synths_key, synths_val = key, odds.synths(r, craft, you, lo, hi);
            end
            local n = synths_val;
            if (n ~= nil and (n.next ~= nil or n.cap ~= nil)) then
                local name, parts = player.CRAFTS[craft].name, { };
                local function about(v) return v < 10 and ('%.1f'):fmt(v) or ('%d'):fmt(math.floor(v + 0.5)); end
                local next_level = math.floor(lo / 10) + 1;
                if (n.next ~= nil) then
                    parts[#parts + 1] = ('%s to %s %d'):fmt(about(n.next), name, next_level);
                end
                if (n.cap ~= nil and n.cap_level > next_level) then
                    parts[#parts + 1] = ('%s to %d, %s'):fmt(about(n.cap), n.cap_level, n.cap_level < r[4][craft] and 'your rank\'s cap' or 'where it stops');
                end
                dim(('Synths on average: %s'):fmt(table.concat(parts, ', ')));
                if (imgui.IsItemHovered()) then
                    imgui.SetTooltip(('Worked out from Phoenix\'s skill-up rules at every tenth on the way: the chance\nrises as you do, and big gaps give bigger skill-ups. %s'):fmt(
                        lo == hi and ('From your %s at %s.'):fmt(name, skill.fmt(lo))
                        or ('Your tenths aren\'t known exactly, so it\'s averaged over %s to %s.'):fmt(skill.fmt(lo), skill.fmt(hi))));
                end
            end
        end
    end

    -- Materials.
    imgui.SeparatorText(desynth and 'Item to break up' or 'Materials');
    imgui.SameLine(box_x);
    dim('AH each');
    link(r[5], ('1x %s'):fmt(model.name(r[5])));
    imgui.SameLine(0, 6);
    dim('(always used)');
    imgui.SameLine(box_x);
    price_box('m' .. r[5], r[5], 76);
    for i = 1, #r[6], 2 do
        local id = r[6][i];
        link(id, ('%dx %s'):fmt(r[6][i + 1], model.name(id)));
        local rate = odds.loss_rate(id);
        if (rate ~= 0.5) then
            imgui.SameLine(0, 6);
            dim(rate == 0 and '(never lost)' or ('(lost %d%% on a break)'):fmt(rate * 100));
        end
        imgui.SameLine(box_x);
        price_box('m' .. id, id, 76);
    end

    -- Results.
    imgui.SeparatorText('Results');
    right_text(chance_r, 'dim', 'chance');
    right_text(npc_r, 'dim', 'NPC each');
    imgui.SameLine(box_x);
    dim('AH each');
    local labels = desynth and { 'NQ', 'HQ1', 'HQ2', 'HQ3' } or { 'NQ', 'HQ', 'HQ2', 'HQ3' };
    for k = 1, 4 do
        if (desynth or k == 1 or o.tiers[k] > 0) then
            local id, count = r[7][k * 2 - 1], r[7][k * 2];
            dim(labels[k]);
            imgui.SameLine(40);
            link(id, ('%dx %s'):fmt(count, model.name(id)), k > 1 and 'hq' or 'text');
            right_text(chance_r, 'text', model.pct(o.tiers[k]));
            local npc = model.npc[id];
            right_text(npc_r, npc and 'text' or 'dim', npc == false and 'won\'t buy' or npc == nil and '?' or model.gil(npc));
            imgui.SameLine(box_x);
            price_box('r' .. k .. '_' .. id, id, 76);
        end
    end
    if (not desynth and can and o.hq == 0) then
        dim('HQ needs you at or over the recipe in every craft.');
    end

    -- What it makes.
    if (not can) then
        return;
    end
    local other = s.sell == 'AH' and 'NPC' or 'AH';
    imgui.SeparatorText(s.sell == 'AH' and 'A try, selling on the AH' or 'A try, selling to an NPC');
    local lines, avg = ui.outcome_lines(r, you, s.sell);
    local bar_x = box_x - 70;
    for _, l in ipairs(lines) do
        imgui.TextColored(style.f('text'), l.label);
        imgui.SameLine(bar_x);
        style.bar(60, l.chance, KIND_KEY[l.kind]);
        right_text(box_x + 76, gil_key(l.gil), l.gil ~= nil and model.gil(l.gil, true) or '?');
    end
    if (avg ~= nil) then
        imgui.TextColored(style.f('accent'), 'Average a try at your odds');
        local text = model.gil(avg, true);
        local tw = imgui.CalcTextSize(text) * 20 / math.max(imgui.GetFontSize(), 1);
        imgui.SameLine(box_x + 76 - tw);
        style.big(text, style.col(gil_key(avg)), 20);
    else
        imgui.PushTextWrapPos(0);
        imgui.TextColored(style.f('warn'), 'Type a price for: ' .. table.concat(missing(r, you, s.sell), ', '));
        imgui.PopTextWrapPos();
    end
    local p2 = odds.profit(r, you, prices.view, other, model.npc);
    dim(('%s: %s a try'):fmt(other == 'AH' and 'Selling on the AH instead' or 'Selling to an NPC instead',
        p2 ~= nil and model.gil(p2, true) or 'needs prices'));
    if (uses_history(r, you, s.sell)) then
        dim('~ prices are from the AH history; type your own to use those instead.');
    end
end

local function legend(s)
    local names = LEGEND[s.desynth and 1 or 0];
    local first = true;
    for _, b in ipairs(BANDS) do
        if (names[b] ~= nil) then
            if (not first) then imgui.SameLine(0, 10); end
            first = false;
            style.dot(style.col(ui.band_key(b)));
            imgui.SameLine(0, 2);
            dim(names[b]);
        end
    end
    imgui.SameLine(0, 24);
    imgui.TextColored(style.f('dim', 170), 'ctrl+click an item: ffxiah.com');
end

-- The settings window: look, expansions, what the list shows, skill bonuses, prices.
local function settings_window(s)
    local open = { true };
    imgui.SetNextWindowPos({ s.x + s.w + 8, s.y }, ImGuiCond_FirstUseEver);
    if (imgui.Begin('allrecipes settings###allrecipes_settings', open, bit.bor(ImGuiWindowFlags_NoCollapse,
            ImGuiWindowFlags_NoSavedSettings, ImGuiWindowFlags_AlwaysAutoResize))) then
        imgui.SeparatorText('Look');
        for i, t in ipairs(style.THEMES) do
            if (i > 1) then imgui.SameLine(0, 4); end
            if (style.chip('##ar_theme_' .. t[1], t[2], s.theme == t[1])) then
                s.theme, ui.dirty = t[1], true;
            end
        end

        imgui.SeparatorText('Expansions');
        for i, e in ipairs(model.EXPANSIONS) do
            if (i > 1) then imgui.SameLine(0, 16); end
            local v = { s.expansions[e.tag] == true };
            if (imgui.Checkbox(e.name .. '##ar_exp', v)) then
                s.expansions[e.tag], ui.dirty = v[1], true;
            end
        end
        dim('The original game is always shown, Abyssea and later never.');
        dim('WotG isn\'t on Phoenix yet.');

        imgui.SeparatorText('The list');
        local sub = { s.sub };
        if (imgui.Checkbox('Recipes where the craft is a sub-craft##ar_sub', sub)) then s.sub, ui.dirty = sub[1], true; end
        local ki = { s.keyitems };
        if (imgui.Checkbox('Recipes needing a key item##ar_ki', ki)) then s.keyitems, ui.dirty = ki[1], true; end

        imgui.SeparatorText('Skill from gear or moghancements');
        for c, craft in ipairs(player.CRAFTS) do
            if (c % 2 == 0) then imgui.SameLine(210); end
            local g = { s.gear[c] or 0 };
            imgui.SetNextItemWidth(84);
            if (imgui.InputInt(('%s##ar_gear%d'):fmt(craft.name, c), g)) then
                s.gear[c], ui.dirty = math.max(0, math.min(10, g[1] or 0)), true;
            end
        end

        imgui.SeparatorText('Prices');
        local n = 0;
        for _ in pairs(prices.list) do
            n = n + 1;
        end
        dim(('%d prices typed in, shared by all your characters.'):fmt(n));
        local read = { s.ahread };
        if (imgui.Checkbox('Keep the AH price history of what you look at##ar_ahread', read)) then
            s.ahread, ui.dirty = read[1], true;
        end
        dim('Where an item has both, its price comes from:');
        imgui.SameLine(0, 8);
        if (style.chip('##ar_basis_single', 'singles', s.ahbasis ~= 'stack')) then
            s.ahbasis, ui.dirty = 'single', true;
            prices.touch();
        end
        imgui.SameLine(0, 4);
        if (style.chip('##ar_basis_stack', 'stacks', s.ahbasis == 'stack')) then
            s.ahbasis, ui.dirty = 'stack', true;
            prices.touch();
        end
        dim('Right-click a price box to switch one item.');
        dim(('%d items with AH history. It\'s only read from the game, never asked for.'):fmt(ah.count()));
        if (imgui.Button('Export prices.json##ar_export')) then
            local count, why = prices.export('prices.json');
            ui.note = count ~= nil and ('Saved %d prices to %s.'):fmt(count, prices.path('prices.json')) or why;
        end
        imgui.SameLine();
        dim('/ar prices import <file> to add some');
        if (ui.note ~= nil) then
            imgui.PushTextWrapPos(420);
            dim(ui.note);
            imgui.PopTextWrapPos();
        end
    end
    imgui.End();
    if (not open[1]) then
        s.cfg, ui.dirty = false, true;
    end
end

-- The crystal on the minimized window's icon: a long diamond, its left facet lit.
local function crystal(dl, x, y, w, h)
    local cx, hw, mid = x + w / 2, h * 0.22, y + h * 0.44;
    local top, bottom = { cx, y + h * 0.14 }, { cx, y + h * 0.86 };
    dl:AddTriangleFilled(top, { cx - hw, mid }, bottom, style.col('accent'));
    dl:AddTriangleFilled(top, bottom, { cx + hw, mid }, style.col('accent', 150));
end

-- Minimized: the icon in the tray at the bottom right (tray.lua). Click it to bring the window
-- back.
function ui.draw_icon(s, save)
    style.set(s.theme);
    local hit = tray.icon('allrecipes', {
        tip = 'allrecipes: click to open',
        panel = style.col('panel', style.panel_alpha()), edge = style.col('edge', 200),
        hot_panel = style.col('chip', style.panel_alpha()), hot_edge = style.col('accent', 200),
        glyph = crystal,
    });
    if (hit) then
        s.minimized = false;
        save();
    end
end

function ui.draw(s, you, save)
    style.set(s.theme);
    imgui.SetNextWindowPos({ s.x, s.y }, ui.reset and ImGuiCond_Always or ImGuiCond_FirstUseEver);
    imgui.SetNextWindowSize({ s.w, s.h }, ui.reset and ImGuiCond_Always or ImGuiCond_FirstUseEver);
    ui.reset = false;
    style.push_window();
    style.push_controls();
    local title = ('allrecipes - %s%s###allrecipes'):fmt(player.CRAFTS[s.craft].name, s.desynth and ' desynthesis' or '');
    -- No close button: a - in its place minimizes it to the icon (/ar hides it).
    if (imgui.Begin(title, nil, bit.bor(ImGuiWindowFlags_NoSavedSettings, ImGuiWindowFlags_NoCollapse))) then
        local wx, wy = imgui.GetWindowPos();
        local ww, wh = imgui.GetWindowSize();
        if (tray.title_button('##ar_minimize', wx, wy, ww, { text = style.col('text'), hover = style.col('bar', 250), held = style.col('edge', 230) })) then
            s.minimized, ui.dirty = true, true;
        end
        if (model.error ~= nil) then
            imgui.TextColored(style.f('bad'), ('No recipe data (%s). Run tools/gen_recipes.py.'):fmt(model.error));
        else
            header(s, you);
            imgui.Spacing();
            toolbar(s);
            imgui.Spacing();
            local rows = model.rows(s, you, s.craft);
            local selected = nil;
            for _, row in ipairs(rows) do
                if (row.r[1] == s.selected) then
                    selected = row.r;
                    break;
                end
            end
            if (selected == nil and rows[1] ~= nil) then
                selected = rows[1].r;
                s.selected = selected[1];
            end
            local aw, ah = imgui.GetContentRegionAvail();
            local foot = imgui.GetTextLineHeightWithSpacing() + 6;
            local head = imgui.GetTextLineHeightWithSpacing();
            local lw = math.min(450, math.floor(aw * 0.55));
            local bodyh = math.max(80, ah - foot - head);
            imgui.BeginGroup();
            list(s, you, rows, lw, bodyh);
            imgui.EndGroup();
            imgui.SameLine();
            imgui.BeginChild('ar_detail', { 0, bodyh + head }, ImGuiChildFlags_Borders);
            if (selected ~= nil) then
                detail(s, you, selected);
            end
            imgui.EndChild();
            legend(s);
        end
        if (math.abs(wx - s.x) > 0.5 or math.abs(wy - s.y) > 0.5 or math.abs(ww - s.w) > 0.5 or math.abs(wh - s.h) > 0.5) then
            s.x, s.y, s.w, s.h, ui.moved = wx, wy, ww, wh, true;
        end
    end
    imgui.End();
    if (s.cfg) then
        settings_window(s);
    end
    style.pop_controls();
    style.pop_window();

    if ((ui.moved and not imgui.IsMouseDown(ImGuiMouseButton_Left)) or ui.dirty) then
        ui.moved, ui.dirty = false, false;
        save();
    end
end

return ui;

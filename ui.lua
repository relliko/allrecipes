--[[
* allrecipes - ui
* The window, in scouter's look (style.lua): craft chips, your level (to the tenth where it's
* known), the crystals you have, the recipe list and the chosen recipe's materials, odds and
* prices; the fishing atlas on the Fish tab; and a settings window.
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
local fishing = require('fishing');
local helm   = require('helm');
local zonemap = require('zonemap');

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
    local name = player.skill_info(c).name;
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
    -- The chips wrap onto another row when the window's too narrow for them all.
    local row_left = imgui.GetCursorScreenPos();
    local row_right = row_left + imgui.GetContentRegionAvail();
    local first = true;
    local function tab(id, text, on, key, gap)
        if (not first) then
            local x = imgui.GetItemRectMax();
            if (x + gap + imgui.CalcTextSize(text) + 14 <= row_right) then
                imgui.SameLine(0, gap);
            end
        end
        first = false;
        return style.chip(id, text, on, key);
    end
    for c, craft in ipairs(player.CRAFTS) do
        local lo, hi = skill.range(s.skill, c, you);
        local level = lo == hi and skill.fmt(lo) or tostring(you.level[c]);
        if (tab(('##ar_craft%d'):fmt(c), ('%s %s'):fmt(craft.short, level), s.craft == c, nil, 4)) then
            s.craft, ui.scroll_top, ui.dirty = c, true, true;
        end
    end
    local f = fishing.SKILL;
    local flo, fhi = skill.range(s.skill, f, you);
    if (tab('##ar_craft9', ('Fish %s'):fmt(flo == fhi and skill.fmt(flo) or tostring(you.level[f])), s.craft == f, 'hq', 12)) then
        s.craft, ui.scroll_top, ui.dirty = f, true, true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('The fishing atlas: every fish, the level to start it and where it stops\ngiving skill-ups, where it bites, and what you\'ve caught today.');
    end
    -- HELM: harvesting, excavation, logging, mining.
    for k, short in ipairs(helm.SHORT) do
        local c = helm.FIRST + k - 1;
        if (tab(('##ar_helm%d'):fmt(k), short, s.craft == c, 'good', k == 1 and 12 or 4)) then
            s.craft, ui.scroll_top, ui.dirty = c, true, true;
        end
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip(('%s: each zone\'s drops and odds, with and without gear, and its points on the map.'):fmt(
                helm.kinds ~= nil and helm.kinds[k].name or short));
        end
    end
    if (s.craft == f) then
        return ui.fish_header(s, you);
    elseif (s.craft >= helm.FIRST) then
        return ui.helm_header(s, you, s.craft - helm.FIRST + 1);
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
    -- Image support: auto (what's up on you), or picked by hand to see the odds with it.
    local im = player.imagery[c];
    local pick = s.support[c] or -1;
    dim('support');
    local auto = im ~= nil and ('auto +%d'):fmt(im.power) or 'auto: none';
    if (chip('##ar_sup_auto', auto, pick == -1, im ~= nil and 'hq' or nil, 6)) then
        if (pick == -1 and im ~= nil) then
            player.set_imagery(c, im.power == 1 and 3 or 1);
        end
        s.support[c], ui.dirty = -1, true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip(im ~= nil
            and 'Counts the image support that\'s on you. Free support is +1, advanced support and\nguild belts +3; it turns +3 by itself when it lasts over 2 minutes. Click again to switch.'
            or 'Counts image support when it\'s on you: +1 free, +3 advanced or a guild belt.');
    end
    for _, v in ipairs({ 0, 1, 3 }) do
        if (chip('##ar_sup_' .. v, v == 0 and 'none' or ('+%d'):fmt(v), pick == v, v > 0 and 'hq' or nil)) then
            s.support[c], ui.dirty = v, true;
        end
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip(({ [0] = 'Count no image support, whatever\'s on you.', [1] = 'Count free image support (+1), whether or not it\'s on you.',
                [3] = 'Count advanced image support or a guild belt (+3), whether or not it\'s on you.\nAdvanced support\'s lower break loss isn\'t counted.' })[v]);
        end
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
    if (chip('##ar_make', 'can make', s.makeable, 'good', 8)) then s.makeable, ui.dirty = not s.makeable, true; end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Only recipes you can make now: high enough in every craft it uses\n(sub-crafts too) to start it, not sure to break, and with its key item.');
    end
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
    -- The old crafting myth: face the crystal's direction, on its day. The server uses neither.
    for _, e in ipairs(player.CRYSTALS) do
        if (e.id == r[5]) then
            dim(('Crafting myth: face %s (%s) on %s.'):fmt(e.face, e.element, e.day));
            if (imgui.IsItemHovered()) then
                imgui.SetTooltip('The old myth: each way on the compass has an element (N dark, NE light, E ice,\nSE wind, S earth, SW lightning, W water, NW fire), and facing your crystal\'s way\non its day helps. Square Enix said direction and day don\'t matter, and Phoenix\'s\nsynthesis code (synthutils.cpp) doesn\'t look at either. It\'s here for luck.');
            end
            break;
        end
    end

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

--[[
* The fishing atlas (fishing.lua): your fishing level and today's catches, the fish with the
* level to start each and the level it stops giving skill-ups, and the one picked: your odds on
* it, the bait it takes and where it bites.
--]]
local FISH_LEGEND = { { 'safe', 'at or under you' }, { 'good', 'skill-ups, 1-20 over' }, { 'risky', '21-35 over' },
                      { 'hard', '36-50 over' }, { 'zero', 'over 50' }, { 'cant', 'item' } };
local POWER = { 'bites', 'good', 'best' };

local function hm(secs)
    return ('%dh %02dm'):fmt(math.floor(secs / 3600), math.floor(secs % 3600 / 60));
end

function ui.fish_header(s, you)
    local f = fishing.SKILL;
    local level, rank = you.level[f], you.rank[f];
    local cap = math.min((rank + 1) * 10, fishing.CAP);
    local lo, hi = skill.range(s.skill, f, you);
    imgui.Spacing();
    local _, top = imgui.GetCursorScreenPos();
    local right = imgui.GetCursorScreenPos() + imgui.GetContentRegionAvail();
    style.big(tostring(level), style.col('accent'), 30);
    imgui.SameLine(0, 1);
    local frac, key, tip = tenths(f, lo, hi);
    style.big(frac, style.col(key), 18, 30);
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip(tip);
    end
    imgui.SameLine(0, 10);
    imgui.BeginGroup();
    imgui.TextColored(style.f('text'), 'Fishing');
    imgui.SameLine();
    dim(('%s, cap %d'):fmt(player.RANKS[rank] or '?', cap));
    local capped = you.capped[f] or level >= cap;
    style.bar(160, capped and 1 or (lo / 10 - rank * 10) / 10, capped and 'hq' or 'accent');
    local over = 0;
    for _, row in ipairs(fishing.list or { }) do
        if (not row.item and row.lv > level and row.lv - level <= fishing.REACH) then
            over = over + 1;
        end
    end
    dim(('%d fish give you skill-ups'):fmt(over));
    if (capped) then
        imgui.SameLine(0, 6);
        style.tag('capped', 'hq');
    end
    imgui.EndGroup();
    local group_right = imgui.GetItemRectMax();

    -- Today's catches, at the top right (under the level in a narrow window).
    local day = s.fishday;
    fishing.roll(day);
    local back_x, back_y = imgui.GetCursorScreenPos();
    local count = tostring(day.count);
    local reset = ('resets in %s'):fmt(hm(fishing.until_reset()));
    local why = ('Your catches since midnight in Japan (15:00 UTC), when the game\'s\ndaily limits start over too. Counted from your "caught" lines while\nthe addon is loaded; fish you let go or couldn\'t carry don\'t count.\nNext reset in %s.'):fmt(hm(fishing.until_reset()));
    local cw = imgui.CalcTextSize(count) * 30 / math.max(imgui.GetFontSize(), 1);
    local lw = math.max(imgui.CalcTextSize('caught today'), imgui.CalcTextSize(reset));
    local x = right - cw - 8 - lw;
    if (x >= group_right + 16) then
        imgui.SetCursorScreenPos({ x, top });
        imgui.BeginGroup();
        style.big(count, style.col(day.count > 0 and 'good' or 'dim'), 30);
        imgui.SameLine(0, 8);
        imgui.BeginGroup();
        imgui.TextColored(style.f('text'), 'caught today');
        dim(reset);
        imgui.EndGroup();
        imgui.EndGroup();
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip(why);
        end
        imgui.SetCursorScreenPos({ back_x, back_y });
    else
        dim(('%d caught today, %s'):fmt(day.count, reset));
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip(why);
        end
    end
end

local function fish_toolbar(s)
    if (style.chip('##ar_fall', 'all fish', not s.fishups)) then s.fishups, ui.dirty = false, true; end
    if (chip('##ar_fups', 'skill-ups', s.fishups, 'good')) then s.fishups, ui.dirty = true, true; end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip(('Only fish that give you skill-ups now: over your level, by no more than %d.'):fmt(fishing.REACH));
    end
    if (chip('##ar_fitems', 'items', s.fishitems, nil, 16)) then s.fishitems, ui.dirty = not s.fishitems, true; end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('List what isn\'t a fish too (logs, buckets, kelp...). They never give skill-ups.');
    end
    imgui.SameLine(0, 16);
    imgui.PushItemWidth(150);
    ui.search[1] = ui.search[1] or '';
    if (imgui.InputTextWithHint('##ar_fsearch', 'search fish', ui.search, 48)) then
        s.search = ui.search[1];
    end
    imgui.PopItemWidth();
    if (chip('##ar_cfg', 'settings', s.cfg, nil, 8)) then s.cfg, ui.dirty = not s.cfg, true; end
end

-- A fish's gear in short, for its row's tooltip: the least rods that hold it and its best bait.
local function fish_gear(f, lv)
    local rods, best = { }, nil;
    for _, r in ipairs(fishing.rods_for(f, lv)) do
        if (best == nil) then
            best = r;
        end
        if (r.risk == best.risk and r.hook == best.hook and #rods < 3) then
            rods[#rods + 1] = r.rod.name;
        end
    end
    local lines = { f.name };
    if (best ~= nil) then
        lines[#lines + 1] = ('Rod: %s%s'):fmt(table.concat(rods, ', '), best.risk > 0 and (' (still loses it %s)'):fmt(model.pct(best.risk)) or ' or better');
    end
    local bait = { };
    for i = 1, #f.bait, 2 do
        if (f.bait[i + 1] == f.bait[2] and #bait < 3) then
            bait[#bait + 1] = model.name(f.bait[i]);
        end
    end
    lines[#lines + 1] = #bait > 0 and ('Bait: %s'):fmt(table.concat(bait, ', ')) or 'Bait: none listed';
    return table.concat(lines, '\n');
end

local function fish_list(s, rows, width, height, lv)
    local today_r = width - 24;
    local up_r = today_r - 56;
    local tag_x = up_r - 50 - 84;
    local function head(label, key, x, right, first, tip)
        local on = s.fishsort == key;
        local shown = on and (label .. (s.fishdir > 0 and ' ^' or ' v')) or label;
        local at = right and x - imgui.CalcTextSize(shown) or x;
        if (first) then
            imgui.SetCursorPosX(at);
        else
            imgui.SameLine(at);
        end
        imgui.TextColored(style.f(on and 'accent' or 'dim'), shown);
        if (tip ~= nil and imgui.IsItemHovered()) then
            imgui.SetTooltip(tip);
        end
        if (imgui.IsItemClicked(ImGuiMouseButton_Left)) then
            if (on) then
                s.fishdir = -s.fishdir;
            else
                s.fishsort, s.fishdir = key, (key == 'up' or key == 'today') and -1 or 1;
            end
            ui.dirty = true;
        end
    end
    head('Start', 'start', 8, false, true, ('The level to start fishing it: %d under its cap. From there skill-ups\ncome more often and fewer than 1 in 10 get away for lack of skill.'):fmt(fishing.START));
    head('Cap', 'cap', 52, false, false, 'Its skill level: no more skill-ups from it once you reach it.');
    head('Fish', 'name', 88);
    head('Up', 'up', up_r, true, false, 'Your skill-up chance a catch, outside a town on an ordinary moon.');
    head('Today', 'today', today_r, true, false, 'How many you\'ve caught today (Japan\'s day).');

    imgui.BeginChild('ar_flist', { width, height }, ImGuiChildFlags_Borders);
    if (ui.scroll_top) then
        imgui.SetScrollY(0);
        ui.scroll_top = false;
    end
    if (#rows == 0) then
        dim(s.fishups and 'No fish gives you a skill-up.' or 'No fish match.');
    end
    local rowh = imgui.GetTextLineHeightWithSpacing();
    local top = imgui.GetCursorPosY();
    local first = math.max(0, math.floor((imgui.GetScrollY() - top) / rowh));
    local last = math.min(#rows, first + math.ceil(imgui.GetWindowHeight() / rowh) + 1);
    local dl = imgui.GetWindowDrawList();
    for i = first + 1, last do
        local row = rows[i];
        local f = row.f;
        imgui.SetCursorPosY(top + (i - 1) * rowh);
        local x0, y0 = imgui.GetCursorScreenPos();
        if (imgui.Selectable(('##arf%d'):fmt(f.id), s.fishsel == f.id)) then
            if (imgui.GetIO().KeyCtrl and f.id < 65535) then
                ui.open_item(f.id);
            else
                s.fishsel, ui.dirty = f.id, true;
            end
        end
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip(imgui.GetIO().KeyCtrl and ('Click: open %s on ffxiah.com'):fmt(f.name) or fish_gear(f, lv));
        end
        local function text(x, col, t)
            dl:AddText({ x0 + x, y0 }, col, t);
        end
        local function rtext(x, col, t)
            text(x - imgui.CalcTextSize(t), col, t);
        end
        text(8, style.col('dim'), f.item and '-' or tostring(f.start));
        text(52, style.col('text'), tostring(f.lv));
        text(88, style.col(ui.band_key(row.band)), fit(f.name, tag_x - 94));
        local tx = tag_x;
        local function tag(t, key)
            local tw, th = imgui.CalcTextSize(t);
            dl:AddRectFilled({ x0 + tx - 3, y0 }, { x0 + tx + tw + 3, y0 + th }, style.col(key, 40), th / 2, ImDrawFlags_RoundCornersAll);
            text(tx, style.col(key, 220), t);
            tx = tx + tw + 9;
        end
        if (f.large) then tag('L', 'hq'); end
        if (f.tag) then tag(model.EXPANSION_SHORT[f.tag] or f.tag, 'dim'); end
        if (f.legendary) then tag('LGD', 'warn'); end
        if (f.ki ~= 0 or f.quest) then tag('KI', 'warn'); end
        rtext(up_r, style.col('good'), row.up > 0 and model.pct(row.up) or '-');
        rtext(today_r, style.col(row.today > 0 and 'text' or 'dim', row.today > 0 and 255 or 160), row.today > 0 and tostring(row.today) or '-');
    end
    imgui.SetCursorPosY(top + #rows * rowh);
    imgui.Dummy({ 1, 0 });
    imgui.EndChild();
end

local function about(v)
    return v < 10 and ('%.1f'):fmt(v) or model.gil(v);
end

local function fish_detail(s, you, f)
    local fl = fishing.SKILL;
    local lv = you.level[fl];
    style.big(f.name, style.col(ui.band_key(fishing.band(f, lv))), 22);
    if (f.id < 65535) then
        linkable(f.id);
    end
    local tags = { { f.item and 'item' or (f.large and 'large fish' or 'small fish'), f.large and 'hq' or 'dim' } };
    if (f.tag) then tags[#tags + 1] = { (model.EXPANSION_SHORT[f.tag] or f.tag) .. ' waters', 'dim' }; end
    if (f.legendary) then tags[#tags + 1] = { 'legendary', 'warn' }; end
    if (f.ki ~= 0) then
        tags[#tags + 1] = { ('needs %s'):fmt(player.key_item_name(f.ki)), player.has_key_item(f.ki) and 'dim' or 'warn' };
    end
    if (f.quest) then tags[#tags + 1] = { 'only during its quest', 'warn' }; end
    for i, t in ipairs(tags) do
        if (i > 1) then imgui.SameLine(0, 6); end
        style.tag(t[1], t[2]);
    end
    if (f.large and not f.item) then
        dim('Large: a rod for large fish (Composite, Lu Shang\'s...) holds it best.');
    end

    imgui.Spacing();
    if (f.item) then
        imgui.TextColored(style.f('text'), ('Skill %d'):fmt(f.lv));
        dim('An item: catching it never gives skill-ups.');
    else
        local best = math.max(0, f.lv - fishing.BEST);
        style.tag(('start %d'):fmt(f.start), 'text');
        imgui.SameLine(0, 6);
        style.tag(('best %d'):fmt(best), 'good');
        imgui.SameLine(0, 6);
        style.tag(('cap %d'):fmt(f.lv), 'hq');
        imgui.PushTextWrapPos(0);
        dim(('Start at %d: from %d under it, skill-ups come more often and fewer than 1 in 10 get away for lack of skill. Anything up to %d under gives some.'):fmt(
            f.start, fishing.START, fishing.REACH));
        dim(('Best at %d, %d under: where the skill-up chance peaks.'):fmt(best, fishing.BEST));
        if (f.lv > fishing.CAP) then
            dim(('Cap %d is over fishing\'s cap of %d, so it gives skill-ups all the way.'):fmt(f.lv, fishing.CAP));
        else
            dim(('Cap %d: no more skill-ups from it once you reach %d.'):fmt(f.lv, f.lv));
        end
        imgui.PopTextWrapPos();

        imgui.SeparatorText('Your odds');
        local up = fishing.skillup(f, lv);
        local lose = fishing.lose(f, lv);
        style.tag(up > 0 and ('skill-up %s a catch'):fmt(model.pct(up)) or 'no skill-ups', up > 0 and 'good' or 'dim');
        imgui.SameLine(0, 6);
        style.tag(lose > 0 and ('gets away %s (skill)'):fmt(model.pct(lose)) or 'skill enough to land', lose > 0 and 'bad' or 'dim');
        if (up <= 0) then
            local cap = math.min((you.rank[fl] + 1) * 10, fishing.CAP);
            if (lv >= cap and f.lv > lv) then
                dim(('No skill-ups: capped at %d until you rank up.'):fmt(cap));
            elseif (f.lv <= lv) then
                dim('No skill-ups: you\'re at or over it.');
            else
                dim(('No skill-ups: more than %d levels over you.'):fmt(fishing.REACH));
            end
        else
            local lo, hi = skill.range(s.skill, fl, you);
            local n = fishing.catches(f, math.floor((lo + hi) / 2), you.rank[fl]);
            if (n ~= nil) then
                local nxt = math.floor(lo / 10) + 1;
                local parts = { ('%s to Fishing %d'):fmt(about(n.next), nxt) };
                if (n.cap_level > nxt) then
                    parts[#parts + 1] = ('%s to %d, %s'):fmt(about(n.cap), n.cap_level, n.cap_level < f.lv and 'your rank\'s cap' or 'where it stops');
                end
                dim(('Catches on average: %s'):fmt(table.concat(parts, ', ')));
                if (imgui.IsItemHovered()) then
                    imgui.SetTooltip(('Worked out from Phoenix\'s skill-up rules level by level: the chance changes\nas you rise, and fish 10 or more over you now and then give 0.2.\n%s'):fmt(
                        lo == hi and ('From your Fishing at %s.'):fmt(skill.fmt(lo)) or ('From the middle of %s-%s (your tenths aren\'t known exactly).'):fmt(skill.fmt(lo), skill.fmt(hi))));
                end
            end
        end
        dim('Outside a town on an ordinary moon. Near a new moon skill-ups');
        dim('come more often; near a full moon and in towns, less.');
        if (lv < 50) then
            dim('Under 50, a Lu Shang\'s Fishing Rod makes them rarer.');
        end
    end
    local today = s.fishday.fish[tostring(f.id)] or 0;
    if (today > 0) then
        imgui.TextColored(style.f('good'), ('%d caught today'):fmt(today));
    end

    -- The rods: the ones that hold it first, then the trouble with the rest.
    local bag = player.inventory(os.clock());
    local w = imgui.GetContentRegionAvail();
    imgui.SeparatorText('Rods');
    -- The four plainest that hold it and two that don't, and any you have.
    local held, bad, more_held, more_bad = 0, 0, 0, 0;
    for _, r in ipairs(fishing.rods_for(f, lv)) do
        local ok = r.risk <= 0;
        local show = bag[r.rod.id] ~= nil or (ok and held < 4) or (not ok and bad < 2);
        if (not show) then
            if (ok) then more_held = more_held + 1; else more_bad = more_bad + 1; end
        else
            if (ok) then held = held + 1; else bad = bad + 1; end
            local parts = { };
            if (r.why == 'big') then parts[#parts + 1] = ('too big for it: gets away %s'):fmt(model.pct(r.lose)); end
            if (r.why == 'small') then parts[#parts + 1] = ('too small for it: let go %s'):fmt(model.pct(r.lose)); end
            if (r.snap > 0) then parts[#parts + 1] = ('line snaps %s'):fmt(model.pct(r.snap)); end
            if (r.brk > 0) then parts[#parts + 1] = ('rod breaks %s'):fmt(model.pct(r.brk)); end
            if (#parts == 0) then
                parts[1] = r.hook == 0 and 'holds it' or r.hook == 3 and 'holds it, fewer bites (a large-fish rod)' or 'holds it, fewer bites (a small-fish rod)';
            end
            local key = r.risk > 0 and (r.risk >= 0.25 and 'bad' or 'warn') or (r.hook == 0 and 'good' or 'text');
            link(r.rod.id, r.rod.name, r.risk > 0 and 'dim' or 'text');
            if (bag[r.rod.id] ~= nil) then
                imgui.SameLine(0, 6);
                style.tag('yours', 'hq');
            end
            imgui.SameLine(0, 10);
            imgui.PushTextWrapPos(0);
            imgui.TextColored(style.f(key), table.concat(parts, ', '));
            imgui.PopTextWrapPos();
        end
    end
    if (more_held > 0 or more_bad > 0) then
        local parts = { };
        if (more_held > 0) then parts[#parts + 1] = ('%d better rod%s hold%s it too'):fmt(more_held, more_held == 1 and '' or 's', more_held == 1 and 's' or ''); end
        if (more_bad > 0) then parts[#parts + 1] = ('%d more lose%s it more often'):fmt(more_bad, more_bad == 1 and 's' or ''); end
        dim(table.concat(parts, '; ') .. '.');
    end
    dim(('Worked out at your level (%d). Within 10 of it, every rod holds a little more.'):fmt(lv));

    imgui.SeparatorText('Bait and lures');
    if (#f.bait == 0) then
        dim('None listed: it only bites now and then, on anything.');
    else
        for i = 1, #f.bait, 2 do
            local id, power = f.bait[i], f.bait[i + 1];
            link(id, model.name(id));
            if (bag[id] ~= nil) then
                imgui.SameLine(0, 6);
                style.tag(('yours x%d'):fmt(bag[id]), 'hq');
            end
            right_text(w, power >= 3 and 'good' or power == 2 and 'text' or 'dim', POWER[power] or '');
        end
    end

    imgui.SeparatorText('Where it bites');
    imgui.PushTextWrapPos(0);
    for _, p in ipairs(fishing.places(f)) do
        imgui.TextColored(style.f('text'), p[1]);
        if (p[2] ~= '') then
            imgui.SameLine(0, 8);
            dim(p[2]);
        end
    end
    imgui.PopTextWrapPos();
end

local function fish_legend()
    for i, b in ipairs(FISH_LEGEND) do
        if (i > 1) then imgui.SameLine(0, 10); end
        style.dot(style.col(ui.band_key(b[1])));
        imgui.SameLine(0, 2);
        dim(b[2]);
    end
    imgui.SameLine(0, 24);
    imgui.TextColored(style.f('dim', 170), 'L large  KI key item');
end

local function fish_body(s, you)
    if (fishing.error ~= nil) then
        imgui.TextColored(style.f('bad'), ('No fishing data (%s). Run tools/gen_fish.py.'):fmt(fishing.error));
        return;
    end
    fish_toolbar(s);
    imgui.Spacing();
    local rows = fishing.rows(s, you.level[fishing.SKILL], s.fishday);
    local selected = nil;
    for _, row in ipairs(rows) do
        if (row.f.id == s.fishsel) then
            selected = row.f;
            break;
        end
    end
    if (selected == nil and rows[1] ~= nil) then
        selected = rows[1].f;
        s.fishsel = selected.id;
    end
    local aw, ah = imgui.GetContentRegionAvail();
    local foot = imgui.GetTextLineHeightWithSpacing() + 6;
    local head = imgui.GetTextLineHeightWithSpacing();
    local lw = math.min(450, math.floor(aw * 0.55));
    local bodyh = math.max(80, ah - foot - head);
    imgui.BeginGroup();
    fish_list(s, rows, lw, bodyh, you.level[fishing.SKILL]);
    imgui.EndGroup();
    imgui.SameLine();
    imgui.BeginChild('ar_fdetail', { 0, bodyh + head }, ImGuiChildFlags_Borders);
    if (selected ~= nil) then
        fish_detail(s, you, selected);
    end
    imgui.EndChild();
    fish_legend();
end

--[[
* HELM (helm.lua): a tab each for harvesting, excavation, logging and mining. The zones with their
* odds; the one picked with its drops a try and a tool, with and without gear, and its points
* on the game's map of the zone (zonemap.lua).
--]]
local GEAR_CHOICES = { { 'none', 'no gear' }, { 'field', 'Field set' }, { 'worker', 'Worker set' }, { 'worn', 'what you wear' } };

local function zone_name(id)
    local n = AshitaCore:GetResourceManager():GetString('zones.names', id);
    return (n ~= nil and n ~= '') and n or ('Zone %d'):fmt(id);
end

-- The gear points the numbers assume (s.helmgear), and what to call them.
local function gear_points(s, kind)
    local sets = helm.sets(kind);
    if (s.helmgear == 'field') then
        return sets.field[1], sets.field[2], 'Field set';
    elseif (s.helmgear == 'worker') then
        return sets.worker[1], sets.worker[2], 'Worker set';
    elseif (s.helmgear == 'worn') then
        local nq, hq = helm.worn(kind);
        return nq, hq, 'what you wear';
    end
    return 0, 0, 'no gear';
end

local function count_of(bag, id)
    return bag[id] or 0;
end

function ui.helm_header(s, you, k)
    imgui.Spacing();
    if (helm.kinds == nil) then
        return;
    end
    local kind = helm.kinds[k];
    style.big(kind.name, style.col('accent'), 30);
    imgui.SameLine(0, 12);
    imgui.BeginGroup();
    local bag = player.inventory(os.clock());
    local tools = count_of(bag, kind.tool);
    imgui.TextColored(style.f(tools > 0 and 'text' or 'warn'), ('%d %s%s in your bags'):fmt(tools, model.name(kind.tool),
        tools == 1 and '' or 's'));
    if (#kind.gear == 0) then
        dim('No gear helps it: the tool breaks as often whatever you wear.');
    else
        local nq, hq, pieces = helm.worn(kind);
        if (#pieces == 0) then
            dim(('No %s gear on: Field and Worker gear make tools break less.'):fmt(kind.name:lower()));
        else
            local names = { };
            for _, id in ipairs(pieces) do
                names[#names + 1] = model.name(id);
            end
            imgui.TextColored(style.f('good'), ('Wearing %s: tools break x%.2f as often'):fmt(table.concat(names, ', '),
                helm.NQ ^ nq * helm.HQ ^ hq));
        end
    end
    imgui.EndGroup();
end

local function helm_toolbar(s, kind)
    local first = true;
    if (#kind.gear > 0) then
        local sets = helm.sets(kind);
        local wnq, whq = helm.worn(kind);
        local mult = { none = 1, field = helm.NQ ^ sets.field[1], worker = helm.HQ ^ sets.worker[2], worn = helm.NQ ^ wnq * helm.HQ ^ whq };
        for _, g in ipairs(GEAR_CHOICES) do
            local text = g[1] == 'none' and g[2] or ('%s x%.2f'):fmt(g[2], mult[g[1]]);
            local on = s.helmgear == g[1];
            if ((first and style.chip('##ar_hg_' .. g[1], text, on)) or (not first and chip('##ar_hg_' .. g[1], text, on))) then
                s.helmgear, ui.dirty = g[1], true;
            end
            first = false;
            if (imgui.IsItemHovered()) then
                local tips = {
                    none = 'The numbers with no gear on.',
                    field = 'With the three Field pieces that help it (each makes tools break x0.893 as often).',
                    worker = 'With the three Worker pieces that help it (each makes tools break x0.843 as often).',
                    worn = 'With the gear you have on now.',
                };
                imgui.SetTooltip(tips[g[1]] .. '\nGear only changes how often the tool breaks, not what you find.');
            end
        end
    else
        dim('no gear for excavation');
        first = false;
    end
    imgui.SameLine(0, 16);
    imgui.PushItemWidth(170);
    ui.search[1] = ui.search[1] or '';
    if (imgui.InputTextWithHint('##ar_hsearch', 'search items or zones', ui.search, 48)) then
        s.search = ui.search[1];
    end
    imgui.PopItemWidth();
    if (chip('##ar_cfg', 'settings', s.cfg, nil, 8)) then s.cfg, ui.dirty = not s.cfg, true; end
end

local function helm_list(s, kind, rows, width, height, nq, hq)
    local pts_r = width - 24;
    local brk_r = pts_r - 44;
    local ob_r = brk_r - 58;
    local find_r = ob_r - 58;
    local searching = (s.search or '') ~= '';
    local function head(label, key, x, right, first_, tip)
        local on = (s.helmsort or 'zone') == key;
        local shown = on and (label .. ((s.helmdir or 1) > 0 and ' ^' or ' v')) or label;
        local at = right and x - imgui.CalcTextSize(shown) or x;
        if (first_) then
            imgui.SetCursorPosX(at);
        else
            imgui.SameLine(at);
        end
        imgui.TextColored(style.f(on and 'accent' or 'dim'), shown);
        if (tip ~= nil and imgui.IsItemHovered()) then
            imgui.SetTooltip(tip);
        end
        if (imgui.IsItemClicked(ImGuiMouseButton_Left)) then
            if (on) then
                s.helmdir = -(s.helmdir or 1);
            else
                s.helmsort, s.helmdir = key, key == 'zone' and 1 or -1;
            end
            ui.dirty = true;
        end
    end
    head('Zone', 'zone', 8, false, true);
    if (searching) then
        head('Item', 'find', find_r, true, false, 'The chance a try of what you searched for.');
    end
    head('Finds', 'obtain', ob_r, true, false, 'How often a try finds something.');
    head('Breaks', 'brk', brk_r, true, false, 'How often a try breaks the tool, with the gear picked above.');
    head('Pts', 'points', pts_r, true, false, 'How many spots its points move between.');

    imgui.BeginChild('ar_hlist', { width, height }, ImGuiChildFlags_Borders);
    if (ui.scroll_top) then
        imgui.SetScrollY(0);
        ui.scroll_top = false;
    end
    if (#rows == 0) then
        dim(searching and 'No zone gives that.' or 'No zones.');
    end
    local dl = imgui.GetWindowDrawList();
    for _, row in ipairs(rows) do
        local z = row.z;
        local x0, y0 = imgui.GetCursorScreenPos();
        if (imgui.Selectable(('##arh%d'):fmt(z.id), ui.hsel == z.id)) then
            ui.hpick = z.id;
        end
        local function text(x, col, t)
            dl:AddText({ x0 + x, y0 }, col, t);
        end
        local function rtext(x, col, t)
            text(x - imgui.CalcTextSize(t), col, t);
        end
        local name = fit(row.name, (searching and find_r - 60 or ob_r - 60) - 8);
        text(8, style.col('text'), name);
        local tx = 8 + imgui.CalcTextSize(name) + 8;
        local function tag(t, key)
            local tw, th = imgui.CalcTextSize(t);
            dl:AddRectFilled({ x0 + tx - 3, y0 }, { x0 + tx + tw + 3, y0 + th }, style.col(key, 40), th / 2, ImDrawFlags_RoundCornersAll);
            text(tx, style.col(key, 220), t);
            tx = tx + tw + 9;
        end
        if (z.tag) then tag(model.EXPANSION_SHORT[z.tag] or z.tag, 'dim'); end
        if (z.level > 0) then tag(('Lv%d'):fmt(z.level), 'warn'); end
        if (z.weather) then tag(z.weather, 'hq'); end
        if (searching) then
            rtext(find_r, style.col('good'), row.find ~= nil and model.pct(row.find) or '-');
        end
        rtext(ob_r, style.col('text'), model.pct(z.obtain));
        rtext(brk_r, style.col('bad'), model.pct(helm.break_with(z, nq, hq)));
        rtext(pts_r, style.col('dim'), tostring(#z.points));
    end
    imgui.EndChild();
end

-- A number of things a tool: 12.3, 8.0, 140.
local function per(v)
    return v >= 100 and ('%d'):fmt(math.floor(v + 0.5)) or ('%.1f'):fmt(v);
end

-- The map of a zone with its points (and you, when you're there).
local function helm_map(s, z, width)
    local maps = zonemap.of(z.id);
    if (#maps == 0) then
        dim('The game has no map of this zone.');
        return;
    end
    local yx, yz, here_zone = zonemap.you();
    local here = here_zone == z.id;
    -- Which floor each point is on: the game's answer, kept from a visit.
    local floors, unknown = { }, 0;
    for i, p in ipairs(z.points) do
        floors[i] = #maps > 1 and zonemap.floor_of(z.id, p, here) or maps[1].floor;
        if (floors[i] == nil) then
            unknown = unknown + 1;
        end
    end
    local pick = nil;
    for _, m in ipairs(maps) do
        if (m.floor == s.helmfloor) then
            pick = m;
        end
    end
    if (pick == nil) then
        -- The floor with the most points, else the first.
        local best, n = maps[1], -1;
        for _, m in ipairs(maps) do
            local c = 0;
            for i = 1, #z.points do
                if (floors[i] == m.floor) then c = c + 1; end
            end
            if (c > n) then best, n = m, c; end
        end
        pick = best;
    end
    if (#maps > 1) then
        dim('Floor');
        for i, m in ipairs(maps) do
            local c = 0;
            for j = 1, #z.points do
                if (floors[j] == m.floor) then c = c + 1; end
            end
            if (chip(('##ar_hf%d'):fmt(m.floor), c > 0 and ('%d (%d)'):fmt(i, c) or tostring(i), m == pick, nil, i == 1 and 6 or 4)) then
                s.helmfloor, ui.dirty = m.floor, true;
            end
        end
    end
    local tex = zonemap.texture(pick);
    local size = math.max(160, math.min(512, width));
    local x0, y0 = imgui.GetCursorScreenPos();
    if (tex == nil) then
        dim(('No map picture: %s.'):fmt(zonemap.why or '?'));
        return;
    end
    local dl = imgui.GetWindowDrawList();
    dl:AddImage(tex, { x0, y0 }, { x0 + size, y0 + size });
    imgui.Dummy({ size, size });
    local k = size / 512;
    local mx, my = imgui.GetMousePos();
    local tip = nil;
    for i, p in ipairs(z.points) do
        local f = floors[i];
        if (f == pick.floor or f == nil) then
            local px, py = zonemap.to_map(pick, p[1], p[3]);
            local cx, cy = x0 + px * k, y0 + py * k;
            if (f == nil) then
                dl:AddCircle({ cx, cy }, 4, style.col('dim', 230), 12, 1.5);
            else
                dl:AddCircleFilled({ cx, cy }, 4.5, style.col('shadow', 160), 12);
                dl:AddCircleFilled({ cx, cy }, 3.5, style.col('bad', 255), 12);
            end
            if ((mx - cx) ^ 2 + (my - cy) ^ 2 <= 36) then
                tip = ('Point spot %d: (%.0f, %.0f), height %.0f%s'):fmt(i, p[1], p[3], p[2], f == nil and '\nIts floor isn\'t known yet.' or '');
            end
        end
    end
    if (here and yx ~= nil) then
        local px, py = zonemap.to_map(pick, yx, yz);
        local cx, cy = x0 + px * k, y0 + py * k;
        dl:AddCircleFilled({ cx, cy }, 5.5, style.col('shadow', 180), 12);
        dl:AddCircleFilled({ cx, cy }, 4, style.col('accent', 255), 12);
        if ((mx - cx) ^ 2 + (my - cy) ^ 2 <= 36) then
            tip = 'You';
        end
    end
    if (tip ~= nil) then
        imgui.SetTooltip(tip);
    end
    dim(('The %d spots its points move between%s. A point shows at one at a time.'):fmt(#z.points, here and '; the gold dot is you' or ''));
    if (unknown > 0) then
        imgui.PushTextWrapPos(0);
        dim(('%d of them are on a floor not known yet (hollow): the game tells which floor a spot is on only in its zone, so they sort themselves once you\'re there.'):fmt(unknown));
        imgui.PopTextWrapPos();
    end
end

local function helm_detail(s, kind, z, nq, hq, label)
    style.big(zone_name(z.id), style.col('text'), 22);
    local tags = { };
    if (z.tag) then tags[#tags + 1] = { (model.EXPANSION_SHORT[z.tag] or z.tag) .. ' zone', 'dim' }; end
    if (z.level > 0) then tags[#tags + 1] = { ('nothing under level %d'):fmt(z.level), 'warn' }; end
    if (z.weather) then tags[#tags + 1] = { ('points only in %s'):fmt(z.weather), 'hq' }; end
    for i, t in ipairs(tags) do
        if (i > 1) then imgui.SameLine(0, 6); end
        style.tag(t[1], t[2]);
    end

    -- The odds, with and without gear.
    local tool = model.name(kind.tool);
    local b = helm.break_with(z, nq, hq);
    imgui.Spacing();
    style.tag(('finds %s'):fmt(model.pct(z.obtain)), 'good');
    imgui.SameLine(0, 6);
    style.tag(('breaks %s'):fmt(model.pct(b)), 'bad');
    imgui.SameLine(0, 6);
    style.tag(('%s finds a %s'):fmt(per(z.obtain / math.max(b, 1e-6)), tool:lower()), 'text');
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip(('Finds on average before the %s breaks, with %s.'):fmt(tool:lower(), label));
    end
    if (#kind.gear > 0) then
        local sets = helm.sets(kind);
        local wnq, whq = helm.worn(kind);
        local cols = {
            { 'no gear', 0, 0 }, { 'Field set', sets.field[1], sets.field[2] }, { 'Worker set', sets.worker[1], sets.worker[2] }, { 'what you wear', wnq, whq },
        };
        local w = imgui.GetContentRegionAvail();
        local cx = { w - 300, w - 225, w - 150, w - 75 };
        imgui.Spacing();
        dim('');
        for i, c in ipairs(cols) do
            right_text(cx[i] + 70, s.helmgear == GEAR_CHOICES[i][1] and 'accent' or 'dim', c[1]);
        end
        local function line(name, f, key)
            dim(name);
            for i, c in ipairs(cols) do
                right_text(cx[i] + 70, key, f(helm.break_with(z, c[2], c[3])));
            end
        end
        line('tool breaks', function (v) return model.pct(v); end, 'bad');
        line('tries a ' .. tool:lower(), function (v) return per(1 / math.max(v, 1e-6)); end, 'text');
        line('finds a ' .. tool:lower(), function (v) return per(z.obtain / math.max(v, 1e-6)); end, 'good');
    end

    -- The drops.
    imgui.SeparatorText('What it gives');
    local w = imgui.GetContentRegionAvail();
    local try_r, tool0_r, tool_r = w - 150, w - 75, w;
    dim('');
    right_text(try_r, 'dim', 'a try');
    right_text(tool0_r, 'dim', 'a tool, no gear');
    if (#kind.gear > 0 and (nq > 0 or hq > 0)) then
        right_text(tool_r, 'accent', 'with gear');
    end
    local b0 = z.brk;
    local worth, priced = 0, 0;
    for _, d in ipairs(z.drops) do
        local c = helm.chance(z, d);
        local name = model.name(d.id);
        if (d.id == helm.RED_ROCK) then
            name = 'Coloured rock (the day\'s)';
        end
        link(d.id, name);
        if (d.cap > 0) then
            imgui.SameLine(0, 6);
            style.tag(('cap %d a day'):fmt(d.cap), 'warn');
        end
        if (d.pool) then
            imgui.SameLine(0, 6);
            style.tag('runs out', 'warn');
            if (imgui.IsItemHovered()) then
                imgui.SetTooltip(('Each one of these (shared with the others marked so) makes the next rarer,\nand after %d none come until you zone.'):fmt(z.depletion));
            end
        end
        right_text(try_r, 'good', model.pct(c));
        right_text(tool0_r, 'text', per(c / math.max(b0, 1e-6)));
        if (#kind.gear > 0 and (nq > 0 or hq > 0)) then
            right_text(tool_r, 'accent', per(c / math.max(b, 1e-6)));
        end
        local v = prices.view[d.id];
        if (v ~= nil) then
            worth, priced = worth + c * v, priced + 1;
        end
    end
    if (priced > 0) then
        dim(('Worth about %s gil a try, %s a %s with %s (%d of %d drops priced).'):fmt(model.gil(worth), model.gil(worth / math.max(b, 1e-6)),
            tool:lower(), label, priced, #z.drops));
    end
    imgui.PushTextWrapPos(0);
    for _, d in ipairs(z.drops) do
        if (d.id == helm.RED_ROCK) then
            dim('The coloured rock is the day\'s: red on Firesday, translucent on Iceday, and so on.');
            break;
        end
    end
    for _, d in ipairs(z.drops) do
        if (d.cap > 0) then
            dim('A capped drop gets rarer with each one that day, and stops at the cap; it starts over the first time you zone in after midnight in Japan.');
            break;
        end
    end
    if (z.level > 0) then
        dim(('Under level %d (your main job) every try finds nothing, and the tool can still break.'):fmt(z.level));
    end
    dim(('A point moves after %d%% of finds (it\'s gone for %d seconds). One that moves away from under you and comes back to the same spot breaks tools %.1f times as often for you there.'):fmt(
        kind.relocate, kind.respawn, kind.camp));
    imgui.PopTextWrapPos();

    imgui.SeparatorText('Where the points are');
    helm_map(s, z, imgui.GetContentRegionAvail());
end

local function helm_body(s, you, k)
    if (helm.error ~= nil or helm.kinds == nil) then
        imgui.TextColored(style.f('bad'), ('No HELM data (%s). Run tools/gen_helm.py.'):fmt(tostring(helm.error)));
        return;
    end
    local kind = helm.kinds[k];
    helm_toolbar(s, kind);
    imgui.Spacing();
    local nq, hq, label = gear_points(s, kind);
    local rows = helm.rows(s, k, model.name, zone_name);
    local sel = nil;
    for _, row in ipairs(rows) do
        if (row.z.id == s.helmsel[k]) then
            sel = row.z;
        end
    end
    if (sel == nil and rows[1] ~= nil) then
        sel = rows[1].z;
        s.helmsel[k] = sel.id;
    end
    ui.hsel, ui.hpick = sel ~= nil and sel.id or nil, nil;
    local aw, ah = imgui.GetContentRegionAvail();
    local head = imgui.GetTextLineHeightWithSpacing();
    local lw = math.min(400, math.floor(aw * 0.42));
    local bodyh = math.max(80, ah - head - 4);
    imgui.BeginGroup();
    helm_list(s, kind, rows, lw, bodyh, nq, hq);
    imgui.EndGroup();
    if (ui.hpick ~= nil and ui.hpick ~= s.helmsel[k]) then
        s.helmsel[k], s.helmfloor, ui.dirty = ui.hpick, -1, true;
    end
    imgui.SameLine();
    imgui.BeginChild('ar_hdetail', { 0, bodyh + head }, ImGuiChildFlags_Borders);
    if (sel ~= nil) then
        helm_detail(s, kind, sel, nq, hq, label);
    end
    imgui.EndChild();
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
    local fish = s.craft == fishing.SKILL;
    local gather = s.craft >= helm.FIRST;
    local tab_name = gather and (helm.kinds ~= nil and helm.kinds[s.craft - helm.FIRST + 1].name or 'HELM') or player.skill_info(s.craft).name;
    local title = ('allrecipes - %s%s###allrecipes'):fmt(tab_name, (s.desynth and not fish and not gather) and ' desynthesis' or '');
    -- No close button: a - in its place minimizes it to the icon (/ar hides it).
    if (imgui.Begin(title, nil, bit.bor(ImGuiWindowFlags_NoSavedSettings, ImGuiWindowFlags_NoCollapse))) then
        local wx, wy = imgui.GetWindowPos();
        local ww, wh = imgui.GetWindowSize();
        if (tray.title_button('##ar_minimize', wx, wy, ww, { text = style.col('text'), hover = style.col('bar', 250), held = style.col('edge', 230) })) then
            s.minimized, ui.dirty = true, true;
        end
        -- A chip in the header can switch between a craft and fishing; the rest of the frame
        -- is left out then, and drawn for the new tab next frame.
        local craft = s.craft;
        if (fish or gather) then
            header(s, you);
            imgui.Spacing();
            if (s.craft == craft) then
                if (fish) then
                    fish_body(s, you);
                else
                    helm_body(s, you, craft - helm.FIRST + 1);
                end
            end
        elseif (model.error ~= nil) then
            imgui.TextColored(style.f('bad'), ('No recipe data (%s). Run tools/gen_recipes.py.'):fmt(model.error));
        elseif (header(s, you) or s.craft ~= craft) then
            imgui.Spacing();
        else
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

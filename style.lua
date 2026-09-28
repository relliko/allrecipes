--[[
* allrecipes - style
* The look, the same as scouter's: a rounded dark panel with a thin edge, pill chips, tinted
* tags and thin bars. Themes:
*   clean    - scouter's: neutral grey, amber for what's picked
*   guild    - warm leather and parchment, gold for what's picked
*   vanadiel - the game's own blue menu windows, with its gold cursor
* Colours for how hard a recipe is are part of each theme.
--]]

require('common');
local imgui = require('imgui');

local style = { theme = 'clean' };

style.THEMES = { { 'clean', 'Clean' }, { 'guild', 'Guild' }, { 'vanadiel', 'Vana\'diel' } };

-- Colours are { r, g, b } (0-255); alpha is given where they're used.
local THEMES = {
    clean = {
        panel  = { 24, 27, 32 },    panel_a = 235,
        edge   = { 95, 94, 90 },
        face   = { 18, 20, 24 },
        text   = { 241, 239, 232 },
        dim    = { 170, 168, 160 },
        bar    = { 68, 68, 65 },
        chip   = { 44, 44, 42 },
        accent = { 239, 159, 39 },   -- what's picked: amber
        good   = { 110, 205, 120 },  -- gil made, skill-ups
        bad    = { 226, 75, 74 },    -- gil lost
        hq     = { 133, 183, 235 },
        warn   = { 255, 204, 64 },
        shadow = { 0, 0, 0 },
        -- how hard a recipe is for you, hardest first
        band_cant  = { 130, 118, 116 },
        band_zero  = { 226, 75, 74 },
        band_hard  = { 239, 129, 49 },
        band_risky = { 255, 204, 64 },
        band_good  = { 110, 205, 120 },
        band_safe  = { 241, 239, 232 },
        band_hq    = { 133, 183, 235 },
    },
    guild = {
        panel  = { 36, 28, 21 },    panel_a = 240,
        edge   = { 140, 108, 66 },
        face   = { 27, 21, 16 },
        text   = { 242, 229, 204 },
        dim    = { 178, 158, 126 },
        bar    = { 78, 62, 43 },
        chip   = { 56, 44, 32 },
        accent = { 232, 180, 76 },   -- guild gold
        good   = { 156, 204, 104 },
        bad    = { 216, 92, 70 },
        hq     = { 122, 184, 222 },
        warn   = { 240, 202, 92 },
        shadow = { 0, 0, 0 },
        band_cant  = { 124, 108, 92 },
        band_zero  = { 216, 92, 70 },
        band_hard  = { 226, 138, 62 },
        band_risky = { 240, 202, 92 },
        band_good  = { 156, 204, 104 },
        band_safe  = { 242, 229, 204 },
        band_hq    = { 122, 184, 222 },
    },
    vanadiel = {
        panel  = { 16, 26, 58 },    panel_a = 235,
        edge   = { 128, 146, 196 },
        face   = { 10, 18, 42 },
        text   = { 238, 242, 252 },
        dim    = { 164, 176, 206 },
        bar    = { 44, 60, 104 },
        chip   = { 30, 45, 86 },
        accent = { 255, 216, 122 },  -- the menu cursor's gold
        good   = { 132, 222, 146 },
        bad    = { 242, 104, 104 },
        hq     = { 132, 206, 255 },
        warn   = { 250, 190, 92 },
        shadow = { 0, 0, 0 },
        band_cant  = { 112, 120, 146 },
        band_zero  = { 242, 104, 104 },
        band_hard  = { 246, 152, 82 },
        band_risky = { 250, 212, 102 },
        band_good  = { 132, 222, 146 },
        band_safe  = { 238, 242, 252 },
        band_hq    = { 132, 206, 255 },
    },
};

function style.set(theme)
    style.theme = THEMES[theme] ~= nil and theme or 'clean';
end

local function rgb(name)
    return (THEMES[style.theme] or THEMES.clean)[name] or THEMES.clean[name];
end

-- Packed ImGui colour (0xAABBGGRR) for a palette entry.
function style.col(name, alpha)
    local c = rgb(name);
    return (alpha or 255) * 16777216 + c[3] * 65536 + c[2] * 256 + c[1];
end

-- Float colour { r, g, b, a } for imgui.TextColored.
function style.f(name, alpha)
    local c = rgb(name);
    return { c[1] / 255, c[2] / 255, c[3] / 255, (alpha or 255) / 255 };
end

function style.panel_alpha()
    return (THEMES[style.theme] or THEMES.clean).panel_a;
end

-- Window background, title bar and border in the theme; pair with style.pop_window().
function style.push_window()
    imgui.PushStyleColor(ImGuiCol_WindowBg, style.f('panel', style.panel_alpha()));
    imgui.PushStyleColor(ImGuiCol_ChildBg, style.f('face', 120));
    imgui.PushStyleColor(ImGuiCol_TitleBg, style.f('panel', 240));
    imgui.PushStyleColor(ImGuiCol_TitleBgActive, style.f('chip', 250));
    imgui.PushStyleColor(ImGuiCol_TitleBgCollapsed, style.f('panel', 200));
    imgui.PushStyleColor(ImGuiCol_Border, style.f('edge', 170));
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 8);
    imgui.PushStyleVar(ImGuiStyleVar_ChildRounding, 6);
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 1);
end

function style.pop_window()
    imgui.PopStyleVar(3);
    imgui.PopStyleColor(6);
end

-- Widget colours: { ImGuiCol, palette entry, alpha }.
local CONTROLS = {
    { ImGuiCol_Text, 'text', 255 },           { ImGuiCol_PopupBg, 'panel', 245 },
    { ImGuiCol_FrameBg, 'chip', 230 },        { ImGuiCol_FrameBgHovered, 'bar', 240 },  { ImGuiCol_FrameBgActive, 'edge', 200 },
    { ImGuiCol_CheckMark, 'accent', 255 },
    { ImGuiCol_Button, 'chip', 240 },         { ImGuiCol_ButtonHovered, 'bar', 250 },   { ImGuiCol_ButtonActive, 'edge', 230 },
    { ImGuiCol_Header, 'chip', 240 },         { ImGuiCol_HeaderHovered, 'bar', 200 },   { ImGuiCol_HeaderActive, 'edge', 200 },
    { ImGuiCol_Separator, 'edge', 120 },
    { ImGuiCol_ScrollbarBg, 'face', 60 },     { ImGuiCol_ScrollbarGrab, 'chip', 255 },  { ImGuiCol_ScrollbarGrabHovered, 'bar', 255 },
    { ImGuiCol_ScrollbarGrabActive, 'edge', 255 },
};

-- Checkboxes, buttons, boxes and lists in the theme; pair with style.pop_controls().
function style.push_controls()
    for _, c in ipairs(CONTROLS) do
        imgui.PushStyleColor(c[1], style.f(c[2], c[3]));
    end
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 4);
end

function style.pop_controls()
    imgui.PopStyleVar(1);
    imgui.PopStyleColor(#CONTROLS);
end

--[[
* A rounded pill at (x, y): text in `fg` on `bg`, with an optional outline. Returns its size.
--]]
function style.pill(dl, x, y, text, fg, bg, border)
    local w, h = imgui.CalcTextSize(text);
    local pw, ph = w + 14, h + 6;
    dl:AddRectFilled({ x, y }, { x + pw, y + ph }, bg, ph / 2, ImDrawFlags_RoundCornersAll);
    if (border ~= nil) then
        dl:AddRect({ x, y }, { x + pw, y + ph }, border, ph / 2, ImDrawFlags_RoundCornersAll, 1);
    end
    dl:AddText({ x + 7, y + 3 }, fg, text);
    return pw, ph;
end

--[[
* A clickable pill at the cursor, reserving its space: lit (tinted with an outline, in `key`)
* when `on`. True when clicked.
--]]
function style.chip(id, text, on, key)
    local dl = imgui.GetWindowDrawList();
    local x, y = imgui.GetCursorScreenPos();
    local w, h = imgui.CalcTextSize(text);
    local hit = imgui.InvisibleButton(id, { w + 14, h + 6 });
    local hot = imgui.IsItemHovered();
    key = key or 'accent';
    if (on) then
        style.pill(dl, x, y, text, style.col(key), style.col(key, hot and 70 or 45), style.col(key, 150));
    else
        style.pill(dl, x, y, text, style.col(hot and 'text' or 'dim', 230), style.col('chip', hot and 255 or 200), nil);
    end
    return hit;
end

-- A tag at the cursor (tinted, outlined, in `key`), reserving its space.
function style.tag(text, key)
    local dl = imgui.GetWindowDrawList();
    local x, y = imgui.GetCursorScreenPos();
    local w, h = style.pill(dl, x, y, text, style.col(key), style.col(key, 45), style.col(key, 150));
    imgui.Dummy({ w, h });
end

-- A thin bar at the cursor, `fraction` full, reserving its space.
function style.bar(width, fraction, key)
    local dl = imgui.GetWindowDrawList();
    local x, y = imgui.GetCursorScreenPos();
    y = y + 4;
    dl:AddRectFilled({ x, y }, { x + width, y + 5 }, style.col('bar', 230), 2.5, ImDrawFlags_RoundCornersAll);
    if (fraction > 0) then
        dl:AddRectFilled({ x, y }, { x + math.max(5, width * math.min(1, fraction)), y + 5 }, style.col(key, 240), 2.5, ImDrawFlags_RoundCornersAll);
    end
    imgui.Dummy({ width, 13 });
end

-- Large text at the cursor (the font drawn bigger), reserving its space.
function style.big(text, color, size)
    local dl = imgui.GetWindowDrawList();
    local x, y = imgui.GetCursorScreenPos();
    local w, h = imgui.CalcTextSize(text);
    local k = size / math.max(imgui.GetFontSize(), 1);
    dl:AddText(imgui.GetFont(), size, { x, y }, color, text);
    imgui.Dummy({ w * k, h * k });
end

-- A small dot at the cursor, as tall as a line of text, reserving its space.
function style.dot(color)
    local dl = imgui.GetWindowDrawList();
    local x, y = imgui.GetCursorScreenPos();
    local _, h = imgui.CalcTextSize('A');
    dl:AddCircleFilled({ x + 5, y + h / 2 }, 4, color, 12);
    imgui.Dummy({ 12, h });
end

return style;

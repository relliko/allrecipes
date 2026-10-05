--[[
* allrecipes - icons
* Items' own icons, from the game's data (the resource manager's bitmap), as textures ImGui can
* draw. Each is made once and kept; one that can't be made gives nil, and a drawn shape stands in.
--]]

local ffi = require('ffi');

local icons = {
    cache  = { },   -- [item id] = texture
    failed = { },   -- [item id] = true when it couldn't be made
    C      = nil,   -- where D3DX is found: ffi.C (the tests stand in their own)
};

local function make(id)
    local d3d = require('d3d8');
    local C = icons.C or ffi.C;
    local item = AshitaCore:GetResourceManager():GetItemById(id);
    if (item == nil or item.Bitmap == nil or (item.ImageSize or 0) <= 0) then
        return nil;
    end
    local ptr = ffi.new('IDirect3DTexture8*[1]');
    if (C.D3DXCreateTextureFromFileInMemoryEx(d3d.get_device(), item.Bitmap, item.ImageSize, 0xFFFFFFFF, 0xFFFFFFFF, 1, 0,
            C.D3DFMT_A8R8G8B8, C.D3DPOOL_MANAGED, C.D3DX_DEFAULT, C.D3DX_DEFAULT, 0xFF000000, nil, nil, ptr) ~= C.S_OK) then
        return nil;
    end
    return d3d.gc_safe_release(ffi.cast('IDirect3DTexture8*', ptr[0]));
end

-- An item's icon as ImGui takes it, or nil.
function icons.get(id)
    local tex = icons.cache[id];
    if (tex == nil and not icons.failed[id]) then
        local ok, t = pcall(make, id);
        if (ok and t ~= nil) then
            tex = t;
            icons.cache[id] = t;
        else
            icons.failed[id] = true;
        end
    end
    return tex ~= nil and tonumber(ffi.cast('uint32_t', tex)) or nil;
end

return icons;

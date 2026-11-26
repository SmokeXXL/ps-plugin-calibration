-- ABOUTME: Shared helpers for plugin glue scripts: guarded preset reads,
-- ABOUTME: automatic bed-size detection, plate-visible errors, and numeric parsing.

local M = {}

--- Run fn safely; any error or nil result yields the fallback. Runtime errors
--- are invisible in the UI, so no preset read is allowed to take the run down.
function M.guarded(fallback, fn)
    local ok, v = pcall(fn)
    if ok and v ~= nil then return v end
    return fallback
end

--- Effective value of a per-tool setting for one slot, as the slicer resolves
--- it: the filament's override, else the tool print's, else the print
--- preset's, else fallback. Retraction and speeds are Print keys that the tool
--- print and the filament may override, so reading the print preset alone
--- returns a value this tool never prints with. A box that lacks the key, or
--- leaves the override unset, raises or yields nil and falls through.
--- When ignore_zero is true, non-positive numeric values (<= 0) are treated as
--- unset and fall through (prevents unchecked 0 overrides in PrusaSlicer 3.0
--- from disabling Z-hop or retraction speeds).
--- Returns the value and the box it came from.
function M.tool_value(bed, slot_idx, name, fallback, ignore_zero)
    local sources = {
        {"filament", function() return bed:material_presets(slot_idx):value(name) end},
        {"tool", function() return bed:tool_print_presets(slot_idx):value(name) end},
        {"print", function() return bed:print_presets():value(name) end},
    }
    for _, src in ipairs(sources) do
        local ok, v = pcall(src[2])
        if ok and v ~= nil then
            if not (ignore_zero and type(v) == "number" and v <= 0) then
                return v, src[1]
            end
        end
    end
    return fallback, "default"
end

--- Parse a PrusaSlicer bed_shape string (e.g. "0x0,248x0,248x205,0x205") into
--- width and depth [mm]. Returns nil if unparseable or degenerate.
function M.parse_bed_shape(shape)
    if type(shape) ~= "string" or shape == "" then return nil end
    local min_x, max_x = math.huge, -math.huge
    local min_y, max_y = math.huge, -math.huge
    local count = 0
    for xs, ys in shape:gmatch("([%-]?%d+%.?%d*)x([%-]?%d+%.?%d*)") do
        local x, y = tonumber(xs), tonumber(ys)
        if x and y then
            if x < min_x then min_x = x end
            if x > max_x then max_x = x end
            if y < min_y then min_y = y end
            if y > max_y then max_y = y end
            count = count + 1
        end
    end
    if count >= 3 and max_x > min_x and max_y > min_y then
        return max_x - min_x, max_y - min_y
    end
    return nil
end

--- Known printable bed dimensions [mm] for Prusa printers available in
--- PrusaSlicer 3.0 (alpha 14 and standard Prusa FFF bundle), matched by
--- printer_model. More specific variants (INDX, CORE One L) are checked first.
function M.bed_size_for_model(model)
    if type(model) ~= "string" or model == "" then return nil end
    local m = model:upper()
    -- CORE One INDX family (e.g. COREONE_INDX4T, COREONE_INDX8T, COREONEINDX):
    -- front tool dock reduces printable Y to 205 mm, X to 248 mm (center 124 x 102.5).
    if m:find("INDX", 1, true) then
        return 248, 205
    end
    -- CORE One L (e.g. COREONEL, COREONE_L)
    if m:find("COREONE_L", 1, true) or m:find("COREONEL", 1, true)
       or m:find("CORE ONE L", 1, true) then
        return 300, 300
    end
    -- CORE One / CORE One+
    if m:find("COREONE", 1, true) or m:find("CORE ONE", 1, true) then
        return 250, 220
    end
    -- Prusa XL (single / 2T / 5T / IS)
    if m == "XL" or m:match("^XL[%d_%-%s]") or m:find("XLIS", 1, true)
       or m:find("PRUSA.*XL") then
        return 360, 360
    end
    -- Prusa MINI / MINI+
    if m:find("MINI", 1, true) then
        return 180, 180
    end
    -- Prusa i3 family: MK4S, MK4, MK3.9S, MK3.9, MK3.5S, MK3.5, MK3S+, MK3S, MK3, MK2.5S, MK2.5, MK2S, MK2
    if m:find("MK4", 1, true) or m:find("MK3", 1, true) or m:find("MK2", 1, true) then
        return 250, 210
    end
    return nil
end

--- Resolve printable bed width and depth [mm].
--- Any positive value entered in the dialog overrides auto-detection for that axis.
--- When 0 (auto), tries printer_presets():value("bed_shape"), then printer_model
--- lookup (covering all PrusaSlicer 3.0 alpha 14 Prusa printers including CORE One INDX),
--- and finally falls back to 250 x 220 mm.
--- Returns bed_w, bed_d, source_string.
function M.resolve_bed_size(bed, req_w, req_d)
    local w = (req_w and req_w > 0) and req_w or nil
    local d = (req_d and req_d > 0) and req_d or nil
    if w and d then
        return w, d, "manual"
    end

    local det_w, det_d, src = nil, nil, nil
    local shape = M.guarded(nil, function()
        return bed:printer_presets():value("bed_shape")
    end)
    det_w, det_d = M.parse_bed_shape(shape)
    if det_w and det_d then
        src = "bed_shape"
    else
        local model = M.guarded("", function()
            return bed:printer_presets():value("printer_model")
        end)
        det_w, det_d = M.bed_size_for_model(model)
        if det_w and det_d then
            src = "model:" .. tostring(model)
        else
            det_w, det_d = 250, 220
            src = "default"
        end
    end

    if w and not d then
        return w, det_d, "manual+" .. src
    elseif d and not w then
        return det_w, d, src .. "+manual"
    end
    return det_w, det_d, src
end

--- 1-based tool index clamped to the number of tools the printer has, so a
--- too-large value cannot reach the extruder settings or the presets.
function M.clamp_tool(bed, requested)
    local idx = math.max(1, math.floor(tonumber(requested) or 1))
    local count = M.guarded(nil, function() return #bed:printer_config().tools end)
    if count and count >= 1 and idx > count then idx = count end
    return idx
end

--- Failures must be visible: emboss the message as an object on the plate.
function M.show_error(prefix, msg)
    print(prefix .. ": " .. msg)
    local ok = pcall(function()
        api.project:add_object{
            mesh = api.emboss_text{font = api.get_default_font(),
                                   text = msg, depth = 1},
            type = VolumeType.Solid,
        }
    end)
    if not ok then print(prefix .. ": could not create the error object") end
end

--- Parse a numeric string param (accepts both '.' and ','); garbage or nil yields the fallback.
function M.parse_number(s, default)
    if type(s) == "string" then
        s = s:gsub(",", ".")
    end
    local v = tonumber(s)
    if v == nil then return default end
    return v
end

return M

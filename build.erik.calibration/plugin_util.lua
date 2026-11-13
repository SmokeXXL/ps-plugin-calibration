-- ABOUTME: Shared helpers for plugin glue scripts: guarded preset reads,
-- ABOUTME: plate-visible error reporting, and numeric param parsing.

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
--- Returns the value and the box it came from.
function M.tool_value(bed, slot_idx, name, fallback)
    local sources = {
        {"filament", function() return bed:material_presets(slot_idx):value(name) end},
        {"tool", function() return bed:tool_print_presets(slot_idx):value(name) end},
        {"print", function() return bed:print_presets():value(name) end},
    }
    for _, src in ipairs(sources) do
        local ok, v = pcall(src[2])
        if ok and v ~= nil then return v, src[1] end
    end
    return fallback, "default"
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

--- Parse a numeric string param; garbage or nil yields the fallback.
function M.parse_number(s, default)
    local v = tonumber(s)
    if v == nil then return default end
    return v
end

return M

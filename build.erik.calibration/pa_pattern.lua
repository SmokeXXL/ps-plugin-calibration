-- ABOUTME: PA Pattern calibration plugin: prints the Ellis or Lines pressure-advance pattern
-- ABOUTME: via a handle object plus per-layer custom G-code with printed value labels.

-- `require` is unavailable at scan time, so params are written literally; tests in
-- tests/test_firmware.lua keep the firmware param equal to firmware.PARAM.
info = {
    id = "pa_pattern",
    type = "project.plugin",
    title = "PA Pattern",
    menu = "Calibration/PA Pattern",
    params = {
        {name = "tool", label = "Extruder / Tool (1 = T0, 2 = T1...)", type = "int", default = 1},
        {name = "use_lines", label = "Use Lines Pattern", type = "bool", default = true},
        {name = "draw_labels", label = "Print Labels", type = "bool", default = true},
        {name = "draw_frame", label = "Draw Frame", type = "bool", default = false},
        {name = "nozzle", label = "Nozzle [mm] (0 = auto)", type = "string", default = "0"},
        {name = "layer_height", label = "Layer Height [mm] (0 = auto)", type = "string", default = "0"},
        -- PA values are strings: the dialog's float control rounds to whole
        -- numbers (upstream bug), so fractional values cannot use type "float".
        {name = "pa_start", label = "PA Start", type = "string", default = "0"},
        {name = "pa_end", label = "PA End", type = "string", default = "0.08"},
        {name = "pa_step", label = "PA Step", type = "string", default = "0.005"},
        {name = "speed", label = "Speed [mm/s] (0 = auto)", type = "int", default = 0},
        {name = "accel", label = "Acceleration [mm/s^2] (0 = leave alone)", type = "int", default = 0},
        {name = "bed_width", label = "Bed Width [mm] (0 = auto)", type = "int", default = 0},
        {name = "bed_depth", label = "Bed Depth [mm] (0 = auto)", type = "int", default = 0},
        {
            name = "firmware",
            label = "Firmware (auto|marlin|marlin2|prusabuddy|klipper|rrf|repetier)",
            type = "string",
            default = "auto",
        },
    },
}

function execute(opts)
    local util = require("plugin_util")
    local firmware = require("firmware")
    local gen = require("pa_pattern_gen")

    local bed = api.project:current_bed()
    local flavor = firmware.from_bed(bed, opts.firmware)
    if firmware.set_pressure_advance(flavor, 0) == nil then
        util.show_error("PA Pattern", "PA: NO PA COMMAND FOR " .. flavor)
        return
    end

    local rel_e = util.guarded(true, function()
        return bed:printer_presets():value("use_relative_e_distances")
    end)
    if rel_e ~= true then
        util.show_error("PA Pattern", "PA: NEEDS RELATIVE E")
        return
    end

    local tool_idx = util.clamp_tool(bed, opts.tool)
    local slot_idx = tool_idx - 1

    local ui_nozzle = util.parse_number(opts.nozzle, 0)
    local ui_lh = util.parse_number(opts.layer_height, 0)

    -- Přepínače: true = zapnuto, false = vypnuto
    local is_lines = (opts.use_lines ~= false)

    local bed_w, bed_d, bed_src = util.resolve_bed_size(bed, opts.bed_width, opts.bed_depth)

    local S = {
        tool_idx = tool_idx,
        slot_idx = slot_idx,
        pattern = is_lines and "lines" or "ellis",
        draw_labels = (opts.draw_labels ~= false),
        draw_frame = (opts.draw_frame == true),
        pa_start = util.parse_number(opts.pa_start, 0),
        pa_end = util.parse_number(opts.pa_end, 0.08),
        pa_step = util.parse_number(opts.pa_step, 0.005),
        speed = opts.speed,
        accel = opts.accel,
        bed_w = bed_w,
        bed_d = bed_d,
        flavor = flavor,
        layer_height = (ui_lh > 0) and ui_lh or util.guarded(0.2, function()
            return bed:print_presets():value("layer_height")
        end),
        nozzle = (ui_nozzle > 0) and ui_nozzle or util.guarded(0.4, function()
            local tools = bed:printer_config().tools
            if tools and tools[tool_idx] then
                return tools[tool_idx]:nozzle_diameter()
            end
            return tools[1]:nozzle_diameter()
        end),
        perimeter_speed = util.tool_value(bed, slot_idx, "perimeter_speed", 0),
        travel_speed = util.tool_value(bed, slot_idx, "travel_speed", 150, true),
        vol_cap = util.guarded(0, function()
            return bed:material_presets(slot_idx):value("filament_max_volumetric_speed")
        end),
        filament_d = util.guarded(1.75, function()
            return bed:material_presets(slot_idx):value("filament_diameter")
        end),
        flow_mult = util.guarded(1.0, function()
            return bed:material_presets(slot_idx):value("extrusion_multiplier")
        end),
        retract = util.tool_value(bed, slot_idx, "retract_length", 0.8, "overrides"),
        retract_speed = util.tool_value(bed, slot_idx, "retract_speed", 35, true),
        deretract_speed = util.tool_value(bed, slot_idx, "deretract_speed", 0),
        zhop = util.tool_value(bed, slot_idx, "retract_lift", 0.5, "overrides"),
        retract_layer_change = util.tool_value(bed, slot_idx, "retract_layer_change", true),
    }
    local _, retract_src = util.tool_value(bed, slot_idx, "retract_length", 0.8, "overrides")
    local _, lift_src = util.tool_value(bed, slot_idx, "retract_lift", 0.5, "overrides")
    print(string.format(
        "PA Pattern: Tool T%d retract %.2f mm @ %g mm/s (from %s), lift %.2f (from %s); max flow %g mm3/s; bed %gx%g (%s)",
        slot_idx, S.retract, S.retract_speed, retract_src, S.zhop, lift_src, S.vol_cap, bed_w, bed_d, bed_src))

    if S.pa_start < 0 or S.pa_step <= 0 or S.pa_end < S.pa_start + S.pa_step then
        util.show_error("PA Pattern", "PA: BAD RANGE")
        return
    end

    local r = gen.build(S)
    if not r.fits then
        util.show_error("PA Pattern", "PA: BED TOO SMALL")
        return
    end

    -- Force slicer to use selected tool for global settings and wiping
    bed:print_presets():set("perimeter_extruder", tool_idx)
    bed:print_presets():set("infill_extruder", tool_idx)
    bed:print_presets():set("solid_infill_extruder", tool_idx)
    bed:print_presets():set("support_material_extruder", tool_idx)
    bed:print_presets():set("support_material_interface_extruder", tool_idx)

    -- Known layer grid (sync both layer_height and first_layer_height with dialog),
    -- and keep slicer-drawn loops out of the pattern area.
    bed:print_presets():set("layer_height", S.layer_height)
    bed:print_presets():set("first_layer_height", S.layer_height)
    pcall(function() bed:print_presets():set("brim_type", "no_brim") end)
    bed:print_presets():set("skirts", 0)

    -- Custom-gcode inserts poke the bed instance directly and fire no
    -- slicing-input-changed event; add_object does. Inserting first means the
    -- snapshot taken when the handle appears carries the blobs with it.
    api.project:clear_layer_custom_steps(bed)
    for _, layer in ipairs(r.layers) do
        api.project:insert_layer_custom_gcode(bed, layer.insert_z, layer.gcode)
    end
    util.add_handle(r.handle, S.tool_idx)

    print(string.format("PA Pattern: Tool T%d, %s, %s, frame=%s, PA %g..%g step %g, speed %d mm/s",
                        S.slot_idx, flavor, S.pattern, tostring(S.draw_frame), S.pa_start, r.pa_end_effective, S.pa_step, r.speed))
    if r.clamped then
        print(string.format("PA Pattern: range clamped to fit the bed; PA End now %g",
                            r.pa_end_effective))
    end
end

-- ABOUTME: Flow-ratio calibration plugin: prints a grid of pads at stepped flow
-- ABOUTME: multipliers via per-layer custom G-code, optionally labeled on a tab.

info = {
    id = "flow_ratio",
    type = "project.plugin",
    title = "Flow Ratio",
    menu = "Calibration/Flow Ratio",
    params = {
        {name = "tool", label = "Extruder / Tool (1 = T0, 2 = T1...)", type = "int", default = 1},
        {name = "use_monotonic", label = "Zigzag Top Fill (off = Archimedean)", type = "bool", default = true},
        {name = "sparse_infill", label = "Sparse Infill Cushion (20%, 10 layers; off = 5 solid)", type = "bool", default = true},
        {name = "draw_labels", label = "Print Labels", type = "bool", default = true},
        {name = "nozzle", label = "Nozzle [mm] (0 = auto)", type = "string", default = "0"},
        {name = "layer_height", label = "Layer Height [mm] (0 = auto)", type = "string", default = "0"},
        {name = "start_flow", label = "Min Flow (start)", type = "string", default = "0.95"},
        {name = "count", label = "Sample Count", type = "int", default = 11},
        {name = "step", label = "Step", type = "string", default = "0.01"},
        {name = "speed", label = "Speed [mm/s] (0 = auto)", type = "int", default = 0},
        {name = "bed_width", label = "Bed Width [mm] (0 = auto)", type = "int", default = 0},
        {name = "bed_depth", label = "Bed Depth [mm] (0 = auto)", type = "int", default = 0},
    },
}

function execute(opts)
    local util = require("plugin_util")
    local gen = require("flow_ratio_gen")

    local bed = api.project:current_bed()

    local rel_e = util.guarded(true, function()
        return bed:printer_presets():value("use_relative_e_distances")
    end)
    if rel_e ~= true then
        util.show_error("Flow Ratio", "FLOW: NEEDS RELATIVE E")
        return
    end

    local tool_idx = util.clamp_tool(bed, opts.tool)
    local slot_idx = tool_idx - 1

    local ui_nozzle = util.parse_number(opts.nozzle, 0)
    local ui_lh = util.parse_number(opts.layer_height, 0)

    -- Přepínač: true = monotonic, false = archimedean
    local is_monotonic = (opts.use_monotonic ~= false)

    local bed_w, bed_d, bed_src = util.resolve_bed_size(bed, opts.bed_width, opts.bed_depth)

    local S = {
        tool_idx = tool_idx,
        slot_idx = slot_idx,
        sparse_infill = (opts.sparse_infill ~= false),
        draw_labels = (opts.draw_labels ~= false),
        start_flow = util.parse_number(opts.start_flow, 0.95),
        count = math.max(1, opts.count or 11),
        step = util.parse_number(opts.step, 0.01),
        pattern = is_monotonic and "monotonic" or "archimedean",
        speed = opts.speed,
        bed_w = bed_w,
        bed_d = bed_d,
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
        flow_mult = 1.0,
        retract = util.tool_value(bed, slot_idx, "retract_length", 0.8, "filament"),
        retract_speed = util.tool_value(bed, slot_idx, "retract_speed", 35, true),
        deretract_speed = util.tool_value(bed, slot_idx, "deretract_speed", 0),
        zhop = util.tool_value(bed, slot_idx, "retract_lift", 0.5, "filament"),
        retract_layer_change = util.tool_value(bed, slot_idx, "retract_layer_change", true),
    }
    local _, retract_src = util.tool_value(bed, slot_idx, "retract_length", 0.8, "filament")
    local _, lift_src = util.tool_value(bed, slot_idx, "retract_lift", 0.5, "filament")
    print(string.format(
        "Flow Ratio: Tool T%d retract %.2f mm @ %g mm/s (from %s), lift %.2f (from %s); max flow %g mm3/s; bed %gx%g (%s)",
        slot_idx, S.retract, S.retract_speed, retract_src, S.zhop, lift_src, S.vol_cap, bed_w, bed_d, bed_src))

    if S.start_flow <= 0 or S.step < 0 then
        util.show_error("Flow Ratio", "FLOW: BAD PARAMS")
        return
    end

    local r = gen.build(S)
    if not r.fits then
        util.show_error("Flow Ratio", "FLOW: BED TOO SMALL")
        return
    end

    local layer_h = S.layer_height
    bed:print_presets():set("layer_height", layer_h)
    bed:print_presets():set("first_layer_height", layer_h)
    pcall(function() bed:print_presets():set("brim_type", "no_brim") end)
    bed:print_presets():set("skirts", 0)

    -- Force slicer to use selected tool for global settings and wiping
    bed:print_presets():set("perimeter_extruder", tool_idx)
    bed:print_presets():set("infill_extruder", tool_idx)
    bed:print_presets():set("solid_infill_extruder", tool_idx)
    bed:print_presets():set("support_material_extruder", tool_idx)
    bed:print_presets():set("support_material_interface_extruder", tool_idx)

    api.project:clear_layer_custom_steps(bed)
    for _, layer in ipairs(r.layers) do
        api.project:insert_layer_custom_gcode(bed, layer.insert_z, layer.gcode)
    end

    util.add_handle(r.handle, S.tool_idx)

    print(string.format(
        "Flow Ratio: Tool T%d, %d pads, %d layers (sparse=%s), labels=%s, flow %.3f..%.3f (step %.3f), pattern %s",
        S.slot_idx, S.count, #r.layers, tostring(S.sparse_infill),
        tostring(S.draw_labels), r.v_min, r.v_max, S.step, S.pattern))
end

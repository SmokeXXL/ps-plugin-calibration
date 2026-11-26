-- ABOUTME: Builds the ironing calibration plate as per-layer G-code blobs: a
-- ABOUTME: 2D grid of pads (optionally labeled) with custom ironing passes on the top layer. Pure.

info = nil

local M = {}

M.PAD_W = 30.0
M.PAD_H = 20.0
M.TAB_W = 24.0
M.TAB_H = 7.0
M.TAB_LAYERS = 2
M.GAP = 6.0
M.LAYERS = 10              -- default 2.0 mm realistic pad height at 0.2 mm (3 bottom + 2 sparse 20% + 5 top)
M.PERIMETERS = 2           -- rigid 2-wall shell around sparse infill cushion
M.SPARSE_INFILL_DENSITY = 0.20
M.BOTTOM_MIN_MM = 0.60
M.SPARSE_MIN_MM = 0.40
M.TOP_MIN_MM = 1.00        -- >= 1.0 mm top shell prevents thermal pillowing during slow ironing
M.SOLID_MIN_MM = 1.00
M.MARGIN = 10.0
M.HANDLE_XY = 5.0
M.CLEARANCE = 3.0          -- gap between the centered handle cube and the grid [mm]
M.FIRST_LAYER_SPEED = 30
M.GLYPH_SPEED = 20
M.WALL_SPEED_FRACTION = 0.6
M.TOP_SPEED_FRACTION = 0.5
M.INSERT_Z_FRACTION = 0.5
M.IRONING_INSET_FRACTION = 0.25

function M.resolve_speed(draw, requested, perimeter_speed, vol_cap, line_width, layer_height)
    local speed = (requested and requested > 0) and requested
                  or math.max(100, perimeter_speed or 0)
    if vol_cap and vol_cap > 0 then
        speed = math.min(speed, vol_cap / draw.bead_area(line_width, layer_height))
    end
    return math.floor(speed)
end

local function fmt_compact(v)
    return string.format("%.3g", v)
end

--- Build a layer plan scaled to layer_height.
--- With realistic_base = true (default): >= 0.6 mm bottom solid (min 3 layers),
--- >= 0.4 mm sparse 20% infill (min 2 layers), and >= 1.0 mm top solid shell
--- (min 5 layers at 0.20 mm) to reflect real printed parts and resist pillowing.
--- With realistic_base = false: fast 100% solid stack (>= 1.0 mm, min 5 layers).
function M.build_layer_plan(layer_height, realistic_base)
    local h = (layer_height and layer_height > 0) and layer_height or 0.2
    local plan = {}
    local function add_layer(role, width, density)
        local idx = #plan + 1
        local angle = (idx % 2 == 1) and 45 or 135
        table.insert(plan, {
            role = role,
            width = width,
            angle = angle,
            density = density,
        })
    end

    if realistic_base ~= false then
        local n_bottom = math.max(3, math.ceil(M.BOTTOM_MIN_MM / h - 1e-9))
        local n_sparse = math.max(2, math.ceil(M.SPARSE_MIN_MM / h - 1e-9))
        local n_top = math.max(4, math.ceil(M.TOP_MIN_MM / h - 1e-9))

        for k = 1, n_bottom do
            add_layer("bottom", (k == 1) and "first" or "solid")
        end
        for _ = 1, n_sparse do
            add_layer("sparse", "solid", M.SPARSE_INFILL_DENSITY)
        end
        for k = 1, n_top do
            add_layer((k == n_top) and "top" or "solid", "solid")
        end
    else
        local total = math.max(5, math.ceil(M.SOLID_MIN_MM / h - 1e-9))
        for k = 1, total do
            if k == 1 then
                add_layer("bottom", "first")
            elseif k == total then
                add_layer("top", "solid")
            else
                add_layer("solid", "solid")
            end
        end
    end
    return plan
end

-- Default 10-layer realistic plan for 0.20 mm layer height (3 bottom + 2 sparse 20% + 5 top).
M.LAYER_PLAN = M.build_layer_plan(0.2, true)

function M.layout(S)
    local L = {}
    L.h = S.layer_height or (S.nozzle / 2)
    L.draw_labels = (S.draw_labels ~= false)
    L.width = {
        wall = 1.125 * S.nozzle,
        first = 1.40 * S.nozzle,
        solid = 1.20 * S.nozzle,
    }

    local f_start = S.flow_start or 10
    local f_step = S.flow_step or 5
    local f_count = math.max(1, S.flow_count or 4)

    local s_start = S.speed_start or 15
    local s_step = S.speed_step or 15
    local s_count = math.max(1, S.speed_count or 3)

    L.cols = f_count
    L.rows = s_count

    L.flow_min = f_start
    L.flow_max = f_start + (f_count - 1) * f_step
    L.speed_min = s_start
    L.speed_max = s_start + (s_count - 1) * s_step

    local cell_w = M.PAD_W
    local cell_h = M.PAD_H + (L.draw_labels and M.TAB_H or 0)
    L.pitch_x = cell_w + M.GAP
    L.pitch_y = cell_h + M.GAP
    L.span_x = L.cols * cell_w + (L.cols - 1) * M.GAP
    L.span_y = L.rows * cell_h + (L.rows - 1) * M.GAP

    -- The handle cube is placed at the bed center (bed_w/2, bed_d/2) by PrusaSlicer.
    -- Position the grid dynamically outside the handle cube (same logic as PA Pattern):
    -- prefer above, else below, else to the right, else to the left.
    -- Only if the grid is too large for any single side, split rows around the cube
    -- using an 8 mm row gap so the cube stays safely between rows.
    local cx, cy = S.bed_w / 2, S.bed_d / 2
    local above_y = cy + M.HANDLE_XY / 2 + M.CLEARANCE
    local below_y = cy - M.HANDLE_XY / 2 - M.CLEARANCE - L.span_y
    local right_x = cx + M.HANDLE_XY / 2 + M.CLEARANCE
    local left_x = cx - M.HANDLE_XY / 2 - M.CLEARANCE - L.span_x

    local fits_x_centered = (cx - L.span_x / 2 >= M.MARGIN)
                            and (cx + L.span_x / 2 <= S.bed_w - M.MARGIN)
    local fits_y_centered = (cy - L.span_y / 2 >= M.MARGIN)
                            and (cy + L.span_y / 2 <= S.bed_d - M.MARGIN)

    if fits_x_centered and (above_y + L.span_y <= S.bed_d - M.MARGIN) then
        L.xbase = cx - L.span_x / 2
        L.ybase = above_y
    elseif fits_x_centered and (below_y >= M.MARGIN) then
        L.xbase = cx - L.span_x / 2
        L.ybase = below_y
    elseif fits_y_centered and (right_x + L.span_x <= S.bed_w - M.MARGIN) then
        L.xbase = right_x
        L.ybase = cy - L.span_y / 2
    elseif fits_y_centered and (left_x >= M.MARGIN) then
        L.xbase = left_x
        L.ybase = cy - L.span_y / 2
    else
        local split_gap = math.max(M.GAP, 8.0)
        L.pitch_y = cell_h + split_gap
        L.span_y = L.rows * cell_h + (L.rows - 1) * split_gap
        L.xbase = cx - L.span_x / 2
        L.ybase = cy + split_gap / 2 - (L.rows // 2) * L.pitch_y
    end

    L.extents = {
        min_x = L.xbase,
        min_y = L.ybase,
        max_x = L.xbase + L.span_x,
        max_y = L.ybase + L.span_y,
    }
    L.fits = L.extents.min_x >= M.MARGIN and L.extents.min_y >= M.MARGIN
             and L.extents.max_x <= S.bed_w - M.MARGIN
             and L.extents.max_y <= S.bed_d - M.MARGIN

    L.pads = {}
    for r = 0, L.rows - 1 do
        local ir_speed = s_start + r * s_step
        for c = 0, L.cols - 1 do
            local ir_flow = f_start + c * f_step
            local x0 = L.xbase + c * L.pitch_x
            local y0 = L.ybase + r * L.pitch_y
            local label
            if L.rows == 1 then
                label = fmt_compact(ir_flow)
            elseif L.cols == 1 then
                label = fmt_compact(ir_speed)
            else
                label = fmt_compact(ir_speed) .. " " .. fmt_compact(ir_flow)
            end
            table.insert(L.pads, {
                x0 = x0,
                y0 = y0,
                iron_flow = ir_flow,
                iron_speed = ir_speed,
                label = label,
                tab_x0 = x0 + (M.PAD_W - M.TAB_W) / 2,
                tab_y0 = y0 + M.PAD_H - L.width.wall,
            })
        end
    end
    return L
end

function M.ironing_epm(draw, nozzle, layer_height, spacing, filament_d, base_flow_mult, iron_flow_pct)
    local normal_spacing = nozzle - layer_height * (1 - math.pi / 4)
    local effective_mult = base_flow_mult * (iron_flow_pct / 100.0) * (spacing / normal_spacing)
    return draw.e_per_mm(nozzle, layer_height, filament_d, effective_mult)
end

function M.draw_pad(draw, w, pad, i, S, L, speed, plan)
    plan = plan or M.LAYER_PLAN[i]
    local z = i * L.h
    local width = L.width[plan.width]
    local wall_w = (i == 1) and L.width.first or L.width.wall
    local base_mult = S.flow_mult or 1.0

    local epm = draw.e_per_mm(width, L.h, S.filament_d, base_mult)
    local epm_wall = draw.e_per_mm(wall_w, L.h, S.filament_d, base_mult)
    local wall_speed = (i == 1) and M.FIRST_LAYER_SPEED
                       or math.floor(speed * M.WALL_SPEED_FRACTION)
    local fill_speed = speed
    if i == 1 then
        fill_speed = M.FIRST_LAYER_SPEED
    elseif plan.role == "top" then
        fill_speed = math.floor(speed * M.TOP_SPEED_FRACTION)
    end

    local perimeters = M.PERIMETERS
    draw.draw_box(w, pad.x0, pad.y0, M.PAD_W, M.PAD_H,
                  {perimeters = perimeters, line_width = wall_w, layer_height = L.h,
                   epm = epm_wall, speed = wall_speed, layer_z = z,
                   fill = false})

    local wall_spacing = wall_w - L.h * (1 - math.pi / 4)
    local fx, fy = pad.x0 + perimeters * wall_spacing, pad.y0 + perimeters * wall_spacing
    local fsz_x = M.PAD_W - 2 * perimeters * wall_spacing
    local fsz_y = M.PAD_H - 2 * perimeters * wall_spacing
    local fill_opts = {
        line_width = width,
        layer_height = L.h,
        epm = epm,
        speed = fill_speed,
        layer_z = z,
        angle = plan.angle,
    }
    if plan.role == "sparse" then
        local solid_spacing = width - L.h * (1 - math.pi / 4)
        fill_opts.spacing = solid_spacing / (plan.density or M.SPARSE_INFILL_DENSITY)
    end
    draw.fill_zigzag(w, fx, fy, fsz_x, fsz_y, fill_opts)

    -- Ironing pass right after the top solid layer is completed (always perpendicular to top fill)
    if plan.role == "top" then
        local iron_angle = (plan.angle == 45) and 135 or 45
        draw.emit(w, string.format("; IRONING pass: speed %g mm/s, flow %g%%, spacing %.3f mm, angle %d",
                                   pad.iron_speed, pad.iron_flow, S.spacing, iron_angle))
        local inset = S.nozzle * M.IRONING_INSET_FRACTION
        local ix = pad.x0 + inset
        local iy = pad.y0 + inset
        local isz_x = M.PAD_W - 2 * inset
        local isz_y = M.PAD_H - 2 * inset
        local epm_iron = M.ironing_epm(draw, S.nozzle, L.h, S.spacing,
                                       S.filament_d, base_mult, pad.iron_flow)
        draw.fill_zigzag(w, ix, iy, isz_x, isz_y, {
            line_width = S.nozzle,
            layer_height = L.h,
            spacing = S.spacing,
            epm = epm_iron,
            speed = pad.iron_speed,
            layer_z = z,
            angle = iron_angle,
        })
    end

    -- Optional label tab and 7-segment numbers (height 1 layer, thickness 2 perimeters)
    if L.draw_labels then
        if i <= M.TAB_LAYERS then
            draw.draw_box(w, pad.tab_x0, pad.tab_y0, M.TAB_W,
                          M.TAB_H + L.width.wall,
                          {perimeters = 1, line_width = wall_w, layer_height = L.h,
                           epm = epm_wall, speed = wall_speed, layer_z = z,
                           fill = true})
        elseif i == M.TAB_LAYERS + 1 then
            draw.emit(w, string.format("; LABEL %s", pad.label))
            local glyph_w = L.width.wall
            local epm_glyph = draw.e_per_mm(glyph_w, L.h, S.filament_d, base_mult)
            local raw_w = math.max(2.0, draw.text_width(pad.label))
            local max_w = M.TAB_W - 2.0
            local scale = math.min(1.0, max_w / raw_w)
            local ox = pad.tab_x0 + (M.TAB_W - raw_w * scale) / 2
            local oy = pad.tab_y0 + L.width.wall + (M.TAB_H - 4.0 * scale) / 2
            draw.draw_number(w, ox, oy, pad.label, {
                epm = epm_glyph,
                speed = M.GLYPH_SPEED,
                layer_z = z,
                horizontal = true,
                scale = scale,
                line_width = glyph_w,
                layer_height = L.h,
                perimeters = 2,
            })
        end
    end
end

function M.build(S)
    local draw = require("draw")
    local L = M.layout(S)
    local layer_plan = M.build_layer_plan(L.h, S.realistic_base ~= false)
    local total_layers = #layer_plan
    local base_mult = S.flow_mult or 1.0
    local vol_cap = (S.vol_cap and S.vol_cap > 0) and S.vol_cap / base_mult or 0
    local speed = M.resolve_speed(draw, S.speed, S.perimeter_speed, vol_cap,
                                  L.width.solid, L.h)
    local layers = {}
    local entry = draw.writer_opts(S)

    for i = 1, total_layers do
        local plan = layer_plan[i]
        local w = draw.new(entry)
        draw.emit(w, string.format("; IRONING_CALIBRATION layer %d/%d (%s)", i, total_layers, plan.role))
        draw.emit(w, "G90")
        draw.emit(w, "M83")
        for _, pad in ipairs(L.pads) do
            M.draw_pad(draw, w, pad, i, S, L, speed, plan)
        end
        draw.emit(w, "; park over the handle")
        draw.park_at(w, S.bed_w / 2, S.bed_d / 2, i * L.h)
        if not entry.retracted then draw.unretract(w) end
        table.insert(layers, {
            z = i * L.h,
            insert_z = (i - M.INSERT_Z_FRACTION) * L.h,
            gcode = draw.gcode(w),
        })
    end

    return {
        handle = {size_xy = M.HANDLE_XY, height = total_layers * L.h},
        pads = L.pads,
        layers = layers,
        speed = speed,
        fits = L.fits,
        extents = L.extents,
        flow_min = L.flow_min,
        flow_max = L.flow_max,
        speed_min = L.speed_min,
        speed_max = L.speed_max,
    }
end

return M

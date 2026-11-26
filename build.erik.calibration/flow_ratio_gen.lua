-- ABOUTME: Builds the flow-ratio calibration plate as per-layer G-code blobs: a
-- ABOUTME: grid of pads (optionally labeled), each extruded at its own flow multiplier. Pure.

info = nil

-- Lazy proxy: `require` is unavailable while the plugin scan loads this file,
-- so the module is resolved on first use (at execute time).
local draw = setmetatable({}, {__index = function(_, k) return require("draw")[k] end})

local M = {}

M.PAD_W = 30.0
M.PAD_H = 20.0
M.TAB_W = 20.0
M.TAB_H = 7.0
M.TAB_LAYERS = 2
M.GAP = 6.0
M.COLS = 4
M.LAYERS = 10              -- default 2.0 mm pad height at 0.2 mm layer height (3 bottom + 2 sparse + 5 top)
M.PERIMETERS = 2           -- rigid 2-wall shell around sparse infill cushion
M.SPARSE_INFILL_DENSITY = 0.20
M.BOTTOM_MIN_MM = 0.60
M.SPARSE_MIN_MM = 0.40
M.TOP_MIN_MM = 1.00
M.SOLID_MIN_MM = 1.00
M.MARGIN = 10.0
M.HANDLE_XY = 5.0
M.CLEARANCE = 3.0          -- gap between the centered handle cube and the grid [mm]
M.FIRST_LAYER_SPEED = 30
M.GLYPH_SPEED = 20
M.WALL_SPEED_FRACTION = 0.6
M.TOP_SPEED_FRACTION = 0.5
M.INSERT_Z_FRACTION = 0.5

function M.resolve_speed(requested, perimeter_speed, vol_cap, line_width, layer_height)
    local speed = (requested and requested > 0) and requested
                  or math.max(100, perimeter_speed or 0)
    if vol_cap and vol_cap > 0 then
        speed = math.min(speed, vol_cap / draw.bead_area(line_width, layer_height))
    end
    return math.floor(speed)
end

--- Build a layer plan scaled to layer_height.
--- With use_sparse = true (default): >= 0.6 mm bottom solid (min 3 layers),
--- >= 0.4 mm sparse 20% infill cushion (min 2 layers) so over-extrusion from
--- bottom layers does not accumulate upward, and >= 1.0 mm top solid shell
--- (min 4 layers, 5 at 0.20 mm) so the top evaluation surface bridges cleanly.
--- With use_sparse = false: fast solid stack (>= 1.0 mm, min 5 layers).
function M.build_layer_plan(layer_height, use_sparse)
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

    if use_sparse ~= false then
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
    -- Align alternating angles so the final top layer always prints at 45 deg
    -- (finishes at bottom-right, exiting across the gap instead of over the pad).
    local total_n = #plan
    for idx = 1, total_n do
        plan[idx].angle = ((total_n - idx) % 2 == 0) and 45 or 135
    end
    return plan
end

-- Default 10-layer plan for 0.20 mm layer height (3 bottom + 2 sparse 20% + 5 top).
M.LAYER_PLAN = M.build_layer_plan(0.2, true)

function M.layout(S)
    local L = {}
    L.h = S.layer_height or (S.nozzle / 2)
    L.draw_labels = (S.draw_labels ~= false)
    L.width = {wall = 1.125 * S.nozzle, first = 1.40 * S.nozzle,
               solid = 1.20 * S.nozzle}

    local start_val = S.start_flow or 0.95
    local step_val = S.step or 0.01
    local count = math.max(1, S.count or 11)

    L.values = {}
    for p = 1, count do
        table.insert(L.values, start_val + (p - 1) * step_val)
    end

    local n = #L.values
    L.v_min = L.values[1]
    L.v_max = L.values[n]

    local cell_w = M.PAD_W
    local cell_h = M.PAD_H + (L.draw_labels and M.TAB_H or 0)
    local cx, cy = S.bed_w / 2, S.bed_d / 2
    local usable_w = S.bed_w - 2 * M.MARGIN
    local max_cols = math.max(1, math.floor((usable_w + M.GAP) / (cell_w + M.GAP)))

    -- The handle cube is placed at the bed center (bed_w/2, bed_d/2) by PrusaSlicer.
    -- Try column counts from M.COLS up to max_cols so the entire grid stays cleanly
    -- OUTSIDE the handle cube (preferring above with the fewest rows, then below,
    -- then right, then left). On a 250x220 bed, up to 18 labeled pads fit above the cube.
    local placed = false
    local best = nil
    local min_try_cols = math.min(M.COLS, n)
    local max_try_cols = math.min(max_cols, n)

    local function try_place(cols)
        local rows = (n + cols - 1) // cols
        local sx = cols * cell_w + (cols - 1) * M.GAP
        local sy = rows * cell_h + (rows - 1) * M.GAP
        local above_y = cy + M.HANDLE_XY / 2 + M.CLEARANCE
        local below_y = cy - M.HANDLE_XY / 2 - M.CLEARANCE - sy
        local right_x = cx + M.HANDLE_XY / 2 + M.CLEARANCE
        local left_x = cx - M.HANDLE_XY / 2 - M.CLEARANCE - sx
        local fx = (cx - sx / 2 >= M.MARGIN) and (cx + sx / 2 <= S.bed_w - M.MARGIN)
        local fy = (cy - sy / 2 >= M.MARGIN) and (cy + sy / 2 <= S.bed_d - M.MARGIN)
        if fx and (above_y + sy <= S.bed_d - M.MARGIN) then
            return {prio = 1, rows = rows, cols = cols, sx = sx, sy = sy, xbase = cx - sx / 2, ybase = above_y}
        elseif fx and (below_y >= M.MARGIN) then
            return {prio = 2, rows = rows, cols = cols, sx = sx, sy = sy, xbase = cx - sx / 2, ybase = below_y}
        elseif fy and (right_x + sx <= S.bed_w - M.MARGIN) then
            return {prio = 3, rows = rows, cols = cols, sx = sx, sy = sy, xbase = right_x, ybase = cy - sy / 2}
        elseif fy and (left_x >= M.MARGIN) then
            return {prio = 4, rows = rows, cols = cols, sx = sx, sy = sy, xbase = left_x, ybase = cy - sy / 2}
        end
        return nil
    end

    for c = min_try_cols, max_try_cols do
        local cand = try_place(c)
        if cand then
            if not best
               or cand.prio < best.prio
               or (cand.prio == best.prio and cand.rows < best.rows) then
                best = cand
            end
        end
    end

    L.pitch_x = cell_w + M.GAP
    L.pitch_y = cell_h + M.GAP

    if best then
        L.cols = best.cols
        L.rows = best.rows
        L.span_x = best.sx
        L.span_y = best.sy
        L.xbase = best.xbase
        L.ybase = best.ybase
        placed = true
    else
        -- Grid too large for any single side: widen to max_cols and split rows around
        -- the center handle cube with a generous 12 mm corridor.
        L.cols = max_try_cols
        L.rows = (n + L.cols - 1) // L.cols
        local split_gap = math.max(M.GAP, 12.0)
        L.pitch_y = cell_h + split_gap
        L.span_x = L.cols * cell_w + (L.cols - 1) * M.GAP
        L.span_y = L.rows * cell_h + (L.rows - 1) * split_gap
        L.xbase = cx - L.span_x / 2
        L.ybase = cy + split_gap / 2 - (L.rows // 2) * L.pitch_y
    end

    L.extents = {min_x = L.xbase, min_y = L.ybase,
                 max_x = L.xbase + L.span_x, max_y = L.ybase + L.span_y}
    L.fits = L.extents.min_x >= M.MARGIN and L.extents.min_y >= M.MARGIN
             and L.extents.max_x <= S.bed_w - M.MARGIN
             and L.extents.max_y <= S.bed_d - M.MARGIN

    L.pads = {}
    for p = 1, n do
        local col = (p - 1) % L.cols
        local row = (p - 1) // L.cols
        local x0 = L.xbase + col * L.pitch_x
        local y0 = L.ybase + row * L.pitch_y
        local v = L.values[p]
        table.insert(L.pads, {
            x0 = x0, y0 = y0, v = v, label = draw.fmt_value(v),
            tab_x0 = x0 + (M.PAD_W - M.TAB_W) / 2,
            tab_y0 = y0 + M.PAD_H - L.width.wall,
        })
    end
    return L
end

function M.draw_pad(w, pad, i, S, L, speed, plan)
    plan = plan or M.LAYER_PLAN[i]
    local z = i * L.h
    local width = L.width[plan.width]
    local wall_w = (i == 1) and L.width.first or L.width.wall
    local epm = draw.e_per_mm(width, L.h, S.filament_d, pad.v)
    local epm_wall = draw.e_per_mm(wall_w, L.h, S.filament_d, pad.v)
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
    local opts = {line_width = width, layer_height = L.h, epm = epm,
                  speed = fill_speed, layer_z = z, angle = plan.angle}
    if plan.role == "sparse" then
        local solid_spacing = width - L.h * (1 - math.pi / 4)
        opts.spacing = solid_spacing / (plan.density or M.SPARSE_INFILL_DENSITY)
        draw.fill_zigzag(w, fx, fy, fsz_x, fsz_y, opts)
    elseif plan.role == "top" and S.pattern == "archimedean" then
        draw.fill_archimedean_chords(w, fx, fy, fsz_x, fsz_y, opts)
    else
        draw.fill_zigzag(w, fx, fy, fsz_x, fsz_y, opts)
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
            local epm_glyph = draw.e_per_mm(glyph_w, L.h, S.filament_d, pad.v)
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
    local L = M.layout(S)
    local layer_plan = M.build_layer_plan(L.h, S.sparse_infill ~= false)
    local total_layers = #layer_plan
    local vol_cap = (S.vol_cap and S.vol_cap > 0) and S.vol_cap / L.v_max or 0
    local speed = M.resolve_speed(S.speed, S.perimeter_speed, vol_cap,
                                  L.width.solid, L.h)
    local layers = {}
    local entry = draw.writer_opts(S)
    for i = 1, total_layers do
        local plan = layer_plan[i]
        local w = draw.new(entry)
        draw.emit(w, string.format("; FLOW_RATIO layer %d/%d (%s)", i, total_layers, plan.role))
        draw.emit(w, "G90")
        draw.emit(w, "M83")
        for _, pad in ipairs(L.pads) do
            M.draw_pad(w, pad, i, S, L, speed, plan)
        end
        draw.emit(w, "; park over the handle")
        draw.park_at(w, S.bed_w / 2, S.bed_d / 2, i * L.h)
        if not entry.retracted then draw.unretract(w) end
        table.insert(layers, {z = i * L.h,
                              insert_z = (i - M.INSERT_Z_FRACTION) * L.h,
                              gcode = draw.gcode(w)})
    end
    return {
        handle = {size_xy = M.HANDLE_XY, height = total_layers * L.h},
        pads = L.pads,
        layers = layers,
        speed = speed,
        fits = L.fits,
        extents = L.extents,
        v_min = L.v_min,
        v_max = L.v_max,
    }
end

return M

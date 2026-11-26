-- ABOUTME: Builds the Ellis and Lines pressure-advance patterns as per-layer
-- ABOUTME: G-code blobs keyed to the handle object's layer heights. Pure.

-- Lazy proxies: `require` is unavailable while the plugin scan loads this file,
-- so each module is resolved on first use. Names are literals (marketplace check).
local draw = setmetatable({}, {__index = function(_, k) return require("draw")[k] end})
local firmware = setmetatable({}, {__index = function(_, k) return require("firmware")[k] end})

local M = {}

M.HANDLE_XY = 4.0          -- handle cube footprint [mm]
M.LAYERS = 4               -- pattern layers (Ellis)
M.LEG = 30.0               -- chevron leg length [mm]
M.WALLS = 3                -- nested walls per chevron / frame perimeters
M.CLEARANCE = 3.0          -- gap between the handle cube and the pattern [mm]
M.PRIME_GAP = 3.5          -- gap between the prime line and the pattern/frame [mm]
M.MARGIN = 10.0            -- minimum pattern distance from the bed edge [mm]
M.GLYPH_PAD = 1.5          -- padding inside the number tab [mm]
M.GLYPH_SCALE = 1.25       -- 25% larger digits (5 mm tall instead of 4 mm)
M.FIRST_LAYER_SPEED = 30   -- frame/tab/layer-1 speed [mm/s]
M.GLYPH_SPEED = 20         -- digit drawing speed [mm/s], Orca's pattern value
M.INSERT_Z_FRACTION = 0.5  -- blobs inserted at (i - this) * layer_height

--- Orca's find_optimal_PA_speed: at least 100 mm/s (or the profile's perimeter
--- speed if higher), capped by the filament volumetric limit; cap 0 = uncapped.
function M.resolve_speed(requested, perimeter_speed, vol_cap, line_width, layer_height)
    local speed = (requested and requested > 0) and requested
                  or math.max(100, perimeter_speed or 0)
    if vol_cap and vol_cap > 0 then
        speed = math.min(speed, vol_cap / draw.bead_area(line_width, layer_height))
    end
    return math.floor(speed)
end

--- Volumetric cap in "flow_mult = 1" terms: the beads are extruded at
--- flow_mult, so the filament limit corresponds to a smaller geometric flow.
local function vol_cap_for(S)
    local m = (S.flow_mult and S.flow_mult > 0) and S.flow_mult or 1
    return (S.vol_cap and S.vol_cap > 0) and S.vol_cap / m or 0
end

--- True when the footprint keeps MARGIN from every bed edge.
local function within(e, S)
    local eps = 1e-6
    return e.min_x >= M.MARGIN - eps and e.min_y >= M.MARGIN - eps
       and e.max_x <= S.bed_w - M.MARGIN + eps
       and e.max_y <= S.bed_d - M.MARGIN + eps
end

--------------------------------------------------------------------------------
-- ELLIS PATTERN GENERATOR
--------------------------------------------------------------------------------

function M.layout_ellis(S)
    local L = {}
    L.lw = 1.125 * S.nozzle
    L.lw_first = 1.40 * S.nozzle
    L.h = S.layer_height
    L.spacing = L.lw - L.h * (1 - math.pi / 4)
    L.wall_shift = L.spacing * math.sqrt(2)
    L.pitch = 2.5 + L.lw
    L.dx = M.LEG / math.sqrt(2)
    L.dy = M.LEG / math.sqrt(2)

    local glyph_h = 4.0 * M.GLYPH_SCALE
    local n = math.ceil((S.pa_end - S.pa_start) / S.pa_step - 1e-9) + 1
    local function width_for(count)
        local chev = (count - 1) * L.pitch + L.dx + (M.WALLS - 1) * L.wall_shift
        local labels = S.draw_labels and ((count + 4) * L.pitch + glyph_h) or 0
        return math.max(chev, labels)
    end
    local spacing_first = L.lw_first - L.h * (1 - math.pi / 4)
    L.wall_band = M.WALLS * spacing_first
    L.frame_pad = L.wall_band + M.GLYPH_PAD

    L.frame_h = 2 * L.dy
    L.tab_gap = (S.draw_labels and S.draw_frame) and spacing_first or 0
    L.tab_h = S.draw_labels and (5 * 3.0 * M.GLYPH_SCALE + 2 * M.GLYPH_PAD) or 0
    local total_h = L.frame_h + L.tab_gap + L.tab_h

    -- The handle cube is placed at the bed center (bed_w/2, bed_d/2) by PrusaSlicer.
    -- Position the pattern dynamically around it so the cube always stays outside:
    -- prefer above the cube (uses full bed width), else below, else to the right.
    local cx, cy = S.bed_w / 2, S.bed_d / 2
    local above_y = cy + M.HANDLE_XY / 2 + M.CLEARANCE
    local below_y = cy - M.HANDLE_XY / 2 - M.CLEARANCE - total_h
    local placed, usable
    if above_y + total_h <= S.bed_d - M.MARGIN then
        placed = "above"
        L.frame_min_y = above_y
        usable = (S.bed_w - 2 * M.MARGIN) - M.PRIME_GAP - 2 * L.frame_pad
    elseif below_y >= M.MARGIN then
        placed = "below"
        L.frame_min_y = below_y
        usable = (S.bed_w - 2 * M.MARGIN) - M.PRIME_GAP - 2 * L.frame_pad
    else
        placed = "right"
        L.frame_min_y = cy - L.frame_h / 2
        local right_x = cx + M.HANDLE_XY / 2 + M.CLEARANCE + M.PRIME_GAP
        usable = (S.bed_w - M.MARGIN) - right_x - 2 * L.frame_pad
    end

    L.clamped = false
    while n > 2 and width_for(n) > usable do
        n = n - 1
        L.clamped = true
    end
    L.num_patterns = n
    L.pattern_w = width_for(n)
    L.frame_w = L.pattern_w + 2 * L.frame_pad

    if placed == "above" or placed == "below" then
        L.frame_min_x = cx - (L.frame_w - M.PRIME_GAP) / 2
    else
        L.frame_min_x = cx + M.HANDLE_XY / 2 + M.CLEARANCE + M.PRIME_GAP
    end
    L.prime_x = L.frame_min_x - M.PRIME_GAP
    L.tab_min_y = L.frame_min_y + L.frame_h + L.tab_gap
    L.pat_min_x = L.frame_min_x + L.frame_pad
    L.pat_min_y = L.frame_min_y

    L.first_y0 = L.frame_min_y + L.wall_band + 0.5
    L.first_dy = (L.frame_h - 2 * L.wall_band - 1.0) / 2
    L.first_dx = L.first_dy
    L.first_x_off = L.dx - L.first_dx
    return L
end

local function draw_chevrons(w, L, S, z, epm, speed, geo)
    for j = 0, L.num_patterns - 1 do
        draw.emit(w, firmware.set_pressure_advance(S.flavor, S.pa_start + j * S.pa_step))
        local base_x = L.pat_min_x + j * L.pitch + geo.x_off
        for k = 0, M.WALLS - 1 do
            local x0 = base_x + k * L.wall_shift
            draw.travel_to(w, x0, geo.y0, z)
            draw.line_to(w, x0 + geo.dx, geo.y0 + geo.dy, epm, speed)
            draw.line_to(w, x0, geo.y0 + 2 * geo.dy, epm, speed)
        end
    end
end

local function draw_labels(w, L, S, z, epm_glyph, speed)
    local opts = {
        epm = epm_glyph,
        speed = M.GLYPH_SPEED,
        layer_z = z,
        scale = M.GLYPH_SCALE,
        line_width = L.lw,
        layer_height = L.h,
        perimeters = 2,
    }
    local glyph_h = 4.0 * M.GLYPH_SCALE
    local oy = L.tab_min_y + M.GLYPH_PAD
    for j = 0, L.num_patterns - 1, 2 do
        local ox = L.pat_min_x + j * L.pitch + glyph_h
        draw.draw_number(w, ox, oy, draw.fmt_value(S.pa_start + j * S.pa_step), opts)
    end
    local flow = speed * draw.bead_area(L.lw, L.h) * S.flow_mult
    draw.draw_number(w, L.pat_min_x + (L.num_patterns + 2) * L.pitch + glyph_h, oy,
                     draw.fmt_value(flow), opts)
    if S.accel and S.accel > 0 then
        draw.draw_number(w, L.pat_min_x + (L.num_patterns + 4) * L.pitch + glyph_h, oy,
                         string.format("%d", S.accel), opts)
    end
end

function M.build_ellis(S)
    local L = M.layout_ellis(S)
    local speed = M.resolve_speed(S.speed, S.perimeter_speed, vol_cap_for(S), L.lw, L.h)
    local epm = draw.e_per_mm(L.lw, L.h, S.filament_d, S.flow_mult)
    local epm_first = draw.e_per_mm(L.lw_first, L.h, S.filament_d, S.flow_mult)
    local epm_glyph = draw.e_per_mm(L.lw, L.h, S.filament_d, S.flow_mult)

    local layers = {}
    local entry = draw.writer_opts(S)
    for i = 1, M.LAYERS do
        local z = i * L.h
        local w = draw.new(entry)
        draw.emit(w, string.format("; PA_PATTERN layer %d", i))
        draw.emit(w, "G90")
        draw.emit(w, "M83")
        local accel_cmd = firmware.set_acceleration(S.flavor, S.accel)
        if accel_cmd then draw.emit(w, accel_cmd) end
        if i == 1 then
            draw.emit(w, firmware.set_pressure_advance(S.flavor, S.pa_start))
            if S.draw_frame then
                local box = {perimeters = M.WALLS, line_width = L.lw_first,
                             layer_height = L.h, epm = epm_first,
                             speed = M.FIRST_LAYER_SPEED, layer_z = z, fill = false}
                draw.draw_box(w, L.frame_min_x, L.frame_min_y, L.frame_w, L.frame_h, box)
            end
            if S.draw_labels then
                local tab = {perimeters = 1, line_width = L.lw_first,
                             layer_height = L.h, epm = epm_first,
                             speed = M.FIRST_LAYER_SPEED, layer_z = z, fill = true}
                draw.draw_box(w, L.frame_min_x, L.tab_min_y, L.frame_w, L.tab_h, tab)
            end
        end

        local chev_speed = (i == 1) and M.FIRST_LAYER_SPEED or speed
        -- Prime line before the pattern on every layer to stabilize nozzle pressure
        draw.emit(w, "; prime line")
        draw.emit(w, firmware.set_pressure_advance(S.flavor, S.pa_start))
        local prime_epm = (i == 1) and epm_first or epm
        draw.travel_to(w, L.prime_x, L.frame_min_y, z)
        draw.line_to(w, L.prime_x, L.frame_min_y + L.frame_h, prime_epm, M.FIRST_LAYER_SPEED)

        local geo = (i == 1 and S.draw_frame)
            and {x_off = L.first_x_off, y0 = L.first_y0, dx = L.first_dx, dy = L.first_dy}
            or {x_off = 0, y0 = L.pat_min_y, dx = L.dx, dy = L.dy}
        draw_chevrons(w, L, S, z, epm, chev_speed, geo)

        -- Tisk čísel pouze ve 2. vrstvě (výška max 1 vrstva, tloušťka 2 perimetry)
        if i == 2 and S.draw_labels then
            draw.emit(w, firmware.set_pressure_advance(S.flavor, 0))
            draw_labels(w, L, S, z, epm_glyph, speed)
        end

        -- every layer ends at PA 0: the handle cube prints right after this blob
        draw.emit(w, firmware.set_pressure_advance(S.flavor, 0))
        draw.emit(w, "; park over the handle")
        draw.park_at(w, S.bed_w / 2, S.bed_d / 2, z)
        if not entry.retracted then draw.unretract(w) end
        table.insert(layers, {z = z, insert_z = (i - M.INSERT_Z_FRACTION) * L.h,
                              gcode = draw.gcode(w)})
    end

    local extents = {min_x = L.prime_x, min_y = L.frame_min_y,
                     max_x = L.frame_min_x + L.frame_w,
                     max_y = L.tab_min_y + L.tab_h}
    return {
        fits = within(extents, S),
        handle = {size_xy = M.HANDLE_XY, height = M.LAYERS * L.h},
        layers = layers,
        speed = speed,
        clamped = L.clamped,
        pa_end_effective = S.pa_start + (L.num_patterns - 1) * S.pa_step,
        extents = extents,
    }
end

--------------------------------------------------------------------------------
-- LINES PATTERN GENERATOR
--------------------------------------------------------------------------------

M.LINES_GLYPH_SCALE = 1.0      -- 4 mm tall digits (compact for Lines only; Ellis & other tests unchanged)
M.LINES_FINE_STEP = 0.002      -- pa_step <= this automatically starts at every-2nd-line labeling

function M.layout_lines(S)
    local L = {}
    L.lw = 1.125 * S.nozzle
    L.lw_first = 1.40 * S.nozzle
    L.h = S.layer_height
    L.slow_len = 20.0
    L.fast_len = 40.0
    L.line_span_y = L.slow_len * 2 + L.fast_len  -- 80 mm vertical calibration lines (along Y)
    L.pad_x = 4.0                                 -- frame overhang left & right of first/last line
    L.layers = S.draw_labels and 2 or 1
    L.glyph_scale = M.LINES_GLYPH_SCALE

    local spacing_first = L.lw_first - L.h * (1 - math.pi / 4)
    L.spacing_first = spacing_first
    L.wall_band = M.WALLS * spacing_first

    local n_req = math.ceil((S.pa_end - S.pa_start) / S.pa_step - 1e-9) + 1
    L.label_h = 18.0           -- height of label strip above lines (fits 5-char numbers @ scale 1.0 + padding)
    L.total_h = L.line_span_y + (S.draw_labels and L.label_h or 0)

    local cx, cy = S.bed_w / 2, S.bed_d / 2
    local above_y = cy + M.HANDLE_XY / 2 + M.CLEARANCE

    -- Stack lines across the bed WIDTH (X) with the prime line to the LEFT of the pattern.
    local usable_x = (S.bed_w - 2 * M.MARGIN) - M.PRIME_GAP - 2 * L.pad_x

    -- Adaptive density tiers {pitch_x, label_every}:
    -- Normal (5.2 mm, every 1st) for coarse steps;
    -- Dense (3.0 mm, every 2nd) automatically when pa_step <= 0.002 or when normal doesn't fit;
    -- Ultra-dense (2.0 mm, every 5th) when even dense doesn't fit all requested lines.
    local tiers
    if not S.draw_labels then
        tiers = {{3.0, 1}, {2.0, 1}}
    elseif S.pa_step <= M.LINES_FINE_STEP + 1e-9 then
        tiers = {{3.0, 2}, {2.0, 5}}
    else
        tiers = {{5.2, 1}, {3.0, 2}, {2.0, 5}}
    end

    local n, clamped, pitch_x, label_every = n_req, false, nil, nil
    for _, tier in ipairs(tiers) do
        local tx_pitch, tx_every = tier[1], tier[2]
        if (n_req - 1) * tx_pitch <= usable_x + 1e-9 then
            pitch_x, label_every = tx_pitch, tx_every
            break
        end
    end

    if not pitch_x then
        local densest = tiers[#tiers]
        pitch_x, label_every = densest[1], densest[2]
        clamped = true
        n = math.min(n_req, math.max(2, math.floor(usable_x / pitch_x) + 1))
    end

    L.pitch_x = pitch_x
    L.label_every = label_every
    L.clamped = clamped
    L.num_lines = n
    L.span_x = (n - 1) * L.pitch_x
    L.frame_w = L.span_x + 2 * L.pad_x
    local total_w = M.PRIME_GAP + L.frame_w

    -- Center full horizontal extent [prime_x .. frame_min_x + frame_w] around bed center X
    L.prime_x = cx - total_w / 2
    L.frame_min_x = L.prime_x + M.PRIME_GAP
    L.min_x = L.frame_min_x + L.pad_x

    -- Vertical placement:
    -- 1) Above the centered handle cube if it fits in the upper half of the bed,
    -- 2) Else centered in Y with two symmetric 4x4 mm handle cubes 3 mm above & below.
    if above_y + L.total_h <= S.bed_d - M.MARGIN + 1e-9 then
        L.frame_min_y = above_y
        L.handle_dual = false
        L.handle_dx = 0
        L.handle_dy = 0
        L.park_x = cx
        L.park_y = cy
    else
        L.frame_min_y = cy - L.total_h / 2
        L.handle_dual = true
        L.handle_dx = 0
        L.handle_dy = L.total_h + 2 * M.CLEARANCE + M.HANDLE_XY
        L.park_x = cx
        L.park_y = L.frame_min_y + L.total_h + M.CLEARANCE + M.HANDLE_XY / 2
    end

    L.min_y = L.frame_min_y
    L.max_x = L.frame_min_x + L.frame_w
    L.max_y = L.frame_min_y + L.total_h
    return L
end

function M.build_lines(S)
    local L = M.layout_lines(S)
    local speed = M.resolve_speed(S.speed, S.perimeter_speed, vol_cap_for(S), L.lw, L.h)
    local epm = draw.e_per_mm(L.lw, L.h, S.filament_d, S.flow_mult)
    local epm_first = draw.e_per_mm(L.lw_first, L.h, S.filament_d, S.flow_mult)
    local epm_glyph = draw.e_per_mm(L.lw, L.h, S.filament_d, S.flow_mult)

    local entry = draw.writer_opts(S)
    local layers = {}

    for i = 1, L.layers do
        local z = i * L.h
        local w = draw.new(entry)

        draw.emit(w, string.format("; PA_PATTERN LINES layer %d", i))
        draw.emit(w, "G90")
        draw.emit(w, "M83")
        local accel_cmd = firmware.set_acceleration(S.flavor, S.accel)
        if accel_cmd then draw.emit(w, accel_cmd) end

        local slow_speed = M.FIRST_LAYER_SPEED

        if i == 1 then
            draw.emit(w, firmware.set_pressure_advance(S.flavor, 0))

            -- 1. Volitelný obvodový rámeček (pouze v 1. vrstvě)
            if S.draw_frame then
                local frame_box = {
                    perimeters = M.WALLS,
                    line_width = L.lw_first,
                    layer_height = L.h,
                    epm = epm_first,
                    speed = slow_speed,
                    layer_z = z,
                    fill = false,
                }
                draw.draw_box(w, L.frame_min_x, L.frame_min_y, L.frame_w, L.line_span_y, frame_box)
            end

            -- 2. Společný podklad pro čísla nad linkami (bez překryvu s rámečkem)
            if S.draw_labels then
                local tab_y = S.draw_frame and (L.frame_min_y + L.line_span_y + L.spacing_first)
                                           or (L.frame_min_y + L.line_span_y + 1.0)
                local tab_h = S.draw_frame and (L.label_h - L.spacing_first)
                                           or (L.label_h - 1.0)
                local tab = {
                    perimeters = 2,
                    line_width = L.lw_first,
                    layer_height = L.h,
                    epm = epm_first,
                    speed = slow_speed,
                    layer_z = z,
                    fill = true,
                }
                draw.draw_box(w, L.frame_min_x, tab_y, L.frame_w, tab_h, tab)
            end

            -- 3. Prime linka vedle vzoru (vlevo) pro ustálení tlaku v trysce
            draw.emit(w, "; prime line")
            draw.emit(w, firmware.set_pressure_advance(S.flavor, S.pa_start))
            draw.travel_to(w, L.prime_x, L.frame_min_y, z)
            draw.line_to(w, L.prime_x, L.frame_min_y + L.line_span_y, epm_first, slow_speed)

            -- 4. Vykreslení kalibračních linek (svisle po Y, skládané na šířku bedu po X)
            local overlap = S.draw_frame and (L.wall_band * 0.5) or 0
            for j = 0, L.num_lines - 1 do
                local pa = S.pa_start + j * S.pa_step
                draw.emit(w, firmware.set_pressure_advance(S.flavor, pa))
                local x = L.min_x + j * L.pitch_x
                local y = L.frame_min_y + overlap

                draw.travel_to(w, x, y, z)
                y = L.frame_min_y + L.slow_len
                draw.line_to(w, x, y, epm, slow_speed)

                y = y + L.fast_len
                draw.line_to(w, x, y, epm, speed)

                y = L.frame_min_y + L.line_span_y - overlap
                draw.line_to(w, x, y, epm, slow_speed)
            end

            draw.emit(w, firmware.set_pressure_advance(S.flavor, 0))

        elseif i == 2 and S.draw_labels then
            -- Tisk čísel pouze ve 2. vrstvě (otočeno o 90 st. nad jednotlivé linky)
            draw.emit(w, firmware.set_pressure_advance(S.flavor, 0))

            local gscale = L.glyph_scale or M.LINES_GLYPH_SCALE
            local glyph_h = 4.0 * gscale
            local label_every = L.label_every or 1
            local oy = L.frame_min_y + L.line_span_y + 2.0
            local opts = {
                epm = epm_glyph,
                speed = M.GLYPH_SPEED,
                layer_z = z,
                horizontal = false,
                scale = gscale,
                line_width = L.lw,
                layer_height = L.h,
                perimeters = 2,
            }
            for j = 0, L.num_lines - 1, label_every do
                local pa = S.pa_start + j * S.pa_step
                local x = L.min_x + j * L.pitch_x
                draw.draw_number(w, x + glyph_h / 2, oy, draw.fmt_value(pa), opts)
            end
        end

        draw.emit(w, "; park over the handle")
        draw.park_at(w, L.park_x, L.park_y, z)
        if not entry.retracted then draw.unretract(w) end

        table.insert(layers, {z = z, insert_z = (i - M.INSERT_Z_FRACTION) * L.h,
                              gcode = draw.gcode(w)})
    end

    local extents = {min_x = L.prime_x, min_y = L.frame_min_y,
                     max_x = L.max_x, max_y = L.max_y}
    local cx, cy = S.bed_w / 2, S.bed_d / 2
    local h_min_y = L.handle_dual and (cy - L.handle_dy / 2 - M.HANDLE_XY / 2) or (cy - M.HANDLE_XY / 2)
    local h_max_y = L.handle_dual and (cy + L.handle_dy / 2 + M.HANDLE_XY / 2) or (cy + M.HANDLE_XY / 2)
    local fits = within(extents, S) and h_min_y >= 5.0 and h_max_y <= S.bed_d - 5.0
    return {
        fits = fits,
        handle = {size_xy = M.HANDLE_XY, height = L.layers * L.h,
                  dual = L.handle_dual, dx = L.handle_dx, dy = L.handle_dy},
        layers = layers,
        speed = speed,
        clamped = L.clamped,
        pa_end_effective = S.pa_start + (L.num_lines - 1) * S.pa_step,
        extents = extents,
    }
end

--------------------------------------------------------------------------------
-- MAIN ROUTER
--------------------------------------------------------------------------------

function M.build(S)
    assert(firmware.set_pressure_advance(S.flavor, 0),
           "flavor has no pressure-advance command: " .. tostring(S.flavor))

    if S.pattern == "lines" then
        return M.build_lines(S)
    else
        return M.build_ellis(S)
    end
end

return M

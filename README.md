# Calibration Plugin for PrusaSlicer 3

Printer calibration tools for the Lua plugin system introduced in PrusaSlicer 3.0.

![PA Pattern printed on a Prusa CORE One](pa-pattern_demo.jpg)

## Plugins

The `build.erik.calibration` bundle adds four tests under
**Menu ▸ Plugins ▸ Calibration**, listed here in the order to run them:

| # | Test | Tunes | Set it in PrusaSlicer |
|---|---|---|---|
| 1 | [Flow Ratio](#1-flow-ratio) | How much plastic is extruded | *Filament → Filament → Extrusion multiplier* |
| 2 | [PA Pattern](#2-pa-pattern) | Pressure at speed changes and corners | *Filament → Extrusion & Calibration → Pressure advance* |
| 3 | [Retraction](#3-retraction) | Stringing across travel moves | *Printer → Extruder → Retraction → Length* (or the filament override) |
| 4 | [Ironing](#4-ironing) | Top-surface smoothing pass | *Print → Infill → Ironing* and *Print → Speed → Ironing* |

Each test generates its own G-code, so it ignores most of your print
profile. It reads only the nozzle diameter, layer height, filament
diameter, max volumetric speed, travel and retraction settings, and the
results of the tests before it.

## Install

Copy (or symlink) the `build.erik.calibration` directory into PrusaSlicer's
user plugin folder, then **Menu ▸ Plugins ▸ Rescan Plugins**:

| OS | Plugin folder |
|---|---|
| macOS | `~/Library/Application Support/PrusaSlicer3-dev/lua/` |
| Windows | `%APPDATA%\PrusaSlicer3-dev\lua\` |
| Linux | `~/.var/app/com.prusa3d.PrusaSlicer/config/PrusaSlicer3-dev/lua/` |

(The `-dev` suffix applies to alpha/beta builds.)

**Requires PrusaSlicer 3.0.0-alpha11 or newer.**

## Building a release

The plugin files must stay in a directory named `build.erik.calibration`
(it matches the `id` in `manifest.json`); `release.sh` packages that
directory.

- **Local build** — `./release.sh --local` writes
  `build.erik.calibration-v<version>.zip` to the repo root and does
  nothing else (no tag, push, or GitHub release). Unzip it into the plugin
  folder above.
- **Published release** — `./release.sh` (maintainers only; needs a clean
  tree, push access to `origin`, and an authenticated `gh`) tags the commit
  `v<version>`, pushes it, and creates a GitHub release with the zip
  attached. Bump `version` in `manifest.json` first; the script refuses to
  reuse an existing tag.

## Calibration order

Calibrate per filament, and per nozzle when you swap nozzles. Each test
builds on the ones before it, so run them in this order:

0. **Temperature first.** No test here sets temperature, but all of
   them respond to it. Pick a temperature for the filament and keep it
   fixed through the whole sequence. If you change it later, re-run from
   step 1.
1. **Flow Ratio.** This is the only test that doesn't depend on another
   result: it prints at absolute multipliers and ignores the filament's
   current *Extrusion multiplier*. The other tests do use that value, so
   save the new one before going on.
2. **PA Pattern.** It extrudes with the multiplier from step 1, so line
   widths are correct and only pressure effects are left to judge. After
   saving PA you can optionally run a fine Flow Ratio pass (step
   0.005), since PA slightly changes how full the top surface looks.
3. **Retraction.** Pressure advance already relieves some nozzle
   pressure before travel moves, so tune retraction with PA on. If you
   tune it first, you'll end up retracting more than you need.
4. **Ironing.** Ironing flow is a percentage of the extruded volume
   (`extrusion multiplier × ironing flow`), so it only makes sense once
   the multiplier is final. It's also the most cosmetic setting, so
   leave it for last.

Save the filament preset (and printer preset, for retraction) after each
step. The next test reads the saved values.

### Before every test

- **Start from an empty plate.** Every test adds a small cube or
  cylinder at bed center. It's a placeholder the slicer needs so that
  the plugin's per-layer custom G-code gets emitted. Slice it along with
  the test.
- **Set Bed Width/Depth** in the dialog. They default to the CORE One
  (250×220) and are used to center the test. The plugin API can't read
  the bed size from the printer profile yet.
- **Choose the Tool** (`1` = T0, `2` = T1, …) on multi-tool printers.
  The test reads that tool's nozzle diameter and filament slot and
  assigns every print-setting extruder to it. Calibrate each tool
  separately.
- **Nozzle** and **Layer Height** default to `0` (auto), which reads them
  from the profile. Fill them in only to override.
- **Relative E is required.** The printer profile must use relative
  extruder distances (Prusa profiles do). If something goes wrong, for
  example a bad range or a bed that's too small, the plugin puts an
  embossed error message on the plate instead of the test.
- **Your print settings get changed.** The test sets layer height and
  first-layer height to the same value, turns brim and skirt off, and
  assigns all extruders to the selected tool. Ironing also turns off
  the slicer's own ironing. Don't save these into your print preset;
  reload or revert it after printing the test.
- **Auto speeds are capped** by the filament's *Max volumetric speed*,
  if one is set, so a test doesn't print faster than the filament can
  melt. In PA Pattern, an explicit Speed bypasses the cap.

## 1. Flow Ratio

![Flow Ratio plate sliced in PrusaSlicer 3 on a Prusa CORE One L](flow-ratio-demo.png)

OrcaSlicer's YOLO flow calibration: a plate of Orca-standard coupons,
each printed at a stepped extrusion multiplier and labeled with that
value. Pure `G1` output, so it works on every firmware.

**Run it:** *Plugins ▸ Calibration ▸ Flow Ratio*.

| Parameter | Default | Notes |
|---|---|---|
| Min Flow (start) | `0.95` | First coupon's multiplier (absolute, not a delta) |
| Sample Count | `11` | Number of coupons |
| Step | `0.01` | Increase per coupon. The default covers 0.95–1.05 |
| Use Monotonic Pattern | on | Off switches the top surface to Archimedean chords |
| Speed [mm/s] | `0` (auto) | Auto uses the larger of perimeter speed and 100 mm/s, then applies the volumetric cap |

**Read it:** look at the top surfaces. Pinholes and gaps between lines
mean under-extrusion; ridges, a rough nap, or a bulging edge mean
over-extrusion. Pick the smoothest coupon. With the **Archimedean** top,
the corner chords run into the center spiral and leave a lip you can
feel (Orca's trick), so run a fingernail across each coupon.
**Monotonic** gives a plain 45° top that's easier to judge by eye.

**Save it:** enter the winning label under *Filament → Filament →
Extrusion multiplier*. The test ignores the current multiplier, so the
label is the exact value to use.

- For a fine pass, center the range on the winner with a smaller step,
  for example Min Flow `0.97`, Count `11`, Step `0.005`.
- Coupons are Orca's standard size (30×20 mm plus a label tab). An
  11-coupon plate uses about 13 g and takes about 35 minutes with a
  0.4 mm nozzle.

## 2. PA Pattern

Calibrates pressure advance (Marlin *Linear Advance*), which compensates
for pressure building up in the nozzle when the print speed changes.
Each row is printed with a different PA value and labeled with it.
Commands are generated for Marlin and Marlin 2 (`M900`), Prusa Buddy
(`M572`), RepRapFirmware (`M572 D0`), Klipper (`SET_PRESSURE_ADVANCE`),
and Repetier (`M233`). The dialect is detected from the printer
profile, or you can set it manually.

**Run it:** *Plugins ▸ Calibration ▸ PA Pattern*.

| Parameter | Default | Notes |
|---|---|---|
| Use Lines Pattern | on | On: line test. Off: Ellis V-chevrons |
| Print Labels | on | Prints the PA value next to each row |
| PA Start / End / Step | `0` / `0.08` / `0.005` | Text fields on purpose: the dialog's float fields round to whole numbers in current alphas |
| Speed [mm/s] | `0` (auto) | Speed of the fast segments |
| Acceleration [mm/s²] | `0` | Non-zero sends `M204` and prints the value on the plate. Use the acceleration you normally print at |
| Firmware | `auto` | `marlin`, `marlin2`, `prusabuddy`, `klipper`, `rrf`, `repetier` |

**Read it:**

- **Lines:** each line is printed slow (20 mm), fast (40 mm), then slow
  (20 mm) again. With PA too low, the line bulges where it slows down
  and thins where it speeds up. With PA too high, it's the other way
  around: gaps or thinning at the slow-down and blobs at the speed-up.
  Pick the line with the most even width along its whole length.
- **Ellis chevrons:** pick the chevron with the sharpest, cleanest
  corner, with no bulge at the tip and no gap right after it.

**Save it:** enter the label under *Filament → Extrusion & Calibration →
Pressure advance*. Halfway between two equally good rows is fine.

- The defaults suit a direct-drive extruder with a 0.4 mm nozzle. For
  Bowden extruders try 0–1.0 with step 0.05. Both ranges come from
  OrcaSlicer's PA calibration dialog defaults. The Bowden range matches
  Klipper's pressure-advance tuning guidance but hasn't been tested with
  this plugin, which was developed on direct-drive printers.
- If the range doesn't fit on the bed, it's shortened and the console
  shows the new PA End.
- The extra number after the PA scale on the Ellis pattern is the
  volumetric flow rate (mm³/s) the chevrons printed at. OrcaSlicer's
  pattern prints the same label (print speed × bead cross-section ×
  flow multiplier; both slicers model the bead the same way).

## 3. Retraction

![Retraction test demo on a Prusa CORE One L](retraction-demo.png)

OrcaSlicer's retraction tower: two thin posts. The travel move between
them retracts a bit more with every millimeter of height. The retraction
lengths are written directly into the G-code with pure `G1` moves, so
it works on every firmware. Retract speed, deretract speed, and Z-hop
come from your current profile.

**Run it:** *Plugins ▸ Calibration ▸ Retraction*.

| Parameter | Default | Notes |
|---|---|---|
| Start Length [mm] | `0` | Retraction in the first band |
| End Length [mm] | `2` | Retraction in the top band |
| Step [mm per 1 mm band] | `0.1` | Added per 1 mm of height |

**Read it:** find the height where the strings between the posts stop.
Measure it in millimeters from the top of the two-layer base (0.4 mm at
0.2 mm layers). Your retraction length is
`Start + (clean height in mm × Step)`. With the defaults, that's the
height divided by 10.

**Save it:** enter the length under *Printer → Extruder → Retraction →
Length*. To keep it per filament instead, set *Filament → Filament
Overrides → Retraction length*.

- With the defaults the tower is about 21 mm tall: 21 bands, one step
  per millimeter, starting just above the base. Changing start/end/step
  changes the height to match.
- Retraction happens where the posts' inner sides are closest, as in
  OrcaSlicer, so strings form across the gap you're looking at and the
  outer sides stay clean.
- If you still get strings at the full range, check temperature first,
  because hotter filament strings more. Then try a range above 2 mm,
  which is common for Bowden setups.

## 4. Ironing

A grid of pads, each with ten layers and a solid top. After the top
layer, the nozzle irons it again at a different combination of ironing
flow and speed:

- **Columns** (left → right): ironing flow increases.
- **Rows** (front → back): ironing speed increases.

Each pad's label reads `speed flow`, for example `30 15` means 30 mm/s
and 15 %. In a single-row or single-column grid the label shows only the
value that changes. The test switches off the slicer's own ironing so
the two don't stack.

**Run it:** *Plugins ▸ Calibration ▸ Ironing*.

| Parameter | Default | Notes |
|---|---|---|
| Start Ironing Flow [%] | `10` | First column |
| Ironing Flow Step [%] | `5` | |
| Flow Sample Count (Columns) | `4` | The default covers 10–25 % |
| Start Ironing Speed [mm/s] | `15` | First row |
| Ironing Speed Step [mm/s] | `15` | |
| Speed Sample Count (Rows) | `3` | The default covers 15–45 mm/s |
| Ironing Line Spacing [mm] | `0.1` | Distance between ironing passes |
| Base Print Speed [mm/s] | `0` (auto) | Speed for the pad body, not the ironing |

**Read it:** look at each pad under a light at a low angle. Too little
flow leaves the top-infill lines visible, or leaves a dull, scratched
surface. Too much flow leaves ridges, smears, or a raised lip at the pad
edge. Going faster usually needs more flow. Pick the smoothest, most
even pad.

**Save it:** in the print preset, enable *Print → Infill → Ironing*
(*Topmost surface only* is the usual choice), then set:

- *Flow rate* (`ironing_flowrate`) to the pad's flow %
- *Spacing between ironing passes* (`ironing_spacing`) to the Ironing
  Line Spacing you used
- *Print → Speed → Ironing* (`ironing_speed`) to the pad's speed

Ironing settings belong to the print preset, so if the best values
differ a lot between filaments, keep a separate print preset for each.

- The default 4×3 grid takes about 144×106 mm. A larger grid shows
  `IRONING: BED TOO SMALL` if it doesn't fit inside a 10 mm margin.
- The ironing pass is inset a quarter of the nozzle diameter from the
  pad edges, so the walls aren't smeared over.

## Firmware Probe (diagnostic)

`firmware_probe.lua` reports what the plugin API can read from your
printer profile and which G-code dialect it resolves to. It's disabled
(`info = nil`), so it doesn't appear in the menu. To use it when
reporting an issue, temporarily restore its `info` table, rescan
plugins, and run PrusaSlicer from a terminal to see its output.

## License

**OCL v1.1 + SWAtt v1** — Prusa's [Open Community License](https://github.com/OpenCommunityLicence/OpenCommunityLicence)
with the Software Attribution add-on. Free to use, modify, and hack;
derivatives must stay under OCL and credit the creator ("built on …") in
their UI and source. See [LICENSE](LICENSE).

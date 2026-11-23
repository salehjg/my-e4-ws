# presentation7: progress log

Started 2026-11-23 by Opus 5.5, from the user's request after the full monte3 run: write presentation7 based on
presentation6. The user's requirements:
- **Plots:** Clang as real bars (no diamonds), patterns and colours, labelled axes, a framed legend, a shared y-axis
  for side-by-side panels, and the right linear or log scale.
- **Self-sufficient:** the slides do not rely on the codebase or on older talks.
- **Bullet-proof:** every result is checked and traceable.
- **Structure** (added during planning): what holds on both machines outside the parts; part 1 is the K1, with
  prefetch and everything else K1-specific; part 2 is the SG2044; comparisons between the machines come after both
  parts. Nothing was committed.

Plan: `/home/saleh/.claude/plans/binary-imagining-brook.md`. Decisions:
- The K1 probe slides stay, labelled "measured on the K1".
- About 25-30 minutes.
- The SG2044 raw logs stay private. Derived tables are tracked.

## Files

| file | what |
|---|---|
| `slides.tex` | the deck. Preamble from presentation6, plus `groupplots`, `catchfile`, the result-plot macros (`\onecorefig`, `\scalingfig`, `\gainfig`, `\timefig`) and `\nv{key}` for every number |
| `tables/` | written by `scripts/presentation7/slide_data.py`: `numbers.tex` (`\nset{key}{value}`), `<m>-1core-<prec>.dat`, `<m>-scaling-<prec>.dat`, `<m>-time-<prec>.dat`, `<m>-table-<prec>.tex` (backup tables), `cmp-fair.dat`; m = `kone` (K1) or `sg` (SG2044). Each file names its source logs with their sha256 |
| `board-logs/k1/` | copies, byte for byte, of `docs/presentation6/board-logs/board/{ldc-*,verify-*,compilers-*}.log` and `notes5/{e2-A-output-last,e10-A-clang-output-last}.log` |
| `figures/` | from presentation6: cavity, lbm, build-run, chain, stencil-d3q19, field-layout, parallel, stream-def, stream-count, ab, aa-pattern, split-loop, k1, streams, stream-test, prefetch-insert, zicbop, split-code, kernel-code, both films. New: `sg2044.tex`, `vlen.tex`, `vlen-flow.tex` |
| `build.sh`, `.gitignore` | presentation6's (header changed; `tables/` and `board-logs/` tracked) |

Edits to the copied figures:
- `kernel-code`: the RVV overlay shows "L cells", with 4 slots drawn full and 4 drawn light.
- `parallel`: one f32 instruction covers 8 cells on the K1 and 4 on the SG2044 (solid and dashed boxes).
- `build-run`, `chain`: `-march=rv64gcv_zvl<V>b`, and the build measures the width.
- `split-loop`: L1 is 32 KB on the K1 and 64 KB on the SG2044.
- `field-layout` is unchanged: the 16-byte padding is `hostAlignment()` = `__BIGGEST_ALIGNMENT__`, which is 16 on
  riscv64 whatever the VLEN (`submodules/walberla/include/walberla/v8/memory/MemoryTraits.hpp:32-46`).

## Data and checks (`python3 scripts/presentation7/slide_data.py`, 2026-11-23: all pass)

**K1** (presentation4 `all.sh`, 2026-11-16):
- 132 configurations × 3 runs; 200 steps + 10 warm-up; 1/4/8 cores.
- The field hash is identical in every run. The 11 builds' energies spread by 1.1e-15 (f64) and 3.9e-6 (f32).
- 7 spot values equal presentation6's tables.
- VERIFY PASS ×4, 44 sha256s. Max error vs reference: 2.2e-16 (f64), 9.2e-8 (f32).

**SG2044** (run `20261122-214637`: build job 8565, timing job 8566):
- 264 configurations × 3 interleaved rounds; 60 steps + 10 warm-up; 1-64 processes.
- Field hashes identical; energy spread 6.2e-16 (f64) and 1.2e-6 (f32).
- BUILD PASS with 44 audits; TIME DONE with no FAILED or SKIPPED lines.
- Our best-of values equal the job's own table (176 values).
- MPI check PASS at 4-64 processes, helper thread at 0 %.
- VERIFY PASS ×4, 44 sha256s, errors as on the K1.
- 240 rounds. In 1 round a core showed 3 % before the round started (`ldc-gcc-autovec-f32-64core.log`, round 2,
  cpu24). The check allows single cores up to 5 % and reports them.

**Round-to-round spread:**

| | K1 | SG2044 |
|---|---|---|
| median | 0.8 % | 0.5 % |
| configurations above 3 % | 3 of 132 | 7 of 264 |
| largest | 6.4 % | 11.0 % (GCC f64 `explicit_cse` at 8 processes; none of the plotted builds) |
| largest among plotted builds | 2.3 % | 5.3 % |

**Fair test** (output only in the last step, one core), fastest RVV over best scalar:

| | K1 GCC | K1 Clang | SG2044 GCC | SG2044 Clang | lanes, K1 / SG2044 |
|---|---|---|---|---|---|
| f32 | 2.08 | 2.36 | 2.00 | 2.23 | 8 / 4 |
| f64 | 1.40 | 1.45 | 1.54 | 1.44 | 4 / 2 |

On the K1 with GCC in f64, the fastest RVV build in that test is in place + prefetch; everywhere else it is the
split loop.

**Findings shown on the slides:**
- The split loop is the fastest build in every column: 12 of 12 on the K1, 24 of 24 on the SG2044.
- Auto-vectorized builds are never faster than scalar by more than 1.8 % (K1) or 0.8 % (SG2044).
- On the SG2044, Clang's `explicit_cse_aa_pf` with output last runs at about half speed:
  - 3.28 vs 6.20 MLUP/s (f64) and 6.66 vs 12.39 (f32), the same in all 3 rounds.
  - Output last selects the generated `StreamCollide*NoOutput` kernels (`SweepgenLdcCPU.cpp:169-206`), so it is a
    different kernel.
  - GCC does not show it. The cause was not investigated, and the slide says so.
- Prefetch on the SG2044:
  - Not in place, it makes GCC's f32 build slower (13.81 → 11.94) and helps Clang.
  - In place, it helps both compilers in both precisions.
  - The deck makes no claim about whether the C920v2 executes the hint.
- Traffic estimate at 64 processes for the GCC split build: 93-102 GB/s (f32), 106-116 GB/s (f64). That is bytes
  per cell in place (42 or 46 values) × MLUP/s, labelled as an estimate.

**Claims I corrected while writing:**
- "Most of the speedup is not the vectors" became "the vectors alone give ×2.08 of 8 / ×2.00 of 4; the rest comes
  from computing less and touching fewer arrays". On the SG2044 the vectors are about half of the total.
- "Vectors give half their lanes" became "far less than their lane count": that is a quarter on the K1.
- The autovec row shows the largest *gain*: autovec was never faster beyond those numbers.

**Generated-code excerpt** (VLEN slide): made on the laptop with the fork (pystencils `78afe1ff`, `.venv-rvv`):
- a 2D 4-point f32 stencil, generated for `RISCV_RVV256` and for `RISCV_RVV128`
- options: `cpu.vectorize.enable`, `assume_inner_stride_one`, `default_dtype="float32"`
- both use `f32m1`; the K1 version has vl and step 8, the SG2044 version 4

Without `default_dtype="float32"`, the default lane count follows f64, which gives `f32mf2`, 4 lanes at 256.

## Build and visual check

- `./build.sh`: 0 errors and 1 open `\todo` (the workspace commit on the code slide).
- Two tiny overfull hboxes remain: 2.7 pt in the build-run figure (presentation6 has the same) and 0.3 pt.
- Every slide was rendered (`pdftoppm`) and looked at. Fixed along the way:
  - groupplot panels drawn on top of each other: `group style` has to be given inline, not through a style
  - the SG2044 hardware boxes
  - the overflowing builds table and vlen-flow figure
  - the K1 backup table split into two slides
  - the fair-test labels made horizontal
  - plot numbers in the text font (`assume math mode`)
- Colours were checked with the dataviz skill's validator:
  - GCC blue `#2A78D6` against Clang orange `#EB6834`: CVD ΔE 24.7.
  - The time-share colours violet, aqua and yellow: all-pairs ΔE ≥ 9.1. Aqua and yellow are below 3:1 contrast,
    so every segment that is big enough carries its number.

## Round 2 (2026-11-23): independent check, restructure, simpler text

The user asked to re-read the slides, verify every result, put less text on each slide in simple English, and add
overview slides as the talk progresses.

**Independent re-check.** I wrote a second parser that shares no code with `slide_data.py`. It recomputed, from the
raw logs of both machines:
- every best-of MLUP/s and every ratio over plain and best scalar: all equal `numbers.tex`
- spreads, energies, the fair-test ratios, the time shares, the per-core numbers, the scaling factors

Two findings changed the slides:

| finding | before | now |
|---|---|---|
| On the K1, GCC, 8 cores (f32 and f64), the runs of the split build overlap with those of in place + prefetch (lead 0.5 % and 0.6 %, within the run-to-run spread) | "split loop fastest in 12 of 12" | "clear win in 10 of 12; in the other 2 (GCC, 8 cores) a tie". On the SG2044, the split build's slowest run beats the runner-up's best run in all 24 columns (smallest lead 4.2 %) |
| The traffic estimates used different methods: the K1's 4.6 GB/s counted only the kernel time, the SG2044's 93-116 GB/s the whole step | mixed | Both machines now count the kernel time only (MLUP/s × total time / kernel time × bytes per cell). K1, 8 cores: 4.2-4.6 GB/s (f32), 4.1-4.4 (f64). SG2044, 64 cores: 125-137 (f32), 129-141 (f64). On each machine f32 and f64 move about the same bytes per second |

**`slide_data.py` additions:**
- `m:splitclear`: columns where the split build's slowest run beats every other build's best run. The script
  stops if the tied K1 columns are not exactly GCC 8 cores f32/f64, or if any SG2044 column is a tie.
- `m:clangslower:...`: how much slower Clang is than GCC, in %.
- `m:kmlups:p` and `m:gbsk:p:{lo,hi}`: the kernel-only traffic estimate.
- "Statements in the slide text": the script stops if a claim made in words stops holding:
  - SG2044 prefetch directions (not in place: slows GCC f32, GCC f64 within 1 %, helps Clang; in place: helps both)
  - the Clang output-last anomaly (below 0.6 × the slowest normal round) and that GCC does not show it
  - auto-vectorization gain below 2 % on both machines
  - Clang 15-25 % slower than GCC in the SG2044 split build at one core
  - f32 and f64 traffic within 10 % on both machines
  - halo exchange below 1 % on one core, and a larger wall-pass share for the split build than for best scalar

**Structure:**
- The question, then the main results.
- Seven sections. Each starts with an overview slide that shows the current section in colour, its subsections
  indented below it, and the other sections in grey:
  1. Background
  2. Code for two vector widths
  3. The kernel and its memory traffic
  4. Part 1: K1
  5. Part 2: SG2044
  6. The two machines compared
  7. Summary
- The overview frames come from `\AtBeginSection`, with beamer's TOC spacing patched from 1.5em to 0.7em so that
  all seven sections fit.
- The frame titles show short section names, so they do not run into long titles.

**Text:**
- About four bullets per slide, in full, simple sentences, and one short takeaway.
- Method details went into the grey note or the backup.
- The first-person "we" is used for what was done.

**Plots:** no stray "1" tick label on the right panels, no thousands comma on the log axes, and the fair-test plot
re-spaced.

**Build:** 0 errors and 1 open `\todo` (the workspace commit). One 2.7 pt overfull hbox remains in the build-run
figure, which presentation6 also has. All slides were rendered and looked at.

## Open

- The workspace commit on the code slide, once the user commits.
- No SG2044 film. The flow slide shows the laptop and K1 films and says so.

## Review 2026-11-23 (user's slide-by-slide review; plan: `plan-p7-v2.md`)

Done (the deck now has 56 frames plus the backup; `./build.sh` builds with no new overfull boxes):
- Overview frames have a light blue background (`\overviewframe`, `psblue!11`).
- New frames: "What one time step does" (`figures/time-step.tex`: kernel, halo exchange, wall pass and the
  bounce-back rule); "pystencils: one backend for each instruction set" (`figures/backends.tex`: one `RvvCpu`
  for both widths, nothing specific to a chip); "Cache lines and streams" (`figures/cache-line.tex`); the old
  stream slide became "Our loop walks through 42 arrays at once", which defines f_i, f'_i, rho, u; a prefetch
  slide "K1: what a software prefetch does" (`figures/prefetch-idea.tex`).
- Redrawn: `stream-count` (real distances, 64-byte line borders), `kernel-code` (flat index with the real f32
  strides, 5 overlays instead of 9), `split-loop` (two pseudo-code boxes), `aa-pattern` (slots f_3 and f_4 instead
  of W and E), `prefetch-insert` (the loop without and with prefetch; the loads stay), `stream-def` (static).
- Resolved todos: backends (frame 10), sha256 = of each executable, energy = sum of u^2 over all cells
  (`SweepgenLdcCPU.cpp:281-307`).
- One-core plots: full build names, rotated 90 degrees; "with prefetch" instead of "+". Titles say throughput
  for MLUP/s. The RVV-gain frames say what a bar means and why the gain falls. Time-share labels are centred,
  and ymax is 100.5 (two labels were dropped because the rounded shares added up to 100.1).
- Hardware: cache line of 64 B on the K1, read on the board (sysfs `coherency_line_size` for L1I, L1D and L2;
  device tree `d-cache-block-size`, `riscv,cbom/cboz-block-size`). SG2044: 64 B from the SG2042 device tree
  (same C920 family), with a todo until it is read on monte3. Zicbop: neither ISA string lists it. The prefetch
  builds contain the same hints on both machines, and on the SG2044 in place goes from 11.85 to 15.90 MLUP/s
  with them (GCC f32). The user decided to state these facts rather than "not supported".
- The glossary was regenerated in sorted order, with new entries: backend, cache line, density, energy, f_i/f'_i,
  target, throughput, velocity.

Open todos: SG2044 line size (confirm on monte3 with
`cat /sys/devices/system/cpu/cpu0/cache/index*/coherency_line_size` inside a peak.sbatch job); autovec as fast as
scalar (frames on K1 one core); the my-e4-ws commit on the last slide (after the user commits).

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

## Review 2026-11-24: slide 9

- `figures/build-run.tex` now shows only the libraries with their real names: CMake, the generator script, lbmpy,
  pystencils, sweepgen with pystencils-sfg, the waLBerla core, GCC/Clang, the program and Open MPI. The arrows
  carry the main settings: V, f32/f64, `-march=rv64gcv_zvlVb -O3`, MPI on, OpenMP off, the target RISCV_RVVV,
  prefetch, split, and `mpirun -np N`. The pystencils backends panel is on the right; the separate backends
  slide and `figures/backends.tex` are gone (55 frames).
- OpenMP: waLBerla has `WALBERLA_BUILD_WITH_OPENMP`. It is OFF by default (CMakeLists.txt:71) and OFF in all our
  build trees (`WALBERLA_BUILD_WITH_MPI=ON`), so the benchmark runs one MPI process per core and no threads. The
  slide says so in its grey note.
- Removed the slide "RISC-V vectors: each chip chooses its register width" and its subsection (user: useless).
  RVV and VLEN are now defined in the grey note of "From Python to a running program". `figures/vlen.tex` is no
  longer used. Added the MPI+OpenMP hybrid as an open question. 54 frames.
- "How the 19 values are stored in memory": the 6-overlay `field-layout` frame was replaced by one static frame
  with two pictures. `figures/fzyx.tex` zooms from the field (19 arrays) to one array (66 planes, 1.2 MB), one
  plane (66 rows, 18 KB) and one row (ghost, 64 cells, ghost, 2 padding values), with the index formula.
  `figures/ghost.tex` shows two blocks with their ghost rings and which border cells the halo exchange copies
  where (Field.hpp:215-252). `figures/field-layout.tex` is no longer used. The stencil frame keeps only its
  last overlay.
- The kernel-code frame (5 overlays) was replaced by one static frame (`figures/kernel-cse.tex`). It shows the real
  generated StreamCollide of the scalar CSE build, shortened, with the generated names kept. Colours: the loads
  f(i,x,y,z) orange, the CSE values violet, `const float` (registers) red, rho/u teal, the stores blue. Counts:
  54 const float values, 19 distinct load addresses, xi_5 used 3 times.
- New frame "The split loop in action" (`figures/split-action.tex`), placed after "Fewer streams, way 2". It is a
  grid of the arrays against the 8 passes (from lbm_split.py): passes 1-4 read f0-4, f5-9, f10-14, f15-18 into
  acc; pass 5 writes rho, u and scr; passes 6-8 update f0 + (1,2)(3,4)(5,6), then (7,10)(8,9)(11,16), then
  (12,15)(13,18)(14,17) in place. Arrays in memory per pass: 5 5 5 4 4 7 6 6. `figures/kernel-code.tex` is no
  longer used.
- Slide 16: added the ndarray form `float f[19][66][66][68]`, value = `f[i][z][y][x]` (fzyx = slowest to fastest); the flat-index box was removed.
- New frame "The split loop in code" (`figures/split-cse.tex`), placed after "The split loop in action". It shows the real generated split code (driver, m1, macro, c0; scalar form, suffixes dropped) with the colours of the kernel slide, plus green for the scratch acc/scr. 56 frames.
- Moved "The kernel code: updating one cell" to just before "The split loop in code" (user). Its key now says "f[i][z][y][x] of the layout slide".
- "Cache lines and streams" and "Which accesses belong to the same stream" (5 overlays) were replaced by one static frame "What a stream is, and why it matters" (`figures/stream-why.tex`). Left: one array, its cache lines, the loop and the prefetcher loading ahead. Right: our 42 arrays and a prefetcher that follows only about 20 (K1). `cache-line.tex` and `stream-count.tex` are no longer used. 55 frames.
- The code slides are now in Python with NumPy indexing (user: no invented load/store syntax). Layout: `f = np.empty((19, 66, 66, 68), np.float32)`, `f[i, z, y, x]`. Kernel and split-loop code: `f[3, z, y, x+1]`, `g[7, z, y, x] = ...`, `acc[0, y, x] += ...`. Way 2: `f[:, z, y, x]` and `f[0:5, z, rows]`. The C slides with intrinsics (generated code at two widths, prefetch, Zicbop, K1 split-code, stream test) stay C.
- Way 2: the split box now writes every index: `f[0:5, z, y0:y0+2, :]` (z, the block's 2 rows of y, all x) instead of the hidden `rows` slice.

- 2026-11-24: the three prefetch slides ("software prefetch in the generated code", "the RISC-V prefetch
  instruction", "the split loop needs no prefetch") merged into one frame with the new figures/prefetch-code.tex:
  the loop with prefetch, the instruction `ori x0, a0, 1`, and four bullets (the pass, Zicbop/x0, the X60 runs it
  176 -> 90 cycles, split loop needs none, 2-13 % slower with it). The bit-field picture, the runtime function, the
  before/after code pair and the split driver code are gone. Glossary entry "Hint" removed (unused).
  figures/prefetch-insert.tex, zicbop.tex, split-code.tex are now unused. Deck: 53 pages.

- 2026-11-24: slide 9 "What we added" (figures/chain.tex) redrawn from the fork diffs (walberla 0c8ed8c9..HEAD,
  pystencils 20d7dcf0..HEAD): five boxes, waLBerla CMake (VLEN probe, -march, -mtune), sweepgen (VLEN ->
  RISCV_RVV128/256 target, AA sweeps, output-free sweeps), pystencils (RVV backend, prefetch and row-pointer
  passes, VLEN #error check), waLBerla core (AA ghost-layer exchange), benchmark apps (lid-driven cavity, split
  loop). Grey line: lbmpy and pystencils-sfg unchanged. The old 4-box chain had no sweepgen and no waLBerla core.

- 2026-11-24: slide 10 "How the build chooses the target": new figures/sizeless.tex (one vfloat32m1_t register,
  8 lanes on the K1 and 4 on the SG2044, plus the GCC error "RVV type 'vfloat32m1_t' does not have a fixed size",
  checked with riscv64-linux-gnu-g++ 16.2.1) and three bullets: RVV types have no fixed size, so the code uses the
  same types and intrinsics at both widths (only vl and the loop step change), so one backend with VLEN as a
  parameter. Flow diagram scaled to 0.76 textwidth. Dropped bullets: "CMake measures..." (the diagram and the
  takeaway say it) and "At 256 bits the generator writes the same code as before" (K1 results still hold).

- 2026-11-24 (later): the sizeless-type note moved off slide 10 (back to the flow diagram + its two bullets;
  figures/sizeless.tex deleted). The slide "The generated code at the two widths" is replaced by "Vector types on
  x86 and on RVV" (new figures/vtypes.tex): a table AVX2 | AVX-512 | RVV K1 (256) | RVV SG2044 (128) with lanes,
  C type, sizeof (32 B / 64 B / none), load and add intrinsics, loop step, and what changes with the width
  (x86: every name; RVV: vl and the loop step). Bullets correct the earlier claim: the sizeless types are NOT why one
  backend works (X86VectorCpu also serves SSE/AVX/AVX-512 by switching prefixes); both backends fix the width at
  generation time (VLS); sizeless types would allow VLA (vsetvl at run time), which we do not use. All names and
  sizes compile-checked (g++ -mavx512f, riscv64-linux-gnu-g++ 16.2.1).

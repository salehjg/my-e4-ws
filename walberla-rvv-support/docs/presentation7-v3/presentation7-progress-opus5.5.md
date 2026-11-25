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

- 2026-11-25: SG2044 cache line confirmed on monte3. The user ran
  `cat /sys/devices/system/cpu/cpu0/cache/index*/coherency_line_size` on mc-peak-2: 64 for all four entries
  (index0-3: L1I, L1D, L2, L3). The todo on "What a stream is, and why it matters" is removed; the source comments in
  figures/sg2044.tex, cache-line.tex and stream-why.tex now cite this reading instead of the SG2042 device tree.
  Open todos: autovec as fast as scalar (2) and the my-e4-ws commit on the last slide.

- 2026-11-25: slide 16, right picture (figures/ghost.tex): it now names the halo exchange (bold label "halo
  exchange, after every step:" over the two copy arrows) and points at the grey ring with an arrow labelled
  "ghost layer". The column heading is now "The ghost layer and the halo exchange". (The user had read block A/B
  as the AB pattern; it is two neighbouring blocks, not the two copies of f.)
- 2026-11-25 (later): slide 16 also has an arrow under block B, "halo = ghost layer", pointing at B's right ghost
  column (the user asked to show what the halo is).
- 2026-11-25 (later): figures/ghost.tex redraws both blocks' bold outlines after the coloured columns, which hid them.

- 2026-11-25: new slide 20 "Fewer streams, way 1: the halo exchange in AB and in AA", right after slide 19 (deck: 54
  pages). Same two columns as slide 19, but the figures are four panels in the style of figures/ghost.tex (new
  figures/halo-steps.tex, macros \halopanel and \halolegend): two blocks with their ghost ring; (1) blue = cells the
  kernel writes in the step; (2) arcs = the copies of the halo exchange, teal left->right, orange right->left.
  AB step 1 / step 2 and AA even: border -> neighbour's ghost layer. AA odd: the kernel also writes the ghost ring
  (blue), and the copy goes back, ghost layer -> neighbour's border. Sources: SweepgenLbmCPU.cpp:110-169
  (aaPull after the even sweep, aaPush after the odd one; streamPullSync after every AB step) and
  GenericFieldPackInfos.hpp (AAPull: borderSlice -> ghostSlice; AAPush: ghostSlice -> borderSlice). Footnote: only
  the 5 of 19 values that cross a face are copied. Blocks are named "block 1/2" (not A/B, which are the arrays).
- Slide 16: the legend of figures/ghost.tex moved up (shift -1.1) so the new labels do not overflow the frame.
- 2026-11-25 (later): slide 20 redrawn after the user's review ("arrows not connected", "A and B not labelled",
  "copy: border -> ghost layer is horrible"). Each copied column now has a bold dashed frame in its colour; each
  arrow runs from the source frame to the destination frame. Every grid is labelled "block 1/2, array A/B". The
  left label says which array the step reads and writes; the right labels are gone. Column headings: "The usual way
  (AB): two arrays, A and B" and "In place (AA): one array, A". Legend: (1) blue = written by the kernel,
  (2) framed cell -> framed cell = copied by the halo exchange.
- 2026-11-25 (later): slide 20 again (user: "no idea what A and B are", "(1) and (2) still confusing"). The circled
  1/2 are gone; the legend says it in words ("the kernel writes these cells during the step", framed -> framed "the
  halo exchange copies them after the step"). The takeaway box now defines A and B: two copies of all the data of
  a block, 19 arrays each, ghost layer included; AB reads one and writes the other (f_i and f'_i of slide 18), AA
  has only A. The footnote "5 of the 19 values cross a face" was dropped for space (the fact stays in the source
  comment of figures/halo-steps.tex).


# presentation7-v3 (cloned from presentation7-v2 on 2026-11-25)

- Clone of docs/presentation7-v2 (without build/). The user asked for three main sections, each opened by the same
  overview slide: (1) everything on the lattice Boltzmann method, (2) our RVV work for the K1 and the SG2044,
  (3) all results. No frame was changed in content; they were only moved (43 frames, none lost, none doubled).
- New order, with the subsections the overview shows:
  1. The lattice Boltzmann method (LBM): the test case (cavity, the flow); one cell and how it is stored (stencil,
     storage with ghost layer and halo exchange); many cores and one time step; cache lines and data streams;
     two ways to use fewer streams (AA, the halo exchange in AB and AA, split loop, split in action); the update in
     code (kernel code, split code).
  2. Our work: RVV support for the K1 and the SG2044: from Python to a running program; what we added (builds,
     target choice, vector types); safety (a wrong width stops the build); the two machines (K1 and SG2044
     hardware); the stream limit and software prefetch (K1 stream limit, stream test, what a prefetch does,
     prefetch in the generated code).
  3. Results: correctness and how we measured; K1; SG2044; the two machines compared.
  Then Summary (own section, with its overview) and the backup (no overview).
- Cross-references fixed: "measured in Part 1" -> "on the K1, in the next section"; "(later in this part)" ->
  "(later in this section)"; the note on the builds slide now says in place and the split loop were explained in
  the previous section, software prefetch later; glossary "SG2044 ... used in part 2" -> "our second machine".
- SG2044 hardware slide: 0.5 mm less space under the figure (it overflowed by 1.7 pt in the new place).

- 2026-11-25: LBM section made coherent (user: "pictures must complete one another, nothing used undefined").
  One picture language: light blue = a block's cells, grey = ghost layer, bold outline = the block, orange =
  core 3's border cells copied into core 2's ghost layer (teal the other way); A = the field f (values f_i), B = the
  field g (new values f'_i, orange tint). Order now goes from large to small: test case -> blocks and cores ->
  one cell (stencil + formula) and its storage (A, B, fzyx, ghost layer) -> one time step -> streams -> AA/AB,
  halo in AB/AA -> split loop -> code.
  - Running on many cores (figures/parallel.tex): panel 3 (RVV row) removed, since RVV is defined only in section 2;
    zoom onto core 2 with its east neighbour core 3 (core 3 had no east neighbour); halo copy in orange as on the
    storage slide; bullets define block, MPI, ghost layer, halo exchange.
  - Stencil: the SRT update as three lines (f*_i = f_i(x - c_i); rho, rho u; f'_i = f*_i + omega (f^eq_i - f*_i)),
    checked against SweepgenLdcCPU.py (D3Q19, SRT, compressible, relaxation rate omega).
  - Storage (figures/fzyx.tex, ghost.tex): code box declares f (A: f_i) and g = np.empty_like(f) (B: f'_i); the
    field is drawn as two rows A and B; blocks are "core 2" / "core 3" (no more "block A/B"); text says the kernel
    reads A and writes B, the halo exchange fills B's ghost layer, then A and B swap (lbm_bulk.py swap_fields).
  - Time step: kernel reads f_i from A, writes f'_i into B; halo copies B's border cells; "then A and B swap".
  - 42 arrays: groups "19 read from A", "19 written into B".
  - AA slide (figures/ab.tex): A and B drawn as the same two rows of 19 arrays as on the storage slide.
  - Halo in AB/AA: blocks "core 2/3", headings "two sets of arrays, A and B" / "only A", grey reminder of A and B,
    takeaway back to the copy directions.
  - Split loop: the 2-row unit is now a "chunk" (it clashed with "block"); loop variable g -> grp (g is B);
    L1 cache defined.
  - Code slides: notes no longer use RVV, L or "scalar build" (defined later); g = B stated.
  - Glossary: A, B; AA/AB reworded; Chunk; L1 cache; SRT (glossary 3/3 item spacing 0 so it fits).

- 2026-11-25: "Open questions" replaced by "Open questions and what is needed next" (page 50, just before the
  thank-you slide), two columns. Left, SG2044 memory and prefetch: stall beyond ~20 streams? (run the K1 stream
  test there; the C920v2 is out of order); a hardware prefetcher, how many streams?; no Zicbop in the ISA string
  but aa -> aapf 11.85 -> 15.90 (nv keys): are the hints executed?; Zicboz (zero a line: no write-allocate load,
  e.g. the 4 output arrays) and Zihintntl (non-temporal hints): could they help?; the Clang in-place + prefetch
  half-throughput case. Right, what is needed next: waLBerla-wind (arXiv:2402.13171, CPE 10.1002/cpe.8117), where it
  sits in the stack, whether its kernels come from lbmpy/pystencils (not checked), one of its benchmarks on both
  machines; MPI only vs MPI + OpenMP (one process per 4-core L2 group on the SG2044); tuning LMUL, prefetch
  distance, split pass size; huge pages on the SG2044. ISA facts from recon round 1: v, zicbom, zicboz, zihintntl,
  no zicbop (K1: zicbom, zicboz). Glossary: OpenMP, waLBerla-wind, Zicboz, Zihintntl.

- 2026-11-25: the RVV-vs-scalar ratio slides now say what they isolate (user: "not clear what they are for").
  New macros \chip, \chipnew, \cmpline: one line per slide that lists what the two compared builds contain; shared
  ingredients grey (they cancel), extra ones teal. The "advantage shrinks" slides are now "K1/SG2044: what RVV adds
  over the best scalar build, 1 to 8/64 cores": RVV split loop [CSE, in place, split loop, vectors] / best scalar
  [CSE, in place]; text: each bar is what split loop + vectors add together; they cannot be separated, the split
  loop exists only as vector code. "The vector gain without the stream limit" is now "The vectors alone: the gain
  without the stream limit": the scalar build has 19 streams (output only at the end), so the split loop gains
  little and the bar is mostly the vectors. Table on "What holds on both machines" relabelled accordingly.
- Overview slide inside the results, between K1 and SG2044 (\overviewframesub: current subsection in colour).
- 2026-11-25 (later): open-questions slide cut to 5 + 5 short bullets, each at most two lines (user: no essays).

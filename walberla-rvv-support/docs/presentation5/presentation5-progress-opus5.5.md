# presentation5: progress log

Started 2026-11-20 by Opus 5.5. Task from the user: read `docs/notes5/`, clone `docs/presentation4` into
`docs/presentation5`, apply the changes notes5 explains, and see whether the benchmarks can run fewer time
steps (target: about 5 min for the slowest experiment) without more variance. Nothing in `docs/presentation4/`,
`docs/notes5/`, `scripts/presentation4/` or the forks was changed. Nothing was committed.

## What was cloned

- From `docs/presentation4/`: `slides.tex`, `figures/` (with both films), `build.sh`, `.gitignore`, and
  `board-logs/{board,x86}/` (byte-identical copies, so every number of the deck has its log inside this folder).
- `docs/notes5/board-logs/*` copied to `board-logs/notes5/` (the audit's raw logs, E1-E10).
- Not copied: presentation4's plan and progress files (they stay the record of presentation4), `build/`.

## Changes to the deck (notes5 finding in brackets)

Build: `./build.sh png` gives 31 pages (25 main, 6 backup), no overfull box except the 2.7 pt title warning
presentation4 already had; every page checked by eye. One open `\todo`: the my-e4-ws commit (the user commits).

| slide (PDF page) | change |
|---|---|
| 2 | 23 stores (19 values, density, velocity) instead of 19 (F13) |
| 4 | takeaway: 8 / 4 lanes bound only the arithmetic, no "these are our goals" (F1, F9) |
| 5, 31 | run loop: kernel, halo exchange, **wall pass (plain C++)** (F16) |
| 6 | "the generator script asks for vector code once" instead of "users change nothing" (F13); figure `chain.tex`: the safety check tests the flags, not the hardware (F10) |
| 8 | bullets: 4 of 5 lines in time for the 4160 B layout; vector-load misses never overlap, scalar ones 3-5 at once (F17, F19, F20); "it is the number of streams" removed; takeaway "stalls in 92 % of its cycles", split loop 64 % in the note (F3); note on single runs (F7, F20); plot: log axis labelled, bottom axis "share late", prefetch series marked "top only" (F20) |
| 9 | caption: the cliff is the same with 4 KB pages (E1-B) |
| 12 | bytes per cell: f32, with write-allocate (F13); gains with two digits (F8) |
| 14 | prefetch in the split loop: 2-7 % (f32), 12-13 % (f64) slower; "from more instructions" replaced by "below 20 streams prefetch costs more than it saves" (F7); gain about 1.2×, note that it holds in this memory layout (F18) |
| 15, 16 | titles "everything together"; takeaways 5.5-6.1× (f32), 5.1× / 5.0× (f64), "more than 4 lanes can give"; goal lines removed from both plots; labels two digits; autovec qualified: the stride is only known at run time (F1, F8, F15) |
| 17 (new) | **Why 5.5× is not what the vectors alone give**: table of what each build has (CSE, in place, prefetch or split loop, vectors) and its streams per step; prefetch and the split loop get around the ~20-stream limit and exist only for vector code, so the best scalar build stays at 23 streams (F1). Added after the user found the first version of the next slide unreadable |
| 18 (new) | **The fair test: what the vectors alone give**: MLUP/s bars (GCC): best scalar as before 2.00 / 1.42, best scalar with density and velocity only at the end 3.98 / 3.44, fastest RVV with the same 8.27 / 4.80 → 2.1× / 1.4×; Clang 2.4× / 1.45× in the note (F1, E2, E10). Figure `figures/vector-share.tex`. The "stream and collide alone" bars of the first version were dropped |
| 19 | caption: the wall pass takes 2.0-2.2 s per run, 27 % and 32 % of the two fastest f32 builds (F2); "fastest build in this run" |
| 20 (new) | **Speed depends on where the arrays sit in memory**: E6 table (both apps × default / huge pages / heap), the ranking flips, with huge pages everything together reads 2.6× instead of 4.8× (in place + prefetch) (F6, F18, E1-C, E6) |
| 21 | labels two digits; takeaway 2.2× / 2.0×, 1.6× / 1.4× (F8) |
| 22 | title "close to the memory's limit"; 4.6 GB/s estimated during stream/collide against ~6 GB/s of the same pattern in a test loop (F4, E9); takeaway only for the two fastest RVV builds, Clang line removed (F5) |
| 23 | f32 agreement: 3·10⁻⁷ between the single-loop builds, split loop 4·10⁻⁶ (F14); "fastest in this run, default memory layout" |
| 25 | mirrored-walberla commit `8c19407a`; notes5 named as the audit |
| 26-28 | glossary on 3 pages; new: cache miss, heap, huge page, stall, stride, write-allocate; removed (unused): FMA, SRT |
| 29 | the 7.7× (lab kernel over whole program) removed; note that these ratios are everything together (F11) |
| 30 | correctness: oracle box sizes named, "each broken version fails at least one check", tests on x86 with plain C++ kernels, "0 vector instructions in the executable", remainder sizes not checked (F12) |

Recheck while editing: notes5 F14 gives the f32 single-loop agreement as 1.2·10⁻⁷; over all 36 logs, max − min over
the mean is 0.9·10⁻⁷ to 2.7·10⁻⁷ (GCC 1 core: 11.3666528 … 11.3666559), the split build 3.4·10⁻⁶ to 3.8·10⁻⁶ away.
The slide says 3·10⁻⁷ and 4·10⁻⁶.

Not applied (outside the deck, listed in notes5 "Outside the deck"): report r03 and notes3 (F19 sentence, F1
framing), `misc/x60-lab/probes/mem.cpp` and `ops.cpp` (F19, F9), presentation3's slides, the presentation4 progress
log (F20), the forks' VLEN check (F10), an odd-extent oracle case in `verify.sh` (F12).

## Shorter timed runs (board, `scripts/presentation5/steps_check.sh`)

Why: presentation4's slowest experiment (`ldc-clang-rvv-f64-8core.log`, 5 builds × 3 runs of 200 steps) took
910 s; every run also costs about 4.5 s of start-up and warm-up (8 cores; 3-4 s on one core). With 60 steps the
same experiment takes about 5 min.

Method: the verified presentation4 executables (sha256 checked), GCC, 1 core (plain scalar, best scalar, RVV in
place + prefetch, RVV split loop; f32 and f64) and 8 cores (f64: plain scalar, RVV CSE, RVV in place + prefetch),
200 / 60 / 30 timed steps after 10 warm-up steps, 4 interleaved rounds (the order of the step counts rotates).
Log: `board-logs/presentation5/steps.log`, `steps-runs.log`; table: `python3 scripts/presentation5/steps_table.py
docs/presentation5/board-logs/presentation5/steps-runs.log`.

Board 2026-11-18 18:17-18:59 (board clock), governor performance, 1.6 GHz on all cores, no busy core except
7 % on cpu7 before round 3; 132 runs, 0 failures, one energy per build and step count (runs repeat bit for bit).

| | 60 steps against 200 | 30 steps against 200 |
|---|---|---|
| 1 core, 8 builds | median within 0.9 %, best within 0.3 %; spread ≤ 1.5 % except one slow split-loop run (6.7 %); 200 steps: up to 2.7 % | median within 1.2 %; spread up to 5.5 % |
| 8 cores, 3 builds | 2-5 % faster (median); spread 0.7-2.0 %; 200 steps: 3.2-7.8 % | spread up to 10.6 % |

The 8-core difference is not thermal (`scripts/presentation5/thermal_check.sh`, log `thermal.log`, 19:00-19:05):
RVV in place + prefetch, GCC f64, 8 cores, 200 / 60 / 200 / 60 steps after 60 s pauses, sampling every 0.5 s: the
clock stayed 1.6 GHz on every core in all 143 samples, the cpufreq cooling state stayed 0, the clusters peaked at
70 / 73 C (first passive trip point: 75 C). MLUP/s: 11.36, 11.87, **11.89**, 11.91: a clean 200-step run equals
the 60-step runs; the slow one lost its time in the halo exchange (t_comm 6.0 s against 4.4 s), i.e. waiting for a
rank that something else on the board slowed (`bluetoothd` was seen at 50-70 % of one core in bursts). Long 8-core
runs catch such bursts more often; the per-step speed itself does not change.

**Decision: 60 timed steps** (warm-up 10, as before): same speed as 200 steps, no more noise (less on 8 cores),
and the slowest experiment (RVV f64, 8 cores, 5 builds × 3 runs) takes about 5 min instead of 15 (measured per run
at 60 steps: 13.5-24.7 s with start-up). 30 steps is too short. New default in `scripts/presentation5/run.sh`
(times the verified presentation4 executables, builds nothing, variants interleaved round-robin, board state
recorded: notes5 F8, F21) and `scripts/presentation5/matrix.sh` (presentation4's matrix plus the fair scalar/RVV
pair, about 1 h 45 min in all). Neither has been run yet; the deck's numbers are still presentation4's and
notes5's.

## Kernel slides (user request: stencil, arrays and streams, animated)

New section "How the kernel works" before part 2, three new frames with beamer overlays (frame 7-9), and the
old stream slide (now frame 10) animated. Every later frame number moves up by 3 (28 main frames, 52 PDF
pages); the one literal reference ("the limit of slide 8") now says slide 11.

| frame | figure | overlays |
|---|---|---|
| 7 The stencil: which cells one update reads | `figures/stencil-d3q19.tex`: 3D lattice, axis vectors i, j, k (x east, y north, z top) | cell; 6 face neighbours (f_4 in orange, the pull example); 12 edge neighbours; 8 corners crossed out |
| 8 How the 19 values are stored in memory | `figures/field-layout.tex` (redrawn twice after review: first a 2D plane next to rows with gaps, which hid the 3D array; then a 4 x 3 x 2 array, which did not match the 3 x 3 x 3 cube of the stencil slide): the same 3 x 3 x 3 cube as the stencil slide, planes pulled apart, i, j, k axes, every cell numbered with its place in memory, the same numbers in one contiguous strip; then one row of our real arrays, colour-coded (ghost cell, 64 cells of the block, ghost cell, 2 values of padding = 68); index x + 3y + 9z, then the generated code for f_4; glossary entry Padding added | row 0 (x fastest); rows 1-2 (then y); planes 1-2 (then z); cell 13 and its face neighbours, coloured as on the stencil slide: -+1, -+3, -+9; one real row (68 values, 272 B) and the real index: +4 B, +272 B, +18 KB, +1.2 MB (f32) |
| 9 The kernel in code: one cell update, load by load | `figures/kernel-code.tex`: shortened StreamCollide, 3D mini stencil, one slot window per array, arrows code line to array | loops; 4 loads one by one; all 19; collide (arrays dimmed); 23 stores; the RVV form (8 slots per load) |
| 10 What a data stream is (old frame 7) | `figures/stream-def.tex` animated: the loop moves one cache line per overlay, then all 42 arrays; the 7-point/AA bullet moved to frame 11 | 4 |
| 11 How many streams the stencil needs (new, user question: how many streams do the flat arrays stand for?) | `figures/stream-count.tex`: the strip and numbers of frame 8; if one array held cell 13 and its 6 face neighbours: 12-14 share a row (1 stream), 10, 16 (rows), 4, 22 (planes): 5 streams; our kernel: f_0..f_6 each in its own array, read at one place (pull, x - c_i: 13, 10, 16, 14, 12, 4, 22): 7 streams; 19 read + 19 written + 4 outputs = 42, AA 23 | 3; all later frames +1 ("the limit of slide 12") |

Facts behind them: D3Q19 order and pull offsets checked against the generated scalar_cse StreamCollide
(f_3 at x+1, f_4 at x-1, f_1 at y-1, f_5 at z-1, f_9 at x+1,y+1, f_14 at x-1,z-1, f_17 at x+1,z+1); layout
fzyx, 1 ghost layer, rows padded to 16 B (waLBerla v8 Field.hpp:215-252, BufferSystem.hpp:441-452): f32 strides
68 / 4488 / 296208 values. New glossary entries: layout fzyx, pull, stencil. Overlay helpers (`visible on`,
`alt`) in the preamble.

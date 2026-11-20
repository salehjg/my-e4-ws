# notes5: audit of the RVV work and of presentation4

Started 2026-11-19 by Opus 5.5. Scope: the `rvv-support` branches of both forks, the presentation4 deck
(`docs/presentation4/`), its scripts (`scripts/presentation4/`) and raw logs
(`docs/presentation4/board-logs/`). Goal: find wrong claims, weak evidence, and mistakes in testing,
benchmarking and plotting.

## Revisions audited

| repo | branch | commit |
|---|---|---|
| my-e4-ws (superproject, `walberla-rvv-support/`) | `main` | `7cd0626` (slides last changed in `decb03c`) |
| mirrored-walberla (`submodules/walberla`) | `rvv-support` | `8c19407a` (LDC app added there; base upstream `0c8ed8c9`) |
| mirrored-pystencil2 (`submodules/pystencils`) | `rvv-support` | `a81dc547` (base upstream `20d7dcf0`) |

Line numbers refer to these revisions. "Slide N" is the page number in `docs/presentation4/build/slides.pdf`
(footer shows N / 22; backup pages 23-27).

## How to read this file

Each finding has: an ID, a severity, where it is (repo, branch, commit, file:line), what is wrong, the
evidence, what it affects (slides, figures, files), and a suggested fix. Severities:

- **S1 wrong**: a claim on a slide is false or not supported by the evidence, or a result is wrong.
- **S2 misleading**: the number is right, but the way it is shown or worded leads to a wrong conclusion.
- **S3 weak evidence**: plausible, but the evidence is thinner than the slide suggests, or a method gap.
- **S4 minor**: wording, labels, small inconsistencies.

Findings are added as they are found; the summary table at the top is kept current.

## Summary

| ID | sev | one line | slides |
|---|---|---|---|
| F1 | S1 | Headline speedups (5.55× f32, 5.12× f64 "passes its 4× goal") mix CSE/AA/prefetch/split with vectorization; with both sides below the stream cliff RVV is 2.1× / 1.4× (GCC) and 2.4× / 1.45× (Clang) the best scalar build (measured, E2, E10) | 4, 15, 16, 18 |
| F2 | S2 | The scalar wall pass is 27-32 % (f32) of the fastest builds' time on one core; never shown | 2, 5, 8, 15-17 |
| F3 | S2 | "Waits for memory in 92 % of cycles" is a backend-stall counter; the split loop still has 64 % | 8 |
| F4 | S2 | "About 4 GB/s, shared memory is the limit": a model-based whole-run average (3.6); bulk phase ≈ 4.6 GB/s vs ≈ 6 GB/s the chip moves for a similar pattern (E9): plausible, not shown | 19 |
| F5 | S4 | "4→8 cores RVV gains only 6-9 %" holds for 2 of 5 RVV builds | 19 |
| F6 | S1 | Timings depend strongly on the memory layout (THP/heap: one binary spans 3.5-7.9 MLUP/s; per build −53 % to +18 %); the default layout favours RVV AA over the scalar pull baseline | 15-21 |
| F7 | S2 | Software prefetch hurts below the cliff (probe: up to 3.6×); slide 14's "7 %, from more instructions" is the worst round and an unshown cause | 8, 14 |
| F8 | S3 | ±10 % baseline uncertainty across sessions, 3-digit speedups, not interleaved; "5.55× with both compilers" is a coincidence | 15, 16 |
| F9 | S3 | 8×/4× per-op bound only partly measured; lab's "fmadd.s tput" is a latency | 4 |
| F10 | S3 | VLEN = 256 assumed but never checked on the hardware (CMake, pystencils target, runtime) | 6 |
| F11 | S2 | Backup "7.7×" divides a lab kernel rate by a whole-program rate | 25 |
| F12 | S4 | Correctness slide overstates (sizes, "every check fails", 24/24 only x86); remainder/tail paths never run in the LBM checks | 26 |
| F13 | S4 | "19 stores" (23), f32-only byte counts, "users change nothing" | 2, 6, 12 |
| F14 | S4 | The f32 "4·10⁻⁶ agreement" is one outlier build (split), others 1.2·10⁻⁷ | 20 |
| F15 | S2 | "Auto-vectorization gives nothing": the plain kernels pass the x stride at run time; with unit stride the repo's own study found autovec on par | 15 |
| F16 | S4 | Run-loop drawing omits the wall pass; slide 27 lists an option (no output) used in no result | 5, 27 |
| F17 | S2 | Read-only stream probe does not predict the program: at 19 in-place streams RVV still misses 67-80 % of lines, scalar 20-30 % | 8, 14 |
| F18 | S2 | Split loop: −19 % (periodic box) vs +17 % (cavity) with identical kernels; resolved: memory layout flips the ranking (split/aa_pf 0.74-1.96), the aa_pf binary alone spans 3.5-7.9 MLUP/s | 13-21 |
| F19 | S1 | notes3/r03 "scalar loads collapse at the same point" was measured with GCC-generated vector gathers; true scalar loads pay ~104 cycles/line past the cliff, vector loads ~365: X60 vector misses never overlap | 8 (and r03) |
| F20 | S4 | Slide 8: "4 of 5 lines in time" violated by its own 1600 B series (0.206 at R = 10); log misquotes 0.128; log axis/units/single runs not stated | 8 |
| F21 | S4 | Timing logs record only the load average (2.0 when idle); no frequency, governor, temperature or busy-core record in all.sh | — |

## Findings

### F1 (S1): the headline speedups are not vector speedups, yet they are compared with the vector-width bound

- **Where:** my-e4-ws `main` `7cd0626`, `docs/presentation4/slides.tex:250-251` (slide 4: "One 256-bit operation per
  cycle: at best 8× (f32) and 4× (f64). These are our goals."), `:477-478` (slide 15: "f32 reaches 5.55× of the
  possible 8×"), `:490-491` (slide 16: "f64 passes its 4× goal with both compilers: 5.12× with GCC, 4.96× with
  Clang"), `:518-519` (slide 18). Goal lines drawn in `figures/speedup-1core-f32.tex:28` and
  `figures/speedup-1core-f64.tex:28`.
- **What is wrong:** the 8×/4× "goal" is the ratio of lanes per instruction, i.e. a bound for what *vectorization*
  can add. The plotted ratio is "RVV build with CSE + in-place AA + split loop (or software prefetch)" over "plain
  scalar build (no CSE, AB pattern, no prefetch, no split)". Every one of CSE, AA, prefetch and split is a
  non-vector optimization that also speeds up scalar code. A ratio of 5.12× in f64 *exceeds* the stated upper
  bound of 4×: that alone shows the ratio is not a vectorization speedup, so "passes its 4× goal" compares two
  different things.
- **Evidence:**
  1. Same session, same logs (`board-logs/board/ldc-*-1core.log`): RVV split over the *best scalar* build
     (scalar_cse_aa): GCC f32 7.678 / 2.002 = **3.84×**, f64 4.709 / 1.457 = **3.23×**; Clang f32 7.543 / 2.112 =
     **3.57×**, f64 4.432 / 1.585 = **2.80×**. Against the build that has the same CSE and AA, **f64 does not reach
     4× with either compiler**.
  2. The best scalar build is not the best scalar build that the same levers allow: the scalar code is
     memory-latency bound in exactly the way the RVV code is. New measurement (notes5 E1-A,
     `docs/notes5/board-logs/e1-A-scalar-perf.log`, method of `streams_check.sh` section ldc, GCC, 64³,
     20 − 0 steps): late lines (X60 `l2_miss`) per cell update: scalar f32 **3.09** vs RVV explicit_cse 3.07;
     scalar_cse_aa f32 **1.73** vs RVV explicit_cse_aa 1.76 (streams-ldc.log); f64 5.73 vs 5.71, 3.12 vs 2.69.
     Backend-stall share of cycles: scalar 75 % / 80 %, scalar_cse_aa 70 % / 79 % (f32 / f64).
  3. The existing kernel lab already shows that the scalar kernel doubles when it gets below the ~20-stream
     cliff: `docs/notes3/board-logs/lab7.log:8-9` (f32) and `:18-19` (f64), repeated in rounds 2 and 3
     (`:44-45, :54-55, :80-81, :90-91`): scalar AA kernel with ρ/u outputs (23 streams) 757.9 cycles/cell,
     without outputs (19 streams) 393.9 cycles/cell (**1.92×**); f64 1281.5 → 476.2 (**2.69×**). With both sides
     below the cliff, the vector gain is RVV AA+pf without outputs over scalar AA without outputs:
     f32 13.351 / 4.218 = **3.2×**, f64 6.516 / 3.970 = **1.64×** (`lab7.log:4, 9, 14, 19`; note: the lab's scalar
     `cse_scalar+aa*` kernels have *no* CSE, `rvv-8x-speedup-progress-fable5.2.md:298-306`, so with CSE the scalar
     side would be faster still and the ratios smaller).
  4. **Direct test in the program (notes5 E2, `docs/notes5/board-logs/e2-A-output-last.log`, 3 interleaved
     rounds, spread ≤ 2 %; GCC, 1 core, 64³, the verified executables).** `SWEEPGEN_LDC_OUTPUT=last` (an existing
     option, `SweepgenLdcCPU.cpp:131-132`; slide 27's change 10) writes ρ and u only in the last step, so the
     in-place loop has 19 streams instead of 23. Final fields equal to 2·10⁻⁸ (f32) / 5·10⁻¹⁶ (f64) in energy.
     Best MLUP/s, output every step → output last:

     | build | f32 | f64 |
     |---|---|---|
     | best scalar (scalar_cse_aa) | 1.996 → **3.975 (×1.99)** | 1.417 → **3.442 (×2.43)** |
     | RVV explicit_cse_aa (no prefetch) | 2.829 → 4.269 | 1.581 → **2.386 (slower than scalar)** |
     | RVV explicit_cse_aa_pf | 6.536 → 7.982 | 3.854 → 4.803 |
     | RVV split | 7.693 → 8.266 | 4.665 → 4.404 |

     With both sides below the cliff, the fastest RVV build is **2.08× (f32) and 1.40× (f64)** the best scalar
     build (bulk time only, walls excluded: 2.64× and 1.49×), instead of the 5.55× / 5.12× on the slides. In f64
     without prefetch the RVV loop is 31 % *slower* than the scalar loop. Late lines per cell
     (`e2-B-output-last-perf.log`): scalar_cse_aa 0.359 / 0.486, explicit_cse_aa 0.956 / 1.592 (f32 / f64).
  5. **The same with Clang (notes5 E10-A, `e10-A-clang-output-last.log`, 2 rounds):** best scalar 2.108 → 3.396
     (f32), 1.570 → 3.296 (f64); explicit_cse_aa_pf unchanged (6.18 / 3.54); split 7.36 → 8.02 / 4.25 → 4.78. Fastest
     RVV over best scalar with output last: **2.36× (f32), 1.45× (f64)** (bulk only 3.05× / 1.55×), against the deck's
     5.55× / 4.96× for Clang.
- **Affects:** slides 4, 15, 16, 18 (takeaways), the goal lines in both one-core speedup figures. The same framing
  is in report r03 (`docs/manual/reports/r03/chapters/09-results.tex:290` "the 4× goal is met",
  `figures/speedup-chart.tex:29`), presentation3 (`docs/presentation3/slides.tex:292` "f64 reaches its 4× goal")
  and notes3 (`rvv-8x-speedup-progress-fable5.2.md:584, 944`).
- **Fix:** define the speedup that the bound applies to (RVV over the scalar build with the *same* non-vector
  levers), or drop the bound from the speedup plots. Add a scalar build with the split loop (or with software
  prefetch, or at least the no-output AA variant) as the baseline for "what vectors add". Present the
  plain-scalar ratio as "everything we did, together", not against 8×/4×.

### F2 (S2): one third of the fastest build's time is the scalar wall pass, which no slide mentions

- **Where:** `slides.tex:198` (slide 2 takeaway: "Walls: border cells only."), `:324-341` (slide 8: "The real
  limit: too many data streams"), results slides 15-17.
- **What is wrong:** the wall passes (`SweepgenLdcCPU.py:126-145`, Target.GenericCPU index-list loops in every
  build) take a nearly constant ~2.0-2.2 s per 200 steps on one core in *every* build. In the two fastest builds
  that is 27-32 % (f32) and 15-19 % (f64) of the timed loop. The whole-program speedups are therefore capped by an
  unvectorized part (Amdahl), and the slides attribute the remaining gap to the memory streams alone.
- **Evidence:** `board-logs/board/ldc-gcc-rvv-f32-1core.log` summary table "Share of the timed loop in the wall
  sweeps": explicit_cse_aa_pf 27.2 %, explicit_cse_aa_split 31.9 %; f64 15.3 % / 18.6 %; Clang f32 25.7 % /
  31.2 %. `t_bc` = 2.02 s (plain scalar) vs 2.17 s (split) in the same runs. Bulk-only throughput of the split
  build (cells × steps / `t_bulk`): f32 11.28 MLUP/s against 7.68 whole-program. The wall pass costs about
  82 ns (≈ 131 cycles) per boundary link (122 112 links per step).
- **Affects:** slides 2, 8, 15-17; the reading of the 1-core speedups.
- **Fix:** show the time split (bulk / walls) on a results slide, or report bulk-only speedups next to the
  whole-program ones; say that the wall pass is scalar in every build and is about a third of the fastest run.

### F3 (S2): "the core waits for memory in 92 % of its cycles" reads a backend-stall counter as memory wait

- **Where:** `slides.tex:339-340` (slide 8 takeaway); source comment `:323`; progress log
  `presentation4-progress-opus5.5.md:697`.
- **What is wrong:** the number is `stalled_cycle_backend / cycles` of the X60 PMU. Backend stalls include waits for
  FP results, full issue queues, store buffer, etc., not only memory.
- **Evidence:** same log and method (`board-logs/board/streams-ldc.log`, recomputed): the split build, with only
  0.34 late lines per cell, still has **64 %** backend-stall cycles (f32; 66 % f64); explicit_cse_aa_pf 75 %
  (76 %). The scalar builds 70-80 % (notes5 E1-A). So a large part of the 92 % is not memory.
- **Affects:** slide 8 takeaway.
- **Fix:** "92 % of the cycles are backend stalls (64 % in the split loop)", or estimate the memory part from
  late lines × latency.

### F4 (S2): "about 4 GB/s ... the shared memory becomes the limit" is an estimate, and a single core already moves 6 GB/s

- **Where:** `slides.tex:523` (slide 19 title "Several cores: the shared memory becomes the limit"), `:531`
  ("Memory traffic of RVV on 8 cores: about 4 GB/s in all"); progress log `:549-551`; notes3 progress
  `rvv-8x-speedup-progress-fable5.2.md:1145-1148` ("About 3.6 GB/s is the chip's limit").
- **What is wrong:**
  1. The "memory traffic" is not measured. It is MLUP/s × an assumed 184 B (f32) / 368 B (f64) per cell
     (compulsory traffic with write-allocate). It gives 3.57 / 3.79 GB/s (explicit_cse_aa_pf, 8 cores), shown as
     "about 4".
  2. The "limit" is inferred from the saturation itself; no independent bandwidth test (STREAM-like, 1-8 cores)
     is shown. The board's own probe moved **6.0 GB/s on one core** with 8 read streams
     (`docs/notes3/board-logs/p2-stream-sweep.txt:4`, `cyc_per_line=16.9 GBps=6.021`), and 2.7-2.9 GB/s with 12-16
     streams. So ~3.6 GB/s is not "the memory's" limit; it is what this many-stream access pattern gets, and the
     mechanism (DRAM banks/rows, write-allocate, a per-cluster queue) is not identified. See also F6 (page layout).
- **Evidence:** recomputation from `ldc-gcc-rvv-f{32,64}-8core.log` (best runs): 19.402 × 184 B = 3.57 GB/s;
  10.293 × 368 B = 3.79 GB/s; scalar 8 cores 8.774 × 260 B = 2.28 GB/s.
  3. The 3.6 GB/s is a whole-run average. On 8 cores the wall pass and the halo exchange take 12.6 % and 10.0 % of
     explicit_cse_aa_pf's time (`ldc-gcc-rvv-f32-8core.log`, best run); during the bulk phase alone the same
     model gives 25.07 MLUP/s × 184 B = **4.6 GB/s**.
- **New measurement (notes5 E9, `docs/notes5/board-logs/e9-bandwidth.log`, 2 rounds):** N copies of the stream probe
  at once, one per core. Caveat: the processes are not synchronized (each reports its best pass; one N = 8 sum reads
  19.6 GB/s because some copies ran alone at the end), so median per process × N is used: read-only, 8 streams per
  core: 1 core 5.4-5.5, 4 cores ≈ 5.0-5.7, 8 cores ≈ 6.8 GB/s; the LBM pattern (19 read + 23 write, prefetch 128 B):
  8 cores ≈ 3.7-4.4 GB/s counted per stream, i.e. ≈ 5.8-6.9 GB/s of DRAM traffic with write-allocate. So the bulk
  phase's 4.6 GB/s is within ~70-80 % of what the chip moves for a similar pattern: "memory becomes the limit" is
  **plausible for the bulk phase**, but the slide's number (whole-run average, model-based) and missing evidence do
  not show it, and walls + halo (23 % of the 8-core time) are not part of that limit.
- **Affects:** slide 19 (title, bullet, takeaway's reading).
- **Fix:** "estimated 4.6 GB/s during the stream/collide phase (bytes per cell × rate), near the ~6 GB/s the chip
  reaches with the same access pattern"; measure the ceiling with a synchronized multi-core probe.

### F5 (S4): "4 to 8 cores: RVV gains only 6 to 9 % (f32), 3 to 6 % (f64)" holds for two of the five RVV builds

- **Where:** `slides.tex:535`.
- **Evidence:** `ldc-gcc-rvv-f32-{4,8}core.log`: explicit_cse_aa_pf 17.914 → 19.402 (+8.3 %), split 18.312 → 19.494
  (+6.5 %), but explicit_cse 7.690 → 10.817 (**+41 %**), explicit_cse_aa 9.285 → 13.723 (**+48 %**),
  explicit_cse_pf 12.350 → 13.887 (+12 %). Clang "1 to 4 % slower on 8 cores" (0.965-0.986) is within the
  8-core run-to-run spread of 1.3-2.2 % for several builds.
- **Fix:** "the two fastest RVV builds gain only ...".

### F6 (S1/S3): the timings depend strongly on the physical memory layout, which the benchmark does not control

- **Where:** whole timing method: `scripts/presentation4/run.sh:143-151` (runs as they come, 4 KB pages), the
  results slides 15-21, the "session effect" in the progress log (`presentation4-progress-opus5.5.md:613-627, 656-661`,
  "Cause unknown"), slide 8's bullet "Other array addresses do not move this cliff: it is the number of streams"
  (`slides.tex:334`).
- **What is wrong:** the program allocates its fields with `operator new` (waLBerla
  `include/walberla/v8/memory/Allocators.hpp:188-190`), THP is `madvise` on the board and nothing calls `madvise`,
  so every run gets 4 KB pages at whatever physical addresses the kernel hands out. New measurement: the same
  verified executables, same fields (identical field hashes), with transparent huge pages switched on for the
  process only (`GLIBC_TUNABLES=glibc.malloc.hugetlb=1`, AnonHugePages 24 MB checked in `/proc/<pid>/smaps_rollup`)
  run at very different speeds (round 1 of notes5 E1-C, `docs/notes5/board-logs/e1-C-program-thp.log`):
  GCC f32 explicit_cse_aa_pf **6.50 → 3.99 MLUP/s (−39 %)**, scalar_cse_aa 1.98 → 2.34 (+18 %), plain scalar
  1.37 → 1.51 (+11 %), split 7.67 → 8.14 (+6 %); f64 scalar −6 %, scalar_cse_aa −7 %, aa_pf −3 %.
  **Confirmed in all 3 interleaved rounds** (spread within each mode ≤ 2 %, one field hash per build and mode),
  median THP / default: f32 plain scalar **1.11**, scalar_cse_aa **1.18**, explicit_cse_aa_pf **0.61** (bulk time
  5.84 s → 11.1 s), split 1.06; f64 0.94, 0.93, 0.97, 1.02. The wall pass also changes (f32 `t_bc` 2.03 → 1.77 s,
  i.e. TLB-sensitive), f64 not. The address layout therefore moves single builds by up to −39 % / +18 %, and
  differently per build, so it moves the speedups too: with THP the f32 speedup of explicit_cse_aa_pf over plain
  scalar would read 4.0 / 1.52 = **2.6×** instead of 4.75×, the split 5.35× instead of 5.6×.
  Today's default-mode numbers repeat all.sh (plain scalar 1.358-1.375 vs 1.384; aa_pf 6.50-6.53 vs 6.56), so the
  4 KB-page result itself is reproducible on a given day. The layout is a plausible *class* of cause for the
  unexplained "session effect" (scalar baseline 8-10 % slower in later sessions, RVV builds not), but the
  direction does not match simply ("more contiguous memory later" would make f32 scalar faster, not slower), so
  that cause is not proven.
  The layout sensitivity was already known: notes3 lab5 (`docs/notes3/rvv-8x-speedup-progress-fable5.2.md:1090-1110`,
  log `docs/notes3/board-logs/lab5.log`) measured row/origin alignment 16 B (waLBerla's default) vs 32 B vs 64 B:
  f64 scalar pull (CSE) **0.885 → 1.185 MLUP/s (+34 %)** with 64-B alignment, while f32 AA + pf loses 24 % and
  f32 pull + pf 29 %. The default layout is the *best* one for the RVV AA kernels and among the *worst* for the
  scalar pull kernel, which is what the plain scalar baseline runs. So the default layout tilts the comparison
  toward RVV by up to a third in f64; the deck does not mention it.
  Heap layout (notes5 E10-B, GCC f32, 2 rounds, `e10-B-gcc-f32-heap.log`): plain scalar 1.357 → 1.415 (+4 %),
  scalar_cse_aa −1 %, explicit_cse_aa_pf 6.44 → 6.98 (+8 %), split ±0 %. In the periodic box the heap layout moves
  aa_pf and split in opposite directions (E6). Every layout tested so far gives a different ranking or ratio.
- **Affects:** every speedup on slides 15-21 (uncertainty larger than shown), the "session effect" explanation,
  slide 8's "it is the number of streams" (the stream count sets the cliff in the probe, but the program's speed
  also depends on where the arrays sit).
- **Fix:** control the layout (e.g. run each build with and without THP, or allocate with huge pages and vary
  the array offsets on purpose), and report the spread over layouts, not over 3 back-to-back runs.

### F7 (S2): software prefetch makes the stream test 2-3.6× *slower* below the cliff; the plot shows it, the text does not, and slide 14 explains the split-loop loss by instruction count instead

- **Where:** plot `docs/presentation4/figures/streams.tex` (series "4160 B + software prefetch", slide 8);
  `slides.tex:450-451` (slide 14: "with prefetch the split loop is 7 % (f32) and 13 % (f64) slower, from 33 % and
  40 % more instructions"); source comment `:429-436`.
- **What is wrong:**
  1. In the stream test the prefetch series (pfr = 512 B) is far above the no-prefetch series for 14-19 streams:
     `board-logs/board/streams-probe.log` (EV2 runs, `cyc_per_line`): R = 14 **168.0** vs 47.1; R = 16 77.3 vs 37.1;
     R = 17-19 102.7-106.6 vs 47.3-51.4. Prefetch hurts below the cliff by up to 3.6×. This is not caused by
     instruction count (R prefetches per 64-byte line against ≥ 2R vector loads). Slide 8 does not discuss it.
  2. That series is one run per point (tag `c` only); the no-prefetch series was repeated (tags `a`, `d`) and
     varies by up to 19 % near the cliff (R = 19: 51.4 vs 61.0). With huge pages, the region R = 20-23 is
     bimodal (notes5 E1-B: R = 20 214.2 vs 62.9, R = 21 242.7 vs 358.7 in two runs). No error bars.
  3. The plotted prefetch distance (512 B) is not the program's (128 B).
  4. Slide 14's "7 %" for f32 is the best-of-3 comparison, driven by one high round without prefetch:
     `docs/notes3/board-logs/lab7.log:22,58,94` (no prefetch 9.967 / 9.461 / 9.439) against `:28,64,100`
     (prefetch 9.236 / 9.173 / 9.255); round by round −7.3 %, −3.0 %, −1.9 % (cycles per cell +8.0 %, +3.8 %,
     +2.4 %). It also uses `best_mlups`, the metric that notes3 itself found to overstate AA kernels
     (`rvv-8x-speedup-progress-fable5.2.md:945-957`). f64 is consistent (−12 % to −13 % in every round).
  5. "from 33 % more instructions" is asserted, not shown; the probe in point 1 shows prefetch costing far more
     than its instructions when the hardware prefetcher already copes, which is the split loop's situation.
- **Affects:** slides 8 and 14.
- **Fix:** mention that prefetch hurts when ≤ 19 streams are live (that is the real reason the split loop does
  not want it), give f32 as "2 to 7 %", drop the causal "from more instructions" or test it (e.g. prefetch only
  every 16 cells instead of every vector iteration).

### F8 (S3): the speedups carry a ±10 % baseline uncertainty but are shown with three digits, and "5.55× with both compilers" is a coincidence presented as a result

- **Where:** `slides.tex:474-478` (slide 15), `:487-491` (slide 16), figures `speedup-1core-f32/f64.tex`.
- **What is wrong:** the plain scalar baseline moved by 8-10 % between sessions (f32: all.sh 1.384, second session
  1.244 GCC; `board-logs/board/speedup-*.log`, progress log `:743-753`) while the RVV builds moved ≤ 3.5 %. The
  slides note this in grey but keep the takeaway "f32 reaches 5.55× ... with both compilers": GCC 5.548 and
  Clang 5.550 agree to 0.04 %, far inside the 10 % session uncertainty, so the equality carries no information.
  Within all.sh the variants were not interleaved: each variant ran 3 times back to back
  (`scripts/presentation4/run.sh:138-152`), scalar.sh, autovec.sh and rvv.sh one after the other
  (`all.sh:76-89`); the "best of 3" spread therefore measures only back-to-back repeatability. With F6, the real
  run-to-run spread over memory layouts is much larger.
- **Fix:** interleave all variants of a column round-robin; report median and min-max over several sessions (or
  over THP on/off); give speedups with two digits and a range ("5.5-6.1×").

### F9 (S3): "one 256-bit operation per cycle: at best 8× / 4×" has partial evidence, not cited; the lab's scalar FMA "throughput" is a latency

- **Where:** `slides.tex:250-251` (slide 4); `misc/x60-lab/probes/ops.cpp:65` (superproject `7cd0626`); its result
  `docs/notes3/board-logs/p2-ops.txt:35` ("fmadd.s tput 5.02 cycles/insn").
- **What is wrong:**
  1. The bound needs both sides: vector and scalar throughput per op class. `p2-ops.txt` has vfadd/vfmul/vfmacc
     e32/e64 at ~1.0 cycles/insn and scalar fadd.s/fmul.s at 1.02, which supports 8× for f32 add/mul. But
     scalar `fmul.d` is 1.26 cycles (so up to 5× for f64 multiplies), vector loads `vle32` (L1) take 2.01 cycles vs
     `flw` 1.27 (≈ 5×, not 8×, per element), and scalar FMA throughput was never measured.
  2. `ops.cpp:65` measures `fmadd.s ft2, ft0, ft1, ft2` repeated: a dependent chain on `ft2`, i.e. latency,
     but labels it "tput". Every other scalar "tput" line uses 8 independent destinations (`TPS8`).
  3. For a loop that is memory-latency bound on both sides (F1, F3), per-op throughput is not the bound at all.
- **Fix:** cite `p2-ops.txt` on the slide, state the bound as "for arithmetic", fix the label (or the probe) in
  `ops.cpp:65`.

### F10 (S3): the VLEN = 256 assumption is checked only at compile time; any RVV host with VLEN 128 silently gets wrong results

- **Where:** mirrored-walberla `rvv-support` `8c19407a`: `cmake/compileroptions/GNU.cmake:23-31` and
  `cmake/compileroptions/Clang.cmake:22-31` (both since commit `dbb1b400`): any `/proc/cpuinfo` ISA matching
  `rv64[a-z]*v` gets `-march=rv64gcv_zvl256b`. mirrored-pystencil2 `rvv-support` `a81dc547`:
  `src/pystencils/codegen/target.py` `_riscv_has_rvv` (selects `RISCV_RVV` for any V host),
  `src/pystencils/jit/cpu/compiler_info.py` (`_RISCV_RVV_MARCH`), `include/pystencils_runtime/rvv.hpp:44-45`
  (`#error` only if the *compiler* is not told zvl256b).
- **What is wrong:** `zvl256b` tells the compiler that VLEN ≥ 256 and the generated VLS code assumes 8 f32 lanes
  per register. On a VLEN-128 core (common: e.g. C908-class cores) `vsetvli` grants only 4 lanes and half of every
  vector is silently skipped; GCC's own auto-vectorization under `zvl256b` has the same problem for all of
  waLBerla. Nothing reads `vlenb` at configure time or at run time. The docstring of `Target.RISCV_RVV` states the
  requirement, but `CurrentCPU` and `WALBERLA_OPTIMIZE_FOR_LOCALHOST` select it without checking.
- **Affects:** not the presented results (K1 has VLEN 256); portability and the slide 6 claim "a safety check:
  compile error unless built for 256 bits" (it checks the flags, not the hardware).
- **Fix:** read `vlenb` (e.g. a tiny `csrr vlenb` probe at configure time, `scripts/legacy-vla/vlenb_probe.cpp`
  exists) and select zvl256b / RVV only when it is 32; add a run-time assert in the runtime header.

### F11 (S2): backup slide 25 compares a kernel-lab number with a whole-program number ("7.7×")

- **Where:** `slides.tex:751-753` ("Lab: hand-written split loop 10.83 MLUP/s (cycle average, Clang with X60
  tuning) against 1.40 for the plain scalar build: 7.7×").
- **What is wrong:** 10.83 is a kernel-only rate in the kernel lab (periodic box, no halo, no walls;
  `rvv-8x-speedup-progress-fable5.2.md:963`), 1.40 is the whole program's plain scalar build. The ratio mixes a
  kernel with a whole program (and a hand-written kernel with generated code), and it puts "7.7×" next to the
  8× goal.
- **Fix:** compare with the lab's own scalar kernel, or drop the ratio.

### F12 (S4): the correctness backup slide says more than the checks show

- **Where:** `slides.tex:757-772` (slide 26).
- **What is wrong / evidence:**
  1. "Every build matches it cell by cell: differences at most 2·10⁻¹⁶": true, but only for the oracle cases
     16³, 32×16×16 (2 processes), 16×24×8 (6 processes), 100/101 steps (`board-logs/board/verify-*.log`). The timed
     configuration (64³, 210 steps) is covered only by agreement between builds and by repeatability.
  2. "Broken on purpose (wrong wall rule, missing wall pass, missing exchange): every check fails": each mutation
     is caught by *at least one* check, not by every check; M4 and M5 pass at np = 1 by design
     (`presentation4-progress-opus5.5.md:263-273`). The mutations ran on x86, GCC f64, on 2 of the 11 builds
     (scalar, scalar_cse_aa).
  3. "24 of 24 waLBerla tests pass" ran on x86 only (`board-logs/x86/ctest-gcc-f64.log`), while the caption opens
     with "Checked on x86 and on the board". These tests also never touch the vector code: their generator
     (mirrored-walberla `8c19407a`, `tests/sweepgen/LbmScenarios/LbmAlgorithms.py:36-46`) sets
     `Target.CurrentCPU` but never `cpu.vectorize.enable`, so even the new `AAMatchesPull` test (commit `efa2b70c`)
     compiles plain C++ kernels. The RVV kernels are verified only by the LDC oracle runs.
  4. Coverage gap: every verification domain has x extents that are multiples of the vector length (16, 32, 8)
     and y extents that are multiples of the split's 2 rows. So the scalar remainder loops of the generated RVV
     LBM kernels and the split driver's `rows < BY` tail (mirrored-walberla `8c19407a`,
     `apps/benchmarks/SweepgenLbmCPU/lbm_split.py:221`) never ran in the LBM checks. (pystencils' own unit tests
     do run remainder loops with odd sizes, e.g. `tests/nbackend/test_rvv_execution.py:133-151`, but not the LBM
     kernels with prefetch, row pointers and the split driver.)
  5. "Scalar builds: 0 vector instructions in the whole program": true for the executable (notes5 E5,
     `docs/notes5/board-logs/e5.log`: 0 with and without `--mattr=+v`, no `<unknown>`), and for libc, libm,
     libstdc++, libmpi, libopen-pal, but the process also loads `libz.so.1` (zlib-ng), which contains **132 RVV
     instructions** (ELF attribute `v1p0`). Most likely never called in the timed loop; the slide's wording is still
     not literally true.
- **Fix:** name the domain sizes; "each broken version fails at least one check"; "24 of 24 tests on x86"; add
  one oracle case with odd extents (e.g. 13×7×5) to `verify.sh`.

### F13 (S4): small inaccuracies on slides 2, 6 and 12

- `slides.tex:198` (slide 2): "19 loads, about 200 operations, 19 stores": the timed runs store ρ and u in every
  step (`output=every` in every log line), i.e. 23 stores; slide 7 itself counts the 4 output streams.
  ("About 200 operations" is fair: about 240 arithmetic operators in the CSE scalar inner loop of the generated
  `StreamCollide`, x86 build tree.)
- `slides.tex:401, 412` (slide 12): "260 bytes per cell", "184 bytes per cell" are f32 values that include an
  assumed write-allocate read; f64 is 520 / 368. Neither is stated.
- `slides.tex:286-287` (slide 6): "Users change nothing" — the generator script must opt in to vectorization
  (`SweepgenLdcCPU.py:71-77`: `cpu.vectorize.enable = True`, `assume_inner_stride_one = True`) and choose
  prefetch / AA / split. That is the same opt-in as for AVX on x86, but not "nothing".

### F14 (S4): one build (split, f32) is a systematic outlier in the energy check, hidden in "all builds agree"

- **Where:** `slides.tex:577-578` ("All builds agree (energy to 10⁻¹⁵ in f64, 4·10⁻⁶ in f32)").
- **Evidence:** `ldc-gcc-rvv-f32-1core.log`: the 10 non-split builds agree to 1.2·10⁻⁷ relative (11.3666528 …
  11.3666559), the split build gives 11.3666148 (3.3·10⁻⁶ away). Against the f64 result 11.3665944, the split is
  closer (1.8·10⁻⁶ vs 5.1·10⁻⁶). In f64 the split agrees to 6·10⁻¹⁶, and its oracle errors are the smallest of all
  builds (`verify-gcc-f32.log`: 7.32·10⁻⁸ vs 9.16·10⁻⁸). So it is a rounding-order effect, not a bug, but the
  4·10⁻⁶ on the slide is entirely this one build.
- **Fix:** "f32: 1.2·10⁻⁷ between the 10 single-loop builds; the split loop rounds differently (3·10⁻⁶, closer to
  f64)".

### F15 (S2): "Auto-vectorization gives nothing" tests a handicapped baseline; the repo's own earlier study found the opposite with unit stride

- **Where:** `slides.tex:477-478` (slide 15 takeaway); the autovec family in mirrored-walberla `8c19407a`
  `apps/benchmarks/SweepgenLdcCPU/SweepgenLdcCPU.py:70-81` (explicit: `assume_inner_stride_one = True`; autovec:
  plain `CreateKernelConfig(target=GenericCPU)`).
- **What is wrong:** the auto-vectorized builds compile kernels whose x index is `ctr_0 * _stride_f_0` with a
  *runtime* `_stride_f_0` (generated `StreamCollideEven`, x86 tree `gcc-f32/.../SweepgenLdcCPU_autovec_cse_aa/gen/
  SweepgenLdcCPU.cpp:23,41`). The compiler cannot assume unit stride; the RVV build is generated with exactly that
  promise. GCC then vectorizes only the wall kernels and Clang nothing (progress log `:317-319, :385-387`). So the
  bars measure "auto-vectorization without the unit-stride promise", not what compiler auto-vectorization can do.
- **Evidence of the opposite:** `misc/rvv-vs-autovec/README.md:186-207, 216-235` (board, 2026-11-01): on an LBM
  kernel with unit stride (constant strides, or Clang's runtime versioning on stride == 1), Clang autovec reached
  8.70-10.10 MLUP/s (f64) against 10.60 for GCC + explicit RVV, and 22.08 vs 21.34 (f32) at LMUL 1: "with the best
  available auto-vectorization, our explicit path is about on par, slightly ahead".
- **Affects:** slide 15 takeaway, the hatched bars on slides 15-19, the narrative "users need our RVV target".
- **Fix:** qualify it ("for these generated kernels, which pass the x stride at run time, the compilers do not
  vectorize the update"), or add an autovec build with unit inner stride (e.g. constant strides or
  `__builtin_assume(_stride_f_0 == 1)`) as a fair auto-vectorization baseline.

### F16 (S4): the run-loop drawing omits the wall pass; slide 27 lists a change that no result uses

- `docs/presentation4/figures/build-run.tex` (slides 5 and 27) draws the run as "generated kernel on each block →
  halo exchange", ×200. That is presentation3's periodic box; the cavity also runs the wall pass every step, and
  it is 27-32 % of the fastest f32 builds' time (F2).
- Slide 27, change 10 "no density and velocity output" (`slides.tex:783`): every presentation4 timing uses
  `output=every` (all 396 result lines of the matrix), so this change is in none of the shown numbers. It is also the
  change that doubles the best scalar build (F1, E2).

### F17 (S2): the read-only stream probe does not predict the program: at 19 in-place streams the RVV loop still misses most lines, the scalar loop does not

- **Where:** slide 8 (`slides.tex:332-336`: "Up to 19 streams the hardware prefetchers bring at least 4 of 5 lines
  in time ... it is the number of streams"), slides 13-14 (the split-loop rationale "at most 7 arrays per pass: the
  hardware prefetcher keeps up").
- **What is wrong:** the probe (`misc/x60-lab/probes/mem.cpp`, `stream R 0`) measures read-only streams in a light
  loop. The program's in-place streams are read-modify-write. In the program with 19 in-place streams
  (output last, notes5 E2-B, `docs/notes5/board-logs/e2-B-output-last-perf.log`, 20 − 0 steps):
  - scalar_cse_aa: 0.359 (f32) / 0.486 (f64) late lines per cell, i.e. about 30 % / 20 % of the 1.19 / 2.38 lines
    a cell touches (wall pass included), backend stalls 49 % / 55 %;
  - RVV explicit_cse_aa: **0.956 / 1.592** late lines per cell (about 80 % / 67 % of its lines), backend stalls
    85 % / 88 %; in f64 it is slower than the scalar loop (2.39 vs 3.44 MLUP/s, F1 point 4).
  So below 20 streams the hardware prefetcher keeps up with the scalar loop but not with the RVV loop: the cliff
  depends on the access type (read vs read-modify-write) and on how fast the loop consumes lines, not only on
  the number of streams. The probe never measured RMW streams or a 19-RMW pattern.
- **Affects:** slide 8's mechanism ("it is the number of streams"), slide 14 ("the hardware prefetcher keeps up").
- **Fix:** add an RMW pattern (`mem stream` with each read array also written) to the probe sweep; state the
  cliff as "~20 read streams in the probe"; show that the program's RVV loop needs prefetch or splitting even at
  19 streams.

### F18 (S2): the split loop is 19 % slower in presentation3 and 17 % faster in presentation4; the decks contradict each other and neither explains it

- **Where:** presentation3 `docs/presentation3/slides.tex` (results; split slower in f32), its log
  `docs/notes3/board-logs/presentation3/walberla-rvv-f32-1core.log` (aa_pf 7.16-7.27, split 5.50-5.91);
  presentation4 `slides.tex:456` ("Split loop against in place + prefetch ... GCC 1.17× / 1.21×"), bold "fastest
  build" on slides 15-21; progress log `presentation4-progress-opus5.5.md:557-565` ("not explained (not
  investigated)").
- **Evidence that it is real and not a measurement slip (notes5 E3, `docs/notes5/board-logs/e3-split-conflict.log`,
  one session, interleaved, 3 rounds):**
  - The generated split kernels are identical in both apps (the `LBM_SPLIT` section of both generated sources
    differs only after the namespace ends; both `--split=2,5,3`), and both apps call the driver identically
    (`SweepgenLbmCPU.cpp:119-130` vs `SweepgenLdcCPU.cpp:173-182`).
  - presentation3's own binaries, today: f32 aa_pf 7.41-7.81, split 6.24-6.60 → split/aa_pf **0.84** (energies equal
    to the presentation3 log to all printed digits); f64 aa_pf 4.14-4.21, split **4.10-4.88** (a 19 % spread in one
    session).
  - presentation4's binaries, same session: f32 aa_pf 6.46-6.52, split 7.60-7.68 → **1.18**.
  - Flow state ruled out: cavity with warm-up 1000 instead of 10 (developed flow): aa_pf 6.46-6.52, split
    7.60-7.66, identical to warm-up 10. (all.sh's warm-up check had covered aa_pf only.)
  - Consequence: whether "the split loop is the fastest build" depends on the app around the same kernel. With
    the phase timers of the cavity (bulk: aa_pf 5.84 s, split 4.63 s per 200 steps) and the periodic box's totals
    (aa_pf 6.71 s, split 8.25 s), one halo-exchange cost cannot make both apps consistent (it would have to be 0.9 s
    for aa_pf and 3.6 s for the split).
- **Resolved (notes5 E6, `docs/notes5/board-logs/e6-layout.log`): it is the memory layout.** Same binaries, same
  results (one energy per build and mode), only the placement of the allocations changed through glibc tunables
  (default mmap; `glibc.malloc.hugetlb=1`: 2 MB pages; `glibc.malloc.mmap_threshold=33554432`: the f32 fields on the
  brk heap; mappings recorded from `/proc/<pid>/maps`). f32, GCC, 1 core, 2 rounds, best MLUP/s, split / aa_pf:

  | app | default | THP | heap |
  |---|---|---|---|
  | periodic box (presentation3) | aa_pf 7.78, split 6.42 → **0.83** | aa_pf **3.71**, split 7.27 → **1.96** | aa_pf 7.90, split 5.85 → **0.74** |
  | cavity (presentation4) | 6.52, 7.66 → **1.17** | 7.08 / **4.33** (two rounds), 8.03 → 1.14 | 6.95, 7.65 → 1.10 |

  The ranking flips with the layout, in both apps. Mostly the in-place + prefetch build moves: **the same
  executable runs at 3.5 to 7.9 MLUP/s** depending on where its memory sits, and with huge pages it is even
  bimodal between runs. The split build moves less (5.6-8.0). So "the split loop is the fastest build"
  (presentation4) and "the split loop is slower" (presentation3) are both layout outcomes, not kernel properties.
- **Affects:** slides 13-21 (the split loop as "the fastest build", the 1.17-1.22× gains), the presentation3 vs
  presentation4 story, report r03's conclusion on the split kernel.
- **Fix:** do not present the split's advantage as a property of the kernel until the cause is known; show both
  apps' numbers.

### F19 (S1): "Scalar loads collapse at the same point" (notes3, report 3) was measured with vector gathers; true scalar loads do not collapse — the cliff is a property of the X60's vector loads

- **Where:** superproject `7cd0626`: `docs/notes3/rvv-8x-speedup-progress-fable5.2.md:224-225` ("Scalar loads collapse
  at the same point (R = 24: 352 cycles per line), so the cliff is not specific to vector loads"), report 3
  `docs/manual/reports/r03/chapters/04-root-cause.tex:97` (same sentence), data
  `docs/notes3/board-logs/p2-stream-levers.txt:1-4`; probe `misc/x60-lab/probes/mem.cpp:132-140` (the `scalar=1`
  path). Slide 8's mechanism (`slides.tex:332-339`) rests on the same reading.
- **What is wrong:** `mem.cpp` is built with `g++ -O2 -march=rv64gcv_zvl256b_zicboz` (`mem.cpp:24`,
  `streams_check.sh:60`). GCC auto-vectorizes the 8 "scalar" loads into `vlseg8e64` + 8 `vluxei64` gathers: the
  board's binary contains 10 `vluxei`/`vloxei` (notes5 E7 log). So `scalar=1` measured vector gathers.
- **Evidence (notes5 E4 + E7, `e4-stream-order.log`, `e7-scalar-vs-vector.log`, 2 rounds each, equal within 1 %):**
  probes rebuilt with `-fno-tree-vectorize -fno-tree-slp-vectorize` (0 gathers, 13-14 `flw`):

  | read streams | vector `vle32`, sequential | true scalar `flw`, sequential | vector, random order | scalar, random order |
  |---|---|---|---|---|
  | 8 | 18.9-19.2 | 16.0-16.1 | **357-358** | 105 |
  | 16 | 38.6 | 24.9 | 365 | 104 |
  | 24 | **367** | **103-104** (`mem.cpp scalar=1`: 115) | 365-366 | 104 |

  Pointer chase: 356 cycles for one miss, 72 per miss with 6 chains. So scalar misses overlap (≈ 3.5-5 in flight),
  vector-load misses **never** overlap: 8 independent vector loads in random order cost one full DRAM latency
  each. Past the cliff, true scalar loads pay ~104-115 cycles per line, vector loads ~365.
- **Consequences:** (1) the cliff is specific to vector loads: for RVV code the hardware prefetcher is the *only*
  source of memory-level parallelism, which is why software prefetch (a scalar hint) doubles the RVV loop and
  helped the scalar loop only ~15 % in notes3; (2) it explains F17 (at 19 in-place streams scalar copes, RVV does
  not); (3) "the X60 follows about 20 streams" describes the prefetcher, but the 360-cycle penalty per line is
  the vector unit's blocking misses; (4) report 3's root-cause chapter needs correcting.
- **Fix:** rebuild `mem.cpp` with `-fno-tree-vectorize` (or `volatile`/asm loads in the scalar path) and correct
  notes3 `:224-225`, r03 `04-root-cause.tex:97`; on slide 8 say "a vector load that misses waits the full latency;
  only the prefetchers overlap them".

### F20 (S4): slide 8's plot: "at least 4 of 5 lines in time" is violated in its own data; the log misquotes it; axis and legend details

- **Where:** `slides.tex:332-334`; `docs/presentation4/figures/streams.tex`; progress log
  `presentation4-progress-opus5.5.md:687-689` ("up to R = 19, L2 demand misses per line ≤ 0.031 / 0.128 / 0.064").
- **Evidence:** `python3 scripts/presentation4/streams_table.py docs/presentation4/board-logs/board`, tag b1
  (1600 B apart): l2_miss per line **0.206 at R = 10**, 0.171 at R = 12 (plotted in `streams.tex`, series `sb1`), i.e.
  fewer than 4 of 5 lines in time; the progress log's 0.128 is wrong. The same layout costs up to 1.7× more cycles
  per line well below the cliff (R = 2: 53.5 vs 31.9 for 4160 B; R = 10: 75.3 vs 41.5): the addresses do matter for
  the cost, they only do not move the cliff much (20-22). "It is the number of streams" is too strong (see also
  F6, F18, F19).
- **Plot details:** the top panel is logarithmic (`semilogyaxis`) without saying so; the bottom axis label "late
  lines" has no unit (late lines per line read); the software-prefetch series has no bottom-panel data (dropped
  without a note, the legend suggests it is in both panels); every series except tag `a` is a single run; the
  shaded "prefetchers keep up" region spans R = 1-19 although the prefetch series inside it is 2-3.6× slower (F7).
- **Fix:** "up to 19 streams, 4 of 5 lines in time (4160 B layout)"; label the log axis and the unit; note the
  single runs.

### F21 (S4): the timing logs do not record frequency, governor, temperature or other load

- **Where:** `scripts/presentation4/run.sh:94-96` (prints only `/proc/loadavg`), `all.sh`, `recheck.sh`,
  `speedup_check.sh` (no `scaling_cur_freq`, `scaling_governor` or thermal reads; `grep` finds none).
- **What is wrong:** the board's load average is 2.0 when idle (D-state kernel threads, progress log `:99`), so it
  cannot show other load; the governor (`performance`, 1.6 GHz) was checked once, after all.sh (progress log
  `:618`). During this audit `bluetoothd` (root) used ~5 % of a core on core 1, the benchmark core's cluster
  (`docs/notes5/board-logs/e1-bluetoothd.log`). `recheck.sh` and `speedup_check.sh` did log busy cores; all.sh did not.
- **Fix:** log governor, `scaling_cur_freq`, temperatures and busy cores (two `/proc/stat` samples) before every
  run, as the notes5 scripts do.

## Resolution status (2026-11-20)

| finding | status |
|---|---|
| F1 | **confirmed by direct measurement** (E2 GCC, E10 Clang): vector share 2.1-2.4× (f32), 1.4-1.45× (f64) against a scalar build below the cliff; slide text to change (proposal file) |
| F2, F3, F5, F11, F13, F14, F16, F20, F21 | confirmed from the existing logs; wording/plot changes only |
| F4 | partly resolved (E9): a ~6 GB/s ceiling for a similar pattern makes "memory is the limit" plausible for the bulk phase; the slide's number and evidence still need fixing; a synchronized multi-core probe would settle it |
| F6 | **confirmed** (E1-C, E6, E10-B); the cause of the presentation4 "session effect" is still not proven, layout is a plausible class |
| F7, F8, F9, F12, F15 | confirmed; method/wording changes |
| F10 | design hazard, not affecting the K1 results; code change proposed |
| F17 | **new, measured** (E2-B) |
| F18 | **resolved**: memory layout (E6); flow state ruled out (E3) |
| F19 | **new, measured** (E4, E7): corrects notes3 and report 3 |
| slide 9 page-size question | resolved: the cliff holds with 4 KB pages (E1-B) |
| slide 11 compiler claim | resolved: confirmed for board GCC 14.2 and Clang 18.1 (E5) |
| scalar "0 RVV instructions" audit method | resolved: valid for the executables (E5); zlib-ng exception noted in F12 |
| pystencils RVV unit tests at `a81dc547` | resolved: 109 passed on the board (E8) |
| board sources = committed sources | resolved: 273 source files of the app, SweepgenLbmCPU, sweepgen, v8 headers, cmake and pystencils `src` sha256-equal between the board copy and the commits above; `scripts/presentation4` and `misc/x60-lab` equal too |
| all numbers in the deck's tables and figures | re-derived independently from the 36 `ldc-*.log` (own parser): every plotted and tabulated value matches |

Nothing in the deck, the forks or the presentation4 scripts was changed. Concrete text for every change:
`docs/notes5/proposed-slide-changes-opus5.5.md`.

## Experiments run for this audit (board, notes5)

All runs: one core (core 2, cluster 0), governor `performance` at 1.6 GHz (checked at start), temperatures
43-47 °C, the verified presentation4 executables (sha256 checked against `prepare.sh`'s verify logs), no build,
detached `screen`. Scripts in `docs/notes5/board/`, logs copied to `docs/notes5/board-logs/`.

### E1 (board 2026-11-18 07:52-08:16, `audit_e1.sh`)

- **A, perf counters of the scalar builds** (`e1-A-scalar-perf.log`): late lines per cell: f32 scalar 3.085,
  scalar_cse_aa 1.726, explicit_cse 3.067 (cross-check with presentation4's `streams-ldc.log`: 3.077, agrees);
  f64 5.731, 3.115, 5.713. Backend stalls: scalar 75 / 80 %, scalar_cse_aa 70 / 79 %, explicit_cse 90 / 92 %
  (f32 / f64). Instructions per cell: f32 scalar 388, explicit_cse 77; f64 409, 123. → used in F1, F3.
- **B, stream probe with 4 KB pages vs huge pages** (`e1-B-probe-thp.log`, 2 runs): the cliff holds with 4 KB
  pages: thp=0 R = 19 48-49 cycles/line, R = 20 130.5 (both runs), R = 21 266-271, R ≥ 22 355-359. With huge
  pages the transition R = 20-23 is bimodal (R = 20: 214.2 / 62.9; R = 21: 242.7 / 358.7; R = 23: 360.1 / 312.0).
  19 + 23 pattern: 182-186 (4 KB) vs 177-182 (THP); with pfr = 128: 92-93 vs 90-91.
  **Conclusion: the slide-8 cliff (~20 streams) does not depend on the page size; this concern is resolved.**
  The noise near the cliff is not shown on the slide (F7).
- **C, the program with THP vs default** (`e1-C-program-thp.log`, 3 interleaved rounds) → F6.
- Background load: `bluetoothd` (root) used about 5 % of a core during E1 (CPU time 29:44 → 30:51 in 23 min,
  `e1-bluetoothd.log`), on core 1 (same cluster as core 2), later core 6. The timing scripts record only the load
  average, which is 2.0 on an idle board (D-state kernel threads), so such load is invisible in the logs.

### E2 (board 2026-11-18 08:16-08:32, `audit_e2.sh`)

- **A, output every step vs output last** (`e2-A-output-last.log`): see the table in F1 point 4. One field hash per
  build and mode in all 3 rounds; every-vs-last energies agree to 2·10⁻⁸ (f32) / 5·10⁻¹⁶ (f64) (different generated
  kernels round differently; the split builds give identical fields). Oddity, not pursued: the f64 split build is
  6 % *slower* with output last (4.40 vs 4.67), although it does less work.
- **B, perf counters with output last** (`e2-B-output-last-perf.log`): see F17.

### E3 (board 08:32-08:48, `audit_e3.sh`) → F18

`e3-split-conflict.log`. presentation3's periodic-box binaries (built 2026-11-14 board time; energies equal to the
presentation3 log) and presentation4's cavity binaries, interleaved, 3 rounds, GCC, 1 core:

| | f32 aa_pf | f32 split | split/aa_pf | f64 aa_pf | f64 split |
|---|---|---|---|---|---|
| periodic box, warm-up 10 | 7.41-7.81 | 6.24-6.60 | **0.84** | 4.14-4.21 | 4.10-4.88 |
| cavity, warm-up 10 | 6.46-6.52 | 7.60-7.68 | **1.18** | 3.86-3.89 | 4.58-4.62 |
| cavity, warm-up 1000 | 6.46-6.52 | 7.60-7.66 | 1.18 | 3.87-3.88 | 4.59-4.63 |

### E4 (board 08:48-08:50, `audit_e4.sh`, probe `stream_order.cpp`) → F19

`e4-stream-order.log`, huge pages, 2 rounds (equal within 3 %):
- pointer chase: 1 chain 356.4 cycles per miss, 6 chains 72.1 (≈ 5 misses overlap);
- vector loads (2 × `vle32` per line, 8 arrays before the sum), **sequential**: R = 8 17.7-17.8, R = 16 37.0-37.2,
  R = 19 365.4-365.8, R = 24 358.5-358.9, R = 32 358 cycles per line;
- the same, **random line order**: R = 8 **347.9-354.7**, R = 16 353-363, R ≥ 19 362-366 (4 KB pages: R = 24 437-438,
  page walks); `mem.cpp stream 24 0` 363.7-364.3 and `stream 8 0` 19.2-19.3 (cross-check: agrees with the new probe).

### E5 (board 08:50-08:51, `audit_e5.sh`): no timing

`e5.log`: (1) board GCC 14.2 and Clang 18.1 both compile `__builtin_prefetch` to nothing with
`-march=rv64gcv_zvl256b` and to `prefetch.r` / `prefetch.w` with `_zicbop`: **slide 11's claim is confirmed for the
board's compilers** (and holds for Clang too). (2) ELF attributes and RVV counts: scalar executables `rv64imafdc…`
without V, 0 RVV instructions with and without `--mattr=+v`, 0 `<unknown>`: **the scalar audit's count is valid**
(the theoretical gap, decoding by attributes, does not hide anything here). System libraries 0, except
`libz.so.1.3.1.zlib-ng` with 132 (F12 point 5).

### E6 (board 08:51-08:56, `audit_e6.sh`) → F18, F6

`e6-layout.log`: table in F18. Mappings > 8 MB per mode are logged (default: the 21 MB PDF field and the 63 MB
arena as anonymous mmaps; THP: AnonHugePages 24 576 kB; heap: a 36 MB `[heap]`).

### E7 (board 08:56-08:58, `audit_e7.sh`) → F19

`e7.log`, `e7-scalar-vs-vector.log`: `stream_order_nv` and `mem_nv` built with `-fno-tree-vectorize
-fno-tree-slp-vectorize` (0 gathers each); the board's `presentation4/probe/mem` (streams_check.sh build) has 10
gathers. Table in F19.

### E8 (board 08:59-09:03, `audit_e8.sh`): no timing

`e8.log`: pystencils RVV tests (`test_rvv_target.py`, `test_rvv_codegen.py`, `test_rvv_execution.py`) on the board
copy of `a81dc547` (src and tests sha256-equal to the laptop): **109 passed**, rc 0. The fork's RVV unit tests are
green at the committed revision.

### E9 (board 09:03-09:05, `audit_e9.sh`) → F4

`e9-bandwidth.log`. Concurrent copies of the stream probe, one per core; unsynchronized, so only per-process
medians are meaningful (see F4).

### E10 (board 09:05-09:16, `audit_e10.sh`) → F1, F6

- **A, Clang, output every step vs last** (`e10-A-clang-output-last.log`, 2 rounds, one field hash per build and
  mode): table in F1 point 5.
- **B, GCC f32, fields on the brk heap vs default** (`e10-B-gcc-f32-heap.log`, 2 rounds): see F6. Today's default
  runs repeat all.sh within 2 % (aa_pf 6.44 vs 6.56, split 7.58 vs 7.68, plain scalar 1.357 vs 1.384).

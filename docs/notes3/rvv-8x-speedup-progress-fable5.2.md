# Progress log: RVV toward 8× on the K1 (Fable 5.2)

Working log for [`rvv-8x-speedup-plan-fable5.2.md`](rvv-8x-speedup-plan-fable5.2.md).
Each entry is one loop: hypothesis → experiment → measurement → conclusion → next action.
Nothing is committed.

## Status

| phase | state |
|---|---|
| 0 set up (notes3, `misc/x60-lab/`) | done |
| 1 attribute cycles (`perf record`) | done (Loop 1): latency-bound DRAM misses, prefetcher idle |
| 2 X60 characterisation probes | done (Loops 2, 5) |
| 3 D3Q19 kernel lab | done (Loop 3): reproduces waLBerla within 5% |
| 4 lever experiments | over the generated kernel: software prefetch 2.1× (Loop 3), direction split 2.8× (Loop 4), AA + split 3.6× = 9.11 MLUP/s f32 (Loop 7) |
| 5 land winners in the stack | software prefetch (Loop 6); in-place AA streaming in sweepgen + v8 halo exchange + app, with a regression test (Loop 9); RVV selector .vf operands + FMA (Loop 10); pull-init bug fixed (Loop 9); X60 `-mtune` in CMake (Loop 11); row pointers + constants in registers (Loop 12, board gate pending) |
| 6 end-to-end verification | GCC f32/f64 1-core matrices (Loops 6, 9): **f32 5.06×, f64 4.14×** the plain scalar build (3.45× / 2.74× the best scalar sweep); 4-process runs (Loop 12); board RVV tests 145 passed (Loop 10); waterfall in "Phase 6: result" |

Starting point (waLBerla `SweepgenLbmCPU`, 64³, one core, from notes2): best explicit vs
plain scalar was 1.31× (GCC f64), 1.73× (GCC f32), 1.92× (Clang f32). Goal: 8× f32, 4× f64.
Now (GCC, end to end): f64 3.95 MLUP/s = **4.14×**, f32 7.08 MLUP/s = **5.06×** the plain scalar
build (see "Phase 6: result" at the end).

## Loop 0 (2026-11-13 laptop / 2026-11-12 board time): is the sweep really bandwidth-bound?

**Hypothesis under test (from notes2):** the D3Q19 sweep is limited by memory bandwidth, so
better vector code cannot help.

**Experiment.** Read-only: the existing binaries in
`/home/bananapi/saleh/walberla-build-gcc-f32/apps/benchmarks/SweepgenLbmCPU/` (and the f64
dir for the tiny grids), `taskset -c 2`, under
`perf stat -e cycles,instructions,L1-dcache-loads,L1-dcache-load-misses,dTLB-load-misses,dTLB-store-misses`.
Steps chosen so each run does about 12 M cell updates, 5 warmup steps. One run each (not
best of 3), board otherwise idle. Counters cover the whole process (init included); the
cycles-per-cell values use the app's own timed seconds at 1.6 GHz.

### Grid-size sweep, GCC f32

| variant | N³ | MLUP/s | cycles (1e9) | insns (1e9) | L1D load misses (1e6) | dTLB load / store misses (1e6) |
|---|---|---|---|---|---|---|
| explicit_cse | 16³ | 2.09 | 9.99 | 1.66 | 30.5 | 55.5 / 35.3 |
| explicit_cse | 32³ | 2.18 | 9.73 | 1.32 | 23.3 | 54.9 / 35.7 |
| explicit_cse | 64³ | 2.34 | 10.07 | 1.31 | 24.2 | 60.6 / 39.7 |
| scalar_cse | 16³ | 1.35 | 14.98 | 5.50 | 29.0 | 262 / 277 |
| scalar_cse | 32³ | 1.42 | 14.52 | 4.86 | 22.7 | 264 / 280 |
| scalar_cse | 64³ | 1.53 | 14.82 | 4.95 | 22.1 | 286 / 306 |

Derived at 64³ (13.1 M cell updates including warmup):

| | explicit_cse | scalar_cse |
|---|---|---|
| timed cycles per cell | ~685 | ~1045 |
| instructions per cell | ~100 | ~378 |
| IPC | 0.13 | 0.33 |
| L1D load misses per cell | ~1.85 (≈15 per 8-cell iteration) | ~1.7 |
| speedup this run | 1.53× | 1.00× |

### Transparent huge pages, 64³, GCC f32

`GLIBC_TUNABLES=glibc.malloc.hugetlb=1` (system THP mode is `madvise`; `AnonHugePages`
rose to ~41 MB during the run, so it took effect).

| variant | MLUP/s 4 K → THP | dTLB load misses (1e6) 4 K → THP |
|---|---|---|
| explicit_cse | 2.34 → 2.49 (+7%) | 60.6 → 31.4 |
| scalar_cse | 1.53 → 1.65 (+8%) | 286 → 150 |

### Tiny grids (energy is NaN: the shear-layer setup is unstable at these sizes)

| config | variant | 6³ | 8³ | 12³ |
|---|---|---|---|---|
| GCC f32 | explicit_cse | 1.84 | 4.27 | 3.13 |
| GCC f32 | scalar_cse | 1.70 | 2.07 | 1.89 |
| GCC f64 | explicit_cse | 1.63 | 2.87 | 1.26 |
| GCC f64 | scalar_cse | 1.18 | 1.94 | 1.03 |

At 8³ the f32 explicit run retires ~225 instructions per cell against ~100 at 64³, so the
halo exchange and per-step framework cost dominate there. These numbers are not a clean
compute-bound kernel measurement.

### Generated code, `explicit_cse` f32 `StreamCollide` (source, per 8-cell vector iteration)

| intrinsic | count | note |
|---|---|---|
| `vfdiv_vv` | 10 | the non-CSE variant has 10 as well; one reciprocal of ρ would do |
| `vle32_v` | 70 | for 19 distinct PDFs (non-CSE: 93) |
| `vfmv_v_f` (splat) | 59 | |
| `vfmul_vv` / `vfadd_vv` / `vfsub_vv` | 101 / 82 / 43 | |
| `vse32_v` | 23 | 19 PDFs + ρ + 3 velocity components |

Compile flags of the sweep: `-O3 -DNDEBUG -march=rv64gcv_zvl256b -std=c++20` (no
`-ffast-math`; the JIT and the D2Q9 kernel experiment use `-Ofast`). The compiled object
keeps the divides (20 `vfdiv.vv` over the two vector kernels in the file).

Board facts: X60 at 1.6 GHz, `performance` governor; L1D 32 K 4-way per core, L2 512 K
16-way per 4-core cluster, no L3; 4 K pages, THP `madvise`; ISA string has `zicbom` and
`zicboz` but not `zicbop`; `perf` works with `perf_event_paranoid = -1`; `perf record` in
pipe mode (`-o -`) yields no samples, so profiles need a `perf.data` file.

### Conclusions

- **Throughput does not depend on grid size from 16³ to 64³.** All three sizes exceed the
  512 K L2, so this alone does not exclude memory, but it is not what a DRAM bandwidth
  ceiling plus a cache-resident fast case would look like.
- **One core is far from a bandwidth limit.** The D2Q9 kernel experiment in notes2 moved
  1.6 GB/s on one core (f32, 18 streams, ~71 cycles/cell). This sweep moves ~0.4 GB/s at
  ~685 cycles/cell for about 1.4× the arithmetic.
- **TLB is a minor factor** (+7% with huge pages).
- **IPC 0.13 with only ~15 L1 misses per iteration** means roughly 5500 cycles per 8-cell
  iteration are stalls. Open candidates, not yet separated:
  1. serialised cache-miss latency on the in-order core with 42 concurrent streams
     (19 read + 23 write), if the hardware prefetcher does not follow them;
  2. the 10 vector divides per iteration (X60 divide cost unmeasured);
  3. redundant loads and splats the compiler cannot remove from intrinsics.
- The notes2 statement "limited by memory bandwidth, which no code generator can fix" is
  therefore withdrawn for the single-core case until Phase 1 and 2 attribute the cycles.

**Next action:** Phase 1, `perf record`/`annotate` of `explicit_cse` and `scalar_cse` at
64³ to get the cycle budget per iteration (sweep vs halo; loads vs divides vs the rest).

## Loop 1 (2026-11-13): where do the cycles go? (Phase 1)

**Hypotheses under test:** H1 miss latency, H2 `vfdiv`, H3 redundant loads/splats, H4 framework.

**Experiment A, sampling.** Hardware-event sampling gives no samples on this kernel/perf
(`perf record -e cycles` and `cycles:u`: "no samples"), so profiles use the timer:
`taskset -c 2 perf record -e cpu-clock -F 999 -o p1-<v>-f32.data SweepgenLbmCPU_<v> 64 100 5`
(gcc-f32 build dir, files in `/home/bananapi/saleh/notes3/`).

| symbol | explicit_cse | scalar_cse |
|---|---|---|
| `StreamCollide` | 88.9% | 91.7% |
| halo `GenericStreamPullPackInfo::localCopy` | 5.4% | 4.1% |
| startup (dl, gz, strings, init) | rest | rest |

`perf annotate` of the explicit kernel: the hot loop is **371 instructions per 8 cells**
(GCC merged the 70 source loads into 37 `vle32.v`, plus 23 `vse32.v`, 82 `vfadd`, 82 `vfmul`,
43 `vfsub`, **1 `vfdiv`**, 44 `ld` + 44 `add` address arithmetic, 3 `vl1re32` spill reloads).
73% of the samples sit in the first third of the loop: the 19 PDF loads and the adds that
consume them. About 10% sit on the stores at the end. The FP multiply section, which is
most of the arithmetic, gets about 1% per chunk. The single `vfdiv` gets 0.05%.

**Correction to Loop 0.** The "10 `vfdiv` per iteration" was wrong: 9 of the 10 source
divides are loop-invariant constants (`1/6`, `1/3`, ...) hoisted before the loop. The loop
has one divide (`1/ρ`). H2 is dropped. H3 is minor: GCC already de-duplicates most loads.

**Experiment B, vendor PMU counters.** The X60 exposes a rich vendor PMU (`perf list`:
`l1d_*`, `l2_*`, `eu_lsu_*`, `vidu_*`, `vpu_*`, ...). New script
`misc/x60-lab/pmu_stat.sh` runs 7 event groups of ≤ 6 events (no multiplexing) at 40 steps
and again at 0 steps; `pmu_report.py` subtracts the two, so startup is removed:
`bash pmu_stat.sh pmu-gcc-f32-<v>.tsv 64 40 -- .../SweepgenLbmCPU_<v>`.

| per cell (64³, f32, GCC) | explicit_cse | scalar_cse |
|---|---|---|
| cycles | 682 | 1033 |
| instructions | 61.6 | 337 |
| `stalled_cycle_backend` | **630** | 770 |
| `eu_lsu_load_full` (load queue full) | **420** | 297 |
| `rf_raw_stall` | 324 | 405 |
| `l1d_load_miss` / `l1d_store_miss` | 1.58 / 1.77 | 1.58 / 1.87 |
| `l1d_miss` / `l2_miss` | 3.49 / **2.97** | 3.44 / 2.98 |
| `l1d_prefetch_hit` / `l1d_prefetch_refill` | **0.36** / 0.11 | 0.36 / 0.10 |
| `vector_div_inst` | 0.13 (= 1 per 8 cells) | 0 |
| `dtlb_load_miss` + `dtlb_store_miss` | 7.2 | 42 |

**Conclusions.**
- The framework is not the drag (halo ≈ 5%). H4 dropped.
- 92% of the explicit kernel's cycles are backend stalls, mostly the load queue full.
- Almost every L1 miss is also an L2 miss (2.97 of 3.49 per cell go to DRAM), and the L1
  prefetcher is nearly idle (0.36 hits per cell).
- 682 cycles / 2.97 DRAM lines ≈ **230 cycles per DRAM line**, close to a full latency per
  line: misses are barely overlapped.
- Scalar has the **same** miss profile, so both are latency-bound. Scalar pays more
  instructions on top.
- H1 (miss latency without overlap) explains the budget. Next: find out why the misses do
  not overlap and the prefetcher does not engage.

## Loop 2 (2026-11-13): what can the X60 memory system do? (Phase 2, memory side)

**Probe:** `misc/x60-lab/probes/mem.cpp` (cycles via `perf_event_open`, `probes/pmu.hpp`),
built `g++ -O2 -march=rv64gcv_zvl256b_zicboz`, `taskset -c 2`. Raw outputs in
`/home/bananapi/saleh/notes3/p2-*.txt`.

### Latency and memory-level parallelism (`mem lat K`, random line chase over 128 MB)

| independent chains K | 1 | 2 | 3 | 4 | 6 | 8 | 12 | 16 |
|---|---|---|---|---|---|---|---|---|
| cycles per miss, THP | 357 | 177 | 122 | 96 | 72 | 63 | 62 | 61 |

- DRAM latency is ~357 cycles (224 ns) with huge pages, ~500 with 4 K pages (page walk).
- Independent scalar misses overlap up to **~6 in flight**: the random-access ceiling is
  about 61 cycles per line, 1.7 GB/s per core.
- A first version kept the chain pointers in an array. GCC spilled it to the stack, and the
  dependent store serialised the chains, which faked "no MLP" for K ≥ 4. Fixed with named
  register variables.

### Concurrent unit-stride streams (`mem stream R W`, f32 `vle32`/`vse32` m1, 4 MB per stream, THP, bases staggered by 4160 B)

| streams | cycles per 64-B line | GB/s |
|---|---|---|
| 1 read | 45 | 2.2 |
| 2 / 4 read | 30 / 25 | 3.4 / 4.1 |
| **8 read** | **17** | **6.0** |
| 12 / 16 read | 37 / 35 | 2.8 / 2.9 |
| 19 read | 75 | 1.4 |
| **24 / 32 read** | **364** | **0.28** |
| 1 / 4 / 8 / 23 write | 34 / 46 / 58 / 80 | 3.0 / 2.2 / 1.8 / 1.3 |
| 8 read + 8 write | 37 | 2.8 |
| **19 read + 23 write (the sweep)** | **181–184** | **0.56** |

- The hardware prefetcher handles about 8 read streams well (6 GB/s on one core) and
  degrades past 8. Past ~20 streams it stops entirely: every line costs a full DRAM latency.
- The sweep's 19 read + 23 write streams sit at 181 cycles per line, which is the
  pathology the waLBerla kernel shows (~230).
- Scalar loads collapse at the same point (R = 24: 352 cycles per line), so the cliff is not
  specific to vector loads.
- Page/way-congruent bases (stagger 0) make it much worse: 693 cycles per line on 19 + 23,
  because of L1 set conflicts. waLBerla's component stride (1 184 832 B = 5184 mod 8192)
  is not congruent, so this does not hit the app.

### Remedies on the 19 + 23 pattern

| variant | cycles per line |
|---|---|
| none | 181 |
| THP off | 179 (no effect) |
| touch-ahead `lw` 256–2048 B ahead | 195–211 (worse: the loads fill the load queue) |
| `prefetch.r` (Zicbop encoding `ori x0, rs, 1`) 128 / 512 / 4096 B ahead | **90** / 102 / 109 |
| `prefetch.r` + `prefetch.w` 256 B ahead | **86** |
| `cbo.zero` on destination lines | 162 (alone), 228 with `prefetch.r` |
| `prefetch.r` on 8 read streams only | 24 (worse than the hardware prefetcher's 17) |

- **The X60 executes `prefetch.r`/`prefetch.w` even though `zicbop` is not in the ISA
  string.** The encodings are HINTs (`ori x0, ...`), so this is safe on any RISC-V core.
  GCC emits them for `__builtin_prefetch` with `-march=..._zicbop`.
- `cbo.zero` is not a win on the X60. It makes pure write streams slower (80 → 208 cycles
  per line), which suggests it waits for the line.
- Software prefetch halves the cost of the many-stream pattern but stays far from the
  ~17 cycles per line that the hardware prefetcher reaches with ≤ 8 streams.

**Conclusion.** The ~1.9× ceiling is the X60's stream prefetcher failing on 42 concurrent
streams, combined with only ~6 outstanding misses per core. Two kinds of lever follow:
(a) software prefetch, cheap to emit from the code generator; (b) fewer concurrent
streams (loop fission by direction groups), which lets the hardware prefetcher work.

## Loop 3 (2026-11-13): kernel lab + software prefetch (Phase 3, Phase 4 M3)

**Lab** (`misc/x60-lab/lab/`):
- `gen.py` builds the update rule exactly like sweepgen's `LbmBulk` and emits a kernel TU
  plus a separate wrapper TU (runtime strides).
- `driver.cpp` uses waLBerla's v8 field layout on RISC-V: fzyx, 1 ghost layer, x padded to
  16 B (`hostAlignment()` = `__BIGGEST_ALIGNMENT__` = 16, so 68 floats per row), and a
  16-B aligned interior origin. It runs a periodic ghost fill between steps (untimed) and
  counts cycles/instructions around the kernel calls only.
- `run.sh` builds and runs variants on the board.
- `edits.py` holds the source-level lever edits.
- The generated bodies are **identical** to the ones in the waLBerla build
  (`_gen/SweepgenLbmCPU_{explicit,scalar}_cse`).

**Gate (lab vs waLBerla, 64³, f32, GCC -O3):**

| | lab cycles/cell (kernel only) | waLBerla cycles/cell (kernel + halo) |
|---|---|---|
| explicit_cse | 653 (2.47 MLUP/s) | 682 |
| scalar_cse | 1035 (1.57 MLUP/s) | 1033 |

Passed: the lab reproduces waLBerla within 5%, so lab results transfer.

**Lever M3: software prefetch** (`edits.py` `pf=D`): one `__builtin_prefetch` per distinct
field access of the cell loop, D bytes ahead. Reads get `prefetch.r`, the 23 stores get
`prefetch.w`. The vector loop prefetches every iteration (42 per 8 cells); the scalar loop
every 16th cell. Kernel flags `-O3 -march=rv64gcv_zvl256b_zicbop_zicboz`.

| variant (64³, f32, GCC -O3) | best MLUP/s | cycles/cell | insns/cell |
|---|---|---|---|
| explicit_cse | 2.47 | 653 | 50.5 |
| + pf 64 / 96 B | 4.95 / 4.98 | 326 / 324 | 68 |
| **+ pf 128 B** | **5.19** | **311** | 68 |
| + pf 256 / 512 B | 4.85 / 4.03 | 332 / 399 | 68 |
| + pf 128 B, reads only | 4.91 | 333 | 58 |
| + pf 128 B, THP | 5.25 | 306 | 68 |
| scalar_cse | 1.57 | 1035 | 311 |
| scalar_cse + pf 128 B (every 16 cells) | 1.81 | 887 | 380 |
| explicit_cse without ρ/u stores (invalid kernel, measures 4 fewer write streams) | 3.19 | 559 | 48 |

Checksums: the explicit+pf energy is bit-identical to explicit (3.955785294018e+02). The
scalar+pf energy differs by 1.7e-7 relative (GCC contracts differently around the `if`).

**Conclusion.** Software prefetch alone doubles the explicit kernel (2.47 → 5.19 MLUP/s):
**3.3× the plain scalar baseline**, 2.9× scalar with the same prefetch lever. IPC is still
only 0.22, so the kernel is still memory-stall bound. Next lever: fewer concurrent streams
(direction-split kernel), so the hardware prefetcher can work.

## Loop 4 (2026-11-13): fewer concurrent streams, direction-split kernel (Phase 4 M2)

**Hypothesis.** If no more than about 5 DRAM streams are live at a time, the hardware
prefetchers work, and the kernel gets much closer to its compute floor.

**Experiment.** `misc/x60-lab/lab/hand/f32-hand-split.cpp` is a hand-written RVV kernel with
the same update and outputs as the generated one. It processes blocks of BY rows (full x
extent) of one z-plane in three passes:
1. Moments, in direction groups of GM: accumulate δρ, jx, jy, jz in an L1 scratch.
2. Macroscopic values: ρ, u, u². Writes rho and u.
3. Collide, in direction groups of GC: re-reads the pulled PDFs (L1/L2 hits) and writes
   f_tmp.

Optional software prefetch PF (distance in floats along each stream).

| variant (64³, f32, GCC -O3) | best MLUP/s | cycles/cell | insns/cell |
|---|---|---|---|
| BY=4, GM=GC=5 | 5.93–6.12 | 267–277 | 66 |
| **BY=2, GM=GC=5** | **6.98** (median 6.62) | **237** | 67 |
| BY=2, + PF 32 / 64 / 128 floats | 5.88 / 5.60 / 6.38 | 275 / 288 / 255 | 79 |
| BY=1 / BY=4 / BY=8, + PF | 3.84 / 5.39 / 3.85 | 457 / 300 / 419 | 77 |
| BY=2, PF 64, GM/GC = 7/5, 7/3, 10/5 | 5.62 / 5.13 / 5.67 | 288 / 315 / 285 | 76–82 |

Energy 3.955780103707e+02 vs 3.955785294018e+02 for the generated kernel: 1.3e-6 relative
(f32, different operation order and FMA use). Mass and the weighted PDF sum agree similarly.

PMU (whole process, ghost fill included, so the absolute cycles are higher than the lab line):

| per cell | generated | generated + pf 128 | split BY=2 + PF |
|---|---|---|---|
| cycles | 677 | 365 | 299 |
| `l2_miss` (demand) | 2.95 | 2.45 | **0.70** |
| `l2_load_access` | 4.6 | 6.2 | 15.8 |
| `l1d_prefetch_hit` | 1.0 | 11.4 | 7.2 |
| `eu_lsu_load_full` | 454 | 364 | 162 |
| `rf_raw_stall` | 303 | 124 | 27 |
| `eu_vfpu_full` | 226 | 83 | 178 |

**Conclusions.**
- With few live streams the L2 hardware prefetcher covers DRAM: demand L2 misses drop
  from 2.95 to 0.70 per cell.
- The split kernel (6.98 MLUP/s) beats the generated kernel with software prefetch (5.2).
- Once the streams are few, software prefetch competes with the hardware prefetcher and
  costs instructions, so the split kernel is best without it.
- Blocks must stay small (2 rows): at 8 rows the working set no longer fits L1.
- About 180 cycles per cell are still stalls, mostly L1 misses served by L2 and the vector
  FP queue. This is the next target for in-place streaming (AA) and better ordering.
- Landing it needs a code-generator feature (split update rule, blocked passes with
  scratch arrays). pystencils/lbmpy cannot express that today. Recorded as the main
  follow-up; not landed.

## Loop 5 (2026-11-13): X60 per-instruction costs, the arithmetic ceiling (Phase 2, op side)

`misc/x60-lab/probes/ops.cpp`, `taskset -c 2`, raw output `notes3/p2-ops.txt`. Two probe
bugs on the way:
- Linux discards the vector state (vtype becomes vill) on every syscall, so the counter
  `ioctl` must come before the `vsetvli`, otherwise SIGILL.
- e64 loads at a 4-byte offset raise SIGBUS (element-misaligned).

| cycles per instruction (m1, VLEN 256) | e32 | e64 | scalar |
|---|---|---|---|
| `vfadd`/`vfmul`/`vfmacc`, throughput | 1.0 | 1.0 | 1.0 (s), 1.0/1.3 (d) |
| latency add / mul / fma | 4 / 4 / 5 | 4 / 5 / 6 | 4 (fadd.s) |
| `.vf` forms | 1.0 | 1.0 | |
| `vfdiv` throughput / latency | 38 / 38 | 40 / 12 | 15 (fdiv.s), 24 (fdiv.d) |
| `vfrec7` | 4 | 4 | |
| `vfmv.v.f` (splat) | **4** | 4 | |
| `vle` L1 hit aligned / element-misaligned | 2 / **4** | 2 / 4 | 1.3 (flw) |
| `vse` L1 hit | 2.6 | 2.6 | 1.5 (fsw) |

**Ceilings.**
- The vector FP unit retires one m1 instruction per cycle at e32 and at e64, so the
  arithmetic speedup over scalar is **8× for f32 and 4× for f64**. The plan's target is a
  real hardware ceiling for arithmetic.
- Memory instructions are relatively expensive: an 8-lane load costs 2–4 scalar-load
  slots, not 8 times less. The single divide per 8 cells costs 38 cycles, about 5 cycles
  per cell.
- Splats cost 4 cycles, but GCC hoists all of them out of the generated loop (the compiled
  loop has no `vfmv.v.f`), so splat folding (C3) is not a lever for GCC.
- Compute floor of the generated loop if every access hit L1:
  - 207 FP + 38 div + 37 loads × 2–4 + 23 stores × 2.6 + about 90 scalar instructions
    ≈ 500–580 cycles per 8 cells, i.e. **63–72 cycles/cell** (22–25 MLUP/s).
  - The plain scalar kernel (311 instructions per cell) would need ≥ 311 cycles/cell if it
    were compute-bound.
  - So the compute-bound ratio of this instruction mix is about 4.5–5×. 8× over the
    *measured* scalar baseline (1035 cycles/cell) needs ≤ 129 cycles/cell, about 2× the
    compute floor: reachable only if memory stalls are almost fully hidden.

## Loop 6 (2026-11-13/14): land software prefetch in the stack, end-to-end in waLBerla (Phases 5, 6)

**What was landed (uncommitted):**

pystencils (`submodules/pystencils`, branch `rvv-support`):
- New option `cpu.vectorize.prefetch_distance` (bytes, default `None`) in
  `codegen/config.py`.
- `codegen/driver.py`: if the option is set, `platform.insert_prefetches(...)` runs before
  intrinsic selection.
- `backend/transformations/insert_prefetches.py` (new, `InsertPrefetches`):
  - For every innermost loop with vector memory accesses, it emits one prefetch per distinct
    (pointer, offset) access, right before the first statement that accesses memory.
  - The prefetch is a write prefetch if the address is written in the loop, a read prefetch
    otherwise.
  - Accesses whose offset depends on symbols declared later in the body, and strided
    accesses, are skipped.
- `backend/platforms/generic_cpu.py`: `GenericVectorCpu.insert_prefetches` refuses
  (`MaterializationError`). `backend/platforms/rvv.py`: `RvvCpu.insert_prefetches` emits
  calls to `pystencils::runtime::rvv::prefetch_{read,write}`.
- `include/pystencils_runtime/rvv.hpp`: `prefetch_read`/`prefetch_write`.
  - With `-march=..._zicbop` they use `__builtin_prefetch`.
  - Otherwise they use inline `ori x0, rs, 1|3`, the Zicbop HINT encodings. These are
    no-ops on cores without Zicbop, so no build flag is needed (waLBerla's flags have no
    `zicbop`).
- Tests:
  - `tests/nbackend/test_rvv_codegen.py`: off by default; one hint per distinct access with
    the read/write split and the distance in elements; a read-and-written address gets a
    write prefetch; refused on AVX; plus a cross-compiled `prefetch` kernel in
    `test_generated_code_compiles`.
  - `tests/nbackend/test_rvv_execution.py`: results bit-identical with and without
    prefetch, f32/f64 (board).
- Local run: `tests/nbackend tests/codegen` 421 passed, 11 skipped (hardware tests).
- Board run (`test_rvv_target`, `test_rvv_codegen`, `test_rvv_execution`,
  `test_vectorization`; native compile and execution on the X60): **130 passed** in 10 min
  (`notes3/pytest-rvv.log`).

waLBerla app (`apps/benchmarks/SweepgenLbmCPU`):
- `SweepgenLbmCPU.py --prefetch-distance N` (explicit variant only).
- `CMakeLists.txt` builds `SweepgenLbmCPU_explicit_pf` and `SweepgenLbmCPU_explicit_cse_pf`
  (128 B).
- `scripts/walberla_lbm_bench.sh` builds and runs them by default (`TARGETS` env
  overrides).

Lab check of the backend path (64³, GCC -O3, `misc/x60-lab/lab`, variant `+bpf=128`):

| | f32 MLUP/s (cycles/cell) | f64 MLUP/s (cycles/cell) |
|---|---|---|
| scalar_cse | 1.57 (1035) | 1.09 (1479) |
| explicit_cse | 2.47 (653) | 1.30 (1238) |
| explicit_cse + `prefetch_distance=128`, inline-asm path (`-march=rv64gcv_zvl256b`) | **5.32** (303) | – |
| explicit_cse + `prefetch_distance=128`, builtin path (`_zicbop`) | 5.18 (311) | **2.60** (629) |

**End-to-end, waLBerla `SweepgenLbmCPU`** (`scripts/walberla_lbm_bench.sh 64 200 3` in a
`screen` session, one core (core 2), best of 3; logs `notes3/e2e-gcc-{f32,f64}.log`). The
`_pf` sweep object contains 65 `ori zero,...` hints (42 in StreamCollide, 23 in InitPdfs);
the non-pf object has none.

GCC f32:

| variant | MLUP/s | vs scalar | vs scalar_cse | energy |
|---|---|---|---|---|
| scalar | 1.40 | 1.00× | | 3.775244759310e+02 |
| scalar_cse | 1.59 | 1.14× | 1.00× | 3.775251445040e+02 |
| autovec / autovec_cse | 1.40 / 1.60 | 1.00× / 1.14× | | (= scalar) |
| explicit | 2.36 | 1.69× | | 3.775233720630e+02 |
| explicit_cse | 2.40 | 1.72× | 1.51× | 3.775233908620e+02 |
| explicit_pf | 4.44 | 3.18× | | 3.775233720630e+02 (= explicit) |
| **explicit_cse_pf** | **4.80** | **3.43×** | **3.02×** | 3.775233908620e+02 (= explicit_cse) |

- The landed lever doubles the explicit sweep in the full application, including the halo
  exchange (2.40 → 4.80 MLUP/s), and leaves the checksum bit-identical.
- Fairness note: the prefetch option is RVV-only, so the waLBerla scalar build cannot use
  it. In the lab, the same lever on the scalar kernel gives +15% (1.57 → 1.81). Against a
  prefetching scalar baseline the f32 ratio would be about 4.8 / (1.59 × 1.15) ≈ 2.6×.

GCC f64 (same run settings; all eight variants give the same energy, 3.775155682480e+02):

| variant | MLUP/s | vs scalar | vs scalar_cse |
|---|---|---|---|
| scalar | 0.91 | 1.00× | |
| scalar_cse | 0.97 | 1.06× | 1.00× |
| autovec / autovec_cse | 0.92 / 0.97 | 1.01× / 1.06× | |
| explicit | 1.14 | 1.25× | |
| explicit_cse | 1.17 | 1.28× | 1.21× |
| explicit_pf | 2.08 | 2.28× | |
| **explicit_cse_pf** | **2.32** | **2.54×** | **2.39×** |

- Prefetch doubles f64 just as it doubles f32 (explicit_cse ×1.98 vs ×2.00). The ratio
  over scalar roughly doubles too: 1.28× → 2.54× for f64, versus 1.72× → 3.43× for f32.
  The f64 ratio stays lower because the f64 scalar code is closer to its own memory limit.
- At 2.32 MLUP/s, f64 explicit_cse_pf is 431 ns/cell = 690 cycles/cell. That is close to
  the lab's 629 cycles/cell; the gap is the halo exchange and the communication loop.
- The goal is 4× f64. The landed lever gives 2.5×, i.e. 64% of the arithmetic ceiling.

Clang 18 (same runs, `notes3/e2e-clang-{f32,f64}.log`):

| variant | f32 MLUP/s | f32 vs scalar | f64 MLUP/s | f64 vs scalar |
|---|---|---|---|---|
| scalar | 1.06 | 1.00× | 0.72 | 1.00× |
| scalar_cse | 1.16 | 1.10× | 0.80 | 1.11× |
| explicit | 2.00 | 1.89× | 1.00 | 1.39× |
| explicit_cse | 1.94 | 1.83× | 0.97 | 1.35× |
| explicit_pf | 3.19 | 3.01× | 1.51 | 2.10× |
| **explicit_cse_pf** | **3.56** | **3.36×** | **1.74** | **2.41×** |

- Prefetch doubles Clang's explicit sweep as well (×1.8). Clang trails GCC by 26% in f32 and
  25% in f64 on explicit_cse_pf.
- Clang's ratios are similar to GCC's only because its scalar baseline is also slower
  (1.06 vs 1.40 f32).
- All f64 variants agree on the energy; f32 agrees to rounding.

## Loop 7 (2026-11-14): in-place AA streaming on top of the direction split (Phase 4 M4)

**Hypothesis.** The split kernel still writes a second PDF field. Each store to `f_tmp`
first reads the line (write-allocate), so the sweep moves about 260 B/cell over
19 + 23 streams. With the AA pattern (Bailey et al. 2009; lbmpy calls it `aa`), every PDF
slot is read and rewritten by the same cell in the same step. That needs one field, about
184 B/cell (76 read + 76 written back to lines already in cache + 32 for ρ/u with
write-allocate) and 19 + 4 streams. Expected gain: the remaining L2→L1 traffic drops by
about 30%.

**Experiment.** `misc/x60-lab/lab/hand/f32-hand-aa.cpp`, same passes as the split kernel
(moments in groups of GM, macroscopic values, collide), with two parities:
- even step: read slot i at x, write the post-collision value of i to slot inv(i) at x;
- odd step: read slot inv(i) at x − c_i, write the post-collision value of i to slot i at
  x + c_i.

The collide pass works on opposite-direction pairs, in groups of GP pairs. A pair's two
write targets are its two read sources, so both members are loaded before either is
stored.

The lab driver's `AA=1` mode does three things:
- Initialises the even-step layout.
- Fills ghost slots before odd steps (periodic, from the opposite interior face).
- Folds the ghost-layer writes of odd steps back into the interior.

Under QEMU at N = 16 and 32 the result is bit-identical to the split kernel. Board: 64³,
GCC -O3, same session as the baselines (`notes3/lab-aa.log`).

| variant (64³, f32) | best MLUP/s (median) | cycles/cell | insns/cell | vs scalar_cse |
|---|---|---|---|---|
| scalar_cse (`-march=rv64gc`) | 1.63 (1.62) | 990 | 311 | 1.00× |
| generated explicit_cse | 2.55 (2.54) | 629 | 50.5 | 1.57× |
| + `prefetch_distance=128` (landed, Loop 6) | 5.17 (5.13) | 311 | 67.9 | 3.17× |
| direction split BY=2 (Loop 4) | 6.96 (6.86) | 233 | 66.6 | 4.27× |
| AA + split, BY=2 GM=5 GP=1 | 8.31 (8.08) | 196 | 65.7 | 5.10× |
| AA + split, BY=2 GM=5 GP=2 | 8.87 (8.72) | 183 | 61.6 | 5.44× |
| AA + split, BY=2 GM=7 GP=2 | 8.98 (8.73) | 182 | 59.7 | 5.51× |
| **AA + split, BY=2 GM=5 GP=3** | **9.11** (8.77) | **180** | 58.6 | **5.59×** |
| AA + split, BY=4 GM=5 GP=2 | 7.55 (7.39) | 215 | 60.2 | 4.63× |

Checksums: energy 3.955780103707e+02, mass 2.621440000558e+05 and wsum 2.336616732401e+03
are bit-identical across all five AA configurations and the split kernel. The generated
kernels give 3.955785294018e+02 (1.3e-6 relative, f32 operation order, as in Loop 4).

**Conclusions.**
- In-place streaming is worth +31% on top of the split (6.96 → 9.11 MLUP/s, 233 → 180
  cycles/cell). Over the generated kernel that waLBerla ran before notes3, it is 3.6×.
- Larger collide groups help (GP 1 → 3: 196 → 180 cycles), because the scalar address
  arithmetic is amortised over more pairs. Two-row blocks are still the sweet spot.
- The kernel moves 184 B in 112 ns per cell, i.e. 1.6 GB/s. That is far below what the
  memory system delivers for a handful of streams (Loop 2: 6 GB/s at 8 streams), so it is
  still latency/issue-bound, not bandwidth-bound.
- f32 at 5.6× over the same-session scalar_cse: 8× needs 13.0 MLUP/s = 123 cycles/cell,
  57 cycles/cell fewer than now. The instruction count, 58.6 per cell = 469 per 8-cell
  vector iteration, puts the issue floor near 60 cycles/cell. The remaining gap is stalls
  (PMU breakdown and f64 queued: `queue_aa64.sh`).

**Addendum: f64 and PMU** (`notes3/lab-aa64.log`, `notes3/pmu-lab-gcc-O3-f32-hand-aa@BY-2_GM-5_GP-3.tsv`).

f64, 64³, GCC -O3, same session:

| variant | best MLUP/s (median) | cycles/cell | vs scalar_cse |
|---|---|---|---|
| scalar_cse | 1.02 (0.97) | 1618 | 1.00× |
| generated explicit_cse | 1.23 (1.19) | 1330 | 1.21× |
| + prefetch 128 B | 2.58 (2.44) | 648 | 2.54× |
| hand AA, BY=2 GM=5 GP=3 | 3.71 (3.62) | 445 | 3.65× |
| **hand AA, BY=1 GM=5 GP=3** | **4.26** (4.19) | **416** | **4.20×** |
| hand AA, BY=1 GM=7 GP=3 | 4.27 (4.16) | 442 | 4.20× |

- In the lab, the f64 hand AA kernel reaches the 4× f64 goal.
- f64 prefers one-row blocks, because an f64 row block needs twice the scratch space of f32.
- Energies are bit-identical across the AA configurations, and identical to the pull kernels
  (3.955776514995e+02).

PMU, f32, per cell (whole process including ghost fill, so the cycles are higher than the lab
line):

| per cell | gen. + pf 128 | split BY=2 + PF | AA BY=2 GP=3 |
|---|---|---|---|
| cycles | 365 | 299 | **223** |
| stalled_cycle_backend | 297 | 227 | 149 |
| `l2_miss` (demand) | 2.45 | 0.70 | **0.22** |
| `l2_load_access` | 6.2 | 15.8 | 7.9 |
| `eu_lsu_load_full` | 364 | 162 | 76 |
| `rf_raw_stall` | 124 | 27 | 36 |
| `eu_vfpu_full` | 83 | 178 | **135** |
| `vidu_vec{0,1}_depend_stall` | 33 / 25 | 56 / 55 | 31 / 29 |
| `dtlb_load_miss` | 9.6 | 0.64 | 0.47 |

- Memory is no longer the limit: demand L2 misses are down to 0.22 per cell, and the
  load-queue-full cycles halved again against the split kernel.
- The largest stall is now the vector FP issue queue (`eu_vfpu_full`), i.e. dependency
  chains in the in-order vector unit. That calls for better instruction scheduling (Loop 8).

## Loop 8 (2026-11-14): next lab cycle: LMUL, compiler scheduling, generated AA (Phase 4)

**Hypotheses** (from Loop 7: 180 cycles/cell, about 3× the issue floor, stall-bound):
1. LMUL=2 (16 f32 lanes per instruction) halves the instruction count and the per-cell
   latency of the dependency chains (moment accumulation; cu → feq → relax per pair) at the
   same register pressure as LMUL=1 with half the registers. LMUL=4 spills.
2. The X60 is in-order, and GCC 14 has no X60 scheduling model (`-mtune=spacemit-x60` is
   unknown). Clang 18 has one (`-mtune=spacemit-x60`), so loads might get hoisted further
   ahead of their uses.
3. lbmpy already implements the AA pattern (`streaming_pattern="aa"`, even/odd kernels). A
   *generated* AA kernel through pystencils RVV plus `prefetch_distance` is the landable form
   of the in-place lever: 23 instead of 42 streams and 30% less traffic, without the
   direction split.

**Preparation (laptop, QEMU):**
- `lab/hand/hand-aa.hpp`: the AA kernel body written once with overloaded RVV intrinsics,
  with macros for element type and `LMUL`. `f32-hand-aa.cpp` and `f64-hand-aa.cpp` are
  two-line includes.
  - At LMUL=1 the f32 object code is identical to the previous kernel.
  - LMUL=2/4 give bit-identical checksums.
  - Spill count (GP=3): none at LMUL=1/2, 60 whole-register spills at LMUL=4.
- `lab/gen.py` pseudo-edit `aa`: lbmpy `streaming_pattern="aa"` with `Timestep.EVEN/ODD`
  produces `kernel_even` + `kernel_odd`, and the wrapper is `run_kernel_aa(..., parity,
  omega)` for the driver's `AA=1` mode.
  - lbmpy's accessors use the same slot convention as the hand kernel (even: slot i at x →
    slot inv(i) at x; odd: slot inv(i) at x − c_i → slot i at x + c_i).
  - Under QEMU, generated f64 AA + prefetch is **bit-identical** to generated f64 pull
    (N = 16 and 32). This validates both lbmpy's AA kernels and the driver's AA ghost
    fill/fold.
  - f32 differs by about 1e-8 relative (FMA contraction).
  - 23 prefetch hints per AA kernel (19 in-place PDF slots + 4 outputs).
- Board job `queue_lab2.sh` (screen `notes3-lab2`, results in `notes3/lab2.log`):
  - generated AA f32/f64 with prefetch distances 0/64/128/256 B, plus same-session baselines;
  - hand AA at LMUL 1/2/4;
  - hand AA with Clang 18, with and without `-mtune=spacemit-x60`.

**Results** (`notes3/lab2.log`, 64³, GCC -O3 unless noted, one session; this session's
baselines came out a little lower than in Loop 7, so ratios are taken within it).

1. lbmpy's AA streaming, generated (pystencils RVV, old selector):

| variant | f32 best (median) | f32 cycles/cell | f64 best (median) | f64 cycles/cell |
|---|---|---|---|---|
| scalar_cse (pull) | 1.47 (1.28) | 1177 | 1.02 (0.97) | 1617 |
| scalar_cse, AA | 2.32 (1.68) | 827 | – | – |
| explicit_cse + pf 128 (pull, landed) | 4.50 (4.47) | 357 | 2.44 (2.29) | 682 |
| explicit_cse, AA, no prefetch | 2.81 (2.40) | 651 | 1.41 (1.20) | 1290 |
| explicit_cse, AA + pf 64 | 7.10 (6.44) | 238 | – | – |
| **explicit_cse, AA + pf 128** | **7.18** (6.50) | **235** | **3.86** (3.31) | **451** |
| explicit_cse, AA + pf 256 | 6.72 (5.99) | 256 | – | – |

- The generated AA kernel with prefetch is **1.60× (f32) and 1.58× (f64) faster** than the
  landed pull + prefetch kernel. Over the same-session scalar_cse that is 4.9× (f32) and 3.8×
  (f64).
- Without prefetch, AA's 23 streams still exceed what the hardware prefetcher handles.
- 128 B stays the right distance.
- Checksums: f64 AA is bit-identical to pull; f32 differs by 4e-9 relative.
- AA also helps the scalar kernel (best 2.32, but its median is 1.68; noisy).

2. LMUL (hand AA, f32 BY=2 GM=5 unless noted):

| LMUL | best MLUP/s (median) | cycles/cell | insns/cell |
|---|---|---|---|
| 1, GP=3 | **10.12** (9.73) | **163** | 58.6 |
| 2, GP=3 | 8.05 (6.89) | 216 | 31.6 |
| 2, GP=2 / GM=7 / BY=4 | 7.74 / 8.11 / 5.47 | 225 / 215 / 296 | 30–33 |
| 4, GP=1 / GP=2 | 7.36 / 7.56 | 226 / 229 | 23–24 |

The f64 kernel behaves the same: LMUL=1 at 3.71 against LMUL=2 at 2.86, or 3.68 with BY=1.
**Hypothesis 1 rejected.** Half the instructions do not help. The X60 executes an m2
operation as two beats, so latency-bound chains get no shorter per cell, and the larger
register groups leave fewer independent chains to interleave.

3. Compiler scheduling (hand AA, f32 LMUL=1 BY=2 GM=5 GP=3):

| compiler | best MLUP/s (median) | cycles/cell | insns/cell |
|---|---|---|---|
| GCC 14 | 10.12 (9.73) | 163 | 58.6 |
| Clang 18 | 9.04 (8.80) | 181 | 54.9 |
| **Clang 18 `-mtune=spacemit-x60`** | **11.17** (10.80) | **147** | 55.1 |
| Clang 18 tuned, LMUL=2 | 8.25 (7.26) | 208 | 28.8 |

**Hypothesis 2 confirmed.** The X60 scheduling model is worth +24% over untuned Clang and +10%
over GCC 14, with the same instruction count; only the order changes. This fits the PMU
finding that the vector FP queue is now the bottleneck. 11.17 MLUP/s is 7.6× the same-session
scalar_cse (noisy) and 6.9–7.1× the stable scalar_cse of Loops 3–7 (1.57–1.63). Whether the
generated kernels and the scalar baseline gain too is tested in `queue_lab4.sh` (Loop 11).

## Loop 9 (2026-11-14): land in-place AA streaming in sweepgen and waLBerla (Phase 5)

**What changed (uncommitted, `submodules/walberla`):**
- sweepgen `prefabs/lbm_bulk.py`: `LbmBulk` accepts `streaming_pattern="aa"`.
  - It builds the even and odd update rules (lbmpy `Timestep.EVEN/ODD`) and generates
    `StreamCollideEven` + `StreamCollideOdd` on one PDF field: no `f_tmp`, no swap.
  - `InitPdfs` then uses the AA even-step read accessor, so each cell writes only its own
    slots.
  - `pull` is unchanged.
- v8 halo exchange (`include/walberla/v8/halo_exchange/fields/`), two new pack infos plus
  factories in `PackInfoSelection.hpp`:
  - `GenericAAPullPackInfo` / `halo_exchange::aaPullSync<Stencil>`, after even steps: the
    inverse slots of what `streamPullSync` sends (the odd step reads slot inv(i) at
    x − c_i).
  - `GenericAAPushPackInfo` / `halo_exchange::aaPushSync<Stencil>`, after odd steps: sends
    the slots that the odd step wrote into the ghost layer (slot i at x + c_i) back to the
    owner's border cells. At the edges of a face slice, some ghost slots were not written by
    the sending block (the writer g − c_i lies outside it). The owner gets those over an
    edge from another neighbor, so `unpack`/`localCopy` skip any slot whose writer is
    outside the sender's interior. Without that check, unpack order would decide whether a
    stale value wins.
  - Slot indices go through `Stencil::idx`/`invDirIdx`.
- App `SweepgenLbmCPU`:
  - `--streaming-pattern {pull,aa}`, and `SWEEPGEN_LBM_AA` in the C++ file: even/odd sweeps,
    `aaPull` after even, `aaPush` after odd.
  - The CMake variant list is now a helper function, with the new targets
    `SweepgenLbmCPU_scalar_cse_aa`, `_explicit_cse_aa` and `_explicit_cse_aa_pf`.
  - `scripts/walberla_lbm_bench.sh`, `walberla_bench_mpi.sh` (new `CONFIGS`, `VARIANTS` and
    `LOGDIR` overrides) and `walberla_bench_summary.py` include them.

**Found and fixed on the way: the pull benchmark's initialization was wrong at block borders.**
- `InitPdfs` (lbmpy `set_pre_collision_pdfs=True`) places the PDF of direction i of cell x in
  slot i of cell x − c_i. Near a block border that is a ghost cell, and these are exactly the
  values the first pull step reads.
- The notes2 app ran `haloExchange()` once before the first step ("the pull stream reads the
  ghost layers"). That overwrote those ghost slots with the neighbor's border slots, which
  nothing had written. Upstream's DoubleShearLayer and the sweepgen scenario tests do not do
  this.
- Symptom: the result depended on the decomposition. After 1 step, the 64³ energy was 382.26
  with one block and 365.71 with 8 blocks of 32³; the correct value is the initial 399.23,
  because the first collision acts on equilibrium.
- Fix: drop that initial exchange (comment in the app). The timed loop is unchanged, so
  performance is too. The checksums of runs made before the fix (Loops 0–7, e2e tables in
  Loop 6) are self-consistent across variants but not physically exact.

**Verification (laptop x86 build in the scratchpad, GCC, f64, MPI; scalar and AVX explicit):**

| processes × block | steps | scalar_cse | scalar_cse_aa | explicit_cse (AVX) | explicit_cse_aa |
|---|---|---|---|---|---|
| 1 × 64³ | 20 | 395.52438346 | 395.52438346 | 395.52438346 | 395.52438346 |
| 8 × 32³ | 20 | 395.52438346 | 395.52438346 | 395.52438346 | 395.52438346 |
| 1 × 64³ | 21 | 395.509094192 | 395.509094192 | 395.509094192 | 395.509094192 |
| 8 × 32³ | 21 | 395.509094192 | 395.509094192 | 395.509094192 | 395.509094192 |
| 2 × 24³ | 101 | 40.4181319145 | 40.4181319145 | 40.4181319145 | 40.4181319145 |
| 6 × 24³ | 101 | 125.207794697 | 125.207794697 | 125.207794697 | 125.207794697 |

Pull and AA agree to all 12 printed digits, for one block (periodic self-exchange via
`localCopy`) and for 2, 6 and 8 processes (`pack`/`unpack`), after even and odd step counts.
x86 timing (not the target, one core, 64³, f64): explicit_cse 83 → explicit_cse_aa 120
MLUP/s (+45%); scalar 45 → 47.

Regression test (new): `tests/sweepgen/LbmScenarios/AAMatchesPull.hpp`.
- `LbmAlgorithms.py` also generates the scenario method (TRT, He force) with
  `streaming_pattern="aa"` as `LBM_AA`.
- The scenario steps pull and AA side by side on a non-uniform periodic flow (sinusoidal u
  along all axes) and asserts ρ and u cell by cell (atol 1e-14, rtol 1e-12) after each of 9
  steps. ctest runs it with 1, 2 and 4 processes.
- Local `ctest -R "LbmScenarios|HaloExchange|CommunicationHiding"`: 24/24 passed (the
  existing scenarios and v8 halo-exchange tests included).
- Mutation check:
  - Dropping the push's writer check fails at 4 processes. It passes at 1 and 2, where the
    unpack order happens to let the correct value win, which is exactly the hazard the check
    removes.
  - Sending direct instead of inverse slots in the AA pull's `pack` fails at 2 and 4.

Board: the changes are staged as `notes3/stage-aa.tgz`. Screen `notes3-e2e-aa` unpacks them
once the Clang/lab jobs that build in the same tree are done, then runs GCC f32/f64 with the
AA targets and 4/8-process runs.

**Board e2e, GCC f32** (`notes3/e2e-aa-gcc-f32.log`, `scripts/walberla_lbm_bench.sh 64 200 3`
on core 2, best of 3).
- Configuration: AA changes plus the pull-init fix, all explicit variants built with the new
  RVV selector (Loop 10, installed after its gates passed).

| variant | MLUP/s | vs scalar | vs scalar_cse | energy |
|---|---|---|---|---|
| scalar | 1.40 | 1.00× | | 3.951706161140e+02 |
| scalar_cse | 1.59 | 1.14× | 1.00× | 3.951713447810e+02 |
| explicit_cse | 2.40 | 1.72× | 1.51× | 3.951691920470e+02 |
| explicit_cse_pf | 4.70 | 3.36× | 2.96× | 3.951691920470e+02 |
| scalar_cse_aa | 2.05 | 1.46× | 1.29× | 3.951713597040e+02 |
| explicit_cse_aa | 3.04 | 2.18× | 1.91× | 3.951691603540e+02 |
| **explicit_cse_aa_pf** | **7.08** | **5.06×** | **4.45×** | 3.951691603540e+02 |

- In-place AA streaming plus prefetch reaches **7.08 MLUP/s, 5.06× waLBerla's scalar build**
  in the full application. That is 1.51× the landed pull + prefetch variant, and 2.95× the
  explicit_cse sweep waLBerla had before notes3.
- AA helps the scalar sweep too (1.59 → 2.05). Against that scalar_cse_aa baseline, the vector
  speedup is 3.45×.
- Checksums:
  - With the initialization fixed, all variants land at 395.17 (formerly 377.5 with the
    corrupted borders).
  - Pull and AA agree to f32 rounding: 8e-8 explicit, 4e-8 scalar, from different operation
    orders.
  - `explicit_cse` and `explicit_cse_pf` are identical, and so are `explicit_cse_aa` and
    `explicit_cse_aa_pf`.
- explicit_cse_pf is 4.70 against 4.80 in Loop 6. The new selector is neutral for pull, as in
  the lab, so this is within run-to-run noise.

**Board e2e, GCC f64** (`notes3/e2e-aa-gcc-f64.log`, same build configuration and protocol):

| variant | MLUP/s | vs scalar | vs scalar_cse | energy |
|---|---|---|---|---|
| scalar | 0.95 | 1.00× | | 3.951592090140e+02 |
| scalar_cse | 1.01 | 1.06× | 1.00× | 3.951592090140e+02 |
| explicit_cse | 1.21 | 1.26× | 1.19× | 3.951592090140e+02 |
| explicit_cse_pf | 2.37 | 2.48× | 2.35× | 3.951592090140e+02 |
| scalar_cse_aa | 1.44 | 1.51× | 1.43× | 3.951592090140e+02 |
| explicit_cse_aa | 1.63 | 1.71× | 1.61× | 3.951592090140e+02 |
| **explicit_cse_aa_pf** | **3.95** | **4.14×** | **3.91×** | 3.951592090140e+02 |

- **f64 reaches 4.14× waLBerla's scalar build in the full application**, which is the plan's
  4× f64 target, with generated code. Before notes3 the best explicit f64 variant was 1.31×.
- All seven variants print the same energy to 13 digits: pull, AA, scalar, RVV, with and
  without prefetch.
- Lab vs application: comparing with the lab's headline "best" figures (8.99 f32, 4.11 f64)
  overstates the gap, because for AA the best step is always an even step, which is the
  cheaper kernel. Against the lab's cycle average (1.6 GHz / cycles per cell: 8.33 f32, 3.82
  f64), the application is 15% behind in f32 and slightly ahead in f64. Pull + pf: 7% (f32)
  and 5% (f64). Followed up in Loop 12.

## Loop 10 (2026-11-14): RVV selector: scalar (.vf) operands and fused multiply-add (Phase 5, pystencils)

**Observation.** Instruction mix of the generated AA kernel's vector loop, per 8 cells (GCC 16 cross,
`-O3`; the board has GCC 14):
- 471 instructions, of which only 280 are vector.
- 82 `vfmul.vv` + 82 `vfadd.vv` + 43 `vfsub.vv`, but **no FMA at all**. The scalar loop of the
  same rule uses 52 `fmadd.s`. GCC contracts scalar code and x86 vector intrinsics
  (vector-extension arithmetic), but RVV intrinsics are opaque builtins.
- **23 vector reloads + 7 spills per iteration**, plus 27 `csrr vlenb` and about 100 scalar
  `add/addi/slli/mul` to address the spill slots.

Cause: 31 rational constants are hoisted as vector declarations (e.g. `1/6` =
`vfdiv(vfmv(1), vfmv(6))`), and each use inside the loop needs one of the 32 vector registers.

**Change (uncommitted, `submodules/pystencils/src/pystencils/backend/platforms/rvv.py`,
`SelectIntrinsicsRvv`):**
- Scalar operands:
  - Every float vector declaration whose value is lane-uniform gets a scalar twin, declared
    right before it. Uniform means a uniform constant, a broadcast, a uniform symbol, or
    + − × ÷ and negation of those.
  - Symbols that are assigned again later, such as reduction accumulators, are excluded via
    a pre-scan.
  - A binary operation with one uniform operand uses the `.vf` form: `vfadd/vfsub/vfmul/
    vfdiv_vf`, or `vfrsub/vfrdiv_vf` when the scalar is on the left.
  - Uniformity is memoized per IR node, so long sum chains stay linear.
- Fused multiply-add:
  - `a*b + c` → `vfmacc`, `a*b − c` → `vfmsac` (also when it arrives as `(−1)*c + a*b`, as
    sympy writes it), `c − a*b` → `vfnmsac`, each in the `vv` or `vf` form.
  - A uniform addend is not fused (it would need a splat).
- Always on, documented in the class docstring. This matches what compilers do by default for
  the scalar and x86 paths.

**Effect on the generated loops** (instructions per 8-cell iteration, GCC 16 cross):

| kernel | before | after | vector before → after | spills/reloads |
|---|---|---|---|---|
| f32 AA + pf, even | 471 | 341 | 280 → 235 | 30 → 0 |
| f32 AA + pf, odd | 556 | 396 | 284 → 236 | 34 → 0 |
| f64 AA + pf, even | 473 | 350 | 280 → 235 | 30 → 0 |
| f32 pull + pf | 458 | 449 | 271 → 239 | 3 → 0 |

- FP operations drop from 207 to about 150 per iteration, 64 of them FMAs.
- GCC adds about 28 `vmv1r.v` copies where all three FMA inputs stay live, which is no worse
  than the mul + add they replace.
- The pull kernel gains less: it had few vector spills, but 56 scalar `ld` for its 42
  pointers remain.

QEMU: f64 checksums unchanged to 13 digits (N = 16, 32). f32 changes by about 1e-8 relative
(single rounding in the FMA).

**Tests:**
- `tests/nbackend/test_rvv_codegen.py`:
  - `test_float_arithmetic` updated.
  - New: `test_scalar_operands_use_vf_forms`, `test_fused_multiply_add` (5 forms),
    `test_scalar_addend_is_not_fused`, `test_hoisted_constants_are_scalar_operands`
    (f32/f64), `test_reassigned_vector_symbol_keeps_its_register` (fails when the
    re-assignment guard is removed).
- `tests/nbackend/test_rvv_execution.py`: `test_vf_forms_and_fma_match_numpy` (board).
- Local: `tests/nbackend tests/codegen` 433 passed, 13 skipped (hardware tests).

**Board pipeline** (`queue_lab3.sh`, screen `notes3-lab3`, after lab2):
- Lab A/B of each kernel with the old and new selector (`+vf2` files from `gen.py`).
- Gate 1: checksums agree (f32 rtol 1e-5, f64 rtol 1e-10).
- The staged pystencils change is unpacked and the RVV pytest files run on the board (gate 2).
- Only if both gates pass does the change stay in the board tree (`notes3/lab3.ok`).
  `notes3-e2e-aa` then builds waLBerla with it and logs which selector it used.

**Board results** (`notes3/lab3.log`, 64³, GCC 14 -O3, one session, old → new selector):

| kernel | MLUP/s | cycles/cell | insns/cell |
|---|---|---|---|
| f32 explicit_cse (pull) | 2.22 → 2.21 | 726 → 732 | 50.6 → 46.2 |
| f32 pull + pf 128 | 4.85 → 4.82 | 334 → 337 | 68.0 → 64.2 |
| f64 pull + pf 128 | 2.44 → **2.59** (+6%) | 685 → 642 | 131.8 → 124.2 |
| f32 AA | 2.83 → 3.10 | 654 → 609 | 61.0 → 42.3 |
| f32 AA + pf 128 | 7.31 → **8.88** (+22%) | 234 → **192** | 70.5 → 51.5 |
| f64 AA + pf 128 | 3.86 → **4.09** (+6%) | 461 → 433 | 138.2 → 100.8 |

- Gate 1 passed: energies within 5e-9 (f32) and identical (f64).
- The selector pays off where the kernel is no longer memory-bound (AA + prefetch). In the
  pull kernels, the extra instructions were hidden behind memory stalls.
- Gate 2 failed on the first try. My new execution test summed all forms into one expression,
  which sympy merged (`7xy − 5z + …`), so the asserted `vfrsub_vf` never appeared; the
  numerics never ran. The pipeline restored the old selector as designed. The test now uses
  one output per form, with an ulp-based tolerance (FMA rounds once, numpy twice).
  `queue_vf2_gate.sh` re-runs gate 2 before the e2e job. Retry: **145 passed** on the
  board (RVV target/codegen/execution and `test_vectorization`), so the new selector stays
  (`notes3/lab3.ok`) and the e2e job builds with it.

## Loop 11 (2026-11-14): X60 scheduling model for generated code and baselines (Phase 4/5)

**Question:** Loop 8 gained 24% on the hand kernel with Clang `-mtune=spacemit-x60`. Do the
generated kernels and the scalar baseline gain too? (`notes3/lab4.log`, 64³, one session, all
kernels with the new selector.)

| kernel | GCC 14 | Clang 18 | Clang 18 `-mtune=spacemit-x60` |
|---|---|---|---|
| f32 scalar_cse (`rv64gc`) | 1.46 | 1.19 | **1.56** |
| f32 pull + pf 128 | 5.12 | 5.55 | 5.45 |
| f32 generated AA + pf 128 | **8.99** | 7.41 | 8.09 |
| f32 hand AA BY=2 GP=3 | 10.13 | 8.83 | **11.10** |
| f64 scalar_cse | 1.03 | 0.97 | 1.07 |
| f64 pull + pf 128 | 2.60 | 2.56 | **2.82** |
| f64 generated AA + pf 128 | **4.11** | 3.34 | 3.94 |
| f64 hand AA BY=1 GP=3 | 4.27 | 3.81 | **4.63** |

- The tuning helps every Clang build (+9 to +31%), including the scalar baseline.
- For the generated f32/f64 AA kernels, GCC 14 stays ahead. The hand kernel profits most
  because its source exposes more independent work per scheduling region.
- Landed (uncommitted), `cmake/compileroptions/{GNU,Clang}.cmake`, RISC-V branch of
  `WALBERLA_OPTIMIZE_FOR_LOCALHOST`: the host core is read from `/proc/cpuinfo` (`uarch :
  spacemit,x60` → `-mtune=spacemit-x60`) and the flag is added if the compiler accepts it
  (`check_cxx_compiler_flag`). Neither compiler derives this from `native`: Clang 18 resolves
  `-mcpu=native` to `generic`. GCC 14 rejects the flag, so GCC builds are unchanged.
- Best generated (landable) kernels so far, GCC 14 with the new selector: f32 AA + pf 8.99
  MLUP/s, 6.2× the same-session scalar_cse (5.5–5.7× the stable 1.57–1.63). **f64 AA + pf
  4.11 MLUP/s = 4.0× scalar_cse: the f64 goal, met in the lab with generated code.**
- Correction (Loop 12): these are best-step figures. For AA the best step is always an even
  step, which is the cheaper kernel. By cycle average (1.6 GHz / cycles per cell), the
  ratios are 8.33 / 1.36 = 6.1× (f32) and 3.82 / 1.00 = 3.8× (f64). The application
  (Loop 9) measures 4.14× for f64 against its scalar build.

## Loop 12 (2026-11-14): lab vs application, AA loop code generation, alignment, multi-core (Phases 4–6)

**1. The lab's headline figure overstates AA kernels.** The lab driver printed the best and
the median step. For AA, even and odd steps run different kernels, and the best step is
always an even step, the cheaper one. Its cycle counter covers all steps, so 1.6 GHz /
cycles per cell is the fair kernel-only rate.

| kernel (lab4, GCC 14) | best step | median | cycle average | application (Loop 9) |
|---|---|---|---|---|
| f32 AA + pf | 8.99 | 7.89 | 8.33 | 7.08 (15% behind) |
| f32 pull + pf | 5.12 | 5.04 | 5.07 | 4.70 (7%) |
| f64 AA + pf | 4.11 | 3.82 | 3.82 | 3.95 (ahead) |
| f64 pull + pf | 2.60 | 2.45 | 2.50 | 2.37 (5%) |
| f32 hand AA, Clang + tune | 11.10 | 10.70 | 10.83 | |

The driver now also prints `mean_mlups` (all timed steps, comparable to the application)
and, for AA, `even_mlups` / `odd_mlups`. `run.sh` gained `RUNONLY=1`, which reruns an
existing binary with another environment.

**2. The AA loop's code: the odd step costs 54 more instructions than the even step.**

The vector loop of the generated f32 AA + pf kernel (GCC 16 cross, `-O3`) has 329
instructions in the even step and 383 in the odd step, with the same 234 vector
instructions. Two code-generation effects are responsible:

- **Stencil offsets.** The odd step writes slot i at x + c_i, so 10 of its 19 PDF addresses
  carry an x offset of ±1 element.
  - GCC builds one pointer register per address but bases these on x itself. It then adds
    ±4 B in every iteration (`addi`), because RVV loads/stores take no immediate offset.
  - For each prefetch it adds 124/132 B, because `prefetch.w` immediates must be multiples
    of 32.
  - The extra addresses live from the load to the store and spill: +24 `addi`, +14 `ld`,
    +10 `sd` per iteration.
- **Constants.** Both steps reload every scalar `.vf` operand from the constant pool in every
  iteration (11–12 `lla` + 13 `flw`). GCC rematerializes the constants instead of keeping
  them in the 32 floating-point registers, which the vector loop leaves idle.

Hand edits in `edits.py` show the effect:
- `rp`: one row base pointer per access, hoisted out of the x loop.
- `opq`: the constants made opaque with an empty `asm`.
- Dropping the ±1 from the prefetch addresses alone saves only 6 instructions.
- `-fno-ivopts` makes both loops much worse (476/531).

**Landed in pystencils (uncommitted):**
- `HoistRowPointers` (new, `backend/transformations/hoist_row_pointers.py`):
  - In every innermost loop, a contiguous vector access `ptr[ctr + rest]` with a
    loop-invariant `rest` becomes `row[ctr]`, with `row = &ptr[rest]` declared before the
    loop. Accesses with the same pointer and `rest` share a row pointer.
  - It runs through a new platform hook, `GenericVectorCpu.prepare_vector_loops`, which is a
    no-op by default. `RvvCpu` applies the pass. The driver calls the hook before software
    prefetches are inserted, so the prefetches reuse the row pointers (`&row[ctr + 32]`).
- RVV selector: scalar twins that are compile-time constants are declared through
  `pystencils::runtime::rvv::in_register(...)`, a new `rvv.hpp` helper that returns its
  argument behind `asm("" : "+f"(x))`.

| vector loop, instructions per iteration (GCC 16) | before | `rp` + `opq` (hand) | pystencils |
|---|---|---|---|
| f32 AA + pf, even | 329 | 305 | 305 |
| f32 AA + pf, odd | 383 | 312 | **305** |
| f64 AA + pf, even / odd | 337 / 383 | 305 / 312 | 305 / 305 |
| f32 pull + pf | 440 | 406 | 406 |

The pull kernel gains less: with 42 streams it keeps some pointer spills.

**Verification:**
- QEMU (`qemu-riscv64 -cpu rv64,v=true,vlen=256`, lab driver, 16³, 4 steps, both AA
  parities): energy, mass and weighted PDF sum are bit-identical between the old and new
  pystencils output for f32/f64 × AA/pull.
- New codegen tests in `tests/nbackend/test_rvv_codegen.py`:
  - `test_stencil_accesses_use_row_pointers`, which fails with the hook disabled.
  - `test_hoisted_constants_are_scalar_operands` now also checks the `in_register` wrapping.
- Local: `tests/nbackend tests/codegen` 435 passed, 13 skipped.
- Clang 18 compiles the helper as well.
- Board (`queue_e2e_cg.sh`): the RVV pytest files with the change, 148 passed.

**4. On the board the instruction savings do not turn into cycles.** Lab A/B
(`queue_lab5.sh`, board GCC 14, 64³, 40 steps, mean of 2 rounds):

| kernel | variant | cycles per cell | insns per cell | mean MLUP/s | even / odd |
|---|---|---|---|---|---|
| f32 AA + pf | landed | 177.2 | 51.5 | 9.01 | 8.69 / 9.35 |
| | + `rp` | 183.7 | 51.6 | 8.68 | 8.67 / 8.70 |
| | + `rp` + `opq` | 177.9 | 49.8 | 8.97 | 9.09 / 8.86 |
| f64 AA + pf | landed | 426.6 | 100.8 | 3.75 | 3.59 / 3.92 |
| | + `rp` | 437.7 | 100.5 | 3.65 | |
| | + `rp` + `opq` | 435.8 | 97.1 | 3.67 | |
| f32 pull + pf | landed | 300.3 | 64.2 | 5.32 | |
| | + `rp` + `opq` | 296.9 | 61.6 | 5.38 | |

- Board GCC 14 has less of the overhead than the local GCC 16 used for the analysis in
  section 2: the edits save 1.7 (f32 AA) to 3.7 (f64 AA) instructions per cell, not 6.
- The saved instructions do not shorten the step: f32 AA −0.4%, f64 AA −2%, f32 pull
  +1.1%, within the noise between rounds (±2% for f64 AA). The kernels wait for memory.
  The in-order core issues about 0.28 instructions per cycle in this loop; removing
  integer instructions leaves the load latency in place.
- `rp` alone slows the odd step by 7% and `opq` speeds up the even step by 5%. I have no
  explanation that I could check. The likely cause is the order of the memory
  instructions, which changes with the register allocation.
- The pystencils version (`HoistRowPointers`, `in_register`) is measured end to end by
  `queue_e2e_cg.sh` (pending). `queue_e2e_halo.sh` reverts it before the next build unless
  that run is at least 2% faster for both f32 and f64 AA + pf.

**5. Field alignment and huge pages: the waLBerla layout is already the best one for the
vector kernels.** Lab (`queue_lab5.sh`), interior origin aligned to ALIGN bytes and rows
padded to ALIGN bytes. waLBerla today: 16 B. Mean MLUP/s of 2 rounds:

| kernel | 16 B (waLBerla) | 32 B | 64 B | 32 B + THP |
|---|---|---|---|---|
| f32 scalar (generic, CSE, pull) | 1.62 | 1.62 | 1.69 | 1.57 |
| f32 pull + pf | 5.16 | 5.25 | **3.67** | **3.93** |
| f32 AA + pf | **8.92** | 8.34 | 6.81 | 7.55 (even 6.1, odd 10.0) |
| f64 scalar (generic, CSE, pull) | 0.885 | 1.01 | **1.185** | 1.02 |
| f64 pull + pf | 2.28 | 2.46 | 2.04 | 2.48 |
| f64 AA + pf | **3.74** | 3.65 | 3.10 | 3.63 |

- For the AA kernels, 16 B (today's layout) is the fastest. 64-byte alignment, which
  sounds right for the cache, costs the vector kernels 17 to 29%.
- The f64 scalar kernel gains 34% from 64-byte alignment, which is the opposite trend. It
  is the only kernel that gains. The landed AA scalar baseline does not use the pull
  kernel, so this does not change the honest baseline, but it shows that the layout
  effects here are large and kernel specific.
- Huge pages (THP) make the f32 AA odd step 7% faster (10.0 MLUP/s, fewer TLB misses as in
  Loop 0) but the even step 30% slower, and the f32 pull kernel 25% slower. With 4 K pages
  the physical addresses of the 19 PDF slices are random beyond bit 12. With 2 MB pages
  they keep the virtual offsets, which points to cache set or DRAM bank conflicts
  between the slices. Loop 13 tests padding between the PDF slices.

**6. Where the AA application loses against the lab: the halo exchange.** `perf record -e
cpu-clock` on the f32 applications (64³, 100 steps, core 2):

| symbol | AA + pf | pull + pf |
|---|---|---|
| sweep kernels | 68.8% (Even 34.2, Odd 34.7) | 80.1% |
| `GenericAAPushPackInfo::localCopy` | 9.9% | |
| `GenericAAPullPackInfo::localCopy` | 7.9% | |
| `GenericStreamPullPackInfo::localCopy` | | 10.1% |
| start-up (initialisation, file I/O) | ~5% | ~2% |

- The halo exchange takes 21% of an AA time step: 17.8 / (68.8 + 17.8). That explains the
  15% between the lab kernel and the application. For pull it takes 11%.
- With one block per process, every direction is a periodic copy of the block onto itself
  (`localCopy`). The copy loops over the 5 slots that cross a face for every cell. On the
  x faces every value then sits on its own cache line, and the AA push variant checks per
  value whether the slot was written. Loop 13 rewrites it.

**7. Multi-core.** 8 processes (both clusters), 64³ per process, 100 steps:

| variant | f32 np4 | f32 np8 | f64 np4 | f64 np8 |
|---|---|---|---|---|
| scalar | 5.42 | 8.07 | 3.44 | 5.15 |
| scalar_cse_aa | 7.39 | 12.69 | 5.17 | 7.52 |
| explicit_cse_pf | 12.49 | 13.88 | 6.42 | 7.06 |
| explicit_cse_aa_pf | 17.99 (3.32×) | 19.68 (2.44×) | 9.51 (2.76×) | 9.88 (1.92×) |

- The vector AA kernel gains only 9% (f32) and 4% (f64) from the second cluster. At 184 B
  (f32) or 368 B (f64) per cell it moves 3.62 / 3.64 GB/s with 8 processes against 3.31 /
  3.50 GB/s with 4. About 3.6 GB/s is the chip's limit for this many-stream pattern,
  shared by both clusters.
- The scalar builds still scale (×1.5 from np4 to np8), because they are not yet at that
  limit. So the vector speedup on the whole chip is 2.44× (f32) and 1.92× (f64) against
  3.32× / 2.76× on one cluster.
- Energy spreads across variants: f32 2.9e-6, f64 0.

## Loop 13 (2026-11-14): halo exchange one PDF slot at a time (Phase 5, waLBerla v8)

**Change** (`include/walberla/v8/halo_exchange/fields/GenericFieldPackInfos.hpp`,
uncommitted): `GenericStreamPullPackInfo`, `GenericAAPullPackInfo` and `GenericAAPushPackInfo`
now move one PDF slot at a time:
- `localCopy`, `pack` and `unpack` loop over the slots outside and over the cells inside (new
  helpers `detail::copySlot`, `packSlot`, `unpackSlot`). With fzyx fields each pass reads
  and writes one slot slice in storage order.
- The MPI buffers hold one contiguous segment per slot instead of one per cell. Sender and
  receiver use the same class, so the layout is internal. `packetSize` is unchanged.
- The AA push exchange skipped slots whose writer g − c_i lies outside the sender, with a
  test per value. Now it computes the cells to copy once per slot, as a box: the interior
  shifted by c_i, cut to the ghost slice (`writtenGhosts`).
- GPU exec tags take the same path, with one kernel launch per slot instead of one per
  direction.

**Verification (local x86 build, GCC 16, MPI):**
- `TestLbmScenarios_CXX`, 12 of 12 passed: FullyPeriodic, AAMatchesPull,
  MirroredHalfChannel and FreeSlipPipe at np = 1, 2, 4. AAMatchesPull compares the AA
  pattern with pull cell by cell over 9 steps, including the exchanges between blocks.
- Mutation: with `writtenGhosts` returning the whole ghost slice (no skip),
  AAMatchesPull fails at np = 4 (the only case with edges between different blocks).
- On the board, the f64 energies must stay bit-identical to the previous runs: the
  exchange only moves values.

**Board job:** `queue_e2e_halo.sh` (after e2e-cg):
- one-core matrices for f32 and f64;
- a perf profile of the f32 AA application;
- the same application with huge pages (`GLIBC_TUNABLES=glibc.malloc.hugetlb=1`) for the
  scalar and vector builds.

No further MPI runs: the K1 is one embedded SoC, and the single-core figures are the result.
The 4/8-process numbers of Loop 12 stay as a measured side note.

It also carries the staged files' mtimes forward. The board's clock runs about 1.7 days
behind the laptop's, so files unpacked from a laptop tarball are "from the future" and Make
would rebuild every dependent target on each later build.

**Padding between the PDF slices** (`queue_lab6.sh`, after e2e-halo): extra bytes between
slices (driver `PADF`) of 0 to 33 024 B, with 4 K pages and with THP. Covers the landed
pull and AA kernels plus two scalar baselines, to test the conflict explanation of
section 5 of Loop 12.

## Loop 14 (2026-11-14): sweep without ρ/u outputs; the direction split generated by pystencils (Phase 4)

**1. Sweep without the macroscopic outputs (plan lever C6).**
- The timed steps of the application need neither ρ nor u: the energy checksum reads u
  once, after the loop. A sweep without the four output stores has 19 instead of 23
  streams and moves 152 instead of 184 B per cell (f32 AA).
- It was measured once in Loop 3, on the pull kernel without prefetch: 559 against about
  629 cycles per cell. It was never measured on the landed kernels.
- `edits.py nomacro` now also removes the outputs' prefetch hints and matches the row
  pointers of Loop 12.
- Variants:
  - `+cg`: generated by today's pystencils. Under QEMU it is bit-identical to the landed
    `+vf2` kernels for f32/f64 × AA/pull.
  - `+cg+nomacro`: the same kernel without the outputs. `wsum` is bit-identical to its
    base, so the PDFs are unchanged.
  - Scalar AA with and without outputs, for the honesty clause.
- `queue_lab7.sh` measures them in one session, 3 rounds.

**2. The direction-split AA kernel, generated** (`lab/gensplit.py`).
- The hand kernel of Loops 4 and 7 is three plain passes per block of BY rows:
  - moments in groups of GM directions, into a scratch;
  - macroscopic values;
  - collision in groups of GP opposite-direction pairs.
- Each pass is now an ordinary pystencils kernel, vectorized for RVV and built from lbmpy:
  - lbmpy's AA accessors give the read and write slots of each parity;
  - its conserved-quantity computation gives δρ, ρ and u;
  - its equilibrium gives the collision. SRT relaxes every direction on its own,
    fᵢ + ω (feqᵢ − fᵢ), and the generator asserts that the method is SRT.
- A generated C++ driver, `run_kernel_aa`, calls the passes block by block. It moves the
  field pointers to the block and sets the sizes to (n0, BY, 1). The scratch arrays are
  passed as fields of the block's shape.
- **lbmpy's D3Q19 SRT equilibrium is not the textbook polynomial.** The generator first
  copied the hand kernel's t = 3cu + 9/2 cu² − 3/2 u², and its symbolic check against
  `method.get_equilibrium_terms()` failed. The rest direction is w₀(δρ − ρu²) instead of
  w₀(δρ − 3/2 ρu²), and face and edge directions differ by multiples of uₐ². Mass and
  momentum are the same.
  - The generator now writes feqᵢ = wᵢ(δρ + ρ tᵢ) with tᵢ from lbmpy, split per opposite
    pair into an even part e = (tᵢ + tⱼ)/2 and an odd part o = (tᵢ − tⱼ)/2. It checks
    every direction symbolically and shares common products through sympy CSE.
  - The hand kernels of Loops 4 and 7 relax towards the textbook equilibrium, so they
    compute a slightly different model. The difference Δᵢ between the two equilibria has
    zero mass, momentum and second moments: it lives only in the non-hydrodynamic
    (ghost) moments of D3Q19.
    - QEMU, f64, 16³ × 20 steps: energy 6.030550062741 (hand) against 6.030550062363
      (generated), 6e-11 relative. The weighted PDF sum, which sees the ghost moments,
      differs by 1.3%.
    - At 64³ the energy difference drops below the 13 printed digits, which is why the
      f64 energies of Loop 7 looked identical.
    - This is not a rounding effect, but it is far below anything the comparisons here
      rely on, and the speed is not affected. The generated split kernel uses lbmpy's
      equilibrium and is identical to the generated kernels.
- QEMU (16³ × 4 steps and 32³ × 10 steps): the f64 split kernels agree with the
  generated AA kernel in all 13 printed digits of energy, mass and weighted PDF sum, for
  every BY/GM/GP. f32 differs by 3.5e-7 relative (summation order).
- Inner loops (GCC 16, f32, BY=2 GM=5 GP=3): 418 instructions per 8 cells for the even
  step over all 8 passes. That compares with 340 for the monolithic generated AA kernel
  and 469 for the hand kernel. The extra work is scratch loads/stores and per-pass loop
  overhead. The split pays only if fewer live streams beat the extra instructions, as
  they did for the hand kernel.
- `queue_lab7.sh` runs a sweep in the same session as the monolithic kernels and the
  hand kernel (GCC; Clang + `-mtune=spacemit-x60`):
  - f32: BY ∈ {1, 2, 4}, GM ∈ {5, 7}, GP ∈ {2, 3, 5}, + prefetch 128 B, + nomacro;
  - f64: BY ∈ {1, 2}, GM ∈ {5, 7}, GP ∈ {2, 3}, + prefetch, + nomacro.

## Phase 6: result (waterfall, ceiling, remaining gap)

waLBerla `SweepgenLbmCPU`, 64³ cells, one core (core 2), GCC 14 `-O3`, best of 3 × 200 steps,
end to end (sweep + halo exchange + timing loop).
- **Plain scalar** = the same application built for `rv64gc` (`SweepgenLbmCPU_scalar`).
- **Best scalar** = the same non-vector levers applied to the scalar build, as the plan's
  honesty clause requires: global CSE and in-place AA streaming (`SweepgenLbmCPU_scalar_cse_aa`).
  Software prefetch is emitted in vector loops only. Its scalar counterpart gave +15% in the
  lab (Loop 3) and is not in the application.

**Waterfall, f32** (session of Loop 9; the notes2 starting point was 1.73×):

| step | lever (loop) | MLUP/s | lever gain | vs plain scalar | vs best scalar |
|---|---|---|---|---|---|
| plain scalar build | | 1.40 | | 1.00× | |
| best scalar (CSE + AA) | | 2.05 | | 1.46× | 1.00× |
| explicit RVV sweep before notes3 | | 2.40 | | 1.72× | 1.17× |
| + software prefetch 128 B | `prefetch_distance` (3, 6) | 4.70 | ×1.96 | 3.36× | 2.29× |
| + in-place AA streaming and `.vf`/FMA selector | sweepgen/v8 halo (9), pystencils (10) | **7.08** | ×1.51 | **5.06×** | **3.45×** |
| + row pointers, constants in registers | pystencils (12) | pending | | | |

- In the lab, the ×1.51 step splits into AA ×1.43 (pull + pf 334 → AA + pf 234 cycles per
  cell, old selector) and selector ×1.22 (234 → 192). In the application, AA loses part of
  this to its overhead outside the sweep (Loop 12, section 1).
- The pull-initialization fix (Loop 9) is a correctness fix and is neutral for performance.
- X60 scheduling model (`-mtune=spacemit-x60`, Loop 11): Clang 18 only, worth +9 to +31% on
  Clang builds. GCC 14 without it still builds the faster generated AA kernel, so the table
  is GCC. The CMake change adds the flag where the compiler supports it.

**Waterfall, f64** (notes2: 1.31×):

| step | MLUP/s | lever gain | vs plain scalar | vs best scalar |
|---|---|---|---|---|
| plain scalar build | 0.95 | | 1.00× | |
| best scalar (CSE + AA) | 1.44 | | 1.51× | 1.00× |
| explicit RVV sweep before notes3 | 1.21 | | 1.26× | 0.84× |
| + software prefetch 128 B | 2.37 | ×1.96 | 2.48× | 1.65× |
| + AA streaming and `.vf`/FMA selector | **3.95** | ×1.67 | **4.14×** | **2.74×** |
| + row pointers, constants in registers | pending | | | |

In the lab: AA ×1.49 (685 → 461 cycles per cell), selector ×1.065 (461 → 433).

**Multi-core** (4 processes = one cluster, 64³ per process, Loop 12): AA + pf reaches 17.99
MLUP/s f32 (3.32× plain scalar) and 9.51 f64 (2.76×). Both move about 3.3–3.5 GB/s, which
is the cluster's limit for this many-stream pattern, so the vector gain shrinks when all
cores share memory.

**Hardware ceiling (Loops 2, 5):**
- Arithmetic: the vector FP unit retires one m1 instruction per cycle at e32 and e64, i.e.
  **8× (f32) / 4× (f64)** over scalar per operation. The plan's goal is that ceiling.
- Compute floor of the landed f32 AA loop: about 300 instructions per 8 cells, about 290
  cycles at the measured load/store costs, i.e. about 36 cycles per cell (44 MLUP/s). The
  loop runs at 192 cycles per cell, so it is still memory-latency bound, not compute bound.
- Memory: about 1.5 GB/s on one core for 23 software-prefetched streams (184 B per cell).
  The X60 streams 6 GB/s only with ≤ 8 streams. The hand-written direction-split AA kernel
  reaches 10.8 MLUP/s (cycle average, Clang + X60 tuning), which is 7.7× the plain scalar
  build's rate: **8× f32 is reachable on this hardware, with a kernel structure that
  pystencils does not generate yet.**

**Achieved vs goal and remaining gap:**
- f64: **4.14× the plain scalar build, the 4× goal.** 2.74× the best scalar sweep, i.e.
  69% of the 4× arithmetic ceiling.
- f32: 5.06× the plain scalar build (goal 8×), 3.45× the best scalar sweep (43% of the 8×
  ceiling). The remaining factor of 1.58 to 8× splits into:
  - Kernel structure: direction split inside the AA kernel. The hand kernel takes 163
    instead of 192 cycles per cell with GCC (×1.17). This needs a loop-fission pass in
    pystencils/lbmpy that splits the moment, collision and store passes by direction groups.
  - Scheduling: ×1.11 more from Clang's X60 model on that kernel.
  - Application overhead around the AA sweep: 15% (halo exchange; profile pending, see Loop
    12).

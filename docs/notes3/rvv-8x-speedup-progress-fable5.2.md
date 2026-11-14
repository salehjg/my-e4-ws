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
| 4 lever experiments | software prefetch 2.1× (Loop 3), direction split 2.8× (Loop 4); AA streaming open |
| 5 land winners in the stack | software prefetch landed (Loop 6): pystencils option + tests, waLBerla `_pf` variants |
| 6 end-to-end verification | see Loop 6 |

Where we stand (waLBerla `SweepgenLbmCPU`, 64³, one core, from notes2): best explicit vs
plain scalar is 1.31× (GCC f64), 1.73× (GCC f32), 1.92× (Clang f32). Goal: 8× f32, 4× f64.

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
- Local run: `tests/nbackend tests/codegen` 421 passed, 11 skipped (hardware tests). Board
  run: see below.

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

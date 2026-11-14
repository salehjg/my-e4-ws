# Plan (Fable 5.2): find what holds RVV at ~1.9× on the K1 and push toward 8×

Running log: [`rvv-8x-speedup-progress-fable5.2.md`](rvv-8x-speedup-progress-fable5.2.md).
Predecessor: [`../notes2/rvv-vls256-only-progress-opus5.5.md`](../notes2/rvv-vls256-only-progress-opus5.5.md).
Nothing gets committed.

## 1. Context

`docs/notes2/` ended with the waLBerla D3Q19 sweep (`apps/benchmarks/SweepgenLbmCPU`) at
1.3× (f64) to 1.9× (f32) over scalar on one X60 core, and concluded that the sweep is
"memory-bandwidth-bound, nothing a code generator can fix". The goal here is the ideal lane
count: **8× for f32** (8 lanes), 4× for f64, same precision, scalar `-march=rv64gc` baseline.

Read-only probes on the board during planning (existing `walberla-build-gcc-f32` binaries,
core 2, `perf stat`) show the old verdict does not hold up:

| observation (f32, GCC, `explicit_cse` unless noted) | value |
|---|---|
| MLUP/s at 16³ / 32³ / 64³ | 2.09 / 2.18 / 2.34 (scalar_cse: 1.35 / 1.42 / 1.53) |
| timed cycles per cell, 64³ | ~685 explicit, ~1045 scalar |
| instructions per cell, IPC | ~100, **0.13** (scalar: ~378, 0.33) |
| L1D load misses per cell | ~1.85 (≈15 per 8-cell vector iteration) |
| THP on (`GLIBC_TUNABLES=glibc.malloc.hugetlb=1`) | dTLB misses halve, only +7% (2.34 → 2.49) |
| tiny grids (8³, 12³) | 4.3 / 3.1 MLUP/s, but 225 insns/cell: halo/framework dominates there |
| vector loop body, per 8 cells (generated source) | **10 `vfdiv`**, **70 `vle32` for 19 PDFs**, 59 splats, 226 mul/add/sub, 23 stores |
| stream count | 19 read + 23 write = 42 concurrent streams (fzyx), 4 K pages, L1D 32K 4-way, L2 512K shared, no L3 |
| compile flags | waLBerla `-O3` (no `-ffast-math`); the JIT experiments used `-Ofast` |

For reference, the D2Q9 kernel experiment (`misc/rvv-vs-autovec`) ran f32 at ~71 cycles/cell
from DRAM with 18 streams, moving 1.6 GB/s on one core. The D3Q19 sweep moves 0.4 GB/s and
costs ~10× the cycles per cell for ~1.4× the arithmetic. So one core is **not** at a
bandwidth limit; ~5500 cycles per vector iteration are being lost somewhere specific.

Ranked hypotheses (all unproven, each has a discriminating experiment below):

1. **Cache-miss latency without overlap.** The in-order X60 serialises misses; if the
   hardware prefetcher cannot follow 42 streams, each missed line costs a full DRAM round
   trip. ~15 misses × ~300 cycles would explain most of the budget, and also the old
   "same bytes/s in f32 and f64" signature.
2. **Vector divides.** 10 `vfdiv` per iteration where 1 reciprocal suffices. X60 divide cost
   is unmeasured.
3. **Redundant work the compiler cannot remove from opaque intrinsics**: 70 loads for 19
   values, 59 splats occupying vector registers, `-1.0*x` multiplies.
4. **Framework overhead** (halo exchange, `sweep::sync`, field allocation/alignment):
   small at 64³ by a surface/volume estimate (~10%), to be confirmed by profile.
5. **TLB**: measured, minor (+7%).

Honesty clause: the 8× is a goal, not a promise. Phase 2 measures the X60's own arithmetic
ceiling (vector vs scalar per-op throughput). If the hardware ceiling is below 8×, the log
states the measured ceiling and reports achieved/ceiling. Results are always reported as
both ratio and absolute MLUP/s, and every lever that is not vector-specific (CSE, layout,
hugepages) is also applied to the scalar baseline so the ratio is not inflated.

## 2. Working method

Every step is one loop, logged in the progress file as one entry:
**hypothesis → experiment → measurement (raw numbers + command) → conclusion → next action.**

Measurement protocol (fixed for the whole plan):

- Board `ssh bananapi`, shared machine: only `/home/bananapi/saleh/`; outputs under
  `/home/bananapi/saleh/notes3/`; check `uptime`/`ps` before each timing batch.
- Pin to core 2 (`taskset -c 2`), best of 3, record spread. Rerun if spread > 3%.
- Always collect `perf stat -e cycles,instructions,L1-dcache-load-misses,dTLB-load-misses`
  and derive cycles/cell, insns/cell, IPC, misses/cell.
- Correctness gate on every variant: checksum (kinetic energy / `sum_f`) equals the
  reference to f64 12 digits, f32 < 1e-5 relative. Use 64³ (smaller grids go NaN in this
  shear-layer setup; pick a stable setup for small-grid runs).
- Sync with `push.to.sh` / `run.on.bananapi.sh` (`NO_PUSH=1` to skip); never two board
  jobs at once; long jobs in `screen`.

## 3. Phases

### Phase 0: set up (short)

- Create `docs/notes3/` plan + progress log; seed the log with the table above.
- New folder `misc/x60-lab/` for probes and the kernel lab (out of tree, like
  `misc/rvv-vs-autovec/`); reuse its `bench.cpp` (`perf_event_open` counters), `hotloop.py`,
  `report.py`, `run.sh` patterns.

### Phase 1: attribute the cycles in the existing binary (observe)

- `perf record` + `perf report/annotate` on `SweepgenLbmCPU_{explicit_cse,scalar_cse}` f32
  and f64, 64³ (perf.data in our board dir; pipe mode does not work on this perf).
- Deliverable: a cycle budget per 8-cell iteration: sweep vs halo exchange vs rest, and
  inside the sweep the cycles on loads (misses), `vfdiv`, other FP, stores, spills.
- Gate G1: ≥ 90% of cycles attributed. This orders everything in Phase 4.

### Phase 2: characterise the X60 (the ceiling ladder)

Small standalone probes in `misc/x60-lab/probes/`, each printing cycles per op/line:

- **Op costs**: latency and throughput of `vfadd/vfmul/vfmacc/vfdiv/vfsqrt/vfrec7`, `.vf`
  forms, `vfmv.v.f`, `vle/vse`, strided `vlse`, `vlseg`, at f32/f64 m1 (and m2), against
  scalar `fadd/fmul/fmadd/fdiv`. Gives the arithmetic-only vector speedup per op class,
  i.e. the hard ceiling for a compute-bound kernel.
- **Stream sweep**: K = 1…64 concurrent unit-stride read / write / read+write streams over
  DRAM-sized arrays; cycles per cache line vs K; 4 K pages vs THP (`madvise`); staggered vs
  page-congruent base addresses (L1D is 4-way). Gives prefetcher capacity and miss cost.
- **Memory levers**: `prefetch.r/w` (Zicbop is not in the ISA string: check whether it is a
  no-op), `cbo.zero` on the destination (Zicboz is present) to avoid write-allocate,
  touch-ahead loads.

### Phase 3: D3Q19 kernel lab (fast iteration vehicle)

- Extend the `misc/rvv-vs-autovec` approach to the exact waLBerla sweep: dump the lbmpy
  D3Q19 SRT `StreamCollide` kernel (same `LBMConfig`/`LBMOptimisation` as
  `SweepgenLbmCPU.py`) as standalone C++, wrapper in a separate TU (runtime strides), 3-D
  driver with waLBerla's fzyx layout, ghost layers and allocation alignment, periodic fill
  outside the timed kernel. Build scalar / explicit × GCC / Clang × f32 / f64, with
  waLBerla's flags (`-O3`) and the JIT's (`-Ofast`).
- Gate: the lab reproduces waLBerla's cycles/cell within ~10%. If it is much faster, the
  difference is the framework layer and gets its own investigation (allocator alignment,
  halo exchange cost, `-O3` vs `-Ofast`) before anything else.

### Phase 4: lever experiments (try → measure → keep or drop)

Run on the lab kernel, in the order the Phase 1 budget dictates. Each lever is first a hand
edit or generator option, measured alone and stacked.

Compute side:

- C1: one reciprocal instead of 10 divides (rewrite the update rule so `1/ρ` is a single
  subexpression before codegen).
- C2: load each PDF once (CSE over field reads; 70 → 19 loads).
- C3: splat folding to `.vf` forms (59 splats; notes2 measured +2–25% on D2Q9).
- C4: negation folding / FMA, retested on D3Q19.
- C5: flags and compiler: `-O3` vs `-Ofast`, GCC vs Clang (+`-mtune=spacemit-x60`), m2 for f64.
- C6: optional sweep without the ρ/u output writes (4 of 23 store streams).

Memory side:

- M1: THP for field allocations (`madvise(MADV_HUGEPAGE)`; system THP mode is `madvise`).
- M2: fewer concurrent streams: (a) line-buffer fission, copying input lines into an
  L1-resident scratch in passes of ≤ K streams (K from Phase 2), then collide from the
  scratch; (b) zyxf/AoS layout with strided or segment loads, if Phase 2 shows they are cheap.
- M3: software prefetch and/or `cbo.zero` on `f_tmp`, if Phase 2 shows they work.
- M4: in-place streaming (lbmpy AA / esoteric twist) to halve streams and traffic.
- M5: x-y blocking so three z-planes of the active block stay in L2.

Gate G2: lab kernel ≥ 4× over scalar (f32), then continue toward 8× or the measured ceiling.

### Phase 5: land the winners in the stack

Only levers that survived Phase 4, each in the layer where it belongs (all uncommitted, on
`rvv-support`):

- pystencils: `src/pystencils/backend/platforms/rvv.py` (e.g. `.vf` folding, negation),
  `include/pystencils_runtime/rvv.hpp`; tests in `tests/nbackend/test_rvv_*.py`.
- generator level: `SweepgenLbmCPU.py` (division/load CSE, layout, streaming pattern) and
  `python/learn-lb-pystencil/lb-pystencils.py`.
- waLBerla: field allocation (THP), app, flags (`cmake/compileroptions/GNU.cmake`).

### Phase 6: end-to-end verification

- `scripts/walberla_lbm_bench.sh` / `walberla_bench_all.sh` / `walberla_bench_mpi.sh`:
  GCC/Clang × f32/f64, 1 core, then 4 and 8 processes.
- pystencils RVV tests locally (`.venv-rvv`, cross-compile) and on the board
  (`test.on.bananapi.sh tests/nbackend/test_rvv_*.py tests/nbackend/test_vectorization.py`).
- Final log section: a waterfall table from 1.9× to the final number, one row per lever
  with its measured gain, plus the measured hardware ceiling and the remaining gap.

## 4. Deliverables

- `docs/notes3/rvv-8x-speedup-plan-fable5.2.md` (this plan) and
  `docs/notes3/rvv-8x-speedup-progress-fable5.2.md` (loop-by-loop log with raw numbers).
- `misc/x60-lab/` (probes, D3Q19 kernel lab, README with results).
- Backend/generator/waLBerla changes from Phase 5, uncommitted.
- Memory note updated to point at notes3.

## 5. Verification

- Each lever: checksum gate + perf counters, before/after, on the board.
- Lab vs waLBerla agreement (Phase 3 gate) so lab results transfer.
- End state: Phase 6 matrix, all RVV tests green, checksums equal across variants.

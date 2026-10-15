# Plan: get RVV-1.0 faster than scalar on the SpacemiT K1

Companion to:
- [`rvv-implementation-plan-fable.md`](rvv-implementation-plan-fable.md) — the backend plan (VLS + VLA)
- [`rvv-implementation-plan-fable-progress.md`](rvv-implementation-plan-fable-progress.md) — the implementation log (current perf numbers live here)
- [`rvv-isa-primer.md`](rvv-isa-primer.md) — RVV terminology (SEW/LMUL/VLEN/`vl`)

## Context

The RVV backend is correct in both VLS and VLA modes, but on the SpacemiT K1 it is
**~0.4–0.5× scalar** for the D2Q9 LBM (full step: generic 3.17 vs rvv 1.96 MLUP/s;
isolated collide: scalar 8.49 vs best-RVV/m2 4.22). The progress log concluded this is a
hardware/kernel-structure limit — but that conclusion was reached **without exercising the
levers the plan itself specifies**, and without ever measuring the actual bottleneck.
Concretely, four things were never tried:

1. **`-mrvv-vector-bits=zvl` was never on in any fixed-mode benchmark.** It is only applied
   when the JIT's `CompilerInfo` has `rvv_fixed_length=True` + `rvv_vlen` set
   (`jit/cpu/compiler_info.py:201-208`). But `.compile()` uses the default
   `CompilerInfo(target=CurrentCPU, rvv_fixed_length=False)` and *nothing wires the
   kernel's RVV config into it* (verified: no assignment of `rvv_fixed_length`/`rvv_vlen`
   anywhere except `scripts/rvv_vlen_sweep.py`, which is the VLA sweep and correctly omits
   it). So every VLS number was compiled with GCC treating the vectors as *scalable* — the
   plan's headline VLS optimization (§2.1, D12, §8) was silently off.
2. **Clang was never tried.** `CompilerInfo.get_default()` returns GCC first
   (`compiler_info.py:113,133-136`); Clang 18.1.8 is on the board. RVV register allocation
   and scheduling differ substantially between GCC 14 and Clang 18.
3. **No hardware-counter diagnosis.** Only MLUP/s and objdump op-histograms exist. We do
   not know whether the bottleneck is stack spills, `vsetvl`, raw vector-unit throughput,
   latency stalls, or memory bandwidth. The K1 has `sscofpmf` counters + `perf`.
4. **f32 was never benchmarked** — everything is f64.

**Goal:** a measurement-first path to RVV ≥ scalar. Per the clarifying answers: the
benchmark of record is the **full D2Q9 step** (collide + stream + boundary), and we study
**both f64 (overhead reduction) and f32 (raw width) as separate tracks**.

## Hardware reality (sets honest expectations; confirm in Phase 0)

The X60 is an 8× in-order core with VLEN=256 but a **128-bit-wide vector datapath**
(widely reported; an LMUL=1 e64 op issues over ~2 cycles). Consequences to expect:

- **f64 compute-bound work has a ~2× ceiling** over scalar *before* any overhead. Current
  0.5× means overhead is eating ~4× of headroom. Removing all overhead plausibly reaches
  ~1×; **beating f64 scalar on the register-heavy collide-alone is unlikely** even done
  perfectly. This is why collide-alone is the worst case.
- **The wins live elsewhere:** (a) the **memory-bound stream** kernels, where vector width
  serves bandwidth directly; (b) **f32**, which doubles lanes (8 @ LMUL=1), halves register
  pressure/spills, and halves bandwidth. These are the realistic "beat scalar" regimes.
- Spills to memory and `vtype` toggles are disproportionately costly on an in-order core.

Phase 0 confirms the datapath width empirically so later phases aren't chasing an
impossible target.

## Phase 0 — Diagnose the bottleneck (GATING; do before any fix)

Nothing downstream is worth doing until we know what we're fighting. All on the board;
edits stay under `/home/bananapi/saleh/`; no concurrent pushes/jobs.

- **Instrument the harnesses** (x86 dev, run on board):
  - `python/learn-lb-pystencil/lb-pystencils.py`: add `--dtype {f64,f32}` (parametrize the
    field/constant dtype, currently hard-coded f64 at lines 95/225-227/314-316),
    `--compiler {gcc,clang}`, `--vector-bits/--no-vector-bits`, `--unroll`. Wire a custom
    `CompilerInfo` into the kernel's JIT (`GccInfo`/`ClangInfo(target=Target.RISCV_RVV,
    rvv_vlen=…, rvv_fixed_length=(mode=="fixed"))`) so the flags actually reach the compiler.
  - New `scripts/rvv_perf_probe.py`: builds collide + full-step for a config matrix and runs
    each under `perf stat` capturing `cycles,instructions` and, if the PMU exposes them,
    `L1-dcache-load-misses` + stall events; also disassembles the JIT-cached `.so` and counts
    **real stack spills** (`ld`/`sd`/`fld`/`fsd` and `vl*r.v`/`vs*r.v` whole-register
    spill ops), not just `vmv1r.v`.
  - New `scripts/rvv_roofline.py`: a tiny `vfmacc`-only streaming micro-kernel (and a scalar
    twin) to measure the K1's *achievable* vector vs scalar FLOP rate → confirms the ~2×
    f64 ceiling / 128-bit datapath and gives f32 the same treatment.
- **Decision gate — classify and record** the dominant cost as one of: {stack spills,
  `vsetvl`/vtype, vector-unit throughput ceiling, latency stalls (low ILP), memory
  bandwidth}. Every later phase is prioritized by this classification. Record in the
  progress log.

## Phase 1 — Zero-cost flag/compiler levers (cheap, plan-specified, do first)

Re-benchmark the full step + collide under each, isolating one variable at a time:

- **1a. Turn on `-mrvv-vector-bits=zvl` for VLS.** First just in the harness via an explicit
  `GccInfo(target=RISCV_RVV, rvv_vlen=256, rvv_fixed_length=True)`. This is the single most
  likely quick win because it was specified but never active. If decisive, promote it to the
  backend (see "backend change" below) so JIT/walberla users get it by default.
- **1b. Clang vs GCC bake-off** — `ClangInfo(...)` with the same flags; also try Clang's
  `-mcpu=spacemit-x60` (verified accepted per plan §7.1). Keep the winner per kernel.
- **1c. Scheduling/unrolling** — `-funroll-loops` (exposes ILP to hide in-order vector
  latency), and verify `vsetvli` is hoisted/immediate (`vsetivli`) in VLS. Trade-off with
  spills; guided by Phase 0.
- **1d. Re-run the LMUL sweep (m1 vs m2)** under 1a+1b. The earlier sweep (m1 3.37, m2 4.22)
  was *without* vector-bits, so its conclusion may change.

Expected: 1a+1b close much of the f64 gap (toward ~1×) but likely do not clear scalar on
collide-alone. That's the ceiling, not a bug — which is why Phases 2–3 exist.

## Phase 2 — f32 / mixed precision (separate track; the likely real win)

- Run the full matrix {f64, f32} × {scalar, rvv-VLS, rvv-VLA} × {gcc, clang}, using the best
  flags from Phase 1. At VLEN=256, f32 → 8 lanes at LMUL=1 (half the register groups of f64,
  half the bandwidth, twice the elements/op).
- Report **f32-RVV vs f32-scalar** *and* **f32-RVV vs f64-scalar** (the "is it worth dropping
  precision" question). Note accuracy: full-step rel_l2 vs the NumPy reference at f32.
- Optionally a mixed path (f32 compute / f64 storage) only if f32-throughout shows a clear
  win worth the extra complexity.

Expected: f32 is the most plausible route to genuinely beat f64 scalar, especially combined
with Phase 3a/3b.

## Phase 3 — Regime & kernel levers (prioritized by the Phase 0 classification)

- **3a. Isolate the stream kernel MLUP/s.** The full-step number mixes compute-bound collide
  with memory-bound stream and a target-independent NumPy bounce-back. Benchmark the stream
  kernels alone (RVV vs scalar) — this is where wide vector loads/stores should already win;
  quantify it.
- **3b. Fuse collide+stream** into one kernel (pystencils can express the fused update) to
  cut PDF memory traffic and reuse loaded values — the classic LBM bandwidth win; strongest
  if Phase 0 says memory-bound.
- **3c. `vfrec7_v` fast reciprocal for `1/rho`** behind an `RvvOptions` accuracy switch (plan
  §6): 7-bit estimate + 2–3 Newton steps. Removes the one `vfdiv` per cell. Small but real;
  measure accuracy impact on rel_l2.
- **3d. Split the monolithic collide** into smaller kernels to shrink live ranges — *only if*
  Phase 0 shows stack spills dominate. This is an LBM-app change (`lb-pystencils.py`), not a
  backend change.
- **3e. Grid size & thread scaling.** Re-measure at larger grids (the 100×100 case may
  dilute results with loop/setup overhead) and with OpenMP across the 8× X60 (check `lscpu`
  cluster topology before trusting parallel numbers).

## Optional backend change (only if Phase 1a proves decisive)

Auto-derive the JIT `CompilerInfo` from the kernel's RVV config so VLS kernels get
`-mrvv-vector-bits=zvl` by default (and VLA kernels correctly do not). Smallest footprint:
in `codegen/driver.py`/`jit/cpu/cpujit.py`, when the codegen target is `RISCV_RVV` and no
explicit `compiler_info` is supplied, construct one with
`target=RISCV_RVV, rvv_vlen=cpu.rvv.vlen, rvv_fixed_length=(mode==FIXED)`. Also propagate to
walberla (`GNU.cmake`/`Clang.cmake` already have the flag per progress log). Keep it behind
"measure first" — do it in the harness (Phase 1a) before touching the backend.

## Phase 4 — Conclude honestly

Stop when either (a) RVV ≥ scalar is achieved for a defined regime, or (b) the roofline +
counters prove the K1 vector unit cannot beat scalar for that regime. Expected landing:
**f32 and/or the memory-bound stream/fused step beat scalar; f64 compute-bound collide-alone
does not** — and that is a correct hardware characterization, not a backend defect. Update
[`rvv-implementation-plan-fable-progress.md`](rvv-implementation-plan-fable-progress.md)
with the full measurement matrix, the confirmed datapath width, and corrected §6 LMUL/
precision guidance.

## Files

- `python/learn-lb-pystencil/lb-pystencils.py` — `--dtype/--compiler/--vector-bits/--unroll`
  knobs; parametrize field dtype; wire custom `CompilerInfo` into the JIT.
- `scripts/rvv_perf_probe.py` (new) — `perf stat` + real-spill-count harness over the config
  matrix.
- `scripts/rvv_roofline.py` (new) — vector-vs-scalar FLOP-rate micro-kernel (datapath/ceiling).
- `scripts/lbm_rvv_check.py` — extend for f32 correctness tolerance; keep as the correctness gate.
- (conditional) `submodules/pystencils/src/pystencils/codegen/driver.py` or
  `jit/cpu/cpujit.py` — auto-wire RVV `CompilerInfo`; `backend/platforms/rvv.py` —
  `vfrec7` reciprocal path (3c).
- `docs/notes/rvv-implementation-plan-fable-progress.md` — record the matrix + ceilings.

## Verification

- **Correctness (must hold throughout):** `scripts/lbm_rvv_check.py` collide max_abs_err
  ≤ ~2e-15 (f64) / relaxed tol (f32); full-step rel_l2 matches the NumPy reference; the VLA
  VLEN sweep stays bit-identical across {128,256,512,1024}.
- **Performance:** MLUP/s matrix (full step + collide + stream) across {f64,f32} ×
  {scalar, VLS, VLA} × {gcc, clang} × {vector-bits on/off}; `perf stat` cycles/instructions/
  IPC deltas; objdump spill-count deltas before/after each lever. Board only — QEMU numbers
  are not performance data.
- **Constraint:** all board work under `/home/bananapi/saleh/`; no concurrent push/jobs.

# Progress log: RVV VLS-256 (Opus 5.5)

Working log for [`rvv-vls256-only-plan-opus5.5.md`](rvv-vls256-only-plan-opus5.5.md).
Nothing is committed: all changes are uncommitted worktree changes on the `rvv-support`
branches of `submodules/pystencils` and `submodules/walberla`, plus repo-root scripts.

## How to work with it

```bash
# local (x86) codegen + cross-compile tests
cd submodules/pystencils
PYTHONPATH=src ../../.venv-rvv/bin/python -m pytest -o addopts='' tests/nbackend/test_rvv_*.py

# board (SpacemiT K1): sync + run pytest natively
bash test.on.bananapi.sh -q tests/nbackend/test_rvv_codegen.py
NO_PUSH=1 bash test.on.bananapi.sh ...           # skip the sync
bash run.on.bananapi.sh python scripts/lbm_rvv_check.py   # any command in the repo root
```

`push.to.sh` now uses `rsync --delete --delete-excluded` (no `.git`, `.venv-rvv`, caches).
A push takes about 2 s instead of the old 333 MB zip, and the remote copy is 54 MB. The
stale `/home/bananapi/saleh/my-e4-ws.zip` was deleted on the board, leaving 3.7 GB free.

## Step 1: strip (done)

Restored to upstream `20d7dcf0` (worktree only):

- `backend/functions.py` (`PsVecStripmineLanes`)
- `backend/kernelcreation/typification.py`
- `backend/platforms/generic_cpu.py`
- `backend/transformations/axis_expansion.py` (`stripmine`)
- `codegen/cpu_loop_strategies.py` (VLA branch)
- `codegen/config.py` (`VectorizationMode`, `RvvOptions`)
- `codegen/__init__.py`
- `tests/fixtures.py`
- `tests/kernelcreation/test_rng.py`
- `jit/cpu/compiler_info.py`, restored first and then re-edited

Hand-simplified:

- `target.py`: `RISCV_RVV` gets AVX-like default lanes (`256 // bits`). Detection is one
  helper, `_riscv_has_rvv(cpuinfo=None)`.
- `driver.py`: `RvvCpu(ctx)`.
- `compiler_info.py`: `RISCV_RVV → -march=rv64gcv_zvl256b`. `CurrentCPU` on riscv64 →
  the same flag if V is present, else `-march=rv64gc`.

## Steps 2–4: backend, runtime header, tests (done)

- `backend/platforms/rvv.py` was rewritten in about 490 lines with comments, modeled on
  `x86.py`. The old version was 1101 lines.
- `include/pystencils_runtime/rvv.hpp` provides:
  - the `#error` VLEN guard,
  - the `set_<sfx>` and `horizontal_<op>_<sfx>` helpers,
  - the Philox f32/f64 wrappers (RVV tuple types).
- Diff vs upstream for source files: about 760 lines. The old branch had about 2.6k.

Generated code (examples, x86 host):

| Feature | Emitted code |
|---|---|
| f64 arithmetic | `__riscv_vfadd_vv_f64m1(…, 4uLL)` |
| Constants | `__riscv_vfmv_v_f_f64m1(0.5, 4uLL)` |
| Inner counter | `pystencils::runtime::rvv::set_i64m1(0LL, 1LL, 2LL, 3LL)` |
| Casts | `vfwcvt_f_f_v_f64m1(vle32_v_f32mf2(…))`, `vfncvt_rtz_x_f_w_i32mf2` |
| Strided access | `vlse64`/`vsse64` with `8LL * _stride_s_1` |
| Reductions | `horizontal_add_f32m1(w_local, w_local__1)` after the loop |

Local results (x86, `.venv-rvv`):

- `test_rvv_target.py` + `test_rvv_codegen.py` + `test_rvv_execution.py`: **77 passed,
  7 skipped**. The skipped tests are the board-only execution tests.
  `test_generated_code_compiles` compiles all 8 kernel shapes with the riscv64 GCC 16
  cross compiler. The runtime header also compiles with Clang 23 when it is given the
  sysroot (`--target=riscv64-linux-gnu --sysroot=/usr/riscv64-linux-gnu`).
- Regression run (`tests/nbackend`, `test_quicktests`, `test_type_cast`, `test_reduction`,
  `test_functions`, `tests/jit`): **636 passed, 250 skipped, 2 xfailed, 0 failed**.
- flake8: clean. The only finding is a pre-existing F821 in `test_functions.py`.
- mypy on `rvv.py`, `compiler_info.py`, `target.py`: clean.

Board results (K1, native GCC 14.2):

- `test_rvv_target.py` + `test_rvv_codegen.py` + `test_rvv_execution.py`: **84 passed**.
  This covers:
  - Philox RVV == GenericCPU, bit-exact for f32 and f64;
  - `(int)-1.5 == -1`;
  - all 8 kernel shapes compiling natively, which also confirms that `__riscv_vcreate_*`
    exists in GCC 14.2.
- `tests/nbackend/test_vectorization.py`: **39/39 passed**. On the board, all its setups
  are RVV: (8,32), (4,32), (4,64), plus the strided-store variants.
- RVV-parametrized cases (`-k RISCV_RVV`) of `test_cpu_axes`, `test_type_cast`
  (int32/int64/float32/float64 squared), `test_reduction` (add/sub/mul/min/max, f32/f64,
  1–3D, OpenMP), `test_functions`, `test_iteration_slices`, `test_domain_kernels`,
  `test_flowgraph_codegen`, `test_quicktests`, and `test_cpujit`: **126 passed**,
  400 deselected, in 29 min.
  - The deselected cases are GenericCPU/SYCL. Every test JIT-compiles natively (about
    10 s each), so the full unfiltered list (565 tests) would take about 2.5 h.
  - An earlier unfiltered run passed its first ~134 tests before I stopped it in favor of
    the filtered run.

## Step 5: LBM harness (done locally)

- `lb-pystencils.py` lost the `--mode`, `--vlen`, `--lanes`, and `--vector-bits` options.
  `--target rvv` now means `RISCV_RVV` with default lanes.
- `scripts/lbm_rvv_check.py` compares generic vs rvv for f64 and f32. `ny = 51` makes the
  remainder loop run too.
- Local generic baseline is unchanged: 100×100×200 gives `rel_l2 = 0.0338124` and a
  maximum speed of 0.138736.
- Board, `run.on.bananapi.sh python scripts/lbm_rvv_check.py`: **PASS**. The D2Q9 collide
  kernel on rvv matches generic with max_abs_err 1.8e-15 (f64) and 9.5e-7 (f32).
- Legacy scripts are left untouched and are now stale, because they use the removed
  VLA-era API: `rvv_vlen_sweep.py`, `run_vlen_sweep.sh`, `rvv_perf_probe.py`,
  `rvv_roofline.py`.

## Step 6: walberla (in progress)

- Restored to upstream `0c8ed8c9`: `CMakeLists.txt`, `GNU.cmake`,
  `sweepgen/cmake/SweepgenConfig.template.py`, `sweepgen/src/sweepgen/build_config.py`.
  None of the new `WALBERLA_RISCV_RVV`/`_VLEN`/`_MODE` options remain.
- `GNU.cmake` / `Clang.cmake`: under `WALBERLA_OPTIMIZE_FOR_LOCALHOST` on riscv64, use
  `-march=rv64gcv_zvl256b` when `/proc/cpuinfo` lists `v`, else `-march=rv64gc`. This
  replaces the `-march=native` that GCC rejects. Code generation follows automatically via
  `Target.CurrentCPU` → `RISCV_RVV`, exactly like x86 builds.

### Board build setup

| Item | Setting |
|---|---|
| Build dir | `/home/bananapi/saleh/walberla-build`, outside the synced repo |
| Configure flags | `WALBERLA_ENABLE_V8CORE=ON`, `WALBERLA_ENABLE_SWEEPGEN=ON`, `WALBERLA_SWEEPGEN_MANAGED_VENV=OFF`, `WALBERLA_OPTIMIZE_FOR_LOCALHOST=ON`, `WALBERLA_BUILD_TESTS=ON`, `Python_EXECUTABLE=/home/bananapi/saleh/venv/bin/python` |
| `PYTHONPATH` | `submodules/pystencils/src:submodules/walberla/sweepgen/src`. Nothing is pip-installed from our repos |
| pystencils-sfg | **0.1.1**, installed in the board venv with `pip install --no-deps` |

Why pystencils-sfg 0.1.1: versions 0.2 and 0.3 import `pystencils.grids`, which does not
exist in the pinned pystencils (`20d7dcf0`, 2026-05-21). 0.1.1 (2026-05-26) is the
release that matches the submodule pins. walberla's managed venv would pull sfg from git
master and hit the same mismatch, and it would also bypass our pystencils fork.

### Board build results

- Configure succeeds: "Found pystencils Source File Generator (Version 0.1.1)".
- All 319 compile flag sets contain `-march=rv64gcv_zvl256b`. The few extra
  `-march=native` entries belong to walberla's own x86 SIMD test targets, which add that
  flag themselves and are not built here.
- Target resolution: `SweepgenConfig.project_info()` returns
  `optimize_for_localhost=True`, so `CurrentCPU` → **`RISCV_RVV`**.
- `tests/sweepgen/TestSweepGeneration.py` pins `get_build_config(sfg).target = Target.CPU`
  (generic) for its sweeps, upstream and on x86 alike. That test therefore checks the
  sweepgen machinery and the build flags on riscv64; it does not exercise the RVV backend.
- To exercise the RVV backend, I generated an extra sweep,
  `/home/bananapi/saleh/rvv-sweep-check/RvvSweep.py`: a 3D stencil on a `GhostLayerField`,
  vectorization on, no target override.
  - The output includes `pystencils_runtime/rvv.hpp` and uses
    `__riscv_vle64/vfadd/vfmul/vfmv/vse64_*_f64m1`.
  - It compiles with walberla's own flags and include paths, taken from
    `TestSweepGeneration`'s `flags.make`: `-Wall -Wconversion -Wshadow -pedantic -std=c++20 -O3
    -march=rv64gcv_zvl256b`. **No warnings.** The object contains 27 vector instructions.

## Unattended board run: results (done)

The run used a detached `screen` session (`rvv-unattended`, script
`/home/bananapi/saleh/walberla-build/run_unattended.sh`), so it did not depend on the laptop.
Raw logs are `/home/bananapi/saleh/walberla-build/build.log` and
`/home/bananapi/saleh/lbm-results.log`.

### walberla

- `TestSweepGeneration` built in 35 min (`-j2`, starting with 42 objects already done).
- `ctest -R TestSweepGeneration`: **6/6 passed**. The tests are test1DField, test2DField,
  testV8Fields, testV8FieldSwaps, test1DFieldV8, and test2DFieldV8.

### LBM, full step on the K1 (board idle)

f64 lid-driven cavity, 100×100×200:

| target | compiler | MLUP/s | rel_l2 vs NumPy | old VLS/VLA branch (fable log) |
|---|---|---|---|---|
| generic | GCC | 3.22 | 0.0338124 | 3.17 |
| rvv | GCC | 2.00 | 0.0338124 | 1.96 |
| rvv | Clang | 2.66 | 0.0338124 | 2.69 |

f32 periodic Taylor-Green, 200×200×100, fused collide-stream:

| target | compiler | MLUP/s | checksum `sum_f` | old branch |
|---|---|---|---|---|
| generic | GCC | 5.11 | 4.0000027e4 | 5.05 |
| rvv | GCC | 5.27 | 4.0000052e4 | — |
| rvv | Clang | **8.04** | 4.0000052e4 | 8.54 |

**Correctness.**

- **f64:** all three configurations give identical cavity fields: the same `rel_l2`, the
  same min/max `rho`, and the same maximum speed.
- **f32:** rvv agrees with generic to f32 precision. `max|momx|` is 0.038522 in both, and
  the checksum differs only in the 7th digit, as on the old branch.

**Performance.**

- The simplified backend performs about the same as the old 2.6k-line VLS/VLA branch:
  - f64 is within ±2%;
  - f32 with Clang reaches 8.04 vs 8.54 MLUP/s, which is within the run-to-run noise of a
    single 100-step run.
- The recipe from the performance track still holds: **explicit RVV + Clang + f32 + fusion**
  gives 8.04 MLUP/s, 1.57× generic f32 and 2.5× generic f64.
- Generic is compiled with `CurrentCPU` → `-march=rv64gcv_zvl256b`, so it is GCC-autovec
  RVV, not true scalar.

**Conclusion.** Dropping VLA, LMUL > 1, D14 folding, the runtime guard, and the config
surface cost nothing measurable for these LBM workloads.

### Leftovers on the board

All under `/home/bananapi/saleh/`, all removable:

- `walberla-build/` (contains `run_unattended.sh` and `build.log`)
- `rvv-sweep-check/`
- `lbm-results.log`
- pystencilssfg 0.1.1 in `venv/`
- `lbm-baselines.log` and `.cache/lbm-baselines/` (baseline run below)

## Baselines: true scalar vs autovec vs explicit RVV (done)

**Question.** Does the explicit RVV backend beat what the compilers do by themselves?
Every configuration runs the same pystencils kernels, built with both GCC 14.2 and Clang 18.

**Script.** `scripts/lbm_baselines.sh [REPS]`, run on the board in `screen`, 3 reps, best
reported. It runs three configurations, each with GCC and Clang:

| config | kernels | flags |
|---|---|---|
| scalar | generic | `-march=rv64gc`: no V extension at all, so code is truly scalar |
| autovec | generic | `-march=rv64gcv_zvl256b`: the compiler auto-vectorizes |
| rvv | `Target.RISCV_RVV` | `-march=rv64gcv_zvl256b`, explicit intrinsics |

This is stricter than the fable performance track, whose "true scalar" was
`-fno-tree-vectorize` with V still enabled.

### Throughput: best of 3, MLUP/s

| workload | scalar GCC | scalar Clang | autovec GCC | autovec Clang | rvv GCC | rvv Clang |
|---|---|---|---|---|---|---|
| f64 cavity 100×100×200 | 2.99 | 1.96 | **3.23** | 2.84 | 2.02 | 2.67 |
| f64 periodic 200×200×100 (fused) | 5.80 | 3.50 | **6.69** | **6.69** | 3.18 | 5.49 |
| f32 periodic 200×200×100 (fused) | 5.44 | 3.54 | 5.15 | 8.01 | 5.39 | **8.09** |

The spread across reps is ≤ 6%. Fable's numbers are close to the matching columns:

| workload | fable scalar | scalar GCC | fable autovec | autovec GCC | fable rvv Clang | rvv Clang |
|---|---|---|---|---|---|---|
| f64 cavity | 2.85 | 2.99 | 3.25 | 3.23 | 2.69 | 2.67 |
| f64 periodic | 5.70 | 5.80 | 6.47 | 6.69 | 5.58 | 5.49 |
| f32 periodic | 5.13 | 5.44 | 5.05 | 5.15 | 8.54 | 8.09 |

### Correctness

- **f64:** all six configurations give `rel_l2 = 0.0338124` on the cavity (vs NumPy) and
  `sum_f = 4.0000000000e+04` on the periodic run.
- **f32 `sum_f`:** the checksums agree to f32 precision (< 1e-6 relative), and the differences
  come only from operation order and FMA contraction:
  - 4.0000027037e4 for scalar GCC, bit-identical to autovec GCC;
  - 4.0000027450e4 for scalar Clang;
  - 4.0000027814e4 for autovec Clang;
  - 4.0000051927e4 for rvv, identical for GCC and Clang because the intrinsics fix the
    operation order.

### RVV instructions in the compiled kernels

The count comes from a recount with the fixed method (see "Measurement fixes" below). The
kernels of all three workloads were rebuilt into a fresh cache, 11 modules per configuration
(grid size does not change the kernel code), and disassembled with `llvm-objdump`. Every
mnemonic that starts with `v` is counted.

| scalar GCC | scalar Clang | autovec GCC | autovec Clang | rvv GCC | rvv Clang |
|---|---|---|---|---|---|
| **0** | **0** | 2143 | 821 | 4027 | 1519 |

- The scalar baselines contain no vector code at all.
- Both autovec builds really vectorize.
- GCC emits about 2.6× more vector instructions than Clang for the same intrinsics. It is
  also the slower compiler for rvv.

### Findings

- **f64: explicit RVV does not pay off on the K1.**
  - The best f64 result is plain autovec (6.69 MLUP/s, either compiler).
  - rvv Clang reaches 0.82–0.83× autovec and 0.89–0.95× scalar GCC.
  - rvv GCC is the worst configuration (0.55–0.68× scalar GCC).
- **f32: explicit RVV with Clang is the fastest configuration (8.09 MLUP/s, 1.49× scalar GCC),
  but autovec Clang is level with it (8.01, within noise).**
  - The f32 win reported in the fable track ("explicit RVV + Clang + f32") is mostly a Clang
    win: Clang auto-vectorizes the generic kernel just as well.
  - Fable never measured Clang autovec, so this is new.
  - GCC does not profit in f32 from either autovec (5.15) or intrinsics (5.39).
- **The compiler matters as much as the backend.**
  - Scalar Clang is 34–40% slower than scalar GCC.
  - rvv GCC is 24–42% slower than rvv Clang in f64.
  - The causes were not investigated.
- **What the explicit backend does give:** results that are the same for both compilers, and
  f32 speed with Clang without depending on the auto-vectorizer. It is not a speedup over
  the best autovec build for these LBM kernels.
- **Lead for later (not investigated):** an f64 rvv Clang module contains whole-register
  spill/reload instructions (`vs2r.v`/`vl2r.v`), a sign of vector register pressure in the
  f64 kernels.

### Measurement fixes made along the way

- The first count used GNU objdump. binutils 2.42 on the board prints Clang's RVV code as
  raw `.insn` words, which made every Clang build count as 0.
  `lbm_baselines.sh` now uses `llvm-objdump`, which also decodes GCC output.
- The harness's macro kernel (ρ/u output, deliberately generic) was compiled with the default
  JIT, `CurrentCPU` → `rv64gcv_zvl256b` with GCC. So the "scalar" caches contained 9 modules
  of GCC-autovec code. It now uses the configured JIT like every other kernel.
- The macro kernel only runs every 1000 steps and these runs are 100–200 steps, so the
  timings above are unaffected.
- The script's cache moved from `$HOME/.cache` to `/home/bananapi/saleh/.cache`, because the
  board is shared.

## Why explicit RVV loses to autovec: kernel experiment (superseded, see "corrected" below)

Out of tree in `misc/rvv-vs-autovec/`; see its README for the method, all tables and the
hot-loop histograms. The LBM kernels were dumped as standalone C++ and built as
scalar / autovec / rvv × GCC / Clang × f64 / f32. Each build was timed with cycle and
instruction counters on the board. Every build agrees on the checksums.

Fused kernel, f64, 200², MLUP/s:

| kernel | GCC autovec | GCC rvv | Clang autovec | Clang rvv |
|---|---|---|---|---|
| fused, as the harness builds it | 10.3 | 3.5 | 8.6 | 6.4 |
| fused + `sympy_cse` | 11.6 | 10.8 | 9.0 | 6.7 |

Three causes, none of them in the VLS-256 design itself:

1. **The harness never applies CSE.** GCC does not remove the repeated RVV intrinsic calls
   (17 `vfdiv` per vector iteration instead of 2). With `ps.simp.sympy_cse`,
   rvv GCC is 3× faster and within 7–8% of autovec at 200² in both f64 and f32. Clang was already
   removing the repeats.
2. **No FMAs, and `-1.0 * x` stays a multiply.** Neither compiler fuses or folds RVV
   intrinsic calls, so the rvv loop has 157 vector mul/add/sub ops against 85 in autovec.
   x86 intrinsics are plain vector arithmetic in the headers, so the AVX path never had to
   care. When compute-bound (48²) GCC rvv needs 17–30% more cycles per cell than autovec in f64
   and 7–13% more in f32, over the two runs.
3. **Clang's rvv loop has low IPC (0.25 vs GCC's 0.36)** with nearly the same instructions.
   Candidates are scheduling for the in-order X60 and spills: 7 whole-register loads/stores
   plus `csrr vlenb` per iteration. Not yet explained.

Follow-up:

- **CSE:** `lb-pystencils.py` and `lbm_rvv_check.py` now apply `ps.simp.sympy_cse` (`_cse()`).
  The baselines are being rerun with it.
- **FMA:** checked by hand with `misc/rvv-vs-autovec/fma_rewrite.py`, which rewrote 49
  FMAs and 22 negations into the generated source.
  - With GCC: no gain. Instructions per cell drop 16%, but the cycles stay the same.
  - With Clang: negation folding alone gains 13–17%, and FMAs on top are slower than that.
  - So **no FMA step in the backend**; the plan's "out of scope" stands.
- **Remaining gap** of 5–10% (GCC rvv vs GCC autovec): not the FP op count. Every vector
  build sits at about 450–500 cycles per 4-cell f64 iteration. Leads: the 2 divides per
  cell, since sympy CSE leaves `1/ρ²` as its own division, and GCC reloading 8 PDFs
  (17 vs 9 `vle` per iteration).

## Baselines with CSE in the harness (done)

These are the same runs as "Baselines" above (`scripts/lbm_baselines.sh 3`, best of 3), now
with `_cse()` in `lb-pystencils.py`. Raw log on the board: `lbm-baselines.log`. The
pre-CSE log is `lbm-baselines-nocse.log`.

| workload (MLUP/s) | scalar GCC | scalar Clang | autovec GCC | autovec Clang | rvv GCC | rvv Clang |
|---|---|---|---|---|---|---|
| f64 cavity 100×100×200 | 2.97 | 2.01 | **3.23** | 2.92 | 3.20 | 2.79 |
| f64 periodic 200×200×100 | 5.90 | 3.57 | 6.66 | 6.87 | **7.85** | 5.79 |
| f32 periodic 200×200×100 | 5.83 | 3.69 | 5.90 | 8.29 | **9.58** | 8.37 |

**What changed vs no CSE:**

- rvv GCC got 1.6×, 2.5× and 1.8× faster (from 2.02, 3.18 and 5.39).
- rvv Clang gained about 4%.
- Scalar and autovec are unchanged within noise, because their compilers already removed
  the repeats.

**Ranking:**

- **rvv GCC is now the fastest build on both periodic (fused) workloads.**
  - f64: 1.14× the best autovec (Clang), 1.18× autovec GCC, 1.33× scalar GCC.
  - f32: 1.16× the best autovec (Clang), 1.62× autovec GCC, 1.64× scalar GCC.
- On the non-fused cavity it ties autovec GCC (3.20 vs 3.23).

**Correctness:** unchanged.

- Every build gives `rel_l2 = 0.0338124` and f64 `sum_f = 4.0000000000e+04`.
- f32 checksums agree to < 1e-6. rvv GCC and rvv Clang are bit-identical to each other.

**RVV instruction counts:** scalar GCC 0, scalar Clang 0. The script now starts from an
empty cache, and the counts cover every module built during the run, all reps included.

## Kernel experiment, corrected: runtime strides (done)

The kernel numbers in "Why explicit RVV loses to autovec" were biased. The experiment's
wrapper was in the kernel's TU, so the compiler inlined the constant strides. That helped
the generic (autovec) kernels. With the wrapper in its own TU, all sizes and strides are
runtime values, as in the JIT, and the result flips. Details and disassembly:
`misc/rvv-vs-autovec/README.md`, "Results with runtime strides".

`fused_cse` kernel, MLUP/s:

| | GCC autovec | Clang autovec | GCC rvv | Clang rvv |
|---|---|---|---|---|
| f64 200² | 7.85 | 8.12 | **10.60** | 6.84 |
| f32 200² | 8.98 | 14.71 | **22.56** | 14.93 |

Why, from the disassembly:

- **Our backend assumes inner stride 1, like AVX**, so it emits plain `vle64`/`vse64`.
- **GCC autovec** cannot assume this, so all 18 accesses become `vluxei64`/`vsuxei64`
  gathers/scatters. The loop has 309 instructions, 78 per cell.
- **Clang autovec** versions the loop on stride == 1 and runs at LMUL 2, with about 21
  spills per iteration.

**Conclusion:** with GCC, which is the JIT's default compiler, the generated RVV code is
the fastest build: 1.24–1.31× (f64) and 1.35–1.53× (f32) over the best autovec build. This
matches the full-step harness, 1.14–1.16× on the periodic workloads.

**The one weak combination is Clang + our intrinsics.** Clang issues dependency chains back
to back on the in-order X60, and keeps the constant splats live in vector registers, which
forces spills.

- The vendor Clang's `-mtune=spacemit-x60` gains 8–17%, but Clang rvv still stays 24–31%
  behind GCC rvv.
- Not added to the JIT, because the flag is vendor- and K1-specific.

**FMA:** confirmed irrelevant with runtime strides too. GCC rvv measured 10.60, 10.46 and
10.43 for the plain, negation-folded and FMA variants.

## Why GCC rvv beats GCC autovec but Clang rvv trails Clang autovec (done)

Kernel experiment, runtime strides; details in `misc/rvv-vs-autovec/README.md`
("Splat folding" and "Summary").

1. **GCC autovec gathers.** In the JIT the inner stride is a runtime value, so every field
   access becomes `vluxei64`/`vsuxei64`. Our backend assumes inner stride 1, the AVX
   contract, and uses `vle`/`vse`. That is the whole GCC story.
2. **Clang autovec does not gather.** It versions the loop on stride == 1, then uses
   unit-stride loads at **LMUL 2** with constants as `.vf` scalar operands
   (32 insns/cell). So for Clang our stride contract gives no advantage. What decides is
   code quality:
   - **Constant splats in vector registers.** Our code emits `vfmv_v_f(c)` and `.vv` ops.
     Both compilers hoist about 10 splats into vector registers, and Clang then spills.
     The hand rewrite to `.vf` forms (`fused_cse_vf`, i.e. the fable branch's D14 broadcast
     folding) removes all spills.
     - Clang rvv gains 7–25%, and **in f32 it then matches or beats Clang autovec**
       (18.15 vs 14.83 MLUP/s at 200²).
     - GCC rvv gains 1.5–13%: f64 10.83, f32 23.30 at 200², still the fastest build overall.
   - **Scheduling.** Clang has no X60 model by default and issues dependency chains back
     to back. The vendor Clang's `-mtune=spacemit-x60` gives +8–17%.
   - **LMUL is not the reason.** Forced to LMUL 1
     (`-mllvm -riscv-v-register-bit-width-lmul=1`), Clang autovec gets *faster*: f64
     8.70 → 10.10, f32 14.83 → 22.08 MLUP/s at 200². Its loop drops its 21 LMUL-2 spills.
     This is now the best autovec build of all, and it is on par with GCC rvv: GCC rvv with
     `.vf` is 1.08–1.12× ahead in f64 and 1.06–1.09× in f32.
   - **What remains between Clang autovec and Clang rvv** is Clang's algebra on scalar IR
     under `-ffast-math`: FMA, folded negations and `.vf` constants give 88 FP ops per
     iteration against 157 in our intrinsic loop. RVV intrinsics are opaque to these passes.
     Clang's default schedule exposes every extra op on the in-order X60. GCC's schedule
     hides them, which is why FMA/negation folding helps Clang but not GCC.

**Overall conclusion:**

- **With default compiler settings,** our explicit RVV path, with GCC (the JIT default), is
  clearly the fastest build.
- **Against the best autovec we could produce** (Clang, hand-forced LMUL 1), it is on par to
  slightly ahead.
- **The explicit path's value is also predictability.** Autovec ranged from gathers (GCC) to
  LMUL-2 spills (Clang default), while our code gives the same structure on both compilers.


**Candidate for pystencils:** splat folding (`.vf` forms for constant operands) in
`backend/platforms/rvv.py`. It gives measurable gains on both compilers and removes Clang's
spills. Whether to implement it is a decision for the user, because AVX has no analogue
(x86 has no vector-scalar arithmetic).

## waLBerla end-to-end benchmark (done; 2026-11-01, all jobs finished 16:36 board time)

**Goal:** measure the speedup of our RVV backend in a real waLBerla LBM run, against scalar
and auto-vectorized baselines, with GCC and Clang, in f64 and f32.

### What was missing, and what was added

- **lbmpy.** sweepgen's LBM support (`sweepgen.prefabs.LbmBulk`, boundaries, the
  `LbmScenarios` tests) needs lbmpy, which was not installed. The git server sweepgen pins
  (`i10git.cs.fau.de`) answered HTTP 500. **lbmpy 2.1.1 from PyPI** was installed with
  `--no-deps` into the board venv (`/home/bananapi/saleh/venv`).
  - Locally it was installed only into a scratchpad directory, so `.venv-rvv` is untouched.
  - It works with our pinned pystencils (version `2.0b1+4.g9a989e16`), although it declares
    `pystencils~=2.1`. A D3Q19 TRT update rule generates, and our RVV backend vectorizes it.
- **sweepgen never enables vectorization.** `WalberlaBuildConfig.get_pystencils_config()`
  sets `cfg.target` (`CurrentCPU` resolves to `RISCV_RVV` on the K1) but never
  `cpu.vectorize.enable`. Without an explicit request, waLBerla-generated sweeps are scalar
  on every platform, x86/AVX included. A generator script requests vectorization through the
  `gen_config` argument of `Sweep` / `LbmBulk`. **No sweepgen change is needed.**
- **New walberla app `apps/benchmarks/SweepgenLbmCPU/`** (in the fork, uncommitted), registered
  in `apps/benchmarks/CMakeLists.txt` under `WALBERLA_ENABLE_SWEEPGEN`.
  - It runs the `DoubleShearLayer` example's LBM: D3Q19 SRT compressible, fully periodic N³,
    one block per process.
  - It times stream-collide plus halo exchange, and prints MLUP/s and the final kinetic
    energy as a checksum.
  - Six executables:
    - `scalar`: GenericCPU, `-march=rv64gc`, no V at all;
    - `autovec`: GenericCPU, waLBerla's `-march=rv64gcv_zvl256b`;
    - `explicit`: `CurrentCPU` = `RISCV_RVV`, vectorize on, `assume_inner_stride_one`;
    - each also as `_cse`, with lbmpy `cse_global=True`.
  - Details: the app's `README.md`.
- **lbmpy's default leaves a lot of repetition** (`cse_global=False`, which `LbmBulk` uses).
  For a D3Q19 TRT rule, per vector iteration of our RVV sweep:

  | | `vfmul` | `vle64` |
  |---|---|---|
  | default | 228 | 147 |
  | `cse_global=True` | 92 | 70 |

  GCC does not remove repeated RVV intrinsic calls, which is why the `_cse` executables exist.
- **Board scripts:**
  - `scripts/walberla_lbm_bench.sh`: in one build dir, build the six targets (`-j2`, the
    board has 3.7 GB RAM), count RVV instructions in each generated sweep object, run each
    executable 3× pinned to core 2 (64³ cells, 200 steps + 10 warmup), and summarize.
  - `scripts/walberla_bench_all.sh`:
    - waits for a running GCC f64 job;
    - then configures and runs `clang-f64`, `gcc-f32` and `clang-f32`, each in its own build
      dir (`walberla-build-<config>`, only benchmarks enabled);
    - then waLBerla's own `TestLbmScenarios_CXX` in the GCC f64 dir (the default
      waLBerla-on-K1 path: `CurrentCPU` = `RISCV_RVV`, not vectorized);
    - then a combined table from `scripts/walberla_bench_summary.py`.
- All jobs run in detached `screen` sessions (`walberla-bench`, then `walberla-all`), so they
  continue without the laptop.

### Where the results land (board, `/home/bananapi/saleh/`)

| log | content |
|---|---|
| `walberla-bench.log` | GCC f64 (build dir `walberla-build`, started 2026-11-01 09:57 board time) |
| `walberla-bench-{clang-f64,gcc-f32,clang-f32}.log` | the other configurations |
| `walberla-lbmscenarios.log` | waLBerla's LBM scenario tests |
| `walberla-all.log` | chain progress plus the **combined summary** at the end (`== ALL DONE`) |
| `walberla-followup.log` | the Clang reruns, the combined summary again, then the multi-core runs (`scripts/walberla_bench_mpi.sh`): every executable with 4 MPI processes (one cluster) and 8 (whole chip), 64³ per process, 100 steps, best of 2, summary per process count (`== FOLLOWUP DONE` at the end) |
| `walberla-mpi-np{4,8}-<config>.log` | raw multi-core result lines |

Per-target build logs are in `walberla-build*/build-<target>.log`.

### Notes

- **The board clock is about 46 h behind the laptop.** Pushed files carry future mtimes, so
  `make` warns about clock skew and regenerates or rebuilds more than needed. That is
  harmless: it can only cause extra rebuilds, never stale objects. It is a shared machine,
  so its clock is left alone.
- **The first GCC f64 target** (`SweepgenLbmCPU_scalar`) built in about 7.5 min. A 16³ smoke
  run printed `energy=5.17904661397`.

### Result: GCC f64 (done; 2026-11-01 10:43–11:00 board time)

The run used 64³ cells, 200 steps plus 10 warmup, one core (pinned to core 2), best of 3.
Raw log on the board: `/home/bananapi/saleh/walberla-bench.log`.

| variant | MLUP/s | vs scalar | RVV insns in the generated sweep object |
|---|---|---|---|
| scalar | 0.90 | 1.00× | 0 |
| scalar_cse | 0.96 | 1.06× | 0 |
| autovec | 0.91 | 1.00× | 138 |
| autovec_cse | 0.96 | 1.06× | 138 |
| **explicit** | **1.14** | **1.26×** | 665 |
| **explicit_cse** | **1.18** | **1.31×** | 608 |

- **The checksum is identical to 12 digits for all six variants:** kinetic energy
  3.775155682480e+02. Our RVV sweeps compute exactly what the scalar ones compute.
- **GCC's auto-vectorizer gains nothing here** (0.91 vs 0.90). Only 138 vector instructions
  appear in its sweep object, so GCC vectorized almost none of the D3Q19 sweep. That fits
  the kernel experiment: with runtime strides, GCC would have to gather.
- **The explicit RVV sweep gives 1.26×, and 1.31× with global CSE.** CSE helps every variant
  by about 5%.
- **The speedup is much smaller than in the 2D kernel experiment** (1.3–1.5× vs autovec at
  kernel level).
  - D3Q19 at 64³ is strongly memory-bound on one in-order X60 core: 0.9 MLUP/s is about
    1.1 µs per cell.
  - The pull stream reads 19 neighbor planes, about 2 MB per z-plane triple, which exceeds
    the L2.
  - Vectorizing the arithmetic cannot help much when the memory system is the limit.
  - A smaller, cache-resident domain would show the compute-bound case (not run yet).
  - Confirmed later by the bytes-per-second comparison of f64 and f32 in "Why the gain
    shrinks" below.

### Result: GCC f32 (done; 2026-11-01 13:02–13:12 board time)

Same setup as GCC f64 (64³, 200 steps + 10 warmup, core 2, best of 3), built with
`WALBERLA_DOUBLE_ACCURACY=OFF`. Raw log on the board: `/home/bananapi/saleh/walberla-bench-gcc-f32.log`.

| variant | MLUP/s | vs scalar | RVV insns in the generated sweep object | kinetic energy |
|---|---|---|---|---|
| scalar | 1.39 | 1.00× | 0 | 3.775244759310e+02 |
| scalar_cse | 1.56 | 1.12× | 0 | 3.775251445040e+02 |
| autovec | 1.39 | 1.00× | 138 | 3.775244759310e+02 |
| autovec_cse | 1.60 | 1.15× | 138 | 3.775251445040e+02 |
| **explicit** | **2.37** | **1.70×** | 665 | 3.775233720630e+02 |
| **explicit_cse** | **2.40** | **1.73×** | 608 | 3.775233908620e+02 |

- **The explicit RVV sweep gives 1.70×, and 1.73× with global CSE.** Against the best
  auto-vectorized build (autovec_cse, 1.60) it is **1.50×**.
- **f32 gains more than f64** (1.73× vs 1.31×). A 256-bit register holds 8 floats instead of
  4 doubles, and each cell moves half the bytes, so the sweep is less memory-bound.
  - Scalar f32 vs scalar f64: 1.39 vs 0.90 MLUP/s (1.54×), roughly the ratio of bytes moved.
  - Explicit f32 vs explicit f64: 2.40 vs 1.18 (2.03×).
- **GCC's auto-vectorizer again gains nothing without CSE** (1.39 = scalar). With CSE it is
  3% ahead of scalar_cse.
- **Checksums.** The variants with the same expression structure agree exactly: scalar ==
  autovec, and scalar_cse == autovec_cse. The groups differ from each other by at most
  4.7e-6 relative.
  - That is about 60 f32 ulps (the ulp at 377 is 3.1e-5) after 200 steps over 262144 cells.
  - It is expected when the operation order differs: CSE reorders the arithmetic, and the
    compiler may contract scalar code into FMAs, which it does not do for RVV intrinsics.
  - In f64 the same differences stay below the 12 printed digits.
- **Build time.** The first target in a fresh build dir took 41 min, because it builds the
  waLBerla core libraries. Each later target took about 5 min. (The GCC f64 dir already had
  the core libraries from the earlier `TestSweepGeneration` build.)

### Result: Clang f64 and f32 (done; 2026-11-01 14:13–15:43 board time)

Rerun by the follow-up chain after the two fixes below; same setup as GCC. Raw logs:
`/home/bananapi/saleh/walberla-bench-clang-{f64,f32}.log`. Run-to-run spread of the 3 runs
was at most 1.2% for every variant.

| variant | clang-f64 MLUP/s | vs scalar | clang-f32 MLUP/s | vs scalar |
|---|---|---|---|---|
| scalar | 0.77 | 1.00× | 1.10 | 1.00× |
| scalar_cse | 0.86 | 1.12× | 1.22 | 1.11× |
| autovec | 0.77 | 1.00× | 1.11 | 1.01× |
| autovec_cse | 0.87 | 1.12× | 1.24 | 1.12× |
| **explicit** | **1.01** | **1.31×** | **2.11** | **1.92×** |
| explicit_cse | 0.99 | 1.28× | 2.06 | 1.87× |

RVV instructions in the sweep objects: autovec 55, explicit 592 (f64) / 590 (f32),
explicit_cse 561.

- **Clang's auto-vectorizer gains nothing either.** Only 55 vector instructions in the sweep
  object, fewer than GCC's 138.
- **Global CSE does not help Clang's explicit sweep.** It is 2–3% slower (above the noise).
  That fits the kernel experiment: Clang already removes repeated RVV intrinsic calls itself,
  while GCC does not.
- **Clang is slower than GCC in every variant** (scalar f64 0.77 vs 0.90, explicit f64
  1.01 vs 1.18). The speedup ratios are similar or larger only because Clang's scalar
  baseline is slower.
- **Checksums.**
  - f64: all six variants agree to 12 digits, with each other and with GCC f64
    (3.775155682480e+02).
  - f32: the explicit sweeps give *exactly* the GCC f32 explicit checksums (3.775233720630e+02,
    and 3.775233908620e+02 with CSE). The intrinsic code fixes the operation order and
    neither compiler fuses or reorders it. The compiler-generated scalar code differs
    between compilers. The spread within clang-f32 is 2.2e-6 relative.

### Single-core summary: all four configurations

Best MLUP/s of 3 runs, 64³ cells, one core. In parentheses: the speedup over the same
configuration's plain scalar build.

| variant | gcc-f64 | clang-f64 | gcc-f32 | clang-f32 |
|---|---|---|---|---|
| scalar | 0.90 (1.00×) | 0.77 (1.00×) | 1.39 (1.00×) | 1.10 (1.00×) |
| scalar_cse | 0.96 (1.06×) | 0.86 (1.12×) | 1.56 (1.12×) | 1.22 (1.11×) |
| autovec | 0.91 (1.00×) | 0.77 (1.00×) | 1.39 (1.00×) | 1.11 (1.01×) |
| autovec_cse | 0.96 (1.06×) | 0.87 (1.12×) | 1.60 (1.15×) | 1.24 (1.12×) |
| explicit | 1.14 (1.26×) | **1.01 (1.31×)** | 2.37 (1.70×) | **2.11 (1.92×)** |
| explicit_cse | **1.18 (1.31×)** | 0.99 (1.28×) | **2.40 (1.73×)** | 2.06 (1.87×) |

Our explicit RVV sweep against the best auto-vectorized build of the same configuration:

| | gcc-f64 | clang-f64 | gcc-f32 | clang-f32 |
|---|---|---|---|---|
| best explicit / best autovec | 1.18 / 0.96 = **1.23×** | 1.01 / 0.87 = **1.16×** | 2.40 / 1.60 = **1.50×** | 2.11 / 1.24 = **1.70×** |

- The fastest build overall is GCC with our RVV backend plus global CSE, in both precisions.
- Neither compiler's auto-vectorizer vectorizes the waLBerla D3Q19 sweep in a useful way.
  Before this backend, waLBerla LBM on the K1 effectively ran scalar.
- f64 is memory-bound (see the GCC f64 notes), so the gain is 1.2–1.3×. f32 halves the
  bytes and doubles the lanes, so the gain is 1.5–1.9×.

### Result: multi-core (done; 2026-11-01 15:43–16:36 board time)

`scripts/walberla_bench_mpi.sh`, run by the follow-up chain: each executable with
`mpirun -np N --bind-to core --map-by core`, one 64³ block per process, 100 steps + 10 warmup,
best of 2. Raw logs: `/home/bananapi/saleh/walberla-mpi-np{4,8}-<config>.log`.
Run-to-run spread was at most 1.4% at 4 processes and at most 3.9% at 8.

**4 processes (one cluster):** MLUP/s (speedup vs the same configuration's scalar)

| variant | gcc-f64 | clang-f64 | gcc-f32 | clang-f32 |
|---|---|---|---|---|
| scalar | 3.30 (1.00×) | 2.82 (1.00×) | 5.25 (1.00×) | 4.31 (1.00×) |
| scalar_cse | 3.49 (1.06×) | 3.11 (1.10×) | 5.61 (1.07×) | 4.78 (1.11×) |
| autovec | 3.34 (1.01×) | 2.83 (1.00×) | 5.33 (1.01×) | 4.32 (1.00×) |
| autovec_cse | 3.48 (1.05×) | 3.12 (1.11×) | 5.57 (1.06×) | 4.81 (1.12×) |
| explicit | 3.84 (1.16×) | **3.56 (1.26×)** | 7.65 (1.46×) | **7.13 (1.66×)** |
| explicit_cse | **3.89 (1.18×)** | 3.51 (1.24×) | **7.81 (1.49×)** | 6.96 (1.62×) |

**8 processes (whole chip):**

| variant | gcc-f64 | clang-f64 | gcc-f32 | clang-f32 |
|---|---|---|---|---|
| scalar | 4.90 (1.00×) | 4.48 (1.00×) | 8.55 (1.00×) | 7.50 (1.00×) |
| scalar_cse | 5.01 (1.02×) | 4.78 (1.07×) | 8.84 (1.03×) | 8.03 (1.07×) |
| autovec | 4.87 (0.99×) | 4.52 (1.01×) | 8.64 (1.01×) | 7.56 (1.01×) |
| autovec_cse | 5.00 (1.02×) | 4.78 (1.07×) | 9.00 (1.05×) | 8.07 (1.08×) |
| explicit | 5.24 (1.07×) | **5.07 (1.13×)** | 10.38 (1.21×) | **10.13 (1.35×)** |
| explicit_cse | **5.26 (1.07×)** | 5.03 (1.12×) | **10.45 (1.22×)** | 9.95 (1.33×) |

Best explicit vs best autovec of the same configuration:

| processes | gcc-f64 | clang-f64 | gcc-f32 | clang-f32 |
|---|---|---|---|---|
| 1 | 1.23× | 1.16× | 1.50× | 1.70× |
| 4 | 1.12× | 1.14× | 1.40× | 1.48× |
| 8 | 1.05× | 1.06× | 1.16× | 1.26× |

- **Checksums:** at 4 and 8 processes as well, all f64 variants of both compilers agree to
  12 digits. The f32 spread is at most 2.5e-6 relative. The halo exchange between
  processes therefore works with every variant.
- **The gain shrinks as cores are added, because the chip runs out of memory bandwidth.**
  The bandwidth table below shows it.

### Why the gain shrinks: the sweep becomes bandwidth-bound

The generated `StreamCollide` reads 19 PDFs and writes 19 PDFs (into `f_tmp`), plus density
(1) and velocity (3). Counted from the stores in the generated source, that is 42 values per
cell: 336 B in f64, 168 B in f32. Write-allocate traffic is not counted, so these are lower
bounds. Bytes per second = MLUP/s × bytes per cell:

| processes | explicit_cse GCC f64 | explicit_cse GCC f32 | explicit Clang f64 | explicit Clang f32 | scalar GCC f64 | scalar GCC f32 |
|---|---|---|---|---|---|---|
| 1 | 396 MB/s | 403 MB/s | 339 | 354 | 302 | 234 |
| 4 | 1307 MB/s | 1312 MB/s | 1196 | 1198 | 1109 | 882 |
| 8 | 1767 MB/s | 1756 MB/s | 1704 | 1702 | 1646 | 1436 |

- **The explicit RVV sweeps move the same number of bytes per second in f64 and in f32**
  (396 vs 403 MB/s on one core, 1307 vs 1312 at 4 processes, 1767 vs 1756 at 8). That is the
  signature of a bandwidth limit: f32 runs twice as many cells per second only because each
  cell is half the bytes.
- **The scalar builds stay below that limit**, especially in f32, so vectorization helps
  them. The more cores share the memory system, the closer scalar gets to the limit and the
  less is left to gain.
  - 8 processes, f64: scalar already reaches 1646 of the roughly 1770 MB/s.
- **The second cluster adds little.** From 4 to 8 processes, explicit GCC f64 goes from 3.89
  to 5.26 MLUP/s (1.35×).
- **On one core, ~400 MB/s is a per-core limit, not the DRAM limit**: 4 cores reach 3.3× that.
  The X60 is in order, so one core can keep only a few cache misses in flight.
- **Conclusion:** the backend removes the compute bottleneck of the waLBerla LBM sweep on
  the K1. Beyond that, the sweep is limited by memory bandwidth, which no code generator can
  fix. Further gains would need less traffic per cell (in-place streaming such as AA or
  esoteric twist, f32 storage, or kernel fusion), not better vector code.

### Result: waLBerla's own LBM scenario tests (done; 2026-11-01 14:03–14:13 board time)

- **`TestLbmScenarios_CXX` passes 9/9** in the GCC f64 build dir: FullyPeriodic,
  MirroredHalfChannel and FreeSlipPipe, each with 1, 2 and 4 MPI processes. Log:
  `/home/bananapi/saleh/walberla-lbmscenarios.log`.
- This is the default waLBerla path on the K1: sweepgen with `CurrentCPU` (= `RISCV_RVV`),
  without vectorization, using lbmpy 2.1.1 and our pystencils. It shows that the LBM stack
  (lbmpy, sweepgen, boundaries, the v8 halo exchange over MPI) works on the board.
- The main chain `walberla-all` ended at 14:12:57 (`== ALL DONE`). Its combined table has
  only the GCC columns, because both Clang configurations failed (see below). The Clang
  numbers come from the follow-up chain.

### Clang 18 could not build waLBerla's v8 halo exchange (fixed in the fork)

- **First clang-f64 pass: all six targets failed.** The generated sweeps compiled, with
  561–592 RVV instructions in the explicit variants. The app TU did not:
  `GenericFieldPackInfos.hpp` declares `const ConstFieldView srcView{ field_, srcBlock };`.
  That deduces the template arguments of an *alias* template (C++20, P1814), which GCC
  supports and Clang implements only from version 19. The board has Clang 17 and 18.
- **Fix (walberla fork, uncommitted):** the four declarations use the explicit type
  `memory::ConstFieldViewType< FieldType >` instead, which is the type deduction would
  produce. Clang 18 then accepts the app; a syntax-only compile with the clang-f64 build
  flags passed. This is a general Clang-compatibility fix, independent of RVV.
- **clang-f32 then failed on a bug in the new benchmark app** (2026-11-01 13:14–14:03 board
  time).
  - `const real_t tau{ nu / (1. / 3.) };` and the `omega` line narrow a `double` expression
    to `float` inside braces.
  - GCC only warns about that, so the GCC f32 build passed. Clang rejects it
    (`-Wc++11-narrowing` is an error).
  - Fixed with `real_c(...)`. That is the same conversion GCC applied implicitly, so the
    GCC f32 results stay valid. A syntax-only Clang compile with the clang-f32 flags passed.
  - The generated sweeps had compiled fine. RVV instructions in the sweep objects: autovec 55,
    explicit 590, explicit_cse 561. GCC f32 had 138, 665 and 608.
- **Rerun of both Clang configurations:** `scripts/walberla_bench_followup.sh` (screen
  `walberla-followup`, restarted 14:08 board time with `RERUN="clang-f64 clang-f32"`).
  - It waits for `walberla-all`, then reruns both into `walberla-bench-clang-{f64,f32}.log`.
    The build dirs are reused, so the core libraries are not rebuilt.
  - It then prints the combined summary again and starts the multi-core runs
    (`walberla_bench_mpi.sh`). Everything goes to `walberla-followup.log`.
  - The separately queued `walberla-mpi` session was removed in favor of this chain.
  - A 2-process smoke run (`mpirun -np 2 --bind-to core`, 16³ per process) of the GCC f64
    explicit_cse executable worked, so the multi-core stage will not fail at launch.

### Status at the end of the waLBerla benchmark (2026-11-03)

- **Nothing is committed.** Uncommitted changes:
  - walberla fork (`rvv-support`):
    - new app `apps/benchmarks/SweepgenLbmCPU/` (generator, app, CMake, README);
    - its registration in `apps/benchmarks/CMakeLists.txt`;
    - the Clang 18 fix in `include/walberla/v8/halo_exchange/fields/GenericFieldPackInfos.hpp`.
  - outer repo: `scripts/walberla_{lbm_bench,bench_all,bench_followup,bench_mpi}.sh`,
    `scripts/walberla_bench_summary.py`, and this log.
  - pystencils: no change was needed for the waLBerla runs.
- **Board:** no jobs are running. The four build dirs
  (`/home/bananapi/saleh/walberla-build{,-clang-f64,-gcc-f32,-clang-f32}`, about 480 MB
  together) and all logs are kept for reruns. The disk has 3.2 GB free.
- **Open decision, for the user:** splat folding (`.vf` forms) in `backend/platforms/rvv.py`.
  It helps Clang in the kernel experiment, but it goes beyond the AVX-parity design. Given
  that the waLBerla sweep is bandwidth-bound beyond one core, its end-to-end value is
  limited to the single-core case.

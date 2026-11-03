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

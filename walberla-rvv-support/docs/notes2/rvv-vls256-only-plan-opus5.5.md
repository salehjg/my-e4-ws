# Plan (Opus 5.5): RVV-1.0 support in pystencils, VLS-only, VLEN hardcoded to 256, built to match the AVX path

Companion notes (older, broader scope): [`../notes/rvv-implementation-plan-fable.md`](../notes/rvv-implementation-plan-fable.md),
its progress log [`../notes/rvv-implementation-plan-fable-progress.md`](../notes/rvv-implementation-plan-fable-progress.md),
and [`../notes/pystencils-cpu-backends.md`](../notes/pystencils-cpu-backends.md).

Target hardware: SpacemiT K1 (Banana Pi F3, `ssh bananapi`), VLEN = 256, GCC 14.2 + Clang 18.1.8.

## 1. Context: why a new plan

The `rvv-support` branches implement the fable plan: pystencils `31758e93` ("vibecoded rvv
support", about 2.6k lines) and walberla `e9712d59`. That plan covers VLS **and** VLA modes,
a per-type LMUL derived from `(lanes, vlen)`, `RvvOptions`/`VectorizationMode` config, a new
IR function `PsVecStripmineLanes`, a `stripmine` axis expansion, a runtime VLEN guard, D14
broadcast folding, `vid`/slide constant chains, and `-march` synthesis from cpuinfo. That
weight is the problem.

This plan cuts the scope down to:

- **VLS only**, with **VLEN hardcoded to 256** (the K1).
- **The same assumptions the AVX (x86) codegen path already makes.** No new IR, loop
  strategies, or config options. Everything that can be simple is simple.
- Development and validation **on the board**, using adapted push/test scripts.
- Moderate code comments that explain the reasons and the flow of ideas.
- **Nothing committed.**

Decisions made with the user:

1. **Strip `rvv-support` in place.** Changes stay uncommitted on top of the existing branches
   in both submodules.
2. **walberla: minimal fix plus a build attempt on the board.**
3. **VLEN guard: compile-time only.** `rvv.hpp` raises `#error` unless it is compiled with
   VLEN ≥ 256. No runtime check is added to kernels.

## 2. The AVX contract we copy

Sources: [`x86.py`](../../submodules/pystencils/src/pystencils/backend/platforms/x86.py),
[`target.py`](../../submodules/pystencils/src/pystencils/codegen/target.py),
[`compiler_info.py`](../../submodules/pystencils/src/pystencils/jit/cpu/compiler_info.py),
[`x86.hpp`](../../submodules/pystencils/src/pystencils/include/pystencils_runtime/x86.hpp),
[`simd_horizontal_helpers.h`](../../submodules/pystencils/src/pystencils/include/pystencils_runtime/bits/simd_horizontal_helpers.h).

| AVX assumption | RVV-256 equivalent |
|---|---|
| The register width is fixed and known at codegen. `default_vector_lanes = 256 // bits` | `Target.RISCV_RVV` → `256 // bits`. Unlike SVE, the user does not have to specify lanes |
| The vector type is picked by `vtype.width`: 256 → `__m256*`, 128 → `__m128*`, wider raises `MaterializationError` | width 256 → LMUL `m1`; width 128 → `mf2`, only if SEW ≤ 32 (the ELEN = 64 rule); anything else raises. **No m2/m4.** |
| No predicates. Loops are peel + `block_loop(L)` + `simd(L)` + a scalar remainder | Unchanged. Every intrinsic takes `vl` = the **literal lane count**. At VLEN = 256, lanes == VLMAX for every legal type |
| Only `Fp` and `SInt` element types (`intrin_suffix` raises on others) | Only `f`/`i` suffixes. UInt, Fp16, and bool raise |
| Ops handled: Broadcast, Horizontal, Add, Sub, Mul, Div, Cast | The same op set. Integer Mul/Div map natively to `vmul`/`vdiv` |
| Constant vectors come from `_mm256_set_*(...)` | `pystencils::runtime::rvv::set_<sfx>(...)` helper in `rvv.hpp` (stack array + `vle`). All-equal constants use `vfmv_v_f`/`vmv_v_x` |
| Reductions go through header helpers `_mm256_horizontal_<op>_<sfx>(dst, v)` | `pystencils::runtime::rvv::horizontal_<op>_<sfx>(dst, v)` in `rvv.hpp`. Each one stores to the stack and runs a scalar loop, so all 4 ops share one code shape |
| Math: sqrt, min, max, abs; floor/ceil up to 256 bits; transcendentals raise | sqrt → `vfsqrt`, min/max → `vfmin`/`vfmax`/`vmin`/`vmax`, abs → `vfabs`, integer abs → `vmax(x, vneg(x))`. Floor/ceil and transcendentals raise |
| A strided load is a gather; a strided store needs AVX-512 | Native `vlse`/`vsse` with a byte stride, which is simpler than a gather |
| RNG uses `_common_rng_engine_intrinsic(namespace="x86")` and `__m256x4` structs | `namespace="rvv"` with RVV tuple types `vfloat32m1x4_t`/`vfloat64m1x2_t`; subscript → `__riscv_vget` |
| JIT flag `-march=x86-64-v3`; no runtime CPU check | `-march=rv64gcv_zvl256b`. `rvv.hpp` checks `__riscv_v_min_vlen >= 256` and raises `#error` otherwise. The precondition **hardware VLEN ≥ 256** is documented. **No** `-mrvv-vector-bits`, because that flag assumes VLEN == 256 exactly |

## 3. Implementation steps

### Step 0: scripts (repo root)

- `push.to.sh`: replace zip + `rm -rf` + unzip (333 MB, because it includes `.venv-rvv` and
  `.git`) with `rsync -az --delete` and excludes (`.git`, `.venv-rvv`, `__pycache__`,
  `.idea`, `scripts/.perfcache`, `*.zip`) into `bananapi:/home/bananapi/saleh/my-e4-ws/`.
  Pushes then become incremental. Delete the stale `/home/bananapi/saleh/my-e4-ws.zip`; it is
  our own artifact and the board has only 2.8 GB free.
- `test.on.bananapi.sh`: keep it and add `NO_PUSH=1` to skip the push.
- New `run.on.bananapi.sh <cmd…>`: push, then run an arbitrary command in the remote repo root
  with the venv Python and `PYTHONPATH=submodules/pystencils/src`. It is used for the LBM
  scripts and the walberla build.

### Step 1: strip the VLA/LMUL machinery (pystencils)

Restore these files to upstream `20d7dcf0` with
`git restore --source=20d7dcf0 --worktree -- <file>`. This touches only the worktree and
stages nothing:

- `backend/functions.py`
- `backend/kernelcreation/typification.py`
- `backend/platforms/generic_cpu.py`
- `backend/transformations/axis_expansion.py`
- `codegen/cpu_loop_strategies.py`
- `codegen/config.py`
- `codegen/__init__.py`
- `tests/fixtures.py`
- `tests/kernelcreation/test_rng.py`

Simplify these by hand:

- `codegen/target.py`
  - Keep `_RISCV`, `_RVV`, and `RISCV_RVV`, with a short docstring.
  - `default_vector_lanes`: `Target.RISCV_RVV → 256 // bits`, the same as AVX.
  - Replace the two detection helpers with one small `_riscv_has_rvv()`. It reads the
    `/proc/cpuinfo` `isa` line and looks for the single-letter `v` before the first `_`.
    The device-tree fallback goes away.
- `codegen/driver.py`: `elif self._target == Target.RISCV_RVV: return RvvCpu(self._ctx)`.
  The `vlen`/`mode`/`check_vlen` plumbing goes away.
- `jit/cpu/compiler_info.py`
  - Drop `rvv_vlen`, `rvv_fixed_length`, and `_synthesize_riscv_march`.
  - `Target.RISCV_RVV → ["-march=rv64gcv_zvl256b"]`.
  - `Target.CurrentCPU` on a riscv64 host resolves to `-march=rv64gcv_zvl256b` if RVV is
    detected, and to `-march=rv64gc` otherwise. This is needed because GCC 14 rejects
    `-march=native` and `CompilerInfo` defaults to `CurrentCPU`.
  - Other hosts keep `-march=native`.

### Step 2: new `backend/platforms/rvv.py` (about 350 lines, modeled 1:1 on `x86.py`)

- Module constant `RVV_VLEN = 256`. This is the single knob, with a comment explaining why it
  is hardcoded.
- `RvvCpu(GenericVectorCpu)`
  - `required_headers` adds `"pystencils_runtime/rvv.hpp"`.
  - `get_intrinsic_selector(use_builtin_convertvector=False)` raises if the flag is set,
    because sizeless RVV types cannot be used with `__builtin_convertvector`.
- `SelectIntrinsicsRvv(SelectIntrinsics)` has small helpers:
  - `_lmul(vtype)` → `"m1"` or `"mf2"`, per the table in section 2.
  - `_sfx(vtype)` → for example `f64m1` or `i32mf2`.
  - `_vtype(vtype)` → `PsCustomType("vfloat64m1_t")`.
  - `_vl(vtype)` → `PsConstant(lanes, UInt(64))`.
- The selector methods:
  - `type_intrinsic`: vector types, plus short-array tuples `v…x{n}_t`.
  - `constant_intrinsic`.
  - `op_intrinsic`: Broadcast, Horizontal, Add, Sub, Mul, Div, Cast.
  - `math_func_intrinsic`.
  - `vector_load` / `vector_store`: contiguous and strided.
  - `rng_engine_intrinsic`: `_common_rng_engine_intrinsic(namespace="rvv")`.
  - `subscript_intrinsic`: `__riscv_vget_v_…`.
- Casts use a single-step table. Legal widths are only 128 and 256 bits, so source and
  destination differ by at most 2×. Each case is one intrinsic `__riscv_<op>_<dst_sfx>(src, vl)`:

  | Width change | Intrinsics |
  |---|---|
  | same width | `vfcvt_rtz_x_f_v` (`_rtz_` matches C truncation), `vfcvt_f_x_v` |
  | widen | `vfwcvt_f_f_v`, `vsext_vf2`, `vfwcvt_f_x_v`, `vfwcvt_rtz_x_f_v` |
  | narrow | `vfncvt_f_f_w`, `vncvt_x_x_w`, `vfncvt_f_x_w`, `vfncvt_rtz_x_f_w` |

- From the old file, keep only the naming idea and the load/store/cast intrinsic spellings
  that were verified on hardware. Drop:
  - LMUL > 1 and LMUL fractions other than mf2,
  - the VLA active-lanes stack,
  - D8 guard emission,
  - D14 folding,
  - `vid`/slide chains,
  - inline reduction IR.

### Step 3: rewrite `include/pystencils_runtime/rvv.hpp` (about 120 lines)

- `#include <riscv_vector.h>`, then
  `#if !defined(__riscv_v_min_vlen) || __riscv_v_min_vlen < 256` → `#error` with a message
  that points at `-march=rv64gcv_zvl256b`.
- `set_<sfx>(vals...)`: a variadic template, generated by one macro for each legal type:
  i8, i16, and i32 at m1 and mf2; i64m1; f32 at m1 and mf2; f64m1.
- `horizontal_{add,mul,min,max}_{f64m1,f32m1,f32mf2}(dst, v)`: `vse` to a stack array, then a
  scalar loop. The loop is ordered, so the semantics match scalar code exactly. Reductions run
  only once per kernel call.
- `random::philox_float32(vint32m1_t ×4, key0, key1) → vfloat32m1x4_t`:
  1. reinterpret the counters to u32,
  2. call `detail::philox_float4`,
  3. pack the results with `__riscv_vcreate_v_f32m1x4`.
- `random::philox_float64(vint64m1_t ×4, …) → vfloat64m1x2_t`, mirroring x86's 64→32 packing:
  1. `vncvt` the counters to u32mf2,
  2. `vlmul_ext` them to m1,
  3. call `detail::philox_double2(…, r0, ignore, r1, ignore)`.
- At VLEN = 256, the Philox kernels' `vsetvlmax_e32m1()` == 8 == lanes, so no lane check is
  needed.
- If `vcreate` is unavailable on GCC 14.2, fall back to `vset` on `vundefined`.

### Step 4: tests (pystencils)

- `tests/nbackend/test_vectorization.py`
  - `get_setups(RISCV_RVV)` → `(8,32)`, `(4,32)`, `(4,64)`. That is AVX's list minus `(2,64)`,
    which would need a nonexistent `vfloat64mf2_t`.
  - Include RVV in the strided-store setups.
- Add RVV cases wherever tests switch on the target, mirroring AVX/SVE:
  - `tests/nbackend/test_cpu_axes.py::_make_kernel` → `RvvCpu(ctx)`.
  - `tests/kernelcreation/test_functions.py`: exclude RVV from floor/ceil, as SVE is.
  - `tests/kernelcreation/test_type_cast.py`: RVV × {int32, int64, float32, float64}².
  - `tests/kernelcreation/test_domain_kernels.py::inspect_kernel`: assert `__riscv_vle64`/`__riscv_vle32`
    is present.
- Rewrite the three RVV test files:
  - `tests/nbackend/test_rvv_target.py` stays small: detection parsing, default lanes, JIT flags.
  - `test_rvv_codegen.py` runs on x86. It checks:
    - the type/LMUL table, and that illegal types raise;
    - intrinsic names for ops, casts, loads/stores, reductions, constants, and RNG;
    - `test_generated_code_compiles`: a syntax-only compile of emitted kernels. It uses
      `riscv64-linux-gnu-g++ -march=rv64gcv_zvl256b` locally if present, native `g++` on the
      board, and skips otherwise.
  - `test_rvv_execution.py` runs on the board only. It checks:
    - RNG parity: RVV output must match GenericCPU output bit-exactly. This replaces
      `test_rng`, which skips on the board because `randomgen` is not installed;
    - the truncation cast `-1.5 → -1`.

### Step 5: LBM harness (repo root)

- `python/learn-lb-pystencil/lb-pystencils.py`
  - Drop `--mode`, `--vlen`, `--lanes`, and `--vector-bits`.
  - `--target rvv` → `Target.RISCV_RVV` with `vectorize.enable` and
    `assume_inner_stride_one`, using the default lanes.
  - `_make_jit` uses `GccInfo`/`ClangInfo(target=RISCV_RVV)`.
- `scripts/lbm_rvv_check.py`: the same simplification, comparing generic vs rvv for f64 and f32.
- `rvv_vlen_sweep.py`, `run_vlen_sweep.sh`, `rvv_perf_probe.py`, and `rvv_roofline.py` stay
  untouched. They are marked as legacy because they use the VLA-era API.

### Step 6: walberla (in place on `rvv-support`)

- Restore `CMakeLists.txt`, `sweepgen/cmake/SweepgenConfig.template.py`, and
  `sweepgen/src/sweepgen/build_config.py` to upstream `0c8ed8c9`. No new options are needed: as
  on x86, `WALBERLA_OPTIMIZE_FOR_LOCALHOST` → `Target.CurrentCPU`, which pystencils resolves to
  `RISCV_RVV`.
- `cmake/compileroptions/GNU.cmake` and `Clang.cmake`: under `WALBERLA_OPTIMIZE_FOR_LOCALHOST`,
  when `CMAKE_SYSTEM_PROCESSOR` is riscv64, use `-march=rv64gcv_zvl256b` instead of
  `-march=native`. Remove the fork's RVV block.
- Board build attempt (time-boxed):
  1. Use the build dir `/home/bananapi/saleh/walberla-build`, which is outside the synced repo.
  2. Configure with `WALBERLA_ENABLE_V8CORE=ON WALBERLA_ENABLE_SWEEPGEN=ON
     WALBERLA_SWEEPGEN_MANAGED_VENV=OFF WALBERLA_OPTIMIZE_FOR_LOCALHOST=ON WALBERLA_BUILD_TESTS=ON`.
  3. Use the board venv's Python with `PYTHONPATH` pointing at our pystencils.
  4. Run `pip install --no-deps pystencilssfg`, plus whatever `CheckExternalEnv.py` requires.
  5. Build and run `TestSweepGeneration`, and check that the generated sources include `rvv.hpp`.

  If dependency versions or disk space block the build, record the reason in the progress log
  and stop.

### Step 7: docs and memory

- Keep a short progress log next to this file (`rvv-vls256-only-progress-opus5.5.md`) with
  board results for each step.
- Update the agent memory note with the new direction: VLS-256, the stripped branch, `notes2`,
  and the rsync-based push.

## 4. Verification

Local (x86, `.venv-rvv`, `PYTHONPATH=submodules/pystencils/src`):

- `pytest -o addopts='' tests/nbackend/test_rvv_target.py tests/nbackend/test_rvv_codegen.py`.
  This covers codegen plus a local cross-compile with GCC 16 for riscv64.
- `tests/nbackend/test_vectorization.py` and `tests/test_quicktests.py`, to show that the strip
  did not break the x86 paths.

Board (`bash test.on.bananapi.sh …`, native GCC 14.2, with spot checks using Clang 18):

- `tests/nbackend/test_rvv_*.py tests/nbackend/test_vectorization.py tests/nbackend/test_cpu_axes.py`
- `tests/kernelcreation/{test_type_cast,test_reduction,test_functions,test_iteration_slices,test_domain_kernels}.py`
- `tests/test_quicktests.py tests/jit/test_cpujit.py`
- Then one full `tests/` run in the background, with pass/fail counts recorded in the progress
  log.
- LBM:
  - `run.on.bananapi.sh python scripts/lbm_rvv_check.py`: rvv must equal generic within f64/f32
    tolerance.
  - `lb-pystencils.py --target rvv --nx 100 --ny 100 --steps 200 --no-plot` must reproduce the
    generic `rel_l2 = 0.0338124`. Record MLUP/s for GCC and Clang.
- walberla: `TestSweepGeneration` builds and passes, or the blocker is documented.

## 5. Out of scope (possible later work)

- VLA / stripmining.
- VLEN ≠ 256.
- LMUL > 1. m2 was measured faster for the f64 collide; it is easy to add later through the
  width table.
- A runtime VLEN guard.
- D14 broadcast folding.
- The FMA peephole.
- Unsigned integers.
- fp16 / Zvfh.
- floor / ceil.
- Masked conditionals.
- `-march` synthesis from cpuinfo.
- Defaulting the JIT to Clang.

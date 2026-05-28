# walberla v7.2 — how pystencils is invoked, how ISAs are selected

Submodule pinned at [`v7.2-88-g0c8ed8c9`](https://i10git.cs.fau.de/walberla/walberla/-/tree/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837)
(`submodules/walberla/`).

All source-file links below resolve to the pinned commit
(`0c8ed8c90a3220f459a5d82868ddd66d2f1a7837`).

There are **two parallel code-generation paths** in v7.2. Both must be
understood; either may need changes for a new target.

## Path A — legacy `pystencils_walberla` (pystencils 1.x API)

Used by every codegen script under
[`submodules/walberla/apps/`](https://i10git.cs.fau.de/walberla/walberla/-/tree/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/apps).

### Flow

1. **CMake** — [`submodules/walberla/cmake/waLBerlaHelperFunctions.cmake:41-112`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/cmake/waLBerlaHelperFunctions.cmake#L41-112)
   `waLBerla_generate_target_from_python()`:
   - Packs CMake vars into JSON
     (`WALBERLA_OPTIMIZE_FOR_LOCALHOST`, `WALBERLA_DOUBLE_ACCURACY`,
     `WALBERLA_BUILD_WITH_{MPI,CUDA,HIP,OPENMP}`, `CODEGEN_CFG`).
   - Invokes `${Python_EXECUTABLE} ${sourceFile} -f <out> -c <jsonVars>`.
2. **Python entry** — [`submodules/walberla/python/pystencils_walberla/cmake_integration.py`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/python/pystencils_walberla/cmake_integration.py)
   - `CodeGeneration` at [`cmake_integration.py:30-67`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/python/pystencils_walberla/cmake_integration.py#L30-67)
     is a context manager that argparse-parses `-f` and `-c` and yields a `CodeGenerationContext`.
   - `CodeGenerationContext` at [`cmake_integration.py:69-85`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/python/pystencils_walberla/cmake_integration.py#L69-85)
     exposes `optimize_for_localhost`, `gpu = cuda or hip`, `openmp`,
     `double_accuracy`, `mpi`, `codegen_cfg`.
3. **Config builder** — [`submodules/walberla/python/pystencils_walberla/utility.py:91-146`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/python/pystencils_walberla/utility.py#L91-146)
   `config_from_context(ctx, target=Target.CPU, ...)`:
   - Validates GPU target vs `ctx.gpu`.
   - Default dtype from `ctx.double_accuracy`.
   - OpenMP from `ctx.openmp`.
   - Calls `get_vectorize_instruction_set(ctx)` at
     [`utility.py:70-88`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/python/pystencils_walberla/utility.py#L70-88)
     which calls `pystencils.backends.simd_instruction_sets.get_supported_instruction_sets()`
     and returns the **last** entry (newest available) as a string
     (`'sse'`, `'avx'`, `'avx2'`, `'avx512'`, `'neon'`, ...).
   - Builds `cpu_vectorize_info = {'instruction_set': <str>, 'assume_inner_stride_one': True, 'assume_aligned': False, 'nontemporal': False, 'assume_sufficient_line_padding': False}`.
   - Returns `pystencils.CreateKernelConfig(target=..., cpu_vectorize_info=..., ...)`.
4. **Codegen entry points** —
   [`sweep.py`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/python/pystencils_walberla/sweep.py),
   [`pack_info.py`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/python/pystencils_walberla/pack_info.py),
   [`boundary.py`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/python/pystencils_walberla/boundary.py)
   under `submodules/walberla/python/pystencils_walberla/` consume the config
   and call `pystencils.create_kernel(...)`.

### API mismatch warning

[`submodules/walberla/python/pystencils_walberla/utility.py:7`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/python/pystencils_walberla/utility.py#L7)
imports `from pystencils.backends.simd_instruction_sets`. That module path is
**pystencils 1.x** (`backends` plural). The 2.0b1 submodule renamed
`backends` → `backend` (singular) and moved ISA selection onto the `Target`
enum. The bundled `pystencils_walberla` package **will not work unmodified
against the 2.0b1 submodule** — it presumes a 1.x pystencils on `PYTHONPATH`.
Any RVV plumbing in Path A would have to either patch this bridge or stay on 1.x.

### Example codegen scripts under `submodules/walberla/apps/`

- [`submodules/walberla/apps/tutorials/codegen/HeatEquationKernel.py`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/apps/tutorials/codegen/HeatEquationKernel.py)
  — minimal.
- [`submodules/walberla/apps/tutorials/codegen/03_AdvancedLBMCodegen.py:63`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/apps/tutorials/codegen/03_AdvancedLBMCodegen.py#L63)
  — `target = ps.Target.GPU if ctx.gpu else ps.Target.CPU`.
- [`submodules/walberla/apps/benchmarks/FluidParticleCoupling/GeneratedLBMWithForce.py:30`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/apps/benchmarks/FluidParticleCoupling/GeneratedLBMWithForce.py#L30)
  — `cpu_vectorize_info = {'instruction_set': get_vectorize_instruction_set(ctx)}`.

## Path B — new `sweepgen` (pystencils 2.0 API)

[`submodules/walberla/sweepgen/`](https://i10git.cs.fau.de/walberla/walberla/-/tree/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/sweepgen)
— newer module, 2.0-aligned. This is the one to target for new work.

- [`submodules/walberla/sweepgen/src/sweepgen/build_config.py:5`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/sweepgen/src/sweepgen/build_config.py#L5)
  imports `Target` directly from pystencils.
- `WalberlaBuildConfig.target` property at
  [`build_config.py:91-115`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/sweepgen/src/sweepgen/build_config.py#L91-115)
  returns a `Target` enum value:
  ```python
  if self.override.target is not None: target = self.override.target
  elif self.cuda_enabled: target = Target.CUDA
  elif self.hip_enabled:  target = Target.HIP
  elif self.optimize_for_localhost: target = Target.CurrentCPU
  else: target = Target.GenericCPU
  ```

For a new CPU target like RVV the natural extension point is **here** — read a
new CMake var, return the matching `Target.RISCV_RVV_*`.

## CMake side — ISA detection

Walberla itself does very little ISA detection; it delegates to the compiler
(`-march=native`) and to pystencils' auto-detect.

- [`submodules/walberla/CMakeLists.txt:96`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/CMakeLists.txt#L96)
  exposes `WALBERLA_OPTIMIZE_FOR_LOCALHOST` (default ON).
- [`submodules/walberla/cmake/compileroptions/GNU.cmake:22-24`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/cmake/compileroptions/GNU.cmake#L22-24)
  and
  [`submodules/walberla/cmake/compileroptions/Clang.cmake:15-22`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/cmake/compileroptions/Clang.cmake#L15-22)
  append `-march=native` when the option is set. Apple Clang on arm64 is
  special-cased to skip `-march`.
- [`submodules/walberla/cmake/compileroptions/GNU.cmake:26-32`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/cmake/compileroptions/GNU.cmake#L26-32)
  and
  [`submodules/walberla/cmake/compileroptions/Clang.cmake:24-32`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/cmake/compileroptions/Clang.cmake#L24-32)
  probe `/proc/sys/abi/sve_default_vector_length` and emit
  `-msve-vector-bits=<N>` if SVE is the host ISA. This is the **only**
  explicit ISA-specific CMake logic.
- No AVX/AVX2/AVX-512/NEON detection at the CMake level; pystencils handles
  that on the codegen side via `get_supported_instruction_sets()`.

CMake → Python codegen JSON blob:
[`submodules/walberla/cmake/waLBerlaHelperFunctions.cmake:72-80`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/cmake/waLBerlaHelperFunctions.cmake#L72-80).
To plumb a new ISA option through to codegen, add a key here.

## No RISC-V references anywhere in walberla v7.2

`grep -rn 'riscv\|rvv\|vlen\|vsetvli\|RISCV' submodules/walberla/` returns
nothing.

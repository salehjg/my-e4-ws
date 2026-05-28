# walberla v7.2 — how pystencils is invoked, how [ISAs](#isa) are selected

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

1. **[CMake](#cmake)** — [`submodules/walberla/cmake/waLBerlaHelperFunctions.cmake:41-112`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/cmake/waLBerlaHelperFunctions.cmake#L41-112)
   `waLBerla_generate_target_from_python()`:
   - Packs [CMake](#cmake) vars into JSON
     (`WALBERLA_OPTIMIZE_FOR_LOCALHOST`, `WALBERLA_DOUBLE_ACCURACY`,
     `WALBERLA_BUILD_WITH_{`[`MPI`](#mpi)`,`[`CUDA`](#cuda)`,`[`HIP`](#hip)`,OPENMP}`, `CODEGEN_CFG`).
     The `OPENMP` slot corresponds to [OpenMP](#openmp).
   - Invokes `${Python_EXECUTABLE} ${sourceFile} -f <out> -c <jsonVars>`.
2. **Python entry** — [`submodules/walberla/python/pystencils_walberla/cmake_integration.py`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/python/pystencils_walberla/cmake_integration.py)
   - `CodeGeneration` at [`cmake_integration.py:30-67`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/python/pystencils_walberla/cmake_integration.py#L30-67)
     is a context manager that argparse-parses `-f` and `-c` and yields a `CodeGenerationContext`.
   - `CodeGenerationContext` at [`cmake_integration.py:69-85`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/python/pystencils_walberla/cmake_integration.py#L69-85)
     exposes `optimize_for_localhost`, `gpu = cuda or hip` (i.e. [GPU](#gpu),
     [CUDA](#cuda), [HIP](#hip)), `openmp` ([OpenMP](#openmp)),
     `double_accuracy`, `mpi` ([MPI](#mpi)), `codegen_cfg`.
3. **Config builder** — [`submodules/walberla/python/pystencils_walberla/utility.py:91-146`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/python/pystencils_walberla/utility.py#L91-146)
   `config_from_context(ctx, target=Target.CPU, ...)`:
   - Validates [GPU](#gpu) target vs `ctx.gpu`.
   - Default dtype from `ctx.double_accuracy`.
   - [OpenMP](#openmp) from `ctx.openmp`.
   - Calls `get_vectorize_instruction_set(ctx)` at
     [`utility.py:70-88`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/python/pystencils_walberla/utility.py#L70-88)
     which calls `pystencils.backends.simd_instruction_sets.get_supported_instruction_sets()`
     and returns the **last** entry (newest available) as a string
     (`'sse'`, `'avx'`, `'avx2'`, `'avx512'`, `'neon'`, ...) — corresponding
     to [SSE](#sse), [AVX](#avx), [AVX2](#avx), [AVX-512](#avx-512),
     [NEON](#neon).
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
`backends` → `backend` (singular) and moved [ISA](#isa) selection onto the
`Target` enum. The bundled `pystencils_walberla` package **will not work
unmodified against the 2.0b1 submodule** — it presumes a 1.x pystencils on
`PYTHONPATH`. Any [RVV](#rvv) plumbing in Path A would have to either patch
this bridge or stay on 1.x.

### Example codegen scripts under `submodules/walberla/apps/`

- [`submodules/walberla/apps/tutorials/codegen/HeatEquationKernel.py`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/apps/tutorials/codegen/HeatEquationKernel.py)
  — minimal.
- [`submodules/walberla/apps/tutorials/codegen/03_AdvancedLBMCodegen.py:63`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/apps/tutorials/codegen/03_AdvancedLBMCodegen.py#L63)
  — `target = ps.Target.GPU if ctx.gpu else ps.Target.CPU` (selects
  [GPU](#gpu) when the [CUDA](#cuda)/[HIP](#hip) build is on).
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
  Branches map to [CUDA](#cuda) and [HIP](#hip) [GPU](#gpu) backends.

For a new CPU target like [RVV](#rvv) the natural extension point is
**here** — read a new [CMake](#cmake) var, return the matching
`Target.RISCV_RVV_*`.

## CMake side — [ISA](#isa) detection

Walberla itself does very little [ISA](#isa) detection; it delegates to the
compiler (`-march=native`) and to pystencils' auto-detect.

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
  `-msve-vector-bits=<N>` (where `N` pins the [SVE](#sve) [VLEN](#vlen)) if
  [SVE](#sve) is the host [ISA](#isa). This is the **only** explicit
  [ISA](#isa)-specific [CMake](#cmake) logic.
- No [AVX](#avx)/[AVX2](#avx)/[AVX-512](#avx-512)/[NEON](#neon) detection at
  the [CMake](#cmake) level; pystencils handles that on the codegen side via
  `get_supported_instruction_sets()`.

[CMake](#cmake) → Python codegen JSON blob:
[`submodules/walberla/cmake/waLBerlaHelperFunctions.cmake:72-80`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/cmake/waLBerlaHelperFunctions.cmake#L72-80).
To plumb a new [ISA](#isa) option through to codegen, add a key here.

## No RISC-V references anywhere in walberla v7.2

`grep -rn 'riscv\|rvv\|vlen\|vsetvli\|RISCV' submodules/walberla/` returns
nothing.

---

## Glossary

Definitions for terms used in this file. All terms above link here.

<a id="isa"></a>
**ISA** — *Instruction Set Architecture*. The set of machine instructions a
processor implements (e.g. x86, ARMv8, RISC-V) and, by extension, vector
sub-extensions like [SSE](#sse) / [AVX](#avx) / [NEON](#neon) /
[SVE](#sve) / [RVV](#rvv).

<a id="sse"></a>
**SSE** — *Streaming SIMD Extensions*. Intel/AMD's 128-bit fixed-width
vector [ISA](#isa) family (SSE, SSE2, SSE3, SSSE3, SSE4.1/4.2). Targeted
by pystencils via `Target.X86_SSE`.

<a id="avx"></a>
**AVX** / **AVX2** — *Advanced Vector Extensions*. Intel/AMD's 256-bit
fixed-width vector [ISA](#isa). AVX2 (2013) extended AVX with integer ops;
both operate on 256-bit registers. Targeted by pystencils via
`Target.X86_AVX`.

<a id="avx-512"></a>
**AVX-512** — Intel/AMD's 512-bit vector [ISA](#isa). Adds opmask
registers, embedded broadcast, and gather/scatter. Targeted by pystencils
via `Target.X86_AVX512` and `Target.X86_AVX512_FP16`.

<a id="neon"></a>
**NEON** — ARM's 64/128-bit fixed-width SIMD [ISA](#isa), mandatory on
AArch64. Targeted by pystencils via `Target.ARM_NEON` /
`Target.ARM_NEON_FP16`.

<a id="sve"></a>
**SVE** — *Scalable Vector Extension*. ARM's length-agnostic vector
[ISA](#isa); vector register width ([VLEN](#vlen)) is implementation-defined
and programs use predicated instructions that work at any width. Targeted
by pystencils via `Target.ARM_SVE`.

<a id="rvv"></a>
**RVV** — *RISC-V Vector extension*. The `V` extension of the RISC-V
[ISA](#isa); a scalable vector [ISA](#isa) conceptually similar to
[SVE](#sve). Not currently supported by pystencils 2.0b1.

<a id="vlen"></a>
**VLEN** — *Vector Register Length*, in bits. Implementation-defined width
of one [SVE](#sve) or [RVV](#rvv) vector register. Must be a power of two.
Pinned at build time by `-msve-vector-bits=<N>` on [SVE](#sve), and (when a
walberla [RVV](#rvv) backend exists) would be pinned analogously via
`-mrvv-vector-bits=<N>`.

<a id="cmake"></a>
**CMake** — Cross-platform build-system generator used by walberla and
pystencils. Drives the codegen by passing build-time configuration
(architecture, parallelism backends, accuracy) to the Python codegen scripts
via a JSON blob.

<a id="openmp"></a>
**OpenMP** — *Open Multi-Processing*. Standard API for shared-memory
parallelism on CPUs, primarily via `#pragma omp`. Enabled in walberla by
`WALBERLA_BUILD_WITH_OPENMP=ON`; passed through to pystencils as the
`cpu_openmp` config knob.

<a id="mpi"></a>
**MPI** — *Message Passing Interface*. Standard API for distributed-memory
parallelism. Enabled in walberla by `WALBERLA_BUILD_WITH_MPI=ON`.

<a id="gpu"></a>
**GPU** — *Graphics Processing Unit*. Massively parallel co-processor used
for offload via [CUDA](#cuda) or [HIP](#hip). Selected in pystencils via
`Target.GPU` (legacy) or `Target.CUDA` / `Target.HIP` (sweepgen).

<a id="cuda"></a>
**CUDA** — *Compute Unified Device Architecture*. NVIDIA's [GPU](#gpu)
programming environment. Enabled in walberla by
`WALBERLA_BUILD_WITH_CUDA=ON`.

<a id="hip"></a>
**HIP** — *Heterogeneous-compute Interface for Portability*. AMD's
[GPU](#gpu) programming environment (the ROCm front end). Enabled in
walberla by `WALBERLA_BUILD_WITH_HIP=ON`.

# pystencils 2.0b1 CPU vector backends — reference

Submodule pinned at [`release/2.0b1-2-g20d7dcf`](https://i10git.cs.fau.de/pycodegen/pystencils/-/tree/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f)
(`submodules/pystencils/`).

All source-file links below resolve to the pinned commit
(`20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f`).

## Target enum

Authoritative source: [`submodules/pystencils/src/pystencils/codegen/target.py:42-112`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/codegen/target.py#L42-112).

`Target` is a `Flag` enum built from private composable flags (`_CPU`, `_VECTOR`,
`_X86`, `_SSE`, `_AVX`, `_AVX512`, `_FP16`, `_ARM`, `_NEON`, `_SVE`, `_VL`,
`_Automatic`). Public CPU targets:

| Target              | Width                       | Backend platform                                                                                                                                                            |
|---------------------|-----------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `GenericCPU`        | scalar (+[OpenMP](#openmp)) | [`submodules/pystencils/src/pystencils/backend/platforms/generic_cpu.py`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/generic_cpu.py) |
| `CurrentCPU`        | auto-detect                 | resolved at codegen time                                                                                                                                                    |
| `X86_SSE`           | 128 b                       | [`submodules/pystencils/src/pystencils/backend/platforms/x86.py`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/x86.py) ([SSE](#sse))   |
| `X86_AVX`           | 256 b                       | [`submodules/pystencils/src/pystencils/backend/platforms/x86.py`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/x86.py) ([AVX](#avx))   |
| `X86_AVX512`        | 512 b                       | [`submodules/pystencils/src/pystencils/backend/platforms/x86.py`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/x86.py) ([AVX-512](#avx-512)) |
| `X86_AVX512_FP16`   | 512 b + [FP16](#fp16)       | [`submodules/pystencils/src/pystencils/backend/platforms/x86.py`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/x86.py) ([AVX-512](#avx-512)+[FP16](#fp16)) |
| `ARM_NEON`          | 64/128 b                    | [`submodules/pystencils/src/pystencils/backend/platforms/neon.py`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/neon.py) ([NEON](#neon))               |
| `ARM_NEON_FP16`     | 64/128 b + [FP16](#fp16)    | [`submodules/pystencils/src/pystencils/backend/platforms/neon.py`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/neon.py) ([NEON](#neon)+[FP16](#fp16))        |
| `ARM_SVE`           | scalable                    | [`submodules/pystencils/src/pystencils/backend/platforms/sve.py`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py) ([SVE](#sve))   |

`Target.default_vector_lanes(dtype)` at
[`submodules/pystencils/src/pystencils/codegen/target.py:135-155`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/codegen/target.py#L135-155)
returns width/itemsize for fixed-width [ISAs](#isa) and **raises `CodegenError` for `ARM_SVE`** —
[SVE](#sve) forces the user to specify a [lane](#lane) count explicitly.
Auto-detect logic at
[`submodules/pystencils/src/pystencils/codegen/target.py:209-279`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/codegen/target.py#L209-279)
probes `cpuinfo` plus platform-specific queries.

## Platform classes

Base: [`submodules/pystencils/src/pystencils/backend/platforms/platform.py:15`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/platform.py#L15)
`Platform` — abstract `required_headers`, `select_function`, optional
`materialize_iteration_space`, `resolve_reduction`, `_select_integer_function`.

Vector base: [`submodules/pystencils/src/pystencils/backend/platforms/generic_cpu.py:167`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/generic_cpu.py#L167)
`GenericVectorCpu(GenericCpu)` adds abstract `get_intrinsic_selector() -> SelectIntrinsics`.

Each platform implements `SelectIntrinsics*` that maps [IR](#ir) nodes
(`PsAdd`, `PsLoad`, `PsStore`, `PsBroadcast` ([broadcast](#broadcast)),
math fns, [gather](#gather)/[scatter](#scatter),
[horizontal reductions](#horizontal-reduction)) to the [ISA's](#isa)
[intrinsics](#intrinsic) and emits the right header via
`required_headers = {'"pystencils_runtime/<isa>.hpp"'}`.

### x86 — [`submodules/pystencils/src/pystencils/backend/platforms/x86.py`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/x86.py)

- `X86VectorArch` enum at [`x86.py:42-113`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/x86.py#L42-113):
  `SSE=128`, `AVX=256`, `AVX512=512`, `AVX512_FP16=513`. Encodes
  [SSE](#sse), [AVX](#avx), [AVX-512](#avx-512), and [AVX-512](#avx-512)+[FP16](#fp16).
  Helpers `intrin_prefix()` (`_mm`/`_mm256`/`_mm512`), `intrin_suffix()`
  (`ps`/`pd`/`epi32`/...), `intrin_type()` (`__m128`/`__m256i`/...).
- `X86VectorCpu` at [`x86.py:115-142`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/x86.py#L115-142),
  `SelectIntrinsicsX86` at [`x86.py:144-644`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/x86.py#L144-644).
- Load: `_mm{,256,512}_loadu_*` packed; `_mm*_i32gather_*` for
  [strided](#stride)/[gather](#gather). Store dual.
  [Broadcast](#broadcast) via `_mm*_set1_*`.
- No [predication](#predicate) exposed ([mask](#mask) registers used
  internally on [AVX-512](#avx-512) only).
- Header: `"pystencils_runtime/x86.hpp"`.

### NEON — [`submodules/pystencils/src/pystencils/backend/platforms/neon.py`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/neon.py)

- `NeonCpu(enable_fp16: bool)` at [`neon.py:43-72`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/neon.py#L43-72)
  ([FP16](#fp16) opt-in); `SelectIntrinsicsNeon` at
  [`neon.py:102-426`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/neon.py#L102-426).
- Types `int32x4_t` etc.; Q-suffix selection for 128-bit vs 64-bit.
- **No [strided](#stride) / [gather](#gather) support** —
  [`neon.py:202-205`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/neon.py#L202-205)
  raises.
- [Horizontal reduction](#horizontal-reduction): `vaddvq_*`, `vminvq_*`.
- Header: `"pystencils_runtime/neon.hpp"`.

### SVE — [`submodules/pystencils/src/pystencils/backend/platforms/sve.py`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py)

See companion note: [`sve-strategy-for-scalable-vectors.md`](sve-strategy-for-scalable-vectors.md).

The only existing scalable-vector backend. Worth reading in full before any
[RVV](#rvv) work because its design choices (fixed [lane](#lane) count +
entry-time [predicate](#predicate), not true [VLA](#vla)) are the
load-bearing pattern for any scalable [ISA](#isa) in pystencils.

## Driver and [JIT](#jit) flag mapping

- Platform selection:
  [`submodules/pystencils/src/pystencils/codegen/driver.py:399`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/codegen/driver.py#L399)
  `_get_platform()` branches on Target flags and constructs the right platform instance.
- `-march` flags:
  [`submodules/pystencils/src/pystencils/jit/cpu/compiler_info.py:97-126`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/jit/cpu/compiler_info.py#L97-126)
  - `X86_SSE` → `-march=x86-64-v2` ([SSE](#sse))
  - `X86_AVX` → `-march=x86-64-v3` ([AVX](#avx))
  - `X86_AVX512[_FP16]` → `-march=x86-64-v4`(`+ -mavx512fp16`) ([AVX-512](#avx-512), optional [FP16](#fp16))
  - `ARM_NEON` → `-march=armv8-a` ([NEON](#neon))
  - `ARM_NEON_FP16` → `-march=armv8.2-a+fp16` ([NEON](#neon)+[FP16](#fp16))
  - `ARM_SVE` → `-march=armv8.2-a+sve` ([SVE](#sve))
  - `CurrentCPU` → `-march=native`

## Existing RISC-V footprint

No backend platform, no `Target` entry. The only RISC-V code is:

- [`submodules/pystencils/src/pystencils/include/pystencils_runtime/bits/philox_rand.h:70`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/include/pystencils_runtime/bits/philox_rand.h#L70)
  and [`:915-1060`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/include/pystencils_runtime/bits/philox_rand.h#L915-1060)
  — hand-written [RVV](#rvv)-1.0 Philox kernels using `__riscv_*`
  [intrinsics](#intrinsic) at [LMUL](#lmul)=1
  (`__riscv_vmul_vv_u32m1`, `__riscv_vsetvlmax_e32m1`, ...).
- [`submodules/pystencils/src/pystencils/include/riscv_v_helpers.h:33`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/include/riscv_v_helpers.h#L33)
  and [`:74`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/include/riscv_v_helpers.h#L74)
  — `cbo.zero` via `__riscv_zicboz` (not vectorization).

These exist only in the runtime headers; nothing in the codegen pipeline
generates RISC-V [intrinsics](#intrinsic) today.

---

## Glossary

Definitions for terms used in this file. All terms above link here.

<a id="isa"></a>
**ISA** — *Instruction Set Architecture*. The set of machine instructions a
processor implements, including vector sub-extensions like [SSE](#sse) /
[AVX](#avx) / [NEON](#neon) / [SVE](#sve) / [RVV](#rvv).

<a id="sse"></a>
**SSE** — *Streaming SIMD Extensions*. Intel/AMD's 128-bit fixed-width
vector [ISA](#isa) family. Targeted by pystencils via `Target.X86_SSE`.

<a id="avx"></a>
**AVX** — *Advanced Vector Extensions*. Intel/AMD's 256-bit fixed-width
vector [ISA](#isa). AVX2 (2013) extended it with integer ops. Targeted via
`Target.X86_AVX`.

<a id="avx-512"></a>
**AVX-512** — 512-bit Intel/AMD vector [ISA](#isa). Adds opmask registers,
embedded broadcast, and gather/scatter. Targeted via `Target.X86_AVX512` /
`Target.X86_AVX512_FP16`.

<a id="neon"></a>
**NEON** — ARM's 64/128-bit fixed-width SIMD [ISA](#isa), mandatory on
AArch64. Targeted via `Target.ARM_NEON` / `Target.ARM_NEON_FP16`.

<a id="sve"></a>
**SVE** — *Scalable Vector Extension*. ARM's length-agnostic vector
[ISA](#isa); vector register width is implementation-defined. Programs use
[predicated](#predicate) instructions that work at any width. Targeted via
`Target.ARM_SVE`.

<a id="rvv"></a>
**RVV** — *RISC-V Vector extension*. The `V` extension of the RISC-V
[ISA](#isa); a scalable vector [ISA](#isa) conceptually similar to
[SVE](#sve). Not currently supported by pystencils 2.0b1's codegen
pipeline.

<a id="fp16"></a>
**FP16** — *16-bit Floating Point* (IEEE 754 binary16). Half-precision
float format. Supported on [AVX-512](#avx-512) via the AVX512-FP16
sub-extension and on [NEON](#neon) via Armv8.2-A `+fp16`.

<a id="lmul"></a>
**LMUL** — *Length Multiplier*. [RVV](#rvv) vector register group
multiplier — combines 1..8 architectural registers (or fractional groups
1/2, 1/4, 1/8 in RVV-1.0) into one logical operand. The Philox runtime
header uses `LMUL=m1`.

<a id="lane"></a>
**lane** — One element position within a vector register. A 256-bit
[AVX](#avx) register at f32 has 8 lanes; an [SVE](#sve) register has
implementation-defined lanes.

<a id="predicate"></a>
**predicate** — A bit-mask telling a vector op which [lanes](#lane) are
active. [SVE](#sve) uses an `svbool_t` register; [AVX-512](#avx-512) uses
k-registers; [RVV](#rvv) uses `v0` as the implicit mask register.

<a id="mask"></a>
**mask** — Same as [predicate](#predicate) in this context.

<a id="stride"></a>
**stride** — Distance (in elements or bytes) between consecutive memory
accesses. A unit-stride load reads contiguous elements; a strided load
reads every Nth.

<a id="gather"></a>
**gather** — Vector load using a vector of indices (one per [lane](#lane)).
Supported by [AVX-512](#avx-512), [SVE](#sve), and [RVV](#rvv); not by
[NEON](#neon).

<a id="scatter"></a>
**scatter** — Vector store using a vector of indices. The store-side dual
of [gather](#gather).

<a id="broadcast"></a>
**broadcast** — Replicating a scalar value to every [lane](#lane) of a
vector. `_mm256_set1_*` on x86, `svdup_n_*` on [SVE](#sve), `__riscv_v*mv_v_x_*` on [RVV](#rvv).

<a id="horizontal-reduction"></a>
**horizontal reduction** — An op that combines all [lanes](#lane) of a
vector into a scalar (sum, min, max, etc.). Examples: `vaddvq_s32`
([NEON](#neon)), `_mm_hadd_ps` ([SSE](#sse)), `vfredosum`
([RVV](#rvv)-1.0).

<a id="intrinsic"></a>
**intrinsic** — Compiler [intrinsic](#intrinsic); a C-level function that
maps one-to-one to a machine instruction. Vector backends in pystencils
emit calls to [intrinsics](#intrinsic) rather than raw assembly.

<a id="ir"></a>
**IR** — *Intermediate Representation*. A compiler's internal
representation between source code and machine code. pystencils has its
own [IR](#ir) for stencil programs.

<a id="jit"></a>
**JIT** — *Just-In-Time*. Compilation performed at program runtime rather
than build time. pystencils [JIT](#jit)-compiles generated kernels via a
small Python wrapper around the system compiler.

<a id="openmp"></a>
**OpenMP** — *Open Multi-Processing*. Standard API for shared-memory
parallelism on CPUs, primarily via `#pragma omp`. pystencils' `GenericCPU`
target can emit [OpenMP](#openmp) parallel loops.

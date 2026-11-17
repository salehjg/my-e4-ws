# Plan: add [RVV](#rvv)-0.7 and [RVV](#rvv)-1.0 support to pystencils + walberla

Companion to:
- [`pystencils-cpu-backends.md`](pystencils-cpu-backends.md) — current ISA support landscape
- [`walberla-codegen-flow.md`](walberla-codegen-flow.md) — how walberla invokes pystencils
- [`sve-strategy-for-scalable-vectors.md`](sve-strategy-for-scalable-vectors.md) — the template this plan follows
- [`rvv-isa-primer.md`](rvv-isa-primer.md) — [RVV](#rvv) terminology, [LMUL](#lmul)/[VLEN](#vlen)/[SEW](#sew), [VLA](#vla) vs [VLS](#vls), and the 0.7 → 1.0 deltas

All submodule source-file links resolve to the pinned commits:
pystencils `20d7dcf0…`, walberla `0c8ed8c9…`.

## [RVV](#rvv)-0.7 vs [RVV](#rvv)-1.0 — the part that actually matters

These are not minor revisions. [Intrinsic](#intrinsic) spelling,
[`vsetvl`](#vsetvl) semantics, and the toolchain landscape differ enough
that the backend must distinguish them.

| Aspect             | [RVV](#rvv)-0.7.1 (T-Head)                                                                               | [RVV](#rvv)-1.0 (standard)                                                          |
|--------------------|----------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------|
| Where it ships     | T-Head C906/C910 — Allwinner D1, LicheePi 4A                                                             | SiFive P670/X280, SpacemiT K1 (BPI-F3), Andes AX45MPV, mainline cores               |
| [Intrinsic](#intrinsic) prefix | `vle32_v_*`, `vfadd_vv_*` (no `__riscv_` prefix) on T-Head GCC, or `__riscv_th_*` on LLVM [`xtheadvector`](#xtheadvector) | `__riscv_vle32_v_*`, `__riscv_vfadd_vv_*` (v1.0 [intrinsic](#intrinsic) spec)        |
| vsetvl             | `vsetvl_e32m1`                                                                                           | `__riscv_vsetvl_e32m1`, `__riscv_vsetvlmax_e32m1`                                   |
| Compiler           | T-Head GCC fork (`-march=rv64gcv0p7`), or LLVM 17+ via [`xtheadvector`](#xtheadvector) ext                | mainline GCC ≥ 13 / Clang ≥ 17, `-march=rv64gcv`                                    |
| Status             | Not standardized; T-Head-specific (now reachable via LLVM [`xtheadvector`](#xtheadvector))               | Ratified, stable                                                                    |

The existing Philox kernels at
[`submodules/pystencils/src/pystencils/include/pystencils_runtime/bits/philox_rand.h:915-1060`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/include/pystencils_runtime/bits/philox_rand.h#L915-1060)
already target **[RVV](#rvv)-1.0** (the `__riscv_v` define + `__riscv_*`
prefix at [LMUL](#lmul)=1).

## Sizing

Rough estimate: ~1–2 weeks for a working [RVV](#rvv)-1.0 backend modeled on
[SVE](#sve). [RVV](#rvv)-0.7 is mostly a string-substitution layer on top,
plus a handful of semantic deltas — another few days.

## A. pystencils side

### A1. Target enum — [`submodules/pystencils/src/pystencils/codegen/target.py`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/codegen/target.py)

Add private flags `_RISCV`, `_RVV`, `_RVV_07` (or `_XTHEAD_V`), `_RVV_10`.
Add public targets:

```python
RISCV_RVV_1_0       = _CPU | _VECTOR | _RISCV | _RVV | _RVV_10
RISCV_RVV_0_7       = _CPU | _VECTOR | _RISCV | _RVV | _RVV_07
# alternatively expose as RISCV_XTHEADVECTOR for clarity
```

`default_vector_lanes()` should **raise `CodegenError`** for these, same as
`ARM_SVE` — forces explicit ([SEW](#sew), [LMUL](#lmul)) at codegen time.

Extend the auto-detect at
[`target.py:209-279`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/codegen/target.py#L209-279):
probe `/proc/cpuinfo` `isa : rv64...v` line; fall back to
`/proc/device-tree/cpus/cpu@0/riscv,isa`. Distinguish 0.7 from 1.0 by checking
for `_xthead*` ISA-string tokens or T-Head CPU model.

### A2. Platform — new `submodules/pystencils/src/pystencils/backend/platforms/rvv.py`

Model directly on
[`sve.py`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py).
Decision: **use the [SVE](#sve)-style fixed-[lane](#lane) approach** for v1
(see [`sve-strategy-for-scalable-vectors.md`](sve-strategy-for-scalable-vectors.md)
and the [VLA](#vla)-vs-[VLS](#vls) discussion in
[`rvv-isa-primer.md`](rvv-isa-primer.md)). At kernel entry emit:

```c
size_t vl = __riscv_vsetvl_e32m1(N);   // or vsetvlmax_e32m1() if N is implicit
```

and thread [`vl`](#vl) through every op as [SVE](#sve) threads its
`svbool_t` [predicate](#predicate).

Structure:

- `RvvCpu(GenericVectorCpu)` — no constructor params for v1.0 case; the
  0.7 subclass overrides [intrinsic](#intrinsic) name generation.
- `RvvSelectionContext` — caches the [`vl`](#vl) symbol per
  ([SEW](#sew), [LMUL](#lmul)) pair.
- `SelectIntrinsicsRvv(SelectIntrinsics)` — concrete mapping for
  [RVV](#rvv)-1.0.

Concrete [intrinsic](#intrinsic) mapping (f32, [LMUL](#lmul)=1,
illustrative):

| Op                              | [Intrinsic](#intrinsic)                                |
|---------------------------------|--------------------------------------------------------|
| type                            | `vfloat32m1_t` / `vint32m1_t` / ...                    |
| unit load                       | `__riscv_vle32_v_f32m1(ptr, vl)`                       |
| [strided](#stride) load         | `__riscv_vlse32_v_f32m1(ptr, stride_bytes, vl)`        |
| [gather](#gather)               | `__riscv_vluxei32_v_f32m1(ptr, idx, vl)`               |
| unit store                      | `__riscv_vse32_v_f32m1(ptr, v, vl)`                    |
| [strided](#stride) store        | `__riscv_vsse32_v_f32m1(ptr, stride_bytes, v, vl)`     |
| [scatter](#scatter)             | `__riscv_vsuxei32_v_f32m1(ptr, idx, v, vl)`            |
| [broadcast](#broadcast) scalar  | `__riscv_vfmv_v_f_f32m1(s, vl)`                        |
| add                             | `__riscv_vfadd_vv_f32m1(a, b, vl)`                     |
| [FMA](#fma) (c += a*b)          | `__riscv_vfmacc_vv_f32m1(c, a, b, vl)`                 |
| reduce sum (ord)                | `__riscv_vfredosum_vs_f32m1_f32m1(x, init, vl)`        |
| sqrt                            | `__riscv_vfsqrt_v_f32m1(x, vl)`                        |
| min / max                       | `__riscv_vfmin_vv_f32m1` / `__riscv_vfmax_vv_f32m1`    |

[RVV](#rvv) peculiarities to handle in code review:

- `vfredusum` is unordered, `vfredosum` is ordered — pick `osum` for
  reproducibility parity with [SVE](#sve) / scalar.
- [Gather](#gather)/[scatter](#scatter) index is in **bytes**, not elements.
  Multiply the element index by `sizeof(elem)` when building the index
  vector (`__riscv_vmul_vx_*` or compute at codegen time).
- [Mask](#mask) register is separate from [`vl`](#vl). We only need
  [`vl`](#vl) in the fixed-[lane](#lane) design; masked ops (for boundary
  handling) are a follow-up.
- [`vsetvl`](#vsetvl) may return a smaller [`vl`](#vl) than requested if
  `N > VLMAX`. In the fixed-[lane](#lane) design we deliberately request
  `N ≤ VLMAX`, so this is benign, but assert it in tests.

Header: `required_headers = {'"pystencils_runtime/rvv.hpp"'}`.

### A3. [RVV](#rvv)-0.7 backend

Subclass `RvvCpu` and override only the [intrinsic](#intrinsic)-name builder:

- Drop the `__riscv_` prefix (T-Head GCC) **or** prepend `__riscv_th_`
  (LLVM [`xtheadvector`](#xtheadvector)) — make this a codegen-time switch.
- Adjust [`vsetvl`](#vsetvl) name and missing policy suffixes (no
  `_x`/`_tu`/`_mu` in 0.7).
- The handful of [intrinsics](#intrinsic) that 0.7 lacks (e.g. `vfredosum`
  semantics differ) get explicit fallbacks.

Start with subclassing; split into a separate file only if
[intrinsic](#intrinsic) coverage diverges materially.

### A4. Driver and [JIT](#jit) flags

- [`submodules/pystencils/src/pystencils/codegen/driver.py:399`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/codegen/driver.py#L399)
  `_get_platform()` — add `_RVV` branch returning `RvvCpu(...)` or
  `Rvv07Cpu(...)` based on `_RVV_10` vs `_RVV_07`.
- [`submodules/pystencils/src/pystencils/jit/cpu/compiler_info.py:97`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/jit/cpu/compiler_info.py#L97)
  — add:
  - `Target.RISCV_RVV_1_0` → `-march=rv64gcv` (or explicit `rv64gcv1p0`)
  - `Target.RISCV_RVV_0_7` → `-march=rv64gcv0p7` (T-Head GCC) **or**
    `-march=rv64gc_xtheadvector` (LLVM ≥ 17 — [`xtheadvector`](#xtheadvector)). Pick one and document.

### A5. Runtime header — new `submodules/pystencils/src/pystencils/include/pystencils_runtime/rvv.hpp`

Mirror `sve.hpp`. Re-export `<riscv_vector.h>` and any helper macros. The
existing Philox [RVV](#rvv) code at
[`philox_rand.h:915-1060`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/include/pystencils_runtime/bits/philox_rand.h#L915-1060)
can stay where it is — it's guarded by `#ifdef __riscv_v` and works at
[LMUL](#lmul)=1.

### A6. Tests

[`submodules/pystencils/tests/`](https://i10git.cs.fau.de/pycodegen/pystencils/-/tree/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/tests)
already parametrizes vectorization tests via a `VectorTestSetup` pattern.
Add entries mirroring the [SVE](#sve) matrix:

```python
VectorTestSetup(Target.RISCV_RVV_1_0, RvvCpu, lanes=4,  scalar_bits=32)
VectorTestSetup(Target.RISCV_RVV_1_0, RvvCpu, lanes=8,  scalar_bits=16)
VectorTestSetup(Target.RISCV_RVV_1_0, RvvCpu, lanes=2,  scalar_bits=64)
```

Without [RVV](#rvv) hardware, run under
`qemu-riscv64 -cpu rv64,v=true,vlen=128` (and larger [VLEN](#vlen) for
stress). For 0.7, `qemu-riscv64 -cpu thead-c906`.

## B. walberla side

Small footprint. Two places because of the dual codegen paths
(see [`walberla-codegen-flow.md`](walberla-codegen-flow.md)).

### B1. Old path — [`submodules/walberla/python/pystencils_walberla/utility.py`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/python/pystencils_walberla/utility.py)

Likely **skip**. The bridge already imports from the legacy
`pystencils.backends.simd_instruction_sets` module that doesn't exist in
2.0b1. Touch only if there is a specific app under
[`submodules/walberla/apps/`](https://i10git.cs.fau.de/walberla/walberla/-/tree/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/apps)
that must run on [RVV](#rvv) and that you do not intend to port to sweepgen.

### B2. New path — [`submodules/walberla/sweepgen/src/sweepgen/build_config.py`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/sweepgen/src/sweepgen/build_config.py)

Extend the `target` property at
[`build_config.py:91-115`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/sweepgen/src/sweepgen/build_config.py#L91-115):

```python
@property
def target(self) -> Target:
    if self.override.target is not None: return self.override.target
    if self.cuda_enabled: return Target.CUDA
    if self.hip_enabled:  return Target.HIP
    if self.riscv_rvv_10: return Target.RISCV_RVV_1_0
    if self.riscv_rvv_07: return Target.RISCV_RVV_0_7
    return Target.CurrentCPU if self.optimize_for_localhost else Target.GenericCPU
```

Plumb new [CMake](#cmake) vars `WALBERLA_RISCV_RVV` and
`WALBERLA_RISCV_RVV_VERSION=1.0|0.7` through the JSON blob at
[`submodules/walberla/cmake/waLBerlaHelperFunctions.cmake:72-80`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/cmake/waLBerlaHelperFunctions.cmake#L72-80).

### B3. [CMake](#cmake) compiler options

After the [SVE](#sve) detection blocks at
[`submodules/walberla/cmake/compileroptions/GNU.cmake:26-32`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/cmake/compileroptions/GNU.cmake#L26-32)
and
[`submodules/walberla/cmake/compileroptions/Clang.cmake:24-32`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/cmake/compileroptions/Clang.cmake#L24-32),
add analogous logic:

- Detect `CMAKE_SYSTEM_PROCESSOR MATCHES "riscv"` (or the cross-compiler
  triple).
- Append `-march=rv64gcv` (1.0) or `-march=rv64gcv0p7` /
  `-march=rv64gc_xtheadvector` (0.7, via [`xtheadvector`](#xtheadvector)),
  driven by a cache var.
- For GCC 14+, append `-mrvv-vector-bits=<N>` to match the [lane](#lane)
  count picked at codegen time. This pins [VLEN](#vlen) at build time —
  the same role as `-msve-vector-bits` for [SVE](#sve).

### B4. Toolchain file *(optional)*

Walberla has no `cmake/toolchains/` directory today. If cross-compilation
for a SpacemiT K1 / LicheePi board is in scope, add a
`submodules/walberla/cmake/toolchains/riscv64-rvv.cmake` modeled on a stock
[CMake](#cmake) RISC-V toolchain file. Not blocking for codegen work
itself.

## Risks / decisions needed upfront

1. **Fixed-[lane](#lane) vs true [VLA](#vla).** Recommendation:
   fixed-[lane](#lane) (i.e. [VLS](#vls)). Confirm before any code is
   written; this choice cascades through the whole platform file.
2. **[RVV](#rvv)-0.7 toolchain target.** Pick *either* T-Head GCC bare
   [intrinsics](#intrinsic) *or* LLVM [`xtheadvector`](#xtheadvector) (with
   `__riscv_th_*` prefix). The mapping differs.
3. **Hardware to validate on.** Without a board or qemu-with-`v` extension,
   nothing gets tested end-to-end. Need at least qemu in CI.
4. **Upstream check before starting.** Submodule is two commits past
   [`release/2.0b1`](https://i10git.cs.fau.de/pycodegen/pystencils/-/tags/release%2F2.0b1).
   Confirm against pystencils
   [`master`](https://i10git.cs.fau.de/pycodegen/pystencils/-/tree/master)
   that [RVV](#rvv) work has not already started upstream — would be a
   duplication.

## Suggested order of work

1. Stub `Target.RISCV_RVV_1_0` + an `RvvCpu` that only generates
   `GenericCPU`-equivalent scalar output, to wire all the plumbing
   end-to-end (driver, [JIT](#jit) flags, walberla sweepgen).
2. Implement the [SVE](#sve)-style fixed-[lane](#lane)
   [intrinsic](#intrinsic) mapping for f32, unit load/store, add/mul/[FMA](#fma).
   Get a single test green under qemu.
3. Fill out the rest of the f32 / f64 / i32 / i64 op table; add
   [strided](#stride) and [gather](#gather)/[scatter](#scatter);
   reductions last.
4. Subclass for [RVV](#rvv)-0.7 once 1.0 is stable.
5. walberla `sweepgen` plumbing — trivial once pystencils is producing valid
   `Target.RISCV_RVV_*` kernels.

---

## Glossary

Definitions for terms used in this file. All terms above link here.

<a id="rvv"></a>
**RVV** — *RISC-V Vector extension*. The `V` extension of the RISC-V ISA;
a scalable vector ISA conceptually similar to [SVE](#sve).
**RVV-0.7.1** is the last pre-ratification draft (Dec 2019), implemented
by T-Head C906/C910 cores. **RVV-1.0** is the ratified spec (late 2021),
the standard targeted by mainline GCC ≥ 13 / Clang ≥ 17. They are
**not source- or binary-compatible**.

<a id="sve"></a>
**SVE** — *Scalable Vector Extension*. ARM's length-agnostic vector ISA.
Pystencils' existing scalable-vector backend uses [SVE](#sve) as its
template; the [RVV](#rvv) plan mirrors it.

<a id="vla"></a>
**VLA** — *Vector Length Agnostic*. Code that produces a correct result
for any legal [VLEN](#vlen) of the target ISA. The canonical [RVV](#rvv) /
[SVE](#sve) idiom is a stripmining loop. **Not** how pystencils generates
code today.

<a id="vls"></a>
**VLS** — *Vector Length Specific*. Code compiled with a fixed,
compile-time-known [VLEN](#vlen). [VLS](#vls) is what pystencils' [SVE](#sve)
backend produces, and what the [RVV](#rvv) plan recommends for v1.

<a id="vlen"></a>
**VLEN** — *Vector Register Length*, in bits. Implementation-defined width
of one [RVV](#rvv) (or [SVE](#sve)) vector register. Pinned at build time
in the [VLS](#vls) model via `-mrvv-vector-bits=<N>` (GCC ≥ 14) or
`-mllvm -riscv-v-vector-bits-min=<N>` (Clang).

<a id="sew"></a>
**SEW** — *Selected Element Width* (in bits). The width of one element in
the currently configured `vtype` — legal values 8, 16, 32, 64.

<a id="lmul"></a>
**LMUL** — *Length Multiplier*. [RVV](#rvv) vector register group
multiplier. Combines 1, 2, 4, or 8 architectural registers (or fractional
groups 1/2, 1/4, 1/8 in RVV-1.0) into one logical operand. With
[SEW](#sew) and [VLEN](#vlen) it determines the [lane](#lane) count per
op: `lanes = VLEN · LMUL / SEW`.

<a id="vl"></a>
**vl** — [RVV](#rvv) *vector length* CSR. The active prefix length: the
number of [lanes](#lane) processed by the next vector instruction. Set by
[`vsetvl`](#vsetvl).

<a id="vsetvl"></a>
**vsetvl / vsetvli / vsetivli** — [RVV](#rvv) instructions that update
`vtype` and [`vl`](#vl). The [intrinsic](#intrinsic) form is
`__riscv_vsetvl_e{sew}m{lmul}(N)` (RVV-1.0) or `vsetvl_e{sew}m{lmul}(N)`
(RVV-0.7).

<a id="lane"></a>
**lane** — One element position within a vector register.

<a id="predicate"></a>
**predicate** — A bit-mask telling a vector op which [lanes](#lane) are
active. [SVE](#sve) uses an `svbool_t` register; [RVV](#rvv) uses `v0` as
the implicit mask register plus a separate [`vl`](#vl) count.

<a id="mask"></a>
**mask** — Same as [predicate](#predicate) in this context.

<a id="stride"></a>
**stride** — Distance (in elements or bytes) between consecutive memory
accesses. [RVV](#rvv) strided ops (`vlse*`/`vsse*`) take the
[stride](#stride) in **bytes**.

<a id="gather"></a>
**gather** — Vector load using a vector of indices (one per [lane](#lane)).
In [RVV](#rvv)-1.0 the index vector contains **byte offsets**, not element
indices — a common porting pitfall.

<a id="scatter"></a>
**scatter** — Vector store using a vector of indices. Same byte-offset
caveat as [gather](#gather).

<a id="broadcast"></a>
**broadcast** — Replicating a scalar value to every [lane](#lane) of a
vector. `__riscv_vfmv_v_f_f32m1(s, vl)` on [RVV](#rvv); `svdup_n_*` on
[SVE](#sve).

<a id="fma"></a>
**FMA** — *Fused Multiply-Add*. `a·b + c` as a single rounded operation.
[RVV](#rvv) intrinsic: `__riscv_vfmacc_vv_f32m1(c, a, b, vl)`.

<a id="intrinsic"></a>
**intrinsic** — Compiler [intrinsic](#intrinsic); a C-level function that
maps one-to-one to a machine instruction. The [RVV](#rvv)-0.7 and
[RVV](#rvv)-1.0 [intrinsic](#intrinsic) families have different names and
are not source-compatible.

<a id="xtheadvector"></a>
**xtheadvector** — LLVM extension that exposes T-Head's [RVV](#rvv)-0.7-era
instructions through standard-style [intrinsics](#intrinsic) with a
`__riscv_th_` prefix. The practical way to target C906/C910 from a modern
toolchain.

<a id="jit"></a>
**JIT** — *Just-In-Time*. Compilation performed at program runtime rather
than build time. pystencils [JIT](#jit)-compiles generated kernels and
selects `-march` flags per `Target`.

<a id="cmake"></a>
**CMake** — Cross-platform build-system generator used by walberla and
pystencils. Drives codegen by passing build configuration to the Python
codegen scripts via a JSON blob.

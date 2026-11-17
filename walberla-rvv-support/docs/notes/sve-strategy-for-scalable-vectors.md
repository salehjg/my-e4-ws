# [SVE](#sve) backend strategy — the template for [RVV](#rvv)

Source: [`submodules/pystencils/src/pystencils/backend/platforms/sve.py`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py)
(at pinned commit `20d7dcf0…`).

[SVE](#sve) is the only existing scalable-vector backend in pystencils. Its
design choices are load-bearing for any future [RVV](#rvv) backend, so they
need to be understood before designing one.

## Headline: [SVE](#sve) is NOT generated as truly [VLA](#vla)

pystencils does **not** emit `svcntw()`-driven loops with runtime-variable
[VLEN](#vlen). Instead:

1. The user picks a **fixed [lane](#lane) count** at codegen time
   (e.g. 4 [lanes](#lane) of f32 ⇒ 128 b on this kernel).
2. The platform emits a **fixed [predicate](#predicate) at kernel entry**
   for that [lane](#lane) count: `svbool_t mask = svwhilelt_b32(0, 4);` —
   [`submodules/pystencils/src/pystencils/backend/platforms/sve.py:102-109`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py#L102-109).
3. Every op threads that [predicate](#predicate): `svadd_s32_x(mask, a, b)`,
   `svld1_s32(mask, ptr)`, etc. The `_x` suffix is
   "[predicated](#predicate), undefined inactive [lanes](#lane)" — chosen
   because it gives the compiler maximum freedom.
4. Outer loop strides assume that fixed [lane](#lane) count. No runtime
   [VLEN](#vlen) query.

This is enforced by `Target.ARM_SVE.default_vector_lanes()` at
[`submodules/pystencils/src/pystencils/codegen/target.py:135-155`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/codegen/target.py#L135-155)
**raising `CodegenError`** — the user must specify the [lane](#lane) count.

If the actual hardware [VLEN](#vlen) differs from what was assumed: the
[predicates](#predicate) still [mask](#mask) to the requested first N
[lanes](#lane), so behavior remains correct, but hardware [lanes](#lane)
beyond N are wasted. Conservative but correct.

## Class structure

- `SveCpu` at [`submodules/pystencils/src/pystencils/backend/platforms/sve.py:46-71`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py#L46-71):
  no architectural params; returns `SelectIntrinsicsSve`. Header:
  `"pystencils_runtime/sve.hpp"`.
- `SveSelectionContext` at [`sve.py:73-110`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py#L73-110):
  caches [predicates](#predicate) keyed by `(scalar_width, lanes)` in
  `_fixed_width_predicates: dict[(int,int), PsSymbol]`. `lane_predicate(vtype)`
  returns or creates the [predicate](#predicate) symbol; the generated
  definition is `svwhilelt_b{sew}(0, lanes)`.
- `SelectIntrinsicsSve` at [`sve.py:112-498`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py#L112-498).

## [Intrinsic](#intrinsic) mapping highlights

- Types at [`sve.py:132-166`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py#L132-166):
  `PsVectorType(int32, any)` → `svint32_t`; multi-vector `PsShortArrayType` →
  `svint32x{2,3,4}_t`.
- Constants at [`sve.py:168-173`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py#L168-173):
  no [broadcast](#broadcast) [intrinsic](#intrinsic) per se; built via
  `svundef_*()` + repeated `svinsr_n_*()`. Slow but correct.
- Binary ops at [`sve.py:175-197`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py#L175-197):
  `svadd_s32_x(predicate, a, b)`. [Broadcasts](#broadcast) use `svdup_n_*()`
  (no [predicate](#predicate)).
- Math at [`sve.py:199-207`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py#L199-207):
  `abs`, `min`, `max`, `sqrt` via `_x` [predicated](#predicate) forms.
- Load at [`sve.py:209-233`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py#L209-233):
  - Packed: `svld1_s32(pred, ptr)`.
  - [Strided](#stride)/[gather](#gather): build index vector via
    `svindex_s32(0, stride)`, then
    `svld1_gather_s32index_s32(pred, ptr, idx)`.
  - **16-bit [gather](#gather)/[scatter](#scatter) not supported by [SVE](#sve)** —
    [`sve.py:220-222`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py#L220-222)
    raises.
- Store at [`sve.py:235-261`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py#L235-261):
  mirror of load.

## Why this matters for [RVV](#rvv)

[RVV](#rvv)-1.0 is conceptually similar to [SVE](#sve): scalable length,
mandatory [mask](#mask) register, indexed loads/stores. The same
"fixed [lane](#lane) count + entry-time configuration" approach maps
directly:

| [SVE](#sve) step                                | [RVV](#rvv)-1.0 equivalent                            |
|-------------------------------------------------|-------------------------------------------------------|
| Pick ([SEW](#sew), [lanes](#lane))              | Pick ([SEW](#sew), [LMUL](#lmul)) ⇒ implied [lanes](#lane) per [VLEN](#vlen)_min |
| `svbool_t m = svwhilelt_b32(0, lanes);`         | `size_t vl = __riscv_vsetvl_e32m1(lanes);`            |
| `svadd_s32_x(m, a, b)`                          | `__riscv_vadd_vv_i32m1(a, b, vl)`                     |
| `svld1_s32(m, ptr)`                             | `__riscv_vle32_v_i32m1(ptr, vl)`                      |
| `svld1_gather_s32index_s32(m, ptr, idx)`        | `__riscv_vluxei32_v_i32m1(ptr, idx, vl)`              |

Key difference: [SVE's](#sve) [predicate](#predicate) is a true [mask](#mask);
[RVV's](#rvv) [`vl`](#vl) is a *count* (active prefix length). Equivalent
for our usage but the codegen template will need a [`vl`](#vl) symbol where
[SVE](#sve) has a `svbool_t` symbol.

## Open question for [RVV](#rvv): fixed-[lane](#lane) vs true [VLA](#vla)

Two options when implementing the [RVV](#rvv) backend. The choice
determines almost everything else.

1. **[SVE](#sve)-style fixed [lane](#lane) count** *(recommended for v1)*.
   - Reuse pystencils' existing loop-emission unchanged.
   - One [`vl`](#vl) set at kernel entry via
     `__riscv_vsetvl_e{sew}m{lmul}(N)` — i.e. picking a [SEW](#sew) and
     [LMUL](#lmul) up front.
   - Low risk, high code reuse.

2. **True [VLA](#vla)**: loop step is `__riscv_vsetvl_*(remaining)` each
   iteration ([stripmining](#stripmining)).
   - Needs new [IR](#ir) machinery — pystencils' outer-loop emission
     assumes a constant [lane](#lane) count.
   - Better hardware utilization on cores with large [VLEN](#vlen).
   - Effectively a research project; do not attempt in v1.

---

## Glossary

Definitions for terms used in this file. All terms above link here.

<a id="sve"></a>
**SVE** — *Scalable Vector Extension*. ARM's length-agnostic vector
ISA; vector register width ([VLEN](#vlen)) is implementation-defined.
Programs use [predicated](#predicate) instructions that work at any width.
Targeted by pystencils via `Target.ARM_SVE`.

<a id="rvv"></a>
**RVV** — *RISC-V Vector extension*. The `V` extension of the RISC-V ISA;
a scalable vector ISA conceptually similar to [SVE](#sve).

<a id="vla"></a>
**VLA** — *Vector Length Agnostic*. Code that produces a correct result for
any legal [VLEN](#vlen) of the target ISA. The canonical [RVV](#rvv) /
[SVE](#sve) idiom is a [stripmining](#stripmining) loop.

<a id="vlen"></a>
**VLEN** — *Vector Register Length*, in bits. Implementation-defined width
of one [SVE](#sve) or [RVV](#rvv) vector register. Must be a power of two.
Real silicon today: 128 (most current [SVE](#sve) Arm cores, T-Head C906),
256 (SpacemiT K1, T-Head C908), 512+ (Andes AX45MPV, future SiFive cores).

<a id="sew"></a>
**SEW** — *Selected Element Width* (in bits). For [RVV](#rvv): the width
of one element in the currently configured [`vtype`](#vl) — legal values
8, 16, 32, 64. The same physical register is interpreted as e.g. 16×i8 or
4×i32 depending on [SEW](#sew). On [SVE](#sve) the equivalent is the
element width baked into each instruction mnemonic.

<a id="lmul"></a>
**LMUL** — *Length Multiplier*. [RVV](#rvv) vector register group
multiplier. Combines 1, 2, 4, or 8 architectural registers (or fractional
groups 1/2, 1/4, 1/8 in RVV-1.0) into one logical operand. With [SEW](#sew)
and [VLEN](#vlen) it determines the [lane](#lane) count per op:
`lanes = VLEN · LMUL / SEW`.

<a id="vl"></a>
**vl** — [RVV](#rvv) *vector length* CSR. The active prefix length: the
number of [lanes](#lane) processed by the next vector instruction. Set by
`__riscv_vsetvl_e{sew}m{lmul}(N)`. The pystencils [RVV](#rvv) backend
plan threads [`vl`](#vl) through every op the same way the [SVE](#sve)
backend threads an `svbool_t` [predicate](#predicate).

<a id="lane"></a>
**lane** — One element position within a vector register.

<a id="predicate"></a>
**predicate** — A bit-mask telling a vector op which [lanes](#lane) are
active. [SVE](#sve) uses an `svbool_t` register threaded through every
[intrinsic](#intrinsic); [RVV](#rvv) uses `v0` as the implicit mask
register and a separate [`vl`](#vl) count.

<a id="mask"></a>
**mask** — Same as [predicate](#predicate) in this context.

<a id="stride"></a>
**stride** — Distance (in elements or bytes) between consecutive memory
accesses. A unit-stride load reads contiguous elements; a strided load
reads every Nth.

<a id="gather"></a>
**gather** — Vector load using a vector of indices (one per [lane](#lane)).
Supported by [SVE](#sve) at 32/64-bit widths only; [RVV](#rvv) supports all
widths.

<a id="scatter"></a>
**scatter** — Vector store using a vector of indices. The store-side dual
of [gather](#gather).

<a id="broadcast"></a>
**broadcast** — Replicating a scalar value to every [lane](#lane) of a
vector. `svdup_n_*` on [SVE](#sve), `__riscv_v*mv_v_x_*` on [RVV](#rvv).

<a id="intrinsic"></a>
**intrinsic** — Compiler [intrinsic](#intrinsic); a C-level function that
maps one-to-one to a machine instruction. Vector backends in pystencils
emit calls to [intrinsics](#intrinsic) rather than raw assembly.

<a id="ir"></a>
**IR** — *Intermediate Representation*. A compiler's internal
representation between source code and machine code. pystencils has its
own stencil [IR](#ir); the outer loop nest is part of it and currently
assumes a constant [lane](#lane) count.

<a id="stripmining"></a>
**stripmining** — Iterative chunking of a long loop into fixed-size vector
chunks. The canonical [VLA](#vla) idiom for [RVV](#rvv) and [SVE](#sve):
each iteration asks hardware "how many [lanes](#lane) can you give me?"
and steps the pointer by that many elements.

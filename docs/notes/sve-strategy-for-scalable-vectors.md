# SVE backend strategy — the template for RVV

Source: [`submodules/pystencils/src/pystencils/backend/platforms/sve.py`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py)
(at pinned commit `20d7dcf0…`).

SVE is the only existing scalable-vector backend in pystencils. Its design
choices are load-bearing for any future RVV backend, so they need to be
understood before designing one.

## Headline: SVE is NOT generated as truly VLA

pystencils does **not** emit `svcntw()`-driven loops with runtime-variable VL.
Instead:

1. The user picks a **fixed lane count** at codegen time
   (e.g. 4 lanes of f32 ⇒ 128 b on this kernel).
2. The platform emits a **fixed predicate at kernel entry** for that lane
   count: `svbool_t mask = svwhilelt_b32(0, 4);` —
   [`submodules/pystencils/src/pystencils/backend/platforms/sve.py:102-109`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py#L102-109).
3. Every op threads that predicate: `svadd_s32_x(mask, a, b)`,
   `svld1_s32(mask, ptr)`, etc. The `_x` suffix is "predicated, undefined
   inactive lanes" — chosen because it gives the compiler maximum freedom.
4. Outer loop strides assume that fixed lane count. No runtime VL query.

This is enforced by `Target.ARM_SVE.default_vector_lanes()` at
[`submodules/pystencils/src/pystencils/codegen/target.py:135-155`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/codegen/target.py#L135-155)
**raising `CodegenError`** — the user must specify the lane count.

If the actual hardware VLEN differs from what was assumed: the predicates
still mask to the requested first N lanes, so behavior remains correct, but
hardware lanes beyond N are wasted. Conservative but correct.

## Class structure

- `SveCpu` at [`submodules/pystencils/src/pystencils/backend/platforms/sve.py:46-71`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py#L46-71):
  no architectural params; returns `SelectIntrinsicsSve`. Header:
  `"pystencils_runtime/sve.hpp"`.
- `SveSelectionContext` at [`sve.py:73-110`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py#L73-110):
  caches predicates keyed by `(scalar_width, lanes)` in
  `_fixed_width_predicates: dict[(int,int), PsSymbol]`. `lane_predicate(vtype)`
  returns or creates the predicate symbol; the generated definition is
  `svwhilelt_b{sew}(0, lanes)`.
- `SelectIntrinsicsSve` at [`sve.py:112-498`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py#L112-498).

## Intrinsic mapping highlights

- Types at [`sve.py:132-166`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py#L132-166):
  `PsVectorType(int32, any)` → `svint32_t`; multi-vector `PsShortArrayType` →
  `svint32x{2,3,4}_t`.
- Constants at [`sve.py:168-173`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py#L168-173):
  no broadcast intrinsic per se; built via `svundef_*()` + repeated
  `svinsr_n_*()`. Slow but correct.
- Binary ops at [`sve.py:175-197`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py#L175-197):
  `svadd_s32_x(predicate, a, b)`. Broadcasts use `svdup_n_*()` (no predicate).
- Math at [`sve.py:199-207`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py#L199-207):
  `abs`, `min`, `max`, `sqrt` via `_x` predicated forms.
- Load at [`sve.py:209-233`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py#L209-233):
  - Packed: `svld1_s32(pred, ptr)`.
  - Strided/gather: build index vector via `svindex_s32(0, stride)`, then
    `svld1_gather_s32index_s32(pred, ptr, idx)`.
  - **16-bit gather/scatter not supported by SVE** —
    [`sve.py:220-222`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py#L220-222)
    raises.
- Store at [`sve.py:235-261`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py#L235-261):
  mirror of load.

## Why this matters for RVV

RVV-1.0 is conceptually similar to SVE: scalable length, mandatory mask
register, indexed loads/stores. The same "fixed lane count + entry-time
configuration" approach maps directly:

| SVE step                                        | RVV-1.0 equivalent                              |
|-------------------------------------------------|-------------------------------------------------|
| Pick (sew, lanes)                               | Pick (sew, lmul) ⇒ implied lanes per VLEN_min   |
| `svbool_t m = svwhilelt_b32(0, lanes);`         | `size_t vl = __riscv_vsetvl_e32m1(lanes);`      |
| `svadd_s32_x(m, a, b)`                          | `__riscv_vadd_vv_i32m1(a, b, vl)`               |
| `svld1_s32(m, ptr)`                             | `__riscv_vle32_v_i32m1(ptr, vl)`                |
| `svld1_gather_s32index_s32(m, ptr, idx)`        | `__riscv_vluxei32_v_i32m1(ptr, idx, vl)`        |

Key difference: SVE's predicate is a true mask; RVV's `vl` is a *count*
(active prefix length). Equivalent for our usage but the codegen template
will need a `vl` symbol where SVE has a `svbool_t` symbol.

## Open question for RVV: fixed-lane vs true VLA

Two options when implementing the RVV backend. The choice determines almost
everything else.

1. **SVE-style fixed lane count** *(recommended for v1)*.
   - Reuse pystencils' existing loop-emission unchanged.
   - One `vl` set at kernel entry via `__riscv_vsetvl_e{sew}m{lmul}(N)`.
   - Low risk, high code reuse.

2. **True VLA**: loop step is `__riscv_vsetvl_*(remaining)` each iteration.
   - Needs new IR machinery — pystencils' outer-loop emission assumes a
     constant lane count.
   - Better hardware utilization on cores with large VLEN.
   - Effectively a research project; do not attempt in v1.

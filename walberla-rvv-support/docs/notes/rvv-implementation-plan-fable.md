# Plan: full [RVV](#rvv)-1.0 support for pystencils — [VLS](#vls) *and* [VLA](#vla) modes

Companion to:
- [`pystencils-cpu-backends.md`](pystencils-cpu-backends.md) — current ISA support landscape
- [`sve-strategy-for-scalable-vectors.md`](sve-strategy-for-scalable-vectors.md) — the existing scalable-vector backend
- [`rvv-isa-primer.md`](rvv-isa-primer.md) — [RVV](#rvv) terminology ([SEW](#sew)/[LMUL](#lmul)/[VLEN](#vlen)/[`vl`](#vl)), the eight formulas, 0.7→1.0 deltas
- [`walberla-codegen-flow.md`](walberla-codegen-flow.md) — how walberla invokes pystencils
- [`rvv-implementation-plan.md`](rvv-implementation-plan.md) — the earlier plan (VLS-only, included RVV-0.7)
- Complete [RVV](#rvv)-1.0 [intrinsics](#intrinsic) cheat-sheet —
  `/workspace/02_ws/my-intrisics-workspace/riscv64/docs/cheatsheet-full/rvv-cheatsheet-full.pdf`
  (generated from `dzaima/rvv-intrinsic-doc` v12; ~1046 ops in 182
  sub-categories incl. all extensions). Reviewed in full for this plan;
  §5.1 records what was adopted vs rejected.

All submodule source links resolve to the pinned commits:
pystencils `20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f`, walberla `0c8ed8c90a3220f459a5d82868ddd66d2f1a7837`.

## 0. Scope, non-goals, and how this differs from the earlier plan

**Goal:** a first-class `Target.RISCV_RVV` backend for pystencils 2.0b1 that
generates [RVV](#rvv)-**1.0** [intrinsic](#intrinsic) code in two
user-selectable modes:

1. **[VLS](#vls) mode** (*fixed-lane*, ships first) — the user pins a
   [lane](#lane) count at codegen time, exactly like the existing
   [SVE](#sve) backend. Reuses the current loop-emission machinery
   unchanged.
2. **[VLA](#vla) mode** (*[stripmining](#stripmining)*) — the generated
   kernel is correct **and fully utilizes the hardware** for *any*
   [VLEN](#vlen) ≥ a configured floor. One binary runs unmodified and
   at full width on [VLEN](#vlen)=128, 256, 512, … cores. This requires
   a small set of IR and loop-strategy extensions that are designed here
   in detail.

Driving application: Lattice-Boltzmann kernels (D2Q9 today in
`python/learn-lb-pystencil/lb-pystencils.py`; D3Q19/D3Q27 via walberla
sweepgen later). §6 collects the LBM-specific consequences.

**Non-goals:**

- [RVV](#rvv)-0.7 / T-Head `xtheadvector`. Deliberately dropped from this
  plan (the earlier plan sketches it). The 1.0 backend should not carry
  0.7 compromises in its core design; 0.7 can be bolted on later as an
  intrinsic-renaming subclass if a C906-class board ever matters.
- Masked/predicated vectorization of conditionals. The
  [`AstVectorizer`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/transformations/ast_vectorizer.py)
  cannot vectorize branches on any backend today; [RVV](#rvv) masks (`v0`,
  `vm` field) stay unused except where noted. The hooks exist
  (`VectorizationContext.lane_mask`,
  [`ast_vectorizer.py:114-134`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/transformations/ast_vectorizer.py#L114-134),
  and the dormant `SelectionContext._lane_mask`) — masked ops are a
  natural follow-up, not part of this plan.
- Vectorized transcendentals (`exp`, `log`, `pow`). No [RVV](#rvv)
  [intrinsics](#intrinsic) exist for them; same limitation as
  [SVE](#sve)/NEON today. LBM BGK collision needs only `+ - * /`, so this
  does not block the target application.

## 1. Where the pipeline is today — the six insertion points

Reading the 2.0b1 codegen pipeline end-to-end, RVV work lands in exactly
six places. Everything else is untouched.

| # | Stage | File (pinned) | What changes |
|---|-------|---------------|--------------|
| 1 | Target enum + detection | [`codegen/target.py`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/codegen/target.py) | new flags + `RISCV_RVV` member + `/proc/cpuinfo` probe |
| 2 | Config surface | [`codegen/config.py:244-310`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/codegen/config.py#L244-310) | `VectorizationOptions.mode` (VLS/VLA) + `RvvOptions` category |
| 3 | Loop strategy | [`codegen/cpu_loop_strategies.py:55-127`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/codegen/cpu_loop_strategies.py#L55-127) | VLA: replace peel+block+remainder with one stripmined axis |
| 4 | Axis expansion & materialization | [`backend/transformations/axis_expansion.py`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/transformations/axis_expansion.py), [`materialize_axes.py:170-224`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/transformations/materialize_axes.py#L170-224) | VLA: new `stripmine()` expansion, `active_lanes` plumbed into `VectorizationContext` |
| 5 | Platform + intrinsic selection | new `backend/platforms/rvv.py`, modeled on [`sve.py`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py); dispatch in [`codegen/driver.py:399-432`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/codegen/driver.py#L399-432) | both modes |
| 6 | JIT flags + runtime header | [`jit/cpu/compiler_info.py:107-124`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/jit/cpu/compiler_info.py#L107-124), new `include/pystencils_runtime/rvv.hpp` | `-march=rv64gcv...`, header, Philox wrappers |

Two load-bearing observations from the code that make VLA *feasible
without an IR rewrite*:

- **`PsLoop` already supports a symbolic step.** The C printer emits
  `for(ctr = start; ctr < stop; ctr += step)` with `step` an arbitrary
  expression
  ([`emission/base_printer.py:212-232`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/emission/base_printer.py#L212-232)).
  A canonical stripmining loop — `for (i = start; i < stop; i += vl)`
  with `vl` reassigned at the top of the body — needs **no new
  structural node**, only a new way to build that loop.
- **The fixed `lanes` count in vector IR types is bookkeeping, not
  semantics, for a scalable backend.** `PsVectorType(f64, L)` maps to
  `vfloat64m1_t` regardless of `L` (just as [SVE](#sve) maps everything to
  `svfloat64_t`). The places where `L` becomes *runtime-observable* are
  enumerable and each has a length-agnostic replacement (§3, D5/D9).

For reference, the current vectorized-loop shape produced by
[`DefaultCpuLoopStrategies._dense_ispace_axes`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/codegen/cpu_loop_strategies.py#L55-127)
for the innermost dimension is:

```
peel_for_divisibility(L)                      # bulk/remainder split
├── block_loop(L, assume_divisible=True)      # for (i = 0; i < bulk; i += L)
│   └── simd(L)                               #     <vectorized body, exactly L lanes>
└── loop()                                    # scalar remainder loop
```

[VLS](#vls) mode keeps this shape verbatim. [VLA](#vla) mode replaces all
three parts with a single stripmined axis (§3 D9).

## 2. The two modes, precisely

### 2.1 VLS — Vector Length Specific (fixed-lane)

Semantics identical to the [SVE](#sve) backend
(see [`sve-strategy-for-scalable-vectors.md`](sve-strategy-for-scalable-vectors.md)):
the user pins `cpu.vectorize.lanes = L` and an assumed hardware
[VLEN](#vlen); codegen emits intrinsics that process exactly `L` elements
per operation, and the outer loop strides by `L`.

Where [RVV](#rvv) differs from [SVE](#sve) — and this drives design
decisions D2, D3, D8:

- [SVE](#sve) threads an `svbool_t` [predicate](#predicate); on
  [RVV](#rvv) every intrinsic instead takes a `size_t vl` **count**
  argument. With the precondition `L ≤ VLMAX` this can be the **literal
  constant `L`** at every call site — the compiler materializes and
  hoists the `vsetvli` instructions itself. No predicate symbol, no
  entry-time declaration needed (D3).
- On [SVE](#sve), running fixed-lane code on wider hardware is
  *automatically safe* (the predicate masks the extra lanes). On
  [RVV](#rvv), running it on **narrower** hardware than assumed is
  *silently wrong*: `vsetvl(L)` grants `min(L, VLMAX) < L` while the
  outer loop still strides by `L` — elements get skipped. A cheap
  runtime guard is mandatory (D8).
- The register type for a given scalar type is **not fixed** — it depends
  on [LMUL](#lmul), which must be derived per type from
  `(L, element width, assumed VLEN)` (D2).

Toolchain-VLS (`-mrvv-vector-bits=N`) is *orthogonal*: our generated code
is correct without it; passing it (GCC ≥ 14 / Clang ≥ 18) additionally
lets the C compiler treat the intrinsic types as fixed-size and optimize
more aggressively. Recommended when the [JIT](#jit)/CMake knows the exact
target (D12, §8).

### 2.2 VLA — Vector Length Agnostic (stripmining)

The canonical [RVV](#rvv) idiom (see
[`rvv-isa-primer.md` §8](rvv-isa-primer.md)): each inner-loop iteration
asks the hardware how many elements it may process, and advances by the
granted count:

```c
size_t vl;
for (int64_t i = start; i < stop; i += vl) {
    vl = __riscv_vsetvl_e64m1((size_t)(stop - i));   // hardware grants 1..VLMAX
    /* vectorized body: every op takes vl */
}
```

Properties:

- **No peel, no remainder loop.** The tail is absorbed by the final
  short `vl`. For LBM this matters: inner rows are often short
  (e.g. 100 cells at 8–32 lanes wastes a large fraction of iterations in
  the scalar remainder today).
- **Full hardware utilization at any [VLEN](#vlen).** The same `.so`
  is optimal on a [VLEN](#vlen)=128 dev board and a [VLEN](#vlen)=512
  HPC core.
- **The IR keeps a *nominal* lane count** `L_nom` for type bookkeeping
  (D9); everything runtime-observable derives from [`vl`](#vl) and
  `vid.v`, never from `L_nom`.

Acceptance criterion (the one test that defines "VLA works"): the same
generated kernel binary produces bit-identical results under
`qemu-riscv64 -cpu rv64,v=true,vlen=128`, `vlen=256`, and `vlen=1024`
(§7).

### 2.3 What is shared

One platform class, one intrinsic selector, one runtime header, one
`Target` member. The mode is a per-kernel codegen option
(`cpu.vectorize.mode`), not a separate target — walberla and the JIT
treat both modes identically apart from the optional
`-mrvv-vector-bits` flag.

## 3. Design decisions

### D1. Target enum, platform dispatch, auto-detection

In [`codegen/target.py`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/codegen/target.py):

```python
_RISCV = auto()
_RVV   = auto()

RISCV_RVV = _CPU | _VECTOR | _RISCV | _RVV
"""RISC-V architecture with the ratified V vector extension (RVV 1.0)."""
```

- `default_vector_lanes()` **raises `CodegenError`** for `RISCV_RVV`,
  same as `ARM_SVE`
  ([`target.py:135-155`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/codegen/target.py#L135-155))
  — in VLS mode the user must pick `lanes`; in VLA mode the loop strategy
  derives `L_nom` itself and never calls this.
- `_available_vector_targets()`
  ([`target.py:209-279`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/codegen/target.py#L209-279)):
  add a `machine_spec in ("riscv64",)` branch. Probe order:
  `/proc/cpuinfo` `isa` line (single-letter `v` in the ISA string, taking
  care not to match `_zvl…`/`_xthead…` substrings — parse the
  single-letter extension segment before the first `_`), falling back to
  `/proc/device-tree/cpus/cpu@0/riscv,isa`. **Do not rely on `Zvl*`
  tokens for the VLEN floor** — verified on the SpacemiT K1
  (VLEN=256): its `/proc/cpuinfo` ISA string carries no `Zvl256b` token
  (§7.1). The authoritative VLEN probe is runtime
  (`__riscv_vlenb()` / `vsetvlmax` via a tiny probe binary, or defer to
  the runtime guard D8); `Zvl*` tokens are a bonus when present.
- `driver._get_platform()`
  ([`driver.py:399-432`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/codegen/driver.py#L399-432)):
  add an `elif Target._RVV in self._target:` branch constructing
  `RvvCpu(self._ctx, **rvv_options)`.

### D2. Lane count × assumed VLEN ⇒ per-type LMUL (the core VLS contract)

The kernel-wide lane count `L` is a single integer (the
[`AstVectorizer`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/transformations/ast_vectorizer.py)
vectorizes every type in the kernel with the same `lanes`). But one
kernel mixes element widths — LBM at f64 also carries i64/i32 index and
counter vectors. On [RVV](#rvv) the register-group size must therefore
differ per type. The platform derives, for every
`PsVectorType(scalar_w, L)`:

```
LMUL(w) = L · w / VLEN_assumed        (must land in {1/8, 1/4, 1/2, 1, 2, 4, 8})
```

with the additional type-existence constraint `w / LMUL ≤ 64` (with
[ELEN](#elen)=64; e.g. `vfloat64mf2_t` does not exist — f64 needs
[LMUL](#lmul) ≥ 1).

Examples ([VLEN](#vlen)=256): `L=4, f64 ⇒ m1`; `L=8, f64 ⇒ m2` and the
i32 counter vector of the same kernel ⇒ `m1`. If the ratio is not a legal
[LMUL](#lmul), raise `MaterializationError` with a message listing the
legal `L` values for this `(dtype, VLEN)`.

This single rule buys:

- consistent lane counts across mixed-width values (the
  [EMUL](#emul) relationship, eq 4 of the primer, holds by construction);
- width-changing casts map onto widening/narrowing conversions with the
  correct register groups (D11) — something the [SVE](#sve) backend
  cannot do at all;
- `VLMAX(w) = VLEN_hw · LMUL(w) / w = L · VLEN_hw / VLEN_assumed` is
  **the same ratio for every type**, so the one runtime precondition is
  simply `VLEN_hw ≥ VLEN_assumed` (D8), and in VLA mode all
  `(SEW, LMUL)` configs of a kernel grant the *same* [`vl`](#vl) per
  stripmine step — one `vl` symbol serves the whole body (D9).

Config surface: new `RvvOptions` category under `CpuOptions`
([`config.py:288-310`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/codegen/config.py#L288-310)):

```python
@dataclass
class RvvOptions(ConfigBase):
    vlen: BasicOption[int] = BasicOption()      # assumed (VLS) / minimum (VLA) VLEN in bits
    check_vlen: BasicOption[bool] = BasicOption(True)   # emit the D8 runtime guard
    lmul: BasicOption[int] = BasicOption()      # VLA only: base LMUL for the default dtype (default 1)
```

In VLS mode `(lanes, vlen)` are both required; in VLA mode `(vlen, lmul)`
determine `L_nom = vlen · lmul / w_default` and `lanes` must not be set.

### D3. Threading the active-length operand

Where [SVE](#sve) threads `svbool_t` predicate symbols
([`sve.py:73-110`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py#L73-110)),
[RVV](#rvv) threads a `size_t` count. Per mode:

- **VLS:** the count is the **compile-time constant `L`**, passed as a
  literal to every intrinsic (`__riscv_vfadd_vv_f64m1(a, b, 4)`). No
  entry-time `vsetvl` declaration, no symbol cache: the C compiler
  materializes/hoists `vsetvli` optimally, and constants ≤ 31 even fold
  into `vsetivli`. (Keep an `RvvSelectionContext` anyway — VLA needs it,
  and it is where a per-`(SEW,LMUL)` symbol cache would go if the
  constant-operand approach ever proves to inhibit optimization; this is
  a two-line change of policy inside one method.)
- **VLA:** the count is the stripmine loop's `vl` **symbol** inside the
  vectorized axis, and `__riscv_vsetvlmax_e{sew}m{lmul}()` outside it
  (accumulator init / final horizontal reduction, D7). The
  `RvvSelectionContext` holds a stack of active-lane expressions;
  `SelectIntrinsicsRvv` pushes the axis' `vl` when entering the marked
  loop body (plumbed via D9) and pops on exit.

Uniform rule either way: *every* op takes the current count — arithmetic,
memory, broadcasts, conversions. Uniform `vl` avoids `vtype` toggles and
is required for correctness on memory ops.

### D4. Tail/mask policy suffixes

Use the **unsuffixed intrinsics** (≙ tail-agnostic, mask-agnostic:
`__riscv_vfadd_vv_f64m1`) everywhere **except** the one place
tail-agnosticism is observable: the [VLA](#vla) reduction accumulator
(D7), which uses a `_tu` (tail-undisturbed) commit. Rationale: `ta` gives
hardware the most freedom; inactive/tail lanes of intermediate values are
never read in code the vectorizer can produce. Suffix policy is
centralized in one name-builder helper so a later switch to fully
explicit `_tama` spellings (as the intrinsic spec now recommends
stylistically) is mechanical.

### D5. Constant vectors: arithmetic progressions become `vid.v`

The vectorizer creates exactly one kind of non-broadcast constant vector:
the per-lane counter offsets `[0, 1, …, L-1]` in
[`AstVectorizer.get_counter_declaration`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/transformations/ast_vectorizer.py#L253-269)
(`np.array(range(lanes))`). [SVE](#sve) lowers general constants via an
`svinsr` chain
([`sve.py:168-173`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py#L168-173))
— slow and, crucially, **length-fixed**.

`SelectIntrinsicsRvv.constant_intrinsic` must instead:

1. **Detect arithmetic progressions** `a + i·d` and emit
   `vid.v`-based construction:
   `__riscv_vadd_vx(__riscv_vmul_vx(__riscv_vid_v_u{w}m{l}(vl), d, vl), a, vl)`
   (folding the trivial `d=1, a=0` case to bare `vid`). This is faster in
   VLS mode *and* is the only valid form in VLA mode, where the lane
   count is unknown at compile time.
2. Fallback for arbitrary per-lane constants: `__riscv_vslide1down_vx`
   / `__riscv_vfslide1down_vf` chain seeded from
   `__riscv_vundefined_*()` — the exact structural mirror of SVE's
   `svundef` + `svinsr` chain. VLS mode only; in VLA mode raise
   `MaterializationError` — no such constants can be expressed
   length-agnostically.

Audit item (WP6): `EliminateConstants` must not fold a `vid`-eligible
progression into an opaque literal vector before intrinsic selection in
VLA mode; verify with a dedicated unit test.

### D6. Memory operations

`PsVecMemAcc`
([`ast/vector.py:103-206`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/ast/vector.py#L103-206))
carries an element-unit `stride` (`None` ⇒ contiguous):

| Access | Intrinsic | Notes |
|--------|-----------|-------|
| contiguous load | `__riscv_vle{w}_v_{t}m{l}(ptr, vl)` | |
| contiguous store | `__riscv_vse{w}_v_{t}m{l}(ptr, v, vl)` | |
| strided load | `__riscv_vlse{w}_v_{t}m{l}(ptr, bstride, vl)` | `bstride = stride · (w/8)`, **bytes** — computed at codegen as `PsMul(stride, itemsize)` then typed `ptrdiff_t` |
| strided store | `__riscv_vsse{w}_v_{t}m{l}(ptr, bstride, v, vl)` | dual |

Note the design choice: where [SVE](#sve) lowers a strided access to
`svindex` + gather
([`sve.py:209-233`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py#L209-233)),
[RVV](#rvv) has *native strided* loads/stores — use them; they are
usually faster than indexed ops and need no index vector. True
[gather](#gather)/[scatter](#scatter) (`vluxei`/`vsuxei` with a computed
index vector, **byte** offsets, eq 7 of the primer) is only needed once
non-affine indexed access is supported by the vectorizer — not today.
Keep a helper ready but out of the v1 surface.

Alignment (`assume_aligned`) has no [RVV](#rvv)-specific instruction
form — ignore the flag (harmless). Nontemporal stores: no standard
intrinsic (the `Zihintntl` hints have no intrinsic-level binding worth
depending on) — if `use_nontemporal_stores` is requested, warn and fall
back to normal stores.

### D7. Reductions

pystencils reduces via a vector accumulator ("modulo variable",
[`materialize_axes.py:180-224`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/transformations/materialize_axes.py#L180-224))
plus one `PsVecHorizontal` after the loop. Mapping:

| `ReductionOp` | Horizontal intrinsic | Scalar combine |
|---------------|----------------------|----------------|
| Add / Sub | `__riscv_vfredosum_vs_f{w}m{l}_f{w}m1(v, init, vl)` (float), `vredsum` (int) | `+` |
| Min | `vfredmin` / `vredmin(u)` | `min` |
| Max | `vfredmax` / `vredmax(u)` | `max` |
| Mul | — raise (same as SVE) | |

Details:

- The `_vs` form needs a scalar-in-vector init operand: build with
  `__riscv_vfmv_s_f_f{w}m1(identity, vl)`; extract the result with
  `__riscv_vfmv_f_s_f{w}m1_f{w}(res)`. Then apply the scalar combine to
  `PsVecHorizontal.scalar_operand`, mirroring the `hreduce` closure in
  [`sve.py:409-443`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py#L409-443).
- **Ordered vs unordered sum:** default `vfredosum` (reproducible,
  matches scalar/SVE semantics). Expose `vfredusum` behind an
  `RvvOptions.unordered_reductions` switch later if benchmarks justify.
- **VLA-mode tail correctness (the one subtle point):** in the last
  stripmine step `vl < VLMAX`, but the final `PsVecHorizontal` reduces
  the accumulator at **VLMAX** width. With tail-agnostic ops the
  accumulator's tail lanes would be garbage (e.g. all-ones ⇒ NaN).
  Fix, correct-by-construction and cheap: the accumulator *declaration*
  broadcasts the identity at `vsetvlmax` width; each in-loop accumulator
  *assignment* is committed tail-undisturbed via one extra move —
  `acc = __riscv_vmv_v_v_f{w}m{l}_tu(acc, new_val, vl)` (or the top-level
  op itself in `_tu` form when the RHS root is a single op). The
  intrinsic selector recognizes "assignment whose LHS symbol also feeds a
  `PsVecHorizontal`" — these are exactly the vectorized modulo variables,
  which `MaterializeAxes` can mark on the symbol (a
  `BackendPrivateProperty`-style tag) so the selector doesn't guess.
  In VLS mode none of this is needed (every step runs exactly `L` lanes).

### D8. The VLS runtime guard

Precondition: `VLEN_hw ≥ vlen_assumed` (D2 shows this single check covers
every `(SEW, LMUL)` in the kernel). Emit at kernel entry, guarded by
`RvvOptions.check_vlen` (default on):

```c
if (__riscv_vlenb() * 8 < /*vlen_assumed*/ 256) { /* report & abort */ }
```

`abort()` with a one-line `fprintf(stderr, ...)` is acceptable for
JIT-compiled kernels; walberla-generated code can map this onto
`WALBERLA_ASSERT`. Do **not** rely on `assert()` — the JIT compiles with
`-DNDEBUG`
([`compiler_info.py:99`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/jit/cpu/compiler_info.py#L99)).
This guard is what makes VLS *safe to ship*; without it, a kernel built
for [VLEN](#vlen)=256 silently corrupts data on a 128-bit core (§2.1).
VLA-mode kernels get the same guard against `vlen` (the configured
*floor*), protecting the `LMUL` legality assumptions.

### D9. VLA loop construction (the genuinely new machinery)

Target shape, for the innermost dimension (rank ≥ 2 shown; the
parallelized rank-1 case is D10):

```c
int64_t vl_i64;                                     /* index-typed copy for the += */
for (int64_t i = i_start; i < i_stop; i += vl_i64) {
    const size_t vl = __riscv_vsetvl_e64m1((size_t)(i_stop - i));
    vl_i64 = (int64_t) vl;
    /* vectorized body; counter vector = vbroadcast(i) + vid·step; every op takes vl */
}
```

Implementation, smallest-footprint version consistent with the existing
architecture:

1. **New IR function** `PsVecStripmineLanes` (a `PsIrFunction` like
   `PsMathFunction`): semantic contract "given remaining count `r > 0`
   and the kernel's vector configuration, return a granted count
   `g, 1 ≤ g ≤ min(r, VLMAX)`; repeated application terminates".
   *Never* model it as `min(r, L)` — [`vsetvl`](#vsetvl) may grant less
   than `min` in the transition band `VLMAX < r < 2·VLMAX` (primer eq 8);
   only the returned value is authoritative. Lowered by
   `SelectIntrinsicsRvv` to `__riscv_vsetvl_e{sew}m{lmul}(r)` for the
   kernel's *reference* config (D2 guarantees all configs agree).
   `GenericCpu.select_function` maps it to `min(r, L_nom)` so the IR
   stays printable/testable on non-RVV platforms (and an [SVE](#sve)
   `whilelt`-based adoption remains open later).
2. **New expansion** `AxisExpansion.stripmine(l_nom)` in
   [`axis_expansion.py`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/transformations/axis_expansion.py):
   like `block_loop` + `simd` fused. It creates the `vl` symbol
   (index-typed twin included), builds the outer `PsLoopAxis` whose range
   step is `vl_i64`, prepends the two `vl` statements to the block, and
   wraps the body in a `PsSimdAxis` **extended with an optional
   `active_lanes: PsSymbol | None` field** (default `None` preserves all
   existing behavior and tests).
3. **`MaterializeAxes`**
   ([`materialize_axes.py:170-224`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/transformations/materialize_axes.py#L170-224)):
   pass `active_lanes` through into `VectorizationContext` (add the field
   next to the existing `lane_mask` hook) and tag vectorized modulo
   variables for D7. The `AstVectorizer` itself needs **no semantic
   change** — it keeps producing `L_nom`-typed nodes; only
   `get_counter_declaration`'s constant progression must survive to the
   backend un-folded (D5 audit).
4. **`SelectIntrinsicsRvv`** reads `active_lanes` from the (extended)
   selection context while inside the axis (D3).
5. **Loop strategy**
   ([`cpu_loop_strategies.py:100-114`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/codegen/cpu_loop_strategies.py#L100-114)):
   when `vectorize.mode == VLA`, the innermost expansion list becomes
   `[ae.stripmine(l_nom)]` — no `peel_for_divisibility`, no remainder
   `loop()`.

Everything runtime-observable that previously depended on the literal
lane count is now covered: loop stepping (the `vl` symbol), counter
vectors (`vid`), tails (granted `vl`), reductions (D7). `L_nom` survives
only inside types — where, for `vfloat64m1_t`-style scalable types, it
was already fictitious.

### D10. OpenMP × VLA

A stripmined loop is **not** in OpenMP canonical form (the increment is
not loop-invariant), so it cannot itself carry `omp for`.

- **rank ≥ 2** (all realistic LBM kernels): unaffected — the parallel
  loop is an outer dimension
  ([`cpu_loop_strategies.py:100-114`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/codegen/cpu_loop_strategies.py#L100-114)),
  the stripmined axis is sequential-innermost.
- **rank 1 + OpenMP**: wrap the stripmined axis in a fixed-size
  `parallel_block_loop(chunk)` (chunk = a multiple of `vlen·8/ w`, config
  default e.g. 4096 elements) so the parallel loop stays canonical and
  each thread stripmines its chunk. Implement in the same
  `_dense_ispace_axes` branch that today special-cases rank-1
  ([`cpu_loop_strategies.py:81-99`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/codegen/cpu_loop_strategies.py#L81-99)).

### D11. Casts and mixed-width ops

Same-lane-count casts (`PsCast` between `PsVectorType`s with equal
`vector_entries` — the only kind the vectorizer emits):

| Cast | Intrinsic family | Register groups |
|------|------------------|-----------------|
| float → int, same width | `__riscv_vfcvt_rtz_x_f_v_…` — the **`_rtz_`** (round-toward-zero) variant, **not** plain `vfcvt_x` | same LMUL |
| int → float, same width | `vfcvt_f_x_v` / `vfcvt_f_xu_v` | same LMUL |
| float → wider float (f32→f64) | `__riscv_vfwcvt_f_f_v_f64m{2l}` | LMUL doubles — consistent with D2 by construction |
| float → narrower float | `__riscv_vfncvt_f_f_w_f32m{l/2}` | LMUL halves |
| int widening | `__riscv_vsext_vf{2,4,8}` / `vzext_vf{2,4,8}` — **single op** for 2×/4×/8×, no chains | LMUL scales by the factor |
| int narrowing | `vncvt_x` (one per 2× step) | LMUL halves per step |
| float ↔ int, width-changing | `vfwcvt_rtz_x_f_v` / `vfncvt_rtz_x_f_w` / `vfwcvt_f_x_v` / `vfncvt_f_x_w` | |

**Correctness trap worth a dedicated test:** plain `vfcvt_x_f_v` rounds
per the dynamic rounding mode (round-to-nearest-even by default), but a
C `(int)` cast truncates. `-1.5` converts to `-2` under `vfcvt_x` and
`-1` under `vfcvt_rtz_x` — only the latter matches what the scalar and
the x86 (`cvttps` = `_tt_`) paths produce. Add negative-halfway values to
the cast test matrix (WP5).

Because D2 fixes `LMUL ∝ width` at constant lanes, the source/destination
groups always match what the widening/narrowing intrinsics expect. This
exceeds [SVE](#sve)-backend parity
([`sve.py:445-467`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py#L445-467)
raises on any width change); implement same-width first (parity), then
widening/narrowing (full).

Integer div/rem exist natively (`vdiv`, `vdivu`, `vrem`) — unlike SVE,
so `PsDiv` need not be float-only; add `PsIntDiv`/`PsRem` mappings.
Bitwise ops (`vand`, `vor`, `vxor`, shifts `vsll`/`vsrl`/`vsra`) are
cheap to include for completeness; `PsNeg` maps to `vfneg`/`vneg`.

### D12. FMA

pystencils has no FMA IR node; x86/[SVE](#sve) backends rely on the C
compiler contracting `a*b+c` (JIT compiles `-Ofast`/`-ffast-math`,
[`compiler_info.py:151-159`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/jit/cpu/compiler_info.py#L151-159)).
Verified behavior to rely on: GCC/Clang contract `__riscv_vfmul` +
`__riscv_vfadd` **only via generic combine at `-ffast-math`**, which is
inconsistent across versions. Mitigation is *measurement first*: WP8
inspects generated assembly for `vfmacc`/`vfmadd` on the LBM collide
kernel; if contraction does not happen, add a small peephole in
`SelectIntrinsicsRvv.op_intrinsic` — localized, no IR change. The full
single-width family covers every add/sub arrangement, so the peephole is
a complete pattern match, not a heuristic:

| IR pattern | Intrinsic (`vd` = accumulator operand) | Semantics |
|------------|-----------------------------------------|-----------|
| `PsAdd(c, PsMul(a,b))` / `PsAdd(PsMul(a,b), c)` | `__riscv_vfmacc_vv(c, a, b, VL)` | `c + a·b` |
| `PsSub(PsMul(a,b), c)` | `vfmsac_vv(c, a, b, VL)` | `a·b − c` |
| `PsSub(c, PsMul(a,b))` | `vfnmsac_vv(c, a, b, VL)` | `c − a·b` |
| broadcast-scalar factor | `vfmacc_vf(c, s, b, VL)` etc. | composes with D14 |

(The dest-multiplied twins `vfmadd`/`vfmsub`/`vfnmacc`/`vfnmadd` exist
too; the register allocator picks between acc- and dest-forms — the
peephole only needs the three acc-forms above.) Flag as likely-needed
for LBM performance parity.

### D13. RNG (Philox) and short-array (tuple) types

- `PsShortArrayType(PsVectorType(f32, L), 4)` →
  [RVV](#rvv) tuple type `vfloat32m{l}x4_t`; `subscript_intrinsic` →
  `__riscv_vget_v_f32m{l}x4_f32m{l}(arr, idx)` (mirror of `svget4`,
  [`sve.py:268-291`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/sve.py#L268-291)).
- The runtime already contains hand-written [RVV](#rvv)-1.0 Philox
  kernels at [LMUL](#lmul)=1
  ([`philox_rand.h:915-1060`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/include/pystencils_runtime/bits/philox_rand.h#L915-1060)),
  but they run at `vsetvlmax` internally. `rvv.hpp` adds
  `pystencils::runtime::rvv::random::philox_*` wrappers (via
  `_common_rng_engine_intrinsic(..., namespace="rvv")`,
  [`select_intrinsics.py:141-179`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/transformations/select_intrinsics.py#L141-179))
  returning `__riscv_vcreate_v_f32m1x4(...)`.
  Constraints to enforce with clear errors: RNG only at derived
  [LMUL](#lmul)=1, and in VLS mode only when `L == VLMAX(e32m1)` on the
  executing hardware (the guard D8 upgraded to equality for RNG kernels);
  VLA-mode RNG requires threading `vl` through the Philox helpers —
  defer, raise `MaterializationError` initially.
- Glue for later kernel-LMUL ≠ 1 support: the **register-retagging ops**
  `__riscv_vlmul_ext_v_*` / `__riscv_vlmul_trunc_v_*` (and
  `vreinterpret` for same-width type punning) adapt m1 Philox results to
  wider groups with *zero data movement* — the existing Philox code
  already uses `vlmul_trunc` internally
  ([`philox_rand.h:946-947`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/include/pystencils_runtime/bits/philox_rand.h#L946-947)).

### D14. Broadcast folding into scalar-operand (`.vf`/`.vx`) forms

Nearly every [RVV](#rvv) arithmetic op has a **scalar-operand form** that
takes its second operand directly from a scalar register:
`vfadd_vf`, `vfmul_vf`, `vfmin_vf`, `vadd_vx`, `vfmacc_vf`, … — plus
**reverse forms** for the non-commutative cases where the scalar is on
the *left*: `vfrsub_vf` (`s − v`), `vfrdiv_vf` (`s / v`), `vrsub_vx`.

The vectorizer wraps every scalar in an explicit `PsVecBroadcast`
([`ast_vectorizer.py:413-427`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/transformations/ast_vectorizer.py#L413-427)).
On [SVE](#sve)/x86 the backend has no choice but to materialize it
(`svdup`, `_mm*_set1`). On [RVV](#rvv), a broadcast feeding an op can be
**folded into the consuming op's `.vf`/`.vx` form** — no broadcast
instruction, and crucially **no vector register held for the kernel's
lifetime**:

| IR pattern | Folded intrinsic |
|------------|------------------|
| `PsAdd/PsMul(v, PsVecBroadcast(s))` (either side, commutative) | `vfadd_vf(v, s, VL)` / `vfmul_vf` / int `vadd_vx`, `vmul_vx` |
| `PsSub(v, bcast(s))` / `PsSub(bcast(s), v)` | `vfsub_vf` / **`vfrsub_vf`** (`vrsub_vx` int) |
| `PsDiv(v, bcast(s))` / `PsDiv(bcast(s), v)` | `vfdiv_vf` / **`vfrdiv_vf`** |
| `Min/Max(v, bcast(s))` | `vfmin_vf` / `vfmax_vf` / `vmin_vx` … |
| FMA patterns with one broadcast factor (D12) | `vfmacc_vf(c, s, b, VL)` |

**Why this matters for LBM specifically:** a BGK collide kernel carries
10–20 scalar coefficients (ω, the lattice weights `w_i`, the `3.0`,
`4.5`, `1.5` equilibrium constants). Today each becomes a hoisted
broadcast occupying one of the 31 usable vector registers *for the whole
kernel body* — a large slice of the §6 register-pressure budget at
D3Q19/D3Q27 scale. Folding hands all of them back; the scalar operand is
read from the x/f register file at issue, effectively free. Notably,
LBM's `1/rho` becomes a single `vfrdiv_vf(rho, 1.0, VL)` with no
broadcast at all.

**Implementation caveat (the honest part):** by intrinsic-selection time
the driver has usually *hoisted* broadcasts out of the loop
(`EliminateConstants(extract_constant_exprs=True)` +
`HoistIterationInvariantDeclarations` in `_general_optimize`,
[`driver.py:297-307`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/codegen/driver.py#L297-307)),
so operands reach the selector as `PsSymbolExpr` references to a
broadcast *declaration*, not as inline `PsVecBroadcast` nodes. The fold
therefore needs a small backend-local pre-pass in `RvvCpu`: find
declarations `x = PsVecBroadcast(s)` where `s` is a scalar symbol or
constant, re-inline the broadcast at the use sites (the existing
`substitute_symbols` rewrite machinery does this), drop the dead
declarations, then let `op_intrinsic` fold. ~50 lines. Phase: after
correctness is green (WP8), validated by measuring spill counts on the
D3Q19 collide kernel with/without the pass.

## 4. Work packages

Ordered; each WP is landable and testable on its own.

**WP0 — Pre-flight** *(half a day)*
- Check pystencils upstream `master` (i10git) for RVV work in
  `backend/platforms/` — avoid duplication; open a coordination issue
  either way (the SVE author is the natural reviewer).
- Pin the toolchain baseline: **Clang ≥ 18 and GCC ≥ 14** (both fully
  implement the v0.12/v1.0 intrinsics incl. tuple types and `__riscv_vlenb`;
  document `clang-18 --target=riscv64-linux-gnu` and
  `riscv64-linux-gnu-g++-14` invocations). Already satisfied *natively*
  on the `bananapi` board — GCC 14.2 + Clang 18.1.8, intrinsics v0.12
  verified (§7.1). QEMU ≥ 8.x for `-cpu rv64,v=true,vlen=…`.
- Execution environments for tests, in priority order: (a) the
  `bananapi` board — one-time venv setup + the `test.on.bananapi.sh`
  wrapper, §7.1; (b) for x86 CI, a Debian/Ubuntu riscv64 container +
  `qemu-user-static` (binfmt), able to run CPython + pytest + the JIT
  with the native g++ inside the container.

**WP1 — Target, config, JIT flags** *(1 day)*
- D1 enum + detection; `RvvOptions` + `VectorizationOptions.mode`
  (enum `VectorizationMode.FIXED | STRIPMINE`, default `FIXED`) per D2.
- [`compiler_info.py`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/jit/cpu/compiler_info.py#L107-124):
  `Target.RISCV_RVV` → `-march=rv64gcv` plus, when `vlen` is configured,
  `_zvl{vlen}b` appended to the march string; optionally
  `-mrvv-vector-bits=zvl` in VLS mode (this exact combination verified
  working with GCC 14.2 on the K1, §7.1).
  `CurrentCPU` on riscv64 hosts: **`-march=native` does not work** —
  verified rejected by GCC 14.2 on the K1 (§7.1). Synthesize an explicit
  `-march=` string from the parsed `/proc/cpuinfo` ISA line instead
  (drop unknown vendor tokens); Clang additionally accepts
  `-mcpu=native`/`-mcpu=spacemit-x60`, usable when Clang is the JIT
  compiler. Note the blast radius (§7.1 baseline item 3): `CompilerInfo`
  defaults its *own* `target` to `CurrentCPU`, so this single fix is
  what un-breaks **all** default-JIT compiles on riscv64, including
  plain `GenericCPU` kernels — it is the gate to running any part of
  the suite on the board.
- Hardware acceptance for this WP (§7.1 baseline item 4): the currently
  red `tests/test_quicktests.py` + `test_index_kernels.py` run on
  `bananapi` turns fully green, and the vectorization quicktest un-skips
  by detecting `RISCV_RVV`.
- Unit tests: enum algebra, flag emission, detection parsing against
  canned `/proc/cpuinfo` strings (incl. tricky ISA strings:
  `rv64imafdcv_zicsr_zvl256b`, `rv64gc_xtheadvector` → *no* RVV-1.0).

**WP2 — `RvvCpu` platform, VLS mode, core ops** *(3–5 days)*
- New [`backend/platforms/rvv.py`](https://i10git.cs.fau.de/pycodegen/pystencils/-/tree/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms):
  `RvvCpu(GenericVectorCpu)` (ctor: `vlen`, `mode`, `check_vlen`),
  `RvvSelectionContext`, `SelectIntrinsicsRvv` implementing the
  normative table (§5): types via D2, ops, broadcasts, D5 constants,
  D6 memory, D7 reductions, D8 guard. Driver dispatch.
- Export from `platforms/__init__.py`; `required_headers = {'"pystencils_runtime/rvv.hpp"'}`.
- Codegen-only unit tests (no RISC-V hardware needed): extend
  [`tests/nbackend/test_vectorization.py`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/tests/nbackend/test_vectorization.py)
  `get_setups()` with `RvvCpu` setups (f64×4@vlen256 ⇒ m1, f64×8@vlen256
  ⇒ m2, f32×8 ⇒ m1, f32×16 ⇒ m2, i32/i64 variants) — these tests
  construct platforms explicitly, so they exercise codegen even on x86
  CI up to the compile step; gate the compile/run stage on the
  availability of a riscv toolchain (pytest marker `rvv_compile`,
  `rvv_run`).

**WP3 — Runtime header + RNG + tuple types** *(1–2 days)*
- `include/pystencils_runtime/rvv.hpp`: `#include <riscv_vector.h>`,
  Philox wrappers (D13). Tuple-type and `vget` support in the selector.
- Port the [SVE](#sve) RNG test coverage
  ([`tests/kernelcreation/test_rng.py`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/tests/kernelcreation/test_rng.py)).

**WP4 — VLS execution validation on hardware + QEMU** *(2 days, mostly CI plumbing)*
- Primary: full vectorization + quicktest suites natively on `bananapi`
  via `test.on.bananapi.sh` (§7.1). The D8 guard negative test runs on
  real silicon: a kernel built for `vlen=512` must **trip the guard**
  (not corrupt data) on the VLEN=256 board.
- CI job (x86): the same suites inside the riscv64 container at
  `vlen=128` and `vlen=256`, including the guard-trip scenario.
- First LBM smoke test: run
  `python/learn-lb-pystencil/lb-pystencils.py` (collide kernel only,
  small grid, fixed steps) on the board with `target=Target.RISCV_RVV`,
  `lanes/vlen` set, compare against the NumPy reference already built
  into the script.

**WP5 — Casts, integer ops, completeness sweep** *(2–3 days)*
- D11 same-width casts (f→i strictly via `_rtz_` variants — include the
  negative-halfway-value semantics test against the scalar path), then
  widening/narrowing (`vfwcvt`/`vfncvt`, `vsext_vf*`/`vzext_vf*`);
  int div/rem, bitwise, neg; `PsVecHorizontal` for int types.
- Property test: for every `(op, dtype, lanes, vlen)` in the support
  matrix, generated code compiles under both GCC and Clang cross
  compilers (catches intrinsic-name typos cheaply — this is where most
  backend bugs live, cf. the suffix-heavy naming scheme).

**WP6 — VLA machinery** *(4–6 days; the design-risk WP)*
- D9 steps 1–5: `PsVecStripmineLanes`, `AxisExpansion.stripmine`,
  `PsSimdAxis.active_lanes`, `MaterializeAxes` plumbing + modulo-variable
  tagging, `SelectIntrinsicsRvv` active-lanes stack, loop-strategy
  branch, D10 rank-1 chunking.
- D5 audit (constant folding must not destroy `vid` progressions),
  D7 `_tu` accumulator commit.
- IR-level unit tests on x86: with the `GenericCpu` lowering of
  `PsVecStripmineLanes` to `min(r, L_nom)`, the stripmined loop structure
  is executable *on the host* — assert loop shape, tail behavior, and
  reduction correctness without any RISC-V toolchain. This decouples the
  IR work from the backend work.

**WP7 — VLA validation: the VLEN sweep** *(1–2 days)*
- The defining test (§2.2): identical kernel binary — natively on
  `bananapi` at [VLEN](#vlen)=256, plus the board's own `qemu-riscv64`
  (and/or the CI container) at `vlen ∈ {128, 512, 1024}` —
  bit-identical field outputs
  (f64; `vfredosum` keeps reductions orderd — note the *order changes*
  with VLEN for a stripmined reduction, so reduction tests compare
  against a tolerance, not bitwise; document this).
- Tail-focused cases: inner extents `1`, `L_nom−1`, `L_nom+1`, primes.
- Reduction kernels (`test_reduction.py` matrix) in VLA mode.

**WP8 — LBM bring-up, performance, walberla** *(1 week, parallelizable)*
- `lb-pystencils.py` full lid-driven-cavity run in both modes; extend the
  script with a `--target/--mode` switch.
- Assembly inspection for `vfmacc` contraction (D12); add the peephole
  if missing. Measure MLUP/s **on the `bananapi` board** (§7.1 —
  `perf stat` via `sscofpmf`, thread pinning); QEMU numbers are *not*
  performance data.
- D14 broadcast-folding pre-pass; validate by comparing spill counts and
  live vector-register usage on the D3Q19 collide kernel with/without.
- LMUL study for D3Q19-class kernels (§6); `vfrec7` fast-reciprocal
  benchmark (§6 division bullet).
- walberla (per [`walberla-codegen-flow.md`](walberla-codegen-flow.md)):
  sweepgen `build_config.py` target branch + CMake vars
  (`WALBERLA_RISCV_RVV`, `WALBERLA_RVV_VLEN`, mode), `-march=rv64gcv…`
  in `GNU.cmake`/`Clang.cmake` mirroring the SVE blocks, optional
  toolchain file for cross builds. Path A (legacy `pystencils_walberla`)
  stays untouched — it targets pystencils 1.x and cannot host this
  backend anyway.

Sizing: **VLS production-ready ≈ 2 weeks (WP0–WP5)**; **VLA ≈ +1.5–2
weeks (WP6–WP7)**; LBM/walberla integration ≈ 1 week, overlappable.

## 5. Normative intrinsic mapping (RVV-1.0, `{w}` = SEW, `{l}` = derived LMUL)

Types: `PsVectorType(f{w}|i{w}|u{w}, L)` → `vfloat{w}m{l}_t` /
`vint{w}m{l}_t` / `vuint{w}m{l}_t`; suffix `{t} ∈ f|i|u`, type-suffix
style analogous to `ArmCommonIntrinsics._op_type_suffix`
([`neon.py:88-99`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/backend/platforms/neon.py#L88-99)).
`VL` denotes the current count operand (constant `L` in VLS, `vl` symbol
in VLA — D3).

| IR node | Float | Integer |
|---------|-------|---------|
| `PsAdd` | `__riscv_vfadd_vv_f{w}m{l}(a,b,VL)` | `__riscv_vadd_vv_{t}{w}m{l}` |
| `PsSub` | `vfsub_vv` | `vsub_vv` |
| `PsMul` | `vfmul_vv` | `vmul_vv` |
| `PsDiv` | `vfdiv_vv` | `vdiv_vv` / `vdivu_vv` |
| `PsIntDiv`, `PsRem` | — | `vdiv(u)`, `vrem(u)` |
| `PsNeg` | `vfneg_v` | `vneg_v` |
| `PsBitwiseAnd/Or/Xor` | — | `vand_vv`/`vor_vv`/`vxor_vv` |
| `PsLeftShift`/`PsRightShift` | — | `vsll_vv` / `vsrl_vv`(u), `vsra_vv`(s) |
| `PsVecBroadcast` | `__riscv_vfmv_v_f_f{w}m{l}(s,VL)` | `__riscv_vmv_v_x_{t}{w}m{l}(s,VL)` |
| counter/progression constant | — | `vid.v` construction (D5) |
| `PsVecMemAcc` load, contiguous | `__riscv_vle{w}_v_f{w}m{l}(p,VL)` | `vle{w}` |
| … load, strided | `__riscv_vlse{w}_v_…(p, bstride, VL)` | dual |
| `PsVecMemAcc` store | `vse{w}` / `vsse{w}` | dual |
| `PsVecHorizontal` Add | `vfredosum_vs` + `vfmv_s_f`/`vfmv_f_s` (D7) | `vredsum_vs` + `vmv_s_x`/`vmv_x_s` |
| … Min/Max | `vfredmin_vs`/`vfredmax_vs` | `vredmin(u)`/`vredmax(u)` |
| `MathFunctions.Abs` | `vfabs_v` | `PsNeg`+`vmax` or raise (parity: SVE has int abs; RVV lacks it — synthesize) |
| `MathFunctions.Min/Max` | `vfmin_vv`/`vfmax_vv` | `vmin(u)`/`vmax(u)` |
| `MathFunctions.Sqrt` | `vfsqrt_v` | — |
| `PsCast` f→i same width | `vfcvt_rtz_x_f_v` (**`_rtz_`**, C trunc semantics — D11) | |
| `PsCast` i→f same width | `vfcvt_f_x_v` / `vfcvt_f_xu_v` | |
| `PsCast` f32↔f64 | `vfwcvt_f_f_v` / `vfncvt_f_f_w` (D11) | widening: `vsext_vf{2,4,8}`/`vzext_vf{2,4,8}`; narrowing: `vncvt_x` |
| op with one broadcast operand | `.vf` forms incl. `vfrsub_vf`/`vfrdiv_vf` (D14) | `.vx` forms incl. `vrsub_vx` |
| contracted `a·b ± c` (peephole, D12) | `vfmacc_vv/_vf`, `vfmsac`, `vfnmsac` | `vmacc`/`vnmsac` |
| `PsVecStripmineLanes` (VLA) | `__riscv_vsetvl_e{w}m{l}(remaining)` | same |
| `PsShortArrayType` subscript | `__riscv_vget_v_f{w}m{l}x{n}_f{w}m{l}` | same |
| RNG engine | `pystencils::runtime::rvv::random::philox_*` (D13) | |

Everything not in this table raises `MaterializationError` with the IR
node and dtype in the message — silent scalar fallback is worse than a
loud error (matches SVE backend philosophy).

### 5.1 Full-intrinsics sweep — adopted vs rejected

The complete v12 intrinsic surface (cheat-sheet in the references,
~1046 ops incl. every extension) was reviewed against this plan.

**Adopted into the design** (beyond the obvious base ops):
`_rtz_` conversion variants (D11), `vsext_vf*`/`vzext_vf*` single-op
integer extension (D11), the full FMA family (D12), `.vf`/`.vx`
scalar-operand and reverse forms (D14), `vid_v` (D5),
`vslide1down`+`vundefined` constant chains (D5), `vfrec7_v`/`vfrsqrt7_v`
(§6 fast-reciprocal option), segment loads/stores (§6, deferred),
`vlmul_ext`/`vlmul_trunc`/`vreinterpret` retagging (D13),
`vcreate`/`vget` tuple ops (D13), `_tu` policy variants (D7).

**Reviewed and rejected/deferred**, with reasons:

| Family | Verdict |
|--------|---------|
| Fault-only-first loads (`vle{w}ff`) | For data-dependent loop exits (strlen-style); pystencils iteration spaces are affine — no consumer. |
| Mask ops (`vmseq`/`vmflt`…, `vmand`…, `vmerge`, `viota`, `vcpop`, `vfirst`, `vcompress`) | Only needed for masked conditional vectorization — an explicit non-goal (§0). Names confirm the future path: compare → `vbool` mask → `vmerge`/masked ops. |
| Fixed-point (`vsadd`, `vaadd`, `vsmul`, `vssra`, `vnclip`) | DSP saturating arithmetic; no pystencils IR node maps to it. |
| `vrgather`, Zvzip (`vzip`/`vunzipe`/`vpaire`…) | In-register permutes — attractive *later* for in-register stencil-neighbor reuse and AoS↔SoA, but nothing in the vectorizer produces shuffles today, and Zvzip is an unratified draft with no silicon. Watch-list only. |
| Zvbb/Zvbc (`vror`, `vandn`, `vclz`, `vclmul`…), crypto (Zvk\*) | Out of domain. (`vror` would help a Threefry-style RNG; Philox is mul/xor — no gain.) |
| BF16 (Zvfbfmin/Zvfbfa), FP8 (Zvfofp8min), dot products (Zv\*dota\*), Zvabd | ML-focused, largely unratified drafts, no shipping silicon; irrelevant to f32/f64 stencils. |
| FP16 via **Zvfh** | The one deferral worth a roadmap entry: parity with `ARM_NEON_FP16`/`X86_AVX512_FP16` costs little — march token `_zvfh`, and the §5 suffix machinery already generalizes (`f16`, `vfloat16m{l}_t`). Defer until an fp16 LBM use case exists. |

## 6. LBM-specific guidance

- **Layout:** `fzyx` (SoA) with `assume_inner_stride_one=True` keeps
  every PDF access contiguous ⇒ pure `vle/vse`, no strided ops in the
  hot loop. AoS (`zyxf`) would hit `vlse/vsse` — supported but
  discouraged; [segment](#segment) loads/stores are the proper AoS
  answer, and the family is complete (`vlseg{n}e{w}`/`vsseg` unit-stride,
  `vlsseg`/`vssseg` strided, `vloxseg`/`vluxseg` indexed, n ≤ 8) — note
  D3Q19/D3Q27 exceed the n ≤ 8 field limit per op, so AoS PDFs would
  need multiple segment ops per cell. The tuple-type machinery they
  consume (`vfloat64m1x{n}_t`, `vget`/`vcreate`) is already required by
  D13, so the marginal cost of adding them later is small. Possible
  later optimization, *not* in this plan's critical path.
- **Register pressure vs [LMUL](#lmul):** a D3Q19 collide kernel holds
  ~19 PDFs + moments + constants live; at [LMUL](#lmul)=1 there are 31
  usable vector registers (v0 reserved conceptually for masks), at
  [LMUL](#lmul)=2 only 15 usable groups, at [LMUL](#lmul)=4 just 7 —
  spills are certain at m4, likely at m2 for D3Q19/D3Q27.
  **Default derived LMUL should land at m1 for the default dtype**
  (i.e. recommend `lanes = vlen/64` for f64). Treat m2 as a benchmark
  point, not the default. This contradicts generic "bigger LMUL = faster"
  advice because LBM collide is register-hungry, not
  instruction-issue-bound. **The first pressure-relief lever is D14
  broadcast folding** — it returns the 10–20 registers pinned by ω,
  `w_i`, and the equilibrium constants before any LMUL compromise is
  considered.
- **Division:** BGK has one reciprocal (`1/rho`) per cell. Exact path:
  `vfrdiv_vf(rho, 1.0, VL)` (one op, no broadcast — D14). Fast path,
  behind an accuracy-relaxing option: `vfrec7_v` gives a 7-bit estimate,
  refined by Newton–Raphson (`e ⇒ e·(2 − rho·e)`, one `vfmul` + one
  `vfnmsac` per step) — 2 steps reach f32 precision, 3 steps f64;
  `vfrsqrt7_v` is the analogue if a `1/sqrt` ever appears. Out of the
  correctness scope; benchmark in WP8.
- **VLA payoff:** boundary/slice kernels (`build_boundary_stream_kernel`
  in `lb-pystencils.py` iterates single rows/columns) and small grids
  benefit most — today those inner extents can be *smaller than* `L`, so
  VLS runs them fully in the scalar remainder. VLA runs them vectorized
  with one `vsetvl`.
- **What to benchmark (WP8):** MLUP/s for collide, stream, fused
  collide-stream; VLS(m1) vs VLS(m2) vs VLA; assembly check for
  `vfmacc`, `vsetvli` placement (should be hoisted/immediate in VLS),
  spill counts (`-fverbose-asm` / `llvm-mca` where useful).

## 7. Testing strategy (summary)

| Layer | Needs | What it catches |
|-------|-------|-----------------|
| Codegen unit tests (x86 host) | nothing special | type/LMUL derivation, intrinsic names, loop shapes, D5/D7/D9 IR properties, `GenericCpu` lowering of `PsVecStripmineLanes` |
| Cross-compile tests | `clang-18 --target=riscv64…` or `riscv64-…-g++-14` | intrinsic-name and type errors across the whole op×dtype matrix |
| Execution tests | **`bananapi` board (§7.1, primary)** or riscv64 container + `qemu-user-static` | end-to-end numerics; **D8 guard trip test**; RNG parity |
| VLEN sweep (VLA) | native run @256 on the board + `qemu-riscv64` (present *on the board*) at `vlen ∈ {128,512,1024}`; or the container | length-agnosticism — the VLA acceptance gate |
| Hardware performance | `bananapi` (SpacemiT K1, [VLEN](#vlen)=256, `sscofpmf` perf counters) | real MLUP/s, `vsetvl` cost, spills |

CI note: the existing test parametrization keys off
`Target.available_vector_cpu_targets()`
([`test_vectorization.py:120-122`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/tests/nbackend/test_vectorization.py#L120-122)),
which hides RVV setups on x86 CI. Restructure so codegen-only assertions
always run and only the compile/execute stages are gated on markers.

### 7.1 Hardware-in-the-loop TDD on the Banana Pi F3 (`bananapi`)

Real RVV-1.0 hardware is available and becomes the **primary
execution-test target**, demoting the QEMU container to CI-only duty.
Development is test-driven with the board in the inner loop: every op,
guard, and mode lands as (1) a failing test written first, (2) codegen
asserts that pass on the x86 host, (3) a compile+run pass on the board
in the same sitting.

**The board — facts verified live on 2026-07-04:**

| Property | Value |
|----------|-------|
| Machine | Banana Pi F3, SpacemiT K1 (8× X60), `ssh bananapi`, kernel 6.6.36 riscv64, 3.7 GiB RAM, 8 cores |
| Vector unit | **[VLEN](#vlen)=256** (`__riscv_vlenb()`=32); `vsetvlmax`: e64m1=4, e32m1=8, e64m8=32 |
| ISA string | `rv64imafdcv_…_zve64d_…_zvfh_zvfhmin_…_sscofpmf_…` — full `v`, **`Zvfh`** (vector fp16!), `sscofpmf` (HW perf counters) |
| Compilers (native) | GCC 14.2.0 and Clang 18.1.8 — both **meet the WP0 baseline on-device**; `__riscv_v_intrinsic = 12000` (v0.12, exactly the cheat-sheet's version) |
| Python | 3.12.3 with numpy 1.26.4 + sympy 1.12 preinstalled; **pytest missing** (venv setup below) |
| Also present | `qemu-riscv64` user-mode — the VLA VLEN sweep can run *on the board itself* |
| Disk caveat | `/home` 85% full (4.4 G free) — keep venvs lean, clean JIT caches |

**Two plan corrections discovered by probing the hardware** (exactly why
the board belongs in the loop):

1. **The kernel's ISA string carries no `Zvl256b` token** despite
   VLEN=256 — D1's detection must *not* rely on `Zvl*` tokens for the
   VLEN floor; the authoritative probe is runtime
   (`__riscv_vlenb()`/`vsetvlmax`, or a tiny probe binary from the JIT).
2. **`-march=native` is rejected by the board's GCC 14.2**
   (`ISA string must begin with rv32 or rv64`). `Target.CurrentCPU` on
   riscv64 must therefore synthesize an explicit `-march=` string from
   the parsed `/proc/cpuinfo` ISA line instead (Clang additionally
   accepts `-mcpu=spacemit-x60` — verified). The VLS flag combination
   `-march=rv64gcv_zvl256b -mrvv-vector-bits=zvl` compiles and runs
   correctly on-device (verified).

**Deployment mechanics** (`push.to.sh` in the repo root):

```bash
bash push.to.sh bananapi        # zip repo → rsync → wipe & unzip at
                                # bananapi:/home/bananapi/saleh/my-e4-ws
ssh bananapi 'cd /home/bananapi/saleh/my-e4-ws && <command>'
```

⚠ The script **deletes and re-creates the remote repo directory on every
push** (`rm -rf` + `unzip`). Consequences for the loop:

- Anything persistent lives *outside* the repo dir:
  `/home/bananapi/saleh/venv` (Python env), `~/.cache` (JIT/ccache).
- No editable installs of the submodule (`pip install -e` would dangle
  after a push). Instead do what `lb-pystencils.py` already does: put
  `submodules/pystencils/src` on `PYTHONPATH` — pushes then never
  invalidate the environment.

**One-time board setup:**

```bash
ssh bananapi 'python3 -m venv --system-site-packages /home/bananapi/saleh/venv'
ssh bananapi '/home/bananapi/saleh/venv/bin/pip install \
  "sympy~=1.14" appdirs joblib pyyaml fasteners py-cpuinfo pytest'
#   heavy compiled packages via apt — PyPI has no riscv64 wheels,
#   pip would build them from source for hours:
ssh bananapi 'sudo apt install python3-scipy python3-matplotlib'
#   optional, only for the WP3 RNG parity tests (source build, needs gcc — present):
ssh bananapi '/home/bananapi/saleh/venv/bin/pip install "randomgen>=2.1"'
```

Notes: `--system-site-packages` reuses the preinstalled numpy 1.26 (fine,
pystencils needs ≥ 1.8) and keeps the venv small on the 85%-full disk.
The system **sympy 1.12 is too old** — pystencils 2.0b1 pins
`sympy~=1.14`, so the venv installs its own (pure Python, shadows the
system copy). `matplotlib` is only needed by `lb-pystencils.py`; run it
headless with `MPLBACKEND=Agg`.

**Setup status: done and verified on the board (2026-07-04):**
Python 3.12.3 venv with sympy 1.14.0, pytest 9.1.1, appdirs, joblib,
PyYAML, fasteners, py-cpuinfo 9.0.0; scipy 1.11.4 + matplotlib 3.6.3 via
system site-packages. Repo present at
`/home/bananapi/saleh/my-e4-ws`.

**The inner loop, one command.** Add a thin wrapper
`test.on.bananapi.sh <pytest-args>` next to `push.to.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
bash "$(dirname "$0")/push.to.sh" bananapi
ssh bananapi "cd /home/bananapi/saleh/my-e4-ws/submodules/pystencils \
  && PYTHONPATH=src /home/bananapi/saleh/venv/bin/python -m pytest \
       -o addopts='' -x -q $*"
```

The `-o addopts=''` is required: the venv's **pytest 9.1 reads the
`[tool.pytest]` table** in pystencils' `pyproject.toml` (pytest 8 ignored
it) and its `addopts` demand `pytest-cov` (`--cov-config=…`) plus
`--doctest-modules`; the override sidesteps both without extra installs
(verified failing without, passing with, on the board).

The cadence: write failing test locally → make codegen asserts
green on x86 → `bash test.on.bananapi.sh -k <new_test>` → green on real
silicon. Push+unzip round-trip is fast enough for per-change use; use
`-k`/`-x` to keep board runs seconds-scale (8 cores, but only 3.7 GiB —
don't run the full matrix with `pytest -n 8`).

**What runs where, per work package:**

- **WP1** — detection test runs on the board (`RISCV_RVV` must appear in
  `available_vector_cpu_targets()`, `CurrentCPU` must produce a
  compilable `-march`, cf. correction 2).
- **WP2 onward, per-op TDD:** each intrinsic mapping lands with a
  `VectorTestSetup` case; board profile `lanes=4/f64`, `lanes=8/f32`
  (`vlen=256`, LMUL=m1) and `lanes=8/f64`, `lanes=16/f32` (m2). The JIT
  compiles **natively on the board** — no cross toolchain in the inner
  loop at all.
- **WP4 (D8 guard):** build with `vlen=512` on the board → the guard
  *must* trip; build with `vlen=256` → must pass. A real negative test
  on real hardware, not just QEMU.
- **WP6/WP7 (VLA):** correctness natively at VLEN=256; the sweep's other
  points via the board's own `qemu-riscv64 -cpu rv64,v=true,vlen=128`
  (and 512/1024) re-running the same test binary; the x86-CI container
  remains the exhaustive sweep in CI.
- **WP8 (performance):** the board is the *only* real performance
  source. `sscofpmf` + `perf stat` for cycles/instructions; pin threads
  (8× X60 in two clusters — check `lscpu` topology before OpenMP
  numbers); MLUP/s on the lid-driven-cavity case; assembly inspection
  can also happen on-device (`objdump -d` of the JIT-cached `.so`).
- **RNG kernels:** the D13 equality guard (`L == VLMAX(e32m1)` = 8) is
  satisfiable natively at `lanes=8`, f32 — Philox parity tests run on
  hardware.
- **Zvfh bonus:** the K1 implements vector fp16 — when the §5.1 FP16
  deferral is ever picked up, this board can validate it natively.

**Verified end-to-end baseline (2026-07-04)** — smoke run of the pinned
pystencils 2.0b1 on the board, before any RVV work:

1. **The full JIT chain works natively on riscv64.** A scalar kernel
   built with an explicit `GccInfo(target=Target.GenericCPU)` compiles
   with the board's g++ 14.2 and runs correctly
   (`dst = 2·src + 1` → `[1, 3, …, 15]`). No porting work is needed in
   the JIT machinery itself — only in target detection and flag
   selection.
2. **Detection baseline:** `Target.available_vector_cpu_targets()`
   returns `()` with the warning *"unknown platform riscv64"*
   ([`target.py:272-277`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/codegen/target.py#L272-277));
   `Target.auto_cpu()` falls back to `GenericCPU`. This is the exact
   gap D1 fills.
3. **The default JIT fails on the board** with
   `g++: error: '-march=native': ISA string must begin with rv32 or
   rv64`. Scope is wider than expected: `CompilerInfo`'s *own* `target`
   field defaults to `Target.CurrentCPU`
   ([`compiler_info.py:25`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/jit/cpu/compiler_info.py#L25)),
   so **every** kernel compiled without an explicit `CompilerInfo` hits
   `-march=native` — even kernels whose codegen target is `GenericCPU`
   (verified: `test_indexed_kernel[_CPU]` fails for this reason despite
   never requesting vectorization).
4. **TDD entry state, recorded as the red baseline:**
   `pytest tests/test_quicktests.py tests/kernelcreation/test_index_kernels.py
   -o addopts=''` on the board today gives
   **2 failed** (both `-march=native`), 1 skipped (no vector target
   detected), 1 xfailed. WP1's acceptance criterion on hardware is
   precisely: this run turns green (and the skip disappears once
   `RISCV_RVV` is detected).

## 8. walberla integration (delta view)

Covered in WP8; unchanged in substance from
[`rvv-implementation-plan.md` §B](rvv-implementation-plan.md) minus the
0.7 branches, plus:

- CMake exposes `WALBERLA_RVV_MODE` (VLS/VLA) and `WALBERLA_RVV_VLEN`;
  sweepgen maps them onto `cpu.vectorize.mode` / `cpu.rvv.vlen` /
  `cpu.vectorize.lanes`.
- In VLS mode CMake also appends `-mrvv-vector-bits=zvl` +
  `-march=…_zvl${VLEN}b` — the walberla analogue of the existing
  `-msve-vector-bits` probing in
  [`GNU.cmake:26-32`](https://i10git.cs.fau.de/walberla/walberla/-/blob/0c8ed8c90a3220f459a5d82868ddd66d2f1a7837/cmake/compileroptions/GNU.cmake#L26-32).
  In VLA mode, only the `Zvl` floor goes into `-march`, never
  `-mrvv-vector-bits`.

## 9. Risks and open questions

1. **Upstream collision** — pystencils 2.0 is under active development
   (this pin is `release/2.0b1`+2); the axes/vectorizer machinery is
   new-ish and may shift. Mitigation: WP0 coordination; keep VLA IR
   additions (`PsVecStripmineLanes`, `active_lanes`) minimal and
   upstream-friendly (they are backend-agnostic by design — SVE could
   adopt them with `whilelt`).
2. **`vsetvl` overhead in VLA inner loops** — one `vsetvli` per
   stripmine step; on some cores (esp. in-order) this is nearly free, on
   others it serializes. If it shows up: hoist a fast-path
   (`if remaining ≥ VLMAX` → `vsetvlmax` variant) — loop versioning,
   doable later inside `stripmine()` without IR changes.
3. **Compiler maturity** — RVV intrinsic codegen quality varies between
   GCC 14/Clang 18/newer; register allocation around LMUL≥2 has known
   weak spots. Pin toolchain versions in CI; keep both compilers in the
   compile matrix.
4. **Transition-band `vl` splitting** (primer eq 8): QEMU grants
   `min(AVL, VLMAX)` but real cores may split the last two iterations
   unevenly. Our loop is correct for any granted `vl ≥ 1` by
   construction (D9) — but never assert `vl == min(...)` in tests.
5. **Reduction reproducibility across VLEN in VLA mode** — `vfredosum`
   is ordered *within* a vector, but stripmine chunking changes the
   summation tree with VLEN. Document: VLA reductions are
   run-to-run-deterministic on fixed hardware, not bit-portable across
   VLEN (VLS reductions at fixed lanes are).
6. **`__riscv_vlenb()` intrinsic availability** (D8) — present in recent
   intrinsics versions; fallback `__riscv_vsetvlmax_e8m1() * 8`
   is universally available. Decide in WP2.

## 10. Definition of done ("proper and full")

- [ ] `Target.RISCV_RVV` selectable via `create_kernel`, auto-detected on
      riscv64 hosts, JIT-compilable and runnable (host or QEMU).
- [ ] VLS mode: full §5 op/dtype matrix for f32/f64/i32/i64 (+u variants),
      strided access, reductions, RNG; D8 guard verified to trip.
- [ ] VLA mode: stripmined kernels pass the VLEN sweep bit-identically
      (fields) / within tolerance (reductions); no scalar remainder loops
      in emitted code; reductions correct on ragged tails.
- [ ] LBM lid-driven cavity (`lb-pystencils.py`) matches its NumPy
      reference in both modes **natively on the `bananapi` board** (and
      under QEMU in CI), with MLUP/s recorded as the performance
      baseline.
- [ ] walberla sweepgen builds an RVV sweep from CMake config alone.
- [ ] Docs: user-facing how-to (choose mode/`vlen`/`lanes`; LMUL
      guidance from §6) in pystencils' docs, plus updates to these notes.

---

## Glossary

Definitions for terms used in this file; see
[`rvv-isa-primer.md`](rvv-isa-primer.md) for the full reference.

<a id="rvv"></a>
**RVV** — *RISC-V Vector extension*, the ratified `V` extension (1.0,
late 2021). A scalable vector [ISA](#isa): vector length is read from a
CSR at runtime, not encoded in instructions.

<a id="isa"></a>
**ISA** — *Instruction Set Architecture*.

<a id="sve"></a>
**SVE** — ARM's *Scalable Vector Extension*; pystencils' only existing
scalable backend and the structural template for the RVV platform class.

<a id="vls"></a>
**VLS** — *Vector Length Specific*: code generated for a fixed,
compile-time lane count and assumed [VLEN](#vlen). What the SVE backend
does today; mode 1 of this plan.

<a id="vla"></a>
**VLA** — *Vector Length Agnostic*: code correct and fully utilizing
hardware for any legal [VLEN](#vlen), via a [stripmining](#stripmining)
loop; mode 2 of this plan.

<a id="vlen"></a>
**VLEN** — width of one vector register in bits;
implementation-defined, power of two (128 on most dev boards, 256 on
SpacemiT K1, 512 on Andes AX45MPV).

<a id="elen"></a>
**ELEN** — maximum supported element width ([SEW](#sew)) in bits;
typically 64.

<a id="sew"></a>
**SEW** — *Selected Element Width*: bits per element in the current
configuration (8/16/32/64).

<a id="lmul"></a>
**LMUL** — *Length Multiplier*: how many architectural registers (or
what fraction of one) form a register group; legal values
1/8…8. Lane count per op = `VLEN·LMUL/SEW`.

<a id="emul"></a>
**EMUL** — *Effective LMUL* of a memory operand whose element width
differs from [SEW](#sew): `EMUL = (EEW/SEW)·LMUL`.

<a id="vlmax"></a>
**VLMAX** — `VLEN·LMUL/SEW`, the maximum grantable [`vl`](#vl) for a
configuration.

<a id="vl"></a>
**vl** — active vector length CSR: the number of leading lanes the next
op processes. Set only by [`vsetvl`](#vsetvl); every RVV intrinsic takes
it as an explicit trailing argument.

<a id="vsetvl"></a>
**vsetvl / vsetvli / vsetivli** — instructions that set `vtype`
(SEW/LMUL/policies) and [`vl`](#vl); intrinsic
`__riscv_vsetvl_e{sew}m{lmul}(avl)` returns the *granted* count, which
in the band `VLMAX < avl < 2·VLMAX` may be less than
`min(avl, VLMAX)`.

<a id="lane"></a>
**lane** — one element position within a vector register group.

<a id="predicate"></a>
**predicate** — per-lane active mask. SVE: `svbool_t` threaded through
every intrinsic; RVV: the `v0` mask register (unused in this plan) plus
the [`vl`](#vl) prefix count (used everywhere).

<a id="stripmining"></a>
**stripmining** — chunking a loop into vector-sized pieces where each
iteration asks the hardware for the next chunk size
([`vsetvl`](#vsetvl)) and advances by the granted [`vl`](#vl); the
canonical [VLA](#vla) idiom.

<a id="gather"></a>
**gather** / <a id="scatter"></a>**scatter** — indexed vector
load/store (`vluxei`/`vsuxei`); RVV-1.0 indices are **byte** offsets.
Not needed by the current vectorizer (native strided ops cover
pystencils' access patterns).

<a id="segment"></a>
**segment load/store** — `vlseg{n}e`/`vsseg{n}e`: AoS-transposing
memory ops; potential later optimization for `zyxf` layouts.

<a id="intrinsic"></a>
**intrinsic** — C-level function mapping ~1:1 to a machine instruction;
this backend emits `__riscv_*` intrinsics from
`<riscv_vector.h>`.

<a id="jit"></a>
**JIT** — pystencils' just-in-time compilation of generated kernels via
the system C++ compiler
([`jit/cpu/compiler_info.py`](https://i10git.cs.fau.de/pycodegen/pystencils/-/blob/20d7dcf07372bf89f41f719e4bcc2bf8646a3c9f/src/pystencils/jit/cpu/compiler_info.py)).

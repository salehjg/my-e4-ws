# RVV ISA primer — terminology, versions, and the 0.7 → 1.0 deltas

Reference glossary for the rest of the notes. Uses the wording from the
RISC-V "V" Vector Extension specification and the official intrinsic
specification. Where 0.7.1 and 1.0 disagree, both are listed.

References:
- RVV 1.0 ratified spec: <https://github.com/riscv/riscv-v-spec/releases/tag/v1.0>
- RVV C intrinsic spec: <https://github.com/riscv-non-isa/rvv-intrinsic-doc>
- RVV 0.7.1 (legacy / T-Head): <https://github.com/riscv/riscv-v-spec/releases/tag/0.7.1>
- T-Head C906 ISA manual ("xthead" extensions): vendor doc only, no stable URL
- LLVM `xtheadvector` extension (the standardized way to reach 0.7-era cores):
  <https://llvm.org/docs/RISCVUsage.html>

## 1. What RVV is

RVV is the standard vector extension to RISC-V, identified by the **`V`**
ISA-string token. It adds a vector register file, a small set of control
CSRs, and a few hundred instructions for arithmetic, memory, mask, and
reduction operations over those registers. The defining design choice is
that **vector length is not encoded in the instruction** — it is read from a
CSR at runtime. This is fundamentally different from x86 SSE/AVX (fixed
width) and similar to ARM SVE (scalable width).

## 2. Architectural state

### Vector register file

- **32 architectural vector registers**: `v0`, `v1`, …, `v31`.
- Each register is **VLEN** bits wide. `v0` is also the *mandatory* mask
  register: when an instruction is masked, the mask source is implicitly `v0`.
- Registers can be **grouped** into larger logical registers via LMUL
  (see below). Grouped registers must be aligned (`v0,v1`, `v4,v5,v6,v7`, …).

### Control CSRs

| CSR        | Purpose                                                                 |
|------------|-------------------------------------------------------------------------|
| `vtype`    | Encodes SEW, LMUL, `vma`, `vta`, `vill`. Set by `vsetvl{i}`.            |
| `vl`       | Active *vector length* — number of elements the next vector op processes. |
| `vstart`   | First element index to process. Non-zero only after a resumed trap.     |
| `vxrm`     | Fixed-point rounding mode.                                              |
| `vxsat`    | Fixed-point saturation flag.                                            |
| `vcsr`     | Combined view of `vxrm`/`vxsat`.                                        |
| `vlenb`    | Read-only: VLEN in bytes (= VLEN/8).                                    |

## 3. The four numbers that govern everything

Every RVV programmer carries these in their head.

### VLEN — vector register width

Implementation-defined width of one vector register, in **bits**. Must be a
power of two. In RVV 1.0 the spec permits VLEN up to 65536. Real silicon
today ships at 128 (SiFive U74-MC + RVV optional), 256 (SpacemiT K1, T-Head
C908), 512 (T-Head TH1520 future, Andes AX45MPV), and 1024+ (research/HPC).
The C906/C910 (RVV-0.7.1) ship at VLEN=128.

### ELEN — maximum element width

Implementation-defined upper bound on **SEW**, in bits. Most cores set
ELEN=64. If ELEN<64, double-width FP ops are unavailable.

### SEW — Selected Element Width

The width of one element *as currently configured*, in bits. Legal values:
**8, 16, 32, 64** (up to ELEN). SEW is part of `vtype` and is set by
`vsetvl{i}`. The same physical register `v8` is interpreted as 16×i8 or
4×i32 depending on the current SEW.

### LMUL — vector register group Length Multiplier

How many architectural registers are *grouped* to form one logical operand.
Legal values in RVV 1.0:

| LMUL setting | Symbol  | Registers used | Notes                                          |
|--------------|---------|----------------|------------------------------------------------|
| 1/8          | `mf8`   | partial of 1   | "fractional LMUL", new in 1.0                  |
| 1/4          | `mf4`   | partial of 1   | new in 1.0                                     |
| 1/2          | `mf2`   | partial of 1   | new in 1.0                                     |
| 1            | `m1`    | 1              | the natural default                            |
| 2            | `m2`    | 2 (aligned)    |                                                |
| 4            | `m4`    | 4 (aligned)    |                                                |
| 8            | `m8`    | 8 (aligned)    |                                                |

Fractional LMUL exists to enable **mixed-width** operations without wasting
registers — e.g. widening a stream of i8 values into i32 results halves the
number of i32 lanes you need.

### VLMAX — derived element count

`VLMAX = (VLEN * LMUL) / SEW`. This is the maximum number of elements you
can request for a given (SEW, LMUL) configuration. `vsetvl{i}` will clamp
`vl` to at most VLMAX.

Worked example: VLEN=256, SEW=32, LMUL=m2 ⇒ VLMAX = 256·2/32 = 16 i32 lanes.

## 4. EEW and EMUL — for memory ops

Memory instructions (loads, stores, indexed ops) can specify their own
**Effective Element Width** and **Effective LMUL** independent of the
current `vtype` SEW/LMUL. This matters for:

- Mixed-width arithmetic: load f32 into an f64-configured stream.
- Indexed memory ops: the index vector's EEW can differ from the data SEW.

The intrinsic spec encodes EEW in the mnemonic: `vle32_v_*` always loads
32-bit elements regardless of current SEW; `vluxei16_v_*` uses a 16-bit
index vector with whatever the data SEW is.

## 5. `vsetvl{i}` — the only way to change `vl` and `vtype`

Three forms:

| Instruction       | Arguments                       | Effect                                      |
|-------------------|---------------------------------|---------------------------------------------|
| `vsetvli rd, rs1, vtypei`  | requested AVL in `rs1`, immediate vtype | sets vtype, returns granted `vl` in `rd` |
| `vsetvl rd, rs1, rs2`      | requested AVL, vtype in `rs2`           | dynamic vtype variant                    |
| `vsetivli rd, uimm, vtypei`| 5-bit immediate AVL                     | for small fixed counts                   |

The "AVL" (Application Vector Length) is what the program *wants* to
process; the hardware returns the actual `vl` granted, which is the
**`min(AVL, VLMAX)`** clamped to the largest power-of-two ≤ AVL when AVL is
in the (VLMAX, 2·VLMAX] range (the "stripmining" tail behaviour).

If the requested `vtype` is unsupported, hardware sets `vill=1`; subsequent
vector ops then trap.

## 6. Tail and mask policies — `vta`, `vma`

Each vector op writes to **active** elements (mask=1 AND index < vl) and may
leave **inactive** elements (mask=0) and **tail** elements (index ≥ vl)
either untouched or filled with all-ones, per two bits in `vtype`:

| Bit   | Value    | Behavior on inactive / tail elements                         |
|-------|----------|--------------------------------------------------------------|
| `vta` | 0 (tu)   | **tail undisturbed**: keep prior destination value           |
| `vta` | 1 (ta)   | **tail agnostic**: hardware may write all-ones (or keep)     |
| `vma` | 0 (mu)   | **mask undisturbed**: keep prior dest at inactive elements   |
| `vma` | 1 (ma)   | **mask agnostic**: hardware may write all-ones (or keep)     |

The "agnostic" forms give hardware freedom to produce whichever is faster
(typically all-ones or undisturbed, implementation choice). The intrinsic
spec encodes this as **`_tu`/`_ta`/`_mu`/`_ma`/`_tumu`/`_tama`/...** suffixes.

Unsuffixed intrinsics (no policy) historically defaulted to `tama` but the
spec now warns against the unsuffixed forms — explicit policy suffixes are
the recommended style.

## 7. VLA vs VLS — the two programming models

These terms are used loosely; the precise meanings:

### VLA — Vector Length Agnostic

Code that produces a correct result for **any legal VLEN**. The
identifying pattern is a stripmining loop:

```c
size_t n_remaining = N;
const float *pa = a; const float *pb = b; float *pc = c;
while (n_remaining > 0) {
    size_t vl = __riscv_vsetvl_e32m1(n_remaining);   // hardware chooses
    vfloat32m1_t va = __riscv_vle32_v_f32m1(pa, vl);
    vfloat32m1_t vb = __riscv_vle32_v_f32m1(pb, vl);
    vfloat32m1_t vc = __riscv_vfadd_vv_f32m1(va, vb, vl);
    __riscv_vse32_v_f32m1(pc, vc, vl);
    pa += vl; pb += vl; pc += vl; n_remaining -= vl;
}
```

The same binary runs on VLEN=128 and VLEN=2048. This is the canonical
RVV idiom and is what the official intrinsic examples teach.

### VLS — Vector Length Specific

Code compiled with the assumption that VLEN is a known compile-time
constant. The compiler can then:

- Inline the lane count into address arithmetic.
- Use fixed-size vector types (the C `__attribute__((riscv_rvv_vector_bits(N)))`
  attribute, or the equivalent compiler flag).
- Skip the stripmining loop and emit a single `vsetvli` at function entry.

Compiler controls:

| Toolchain         | Flag                                                  | Notes                                       |
|-------------------|-------------------------------------------------------|---------------------------------------------|
| GCC ≥ 14          | `-mrvv-vector-bits=<N>`                               | N ∈ {128, 256, 512, 1024, 2048, 4096, 8192, 16384} or `zvl` for chosen Zvl* extension |
| Clang/LLVM ≥ 17   | `-mllvm -riscv-v-vector-bits-min=<N>`                 | older syntax; new spelling `-mrvv-vector-bits=<N>` is being added |
| Both              | `__attribute__((riscv_rvv_vector_bits(N))) vint32m1_t`| user-controlled fixed-size vector types     |

VLS is conceptually similar to compiling SVE with `-msve-vector-bits=<N>`.

**Why this matters for pystencils**: the existing SVE backend
(see [`sve-strategy-for-scalable-vectors.md`](sve-strategy-for-scalable-vectors.md))
is effectively VLS — it picks a lane count at codegen time and generates
predicates against it. The same approach for RVV is straightforward; true
VLA codegen would require a stripmining loop construct in pystencils' IR.

## 8. Memory operations — taxonomy

The mnemonic prefix tells you what kind of access it is. Worth memorizing:

| Prefix     | Access pattern                       | Example (RVV 1.0)                        |
|------------|--------------------------------------|------------------------------------------|
| `vle{eew}` | unit-stride load                     | `__riscv_vle32_v_f32m1(ptr, vl)`         |
| `vse{eew}` | unit-stride store                    | `__riscv_vse32_v_f32m1(ptr, v, vl)`      |
| `vlse{eew}`| strided load (byte stride)           | `__riscv_vlse32_v_f32m1(ptr, bstride, vl)` |
| `vsse{eew}`| strided store                        | `__riscv_vsse32_v_f32m1(ptr, bstride, v, vl)` |
| `vluxei{eew}` | indexed-unordered load (gather)   | `__riscv_vluxei32_v_f32m1(ptr, idx, vl)` |
| `vloxei{eew}` | indexed-ordered load              | element order observed for exceptions    |
| `vsuxei{eew}` | indexed-unordered store (scatter) |                                          |
| `vsoxei{eew}` | indexed-ordered store             |                                          |
| `vlseg{n}e{eew}` | segment unit-stride load        | n-tuple AoS load, n ∈ {2..8}             |
| `vlsseg{n}e` | segment strided load               |                                          |
| `vluxseg{n}ei`/`vloxseg{n}ei` | segment indexed     |                                          |
| `vl{n}re{eew}` | whole-register load              | bypasses vtype; loads `n` whole registers|
| `vs{n}r`   | whole-register store                 |                                          |

**Index units**: in RVV 1.0, indexed-load/store indices are in **bytes**.
The element being addressed is `ptr + idx[i]`. This is a frequent
porting pitfall coming from architectures that use element indices.

## 9. RVV-0.7.1 vs RVV-1.0 — what actually changed

RVV-0.7.1 (December 2019) was the last pre-ratification draft and is the
version T-Head implemented in the C906/C910 (Allwinner D1, Sipeed LicheePi
4A, T-Head TH1520-based boards). RVV-1.0 was ratified in late 2021. They
are **not binary-compatible** and **not source-compatible** at the
intrinsic level.

### Headline deltas

| Area                       | 0.7.1                                                        | 1.0                                                                |
|----------------------------|--------------------------------------------------------------|--------------------------------------------------------------------|
| Spec status                | Draft, not ratified                                          | Ratified                                                           |
| Mask layout                | One mask bit per element, **SEW-dependent stride** in mask reg | **Dense**: bit `i` is for element `i`, independent of SEW          |
| Fractional LMUL            | Not present                                                  | Added (`mf2`, `mf4`, `mf8`)                                        |
| Tail policy                | Implicitly **undisturbed** only                              | Programmable: `vta` (tail-agnostic) bit in `vtype`                 |
| Mask policy                | Implicitly **undisturbed** only                              | Programmable: `vma` (mask-agnostic) bit in `vtype`                 |
| `vill` flag                | Not present                                                  | Added — illegal `vtype` causes subsequent vector ops to trap       |
| Reduction ordering         | Single `vfredsum` (implementation-defined order)             | Split into `vfredusum` (unordered) and `vfredosum` (ordered)       |
| Indexed memory units       | **Element**-indexed                                          | **Byte**-indexed                                                   |
| Indexed memory ordering    | One form only                                                | Split: `vluxei`/`vloxei`, `vsuxei`/`vsoxei`                        |
| Whole-register move/load/store | Not present as standalone ops                            | Added (`vmv{1,2,4,8}r`, `vl{1,2,4,8}re{eew}`, `vs{1,2,4,8}r`)      |
| `vsetvli` `vtype` encoding | Different bit layout                                         | New layout (incompatible) including `vta`/`vma`/`vill` bits        |
| Segment ops                | Present, different mnemonics                                 | Reworked with explicit EEW                                         |
| Permitted SEW            | 8, 16, 32, 64 (same)                                         | 8, 16, 32, 64                                                      |
| `vfslide1up`/`vfslide1down`| Present but renamed in some draft versions                   | Final names                                                        |
| Removed instructions       | —                                                            | Several 0.7 ops dropped or renamed (e.g. `vfdot`)                  |
| Maximum VLEN               | Effectively limited by 0.7 encoding                          | Up to 65536 bits                                                   |
| Zfh/Zvfh interaction       | Not specified                                                | Half-precision FP via `Zvfh`/`Zvfhmin` sub-extensions              |

### Why each change matters (briefly)

1. **Dense mask layout (1.0)** — In 0.7 the mask bit position depended on
   SEW, which made writing efficient cross-width code awkward. 1.0's dense
   layout means bit `i` of `v0` corresponds to lane `i` regardless of the
   current SEW.

2. **`vta`/`vma`/`vill` (1.0)** — The biggest practical change.
   - `vta`/`vma` let hardware skip writing inactive/tail lanes, which
     measurably improves throughput on long pipelines.
   - `vill` is a safety net: if you wrote `vsetvl` with an unsupported
     (SEW, LMUL) combo on a 0.7 core you got silent UB. 1.0 traps.

3. **Fractional LMUL (1.0)** — Enables register-efficient widening
   sequences (e.g. `i8 → i32`). On 0.7 you had to widen at LMUL=1 then
   manually re-pack.

4. **Reduction split (1.0)** — Reproducibility-conscious code (HPC, ML
   training) needs `vfredosum`. Performance-only code uses `vfredusum`.
   0.7's single `vfredsum` left ordering vendor-defined → cross-vendor
   non-determinism.

5. **Indexed memory: byte vs element offsets** — Source-level intrinsic
   code that compiles on both versions will compute wrong addresses if you
   don't account for this. This is the single most error-prone porting
   issue.

6. **Whole-register ops (1.0)** — Useful for context save/restore and for
   moving values across LMUL groups without re-running `vsetvl`. 0.7 lacked
   these.

7. **`vtype` encoding change** — Means any assembly that hard-codes the
   `vtype` immediate breaks. Intrinsic-only code is unaffected by the
   encoding change itself but is affected by the addition of `vta`/`vma`
   bits since those need to be set sensibly.

8. **Segment ops reworked** — In 0.7 the segment-LMUL relationship was
   implicit; in 1.0 EEW is explicit in the mnemonic. Source-level porting
   requires re-deriving the right intrinsic.

### Intrinsic naming — the source-level break

This is what you actually see when porting C code.

| Concept               | RVV-0.7 (T-Head intrinsics)              | RVV-0.7 via LLVM `xtheadvector`         | RVV-1.0 (standard)                                    |
|-----------------------|------------------------------------------|-----------------------------------------|-------------------------------------------------------|
| Set VL, max           | `vsetvlmax_e32m1()`                      | `__riscv_th_vsetvlmax_e32m1()`          | `__riscv_vsetvlmax_e32m1()`                           |
| Set VL                | `vsetvl_e32m1(n)`                        | `__riscv_th_vsetvl_e32m1(n)`            | `__riscv_vsetvl_e32m1(n)`                             |
| Load unit-stride f32  | `vle32_v_f32m1(p, vl)`                   | `__riscv_th_vle_v_f32m1(p, vl)`         | `__riscv_vle32_v_f32m1(p, vl)`                        |
| Strided load          | `vlse32_v_f32m1(p, bstride, vl)`         | `__riscv_th_vlseg_*` (different)        | `__riscv_vlse32_v_f32m1(p, bstride, vl)`              |
| Indexed load          | `vlxei32_v_f32m1(p, idx, vl)` (elem idx) | `__riscv_th_vlxe_v_f32m1` (elem idx)    | `__riscv_vluxei32_v_f32m1(p, idx_bytes, vl)` (byte idx)|
| Add                   | `vfadd_vv_f32m1(a, b, vl)`               | `__riscv_th_vfadd_vv_f32m1(a, b, vl)`   | `__riscv_vfadd_vv_f32m1(a, b, vl)`                    |
| FMA (c += a*b)        | `vfmacc_vv_f32m1(c, a, b, vl)`           | `__riscv_th_vfmacc_vv_f32m1(c, a, b, vl)`| `__riscv_vfmacc_vv_f32m1(c, a, b, vl)`                |
| Ordered sum reduction | `vfredsum_vs_f32m1_f32m1(x, init, vl)`   | `__riscv_th_vfredsum_*`                 | `__riscv_vfredosum_vs_f32m1_f32m1(x, init, vl)`       |
| Policy suffix         | n/a (always undisturbed)                 | n/a                                     | `_tu`/`_ta`/`_mu`/`_ma`/`_tumu`/...                    |

The intrinsic header included is `<riscv_vector.h>` in all three cases — the
header content differs by compiler.

## 10. Toolchain support matrix

| Compiler                              | RVV-0.7.1 path                                  | RVV-1.0 path                                  |
|---------------------------------------|-------------------------------------------------|-----------------------------------------------|
| T-Head GCC fork (Xuantie)             | `-march=rv64gcv0p7` + bare intrinsics           | Not supported                                 |
| Mainline GCC ≥ 13                     | Not supported                                   | `-march=rv64gcv` (1.0)                        |
| Mainline GCC ≥ 14                     | Not supported                                   | `-march=rv64gcv` + `-mrvv-vector-bits=<N>` for VLS |
| Mainline Clang ≥ 17                   | `-march=rv64gc_xtheadvector` (different intrinsics) | `-march=rv64gcv`                          |
| Mainline Clang ≥ 19                   | `-march=rv64gc_xtheadvector` (mature)           | `-march=rv64gcv` + `-mrvv-vector-bits=<N>`    |
| QEMU user                             | `-cpu thead-c906` (0.7)                         | `-cpu rv64,v=true,vlen=<N>` (1.0)             |

LLVM's `xtheadvector` is the practical way to target C906/C910 from a
modern toolchain. It exposes a **different intrinsic family**
(`__riscv_th_*`) — source code written against bare T-Head intrinsics won't
build on LLVM and vice versa. This is the source of the "pick a 0.7
toolchain" decision called out in
[`rvv-implementation-plan.md`](rvv-implementation-plan.md).

## 11. Implications for the pystencils RVV backend

Summary of how the terminology above maps onto the implementation plan:

- **Codegen model**: VLS (fixed-lane), not VLA. User specifies (SEW, LMUL)
  at codegen time; backend emits one `__riscv_vsetvl_e{sew}m{lmul}(N)` at
  kernel entry and a derived `vl` symbol that threads through every op.
  Mirrors the SVE backend's predicate-at-entry pattern.
- **LMUL choice**: default to `m1`. Allow user override. Fractional LMUL is
  only useful for mixed-width kernels and is RVV-1.0-only — don't expose it
  in a 0.7 path.
- **Policy suffixes (RVV 1.0)**: default to `_tu` (tail-undisturbed) to
  match SVE semantics; allow per-op override later. `_ta` is more
  performant but changes observable output at the tail.
- **Mask register**: not used in v1 of the backend. `vl` alone is the
  active-lane mechanism. Masked ops are a follow-up for boundary handling.
- **Indexed memory**: remember the byte vs element offset distinction. The
  pystencils stride is in elements; multiply by `sizeof(elem)` at codegen
  time before passing to `__riscv_vluxei*` (1.0) or to T-Head's `vlxei*`
  (0.7) — wait, T-Head's was *element*-indexed natively, so the multiply
  applies only to 1.0. Easy to get wrong; assert in tests.
- **0.7 backend strategy**: subclass `RvvCpu` and override the intrinsic
  name builder. Pick LLVM `xtheadvector` (`__riscv_th_*` names) as the
  target toolchain; T-Head GCC support can be a later layer.
- **VLEN at codegen**: since this is VLS, codegen needs a VLEN value to
  compute the lane count. CMake side passes it as a build option (analogue
  of `-msve-vector-bits` plumbing already in walberla).

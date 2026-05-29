# [RVV](#rvv) ISA primer — terminology, versions, and the 0.7 → 1.0 deltas

Reference glossary for the rest of the notes. Uses the wording from the
RISC-V "V" Vector Extension specification and the official
[intrinsic](#intrinsic) specification. Where 0.7.1 and 1.0 disagree, both
are listed. The full glossary is at the bottom; all term mentions in the
body link to it.

References:
- [RVV](#rvv) 1.0 ratified spec: <https://github.com/riscv/riscv-v-spec/releases/tag/v1.0>
- [RVV](#rvv) C [intrinsic](#intrinsic) spec: <https://github.com/riscv-non-isa/rvv-intrinsic-doc>
- [RVV](#rvv) 0.7.1 (legacy / T-Head): <https://github.com/riscv/riscv-v-spec/releases/tag/0.7.1>
- T-Head C906 ISA manual ("xthead" extensions): vendor doc only, no stable URL
- LLVM [`xtheadvector`](#xtheadvector) extension (the standardized way to reach 0.7-era cores):
  <https://llvm.org/docs/RISCVUsage.html>

## 1. What [RVV](#rvv) is

[RVV](#rvv) is the standard vector extension to RISC-V, identified by the
**`V`** [ISA](#isa)-string token. It adds a vector register file, a small
set of control [CSRs](#csr), and a few hundred instructions for arithmetic,
memory, [mask](#mask), and reduction operations over those registers. The
defining design choice is that **vector length is not encoded in the
instruction** — it is read from a [CSR](#csr) at runtime. This is
fundamentally different from x86 [SSE](#sse)/[AVX](#avx) (fixed width) and
similar to ARM [SVE](#sve) (scalable width).

## 2. Architectural state

### Vector register file

- **32 architectural vector registers**: `v0`, `v1`, …, `v31`.
- Each register is **[VLEN](#vlen)** bits wide. `v0` is also the *mandatory*
  [mask](#mask) register: when an instruction is masked, the [mask](#mask)
  source is implicitly `v0`.
- Registers can be **grouped** into larger logical registers via
  [LMUL](#lmul) (see below). Grouped registers must be aligned
  (`v0,v1`, `v4,v5,v6,v7`, …).

### Register-file dimensions, for an HDL reader

If "[VLEN](#vlen) bits wide" is unclear, the [RVV](#rvv) register file maps
directly onto a Verilog register-file declaration. Start from the scalar
integer file you already know — 32 registers, each `XLEN` (= 64 on rv64)
bits:

```verilog
reg [63:0] x [0:31];      // depth = 32 entries, width = 64 bits per entry
```

Two dimensions: **depth** = 32 (addressed by the 5-bit register number in
the instruction) and **width** = 64 bits (the physical flip-flop width of
one row). "64 bits wide" *is* that `[63:0]`. The vector file is the same
array, only much wider:

```verilog
reg [VLEN-1:0] v [0:31];  // depth still 32, width = VLEN bits per entry
```

- **Depth is fixed at 32** (`v0`–`v31`, still a 5-bit index) — the spec
  never changes this per SoC.
- **Width = [VLEN](#vlen) bits** is the *only* dimension the silicon
  designer picks. "[VLEN](#vlen) = 256" literally means each entry is
  `reg [255:0]` — a 256-bit bank of flip-flops, exactly analogous to the
  `[63:0]` on a scalar register. Total architectural vector state is just
  `32 × VLEN` bits (1 KB at [VLEN](#vlen)=256).

```
                 width = VLEN bits   (the "XX bits wide" number)
              ◄────────────────────────────►
        v0   │ b(VLEN-1) ........... b1  b0 │
        v1   │                             │
        ...  │                             │   depth = 32 entries (fixed by spec)
        v31  │                             │
              ◄────────────────────────────►
```

That declaration is the *entire* register file. [SEW](#sew), [LMUL](#lmul)
and [`vl`](#vl) add **zero** flip-flops — they only change how the datapath
slices and addresses these same bits:

- **[SEW](#sew) bit-slices the width into [lanes](#lane)** — a packed-array
  reinterpretation (`+:` part-select). Same bits, different lane
  boundaries; lane count = `VLEN / SEW`:

  ```verilog
  // VLEN = 256, SEW = 32  ->  256/32 = 8 lanes
  wire [31:0] lane [0:7];
  genvar i;
  for (i = 0; i < 8; i = i + 1)
      assign lane[i] = v[r][32*i +: 32];   // re-slice the SAME 256 bits
  ```

- **[LMUL](#lmul) changes how many register-file rows back one logical
  operand.** [SEW](#sew) slices *within* a row; [LMUL](#lmul) changes *how
  many rows* (or what fraction of a row) the operand spans. The two compose:
  the lane count of an operation is always
  [VLMAX](#vlmax) = `VLEN × LMUL / SEW`. Detail for both directions below.

- **[`vl`](#vl) is a dynamic active-[lane](#lane) count** — effectively a
  per-lane write-enable / loop bound, so one instruction handles a partial
  final chunk without a cleanup path:

  ```verilog
  for (i = 0; i < VLMAX; i = i + 1)
      if (i < vl)
          v[rd][SEW*i +: SEW] <= alu_result[i];   // active lane commits
      // else: tail lane -> undisturbed or all-ones, per vta
  ```

#### [LMUL](#lmul) in detail — the HDL view

Hold [VLEN](#vlen) = 128 and [SEW](#sew) = 32 fixed for all of the diagrams
below, so one physical register holds `128/32 = 4` elements. [LMUL](#lmul)
only changes how many of those 4-element rows (or what slice of one row)
form the operand the instruction sees. The element index runs **low-to-high
across the concatenation**, and the register-number field in the
instruction names the *first* (lowest-numbered) register of the group.

**[LMUL](#lmul) = 1 — the baseline.** One row, one operand, 4 [lanes](#lane):

```
                       VLEN = 128 bits  ->  4 lanes of SEW=32
                    ◄────────────────────────────────────►
   v4   (LMUL=1)    │  e3   │  e2   │  e1   │  e0   │        VLMAX = 128*1/32 = 4
                    └───────┴───────┴───────┴───────┘
   instruction says "v4"; operand = v4 alone
```

```verilog
// LMUL = 1 : operand is exactly one row
wire [127:0] op = v[4];                       // lanes e0..e3 via [32*i +: 32]
```

**[LMUL](#lmul) > 1 — gang adjacent rows (more lanes per instruction).**
LMUL=2 concatenates two aligned rows into one 256-bit operand of 8 lanes;
LMUL=4 → four rows, 16 lanes; LMUL=8 → eight rows, 32 lanes. The group must
be **aligned** to its size (LMUL=2 groups start at even register numbers,
LMUL=4 at multiples of 4, LMUL=8 only at v0/v8/v16/v24):

```
   LMUL = 2 : operand spans v4,v5  ->  2*VLEN = 256 bits = 8 lanes
                              v5 (high half)              v4 (low half)
              ◄──────────────────────────────►◄──────────────────────────────►
              │ e7 │ e6 │ e5 │ e4 │            │ e3 │ e2 │ e1 │ e0 │
              └────┴────┴────┴────┘            └────┴────┴────┴────┘
              instruction says "v4"; operand = {v5, v4}      VLMAX = 128*2/32 = 8

   LMUL = 4 : operand spans v4,v5,v6,v7  ->  4*VLEN = 512 bits = 16 lanes
              {        v7      |      v6      |      v5      |      v4        }
              │ e15..e12 │ e11..e8 │ e7..e4 │ e3..e0 │            VLMAX = 16
```

```verilog
// LMUL = 2 : two aligned rows make one wide operand
wire [255:0] op = { v[5], v[4] };             // 8 lanes: e0..e3 in v4, e4..e7 in v5

// LMUL = 4 : four aligned rows
wire [511:0] op = { v[7], v[6], v[5], v[4] }; // 16 lanes
```

Cost: a wide group **consumes that many architectural registers**. With
only 32 rows total, LMUL=8 leaves you just 4 independent operands
(`v0`, `v8`, `v16`, `v24`). That register pressure is the whole tradeoff —
big LMUL means fewer instructions for a given array but fewer live vectors.

**[LMUL](#lmul) < 1 (fractional, [RVV](#rvv) 1.0 only) — use only part of
one row (fewer lanes).** The operand occupies a *fraction* of a single
register; the upper bits of that register are unused by the op. LMUL=1/2
uses half a row (2 lanes at SEW=32), 1/4 a quarter (1 lane), 1/8 an eighth:

```
   LMUL = 1/2 : operand = low half of v4  ->  VLEN/2 = 64 bits = 2 lanes
                    ┌ ─ ─ ─ ─ ─ ─ ─ ┬───────┬───────┐
   v4               │   unused      │  e1   │  e0   │   VLMAX = 128*(1/2)/32 = 2
                    └ ─ ─ ─ ─ ─ ─ ─ ┴───────┴───────┘
                     ◄── top 64 b ──►◄──── used 64 b ───►

   LMUL = 1/4 : operand = low quarter of v4  ->  32 bits = 1 lane
                    ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┬───────┐
   v4               │           unused            │  e0   │   VLMAX = 1
                    └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┴───────┘
```

```verilog
// LMUL = 1/2 : only the low VLEN/2 bits of one row participate
wire [63:0] op = v[4][63:0];                  // 2 lanes; v4[127:64] untouched

// LMUL = 1/4 : low VLEN/4 bits
wire [31:0] op = v[4][31:0];                  // 1 lane
```

Why fractional [LMUL](#lmul) exists: **mixed-width** kernels. When you widen
`int8 → int32` (SEW goes ×4), the result needs 4× the bits per element. If
you hold the *element count* constant, the narrow source should occupy
[LMUL](#lmul)=1/4 while the wide destination is [LMUL](#lmul)=1 — both then
have the same lane count and you don't waste registers padding the narrow
side up to a full row. This is the [EMUL](#emul) relationship (eq 4 in §4):
`EMUL = (EEW/SEW) × LMUL`.

**One table, [VLEN](#vlen)=128, [SEW](#sew)=32 throughout:**

| [LMUL](#lmul) | rows used / fraction | operand width | [VLMAX](#vlmax) (lanes) | aligned start | usable groups |
|---------------|----------------------|---------------|-------------------------|---------------|---------------|
| 1/8           | 1/8 of one row       | 16 b          | —¹                      | any           | 32            |
| 1/4           | 1/4 of one row       | 32 b          | 1                       | any           | 32            |
| 1/2           | 1/2 of one row       | 64 b          | 2                       | any           | 32            |
| 1             | 1 row                | 128 b         | 4                       | any           | 32            |
| 2             | 2 rows               | 256 b         | 8                       | even          | 16            |
| 4             | 4 rows               | 512 b         | 16                      | mult. of 4    | 8             |
| 8             | 8 rows               | 1024 b        | 32                      | v0/v8/v16/v24 | 4             |

¹ At SEW=32, LMUL=1/8 gives `128/8 = 16 b < SEW`, i.e. VLMAX = 0 — illegal
(it sets [`vill`](#vill)). Fractional [LMUL](#lmul) only makes sense when
`VLEN × LMUL ≥ SEW`; at SEW=8 on this core, LMUL=1/8 would be legal with
VLMAX=2.

Summary of which dimension is what, and who fixes it:

| Concept                | HDL analogue                                          | Who fixes it                |
|------------------------|-------------------------------------------------------|-----------------------------|
| **32 registers**       | array depth `v[0:31]`, 5-bit index                    | spec (always 32)            |
| **[VLEN](#vlen)** ("XX bits wide") | entry width `reg [VLEN-1:0]`              | **silicon** (per SoC)       |
| **[SEW](#sew)**        | part-select stride `[SEW*i +: SEW]` → `VLEN/SEW` lanes | software (`vtype`), per op  |
| **[LMUL](#lmul)**      | concatenation depth `{v[r+1],v[r]}` → `VLEN×LMUL` wide | software (`vtype`), per op  |
| **[VLMAX](#vlmax)**    | derived lane count `VLEN×LMUL/SEW`                    | derived                     |
| **[`vl`](#vl)**        | per-lane write-enable / loop bound                    | dynamic ([`vsetvl`](#vsetvl)) |

The one thing physically baked into the silicon about the register file is
**[VLEN](#vlen)** — the bit-width of each of the 32 rows. [SEW](#sew) and
[LMUL](#lmul) re-slice and gang those rows; [`vl`](#vl) gates how many
[lanes](#lane) fire.

### Control [CSRs](#csr)

| [CSR](#csr) | Purpose                                                                            |
|-------------|------------------------------------------------------------------------------------|
| [`vtype`](#vtype) | Encodes [SEW](#sew), [LMUL](#lmul), [`vma`](#vma), [`vta`](#vta), [`vill`](#vill). Set by [`vsetvl{i}`](#vsetvl). |
| [`vl`](#vl) | Active *vector length* — number of elements the next vector op processes.          |
| [`vstart`](#vstart) | First element index to process. Non-zero only after a resumed trap.        |
| [`vxrm`](#vxrm) | Fixed-point rounding mode.                                                     |
| [`vxsat`](#vxsat) | Fixed-point saturation flag.                                                 |
| [`vcsr`](#vcsr) | Combined view of [`vxrm`](#vxrm)/[`vxsat`](#vxsat).                            |
| [`vlenb`](#vlenb) | Read-only: [VLEN](#vlen) in bytes (= [VLEN](#vlen)/8).                       |

## 3. The four numbers that govern everything

Every [RVV](#rvv) programmer carries these in their head.

### [VLEN](#vlen) — vector register width

Implementation-defined width of one vector register, in **bits**. Must be a
power of two. In [RVV](#rvv) 1.0 the spec permits [VLEN](#vlen) up to 65536.
Real silicon today ships at 128 (SiFive U74-MC + [RVV](#rvv) optional), 256
(SpacemiT K1, T-Head C908), 512 (T-Head TH1520 future, Andes AX45MPV), and
1024+ (research/HPC). The C906/C910 ([RVV](#rvv)-0.7.1) ship at
[VLEN](#vlen)=128.

### [ELEN](#elen) — maximum element width

Implementation-defined upper bound on **[SEW](#sew)**, in bits. Most cores
set [ELEN](#elen)=64. If [ELEN](#elen)<64, double-width FP ops are
unavailable.

### [SEW](#sew) — Selected Element Width

The width of one element *as currently configured*, in bits. Legal values:
**8, 16, 32, 64** (up to [ELEN](#elen)). [SEW](#sew) is part of
[`vtype`](#vtype) and is set by [`vsetvl{i}`](#vsetvl). The same physical
register `v8` is interpreted as 16×i8 or 4×i32 depending on the current
[SEW](#sew).

### [LMUL](#lmul) — vector register group Length Multiplier

How many architectural registers are *grouped* to form one logical operand.
Legal values in [RVV](#rvv) 1.0:

| [LMUL](#lmul) setting | Symbol  | Registers used | Notes                                          |
|-----------------------|---------|----------------|------------------------------------------------|
| 1/8                   | `mf8`   | partial of 1   | "fractional [LMUL](#lmul)", new in 1.0         |
| 1/4                   | `mf4`   | partial of 1   | new in 1.0                                     |
| 1/2                   | `mf2`   | partial of 1   | new in 1.0                                     |
| 1                     | `m1`    | 1              | the natural default                            |
| 2                     | `m2`    | 2 (aligned)    |                                                |
| 4                     | `m4`    | 4 (aligned)    |                                                |
| 8                     | `m8`    | 8 (aligned)    |                                                |

Fractional [LMUL](#lmul) exists to enable **mixed-width** operations
without wasting registers — e.g. widening a stream of i8 values into i32
results halves the number of i32 [lanes](#lane) you need.

### [VLMAX](#vlmax) — derived element count

`VLMAX = (VLEN * LMUL) / SEW`. This is the maximum number of elements you
can request for a given ([SEW](#sew), [LMUL](#lmul)) configuration.
[`vsetvl{i}`](#vsetvl) will clamp [`vl`](#vl) to at most [VLMAX](#vlmax).

Worked example: [VLEN](#vlen)=256, [SEW](#sew)=32, [LMUL](#lmul)=m2 ⇒
[VLMAX](#vlmax) = 256·2/32 = 16 i32 [lanes](#lane).

## 4. Practical: what the silicon bakes in vs. what you compute

This is the part you need straight before writing [intrinsics](#intrinsic).
Some parameters are fixed in the hardware; everything else you derive from
them at codegen / coding time.

### 4.1 Baked into the silicon (you cannot change these)

For a given RISC-V SoC / core, these are fixed properties of the
implementation. Read them from the core's datasheet, its `riscv,isa`
device-tree string, or `/proc/cpuinfo`:

| Parameter                       | What it is                                                            | How to find it                                                        |
|---------------------------------|-----------------------------------------------------------------------|-----------------------------------------------------------------------|
| [VLEN](#vlen)                   | Physical vector register width in bits (power of two)                 | Datasheet, or at runtime: [`vlenb`](#vlenb) CSR × 8, or `__riscv_vsetvlmax_e8m1()` |
| [ELEN](#elen)                   | Max supported [SEW](#sew) (usually 64, sometimes 32)                  | Datasheet / advertised [Zve*](#zve) extension                         |
| [RVV](#rvv) version             | 0.7.1 (T-Head) vs 1.0 (ratified)                                      | Datasheet; `_xthead*` token in [ISA](#isa) string ⇒ 0.7-era           |
| [Zvl](#zvl)* guarantee          | Minimum [VLEN](#vlen) the binary may assume (`Zvl128b`, `Zvl256b`, …) | [ISA](#isa) string                                                    |
| [Zve](#zve)* subset             | Which element widths / FP types the vector unit supports              | [ISA](#isa) string (`Zve32f`, `Zve64d`, …)                            |
| FP support ([Zvfh](#zve), etc.) | Whether [FP16](#fp16)/BF16 vector ops exist                           | [ISA](#isa) string                                                    |
| Number of vector registers      | Always **32** (`v0`–`v31`) — architectural, not per-SoC              | Fixed by the spec                                                     |

Concrete examples of `(VLEN, ELEN, version)` for real parts:

| SoC / core                       | [VLEN](#vlen) | [ELEN](#elen) | [RVV](#rvv) version |
|----------------------------------|---------------|---------------|---------------------|
| Allwinner D1 / T-Head C906       | 128           | 64            | 0.7.1               |
| T-Head C908                      | 128 or 256    | 64            | 1.0                 |
| SpacemiT K1 (BPI-F3)             | 256           | 64            | 1.0                 |
| SiFive P670 / X280               | 128 / 512     | 64            | 1.0                 |
| Andes AX45MPV                    | 512           | 64            | 1.0                 |

### 4.2 What you choose (per kernel)

Two free choices drive everything downstream:

- **[SEW](#sew)** — Selected Element Width. Dictated by your data type:
  `float`→32, `double`→64, `int16_t`→16, etc. Must satisfy
  **[SEW](#sew) ≤ [ELEN](#elen)**.
- **[LMUL](#lmul)** — Length Multiplier. A tuning knob: larger
  [LMUL](#lmul) ⇒ more elements per instruction (fewer instructions, more
  throughput) but more register pressure (you have only 32 registers, and a
  group of [LMUL](#lmul)=8 eats 8 of them). Default to `m1`; raise to `m2`/`m4`
  for simple streaming kernels; use fractional ([RVV](#rvv) 1.0 only) for
  mixed-width.

### 4.3 The formulas

Everything else is derived. These hold for both 0.7 and 1.0 (fractional
[LMUL](#lmul) is 1.0-only):

```
                         VLEN × LMUL
(1)   VLMAX        =  ───────────────────         (elements per vector op)
                            SEW

(2)   vlenb        =  VLEN / 8                      (bytes per register, CSR)

(3)   regs_in_group =  max(1, ceil(LMUL))           (architectural registers used;
                                                     fractional LMUL ⇒ 1)

(4)   EMUL         =  (EEW / SEW) × LMUL            (effective LMUL for a memory op)
       constraint:    1/8 ≤ EMUL ≤ 8   AND   EMUL is a representable LMUL

(5)   elems_per_reg =  VLEN / SEW                   (= VLMAX when LMUL = 1)

(6)   byte_stride  =  elem_stride × (SEW / 8)       (for vlse*/vsse* strided ops)

(7)   byte_index[i] =  elem_index[i] × (SEW / 8)    (RVV 1.0 indexed gather/scatter;
                                                     RVV 0.7 indices are in ELEMENTS,
                                                     so this multiply is 1.0-only)
```

**The [`vl`](#vl) rule** — what [`vsetvl`](#vsetvl) actually returns for a
requested [AVL](#avl):

```
(8)   if  AVL ≤ VLMAX        →  vl = AVL
      if  AVL ≥ 2 × VLMAX    →  vl = VLMAX
      if  VLMAX < AVL < 2×VLMAX
                             →  vl = implementation-defined,
                                 but  ceil(AVL/2) ≤ vl ≤ VLMAX
                                 (and both halves come out roughly equal)
```

> **Practical rule:** never hard-code the result of (8) in the transition
> band — always use the value [`vsetvl`](#vsetvl) *returns*. In the common
> stripmining loop you simply pass the remaining count as [AVL](#avl) each
> iteration and trust the returned [`vl`](#vl). (RVV 0.7 and 1.0 differ in
> the exact transition-band behaviour, which is another reason to read the
> return value rather than compute it.)

### 4.4 Worked example

Target: SpacemiT K1, processing a `float` (f32) array of `N = 1000`.

```
Silicon:   VLEN = 256,  ELEN = 64,  RVV 1.0
Choose:    SEW  = 32  (float),  LMUL = m1
Derive:    VLMAX        = 256 × 1 / 32      = 8 elements per op      [eq 1]
           vlenb        = 256 / 8           = 32 bytes              [eq 2]
           elems_per_reg= 256 / 32          = 8                     [eq 5]
Loop:      iteration 1..125 → AVL=1000,992,…,8 each returns vl=8    [eq 8]
           last full chunk leaves 1000 mod 8 = 0 → no tail here;
           had N=1003, final AVL=3 → vl=3, only 3 lanes active
Strided:   to read every 3rd float, byte_stride = 3 × (32/8) = 12   [eq 6]
```

Bump to `LMUL = m4` on the same hardware: `VLMAX = 256 × 4 / 32 = 32`
elements per op (4 registers per group, 8 groups available) — a quarter as
many loop iterations, at 4× the register footprint.

### 4.5 The pre-flight checklist (before you write any [intrinsic](#intrinsic))

1. **Know the silicon**: [VLEN](#vlen), [ELEN](#elen), [RVV](#rvv) version,
   [Zve](#zve)/[Zvl](#zvl) extensions (§4.1).
2. **Pick [SEW](#sew)** from your data type; assert [SEW](#sew) ≤
   [ELEN](#elen).
3. **Pick [LMUL](#lmul)** (start at `m1`; only go fractional on 1.0).
4. **Compute [VLMAX](#vlmax)** with eq (1) — this is your max chunk size.
5. **Decide [VLA](#vla) or [VLS](#vls)** (§7): [VLA](#vla) ⇒ stripmining
   loop reading the returned [`vl`](#vl); [VLS](#vls) ⇒ pin [VLEN](#vlen)
   at compile time and treat [VLMAX](#vlmax) as constant.
6. **For mixed-width / indexed ops**: compute [EEW](#eew) and check
   [EMUL](#emul) with eq (4) stays in `[1/8, 8]`.
7. **For strided / indexed memory**: convert element strides/indices to
   **bytes** with eq (6)/(7) — remembering eq (7) applies to [RVV](#rvv)
   1.0 only (0.7 is element-indexed).
8. **Set the tail/[mask](#mask) policy** ([`vta`](#vta)/[`vma`](#vma),
   1.0 only — §6); 0.7 is always tail-undisturbed.

## 5. [EEW](#eew) and [EMUL](#emul) — for memory ops

Memory instructions (loads, stores, indexed ops) can specify their own
**Effective Element Width** and **Effective [LMUL](#lmul)** independent of
the current [`vtype`](#vtype) [SEW](#sew)/[LMUL](#lmul). This matters for:

- Mixed-width arithmetic: load f32 into an f64-configured stream.
- Indexed memory ops: the index vector's [EEW](#eew) can differ from the
  data [SEW](#sew).

The [intrinsic](#intrinsic) spec encodes [EEW](#eew) in the mnemonic:
`vle32_v_*` always loads 32-bit elements regardless of current [SEW](#sew);
`vluxei16_v_*` uses a 16-bit index vector with whatever the data
[SEW](#sew) is.

## 6. [`vsetvl{i}`](#vsetvl) — the only way to change [`vl`](#vl) and [`vtype`](#vtype)

Three forms:

| Instruction                | Arguments                              | Effect                                      |
|----------------------------|----------------------------------------|---------------------------------------------|
| `vsetvli rd, rs1, vtypei`  | requested [AVL](#avl) in `rs1`, immediate [`vtype`](#vtype) | sets [`vtype`](#vtype), returns granted [`vl`](#vl) in `rd` |
| `vsetvl rd, rs1, rs2`      | requested [AVL](#avl), [`vtype`](#vtype) in `rs2`           | dynamic [`vtype`](#vtype) variant                    |
| `vsetivli rd, uimm, vtypei`| 5-bit immediate [AVL](#avl)                                 | for small fixed counts                       |

The "[AVL](#avl)" (Application Vector Length) is what the program *wants*
to process; the hardware returns the actual [`vl`](#vl) granted, which is
the **`min(AVL, VLMAX)`** clamped to the largest power-of-two ≤
[AVL](#avl) when [AVL](#avl) is in the ([VLMAX](#vlmax), 2·[VLMAX](#vlmax)]
range (the "[stripmining](#stripmining)" tail behaviour).

If the requested [`vtype`](#vtype) is unsupported, hardware sets
[`vill`](#vill)=1; subsequent vector ops then trap.

## 7. Tail and [mask](#mask) policies — [`vta`](#vta), [`vma`](#vma)

Each vector op writes to **active** elements ([mask](#mask)=1 AND index <
[`vl`](#vl)) and may leave **inactive** elements ([mask](#mask)=0) and
**tail** elements (index ≥ [`vl`](#vl)) either untouched or filled with
all-ones, per two bits in [`vtype`](#vtype):

| Bit            | Value  | Behavior on inactive / tail elements                          |
|----------------|--------|---------------------------------------------------------------|
| [`vta`](#vta)  | 0 (tu) | **tail undisturbed**: keep prior destination value            |
| [`vta`](#vta)  | 1 (ta) | **tail agnostic**: hardware may write all-ones (or keep)      |
| [`vma`](#vma)  | 0 (mu) | **[mask](#mask) undisturbed**: keep prior dest at inactive    |
| [`vma`](#vma)  | 1 (ma) | **[mask](#mask) agnostic**: hardware may write all-ones (or keep) |

The "agnostic" forms give hardware freedom to produce whichever is faster
(typically all-ones or undisturbed, implementation choice). The
[intrinsic](#intrinsic) spec encodes this as
**`_tu`/`_ta`/`_mu`/`_ma`/`_tumu`/`_tama`/...** suffixes.

Unsuffixed [intrinsics](#intrinsic) (no policy) historically defaulted to
`tama` but the spec now warns against the unsuffixed forms — explicit
policy suffixes are the recommended style.

## 8. [VLA](#vla) vs [VLS](#vls) — the two programming models

These terms are used loosely; the precise meanings:

### [VLA](#vla) — Vector Length Agnostic

Code that produces a correct result for **any legal [VLEN](#vlen)**. The
identifying pattern is a [stripmining](#stripmining) loop:

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

The same binary runs on [VLEN](#vlen)=128 and [VLEN](#vlen)=2048. This is
the canonical [RVV](#rvv) idiom and is what the official
[intrinsic](#intrinsic) examples teach.

### [VLS](#vls) — Vector Length Specific

Code compiled with the assumption that [VLEN](#vlen) is a known
compile-time constant. The compiler can then:

- Inline the [lane](#lane) count into address arithmetic.
- Use fixed-size vector types (the C
  `__attribute__((riscv_rvv_vector_bits(N)))` attribute, or the equivalent
  compiler flag).
- Skip the [stripmining](#stripmining) loop and emit a single `vsetvli` at
  function entry.

Compiler controls:

| Toolchain         | Flag                                                  | Notes                                       |
|-------------------|-------------------------------------------------------|---------------------------------------------|
| GCC ≥ 14          | `-mrvv-vector-bits=<N>`                               | N ∈ {128, 256, 512, 1024, 2048, 4096, 8192, 16384} or `zvl` for chosen Zvl* extension |
| Clang/LLVM ≥ 17   | `-mllvm -riscv-v-vector-bits-min=<N>`                 | older syntax; new spelling `-mrvv-vector-bits=<N>` is being added |
| Both              | `__attribute__((riscv_rvv_vector_bits(N))) vint32m1_t`| user-controlled fixed-size vector types     |

[VLS](#vls) is conceptually similar to compiling [SVE](#sve) with
`-msve-vector-bits=<N>`.

**Why this matters for pystencils**: the existing [SVE](#sve) backend
(see [`sve-strategy-for-scalable-vectors.md`](sve-strategy-for-scalable-vectors.md))
is effectively [VLS](#vls) — it picks a [lane](#lane) count at codegen
time and generates [predicates](#predicate) against it. The same approach
for [RVV](#rvv) is straightforward; true [VLA](#vla) codegen would require
a [stripmining](#stripmining) loop construct in pystencils' [IR](#ir).

## 9. Memory operations — taxonomy

The mnemonic prefix tells you what kind of access it is. Worth memorizing:

| Prefix              | Access pattern                       | Example ([RVV](#rvv) 1.0)                  |
|---------------------|--------------------------------------|--------------------------------------------|
| `vle{eew}`          | unit-stride load                     | `__riscv_vle32_v_f32m1(ptr, vl)`           |
| `vse{eew}`          | unit-stride store                    | `__riscv_vse32_v_f32m1(ptr, v, vl)`        |
| `vlse{eew}`         | [strided](#stride) load (byte stride)| `__riscv_vlse32_v_f32m1(ptr, bstride, vl)` |
| `vsse{eew}`         | [strided](#stride) store             | `__riscv_vsse32_v_f32m1(ptr, bstride, v, vl)` |
| `vluxei{eew}`       | indexed-unordered load ([gather](#gather)) | `__riscv_vluxei32_v_f32m1(ptr, idx, vl)` |
| `vloxei{eew}`       | indexed-ordered load                 | element order observed for exceptions      |
| `vsuxei{eew}`       | indexed-unordered store ([scatter](#scatter)) |                                 |
| `vsoxei{eew}`       | indexed-ordered store                |                                            |
| `vlseg{n}e{eew}`    | [segment](#segment) unit-stride load | n-tuple AoS load, n ∈ {2..8}               |
| `vlsseg{n}e`        | [segment](#segment) strided load     |                                            |
| `vluxseg{n}ei`/`vloxseg{n}ei` | [segment](#segment) indexed |                                            |
| `vl{n}re{eew}`      | whole-register load                  | bypasses [`vtype`](#vtype); loads `n` whole registers |
| `vs{n}r`            | whole-register store                 |                                            |

**Index units**: in [RVV](#rvv) 1.0, indexed-load/store indices are in
**bytes**. The element being addressed is `ptr + idx[i]`. This is a
frequent porting pitfall coming from architectures that use element
indices.

## 10. [RVV](#rvv)-0.7.1 vs [RVV](#rvv)-1.0 — what actually changed

[RVV](#rvv)-0.7.1 (December 2019) was the last pre-ratification draft and
is the version T-Head implemented in the C906/C910 (Allwinner D1, Sipeed
LicheePi 4A, T-Head TH1520-based boards). [RVV](#rvv)-1.0 was ratified in
late 2021. They are **not binary-compatible** and **not source-compatible**
at the [intrinsic](#intrinsic) level.

### Headline deltas

| Area                       | [RVV](#rvv)-0.7.1                                                | [RVV](#rvv)-1.0                                                              |
|----------------------------|------------------------------------------------------------------|------------------------------------------------------------------------------|
| Spec status                | Draft, not ratified                                              | Ratified                                                                     |
| [Mask](#mask) layout       | One [mask](#mask) bit per element, **[SEW](#sew)-dependent stride** in mask reg | **Dense**: bit `i` is for element `i`, independent of [SEW](#sew)            |
| Fractional [LMUL](#lmul)   | Not present                                                      | Added (`mf2`, `mf4`, `mf8`)                                                  |
| Tail policy                | Implicitly **undisturbed** only                                  | Programmable: [`vta`](#vta) (tail-agnostic) bit in [`vtype`](#vtype)         |
| [Mask](#mask) policy       | Implicitly **undisturbed** only                                  | Programmable: [`vma`](#vma) ([mask](#mask)-agnostic) bit in [`vtype`](#vtype) |
| [`vill`](#vill) flag       | Not present                                                      | Added — illegal [`vtype`](#vtype) causes subsequent vector ops to trap        |
| Reduction ordering         | Single `vfredsum` (implementation-defined order)                 | Split into `vfredusum` (unordered) and `vfredosum` (ordered)                  |
| Indexed memory units       | **Element**-indexed                                              | **Byte**-indexed                                                              |
| Indexed memory ordering    | One form only                                                    | Split: `vluxei`/`vloxei`, `vsuxei`/`vsoxei`                                  |
| Whole-register move/load/store | Not present as standalone ops                                | Added (`vmv{1,2,4,8}r`, `vl{1,2,4,8}re{eew}`, `vs{1,2,4,8}r`)                |
| [`vsetvli`](#vsetvl) [`vtype`](#vtype) encoding | Different bit layout                        | New layout (incompatible) including [`vta`](#vta)/[`vma`](#vma)/[`vill`](#vill) bits |
| [Segment](#segment) ops    | Present, different mnemonics                                     | Reworked with explicit [EEW](#eew)                                            |
| Permitted [SEW](#sew)      | 8, 16, 32, 64 (same)                                             | 8, 16, 32, 64                                                                 |
| `vfslide1up`/`vfslide1down`| Present but renamed in some draft versions                       | Final names                                                                   |
| Removed instructions       | —                                                                | Several 0.7 ops dropped or renamed (e.g. `vfdot`)                             |
| Maximum [VLEN](#vlen)      | Effectively limited by 0.7 encoding                              | Up to 65536 bits                                                              |
| Zfh/Zvfh interaction       | Not specified                                                    | Half-precision FP via `Zvfh`/`Zvfhmin` sub-extensions                         |

### Why each change matters (briefly)

1. **Dense [mask](#mask) layout (1.0)** — In 0.7 the [mask](#mask) bit
   position depended on [SEW](#sew), which made writing efficient
   cross-width code awkward. 1.0's dense layout means bit `i` of `v0`
   corresponds to [lane](#lane) `i` regardless of the current [SEW](#sew).

2. **[`vta`](#vta)/[`vma`](#vma)/[`vill`](#vill) (1.0)** — The biggest
   practical change.
   - [`vta`](#vta)/[`vma`](#vma) let hardware skip writing inactive/tail
     [lanes](#lane), which measurably improves throughput on long
     pipelines.
   - [`vill`](#vill) is a safety net: if you wrote [`vsetvl`](#vsetvl)
     with an unsupported ([SEW](#sew), [LMUL](#lmul)) combo on a 0.7 core
     you got silent UB. 1.0 traps.

3. **Fractional [LMUL](#lmul) (1.0)** — Enables register-efficient
   widening sequences (e.g. `i8 → i32`). On 0.7 you had to widen at
   [LMUL](#lmul)=1 then manually re-pack.

4. **Reduction split (1.0)** — Reproducibility-conscious code (HPC, ML
   training) needs `vfredosum`. Performance-only code uses `vfredusum`.
   0.7's single `vfredsum` left ordering vendor-defined → cross-vendor
   non-determinism.

5. **Indexed memory: byte vs element offsets** — Source-level
   [intrinsic](#intrinsic) code that compiles on both versions will compute
   wrong addresses if you don't account for this. This is the single most
   error-prone porting issue.

6. **Whole-register ops (1.0)** — Useful for context save/restore and for
   moving values across [LMUL](#lmul) groups without re-running
   [`vsetvl`](#vsetvl). 0.7 lacked these.

7. **[`vtype`](#vtype) encoding change** — Means any assembly that
   hard-codes the [`vtype`](#vtype) immediate breaks.
   [Intrinsic](#intrinsic)-only code is unaffected by the encoding change
   itself but is affected by the addition of [`vta`](#vta)/[`vma`](#vma)
   bits since those need to be set sensibly.

8. **[Segment](#segment) ops reworked** — In 0.7 the
   [segment](#segment)-[LMUL](#lmul) relationship was implicit; in 1.0
   [EEW](#eew) is explicit in the mnemonic. Source-level porting requires
   re-deriving the right [intrinsic](#intrinsic).

### [Intrinsic](#intrinsic) naming — the source-level break

This is what you actually see when porting C code.

| Concept                | [RVV](#rvv)-0.7 (T-Head intrinsics)         | [RVV](#rvv)-0.7 via LLVM [`xtheadvector`](#xtheadvector) | [RVV](#rvv)-1.0 (standard)                                        |
|------------------------|---------------------------------------------|----------------------------------------------------------|-------------------------------------------------------------------|
| Set [`vl`](#vl), max   | `vsetvlmax_e32m1()`                         | `__riscv_th_vsetvlmax_e32m1()`                           | `__riscv_vsetvlmax_e32m1()`                                       |
| Set [`vl`](#vl)        | `vsetvl_e32m1(n)`                           | `__riscv_th_vsetvl_e32m1(n)`                             | `__riscv_vsetvl_e32m1(n)`                                         |
| Load unit-stride f32   | `vle32_v_f32m1(p, vl)`                      | `__riscv_th_vle_v_f32m1(p, vl)`                          | `__riscv_vle32_v_f32m1(p, vl)`                                    |
| [Strided](#stride) load | `vlse32_v_f32m1(p, bstride, vl)`           | `__riscv_th_vlseg_*` (different)                         | `__riscv_vlse32_v_f32m1(p, bstride, vl)`                          |
| Indexed load           | `vlxei32_v_f32m1(p, idx, vl)` (elem idx)    | `__riscv_th_vlxe_v_f32m1` (elem idx)                     | `__riscv_vluxei32_v_f32m1(p, idx_bytes, vl)` (byte idx)            |
| Add                    | `vfadd_vv_f32m1(a, b, vl)`                  | `__riscv_th_vfadd_vv_f32m1(a, b, vl)`                    | `__riscv_vfadd_vv_f32m1(a, b, vl)`                                |
| [FMA](#fma) (c += a*b) | `vfmacc_vv_f32m1(c, a, b, vl)`              | `__riscv_th_vfmacc_vv_f32m1(c, a, b, vl)`                | `__riscv_vfmacc_vv_f32m1(c, a, b, vl)`                            |
| Ordered sum reduction  | `vfredsum_vs_f32m1_f32m1(x, init, vl)`      | `__riscv_th_vfredsum_*`                                  | `__riscv_vfredosum_vs_f32m1_f32m1(x, init, vl)`                   |
| Policy suffix          | n/a (always undisturbed)                    | n/a                                                      | `_tu`/`_ta`/`_mu`/`_ma`/`_tumu`/...                                |

The [intrinsic](#intrinsic) header included is `<riscv_vector.h>` in all
three cases — the header content differs by compiler.

## 11. Toolchain support matrix

| Compiler                              | [RVV](#rvv)-0.7.1 path                                  | [RVV](#rvv)-1.0 path                                  |
|---------------------------------------|---------------------------------------------------------|-------------------------------------------------------|
| T-Head GCC fork (Xuantie)             | `-march=rv64gcv0p7` + bare [intrinsics](#intrinsic)     | Not supported                                         |
| Mainline GCC ≥ 13                     | Not supported                                           | `-march=rv64gcv` (1.0)                                |
| Mainline GCC ≥ 14                     | Not supported                                           | `-march=rv64gcv` + `-mrvv-vector-bits=<N>` for [VLS](#vls) |
| Mainline Clang ≥ 17                   | `-march=rv64gc_xtheadvector` (different [intrinsics](#intrinsic)) | `-march=rv64gcv`                              |
| Mainline Clang ≥ 19                   | `-march=rv64gc_xtheadvector` (mature)                   | `-march=rv64gcv` + `-mrvv-vector-bits=<N>`            |
| QEMU user                             | `-cpu thead-c906` (0.7)                                 | `-cpu rv64,v=true,vlen=<N>` (1.0)                     |

LLVM's [`xtheadvector`](#xtheadvector) is the practical way to target
C906/C910 from a modern toolchain. It exposes a **different
[intrinsic](#intrinsic) family** (`__riscv_th_*`) — source code written
against bare T-Head [intrinsics](#intrinsic) won't build on LLVM and vice
versa. This is the source of the "pick a 0.7 toolchain" decision called
out in [`rvv-implementation-plan.md`](rvv-implementation-plan.md).

## 12. Implications for the pystencils [RVV](#rvv) backend

Summary of how the terminology above maps onto the implementation plan:

- **Codegen model**: [VLS](#vls) (fixed-[lane](#lane)), not [VLA](#vla).
  User specifies ([SEW](#sew), [LMUL](#lmul)) at codegen time; backend
  emits one `__riscv_vsetvl_e{sew}m{lmul}(N)` at kernel entry and a
  derived [`vl`](#vl) symbol that threads through every op. Mirrors the
  [SVE](#sve) backend's [predicate](#predicate)-at-entry pattern.
- **[LMUL](#lmul) choice**: default to `m1`. Allow user override.
  Fractional [LMUL](#lmul) is only useful for mixed-width kernels and is
  [RVV](#rvv)-1.0-only — don't expose it in a 0.7 path.
- **Policy suffixes ([RVV](#rvv) 1.0)**: default to `_tu`
  (tail-undisturbed) to match [SVE](#sve) semantics; allow per-op override
  later. `_ta` is more performant but changes observable output at the
  tail.
- **[Mask](#mask) register**: not used in v1 of the backend. [`vl`](#vl)
  alone is the active-[lane](#lane) mechanism. Masked ops (for boundary
  handling) are a follow-up.
- **Indexed memory**: remember the byte vs element offset distinction. The
  pystencils [stride](#stride) is in elements; multiply by `sizeof(elem)`
  at codegen time before passing to `__riscv_vluxei*` ([RVV](#rvv)-1.0).
  T-Head's 0.7 ops were *element*-indexed natively, so the multiply
  applies only to 1.0. Easy to get wrong; assert in tests.
- **0.7 backend strategy**: subclass `RvvCpu` and override the
  [intrinsic](#intrinsic) name builder. Pick LLVM
  [`xtheadvector`](#xtheadvector) (`__riscv_th_*` names) as the target
  toolchain; T-Head GCC support can be a later layer.
- **[VLEN](#vlen) at codegen**: since this is [VLS](#vls), codegen needs a
  [VLEN](#vlen) value to compute the [lane](#lane) count. CMake side
  passes it as a build option (analogue of `-msve-vector-bits` plumbing
  already in walberla).

---

## Glossary

Definitions for every term used in this file. All term mentions above
link here.

<a id="rvv"></a>
**RVV** — *RISC-V Vector extension*. The `V` extension of the RISC-V
[ISA](#isa); a scalable vector ISA conceptually similar to [SVE](#sve).
**RVV-0.7.1** is the last pre-ratification draft (Dec 2019), implemented
by T-Head C906/C910 cores. **RVV-1.0** is the ratified spec (late 2021),
the standard targeted by mainline GCC ≥ 13 / Clang ≥ 17. They are **not
source- or binary-compatible**.

<a id="isa"></a>
**ISA** — *Instruction Set Architecture*. The set of machine instructions
a processor implements (e.g. x86, ARMv8, RISC-V), including vector
sub-extensions like [SSE](#sse) / [AVX](#avx) / [SVE](#sve) / [RVV](#rvv).

<a id="sse"></a>
**SSE** — *Streaming SIMD Extensions*. Intel/AMD's 128-bit fixed-width
vector [ISA](#isa) family.

<a id="avx"></a>
**AVX** — *Advanced Vector Extensions*. Intel/AMD's 256-bit fixed-width
vector [ISA](#isa). AVX-512 is the 512-bit successor.

<a id="sve"></a>
**SVE** — *Scalable Vector Extension*. ARM's length-agnostic vector
[ISA](#isa); vector register width is implementation-defined. Programs
use [predicated](#predicate) instructions that work at any width. The
existing scalable-vector backend in pystencils.

<a id="vlen"></a>
**VLEN** — *Vector Register Length*, in bits. Implementation-defined
width of one [RVV](#rvv) (or [SVE](#sve)) vector register. Must be a
power of two; [RVV](#rvv) 1.0 permits up to 65536.

<a id="elen"></a>
**ELEN** — *Element Length*. Implementation-defined upper bound on
[SEW](#sew), in bits. Typically 64. If [ELEN](#elen) < 64, double-width
FP ops are unavailable.

<a id="sew"></a>
**SEW** — *Selected Element Width* (in bits). The width of one element in
the currently configured [`vtype`](#vtype). Legal values: 8, 16, 32, 64
(up to [ELEN](#elen)).

<a id="lmul"></a>
**LMUL** — *Length Multiplier*, also called the *vector register group
multiplier*. Combines architectural registers into one logical operand.
Legal values in [RVV](#rvv) 1.0: 1/8, 1/4, 1/2, 1, 2, 4, 8 (fractional
values are 1.0-only).

<a id="vlmax"></a>
**VLMAX** — *Maximum Vector Length*. Derived: `VLMAX = VLEN · LMUL / SEW`.
The maximum element count for the current ([SEW](#sew), [LMUL](#lmul))
configuration. [`vsetvl`](#vsetvl) clamps [`vl`](#vl) to ≤ [VLMAX](#vlmax).

<a id="eew"></a>
**EEW** — *Effective Element Width*. Element width used by a specific
memory op, independent of the current [`vtype`](#vtype) [SEW](#sew).
Encoded in the [intrinsic](#intrinsic) mnemonic (`vle**32**`, `vluxei**16**`,
etc.).

<a id="emul"></a>
**EMUL** — *Effective Length Multiplier*. [LMUL](#lmul) used by a specific
memory op, independent of [`vtype`](#vtype) [LMUL](#lmul). Derived from
the relationship between the op's [EEW](#eew) and the current
[SEW](#sew)/[LMUL](#lmul).

<a id="avl"></a>
**AVL** — *Application Vector Length*. The element count a program
requests from [`vsetvl`](#vsetvl). Hardware returns the actually-granted
[`vl`](#vl), which may be ≤ [AVL](#avl).

<a id="vl"></a>
**vl** — *Vector length* [CSR](#csr). The active prefix length: number of
elements processed by the next vector instruction. Written by
[`vsetvl{i}`](#vsetvl), read by ordinary CSR reads.

<a id="vtype"></a>
**vtype** — *Vector type* [CSR](#csr). Encodes the current [SEW](#sew),
[LMUL](#lmul), [`vta`](#vta), [`vma`](#vma), and [`vill`](#vill).
Written exclusively by [`vsetvl{i}`](#vsetvl).

<a id="vstart"></a>
**vstart** — *Vector start* [CSR](#csr). First element index to process.
Non-zero only after a trap is resumed; ordinary code can assume it is 0.

<a id="vxrm"></a>
**vxrm** — *Vector fixed-point Rounding Mode* [CSR](#csr).

<a id="vxsat"></a>
**vxsat** — *Vector fixed-point Saturation flag* [CSR](#csr).

<a id="vcsr"></a>
**vcsr** — Convenience [CSR](#csr) providing a combined view of
[`vxrm`](#vxrm) and [`vxsat`](#vxsat).

<a id="vlenb"></a>
**vlenb** — Read-only [CSR](#csr): [VLEN](#vlen) in bytes (= [VLEN](#vlen)
÷ 8). Useful for portable address arithmetic in [VLA](#vla) code.

<a id="vta"></a>
**vta** — *Vector Tail-Agnostic* policy bit in [`vtype`](#vtype).
0 = tail-undisturbed (keep prior destination at tail elements),
1 = tail-agnostic (hardware may write all-ones).

<a id="vma"></a>
**vma** — *Vector [Mask](#mask)-Agnostic* policy bit in [`vtype`](#vtype).
0 = mask-undisturbed (keep prior dest at inactive elements),
1 = mask-agnostic.

<a id="vill"></a>
**vill** — *Vector Illegal* flag in [`vtype`](#vtype). Set by
[`vsetvl{i}`](#vsetvl) when the requested configuration is unsupported.
Causes subsequent vector ops to trap. Added in [RVV](#rvv) 1.0.

<a id="vsetvl"></a>
**vsetvl / vsetvli / vsetivli** — [RVV](#rvv) instructions that update
[`vtype`](#vtype) and [`vl`](#vl). `vsetvli` uses an immediate
[`vtype`](#vtype); `vsetvl` a dynamic one; `vsetivli` a 5-bit immediate
[AVL](#avl). [Intrinsic](#intrinsic) form:
`__riscv_vsetvl_e{sew}m{lmul}(N)` (1.0).

<a id="csr"></a>
**CSR** — *Control and Status Register*. RISC-V register for system-level
state. [RVV](#rvv) adds [`vl`](#vl), [`vtype`](#vtype), [`vstart`](#vstart),
[`vxrm`](#vxrm), [`vxsat`](#vxsat), [`vcsr`](#vcsr), [`vlenb`](#vlenb).

<a id="zvl"></a>
**Zvl\*** — *Minimum [VLEN](#vlen)* sub-extensions (`Zvl32b`, `Zvl64b`,
`Zvl128b`, `Zvl256b`, …, `Zvl65536b`). Each guarantees [VLEN](#vlen) is
*at least* that many bits, letting a binary assume a floor without pinning
the exact width. Part of the [ISA](#isa) string. [RVV](#rvv) 1.0 concept.

<a id="zve"></a>
**Zve\*** — *Embedded Vector* subsets (`Zve32x`, `Zve32f`, `Zve64x`,
`Zve64f`, `Zve64d`) plus FP add-ons (`Zvfh`, `Zvfhmin`, `Zvfbfmin`). They
specify which [SEW](#sew) values and floating-point element types the
vector unit actually implements — e.g. `Zve32f` = up to 32-bit incl. f32
but no f64; `Zve64d` = up to 64-bit incl. f64; `Zvfh` adds [FP16](#fp16).
Determines the effective [ELEN](#elen) and legal element types. [RVV](#rvv)
1.0 concept.

<a id="fp16"></a>
**FP16** — *16-bit Floating Point* (IEEE 754 binary16), half precision. In
[RVV](#rvv), vector [FP16](#fp16) ops are provided by the [Zvfh](#zve)
sub-extension (`Zvfhmin` for the conversion-only subset).

<a id="vla"></a>
**VLA** — *Vector Length Agnostic*. Code that produces a correct result
for any legal [VLEN](#vlen) of the target [ISA](#isa). Identifying
pattern: a [stripmining](#stripmining) loop.

<a id="vls"></a>
**VLS** — *Vector Length Specific*. Code compiled with a fixed,
compile-time-known [VLEN](#vlen). Enables fixed-size types, inlined
[lane](#lane) counts, and no [stripmining](#stripmining). Selected via
`-mrvv-vector-bits=<N>` (GCC ≥ 14) or
`-mllvm -riscv-v-vector-bits-min=<N>` (Clang ≥ 17).

<a id="stripmining"></a>
**stripmining** — Iterative chunking of a long loop into vector-sized
chunks. The canonical [VLA](#vla) idiom for [RVV](#rvv) and [SVE](#sve):
each iteration asks hardware for the largest [`vl`](#vl) it can grant and
steps the pointer by that many elements.

<a id="lane"></a>
**lane** — One element position within a vector register. With
[VLEN](#vlen)=256 and [SEW](#sew)=32 at [LMUL](#lmul)=1 there are 8
[lanes](#lane).

<a id="predicate"></a>
**predicate** — A bit-[mask](#mask) telling a vector op which
[lanes](#lane) are active. [SVE](#sve) uses an `svbool_t` register;
[RVV](#rvv) uses `v0` as the implicit [mask](#mask) register plus a
separate [`vl`](#vl) count.

<a id="mask"></a>
**mask** — Same as [predicate](#predicate). In [RVV](#rvv), the
[mask](#mask) is held in `v0` and selected per-instruction by the `vm`
field.

<a id="stride"></a>
**stride** — Distance between consecutive memory accesses. [RVV](#rvv)
strided ops (`vlse*`, `vsse*`) take the stride in **bytes**.

<a id="gather"></a>
**gather** — Vector load using a vector of indices (one per
[lane](#lane)). In [RVV](#rvv) 1.0 the index vector contains **byte
offsets**, not element indices — a common porting pitfall when coming
from [RVV](#rvv)-0.7 (element-indexed) or [SVE](#sve).

<a id="scatter"></a>
**scatter** — Vector store using a vector of indices. Same byte-offset
caveat as [gather](#gather).

<a id="broadcast"></a>
**broadcast** — Replicating a scalar value to every [lane](#lane) of a
vector. [RVV](#rvv): `__riscv_v*mv_v_x_*` (int) / `__riscv_vfmv_v_f_*` (FP).

<a id="segment"></a>
**segment load/store** — Memory op that transfers AoS
(array-of-structures) data, transposing it into separate vector registers
per field. [RVV](#rvv): `vlseg{n}e{eew}` and friends, n ∈ {2..8}.

<a id="fma"></a>
**FMA** — *Fused Multiply-Add*. `a·b + c` as a single rounded operation.
[RVV](#rvv) [intrinsic](#intrinsic): `__riscv_vfmacc_vv_f32m1(c, a, b, vl)`.

<a id="intrinsic"></a>
**intrinsic** — *Compiler intrinsic*. A C-level function that maps
one-to-one to a machine instruction. The [RVV](#rvv)-0.7 and [RVV](#rvv)-1.0
[intrinsic](#intrinsic) families have different names and are not
source-compatible.

<a id="xtheadvector"></a>
**xtheadvector** — LLVM extension that exposes T-Head's [RVV](#rvv)-0.7-era
instructions through standard-style [intrinsics](#intrinsic) with a
`__riscv_th_` prefix. The practical way to target C906/C910 from a modern
toolchain.

<a id="ir"></a>
**IR** — *Intermediate Representation*. A compiler's internal
representation between source code and machine code. pystencils has its
own stencil [IR](#ir).

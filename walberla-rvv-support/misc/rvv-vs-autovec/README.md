# RVV vs autovec: out-of-tree kernel experiment

**Question.** In the LBM baselines (`docs/notes2/rvv-vls256-only-progress-opus5.5.md`,
"Baselines"), explicit RVV is slower than plain auto-vectorization in f64, and rvv with GCC is
the slowest configuration. Why?

**Approach.** Take the kernels out of the JIT, build every variant as a standalone binary,
and measure each with wall time *and* hardware counters (cycles, retired instructions). No
pystencils code is changed. The generated sources can be edited by hand to test a hypothesis.

## Files

| file | role |
|---|---|
| `gen.py` | dumps the D2Q9 kernels (same assignments as `lb-pystencils.py`) as standalone `.cpp`, each with a fixed-signature `run_kernel` wrapper |
| `bench.cpp` | driver: same data layout as the harness; times `REPS` calls; reads cycles and instructions via `perf_event_open`; prints a checksum |
| `run.sh` | on the board: generate, build the variant matrix (parallel), disassemble (`llvm-objdump`), run pinned to one core, report |
| `report.py` | pivots `results.tsv` into markdown tables and appends `hotloops.txt` |
| `hotloop.py` | instruction histogram of the hot vector loops of linked binaries (`llvm-objdump`) |
| `fma_rewrite.py` | rewrites the generated RVV call trees: folds `-1.0 * x` into `vfneg` and fuses `a*b ± c` into `vfmacc`/`vfnmsac`/`vfmsac` (the FMA hand check) |

## Variant matrix

The matrix is {GCC 14.2, Clang 18} × {f64, f32} × kernel × build:

| kernel | what it does |
|---|---|
| `stream` | `g_i(x) = f_i(x − c_i)`: only memory traffic, so it is the floor for the fused kernel |
| `fused` | pull collide-stream exactly as the harness builds it (assignments passed as-is) |
| `fused_cse` | the same after `ps.simp.sympy_cse` |
| `fused_cse_neg` | `fused_cse`, RVV source with negations folded (`fma_rewrite.py`, mode `neg`) |
| `fused_cse_fma` | `fused_cse`, RVV source with negations folded and FMAs fused (mode `fma`) |

For the generic target, `fused_cse_neg` and `fused_cse_fma` are the same source as `fused_cse`.
Compilers already fold and fuse scalar code under `-ffast-math`, so those columns only
measure noise.

| build | source | flags |
|---|---|---|
| scalar | generic | `-march=rv64gc` (no V) |
| autovec | generic | `-march=rv64gcv_zvl256b` |
| rvv | rvv | `-march=rv64gcv_zvl256b` |

Optimization flags are the JIT's: GCC `-Ofast`, Clang `-O3 -ffast-math -fhonor-infinities`.
The grid sizes are 200² (the harness's periodic grid, about 5.9 MB in f64, so it runs from DRAM)
and 48² (fits in L2).

## Run

```bash
bash run.on.bananapi.sh bash misc/rvv-vs-autovec/run.sh     # from the laptop, ~10 min
# results: /home/bananapi/saleh/rvv-vs-autovec-build/report.md (+ src/, obj/, bin/)
# hand-edit a kernel on the board, then rebuild + rerun without regenerating:
NO_GEN=1 bash misc/rvv-vs-autovec/run.sh
```

Knobs (environment variables): `SIZES`, `REPS`, `CPU` (the pinned core), `JOBS`, `BUILD`,
`GCC_EXTRA` / `CLANG_EXTRA` (extra kernel flags for one compiler).

## Hypothesis

The harness passes the BGK assignments to `create_kernel` without CSE, so each of the 9
`g_i` statements contains the full ρ sum, the `1/ρ` divisions and `u²` again. pystencils
prints that one-to-one. In the generated f64 rvv source, each vector iteration has:

| per vector iteration (source) | `fused` | `fused_cse` |
|---|---|---|
| `__riscv_vfdiv` | 46 | 2 |
| `__riscv_vle64` | 1059 | 60 |
| `__riscv_vfmv_v_f` (broadcast) | 269 | 68 |

- **Scalar and autovec builds:** the compiler sees plain scalar C and removes the repeats
  itself.
- **rvv build:** the compiler would have to merge identical `__riscv_*` intrinsic calls across
  the intervening `vse` stores.
  - The baselines show 4027 vector instructions for rvv-GCC vs 1519 for rvv-Clang.
  - This suggests GCC does not merge them, and Clang only partly does.

## Results with runtime strides (board run 2026-11-01 09:01) — supersedes the sections below

**Correction.** The earlier runs (06:07–06:26, kept below) compiled the wrapper in the same
TU as the kernel. The compiler inlined the constant strides: inner stride 1, and one row
stride for all 18 arrays. That helped the generic (autovec) kernels most. In the JIT every
size and stride is a runtime argument, so `gen.py` now writes the wrapper as a separate TU.
The CSE'd harness confirms the new picture: rvv GCC is the fastest full step (see
`docs/notes2/rvv-vls256-only-progress-opus5.5.md`, "Baselines with CSE").

`fused_cse` kernel, MLUP/s:

| | GCC scalar | GCC autovec | Clang autovec | GCC rvv | Clang rvv |
|---|---|---|---|---|---|
| f64, 200² | 7.05 | 7.85 | 8.12 | **10.60** | 6.84 |
| f64, 48² | 8.15 | 9.98 | 10.70 | **13.23** | 7.87 |
| f32, 200² | 9.12 | 8.98 | 14.71 | **22.56** | 14.93 |
| f32, 48² | 10.10 | 9.95 | 20.76 | **28.11** | 16.82 |

**Our generated code with GCC beats every autovec build**, compared with the better of the
two autovec builds: 1.24–1.31× in f64 and 1.35–1.53× in f32. Checksums agree as before.

### Why, from the disassembly (f64, `hotloop.py` and `llvm-objdump`)

- **GCC autovec cannot assume the inner stride is 1, so it gathers.**
  - All 18 field accesses become indexed `vluxei64`/`vsuxei64`.
  - The index vectors are reloaded from the stack: 27 `vl1re64` per iteration.
  - The hot loop is 309 instructions (78 retired per cell); with constant strides it was 161.
- **Clang autovec versions the loop on stride == 1.**
  - The binary has no gathers, only unit-stride `vl2re64` at LMUL 2 (8 cells per iteration).
  - This keeps Clang autovec decent (32 instructions per cell). The price is register
    pressure: the hot loop has 39 whole-register loads/stores, 18 of which are data, so
    about 21 are LMUL-2 spills and reloads.
- **Our backend assumes inner stride 1, exactly like AVX** (`assume_inner_stride_one`).
  - It emits plain `vle64`/`vse64`: GCC's loop is 220 instructions, 56 per cell.
  - The FP ops are not fused (73 `vfmul` + 73 `vfadd`), but on the X60 that costs nothing
    measurable (see "FMA hand check").
- **Clang rvv is the one weak build** (0.74–0.84× Clang autovec in f64, about equal in f32). It has the same op mix
  as GCC rvv but a much worse schedule:
  - Clang issues each dependency chain back to back. Its ρ sum is 8 dependent `vfadd` in a
    row, so the in-order X60 stalls on every one. GCC interleaves the loads and two
    independent chains.
  - Clang keeps the hoisted constant splats live in vector registers, then spills: 1 `vs1r`,
    5 `vl1r`, 6 `csrr vlenb` and scalar `sd`/`ld` per iteration.
  - The board's Clang 18.1.8 (Bianbu) has a `spacemit-x60` scheduling model; GCC 14 does not.

### Clang with `-mtune=spacemit-x60` (board run 09:06, `CLANG_EXTRA=-mtune=spacemit-x60`)

`fused_cse` kernel, MLUP/s; the value in parentheses is without `-mtune`:

| | Clang scalar | Clang autovec | Clang rvv | GCC rvv (unaffected) |
|---|---|---|---|---|
| f64, 200² | 6.91 (3.88) | 7.78 (8.12) | 7.42 (6.84) | 10.50 |
| f64, 48² | 7.86 (4.15) | 10.97 (10.70) | 8.87 (7.87) | 12.80 |
| f32, 200² | 7.71 (4.77) | 15.94 (14.71) | 17.13 (14.93) | 22.61 |
| f32, 48² | 8.54 (5.16) | 22.21 (20.76) | 19.60 (16.82) | 28.18 |

- **Clang scalar code gains 62–89%**, about level with GCC scalar.
- **Clang rvv gains 8–17%, but stays 24–31% behind GCC rvv.**
  - The X60 schedule hoists loads earlier, which raises register pressure.
  - The f64 loop grows from 235 to 307 instructions, and whole-register spills/reloads go
    from 6 to 19 per iteration.
  - Clang + X60 tuning is even faster on the *non*-CSE kernel (f64 8.59 vs 7.42). With
    fewer long-lived subexpressions there is less to spill.
- **Clang autovec is unchanged within noise.**
- **GCC rvv stays the fastest build everywhere.** GCC is also the JIT's default compiler on
  Linux (`GccInfo` is tried first), so the default path is already the fast one.
- `-mtune=spacemit-x60` is a vendor-Clang, K1-specific flag, so it is not added to the
  pystencils JIT.

### Splat folding: `fused_cse_vf` (board run 2026-11-01 09:19, default flags)

`fma_rewrite.py` mode `vf` passes every constant splat operand as a scalar:

- `vfmul_vv(splat(c), x)` becomes `vfmul_vf(x, c)`;
- likewise for add, and with `vfrsub`/`vfrdiv` for the reversed operand order.

That is 59 rewrites. 9 splats remain where both operands were splats. Checksums are
bit-identical to `fused_cse`, because `.vf` with a scalar is the same arithmetic as `.vv`
with its splat. This is the old fable branch's "D14 broadcast folding".

MLUP/s; the arrow shows `fused_cse` → `fused_cse_vf`:

| | GCC rvv | Clang rvv | Clang autovec (for reference) |
|---|---|---|---|
| f64, 200² | 10.67 → 10.83 | 6.84 → **7.91** (+16%) | 8.70 |
| f64, 48² | 13.93 → 14.75 | 7.97 → **8.53** (+7%) | 11.47 |
| f32, 200² | 22.54 → 23.30 | 14.93 → **18.15** (+22%) | 14.83 |
| f32, 48² | 26.56 → 29.99 | 16.85 → **20.98** (+25%) | 20.86 |

- **Why it helps:** with `.vv`, both compilers hoist each constant splat out of the loop into
  its own vector register. About 10 constants (the weights, 3, 4.5, 1.5, ω, −1, …) occupy a
  third of the 32 vector registers.
  - Clang then spills: 6 whole-register spills/reloads plus `csrr vlenb` per iteration.
  - With `.vf` the constants sit in scalar FP registers. Clang's f64 loop shrinks from 235 to
    210 instructions with **0 spills**, and GCC's 2 whole-register ops disappear too.
- **Effect:** Clang rvv gains 7–25%, GCC rvv 1.5–13%.
- **In f32, Clang rvv with `.vf` now matches or beats Clang autovec:** 18.15 vs 14.83 at 200²,
  20.98 vs 20.86 at 48².
- **In f64, Clang rvv is still behind Clang autovec** (0.91× at 200², 0.74× at 48²).
  - Clang autovec runs at LMUL 2: 8 doubles per instruction and 32 instructions per cell,
    against our 54.
  - Test: Clang with `-mllvm -riscv-v-register-bit-width-lmul=1` (autovec forced to
    LMUL 1). Results in the next section.

### Clang autovec at LMUL 1 (board run 2026-11-01 09:24, `CLANG_EXTRA="-mllvm -riscv-v-register-bit-width-lmul=1"`)

The flag only changes Clang's auto-vectorizer. Intrinsic code is unaffected: Clang rvv
`fused_cse` measured 7.15 vs 6.84, which is noise. GCC is untouched.

`fused_cse` kernel, MLUP/s:

| | Clang autovec LMUL 2 (default) | Clang autovec **LMUL 1** | Clang rvv + `.vf` | GCC rvv (+ `.vf`) |
|---|---|---|---|---|
| f64, 200² | 8.70 | **10.10** | 7.93 | 10.60 (10.88) |
| f64, 48² | 11.47 | **13.15** | 9.21 | 14.19 (14.75) |
| f32, 200² | 14.83 | **22.08** | 18.05 | 21.34 (23.35) |
| f32, 48² | 20.86 | **27.47** | 20.58 | 26.39 (29.99) |

The second Clang autovec value at 48² f64 is used; the first was an outlier, 11.79 against
13.15–13.17 for the identical sources.

- **LMUL 2 is not Clang autovec's advantage; it costs Clang 15–49%.**
  - At LMUL 1 the hot loop is 142 instructions per 4 cells with 18 whole-register ops,
    which are exactly the 9 loads and 9 stores, so no spills.
  - At LMUL 2 it had about 21 spills per iteration.
- **With LMUL 1, Clang autovec reaches GCC rvv level.** GCC rvv with `.vf` is ahead by
  1.08–1.12× in f64, and 1.06/1.09× in f32 (200²/48²). So with the best available
  auto-vectorization, our explicit path is about on par, slightly ahead. With the
  compilers' default settings it is clearly ahead: GCC autovec gathers, and Clang autovec
  picks LMUL 2 and spills.
- **What Clang autovec still has over Clang rvv is op count and schedule.**
  - Clang optimizes scalar IR under `-ffast-math`, which gives FMA contraction, folded
    negations and `.vf` constants: 88 FP ops per 4 cells against 157 in our intrinsic loop.
  - RVV intrinsics are opaque to those passes.
  - GCC schedules our 157-op loop well enough that the op count does not matter (FMA hand
    check). Clang does not: its default scheduler for generic RISC-V issues dependency
    chains back to back on the in-order X60, so every extra op adds stall cycles.
  - This is why folding helps Clang (`.vf` up to 25%, `neg` 13–17%) and not GCC.

### Summary: why GCC rvv beats GCC autovec, but Clang rvv trails Clang autovec

| | GCC | Clang |
|---|---|---|
| autovec with a runtime inner stride | indexed gathers/scatters (`vluxei64`/`vsuxei64`) for all 18 accesses, 78 insns/cell: **slow** | versions the loop on stride == 1, then unit-stride `vl2re64` at LMUL 2 with `.vf` constants, 32 insns/cell: **good** |
| our intrinsics | good schedule (interleaves independent chains), splats in vector registers but only 2 spill ops: **fast** | chains issued back to back on the in-order X60, splats in vector registers cause spills: **weak** |

1. **GCC side:** our win is the inner-stride-1 assumption, the same contract as AVX. GCC's
   autovec has no such information in the JIT and gathers.
2. **Clang side:** Clang autovec gets unit stride too, via runtime versioning, so our
   contract gives no advantage. What remains is code quality:
   - The splat registers make Clang spill. Fixed by `.vf`: f32 catches up.
   - Clang has no X60 scheduling by default. `-mtune=spacemit-x60` gives +8–17%, but only
     in the vendor Clang.
   - It is **not** LMUL: Clang autovec gets *faster* at LMUL 1 (f64 10.10, f32 22.08 MLUP/s),
     on par with GCC rvv. The remaining gap is Clang's own algebra on scalar IR (88 vs 157
     FP ops per iteration), which RVV intrinsics block, combined with a schedule that exposes
     every extra op on the in-order X60.

## Earlier results with inlined strides (06:07, biased toward the generic kernels)

A second run at 06:15 reproduced every fused / fused_cse number within about 5%.

**Correctness.** Every build of a kernel agrees:

- f64 checksums are identical to 13 digits;
- f32 checksums spread ≤ 2e-8 relative (`-ffast-math` reassociation).

### Kernel throughput (MLUP/s, higher is better)

| kernel | grid | GCC scalar | GCC autovec | GCC rvv | Clang scalar | Clang autovec | Clang rvv |
|---|---|---|---|---|---|---|---|
| f64 fused (as the harness) | 200² | 7.54 | 10.31 | **3.54** | 4.33 | 8.61 | 6.38 |
| f64 fused_cse | 200² | 7.40 | **11.55** | 10.85 | 4.45 | 8.98 | 6.68 |
| f64 fused_cse | 48² | 8.54 | **16.12** | 12.30 | 4.60 | 12.30 | 7.74 |
| f32 fused (as the harness) | 200² | 9.19 | 22.50 | **7.66** | 5.16 | 15.74 | 14.26 |
| f32 fused_cse | 200² | 9.40 | **24.78** | 23.10 | 5.13 | 17.06 | 14.66 |
| f32 fused_cse | 48² | 10.49 | **31.49** | 30.00 | 5.54 | 25.24 | 16.05 |

Retired instructions per cell, f64, 200²:

| kernel | GCC autovec | GCC rvv | Clang autovec | Clang rvv |
|---|---|---|---|---|
| fused | 50 | **169** | 32 | 63 |
| fused_cse | 41 | 56 | 29 | 62 |

### Hot vector loop, f64 fused_cse (one iteration = 4 cells at LMUL 1)

From `hotloop.py`. Retired instructions per cell × lanes matches the loop length, which
identifies the loop that actually runs.

| build | insns | vfmul | vfadd | vfsub | FMA | vfdiv | note |
|---|---|---|---|---|---|---|---|
| GCC rvv | 222 | 73 | 73 | 11 | **0** | 2 | |
| Clang rvv | 244 | 73 | 73 | 11 | **0** | 2 | 7 whole-register ld/st |
| GCC autovec | 161 | 15 | 24 | 9 | **37** | 2 | |
| Clang autovec | 230 | 21 | 35 | 12 | 19 | 2 | LMUL 2 (8 cells), 34 whole-register ld/st |

f32 gives the same loops with `e32`.

### Findings

1. **Stupid problem #1: the harness never applies CSE.**
   - `lb-pystencils.py` hands the raw BGK assignments to `create_kernel`, so each of the 9
     `g_i` statements recomputes ρ, `1/ρ` and `u²`.
   - In the f64 RVV source, one vector iteration has 46 `vfdiv` and 1059 `vle64`; with CSE
     it has 2 and 60.
   - Compilers remove the repeats from scalar code, and Clang also does it for RVV
     intrinsics (63 → 62 insns/cell). **GCC does not** (169 → 56 insns/cell).
   - GCC's no-CSE RVV loop is 673 instructions per iteration, with 17 `vfdiv` and 81
     `vle`. Clang's is 247 instructions with 2 `vfdiv`.
   - This alone makes rvv GCC 3× slower: f64 3.54 → 10.85, f32 7.66 → 23.10 MLUP/s.
   - `create_kernel` never applies CSE itself; callers do (the pystencils tutorials call
     `ps.simp.sympy_cse` explicitly). So this is a harness bug, not a backend bug. Whether
     lbmpy-generated walberla kernels are affected was not checked, because lbmpy is not installed.

2. **Stupid problem #2: the intrinsic code has no FMAs and keeps `-1.0 * x` as a multiply.**
   - Per iteration the rvv loop has 157 vector mul/add/sub ops; GCC autovec has 85, counting
     an FMA as one op, for the same 4 lanes.
   - pystencils prints `-x` as `-1.0 * x`: 23 of the 90 `vfmul` calls in the source are
     multiplications by a splat of `-1.0`.
   - Neither GCC 14 nor Clang 18 fuses or folds RVV intrinsic calls.
   - The AVX path does not hit this: `_mm256_mul_pd` and friends are defined in the headers
     as plain vector arithmetic (`(__v4df)a * (__v4df)b`), so the compiler contracts and folds
     them like scalar code. An RVV intrinsic is an opaque builtin.
   - Cost when compute-bound (48², f64): GCC rvv 135 vs GCC autovec 104 cycles/cell. At 200²
     DRAM hides part of it (156 vs 145).

3. **Clang's rvv loop runs at low IPC.**
   - It has almost the same instruction mix as GCC's (244 vs 222 per iteration), but needs
     247 vs 156 cycles/cell (f64, 200²). IPC is 0.25 vs 0.36.
   - Not yet explained. Candidates: instruction scheduling for the in-order X60, and spill
     reloads (7 whole-register loads/stores plus 7 `csrr vlenb` for spill-slot addresses per
     iteration; GCC's loop has 2 whole-register loads/stores).

4. **Other observations, not investigated:**
   - Clang autovec picks LMUL 2 and spills heavily (34 whole-register loads/stores per iteration).
   - GCC autovec at LMUL 1 is the fastest build overall.
   - The DRAM-bound `stream` numbers at 200² are noisy on the shared board: GCC scalar f64
     gave 29.1 and then 17.9 MLUP/s. In L2 (48²) the rvv `stream` kernel is reproducibly the
     fastest (31–37 MLUP/s f64, 67–81 f32), so plain RVV loads/stores are fine.
   - The harness's full-step MLUP/s is about 35% below the kernel's (f64 periodic autovec GCC:
     6.69 vs 10.31). The rest of the step goes to NumPy ghost fills and Python calls, so harness
     numbers compress the differences.

### FMA hand check (board run 2026-11-01 06:26)

`fma_rewrite.py` rewrote the `fused_cse` RVV source:

- 22 `x * splat(-1.0)` became `vfneg`;
- 1 `x + vfneg(y)` became `vfsub`;
- 49 `a*b ± c` became `vfmacc`/`vfnmsac`.

The compiled loop (f64, GCC) goes from 222 instructions with 73 `vfmul` and no FMA to
187 instructions with 19 `vfmul` and 49 FMAs. That is a better op mix than GCC autovec
(15 mul + 37 FMA). Checksums still agree: f64 identical, f32 within 1e-8.

f64, MLUP/s (cycles per cell):

| rvv build | grid | fused_cse | + neg folded | + neg + FMA | autovec, same compiler |
|---|---|---|---|---|---|
| GCC | 200² | 10.85 (157) | 10.84 (153) | 10.51 (160) | 11.64 (148) |
| GCC | 48² | 13.47 (126) | 12.66 (133) | 13.33 (126) | 15.46 (114) |
| Clang | 200² | 6.65 (248) | **7.52 (219)** | 7.02 (236) | 9.09 (186) |
| Clang | 48² | 7.52 (220) | **8.83 (197)** | 8.42 (202) | 12.61 (139) |

f32 behaves the same:

- GCC rvv: 23.0 → 22.9 → 22.7 at 200²; 28.1 → 28.2 → 29.8 at 48².
- Clang rvv: 14.7 → **16.6** → 15.2 at 200²; 16.1 → **18.9** → 17.2 at 48².

**Verdict: FMA does not matter on the X60 for this kernel.**

- **GCC:** 16% fewer retired instructions (56 → 47 per cell), yet the cycles stay the
  same. All three columns are within the run-to-run noise. The fused_cse rvv number alone
  varied 12.3–13.5 MLUP/s at 48² over three runs.
- **Clang:** folding the negations gains 13–17%, but adding FMAs on top is *slower* than
  folding alone. Clang's rvv loop stays far behind GCC's (7.5 vs 10.8 MLUP/s), so its
  problem (#3) is not the op count.
- **Every vector build sits at about 450–500 cycles per 4-cell f64 iteration**, whether
  the loop has 161, 187 or 222 instructions. The loop is bound by something other than FP
  op issue.
- **Lead (not measured):** every build still does 2 divides per cell, `1/ρ²` and `1/ρ`.
  sympy's CSE keeps `1.0 / (xi_5 * xi_5)` as its own division instead of squaring `1/ρ`.
  Vector divides are a likely candidate for that floor.
- **The rest of the rvv-vs-GCC-autovec gap (about 5–10%):** GCC's rvv loop issues 17
  vector loads per iteration where autovec issues 9. GCC reloads 8 PDFs after the first
  `vse` instead of reusing them. Clang's rvv loop loads each PDF once.

### What would fix what

| problem | fix | where |
|---|---|---|
| #1 | `ps.simp.sympy_cse` in the harness (**done**: `_cse()` in `lb-pystencils.py`, also `lbm_rvv_check.py`) | harness |
| #2 | measured by hand (above): FMA gains nothing with GCC; folding negations gains 13–17% with Clang only. Not worth a backend change for now | — |
| #3 | try a Clang with an X60 scheduling model; inspect spills | investigation |

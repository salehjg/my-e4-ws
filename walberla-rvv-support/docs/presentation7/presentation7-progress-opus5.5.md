# presentation7: progress log

Started 2026-11-23 by Opus 5.5, from the user's request after the full monte3 run: write presentation7 based on
presentation6. The user's requirements:
- **Plots:** Clang as real bars (no diamonds), patterns and colours, labelled axes, a framed legend, a shared y-axis
  for side-by-side panels, and the right linear or log scale.
- **Self-sufficient:** the slides do not rely on the codebase or on older talks.
- **Bullet-proof:** every result is checked and traceable.
- **Structure** (added during planning): what holds on both machines outside the parts; part 1 is the K1, with
  prefetch and everything else K1-specific; part 2 is the SG2044; comparisons between the machines come after both
  parts. Nothing was committed.

Plan: `/home/saleh/.claude/plans/binary-imagining-brook.md`. Decisions:
- The K1 probe slides stay, labelled "measured on the K1".
- About 25-30 minutes.
- The SG2044 raw logs stay private. Derived tables are tracked.

## Files

| file | what |
|---|---|
| `slides.tex` | the deck. Preamble from presentation6, plus `groupplots`, `catchfile`, the result-plot macros (`\onecorefig`, `\scalingfig`, `\gainfig`, `\timefig`) and `\nv{key}` for every number |
| `tables/` | written by `scripts/presentation7/slide_data.py`: `numbers.tex` (`\nset{key}{value}`), `<m>-1core-<prec>.dat`, `<m>-scaling-<prec>.dat`, `<m>-time-<prec>.dat`, `<m>-table-<prec>.tex` (backup tables), `cmp-fair.dat`; m = `kone` (K1) or `sg` (SG2044). Each file names its source logs with their sha256 |
| `board-logs/k1/` | copies, byte for byte, of `docs/presentation6/board-logs/board/{ldc-*,verify-*,compilers-*}.log` and `notes5/{e2-A-output-last,e10-A-clang-output-last}.log` |
| `figures/` | from presentation6: cavity, lbm, build-run, chain, stencil-d3q19, field-layout, parallel, stream-def, stream-count, ab, aa-pattern, split-loop, k1, streams, stream-test, prefetch-insert, zicbop, split-code, kernel-code, both films. New: `sg2044.tex`, `vlen.tex`, `vlen-flow.tex` |
| `build.sh`, `.gitignore` | presentation6's (header changed; `tables/` and `board-logs/` tracked) |

Edits to the copied figures:
- `kernel-code`: the RVV overlay shows "L cells", with 4 slots drawn full and 4 drawn light.
- `parallel`: one f32 instruction covers 8 cells on the K1 and 4 on the SG2044 (solid and dashed boxes).
- `build-run`, `chain`: `-march=rv64gcv_zvl<V>b`, and the build measures the width.
- `split-loop`: L1 is 32 KB on the K1 and 64 KB on the SG2044.
- `field-layout` is unchanged: the 16-byte padding is `hostAlignment()` = `__BIGGEST_ALIGNMENT__`, which is 16 on
  riscv64 whatever the VLEN (`submodules/walberla/include/walberla/v8/memory/MemoryTraits.hpp:32-46`).

## Data and checks (`python3 scripts/presentation7/slide_data.py`, 2026-11-23: all pass)

**K1** (presentation4 `all.sh`, 2026-11-16):
- 132 configurations × 3 runs; 200 steps + 10 warm-up; 1/4/8 cores.
- The field hash is identical in every run. The 11 builds' energies spread by 1.1e-15 (f64) and 3.9e-6 (f32).
- 7 spot values equal presentation6's tables.
- VERIFY PASS ×4, 44 sha256s. Max error vs reference: 2.2e-16 (f64), 9.2e-8 (f32).

**SG2044** (run `20261122-214637`: build job 8565, timing job 8566):
- 264 configurations × 3 interleaved rounds; 60 steps + 10 warm-up; 1-64 processes.
- Field hashes identical; energy spread 6.2e-16 (f64) and 1.2e-6 (f32).
- BUILD PASS with 44 audits; TIME DONE with no FAILED or SKIPPED lines.
- Our best-of values equal the job's own table (176 values).
- MPI check PASS at 4-64 processes, helper thread at 0 %.
- VERIFY PASS ×4, 44 sha256s, errors as on the K1.
- 240 rounds. In 1 round a core showed 3 % before the round started (`ldc-gcc-autovec-f32-64core.log`, round 2,
  cpu24). The check allows single cores up to 5 % and reports them.

**Round-to-round spread:**

| | K1 | SG2044 |
|---|---|---|
| median | 0.8 % | 0.5 % |
| configurations above 3 % | 3 of 132 | 7 of 264 |
| largest | 6.4 % | 11.0 % (GCC f64 `explicit_cse` at 8 processes; none of the plotted builds) |
| largest among plotted builds | 2.3 % | 5.3 % |

**Fair test** (output only in the last step, one core), fastest RVV over best scalar:

| | K1 GCC | K1 Clang | SG2044 GCC | SG2044 Clang | lanes, K1 / SG2044 |
|---|---|---|---|---|---|
| f32 | 2.08 | 2.36 | 2.00 | 2.23 | 8 / 4 |
| f64 | 1.40 | 1.45 | 1.54 | 1.44 | 4 / 2 |

On the K1 with GCC in f64, the fastest RVV build in that test is in place + prefetch; everywhere else it is the
split loop.

**Findings shown on the slides:**
- The split loop is the fastest build in every column: 12 of 12 on the K1, 24 of 24 on the SG2044.
- Auto-vectorized builds are never faster than scalar by more than 1.8 % (K1) or 0.8 % (SG2044).
- On the SG2044, Clang's `explicit_cse_aa_pf` with output last runs at about half speed:
  - 3.28 vs 6.20 MLUP/s (f64) and 6.66 vs 12.39 (f32), the same in all 3 rounds.
  - Output last selects the generated `StreamCollide*NoOutput` kernels (`SweepgenLdcCPU.cpp:169-206`), so it is a
    different kernel.
  - GCC does not show it. The cause was not investigated, and the slide says so.
- Prefetch on the SG2044:
  - Not in place, it makes GCC's f32 build slower (13.81 → 11.94) and helps Clang.
  - In place, it helps both compilers in both precisions.
  - The deck makes no claim about whether the C920v2 executes the hint.
- Traffic estimate at 64 processes for the GCC split build: 93-102 GB/s (f32), 106-116 GB/s (f64). That is bytes
  per cell in place (42 or 46 values) × MLUP/s, labelled as an estimate.

**Claims I corrected while writing:**
- "Most of the speedup is not the vectors" became "the vectors alone give ×2.08 of 8 / ×2.00 of 4; the rest comes
  from computing less and touching fewer arrays". On the SG2044 the vectors are about half of the total.
- "Vectors give half their lanes" became "far less than their lane count": that is a quarter on the K1.
- The autovec row shows the largest *gain*: autovec was never faster beyond those numbers.

**Generated-code excerpt** (VLEN slide): made on the laptop with the fork (pystencils `78afe1ff`, `.venv-rvv`):
- a 2D 4-point f32 stencil, generated for `RISCV_RVV256` and for `RISCV_RVV128`
- options: `cpu.vectorize.enable`, `assume_inner_stride_one`, `default_dtype="float32"`
- both use `f32m1`; the K1 version has vl and step 8, the SG2044 version 4

Without `default_dtype="float32"`, the default lane count follows f64, which gives `f32mf2`, 4 lanes at 256.

## Build and visual check

- `./build.sh`: 0 errors and 1 open `\todo` (the workspace commit on the code slide).
- Two tiny overfull hboxes remain: 2.7 pt in the build-run figure (presentation6 has the same) and 0.3 pt.
- Every slide was rendered (`pdftoppm`) and looked at. Fixed along the way:
  - groupplot panels drawn on top of each other: `group style` has to be given inline, not through a style
  - the SG2044 hardware boxes
  - the overflowing builds table and vlen-flow figure
  - the K1 backup table split into two slides
  - the fair-test labels made horizontal
  - plot numbers in the text font (`assume math mode`)
- Colours were checked with the dataviz skill's validator:
  - GCC blue `#2A78D6` against Clang orange `#EB6834`: CVD ΔE 24.7.
  - The time-share colours violet, aqua and yellow: all-pairs ΔE ≥ 9.1. Aqua and yellow are below 3:1 contrast,
    so every segment that is big enough carries its number.

## Open

- The workspace commit on the code slide, once the user commits.
- No SG2044 film. The flow slide shows the laptop and K1 films and says so.

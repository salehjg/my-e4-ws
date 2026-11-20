# notes5: proposed changes to docs/presentation4 (not applied)

Written by Opus 5.5 on 2026-11-20, from `audit-findings-opus5.5.md` (same folder). Nothing in `docs/presentation4/`,
the forks or the scripts was changed by the audit; this file lists what each finding would change, so the owner
can decide. Slide numbers are PDF pages of `docs/presentation4/build/slides.pdf` (main part 1-22, backup 23-27).
Line numbers refer to `docs/presentation4/slides.tex` at superproject `7cd0626`.

## The one change that matters most (F1, F6, F19)

The deck measures "everything we did" against the plain scalar build and compares that with the vector width.
The audit's measurements show what the vectors themselves add on this board, with the same non-vector levers on
both sides (notes5 E2: in place, ρ/u written only in the last step, so both loops have 19 streams):

| GCC, 1 core, 64³ | best scalar | fastest RVV build | RVV / scalar |
|---|---|---|---|
| f32 | 3.98 MLUP/s | 8.27 (split) | **2.1×** (bulk phase only: 2.6×) |
| f64 | 3.44 MLUP/s | 4.80 (in place + prefetch) | **1.4×** (bulk phase only: 1.5×) |

Clang (E10): best scalar 3.40 / 3.30, fastest RVV 8.02 / 4.78, i.e. **2.4× / 1.45×**. A defensible story for the talk:

1. Everything together (CSE, in-place update, prefetch, split loop, RVV) makes the program 5.5× (f32) / 5.1× (f64)
   faster than the plain scalar build. True, keep it, but do not compare it with 8× / 4×.
2. The vectors' own share is about 2× (f32) and 1.4× (f64). The reason is the memory system, and the audit found
   a sharper explanation than "the prefetcher follows 20 streams": on the X60 **a vector load that misses waits the
   full ~360 cycles and never overlaps with other misses** (scalar misses overlap 3-5×, E4/E7). For vector code the
   hardware prefetcher, or software prefetch (a scalar hint), is the only memory parallelism there is. That is
   why prefetch doubles the RVV loop, why the split loop helps it, and why the scalar loop copes with 19 streams
   and the RVV loop does not (F17).
3. The measured speeds depend on where the arrays sit in memory: the same in-place + prefetch executable runs at
   3.5 to 7.9 MLUP/s across allocation layouts (F6, E6), and the split loop's ranking flips with it (F18).
   Present speedups as ranges, not three-digit numbers.

## Slide by slide

| slide | now (slides.tex line) | proposed | finding |
|---|---|---|---|
| 2 | "Per cell and time step: 19 loads, about 200 operations, 19 stores. Walls: border cells only." (198) | "... 19 loads, about 200 operations, 23 stores (19 values + ρ, u). The wall pass touches border cells only, but it is plain C++ in every build: a third of the fastest build's time." | F2, F13 |
| 4 | "One 256-bit operation per cycle: at best 8× (f32) and 4× (f64). These are our goals." (250-251) | "One 256-bit operation per cycle: 8 f32 or 4 f64 numbers at once (measured: `p2-ops.txt`). That bounds what vectors alone can add to the arithmetic." | F1, F9 |
| 5, 27 | run loop "kernel → halo exchange" (`figures/build-run.tex`) | add "wall pass" after the halo exchange | F16 |
| 6 | "Users change nothing ..." (286-287) | "The generator script asks for vectorized code once; on RISC-V that now gives RVV, as it gives AVX on x86." | F13 |
| 8 | "Up to 19 streams ... at least 4 of 5 lines in time ... it waits a full memory latency ... it is the number of streams." (332-336); takeaway "waits for memory in 92 % of its cycles" (339-340) | "In this read-only test, up to 19 streams the prefetchers deliver most lines in time (4160 B layout). Past that, every vector load waits the full latency, about 360 cycles: vector misses do not overlap on the X60, scalar misses do (3-5 at once)." Takeaway: "... 92 % of the cycles are backend stalls (64 % in the split loop)." Plot: label the log axis, unit of "late lines", note single runs. | F3, F17, F19, F20 |
| 9 | caption "huge pages" | add: "the cliff is the same with 4 KB pages (notes5 E1-B)" (strengthens the slide) | E1-B |
| 12 | "260 bytes per cell", "184 bytes per cell" (401, 412) | "... per cell in f32 (with write-allocate)" | F13 |
| 14 | "7 % (f32) and 13 % (f64) slower, from 33 % and 40 % more instructions" (450-451) | "2 to 7 % (f32) and 12 to 13 % (f64) slower; prefetching streams the hardware already follows costs more than it saves (stream test: up to 3.6× slower below 20 streams)" | F7 |
| 13-21 | split loop "the fastest build" (bold) | keep it as the fastest *in this run*, add "the ranking against in place + prefetch depends on the memory layout (0.74-1.96×, notes5 E6)" | F18 |
| 15 | takeaway "f32 reaches 5.55× of the possible 8× with both compilers. Auto-vectorization gives nothing." (477-478) | "Everything together: 5.5× (f32) the plain scalar build, with both compilers. With the same in-place update and no output stores on the scalar side, the vectors add about 2×. The compilers do not vectorize these kernels by themselves (the x stride is a run-time value)." Remove the 8× line or move it to a vectors-only plot. | F1, F8, F15 |
| 16 | "f64 passes its 4× goal with both compilers ..." (490-491) | "Everything together: 5.1× (GCC), 5.0× (Clang). The vectors' own share in f64: about 1.4×." | F1 |
| 15-19 | three-digit speedups | two digits and a range ("5.5-6.1×", second session) | F8 |
| 19 | "Memory traffic of RVV on 8 cores: about 4 GB/s in all." (531); takeaway (535-536) | "Estimated 4.6 GB/s during stream/collide (bytes per cell × rate), close to the ~6 GB/s the chip moves for the same pattern." "The two fastest RVV builds gain only 6-9 % ..." | F4, F5 |
| 20 | "All builds agree (energy to 10⁻¹⁵ in f64, 4·10⁻⁶ in f32)" (577-578) | "... f32: 1.2·10⁻⁷ between the single-loop builds; the split loop rounds differently (3·10⁻⁶, closer to f64)" | F14 |
| 22 | `[TODO: commit]` ×2 (630-631) | mirrored-walberla `8c19407a`; my-e4-ws: the commit that will contain the final deck (now `7cd0626`) | — |
| 25 | "Lab: hand-written split loop 10.83 MLUP/s ... against 1.40 for the plain scalar build: 7.7×" (751-753) | drop the ratio, or compare with the lab's scalar kernel | F11 |
| 26 | "Every build matches it cell by cell", "every check fails", "24 of 24 waLBerla tests pass", "0 vector instructions in the whole program" (760-771) | name the oracle domains (16³ ... 16×24×8, 101 steps); "each broken version fails at least one check"; "24 of 24 tests (x86, plain C++ kernels)"; "0 vector instructions in the executable" | F12 |

## Outside the deck

| where | change | finding |
|---|---|---|
| `docs/manual/reports/r03/chapters/04-root-cause.tex:97`, `docs/notes3/rvv-8x-speedup-progress-fable5.2.md:224-225` | "Scalar loads collapse at the same point" is wrong (gathers); replace with the E7 result | F19 |
| `misc/x60-lab/probes/mem.cpp` (and `streams_check.sh:60`) | build with `-fno-tree-vectorize -fno-tree-slp-vectorize`, or the `scalar=1` mode measures `vluxei64` gathers | F19 |
| `misc/x60-lab/probes/ops.cpp:65` | "fmadd.s tput" is a dependent chain: rename to "lat" or use 8 accumulators | F9 |
| `docs/manual/reports/r03/chapters/09-results.tex:290`, `figures/speedup-chart.tex:29`; `docs/presentation3/slides.tex:292` | the same "4× goal met" framing as slide 16 | F1 |
| `docs/presentation4/presentation4-progress-opus5.5.md:687-689` | "≤ 0.031 / 0.128 / 0.064" → 1600 B reaches 0.206 at R = 10 | F20 |
| mirrored-walberla `cmake/compileroptions/{GNU,Clang}.cmake`, mirrored-pystencil2 `codegen/target.py`, `pystencils_runtime/rvv.hpp` | check VLEN (`vlenb` = 32) before choosing zvl256b / RISCV_RVV; add a run-time assert | F10 |
| `scripts/presentation4/verify.sh` | one oracle case with odd extents (e.g. 13×7×5) to run the RVV remainder loops and the split's `rows < BY` tail | F12 |
| `scripts/presentation4/run.sh`, `all.sh` | interleave variants round-robin; record busy cores (not only load average) before each run; optionally a THP / heap layout pass | F6, F8 |

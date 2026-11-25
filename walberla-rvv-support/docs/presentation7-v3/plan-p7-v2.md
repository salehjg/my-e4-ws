# presentation7-v2: review fixes to slides.tex

## Context
The user reviewed `docs/presentation7-v2/build/slides.pdf` (52 frames) and listed problems. Some slides are too
dense, some terms are never defined (W/E, f_i′, ρ, u, wall pass, energy, sha256), the cache line is missing from
the stream slides, the prefetch slides are confusing, and the one-core plot labels overlap. Every open `\todo`
should be resolved and then removed. Goal: a deck an outsider can follow, with every hardware fact checked.

Frame numbers below are the ones printed in the footer. Files: `slides.tex`, `figures/*.tex` (all in
`docs/presentation7-v2/`). Writing rules (memory): natural, full English sentences; every term defined where it is
first used and in the glossary; numbers from `\nv{}` (`tables/numbers.tex`), never typed in.

## Facts settled during planning (cite them in the source comments)
- **Cache line, K1: 64 B.** Read on the board: sysfs `coherency_line_size` = 64 for L1I, L1D and L2;
  device tree `d-cache-block-size` = `riscv,cbom/cboz-block-size` = 64. That is 16 f32 or 8 f64 values.
  One RVV load is 8 f32 = half a line on the K1, and 4 f32 = a quarter of a line on the SG2044.
- **Cache line, SG2044: 64 B, not yet measured on the machine.** The source is the SG2042 device tree (same
  C920 family, `d-cache-block-size = <64>`). Add a `\todo` until the user runs this inside a peak.sbatch job:
  `cat /sys/devices/system/cpu/cpu0/cache/index*/coherency_line_size` (it only reads facts about its own job,
  which is allowed on the supervised machine). I give the user that command in my final message.
- **Zicbop:** neither ISA string lists `zicbop` (K1: `rv64imafdcv_zicbom_zicboz_…`; SG2044: recon round 1).
  The X60 executes the hints anyway (stream test: 176 → 90 cycles per line). The pystencils backend emits the same
  `ori x0, rs, 1|3` hint whatever the machine, but only in the two builds that ask for prefetch
  (`explicit_cse_pf`, `explicit_cse_aa_pf`, `--prefetch-distance=128`, `SweepgenLdcCPU/CMakeLists.txt`). On the
  SG2044 these builds ran: GCC f32 in place goes from `\nv{sg:gcc:f32:1:aa}` to `\nv{sg:gcc:f32:1:aapf}` with
  prefetch. **User's decision: state these facts. Do not say "not supported".**
- **Backends:** pystencils has one platform class per instruction-set family: `GenericCpu`, `X86VectorCpu`
  (SSE, AVX, AVX-512), `NeonCpu`, `SveCpu`, **`RvvCpu` (one class for VLEN 128 and 256; the width is a
  constructor parameter, `SUPPORTED_VLENS = (128, 256)`)**, plus CUDA, HIP and SYCL. There is no code specific to
  the X60 or the C920v2. Chip tuning goes only through options (prefetch distance, LMUL, split sizes).
- **Energy** (`SweepgenLdcCPU.cpp:281-307`): the sum over all cells of u_x² + u_y² + u_z², summed in double.
  **sha256**: a checksum of each benchmark executable. A timed executable must have the same checksum as one in
  the verification log.

## Changes, in deck order

1. **Overview slides on a light blue background.** In `\overviewframe`, wrap the frame in a group that sets
   `\setbeamercolor{background canvas}{bg=psblue!7}`.
2. **Frame 3** "Speed is measured in MLUP/s" → "Throughput is measured in MLUP/s: …".
3. **New frame in Background, after "Running on many cores": "What one time step does"** (new
   `figures/time-step.tex`). It shows a bar for one time step with three segments in the colours of the time plots
   (kernel violet, halo exchange aqua, wall pass yellow). Below it, a small 2D picture of cells next to a wall: a
   value heading into the wall comes back in the opposite direction (bounce-back), and at the moving lid it also
   picks up the lid's speed. Text: the kernel updates every cell; the halo exchange copies the border cells to the
   neighbouring blocks; the **wall pass** fixes the cells next to the walls. It is plain C++ in every build. This
   defines "wall pass" before frames 35 and 45 use it.
4. **Frame 10 todo (backends).** Add a new frame before it, "pystencils: one backend per instruction set" (new
   `figures/backends.tex`). The pystencils box branches to generic CPU, x86 (SSE, AVX, AVX-512 as targets),
   ARM (NEON, SVE), **RISC-V RVV (new): one backend, two targets, RISCV_RVV128 and RISCV_RVV256**, and GPU
   (CUDA, HIP, SYCL), with the others greyed. Text: the RVV backend is not copied per width or per chip. The width
   is a parameter, and nothing in it is specific to the X60 or the C920v2. Frame 10 keeps the `vlen-flow`
   diagram. Delete the todo.
5. **Frame 13 todos.** sha256: "The programs we time are the same executable files that passed this check: their
   sha256 checksums are equal." Energy: "Each run ends by printing one number for the whole flow, the energy: the
   sum of u_x² + u_y² + u_z² over all cells. All 11 builds print the same energy, up to rounding." Adjust the table
   header to match, and update the glossary (Energy, sha256). Delete both todos.
6. **Frame 16 (field-layout): what the numbers in the flat array are.** They are cell positions (0 to 26), not the
   values f_0…f_18. Add a header "the array of f_4: one value for each cell" above the cube. Rewrite the first
   bullet: "Each number is the position of a cell in this array. It is not one of the 19 values: each of those has
   an array like this." Label the strip "memory of the f_4 array".
7. **Frame 17 (kernel-code): simpler and concrete.** Replace the abstract `src[4][z][y][x-1]` with the flat index
   from frame 16, with real f32 strides: `f4 = f[(x-1) + 68*y + 4488*z + 4*296208]`, each with a short comment
   ("4 bytes to the left", "one row = 272 bytes back", "one plane back"). Cut the overlays from 9 to 5: loops,
   the loads, collide, the stores, then the vector version. Keep the stencil and array strips on the right.
8. **Frame 18 (stream-def) becomes two frames.**
   - **"Cache lines and streams"** (new `figures/cache-line.tex`): one array drawn cell by cell, with thick borders
     every 16 cells (64 B in f32) labelled "cache line 0, 1, 2 …". A table: cache line 64 B on both machines, which
     is 16 f32 or 8 f64 values; one vector load covers 8 f32 on the K1 and 4 on the SG2044. The loop marker moves
     over three overlays: the line being used, the lines the hardware prefetcher is already loading, and the lines
     already used. Definition: "A stream is a run of consecutive cache lines that the loop walks through in order."
   - **"Our loop walks through 42 arrays at once"** (the existing figure, cleaned up): a legend that defines every
     row label. f_0…f_18 are the 19 values of each cell before the step (read). f′_0…f′_18 are the 19 new values
     after the step, written into a second set of arrays. ρ is the density. u_x, u_y, u_z are the three parts of
     the flow velocity. ρ and u are written as outputs.
9. **Frame 19 (stream-count): show where the cache lines fall.** Redraw the one-array strip with real distances:
   the current row with 64-byte line borders (x−1, x, x+1 inside one line), then the rows y±1 (272 B away) and the
   planes z±1 (about 18 KB away) as separate pieces joined by "…" gaps, each piece in its own line. The message:
   accesses in the same or the next line form one stream, and accesses in lines far apart form separate streams.
   Note that x−1 or x+1 can fall into the neighbouring line, which comes next anyway. The bottom part: in our
   kernel the 19 values sit in arrays 1.2 MB apart, so every access is in a different line, which makes 19 streams.
10. **Frame 20 (AA): define W and E.** Name the slots after their arrays, `f_3` (moving west ←) and `f_4` (moving
    east →), with a legend line: "Each cell has 19 slots; two are shown, f_4 (moving east) and f_3 (moving west)."
    Add one sentence for each step. Even step: each new value goes into the slot of the opposite direction in the
    same cell, so nothing moves yet. Odd step: values are read from and written to the neighbours' slots, which
    completes the move.
11. **Frame 21 (split loop): explain it with code.** Two short code boxes side by side. Left, "one loop" (23
    arrays per cell: load 19, compute ρ and u, collide, store 19 + 4). Right, "split loop" (for each block of 2
    rows: 4 passes add up f in groups of 5 into a scratch array; 1 pass computes ρ and u; 3 passes reload 7, 6 and
    6 values, collide them and store them in place). One sentence on why this works for LBM: collide needs ρ and u,
    which depend on all 19 values, so they are computed first, in passes that each read only a few arrays. The
    block is small, so the reloads come from L1. Keep the takeaway (at most 7 arrays per pass). Remove the
    block-plane picture, and keep its numbers as one grey line.
12. **Frame 23 (K1 hardware).** Add "L1: 32 KB, 64-byte lines" to the figure. Add a bullet: "The X60 executes the
    RISC-V prefetch instructions (Zicbop), although its ISA string does not list them. We measured this (frame 27)."
13. **Frames 26–27 (prefetch): say clearly that prefetch is added, not swapped in.** Frame 26 gets a before/after
    code pair: the same loop without and with prefetch. The `vle32` load stays, and one `prefetch_read` per stream
    is added 32 floats (128 B, two lines) ahead. Add a small strip of the array with two arrows: "load now: x" and
    "prefetch: x + 32", and a two-row timeline. Without prefetch the load misses and the core waits about 360
    cycles. With prefetch the line arrives while the core computes, and the load finds it in the cache. Sentence:
    "A prefetch loads nothing into a register and returns nothing. It only asks the cache to fetch a line early."
    Frame 27: the same point in its bullets (x0 as destination: no result), and keep the encoding.
14. **Frames 29/30 and 39/40 (`\onecorefig`): x labels.** Use full names, rotated about 45°: plain scalar, plain
    auto-vectorized, best scalar, best auto-vectorized, RVV, RVV with prefetch, RVV in place, RVV in place with
    prefetch, **RVV split loop**. Replace "+" with "with", and adjust the plot height so nothing is cut. Add a grey
    line: "Each bar is a separate build. 'with prefetch' means the build on its left with software prefetch added."
    Add to frames 29 and 30: `\todo{The auto-vectorized builds are as fast as the scalar ones: check why (do the
    plain kernels contain any vector instructions? see the objdump counts).}`
15. **Titles and text: "throughput" for MLUP/s.** "speed of each build" → "throughput of each build" (29, 39),
    "total speed" → "total throughput" (33, 42), "speed per core" → "throughput per core" (43). In takeaways, "the
    memory sets the speed" → "memory bandwidth limits the throughput". Keep "speedup" only for ratios.
16. **Frames 34/44 ("what RVV still gains"): clear message.** New title: "K1, several cores: the RVV advantage
    shrinks". One plain sentence above the plot: "Each bar shows how many times faster the RVV split loop is than
    the best scalar build, with the same compiler and number of cores. 1 means no gain." Takeaway: the gain falls
    from `\nv{…1:split/best}` to `\nv{…8:split/best}` because all cores share one memory: the split build already
    moves 4.2–4.6 GB/s, close to the about 6 GB/s the test loop reaches. Keep the traffic numbers in the grey line.
    Do the same for frame 44 (SG2044).
17. **Frames 35/45 (time shares).** Refer to the new time-step frame ("the three parts from frame N"), with the
    wall pass already defined. Fix the overlapping "8" label in the f32 best-scalar bar if it still overlaps.
18. **SG2044 hardware (frame 37).** Add "64-byte lines" to the figure (with the cache-line `\todo` from the facts
    section). Add a bullet: "Its ISA string does not list Zicbop (the K1's does not either). The prefetch builds
    contain the same hint on both machines. We have not tested directly whether the C920v2 acts on it, but on one
    core the in-place build gets faster with it (`\nv{sg:gcc:f32:1:aa}` → `\nv{sg:gcc:f32:1:aapf}` MLUP/s, GCC
    f32)." Make frame 41's wording and the open-question bullet agree with this.
19. **Frame 52 todo (commit).** User's decision: keep a `\todo`, reworded as "fill in the my-e4-ws commit that
    contains docs/presentation7-v2 once it is committed". The user commits; I never commit.
20. **Glossary:** add Cache line (64 B, 16 f32 / 8 f64, both machines), Energy, Throughput, f_i / f′_i, Density
    ρ, Velocity u. Update Stream ("consecutive cache lines") and Wall pass. Then do a light writing pass over the
    whole deck for clipped phrases.

## Verification
- `./build.sh` must build with no LaTeX errors. Check the `Overfull` lines it prints, and fix every new one.
- `./build.sh png`, then look at every changed frame (overlays included): no overlap, no clipped labels, rotated
  x labels readable, overview frames light blue.
- `./build.sh todos` should list only the intended todos: autovec (29, 30), SG2044 cache line, and commit (52).
  The three original todos for frames 10 and 13 are gone.
- Check that every new number is either a `\nv{}` key or a hardware fact cited in a source comment (cache line,
  strides 68/4488/296208, 128 B distance).
- Log the changes in `presentation7-progress-opus5.5.md` (new section "Review 2026-11-23"), and copy this plan
  next to it as `presentation7-v2-review-plan-opus5.5.md`. No commits.

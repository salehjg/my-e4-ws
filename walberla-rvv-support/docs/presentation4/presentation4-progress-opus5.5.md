# presentation4: progress log

The running record for `presentation4-plan-opus5.5.md`. Every claim names the command or log behind it.
Newest entries at the bottom.

## Status

| stage | content | state |
|---|---|---|
| 0 | plan and progress files, clone of presentation3, ignore and push rules | done |
| 1 | app `SweepgenLdcCPU`, local x86 build, verification chain on x86 | done (all checks pass; `_pf` variants are RVV-only, checked in stage 2) |
| 2 | board: f64 trees (GCC, Clang, vector and scalar), build audit, f64 verification | done: GCC and Clang f64 built, audited, verified; GCC = Clang bit-identical for the RVV builds |
| 3 | board: f32 trees and f32 verification | done: GCC and Clang f32 built, audited, verified (`prepare-f32.log`: `PREPARE PASS`, 0 failures); GCC = Clang bit-identical for the RVV builds |
| 4 | board: full matrix, 1/4/8 cores, timing-stability check | `all.sh` done (0 unverified, no failure); `extras.sh` done (correctness passes, timing disturbed by the board); `recheck.sh` done (warm-up and vector-tree questions settled, interleaved); `streams_check.sh` done (stream plot); `speedup_check.sh` done (headline speedups, second session) |
| 5 | logs copied to `board-logs/`, summary tables | all logs copied (sha256 equal); entries written |
| 6 | slides | result plots split (speedup per precision, MLUP/s separate); stream slides rebuilt on new counters; new slides: stream definition, stream-test code, prefetch pass, film; split-loop label fixed; 25 pages; open `\todo`: only the 2 commit hashes |
| 7 | final audit (nothing committed) | not started |

## Resume here (handover, written 2026-11-17 at board time Mon Nov 16 05:04, updated 2026-11-18 at board time 18:30)

This section is enough to continue in a fresh session. The entries below it are the detailed evidence. The plan is
`docs/presentation4/presentation4-plan-opus5.5.md` (authoritative, with its "Amendments" section at the end); the
original plan-mode copy is `~/.claude/plans/read-submodules-walberla-and-see-jiggly-platypus.md` (outdated, do not use).
All paths below are relative to the superproject `/workspace/02_ws/my-e4-ws/walberla-rvv-support` unless absolute.

### Rules from the user (do not break)

- Nothing in `docs/presentation3/` or `scripts/presentation3/` (or `scripts/common/`) changes. Everything new is named
  presentation4.
- Never `git commit` or `git push` unless the user asks in that request. The user commits.
- Correct results come first: every variant verified, nothing assumed, every claim with its log. Ask the user if unsure.
- Board (`ssh bananapi`) is shared: write only under `/home/bananapi/saleh/`; caches under `/home/bananapi/saleh/.cache`
  (`run.sh` sets `XDG_CACHE_HOME`). Every board job runs detached in `screen`, with a log.
- All builds `-O3`, waLBerla's default flags per compiler; scalar executables must contain 0 vector instructions.
- Slide style (as presentation3): simple English, no em/en dashes, every term defined (glossary), little text,
  about 3 bullets per slide at most.

### Where everything is

| what | where |
|---|---|
| new waLBerla app (fork, uncommitted) | `submodules/walberla/apps/benchmarks/SweepgenLdcCPU/{CMakeLists.txt,SweepgenLdcCPU.py,ldc_boundaries.py,SweepgenLdcCPU.cpp,README.md}`; plus 1 line `add_subdirectory( SweepgenLdcCPU )` in `submodules/walberla/apps/benchmarks/CMakeLists.txt` |
| scripts | `scripts/presentation4/`: `prepare.sh`, `run.sh`, `{scalar,autovec,rvv}.sh`, `all.sh`, `extras.sh`, `recheck.sh`, `verify.sh`, `ldc_reference.py`, `compare_fields.py`, `check_build.py`, `check_walls.py`, `summary.py`, `slide_numbers.py` (all slide numbers from the `ldc-*.log`: MLUP/s, speedups, gains, Clang/GCC, core scaling; tested on synthetic logs), `streams_check.sh`, `streams_table.py`, `speedup_check.sh`, `speedup_table.py`, `check_figures.py`, `build_x86.sh`, `cavity_movie.py`; guide `scripts/presentation4/README.md`; row in `scripts/README.md` |
| deck | `docs/presentation4/slides.tex`, `figures/*.tex` (new: `figures/cavity.tex`), `build.sh` (`./build.sh`, `./build.sh png`, `./build.sh todos`, `./build.sh final`) |
| raw logs (tracked; `.gitignore` last rule `!/board-logs/**`) | `docs/presentation4/board-logs/x86/` (stage 1), `docs/presentation4/board-logs/board/` (board) |
| local x86 build (ignored, `/build/`) | `build/presentation4-x86/{gcc,clang}-{f64,f32}` (Ninja), recipe `build/presentation4-x86/build-trees.sh`, sfg at `build/presentation4-x86/sfg`, Python `/workspace/02_ws/my-e4-ws/.venv-rvv/bin/python`, `PYTHONPATH=$B/sfg:submodules/pystencils/src:submodules/walberla/sweepgen/src` |
| board repo copy | `/home/bananapi/saleh/my-e4-ws` (synced by `bash push.to.sh bananapi`, see pitfalls) |
| board venv | `/home/bananapi/saleh/venv` (numpy 1.26.4, sympy 1.14.0, lbmpy 2.1.1, pystencilssfg 0.1.1) |
| board build trees (Makefiles) | `/home/bananapi/saleh/presentation4/build-{gcc,clang}-{f64,f32}[-scalar]`; configure logs `…/build-*.configure.log`, per-target build logs `…/build-*/build-SweepgenLdcCPU_*.log` |
| board logs | `/home/bananapi/saleh/presentation4/logs/` (`prepare-<prec>.log`, `build-/check-/verify-<cc>-<prec>.log`, `verify-<cc>-<prec>-results.log`, `compilers-<prec>.log`, later `all.log`, `ldc-*.log`, `extras*.log`) |
| board verify dumps | `/home/bananapi/saleh/presentation4/verify/<cc>-<prec>/{oracle-np*-c*-s*,decomp}/` |
| presentation3 build dirs on the board (do not touch) | `/home/bananapi/saleh/walberla-build*` |

### State at handover

- **Stages 2 and 3 passed** (board time Mon Nov 16): `prepare-f64.log` ended 06:05 with exactly the 1 expected
  failure (first GCC audit, sqlite3.c, superseded by `check-gcc-f64-rerun.log`); `prepare-f32.log` ended 09:38 with
  `PREPARE PASS`, 0 failures. All 44 executables (2 compilers × 2 precisions × 11 variants) are built, audited and
  verified; their sha256 are in `verify-<cc>-<prec>.log`. All prepare logs are in `docs/presentation4/board-logs/board/`.
- **Stage 4 timing done**: `all.sh` ran 09:42:10-14:22:33 board time; `all.log` and the 36 `ldc-*.log` are in
  `docs/presentation4/board-logs/board/`; results in the entry "stage 4 finished (`all.sh`), stage 5 results".
- **`extras.sh` done** (14:25:51-17:20:52 board time; logs copied; entry "`extras.sh` finished (method checks);
  interleaved recheck started"): correctness passes everywhere; its timings are disturbed by the board (same
  executables up to 10 % slower than in `all.sh` after its first session, wall time too), so its warm-up and
  vector-tree comparisons are inconclusive.
- **`recheck.sh` done** (18:20-19:07), **`streams_check.sh` done** (19:07-19:11); logs copied; see the entry
  "recheck results; plots split; stream plot checked; split-loop label fixed; new slides; film".
- **`speedup_check.sh` done** (19:11-19:28): entry "headline speedups in a second session". No board job is running.
- Background watchers of a session do not survive it (they run on the laptop and only read logs). The board job does:
  `screen -dmS`, parent PID 1, and logind's `KillUserProcesses` is false (checked). Check by hand:
  - still running, and where: `ssh bananapi 'screen -ls; tail -3 /home/bananapi/saleh/presentation4/logs/speedup.log'`
  - finished when `speedup.log` ends with `== SPEEDUP DONE`.
- Board inputs were checked byte-identical to the laptop (app, SweepgenLbmCPU, pystencils `src`, sweepgen `src`,
  waLBerla `include`). Since then only `scripts/presentation4/` was synced (narrow rsync, below). No source file was
  changed locally after the push.
- Local uncommitted changes (expected, nothing else may appear): superproject `M .gitignore`,
  `M docs/presentation4/{.gitignore,presentation4-plan-opus5.5.md,presentation4-progress-opus5.5.md,slides.tex}`,
  `M push.to.sh`, `M scripts/README.md`, `m submodules/walberla`, `?? docs/presentation4/board-logs/`,
  `?? docs/presentation4/figures/cavity.tex`, `?? scripts/presentation4/`; fork `M apps/benchmarks/CMakeLists.txt`,
  `?? apps/benchmarks/SweepgenLdcCPU/`; pystencils fork clean.

### Pitfalls found so far (each one cost time)

- **Clock skew and mtimes.** The board clock is about 46 h behind the laptop. `push.to.sh` (rsync `-az`, no checksum)
  re-sends every file whose mtime differs, and `run.sh` touches files "in the future" to now
  (`find … -newermt now -exec touch`). So after a full push, the next build in a tree recompiles everything, and the
  executables change (new sha256, no longer the verified ones). Therefore:
  - do **not** run `push.to.sh` between `prepare.sh` and `all.sh`/`extras.sh`;
  - to update only scripts: `rsync -az --exclude '__pycache__' scripts/presentation4/ bananapi:/home/bananapi/saleh/my-e4-ws/scripts/presentation4/`
    (rsync replaces files by rename, so a running bash keeps its old copy; a script started later reads the new one);
  - if a source fix is ever needed: full push, then `prepare.sh` again for every affected tree (it regenerates and
    re-verifies); `all.sh` refuses unverified binaries anyway.
- `cp -a` keeps old mtimes, so a restore is not rebuilt: `touch` after restoring (mutation-test harness error, stage 1).
- zsh (the laptop shell) does not split `$var` into words: use `${=var}` in zsh one-liners.
- `ldc_reference.py` must not run under `python -I` (it needs `PYTHONPATH` for lbmpy).
- GNU objdump 2.42 cannot decode Clang's RVV code: use `llvm-objdump` (the scripts do).
- Board RAM is 3.7 GB, no swap: build with `-j2` (`JOBS=2` in `run.sh`). Measured (`board-logs/board/rss-sample.log`):
  one `clang++` process reaches 1248 MB (GCC's `cc1plus` 751 MB), so `-j3` with Clang could need about 3.7 GB: keep 2.
- Board load average is 2.00 when idle (kernel threads `vq0`/`vq1` in D state since boot): not CPU use.
- The `_pf` variants cannot be generated on x86 (pystencils `MaterializationError`); they are checked on the board only.
- waLBerla's `GNU.cmake:28` puts `-march` into C++ flags only: GCC's C files (sqlite3) have no `-march`; not linked
  into the app (handled in `check_build.py`).

### Remaining work, in order, with gates

1. **DONE: stage 2, Clang f64** (see the entry "stage 2, Clang f64 on the board; stage 2 complete"; kept for the method) (`prepare-f64.log`, `build-clang-f64.log`, `check-clang-f64.log`, `verify-clang-f64.log`,
   `compilers-f64.log`).
   - If a Clang build fails (`BUILD FAILED` in `build-clang-f64.log`; per-target log in
     `/home/bananapi/saleh/presentation4/build-clang-f64[-scalar]/build-SweepgenLdcCPU_<v>.log`): this is the first
     Clang build of the AA/prefetch/split code; the plan names possible causes (alias CTAD, the `in_register` asm with
     `"+f"` in `pystencils_runtime/rvv.hpp`). Read the error, fix at the root, tell the user. A fix in a shared fork
     file (v8 headers, pystencils runtime) needs the plan's regression checks: presentation3's GCC f64 1-core
     `SweepgenLbmCPU_explicit_cse_aa_pf` energy equal to `docs/notes3/board-logs/presentation3/walberla-rvv-f64-1core.log`,
     the x86 ctest set (`ctest -R "LbmScenarios|HaloExchange|CommunicationHiding"`, 24/24), and, if pystencils
     changed, `bash test.on.bananapi.sh` plus x86 `tests/nbackend tests/codegen`. Then full push and `prepare.sh` again
     for all trees (sources changed).
   - Gate: Clang `CHECK_BUILD PASS` twice (expect `-mtune=spacemit-x60` on every command, because Clang accepts it,
     and C files with `-march` too, `Clang.cmake:31-32`), `CHECK_WALLS PASS`, `VERIFY PASS` for 11/11, and
     `compilers-f64.log`: 4 × `PASS compilers` (tolerance 2e-12).
   - Then copy: `scp bananapi:/home/bananapi/saleh/presentation4/logs/{prepare-f64,build-clang-f64,check-clang-f64,verify-clang-f64,verify-clang-f64-results,compilers-f64}.log docs/presentation4/board-logs/board/`
     and write a "stage 2, Clang f64" entry here (RVV counts, prefetch hint counts, autovec kernels, bit-identical
     pairs, worst errors, sha256 reference to the log).
   - Prefetch-hint count used for GCC (repeat for Clang; Clang may print `prefetch.r`/`ori zero`):
     `llvm-objdump -d --no-show-raw-insn <exe> | grep -c -E "prefetch\.(r|w)|ori[[:space:]]+zero"`.
2. **DONE: stage 3, f32** (see the entries "stage 3, GCC f32 on the board" and "stage 3, Clang f32 on the board; stage 3 complete") (`prepare-f32.log` and the `*-f32` logs; runs by itself after f64). Gate: `PREPARE PASS` (now
   strict). The f32 thresholds are calibrated inside `verify.sh` (max(2× scalar error, 4 eps = 4.77e-7)); the
   GCC-against-Clang f32 comparison is calibrated on the Clang scalar build. Copy the logs, write the entry.
3. **Stage 4**: all board jobs DONE (`all.sh`, `extras.sh`, `recheck.sh`, `streams_check.sh`, `speedup_check.sh`).
4. **Stage 5**: all logs copied (sha256 equal), entries written.
5. **Stage 6, slides**: 25 pages, builds with only the inherited 2.7 pt title warning; open `\todo`: the 2 commit
   hashes. Open questions to the user (asked in the report): bold the split loop or "in place + prefetch" as the
   best build; whether the stream-test and prefetch-pass
   slides stay in the main part or go to the backup. Not changed, outside presentation4: presentation3's slides
   carry the same wrong split label, and `SweepgenLbmCPU/lbm_split.py`'s docstring says the X60 "follows about 8
   streams" (the counters say about 20 for L2, about 8 for L1).
6. **Stage 7, final audit**: `git status` in the superproject and both forks shows only the files listed above;
   `git diff --stat -- docs/presentation3 scripts/presentation3 scripts/common` and, in the fork,
   `git status -- apps/benchmarks/SweepgenLbmCPU sweepgen include src` are empty; `git check-ignore -v` on the new
   paths; the plan's status line updated; nothing committed. Update the memory note
   `~/.claude/projects/-workspace-02-ws-my-e4-ws/memory/presentation4.md`.

## 2026-11-17: planning (read-only investigation)

Nothing was changed in the repository, the submodules or on the board during planning.

**LDC codes in waLBerla, and why none of them can use the RVV backend**
- `apps/benchmarks/UniformGridCPU`: LDC scenario `ldc_setup` in `simulation_setup/benchmark_configs.py:37`.
  The N face is UBB, and W/E/S/B/T are NoSlip, all at walldistance −1. The lid velocity
  `UBB([0.05, 0, 0])` is at `UniformGridCPU.py:156`; the Scenario default is omega 1.8.
- Generators: `python/pystencils_walberla/*.py` import `pystencils.astnodes`, `pystencils.backends.cbackend`
  and `pystencils.typing`. Checked with `ls submodules/pystencils/src/pystencils`: there is no `astnodes.py`,
  no `backends/` and no `typing/` package, only `typing.py`.
- `tests/lbm_generated/LDC.cpp` uses `src/lbm_generated/sweep_collection/D3Q19SRT.h`. That file was
  pre-generated with pystencils 1.x (`sweep_collection_generation_script.py`).
- `apps/tutorials/lbm/03_LBLidDrivenCavity.cpp` uses the hand-written `lbm::D3Q19<SRT>`, `NoSlip` and `SimpleUBB`.

**The sweepgen route**
- `sweepgen/src/sweepgen/boundaries/sparse.py:215-262` (`SparseBoundary._get_kernel_assignments`):
  `streaming_pattern = "pull"` is hardcoded at line 222, with `prev_timestep = Timestep.BOTH`.
- `sweepgen/src/sweepgen/boundaries/grid_aligned.py`: only NoSlip and FreeSlip, pull indexing, no UBB.
- lbmpy 2.1.1 `advanced_streaming/indexing.py:38-41`: `BetweenTimestepsIndexing` accepts the in-place
  patterns with `prev_timestep` EVEN or ODD.
- `include/walberla/sweepgen/boundaries/GenericBoundary.hpp`: `fromLinks(pred)` visits every interior cell and
  direction, and the predicate sees `wallCell` in block-local coordinates.
- `apps/examples/FlowAroundSphere/FlowAroundSphereExample.cpp`: transforms `wallCell` to global coordinates and
  compares it with `getDomainCellBB()`. Order: stream-collide, then halo exchange, then the boundary sweeps.
- lbmpy UBB, compressible (`boundaries/boundaryconditions.py:881-905`):
  `f_in(inv d) = f_out(d) − (2/c_s²)·(c_d·u_w)·w_d·rho`, where rho is computed from all `f_out(i)` of the fluid cell.
- `geometry/initializer/BoundaryFromDomainBorder.impl.h:96-126`: walldistance −1 marks the ghost layer,
  including edges and corners, and flags are added (`addFlag`), so the classic setup gives edge cells two flags.

**Board state (`ssh bananapi`, read-only)**
- No screen sessions are running.
- `/home` has 3.1 GB free (90 % used). The existing build dirs are 108-169 MB each.
- Compilers: GCC 14.2.0 (Bianbu), Clang 18.1.8 (Bianbu), cmake 3.28.3.
- `/proc/cpuinfo`: `isa ... _zve64d ...`, `uarch : spacemit,x60`.
- Board venv with the repo's pystencils and sweepgen on PYTHONPATH: numpy 1.26.4, sympy 1.14.0, lbmpy 2.1.1, pystencilssfg 0.1.1.
- `walberla-build` and `walberla-build-gcc-f32` have `WALBERLA_CXX_SUPPORTS_RISCV_HOST_TUNE` empty, so GCC gets no
  `-mtune`. Their CXX_FLAGS include `-march=rv64gcv_zvl256b ... -O3 -DNDEBUG`.
- `walberla-build-clang-{f32,f64}`: there is no flags.make for `SweepgenLbmCPU_explicit_cse_aa_pf`, so Clang never
  built the AA targets. The last Clang runs are `docs/notes3/board-logs/e2e-clang-f{32,64}.log` (pull variants only).

**"Really scalar" check**
- Command: `llvm-objdump -d --no-show-raw-insn walberla-build/apps/benchmarks/SweepgenLbmCPU/SweepgenLbmCPU_scalar_cse_aa`.
- Result: **5,795** RVV instructions. All of them are in waLBerla library functions (`BlockForest::BlockForest`,
  `mpi::writeBufferSerialIO`, `logging::Logging::*`, `SetupBlockForest::init`, ...).
- The same count for `libc.so.6`, `libstdc++.so.6`, `libm.so.6`, `libmpi.so.40` and `libopen-pal.so.40` gives 0 each.
- Compiler defaults: `gcc -Q --help=target` reports `-march=rv64imafdc_zicsr_zifencei`. `clang -dM -E` defines no `__riscv_v`.
- Consequence for the plan: separate scalar build trees, with every file built with `-march=rv64gc -O3`.

**User decisions**
- All 11 variants, including AA and split.
- 1, 4 and 8 cores.
- Compressible SRT, with u_lid 0.05 and omega 1.8.
- waLBerla's default flags for each compiler.
- Everything at -O3.
- The scalar baselines must contain no vector code anywhere.

## 2026-11-17: stage 0 (docs, clone, ignore and push rules)

- `docs/presentation3/{slides.tex,build.sh,.gitignore,figures/}` copied to `docs/presentation4/`; `diff -r` showed
  no difference. `./build.sh` built the unmodified clone: 1 warning (an Overfull hbox of 2.7 pt at
  lines 93-174, the same as presentation3), 0 `\todo`. The user committed the clone and the plan as `6a23e0e`.
- `docs/presentation4/.gitignore`: header changed, plus `!/board-logs/**` as its **last** rule. Placed earlier, the
  later rules (`*.out`, ...) would re-ignore some log files. `git status --porcelain --ignored` with test files
  `board-logs/x.{log,out,txt}`: all three listed as untracked, not ignored; `build/` is ignored.
- `walberla-rvv-support/.gitignore`: `/build/` (local builds). `push.to.sh`: `--exclude '/build/'`. An rsync dry run
  still lists `docs/presentation3/build/` (the anchored pattern only matches the top-level `build/`).

## 2026-11-17: stage 1 (the app, on x86)

**Files** (walberla fork, uncommitted):
- `apps/benchmarks/SweepgenLdcCPU/{CMakeLists.txt,SweepgenLdcCPU.py,ldc_boundaries.py,SweepgenLdcCPU.cpp,README.md}` (new).
- `apps/benchmarks/CMakeLists.txt`: one line, `add_subdirectory( SweepgenLdcCPU )` inside the existing sweepgen guard.
- Nothing else in the fork changed. sweepgen, v8, pystencils and `SweepgenLbmCPU` are untouched.

**Facts read in the generated code** (standalone generation into the scratchpad, then the build trees):
- lbmpy stores **zero-centred** PDFs: the UBB kernel computes `rho = 1.0 + delta_rho`, and
  `create_lb_method(...).get_equilibrium_terms()` is 0 at rest. The UBB update has the same form in this storage,
  because w_inv(d) = w_d. The oracle uses the same storage.
- Pull walls: link (x, d) writes slot inv(d) of the wall cell x + c_d. AA after an even step: slot d of x + c_d.
  AA after an odd step: slot inv(d) of x.
- The generated pragmas are only `#pragma once` and `#pragma GCC diagnostic push/ignored "-Wunused-variable"/pop`.
- `memory::Field` initializes every value, ghost layers included (`include/walberla/v8/memory/Field.hpp:158-168`).
- `run()` of the classic boundary collection calls the boundaries in list order
  (`python/lbmpy_walberla/templates/BoundaryCollection.tmpl.h:57-61`); `UniformGridCPU.py` lists `[no_slip, ubb]`.
  So in UniformGridCPU, UBB wins at lid edges and corners that carry both flags, which matches our lid predicate.

**Local x86 build:** `build/presentation4-x86/` (GCC 16.2.1, Clang 23.1.5, Open MPI 5.0.11, AVX for the explicit
variants). The 2 `_pf` variants cannot be generated on x86: `MaterializationError: Software prefetching
(cpu.vectorize.prefetch_distance) is not supported on platform X86VectorCpu` (pystencils `generic_cpu.py:188`).
So x86 covers 9 of the 11 variants; the `_pf` ones are checked on the board.

**Finding: the variants are not bit-identical.** Plan criterion 2 assumed they would be, because presentation3
reported "identical f64 checksums". That was 12 printed digits of the energy, not bit identity. Measured with the new
`fieldhash` (16³, 100 steps, GCC f64):
- scalar and autovec are bit-identical, and so are scalar_cse and autovec_cse (GCC does not vectorize these kernels on x86).
- Every other pair differs: no CSE vs CSE, pull vs AA, scalar vs explicit AVX.
- All energies agree to ≤ 5.8e-16 relative, and the mass is identical.

Criterion 2 is therefore replaced by the oracle criterion applied to every variant, together with criterion 3
(decomposition, bit-identical), which holds; see the amendment in the plan.

**Verification chain on x86** (logs: `board-logs/x86/`):

| check | GCC f64 | GCC f32 | Clang f64 | Clang f32 |
|---|---|---|---|---|
| oracle, 4 cases (16³ ×100, 16³ ×101, 2×16³ = 32×16×16 ×101, 6×8³ = 16×24×8 ×101) | PASS | PASS | PASS | PASS |
| link counts = oracle's (e.g. 16³: 6208 NoSlip, 1280 lid = 5·16·16) | PASS | PASS | PASS | PASS |
| decomposition 1×32³ vs 8×16³, 61 steps: bit-identical (same `fieldhash`, 32768/32768 cells) | 9/9 PASS | 9/9 PASS | 9/9 PASS | 9/9 PASS |

- f64 against the oracle, worst case over all variants and cases: max|Δrho| = 2.22e-16 (1 ulp of 1.0), max|Δu| = 5.55e-17.
  Mass error 0 (summed by NumPy), z-mirror asymmetry 2.22e-16, no subnormal values.
- f32 against the f64 oracle (GCC, 16×24×8 case): scalar |Δrho| 6.92e-8, |Δu| 4.35e-8. All variants are at most
  7.73e-8 and 4.86e-8, i.e. within 1.12× of the scalar build.
  - The thresholds became the floor of 4 f32 epsilons (4.77e-7), not "2× scalar". The scalar errors are below the
    floor, and variants of the same accuracy scatter by more than 2× at the 1e-10 level of the mass error
    (5.6e-10 against 2.1e-10).
  - The floor still leaves the check orders of magnitude below the errors of the mutation tests below (≥ 1e-2).
- `files: board-logs/x86/verify-{gcc,clang}-{f64,f32}.log` (thresholds, all per-variant numbers, sha256 of each binary),
  `verify-*-results.log` (every result line).

**Mutation tests** (GCC f64, x86): each a temporary edit, then rebuild, `verify.sh`, and a restore checked with
`diff -r` against a backup (logs `board-logs/x86/mutation-*.log`):

| mutation | target | caught by | first error |
|---|---|---|---|
| M1 lid edges and corners → NoSlip (link assertion removed) | scalar | links + oracle, all 4 cases | |Δrho| 1.0e-2, mass 1.4e-4 |
| M2 odd-step walls built with even-step indexing | scalar_cse_aa | oracle, all 4 cases | |Δu| 2.6e-1 |
| M3 no wall sweeps after odd steps | scalar_cse_aa | oracle, all 4 cases | (same fields as M2) |
| M4 no aaPushSync | scalar_cse_aa | oracle np=2, np=6; decomposition. np=1 passes, as it must (a single closed block has no neighbour) | |
| M5 pull without halo exchange | scalar_cse | oracle np=2, np=6; decomposition. np=1 passes | |
| M6 lid velocity sign flipped | scalar | oracle, all 4 cases | |

- Harness error, found and fixed: `cp -a` restored the backup with its old mtimes, so ninja did not rebuild.
  The M3 and M4 binaries of the first round still contained M2's generated code. The tell: M4 at np=1 gave M2's hash.
  - With `touch` after the restore, M3 and M4 were redone. M3 gives the same fields as M2 (even-step indexing after
    an odd step writes wall slots that the next even step never reads). M4 behaves as predicted.
  - All 9 targets were then regenerated (`_gen` deleted) and rebuilt from the restored sources, and `verify.sh` passed
    again with the same hashes as before the mutations.
- Existing tests: `ctest -R "LbmScenarios|HaloExchange|CommunicationHiding"` in the GCC f64 tree: 24 of 24 passed
  (`board-logs/x86/ctest-gcc-f64.log`).
- `check_walls.py`: the wall kernels are byte-identical across all variants (pull: 5 files, AA: 4 files).
- `check_build.py` on x86: `-O3` is the last `-O` in all 501 compile commands; no code-changing pragma.

**Board state before stage 2:**
- Load average 2.00 while idle. It comes from the kernel threads `vq0`/`vq1`, in D state since boot (287 days),
  and is not CPU use: over 2 s, user time stayed constant and idle time grew by 1603 jiffies, i.e. 8 cores × 2 s.
- presentation3's runs started at load 3.09 (`walberla-rvv-f64-1core.log`).

## 2026-11-17: stage 2, GCC f64 on the board

`prepare.sh f64` in screen `presentation4-prepare`, started Mon Nov 16 02:33 board time. The board's clock is
about 46 h behind the laptop's (board `Mon Nov 16 04:26 CST` while the laptop showed `Tue Nov 17 19:48 CET`), so
board-log times are board times. Before the run, the board's copies of the app, `SweepgenLbmCPU`, pystencils `src`,
sweepgen `src` and the waLBerla headers were checked to be byte-identical to the laptop's (sha256 of every file).

**Build** (`board-logs/board/build-gcc-f64.log`, GCC 14.2.0): all 11 targets built.
- Compile line of the generated sweeps: scalar tree `-march=rv64gcv_zvl256b -O3 -march=rv64gc -std=c++20 -march=rv64gc`
  (the last `-march` counts), vector tree `-march=rv64gcv_zvl256b -O3 -std=c++20`. No `-mtune` (GCC 14 rejects
  `-mtune=spacemit-x60`, see the plan).
- RVV instructions (llvm-objdump), whole executable / generated sweeps object:

| target | executable | generated sweeps |
|---|---|---|
| scalar, scalar_cse, scalar_cse_aa | 0 | 0 |
| autovec, autovec_cse | 7471 | 276 |
| autovec_cse_aa | 7966 | 287 |
| explicit_cse, explicit_cse_pf | 8097 | 902 |
| explicit_cse_aa, explicit_cse_aa_pf | 9060 | 1381 |
| explicit_cse_aa_split | 9871 | 2245 |

- Prefetch hints (`ori zero, rs, imm`, i.e. Zicbop `prefetch.r/w`, `rvv.hpp:144-160`), counted in the executables:
  explicit_cse_pf 103, explicit_cse_aa_pf 107; explicit_cse, explicit_cse_aa, explicit_cse_aa_split 0. So `_pf` and
  its partner differ in the prefetch hints only, as intended; `_split` has no prefetch in presentation3 either
  (`SweepgenLbmCPU/CMakeLists.txt:63-64`).
- **GCC auto-vectorizes only the wall kernels.** In the autovec executables, the RVV instructions inside generated
  kernel functions are 15 in `UBB` and 9 in `NoSlip` (AA: the same in each of the even and odd ones); the
  stream/collide kernels have none. This is why scalar and autovec give bit-identical fields (below).

**Build audit** (`board-logs/board/check-gcc-f64.log`, then `check-gcc-f64-rerun.log`):
- First run: `CHECK_BUILD FAIL` in the vector tree for one command: `extern/sqlite3/.../sqlite3.c.o` has no `-march`.
  Cause, read in waLBerla: `cmake/compileroptions/GNU.cmake:28` adds `-march` to `CMAKE_CXX_FLAGS` only
  (`Clang.cmake:31-32` adds it to C and C++), so GCC compiles C files with its default (no V). sqlite3 is not linked
  into any SweepgenLdcCPU executable: their `link.txt` lists only `libwalberla_{field,vtk,blockforest,
  domain_decomposition,core}.a` and MPI, and `nm` finds no sqlite3 symbol.
  The 12 `-march=rv64gc` commands in the vector tree are the scalar targets of SweepgenLbmCPU and SweepgenLdcCPU
  (configured there, not built), and were already accepted.
- Fix in `check_build.py`: with GCC in a vector tree, C files are expected without `-march`, and their library must not
  be linked into any audited target (checked in `link.txt`). Rerun: `CHECK_BUILD PASS` for both trees, `CHECK_WALLS PASS`.
  - scalar tree: `-O3` last in 242/242 commands, last `-march` = `rv64gc` in 242/242, 0 RVV instructions in each whole
    scalar executable.
  - vector tree: `-O3` last in 242/242; `-march=rv64gcv_zvl256b` in 229, `rv64gc` in the 12 scalar-target commands,
    none in sqlite3.c.
- Also hardened, so that a crashed check cannot pass: `prepare.sh` now requires two `CHECK_BUILD PASS`, one
  `CHECK_WALLS PASS` and one `PASS compilers` per oracle case, instead of only the absence of `FAIL`. The running
  `prepare.sh f64` still uses the old file (bash keeps the inode that rsync replaced), so its last line will say
  `PREPARE FAIL` for this one audit; `prepare.sh f32` reads the new file.
- Only `scripts/presentation4/` was synced to the board for this (`rsync` of that directory). A full `push.to.sh` would
  re-send every source file with laptop mtimes, and the next build would then recompile verified binaries.

**Verification** (`board-logs/board/verify-gcc-f64.log`): `VERIFY PASS`, all 11 executables, `_pf` included (first
check of the `_pf` variants: x86 cannot generate them).
- Oracle, 4 cases (16³ ×100, 16³ ×101, 32×16×16 on 2 processes ×101, 16×24×8 on 6 processes ×101): worst over all
  variants and cases max|Δrho| = 2.22e-16, max|Δu| = 6.25e-17. Mass error 0, z-mirror asymmetry 2.22e-16, 0 subnormals.
- Link counts = oracle's in every case (e.g. 16³: 6208 NoSlip, 1280 lid).
- Decomposition, 1×32³ against 8×16³ (61 steps): 11/11 bit-identical (32768/32768 cells).
- Bit-identical pairs (same `fieldhash` in every case): scalar = autovec, scalar_cse = autovec_cse,
  scalar_cse_aa = autovec_cse_aa (GCC does not vectorize the bulk kernels), explicit_cse = explicit_cse_pf,
  explicit_cse_aa = explicit_cse_aa_pf (prefetch hints do not change arithmetic). All other pairs differ by rounding.
- sha256 of the 11 verified executables: in the verify log. `all.sh` now times only these (below).

**Timing scripts, changed before any timing** (`scripts/presentation4/`):
- `run.sh`: `SKIP_BUILD=1` runs the executables as they are, with no cmake and no build.
- `all.sh`: runs every experiment with `SKIP_BUILD=1`. It refuses to start unless each of the 44 executables
  (2 compilers × 2 precisions × 11) has its sha256 and path in a `verify-<cc>-<prec>.log` that says `VERIFY PASS`.
  At the end it checks every sha256 line of the timing logs against the same verify logs.
- `extras.sh`: the warm-up check uses the verified executables (`SKIP_BUILD=1`). The scalar-in-vector-tree runs build
  new executables; their field hashes are compared by hand with the scalar tree's.

## 2026-11-17 (resumed session): stage 2, Clang f64 on the board; stage 2 complete

`prepare-f64.log` ended `Mon Nov 16 06:05:54` board time with `1 failure(s)` / `PREPARE FAIL`; the one failure is the
first GCC f64 audit (sqlite3.c, explained above, superseded by `check-gcc-f64-rerun.log`). Everything else passed.
Logs copied to `board-logs/board/`: `prepare-f64.log`, `build-clang-f64.log`, `check-clang-f64.log`,
`verify-clang-f64.log`, `verify-clang-f64-results.log`, `compilers-f64.log`.

**Build** (`build-clang-f64.log`, Bianbu clang 18.1.8): all 11 targets built. This was the first Clang build of the
AA, prefetch and split code; no source change was needed.
- Compile line of the generated sweeps: scalar tree `-march=rv64gcv_zvl256b -mtune=spacemit-x60 -O3 -march=rv64gc
  -std=c++20 -march=rv64gc`, vector tree `-march=rv64gcv_zvl256b -mtune=spacemit-x60 -O3 -std=c++20`.
- RVV instructions, whole executable / generated sweeps object:

| target | executable | generated sweeps |
|---|---|---|
| scalar, scalar_cse, scalar_cse_aa | 0 | 0 |
| autovec, autovec_cse | 3832 | 91 |
| autovec_cse_aa | 4158 | 54 |
| explicit_cse / explicit_cse_pf | 4481 / 4476 | 740 / 735 |
| explicit_cse_aa / explicit_cse_aa_pf | 5267 / 5270 | 1163 / 1166 |
| explicit_cse_aa_split | 7732 | 3665 |

- Prefetch hints (same `llvm-objdump | grep -c` as for GCC): explicit_cse_pf 103, explicit_cse_aa_pf 107, the other
  three explicit targets 0. The same counts as GCC.
- **Clang auto-vectorizes no generated kernel at all**: 0 RVV instructions inside the kernel functions of the three
  autovec targets (`check-clang-f64.log`, `INFO ... 0 in the kernels`), not even the wall kernels that GCC vectorizes.
  The 91/54 instructions of the generated-sweeps object lie outside the kernel functions.
- In explicit_cse_aa_split Clang inlined most split passes into `LBM_SPLIT::streamCollide` (2200 RVV instructions
  there); GCC kept them as separate functions.

**Build audit** (`check-clang-f64.log`): `CHECK_BUILD PASS` for both trees, `CHECK_WALLS PASS`.
- `-O3` last in 242/242 commands per tree; `-mtune=spacemit-x60` in every command (waLBerla's configure check
  accepted it for Clang); scalar tree last `-march=rv64gc` 242/242, vector tree `rv64gcv_zvl256b` 230 (sqlite3.c
  included: `Clang.cmake:31-32` sets C flags too) and `rv64gc` 12 (the scalar targets).
- 0 RVV instructions in each whole scalar executable.

**Verification** (`verify-clang-f64.log`): `VERIFY PASS`, 11/11.
- Oracle, 4 cases: worst over all variants and cases max|Δrho| = 2.22e-16, max|Δu| = 6.94e-17; mass error 0,
  z-mirror asymmetry ≤ 2.22e-16, 0 subnormals; link counts = oracle's.
- Decomposition 1×32³ against 8×16³: 11/11 bit-identical.
- The same bit-identical pairs as GCC: scalar = autovec (and with `_cse`, `_cse_aa`), explicit = explicit `_pf`.

**GCC against Clang** (`compilers-f64.log`): 4 × `PASS compilers` (GCC scalar against every Clang build, tolerance
2e-12); worst max|Δrho| 2.22e-16, max|Δu| 5.55e-17.
- Field hashes compared per case over the 6 runs of each verify (4 oracle cases, decomposition np=1 and np=8),
  from `verify-{gcc,clang}-f64-results.log`: the 5 explicit (RVV) variants are **bit-identical between GCC and Clang in
  6/6 cases**; the 6 plain C++ variants (scalar, autovec, with `_cse`, `_cse_aa`) differ in 6/6.
- Evidence for the reason (llvm-objdump of `StreamCollide_kernels::StreamCollide`): plain C++ scalar build: GCC uses
  107 fused multiply-adds (`fmadd.d` etc.) and 64 separate `fmul/fadd/fsub.d`; Clang 88 and 95. So the compilers fuse
  different operations, which rounds differently. The RVV build: both have exactly 67 vector fused multiply-adds,
  which the generated intrinsics fix. (The compilers' different `-ffp-contract` defaults are the likely cause of the
  scalar difference; not checked further, it does not affect any result.)

**Stage 2 gate: passed** (all 22 f64 executables built, audited and verified; GCC and Clang agree).
sha256 of the 22 verified executables: `verify-{gcc,clang}-f64.log`.

## 2026-11-17: why the board builds are slow (measured at board time 07:29)

- `nproc` = 8; the builds use `cmake --build … -j 2` (`JOBS=2`, the default in `run.sh`, taken from presentation3's
  `run.sh:31` comment "the heaviest waLBerla translation units need ~1.3 GB each"; that figure is inherited, not
  measured in this work). `top`: 25 % user, 70 % idle: 2 of 8 cores compile. No other user's job runs.
- RAM 3808 MB, about 1.3 GB used, 2.5 GB available; **no swap configured** (`SwapTotal: 0 kB`, `swapon` empty), so
  nothing can swap; memory pressure (PSI `/proc/pressure/memory`) 0.00; no OOM message in the kernel log.
  The two running `cc1plus` had 134 and 364 MB resident. Without swap, too many parallel jobs would end in the OOM
  killer (a failed build, or a killed process of another user on this shared board), not in swapping.
- Where the time goes (GCC f64, `build-gcc-f64.log`): each tree rebuilds waLBerla's libraries from scratch (about
  35 min at `-j 2`), configure about 6-7 min, then each further variant about 2.5 min. 4 trees per precision.
- Measurement started: screen `presentation4-rss` runs `/home/bananapi/saleh/presentation4/rss-sample.sh` (read-only:
  every 2 s the largest compiler RSS and MemAvailable, into `logs/rss-sample.log`; it stops by itself when
  `presentation4-prepare` ends). Its maximum decides whether a later rebuild may use more jobs. The timing runs
  (`all.sh`) compile nothing.

## 2026-11-17: stage 3, GCC f32 on the board

From `prepare-f32.log` (fixed scripts, strict gate): GCC f32 build 06:05-07:57, audit `CHECK_BUILD PASS` ×2 and
`CHECK_WALLS PASS`, verify `VERIFY PASS` at 08:02 board time. Logs copied to `board-logs/board/`: `build-gcc-f32.log`,
`check-gcc-f32.log`, `verify-gcc-f32.log`, `verify-gcc-f32-results.log`.

- Build: all 11 targets. RVV instructions, executable / generated sweeps: scalar ×3 0 / 0; autovec, autovec_cse
  7929 / 273; autovec_cse_aa 8417 / 281; explicit_cse, _pf 8555 / 899; explicit_cse_aa, _aa_pf 9511 / 1375;
  explicit_cse_aa_split 10338 / 2250. Prefetch hints: _pf 103, _aa_pf 107, the others 0.
- As in f64, GCC auto-vectorizes only the wall kernels (autovec: 12 RVV instructions in `UBB`, 9 in `NoSlip`).
- Audit: `-O3` last in 242/242 commands per tree; scalar tree last `-march=rv64gc` 242/242; vector tree
  `rv64gcv_zvl256b` 229, `rv64gc` 12 (scalar targets), none for sqlite3.c (not linked: the new check passes);
  0 RVV instructions in each whole scalar executable.
- Verification, f32 against the f64 oracle, 4 cases. Thresholds calibrated per case on the scalar build: 2× its error
  is below the floor, so every threshold is the floor 4 f32 epsilons = 4.77e-7.
  - Worst over all cases: max|Δrho| = 9.16e-8 for 10 of the 11 variants (split 7.32e-8), max|Δu| 5.71e-8 to
    6.09e-8 (split 2.98e-8). Every variant is within 1.01× of the scalar build's error.
  - Mass error 8.9e-10 to 1.36e-9 (relative), z-mirror asymmetry 1.19e-7 (1 f32 epsilon), 0 subnormals.
  - Link counts = oracle's. Decomposition 1×32³ against 8×16³: 11/11 bit-identical.
  - Bit-identical pairs as in f64 (scalar = autovec with each suffix, explicit = explicit `_pf`).
- Memory sampler (`logs/rss-sample.log`) during the GCC f32 build: largest compiler process 751 MB (07:57, one
  `cc1plus`); lowest MemAvailable 1748 MB (07:56, two compilers, the larger 641 MB).

## 2026-11-18: stage 3, Clang f32 on the board; stage 3 complete

From `prepare-f32.log`: Clang f32 build 08:02-09:33 board time, audit `CHECK_BUILD PASS` ×2 and `CHECK_WALLS PASS`,
verify `VERIFY PASS`, then `compilers-f32.log` 4 × `PASS compilers`; last line (09:38) `PREPARE PASS`, 0 failures.
Logs copied to `board-logs/board/`: `prepare-f32.log`, `build-clang-f32.log`, `check-clang-f32.log`,
`verify-clang-f32.log`, `verify-clang-f32-results.log`, `compilers-f32.log`, `rss-sample.log`.

- Build: all 11 targets. RVV instructions, executable / generated sweeps (`build-clang-f32.log`): scalar ×3 0 / 0;
  autovec, autovec_cse 3822 / 91; autovec_cse_aa 4148 / 54; explicit_cse 4470 / 739; explicit_cse_pf 4464 / 733;
  explicit_cse_aa and explicit_cse_aa_pf both 5254 / 1160; explicit_cse_aa_split 7698 / 3641.
- explicit_cse_aa and explicit_cse_aa_pf have the same RVV count (also 1121 each inside the kernels,
  `check-clang-f32.log`), so I checked that the `_pf` build really has the prefetch hints (by hand on the board, the
  `llvm-objdump … | grep -c` command of the handover): explicit_cse_pf 103, explicit_cse_aa_pf 107, explicit_cse,
  explicit_cse_aa, explicit_cse_aa_split 0. The same counts as GCC and as Clang f64 (Clang f64 aa 0, aa_pf 107, recounted).
  The hints are scalar instructions (`ori zero, rs, imm`), so they do not change the RVV count; the two executables
  differ (sha256 `fec690069b9c6130` and `6ca2150a6fe9a1a9`, `verify-clang-f32.log`).
- As in f64, Clang vectorizes no generated kernel: 0 RVV instructions inside the kernels of the three autovec targets
  (`INFO … 0 in the kernels`); the 91 / 54 of the generated-sweeps object lie outside the kernel functions.
- Audit: `-O3` last in 242/242 commands per tree; `-mtune=spacemit-x60` in every command; scalar tree last
  `-march=rv64gc` 242/242; vector tree `rv64gcv_zvl256b` 230, `rv64gc` 12 (the scalar targets); 0 RVV instructions in
  each whole scalar executable.
- Verification, f32 against the f64 oracle (`verify-clang-f32.log`: `VERIFY PASS`, 15 × `RESULT PASS`). Thresholds:
  2× the scalar build's error is below the floor in all 4 cases, so each is the floor 4 f32 epsilons = 4.77e-7.
  Worst over the 4 cases, per variant (parsed from the log's tables on the laptop):
  - max|Δrho| 8.98e-8 to 9.16e-8 (split 7.32e-8); max|Δu| 5.66e-8 to 5.95e-8 (split 2.98e-8). Every variant within
    1.026× of the scalar build's error (largest ratio: explicit_cse, u).
  - Mass error ≤ 1.06e-9 (relative), z-mirror asymmetry 1.19e-7 (1 f32 epsilon), 0 subnormals.
  - Link counts: 11/11 variants equal the oracle's in each case (lid links 5·Nx·Nz: 1280, 1280, 2560, 640).
  - Decomposition 1×32³ against 8×16³: 11/11 bit-identical (`PASS decomp` ×11).
  - Bit-identical pairs as before: scalar = autovec (with each suffix), explicit = explicit `_pf`.
  - The worst errors of the 5 RVV variants equal GCC f32's in every printed digit (explained by the next item).
- GCC against Clang (`compilers-f32.log`; GCC scalar against every Clang build, calibrated on the Clang scalar build,
  threshold 4.77e-7): 4 × PASS; worst max|Δrho| 1.19e-7 (one f32 rounding step at rho ≈ 1), max|Δu| 4.47e-8.
- Field hashes per run (the 6 runs of each verify, from `verify-{gcc,clang}-f32-results.log`, same method as for
  f64): the 5 explicit (RVV) variants are bit-identical between GCC and Clang in 6/6 runs; the 6 plain C++ variants
  differ in 6/6. (The same script on the f64 logs reproduces the f64 result: 6/6 and 0/6.)
- Memory sampler, Clang f32 build (08:02-09:33): largest compiler process 1248 MB (09:03:51, one `clang++`); lowest
  MemAvailable 1730 MB (08:24:21, one `clang++` of 1240 MB). These are also the extremes of the whole sample
  (07:30-09:38, 3634 samples). So a heavy Clang translation unit needs about 1.25 GB: `JOBS=2` stays (GCC's 751 MB
  alone had suggested that `-j3` is safe; with Clang it is not: 3 × 1.25 GB ≈ 3.7 GB of 3.8 GB, no swap).

**Stage 3 gate: passed** (all 22 f32 executables built, audited and verified; GCC and Clang agree).
sha256 of the 22 verified executables: `verify-{gcc,clang}-f32.log`.

## 2026-11-18: stage 4 started (timing matrix, `all.sh`)

- Before the start: board idle (`top`: 99.5 % idle, no screen of ours, load average falling from the build);
  `scripts/presentation4/` on the board identical to the laptop by sha256, except `slide_numbers.py` (laptop-only tool,
  not needed on the board). No push, no rebuild since `prepare.sh`.
- Started Mon Nov 16 09:42:10 board time in screen `presentation4-all` (command in "Resume here"). `all.log` begins with
  44 × `verified <hash> <exe>`: every executable's sha256 equals the one in its `verify-<cc>-<prec>.log`.
- First experiment `ldc-gcc-scalar-f32-1core.log` (09:42:13-09:47:33, 5 min 20 s for 3 variants × 3 runs):
  `SKIP_BUILD=1: no configure, no build`; process on core 2 (`ps -o psr`). Each variant's 3 runs have the same field
  hash (deterministic). Best MLUP/s: scalar 1.38, scalar_cse 1.57, scalar_cse_aa 2.00 (1.45× plain scalar); the wall
  sweeps take 5.3 / 6.0 / 8.3 % of the timed loop. (presentation3, periodic box, same protocol: 1.42 / 1.59 / 2.12.)
- A laptop watcher waits for `ALL DONE`, `ABORTED`, a `FAILED`/`missing` line or the end of the screen; it does not
  survive the session (check by hand as in "Resume here").

## 2026-11-18: stage 4 finished (`all.sh`), stage 5 results

**Run** (`board-logs/board/all.log`, 36 `ldc-*.log` copied; sha256 of all 37 files equal on board and laptop):
09:42:10-14:22:33 board time, 4 h 40 min (the plan's 10-12 h estimate was too high). `all.log` starts with 44 ×
`verified`, ends with `== timed executables not in a verify log: 0` and `== ALL DONE`. No `FAILED` or `missing` line
in any `ldc-*.log`. No other job of ours ran meanwhile (`extras.sh` started only afterwards); load from others was not
recorded (see the extras entry: the board's speed can differ between sessions).

**Checks on the timing runs** (laptop, parsing every result line of the 36 logs):
- 33 runs per configuration (11 variants × 3), all with `steps=200 warmup=10 output=every`, domain 64³ (1 core),
  128×128×64 = 2×2×1 blocks (4 cores), 128³ = 2×2×2 blocks (8 cores).
- Deterministic: the 3 runs of every variant have the same field hash and energy (0 exceptions in 132 variant/configuration triples, 396 runs).
- Energy spread over the 11 variants per configuration: f64 ≤ 1.1e-15, f32 ≤ 3.9e-6 (relative). Mass error: f64
  ≤ 5.4e-15, f32 ≤ 8.4e-10. Link counts: `links_ubb = 5·Nx·Nz` in every run, `links_noslip` equal in every run.
- GCC against Clang, same variant, precision and core count: field hash equal for the RVV variants in 30/30
  configurations, for the plain C++ variants in 0/36 (as in the verification runs).

**Numbers** (`python3 scripts/presentation4/slide_numbers.py docs/presentation4/board-logs/board` prints all tables;
`--tex` prints the slide pieces). Best MLUP/s, 1 core, f32 / f64:

| variant | GCC | Clang |
|---|---|---|
| scalar (plain) | 1.38 / 0.92 | 1.36 / 0.89 |
| scalar_cse_aa (best scalar) | 2.00 / 1.46 | 2.11 / 1.58 |
| autovec_cse_aa | 2.01 / 1.44 | 2.10 / 1.58 |
| explicit_cse | 2.34 / 1.14 | 2.23 / 1.10 |
| explicit_cse_pf | 4.58 / 2.42 | 4.20 / 2.16 |
| explicit_cse_aa_pf | 6.56 / 3.89 | 6.19 / 3.63 |
| explicit_cse_aa_split | 7.68 / 4.71 | 7.54 / 4.43 |

- Speedup over the same compiler's plain scalar, 1 core: explicit_cse_aa_pf GCC 4.74 / 4.23, Clang 4.55 / 4.06;
  explicit_cse_aa_split GCC 5.55 / 5.12, Clang 5.55 / 4.96. So f64 passes ×4 with both compilers.
- Gains, 1 core (GCC; Clang): prefetch (AB) 1.96 / 2.12; 1.88 / 1.97. In place with prefetch 1.43 / 1.60;
  1.47 / 1.68. Split loop 1.17 / 1.21; 1.22 / 1.22. Auto-vectorization 0.99 to 1.00 everywhere (GCC vectorizes only
  the wall kernels, Clang nothing: stage 2/3).
- 8 cores, GCC: split 19.49 / 10.35 MLUP/s = 2.22 / 2.00 × plain scalar, 1.56 / 1.36 × best scalar. 4 → 8 cores, RVV:
  +6 to +9 % (f32), +3 to +6 % (f64). Memory traffic of explicit_cse_aa_pf (184 / 368 bytes per cell): 8 cores 3.6 /
  3.8 GB/s.
- Clang against GCC (same variant, precision, cores): 0.89 to 1.10. Plain C++ with CSE: Clang up to 10 % faster;
  RVV on 1 core: 0.89 (explicit_cse_pf f64) to 1.10 (explicit_cse_aa f64); the two fastest RVV builds
  (explicit_cse_aa_pf, _split) 0.93 to 0.98, i.e. Clang 2 to 7 % slower. RVV on 8 cores: 0.965 to 0.986, i.e. 1 to 4 %
  slower.

**New finding: the split loop is the fastest build here** (the periodic box of presentation3 had it at −19 % in f32,
+11 % in f64). Checked that it does the same work and is not "fast because wrong":
- the driver passes `output = true` to the split kernel in every step (`SweepgenLdcCPU.cpp:198-207`, `276`), and the
  split kernel writes rho and u when `output` is true (`../SweepgenLbmCPU/lbm_split.py:100`, `226-234`);
- its energy equals the other variants' to 3.3e-6 (f32) and 6e-16 (f64) in the timing runs; it passes the oracle
  and decomposition checks (stage 2/3); same split sizes as presentation3 (`CMakeLists.txt` of both apps: 2,5,3 / 1,5,3).
- Phase timers, 1 core, GCC f32: split bulk 4.65 s against 5.82 s for explicit_cse_aa_pf (bulk-only 11.3 against
  9.0 MLUP/s; report 3's hand-written split loop in the kernel lab: 10.83). Walls 2.17 s in both.
- Why the periodic box measured the opposite is **not explained** (not investigated; it does not affect any result).

**New finding: the wall passes cost a fixed time.** `t_bc` ≈ 2.1-2.2 s per 200 steps on 1 core for every RVV variant
(f32 and f64), i.e. 27 % (explicit_cse_aa_pf) to 32 % (split) of the GCC f32 run; scalar variants 5-8 %. The wall
kernels are generated as generic scalar code in every build (plan: identical boundary code everywhere), so they
limit the 1-core speedup.

**Slides updated from these numbers** (deck builds with only the clone's inherited 2.7 pt title warning; every page
looked at in `./build.sh png`): `figures/speedup.tex` (bars GCC, diamonds Clang, new group "+ split loop"),
`figures/multicore.tex` (5 series, Clang diamonds, legend in the f64 panel), results and multicore texts and
takeaways, optimizations table (GCC and Clang columns; periodic-box rows marked *; the old row "Clang with X60
tuning, dropped" replaced by the footnote "Clang against GCC, one core: the two fastest RVV builds 2 to 7 % slower"; split loop
now "kept"), AA takeaway, two numbers slides (GCC, Clang; bold = split loop, the fastest in every column), backup
footnote; also fixed: builds table 15 pt too wide, title subtitle line break. Open `\todo`: only the 2 commit hashes.

## 2026-11-18: `extras.sh` finished (method checks); interleaved recheck started

**Run** (`board-logs/board/extras.log` and the 12 `extras-*.log`, copied; sha256 of all 13 files equal on board and
laptop): 14:25:51-17:20:52 board time (2 h 55 min), ends with `== EXTRAS DONE`. No `FAILED` or `missing` line.

**Correctness: all checks pass**
- The 8 executables timed with `SKIP_BUILD=1` (scalar_cse_aa and explicit_cse_aa_pf per compiler and precision)
  have the sha256 of `all.sh`'s runs (and of `verify-<cc>-<prec>.log`), and with warm-up 10 give the same field hash
  as in `all.sh` (8/8): the results repeat bit for bit across sessions.
- Warm-up 2000 (2210 steps in all): GCC and Clang explicit_cse_aa_pf have the same field hash, f32 `0xccd80841af4e6f2c`,
  f64 `0xbc332402b73771fa` (2/2): the RVV builds stay bit-identical between compilers over a long run too.
- Scalar variants built in the vector tree (waLBerla's libraries with `-march=rv64gcv_zvl256b`, the app's own files and
  the generated sweeps with `-march=rv64gc`, as in presentation3; compile lines in the logs): field hash equal to the
  scalar tree's in 12/12 (2 compilers × 2 precisions × scalar, scalar_cse, scalar_cse_aa). Their executables hold
  RVV instructions in the library code only: GCC 5765 (f32) / 5786 (f64), Clang 2716 / 2852; generated sweeps 0.
  (presentation3's GCC scalar executable: 5,795.) So RVV in the libraries does not change any result.
- After extras' vector-tree builds, the 44 verified executables are unchanged: the sha256 recheck command of
  "Remaining work" item 3 (44 unique lines) printed nothing (run just before the recheck below started).

**Timing: inconclusive because of the board, not the flow.** Same executable, same configuration (warm-up 10 is
exactly `all.sh`'s), same field hash, so the same work; best MLUP/s and wall time `t_bc`, extras against `all.sh`:

| | extras w10 / all.sh, MLUP/s | t_bc, extras / all.sh | w2000 / w10 (spread of 3 runs: w10, w2000) |
|---|---|---|---|
| GCC f32 scalar_cse_aa | 1.002 | 1.001 | 1.001 (0.9 %, 1.0 %) |
| GCC f32 explicit_cse_aa_pf | 1.003 | 1.001 | 1.000 (0.4 %, 0.1 %) |
| GCC f64 scalar_cse_aa | 0.915 | 1.046 | 1.010 (0.2 %, 0.9 %) |
| GCC f64 explicit_cse_aa_pf | 0.970 | 1.047 | 0.998 (0.8 %, 0.0 %) |
| Clang f32 scalar_cse_aa | 0.905 | 1.043 | 0.988 (0.4 %, 1.0 %) |
| Clang f32 explicit_cse_aa_pf | 0.902 | 1.045 | 1.051 (2.1 %, 1.7 %) |
| Clang f64 scalar_cse_aa | 0.947 | 1.071 | 1.008 (3.2 %, 3.4 %) |
| Clang f64 explicit_cse_aa_pf | 1.006 | 1.035 | 1.002 (0.2 %, 0.6 %) |

- The first session (GCC f32, 14:25-14:46, directly after `all.sh`) reproduces `all.sh` to 0.3 %. From the GCC f64
  session on (15:03), the same executables run up to 10 % slower, and the wall sweeps, whose work does not depend on
  the flow, take 4 to 7 % longer. So the board was slower during those sessions. Cause not known. Ruled out:
  transparent huge pages (`/sys/kernel/mm/transparent_hugepage/enabled` = `madvise`, and nothing in waLBerla or the
  app calls `madvise`: `grep -rn madvise` over `src`, the app and sweepgen's `include` finds nothing); frequency
  scaling (governor `performance`, 1.6 GHz, min 614 MHz; temperatures 42-43 °C at 18:15, no history); the daily
  release check (`pam_motd` runs `/etc/update-motd.d/91-release-upgrade` on every ssh login; it starts
  `check-new-release` only when the stamp `/var/lib/bianbu-release-upgrader/release-upgrade-available` is older than
  24 h; seen by `recheck.sh` at 18:22 using one core, stamp rewritten 18:22:22), which lasts seconds once a day and
  so cannot slow whole sessions. No history of other
  load exists (`/etc/default/sysstat`: `ENABLED="false"`); `last` shows one interactive login (pts/0, from the VPN
  address 172.16.15.11, the same as this laptop's) from 07:29 to 17:30, which covers `all.sh` too.
- Warm-up, within one session: 7 of 8 ratios lie within 1.2 % (Clang f64 scalar_cse_aa's runs spread 3 %).
  The exception, Clang f32 explicit_cse_aa_pf (w2000 5.1 % faster), is in a disturbed session: its warm-up 10 runs
  (5.46, 5.52, 5.58) are 10 % below the identical configuration in `all.sh` (6.18 to 6.19), and they rise run by run.
- Vector tree against scalar tree: the vector-tree runs are 0.89 to 1.00 of the scalar tree, but they ran in the
  extras session and the scalar tree in `all.sh`, so the session effect above is mixed in. The vector tree's wall time
  was also higher (t_bc 1.02 to 1.09). No conclusion from these numbers.
- The wall-time share in the extras tables: explicit_cse_aa_pf 27 % (f32) and 15.5 % (f64) of the timed loop (GCC);
  the earlier "27-32 %" holds for f32 only. From `all.sh`'s best runs (`t_bc / seconds`), explicit_cse_aa_pf and
  _split: f32 GCC 27.2 / 31.9 %, Clang 25.7 / 31.2 %; f64 GCC 15.3 / 18.6 %, Clang 14.7 / 17.9 %.

**Recheck started** (new script `scripts/presentation4/recheck.sh`, synced alone with `rsync`; also `slide_numbers.py`,
not used on the board): the two sides of each comparison alternate run by run, and the order flips every round (3 rounds):
Clang f32 explicit_cse_aa_pf warm-up 10 against 2000; scalar and scalar_cse_aa, vector tree against scalar tree, both
compilers and precisions. Reference at the start and the end: GCC f64 scalar_cse_aa, warm-up 10 (all.sh 1.457,
extras 1.333). Before every run it logs the busy cores of the board during 1 s and the top processes. No build
(`SKIP_BUILD=1`). Started Mon Nov 16 18:20:12 board time in screen `presentation4-recheck` (board idle before:
0.58 of 8 cores busy, no screen of ours). Logs: `logs/recheck.log`, `logs/recheck-<name>.log`; ends with
`== RECHECK DONE`. Expected about 50 min (estimate).

## 2026-11-18: recheck results; plots split; stream plot checked; split-loop label fixed; new slides; film

**Recheck (`recheck.sh`, 18:20:12-19:07:18 board time; 21 `recheck*.log` copied, sha256 equal on board and laptop).**
Board idle before every run (busy cores ≤ 0.08 of 8, except 0.58 / 0.98 before the first two runs: the daily
`check-new-release` at 18:22). Every run's sha256 is the one of its earlier log; field hashes as before.
- Warm-up, Clang f32 explicit_cse_aa_pf, interleaved: warm-up 10: 6.181 / 6.198 / 6.174, warm-up 2000:
  6.178 / 6.168 / 6.088 MLUP/s; best 2000 / best 10 = 0.997; `all.sh`: 6.186. **Timing does not depend on the
  flow state** (the extras' 5 % difference was the disturbed session).
- Vector tree against scalar tree (scalar, scalar_cse_aa; 2 compilers × 2 precisions; 3 interleaved rounds):
  mean V/S 0.977 to 1.009, best V/S 0.974 to 1.025, within the run-to-run spread (2 to 3 %); field hashes equal
  in 8/8. **The RVV code in waLBerla's libraries (presentation3's way of building the scalar baseline) changes
  neither the results nor, measurably, the speed.** The extras' "6 to 11 % slower" was the session.
- Session effect, confirmed on an idle board: the same scalar executables run at 0.90 to 1.00 of their `all.sh`
  speed (GCC f32 plain scalar 1.244 against 1.384), reference GCC f64 scalar_cse_aa 1.36 / 1.34 at start / end
  against 1.457, while Clang f32 explicit_cse_aa_pf runs as in `all.sh`. Cause unknown (huge pages, clock,
  other load ruled out, see the extras entry). Outside lead, not verified: sonos/tract PR #3014 (merged
  2026-10-13) says the X60's L1 data prefetcher "drifts into a state where it stops covering" streams until a TLB
  flush; it gives no measurements.

**Result plots separated (user request).** Speedup and MLUP/s are now separate figures; speedup has one plot per
precision. New: `figures/speedup-1core-f32.tex`, `speedup-1core-f64.tex` (one slide each, same y scale),
`mlups-1core.tex` (new: one-core MLUP/s, f32 and f64), `speedup-multicore-f32.tex`, `speedup-multicore-f64.tex`
(new: speedup over plain scalar at the same core count, side by side, legend under both by `\ref`);
`multicore.tex` renamed `mlups-multicore.tex` (data unchanged; its figure area is pixel-identical after moving
its styles to the preamble, 0 differing pixels at `build.sh png` resolution); `speedup.tex` deleted.
Clang diamonds now sit next to their bar in the one-core plots (they covered GCC's numbers); the multicore
labels start 4 pt above the bar. Shared pgfplots styles (`onecore`, `clang1`, `mc`, ...) in the preamble.
`slide_numbers.py --tex` prints the coordinates of all five plots (markdown output unchanged except the gains
table, see below).

**Stream plot checked (user doubt).** The old plot (report 3) matched its logs, except that the measured point
at 2 streams (29.5) was left out, and its dashed lines ("our loop, 42 streams: 184", "with software prefetch:
90") were the test loop with the kernel's 19 + 23 pattern, not the program. Its reading, "the prefetcher gives
up past 20 streams", was plausible but not shown: a cliff like that can also come from cache-set or DRAM-bank
conflicts. New measurement, `scripts/presentation4/streams_check.sh` (19:07-19:11 board time, after the
recheck; `streams.log`, `streams-probe.log`, `streams-ldc.log` copied, sha256 equal; tables:
`python3 scripts/presentation4/streams_table.py docs/presentation4/board-logs/board`):
- The probe (`misc/x60-lab/probes/mem.cpp`, unchanged, sha256 `ea67c3bd879c8ad7` on both sides) under `perf stat`
  with the X60 events. Event group 1 (cycles, instructions, prefetch hit/refill) was multiplexed (cycles counted
  68 %, and the probe's own cycle counter then wrong: 0.3 cycles/line); group 2 (l1d_load_miss, l2_miss,
  l2_load_access, stalled_cycle_backend) was counted 100 % in every run. Only 100 % values are used; cycles per
  line from the group-2 runs.
- Read streams R = 1 ... 32 with array starts 4160 B apart (twice, at start and end: e.g. R = 8 19.2 / 19.2,
  R = 24 364.7 / 364.6 cycles per line), 1600 B and 12352 B apart: up to R = 19, L2 demand misses per line
  ≤ 0.031 / 0.128 / 0.064 (every line comes from DRAM: 4 MB per array, so the prefetchers bring them); from
  R = 21 to 23 on, 1.01 to 1.02 per line and 356 to 366 cycles per line (report 3's pointer chase: 357 cycles
  per miss). **The cliff is at 20 to 22 streams for all three offsets: it is set by the number of streams, not
  by the addresses.** Two levels: up to 8 streams L1 misses ≈ 0.01 per line (the L1 prefetcher), 10 to 19
  streams about 0.42 to 0.49 L1 misses per line but L2 still in time.
- Software prefetch 512 B ahead: R = 20 ... 23 cost 96 to 102 cycles instead of 110 to 361; R ≥ 24: 180 to 191
  instead of 365.
- The program (GCC, 64³, 20 steps minus 0 steps), L2 demand misses per cell update: explicit_cse (AB, 42
  streams) 3.08 f32 / 5.71 f64, explicit_cse_aa (23 streams) 1.76 / 2.69, explicit_cse_aa_split 0.34 / 0.31,
  none of the three with software prefetch. explicit_cse: 713.5 backend-stall cycles of 776 per cell (1.6 GHz /
  2.06 MLUP/s) = 92 %. (With software prefetch the counter also counts the prefetches' own misses: not used.)
- Conclusion: the plot's message holds and is now shown: the X60's prefetchers follow about 20 streams; the
  program's 42 (AB) and 23 (in place) are beyond that; the split loop, a few streams per pass, is not.

**Split-loop label fixed (found while checking the counters).** `explicit_cse_aa_split` has **no software
prefetch**: no `--prefetch-distance` in `apps/benchmarks/SweepgenLdcCPU/CMakeLists.txt:69-70`, and 0 prefetch
hints in all four executables (board, `llvm-objdump`; aa_pf: 107). The deck called it "RVV, CSE, in place,
prefetch, split loop" (inherited from presentation3, whose slide row has the same wrong label; presentation3
not changed). Fixed: numbers tables "RVV, CSE, in place, split loop, no prefetch"; one-core plot label "RVV, in
place, split, no prefetch"; optimizations footnote "split loop (no prefetch): against in place with
prefetch". `slide_numbers.py` gains: "split loop (instead of prefetch)" 1.171 / 1.211 / 1.219 / 1.221 and new
"split loop (no prefetch in either)" = split / explicit_cse_aa: 2.636 / 3.203 (GCC f32 / f64), 2.600 / 2.735
(Clang). So in the program, cutting the live streams gains more than prefetching them (prefetch on in place:
2.25 / 2.65 GCC).

**New slides (user request).** "What a data stream is, and why our loop has 42" (`figures/stream-def.tex`;
quote: Wittmann, Zeiser, Hager, Wellein, arXiv:1410.0412, sec. 4.3: "concurrent memory streams (38 with OS-NT
and 19 with AA)"; their 2017 paper arXiv:1711.11468: "19 read and 19 write streams"); "The real limit" rebuilt
on the new measurement (`figures/streams.tex`: cycles and late lines against streams, 3 offsets + software
prefetch); "The stream test: the code behind the plot" (`figures/stream-test.tex`: the timed loop, simplified
from `mem.cpp:124-158`, and the commands with results); "Software prefetch: where the code generator puts it"
(`figures/prefetch-insert.tex`: the pass `InsertPrefetches`, `pystencils/codegen/driver.py:313-315`; generated
loop from the board's `SweepgenLdcCPU_explicit_cse_pf` source: StreamCollide 19 read + 23 write prefetches, one
per stream, 32 floats = 128 B ahead; whole program 103 = 42 + 38 + 23, equal to the executable's 103 hints;
runtime `prefetch_read` = `ori x0, rs, 1`); "The flow we compute" (film, below). Glossary: Stream redefined,
new L1/L2 and Late line. Code boxes are generated with aligned comments (escaping by a helper, not by hand).

**Film (user request).** `scripts/presentation4/cavity_movie.py` runs the benchmark program itself (x86 build
`build/presentation4-x86/gcc-f64/.../SweepgenLdcCPU_explicit_cse_aa`, f64, 64³, warm-up 0) once per frame from
rest, 16 at a time, dumps rho and u, draws the middle plane (speed / lid speed, streamlines): 42 frames, steps
16000 (k/40)² plus 210, `figures/cavity-movie/frame-00..41.png` (128-colour PNG) and `cavity.gif` (2.4 MB),
4.2 MB in all; log `board-logs/x86/cavity-movie.log`. Checks: x86, 200 + 10 steps: energy 11.366594364647609;
frame-05 (step 210) the same. [Corrected later: this equals the board's GCC scalar_cse_aa / autovec_cse_aa f64
value to the last digit, not the board's explicit_cse_aa (…647622); the board's f64 builds span …647609 to
…647623, so x86 and board agree to about 1e-15 relative, not bitwise.] Energy against steps (to choose the
length): 1000: 20.80, 4000: 29.91, 8000: 32.89, 16000: 33.75, 24000: 33.80, 48000: 33.80. Slide: `animate`
package, plays in Acrobat/Okular, poster = last frame elsewhere.

## 2026-11-18: headline speedups in a second session (`speedup_check.sh`)

Board 19:11:26-19:28:05 (after the stream check), idle before every run (busy cores ≤ 0.02 of 8). Plain scalar,
explicit_cse_aa_pf and explicit_cse_aa_split alternate run by run, order reversed every second round, 3 rounds,
both compilers and precisions; every run's sha256 is the one in `all.sh`'s log, field hashes as in `all.sh`
(1 per executable). 13 `speedup*.log` copied, sha256 equal on board and laptop.

| | scalar today / all.sh | aa_pf today / all.sh | split today / all.sh | speedup aa_pf today (all.sh) | speedup split today (all.sh) |
|---|---|---|---|---|---|
| GCC f32 | 0.901 | 1.003 | 0.993 | 5.274 (4.738) | 6.119 (5.548) |
| GCC f64 | 0.989 | 1.009 | 0.965 | 4.315 (4.230) | 5.000 (5.123) |
| Clang f32 | 0.919 | 0.999 | 1.001 | 4.947 (4.551) | 6.045 (5.550) |
| Clang f64 | 1.042 | 1.013 | 0.987 | 3.944 (4.061) | 4.698 (4.959) |

(best of 3 each; per-round ratios: e.g. GCC f32 split 6.11 / 6.33 / 6.12, Clang f64 aa_pf 3.89 / 4.23 / 4.11.)
- The RVV builds repeat `all.sh` within 3.5 %; the plain scalar baseline does not (f32: 8 to 10 % slower today).
  So the f32 speedups of another session are 9 to 11 % higher than the slides' `all.sh` values; f64 5 % lower to
  2 % higher. The f64 ×4 claim (split loop) holds in both sessions (today ×5.00 GCC, ×4.70 Clang); Clang's in place
  + prefetch is ×3.94 today against ×4.06.
- Slides: both one-core results slides now say this in their caption line (numbers above; source comment above the
  f32 frame). The shown values stay those of `all.sh` (all builds, compilers and core counts in one session).
- Plot labels: the split group's tick label is now "RVV, AA, split loop, no prefetch" (three lines; the two-line
  version ran into its neighbour), the one-core plots 1.5 to 3.5 mm lower to fit.

## 2026-11-18: film as a video for pdfpc (user: the GIF/`animate` film did not play in their viewer)

- The user's choice: beamer's `multimedia` package, `\movie`, shown with pdfpc (installed by the user: pdfpc v4.7.0).
  pdfpc docs (man page `man/pdfpc.in`, demo `demo/pdfpc-video-example/pdfpc-video-example.tex`): options in
  `\movie[...]` (`loop`, `once`, `showcontrols`, `start=`, `duration=`, `poster`); playback through GStreamer;
  `\movie` does not autostart (only the deprecated `\href{run:...?autostart}` hack does).
- Video: `cavity_movie.py` now also writes `figures/cavity-movie/cavity.avi` with ffmpeg from the full-colour
  frames: Motion-JPEG in AVI (needs only `avidemux` + `jpegdec` from gst-plugins-good, which pdfpc requires; H.264
  would need extra plugins on other machines), 8 frames/s, last frame held 1.5 s, 3.8 MB. Re-rendered with
  `--render-only` from the cached runs (`cavity-movie.log` byte-identical, sha256 `5528d1f775ea40a9`). Checked:
  `gst-discoverer-1.0`: AVI, JPEG, 510×480, 8/1, 6.75 s; `gst-launch-1.0 filesrc ! avidemux ! jpegdec !
  videoconvert ! fakesink`: exit 0; ffprobe: 54 frames (42 + 12 held).
- Slide: `\usepackage{animate}` replaced by `\usepackage{multimedia}`;
  `\movie[loop]{\includegraphics[height=5.1cm]{figures/cavity-movie/frame-41.png}}{figures/cavity-movie/cavity.avi}`.
  The PDF (qpdf JSON) has on page 3 a /Movie annotation, /F `figures/cavity-movie/cavity.avi`, activation
  /Mode /Repeat, Rect 153.6 × 144.6 pt (the poster's 510:480). `\movie` links the file, it does not embed it, and
  pdfpc's docs do not say whether the path is taken from the PDF's folder or the working directory: `build.sh`
  copies the video to `build/figures/cavity-movie/` after every build, so both work. PDF 0.39 MB (was 2.2 MB with
  the frames embedded). Playback itself not seen here (GUI): to check, `pdfpc docs/presentation4/build/slides.pdf`,
  slide 3, click the picture.

## 2026-11-18: reproduction guide `scripts/presentation4/README.md`

- New `scripts/presentation4/README.md`: the pipeline, a table "what each figure and table comes from" (every
  data figure, both numbers tables, the caption lines, the film; drawings named as such), the board and laptop
  steps with exact commands, the script index, caveats.
- Gaps closed so that a fresh clone can reproduce everything:
  - `build_x86.sh` (new, tracked): the x86 build recipe that lived only in the ignored
    `build/presentation4-x86/build-trees.sh`; settings from the trees' `CMakeCache.txt`. Tested in a separate
    root (`B=build/presentation4-x86-check`, pystencils-sfg 0.1.1 freshly from PyPI): configure + build of
    `SweepgenLdcCPU_explicit_cse_aa` gcc f64 in 72 s; its output at 210 and 1000 steps (energy and field hash)
    equals `board-logs/x86/cavity-movie.log` exactly. Test tree deleted afterwards. (First attempt with a relative
    `B` was stopped: code generation runs inside the tree, so the script now makes `B` absolute.)
  - `speedup_table.py` (new): the second-session evaluation that had been a scratch script; same numbers as the
    caption lines; checks one sha256 and one field hash per executable in both sessions (passes).
  - `check_figures.py` (new): recomputes every plotted coordinate (57 `\addplot` blocks of the 7 data figures; 2
    all-1 blocks skipped) and the 22 numbers-table rows from the logs and compares digit for digit, per figure
    section and precision: `CHECK_FIGURES PASS`. Mutation test: one changed digit, f64 values put into the f32
    figure, one changed table number: each `CHECK_FIGURES FAIL (1)`; files restored (sha256 identical), PASS again.
- The README's log-copy check (sha256 of every `*.log` on the board against `board-logs/board/`) prints nothing:
  the repository holds exactly the board's logs.

## 2026-11-18: the film on the board; `all.sh` runs every board job; README cut down

- **Board film (user request: same exact parameters, on bananapi).** `scripts/presentation4/cavity_movie_board.sh`
  runs the unchanged `cavity_movie.py` (same frame steps, 64³, warm-up 0, middle plane, drawing, AVI, GIF) with the
  verified RISC-V executable GCC f64 `SweepgenLdcCPU_explicit_cse_aa` (sha256 `4cc7d6a9f3d1d81c`, the variant of
  the x86 film); the board's venv has matplotlib 3.6.3 and Pillow 10.2, ffmpeg 6.1.1 has `tpad`. Checks: (1) the
  sha256 is in `verify-gcc-f64.log` (VERIFY PASS); (2) frame step 210 must have all.sh's energy and field hash of
  this executable, `energy=11.366594364647622 fieldhash=0xf2c7bddf8a3b3a76` (10 warm-up + 200 steps; on x86 the
  warm-up steps were shown to be ordinary steps: 200 + 10 and 210 + 0 give the same hash); (3) 42 frames, one
  variant. Started Mon Nov 16 20:10:01 board time in screen `presentation4-movie` (check 1 PASS, 8 runs at once);
  estimate 2 to 2.5 h (8 cores, explicit_cse_aa f64: 7.29 MLUP/s on 8 cores in all.sh, 5.8e10 cell updates).
  Laptop side: `fetch_movie_board.sh` (copy, sha256 check, then `compare_movies.py`: per frame energy, mass and
  middle-plane velocities against the x86 film, PASS at 1e-10; field hashes not expected equal across ISAs).
- `cavity_movie.py`: the cache now keeps the middle planes in f64 (float32's resolution, about 3e-9 at the lid
  speed, is coarser than the 1e-10 comparison) and stores the program path (used by `--render-only`); drawing
  still from float32 as before. The x86 film is being re-run to refresh its cache; its 45 output files must stay
  byte-identical (sha256 list taken before).
- **`all.sh` runs every board job (user request).** After the timing matrix: `streams_check.sh`,
  `speedup_check.sh`, `extras.sh`, `recheck.sh`, `cavity_movie_board.sh` (last: all 8 cores), each as when started
  alone, with its own log; a status line per part at the end. `PARTS` selects parts, `DRY_RUN=1` lists the
  commands without running anything. Dry run on the board: 44/44 executables verified, the 36 matrix experiments,
  the 5 parts in order, status block; an unknown part is refused. Not run for real (11 h, and it would overwrite
  the logs behind the slides).
- **`scripts/presentation4/README.md` cut to 42 lines (user: too long)**: the board commands, the laptop commands,
  the x86 film, two notes. The per-figure source table it had is in the figure files' headers.

## 2026-11-18: two films side by side (laptop x86 AVX, board RVV); `laptop.sh`

- **The laptop film uses pystencils' unmodified x86 path (user requirement), shown:** on x86 the `explicit`
  family uses `Target.CurrentCPU` (`SweepgenLdcCPU.py:63,72`), which on the i9-13950HX (AVX2, FMA, no AVX-512)
  gives 256-bit AVX intrinsics (generated source: `_mm256_mul_pd` 648×, `_mm256_add_pd` 416×, ...; includes
  `pystencils_runtime/x86.hpp`; no RVV), GCC 16.2.1 `-O3 -march=native`. Our fork's diff against upstream
  (`20d7dcf0`, the last upstream commit; `git diff --stat 20d7dcf0 HEAD -- src`) only adds RVV files and hooks
  that do nothing for x86 (`prepare_vector_loops` default identity; prefetches only with the option; the new
  row-pointer pass used only in `rvv.py`; the JIT change only on riscv64). Test: `build_x86.sh` with new option
  `PYSTENCILS=upstream` (exports 20d7dcf0 from the submodule; waLBerla takes the runtime headers from Python,
  `CMakeLists.txt:344-347`, so upstream headers too) into `build/presentation4-x86-upstream`: the generated
  `SweepgenLdcCPU.hpp` byte-identical, the `.cpp` has the same 4400 lines in a different order (only the setup
  blocks of the rho and u parameters swap); its executable gives the same energy and field hash as the fork build
  at 210, 1000 and 4000 steps. The film is now made with this upstream build (`laptop.sh` part `x86film`): all 44
  film files byte-identical to before; the run log differs only in wall times and its header (program path).
- Correction: the earlier "x86 energy equals the board's to the last digit" holds for the board's scalar_cse_aa
  / autovec_cse_aa builds (…647609), not for explicit_cse_aa (…647622); x86 and board agree to about 1e-15
  relative. Fixed in the slide text and here (stage-1 film entry annotated).
- `scripts/presentation4/laptop.sh` (new): the laptop half (x86film, logs, boardfilm, check, slides; `PARTS`).
  Its x86film step checks step 210 against all.sh's board energy of the same program to 1e-12 (passes:
  11.366594364647609 against 11.366594364647622). Defaults of `cavity_movie.py` and the x86 cache path of
  `fetch_movie_board.sh` now point to the upstream build.
- Slide "The flow we compute, on both machines": the laptop film and the board film side by side, each with a
  caption (machine, ISA and vector width, which code path, compiler); the board slot shows "not fetched yet"
  until `fetch_movie_board.sh` has run (`\IfFileExists`), so the deck always builds. `build.sh` copies both
  videos next to the PDF. The agreement numbers go on the slide only after `compare_movies.py` has run.
- `compare_movies.py` sanity check: the x86 film against itself gives 0 differences, 42/42 hashes, PASS.

## 2026-11-18: board film done, fetched, compared; slide shows both films

- `cavity_movie_board.sh`: 20:10:01-22:25:09 board time (2 h 15 min; estimated at 21:20 from the measured rate
  0.90 MLUP/s per run, 7.2 on 8 cores: "about 22:30"). PASS 1 (verified executable), PASS 2 (step 210:
  energy=11.366594364647622 fieldhash=0xf2c7bddf8a3b3a76 = all.sh, bit for bit), PASS 3 (42 frames, one variant),
  MOVIE PASS. Board outputs 7.8 MB (frames, 3.8 MB AVI, 2.4 MB GIF).
- `laptop.sh` parts boardfilm, check, slides: 47 files copied (44 film files, `movie.log`,
  `cavity-movie-board.log`, `slices.npz`), sha256 equal on board and laptop (rechecked by hand); `compare_movies.py`
  x86 (upstream-pystencils build, GCC 16.2.1) against board (GCC 14.2.0): worst relative energy difference
  1.20e-14 (frame 41, step 16000), worst middle-plane |du| / u_lid 5.07e-15; the difference grows slowly from
  ~1e-16 (step 10) to ~1e-14 (step 16000); field hashes equal only at step 0; COMPARE_MOVIES PASS (tolerance
  1e-10). `CHECK_FIGURES PASS`; deck builds (only the inherited title warning).
- Slide "The flow we compute, on both machines": both films with captions, the measured agreement in the
  caption line, takeaway "A real flow, and both machines compute the same one: they agree to 14 digits." PDF page
  3 has two /Movie annotations (`figures/cavity-movie/cavity.avi`, `figures/cavity-movie-board/cavity.avi`, mode
  /Repeat, same size); both videos decode with GStreamer (6.75 s, 510×480, JPEG). `build.sh` copies both next to
  the PDF.
- Board copy of `scripts/presentation4/` brought equal to the laptop's (0 content differences); the copy that
  made the film differed only in `cavity_movie.py`'s defaults and comments (the board script passes `--exe` and
  `--work`).

## 2026-11-18: the stream-test slide's last two lines now from presentation4's own runs

- `streams_check.sh` section 3 "pattern" (new; `STREAMS_PARTS` selects sections, default all; not `PARTS`, which
  all.sh's children would inherit): `mem stream 19 23 thp=1 stagger=4160` without and with `pfr=128`, 3 runs each,
  alternating, core 2, without perf. Run alone on the board (`STREAMS_PARTS=pattern`, 22:48:18-22:48:40 board
  time; job log `streams-pattern-job.log`, so the full run's `streams.log` and the plot's logs stay untouched);
  probe binary rebuilt identical (sha256 `b6392ad226b24a09`). `streams-pattern.log`: without prefetch 180.7 / 181.9
  / 176.3, with prefetch 90.0 / 91.0 / 90.8 cycles per line (report 3: 184.3 and 90.4). Both logs copied, sha256
  equal.
- `streams_table.py` prints the five results of the stream-test slide (table; `--tex`: "% figures/stream-test.tex:
  <command> -> <cycles>"); `check_figures.py` checks each command line of the figure's code box against them
  (now 62 items + 22 table rows, PASS; mutation: 184 put back -> FAIL (1), file restored, sha256 identical).
- Slide: the 19 + 23 line shows 176 (was report 3's 184), the takeaway "176 ... 90"; caption names only
  presentation4 logs. Every number on the two stream slides now comes from `scripts/presentation4/`.

## 2026-11-19: new slide "Software prefetch: the RISC-V instruction behind it"

- Asked by the user: explain how RISC-V prefetches and with which instructions. New slide 11, after "Software prefetch:
  where the code generator puts it"; figure `figures/zicbop.tex` (the 32-bit word of `prefetch.r 0(a0)` =
  `ori x0, a0, 1` = `0x00156013`, field by field; the two readings: cores without Zicbop vs the X60; the runtime
  function `prefetch_read` from `include/pystencils_runtime/rvv.hpp:144-151`, shortened). 3 bullets: RVV has no
  prefetch instruction or intrinsic, Zicbop does; the encoding is a hint; the X60 does not list Zicbop, so GCC drops
  `__builtin_prefetch` and the runtime writes the bits by inline assembly. Takeaway uses 176 -> 90 cycles per line
  (`board-logs/board/streams-pattern.log`, as on the stream-test slide).
- Checked on the laptop (board unreachable at the time, VPN): `riscv64-linux-gnu-g++` 16.2.1 `-O3 -march=rv64gcv`
  compiles `__builtin_prefetch` to nothing and `-march=rv64gcv_zicbop` to `prefetch.r`/`prefetch.w`; `llvm-objdump`
  decodes the inline asm as `00156013 prefetch.r 0x0(a0)`. Clang 23.1.5 emits `prefetch.r` even without `_zicbop`,
  so the slide states the GCC behaviour only (board Clang 18.1 not checked). X60 ISA string without `zicbop`: notes3
  progress log, board facts.
- Glossary (1/2): new entries Hint and Inline assembly; "f32, f64" moved to the left column, item spacing 0.8 pt (as
  in 2/2) so both columns fit. Deck: 26 pages; only warning the inherited `Overfull \hbox` (lines 93-259), also in
  the committed deck. `CHECK_FIGURES PASS`.

## 2026-11-19: split-loop slides; "All the optimizations we tried" removed

- User: "what is split loop? add a slide or two ... why prefetch is not considered for this. get rid of slide 12."
  Slide 12 was "All the optimizations we tried" (footer number = PDF page 12); removed with its comment block (the
  removed source is not kept in the repo). Its per-optimization gains are still in `slide_numbers.py` ("Gain of
  each optimization"); the in-place gain stays in the AA slide's takeaway, the split gain moved to the new slide
  14's takeaway. The prefetch gain (1.96 / 2.12 / 1.88 / 1.97) is no longer on any slide.
- New slide 13 "The split loop: the same update in eight short passes" (`figures/split-loop.tex`): one loop (in
  place, 23 arrays) against the 8 passes per block (4 sums of 5/5/5/4 values, rho and u, 3 collide passes of
  7/6/6 values), the block as 2 rows of a 64 x 64 plane, its size (19 x 128 x 4 B = 9.7 KB + 4.6 KB scratch, L1 32
  KB; f64 1-row blocks, same size). Sources: `SweepgenLbmCPU/lbm_split.py`, `SweepgenLdcCPU/CMakeLists.txt:63-70`,
  the generated `LBM_SPLIT::streamCollide` (x86 build tree, gcc-f32, `SweepgenLdcCPU.cpp:6933-6997`).
- New slide 14 "The split loop in code, and why it needs no prefetch" (`figures/split-code.tex`: the driver and
  pass `m1`, shortened from the same generated file). Why no prefetch: at most 7 arrays per pass; late lines per
  cell 1.762 (explicit_cse_aa) vs 0.341 (split), GCC f32, `streams_table.py` (neither has prefetch); the collide
  passes reload lines still in L1; measured with prefetch (notes3 `board-logs/lab7.log`, kernel lab, periodic box,
  GCC, generated split passes + `prefetch_distance=128`, best of 3): f32 9.967 -> 9.255 MLUP/s (-7 %), 66.4 -> 88.0
  instructions per cell (+33 %); f64 5.528 -> 4.802 (-13 %), 114.5 -> 159.8 (+40 %). Takeaway: split against in
  place + prefetch, `slide_numbers.py`: 1.171 / 1.211 (GCC), 1.219 / 1.221 (Clang).
- Wording: "collide" (as on the benchmark slide), not "relax". Glossary 2/2: new entry "Split loop"; "QEMU" removed
  (used nowhere in the deck, also not in the committed version) so the column fits.
- Deck: 27 pages (22 main + 5 backup); only warning the inherited `Overfull \hbox` (lines 93-259);
  `CHECK_FIGURES PASS`. Every new page looked at in `./build.sh png`.

# Progress (Opus 5.5): RVV for waLBerla-wind on the legacy core

Plan: [`rvv-legacy-wind-plan-opus5.5.md`](rvv-legacy-wind-plan-opus5.5.md). Nothing is committed (the user commits).
All work is on the branch `rvv-support-legacy` of this repository and of the three submodules.

## Resume here

- Names since 2026-11-28 (`scripts-legacy/README.md`, Names): pystencils' own `rvv` is `rvv.lgcy`, our `rvv_ext` is
  `rvv.our1`; entries before that date use the old names.
- Steps 0 to 6 done on the laptop: `rvv_ext` with `vls128`/`vls256`, `m2`/`m4`, `vf`, `fma`, `pf<N>`; all checked
  under QEMU, also on the LBM kernels; `UniformGridCPU` variants; waLBerla-wind benchmark app with pull and AA.
- `scripts-legacy/` (configure, build, time, tabulate; `scripts-legacy/README.md`) works on the laptop; every run
  is one folder `results-legacy/<time>-<random>/` with `bench.json5`.
- Not done yet: row pointers and `in_register` (measure first, plan §2). Step 8 (monte3): the scripts are ready
  and tested on the laptop only (2026-11-28); nothing has run there yet (the user decides when).
- Step 7 (K1): all nine waLBerla-wind variants build (after the `aa_rvv` fix in walberla's template) and pass
  the single-process quick check; multi-process runs died on misaligned MPI buffers. With the alignment patch
  (our walberla branch, commit `1965f0de`) all 81 timed runs pass on 1/4/8 processes (2026-11-28); the RVV checksums
  drift from the scalar one exactly as AVX's do (float32 tolerance now 1e-5). Next: `all ugc` on the K1 (ask first).
  The next K1 build recompiles every vector variant (new names; waLBerla-wind's `main.cpp` got the VTK hook).
- Animations: `bench.py animate <experiment>` and `render <folder>` (`animation.py`), tested on the laptop.
- Open (2026-11-28): a `pull_rvv.our1-...` variant for a like-for-like comparison with `pull_rvv.lgcy`; why `vls256`
  is slower than VLA on the K1; the cause of the vector-vs-scalar checksum drift. The user's decisions: `all ugc`,
  monte3, removing `push.to.sh --repo` (unused now), several experiments in one `start` (user: wait, not done),
  whether monte3 runs go into `results-legacy/` (committed) or stay in `00_private_data/` like notes7's raw monte3
  logs, deleting pystencils' 2.x leftovers (`src/pystencils/{backend,codegen,flow}/`, only `.pyc`, ignored).
- Committed on 2026-11-28 by request, as the user (no Claude trailer): walberla `1965f0de` (alignment fix),
  `888be635` (UniformGridCPU names); waLBerla-wind `cd303fe` (VTK hook), `4e6a85b` (names). Not pushed.
- Uncommitted: pystencils (the `rvv.our1`/`rvv.lgcy` rename), this repository (`scripts-legacy` incl. the new
  `animation.py`, the two K1 runs in `results-legacy/`, READMEs, gitignores, these notes, the submodule pointers).

## 2026-11-26

**Branches.** `rvv-support-legacy` created in this repository (from `main` 9ff8e8b), pystencils (from tag
`release/1.4`, 48474c1a), walberla (from `rvv-support`, 42855054) and waLBerla-wind (from `main`, 9d74213). This
repository's `git status` shows the pystencils submodule pointer as modified (now 1.4).

**Step 0, environment.** `/mnt/LinuxData/02_ws/my-e4-ws/.venv-legacy` (covered by the root `.gitignore` rule
`.venv*/`): Python 3.12.12, sympy 1.12.1, numpy 2.5.5, jinja2, py-cpuinfo, pyvista, scipy, `lbmpy==1.4` without
dependencies, pytest 8.4.2. pystencils comes from the submodule with `PYTHONPATH=submodules/pystencils/src`.
pytest 9 cannot load pystencils 1.4's `conftest.py` (it uses the `path` argument of `pytest_collect_file`, removed in
pytest 9), so the venv pins pytest 8; the upstream file stays as it is.

**Step 1, waLBerla-wind against our walberla on x86.** Build tree `build/notes8-wind-x86` (gitignored):

```bash
PYTHONPATH=$PWD/submodules/pystencils/src cmake -G Ninja -S submodules/waLBerla-wind -B build/notes8-wind-x86 \
  -DWALBERLA_DIR=$PWD/submodules/walberla -DPython_EXECUTABLE=/mnt/LinuxData/02_ws/my-e4-ws/.venv-legacy/bin/python \
  -DWALBERLA_BUILD_WITH_CODEGEN=ON -DWALBERLA_BUILD_WITH_PYTHON=OFF -DWALBERLA_DOUBLE_ACCURACY=OFF \
  -DWALBERLA_OPTIMIZE_FOR_LOCALHOST=OFF -DCMAKE_BUILD_TYPE=Release
ninja -C build/notes8-wind-x86 TurbineLBM_CPU TurbineLBM_CPU_CP TurbineApp_cpu_uniform TurbineApp_cpu_static_refinement TurbineLBM_CPU_AMR
```

- The legacy code generator takes `PYTHONPATH` at configure time (`waLBerla_generate_target_from_python` writes
  `$ENV{PYTHONPATH}` into the custom command), so the 1.4 checkout is used without installing it.
- `WALBERLA_BUILD_WITH_PYTHON=OFF`: waLBerla-wind's apps do not link `python_coupling`, and ON downloads pybind11.
- GCC 16.2.1, CMake 4.4.4, Open MPI of Arch Linux: 224/224 targets in 5 min 35 s, 5 warnings, no errors.
- Non-regression tests. Their `run.sh` runs in the source tree and would leave output files in the submodule, so the
  two test folders were copied to `build/notes8-wind-x86/nonreg/` and their two commands run there
  (`mpirun -np 6 <app> testCase.prm`, `python postprocess.py`):

| test | app time | means printed by `postprocess.py` | reference | result |
|---|---|---|---|---|
| `LBM_CPU` | 10.1 s | 0.018900592 0.019205922 0.0059087444 | the same | PASS |
| `LBM_CPU_CP` | 20.7 s | 0.01865512 0.018785393 0.0036025066 -4.223435e-07 0.018723393 | the same | PASS |

So the 32 upstream commits after waLBerla-wind's CI pin and our RISC-V CMake do not break waLBerla-wind (x86, pull,
float32).

**Step 2, upstream `rvv`.**

- waLBerla-wind's kernel (D3Q27 cumulant, Galilean correction, fourth-order correction 0.1, Guo, QR, compressible,
  zero-centered, float32, pull) vectorizes with `instruction_set='rvv'` in 61 s. The QR model's maximum becomes a
  compare and merge (`vmfgt`, `vmerge`), so the missing min/max templates are no obstacle. The loop body has
  761 `vfmul`, 614 `vfadd`, 476 inline splats (`vfmv_v_f`), 12 `vfdiv`, 92 loads, 33 stores, no FMA.
- `tests/test_rvv_qemu.py` (new file in the pystencils branch; the 2.x `test_rvv_qemu.py` simplified: no targets or
  LMUL parameters, instruction-set strings instead): fixed-shape fields, inputs embedded in a cross-compiled C++
  program, outputs compared with the host JIT of the same kernel without vectors. Upstream `rvv` is right at VLEN
  128, 256 and 512 (one binary, `-march=rv64gcv`).

**Step 3 and the first part of step 4, `rvv_ext`.**

- `src/pystencils/backends/riscv_ext_instruction_sets.py` (new): upstream's dictionary builder copied, with
  `get_argument_string` imported from upstream instead of copied. Options in the name, as 1.4's `sve256` does it:
  `vls128`/`vls256`, `m2`/`m4`, `vf`, `fma`, `pf<N>` (e.g. `rvv_ext-vls256-vf-fma-pf128`).
- Upstream files: two lines in `backends/simd_instruction_sets.py` (import and dispatch). Nothing else.
- Simpler than in 2.x:
  - `vf` and `fma`: the printer builds vector code by calling `.format` on the templates. The `makeVecConst` and
    operator templates of `rvv_ext` are `str` subclasses with their own `format`: a splat remembers its scalar, a
    product its factors, and `+ - * /` look their operands up. No printer change, no symbol bookkeeping (2.x needs
    `_is_uniform`, `_uniform_scalar`, scalar twins and a reassignment check, about 100 lines). The vectorizer
    deep-copies loops when it cuts off the remainder (`vls`), so a copy of such a template is the template itself.
  - `pf<N>`: load and store templates become `(rvv_ext_prefetch_read(addr, N), load(addr, vl))`. No AST pass (2.x:
    `InsertPrefetches`, 118 lines, plus platform hooks). Helper header `include/riscv_v_ext_prefetch.h`.
  - `vls<N>`: integer width and literal `vl`; the vectorizer then cuts the loop into a vector part and a scalar
    remainder by itself. Guard headers `include/riscv_v_ext_vls{128,256}.h`.
- `tests/test_rvv_qemu.py`: 30 passed in 15.6 s.
  - `rvv`, `rvv_ext`, `-vf`, `-fma`, `-vf-fma`, `-pf128`, `-m2`, `-m4-vf-fma-pf128` at VLEN 128, 256, 512;
    `-vls128` at 128 and 256; `-vls256` and `-vls256-m2-vf-fma-pf128` at 256.
  - `rvv_ext` without options prints exactly `rvv`'s code (golden test).
  - `rvv_ext-vls256` code does not compile with `zvl128b`.

**LBM kernels under QEMU** (`scripts/notes8/lbm_qemu_check.py`, new; same harness idea as the pystencils test, with
lbmpy kernels on fixed 13×6×5 fields, x extent odd). Columns: largest difference divided by the array's largest
value (a per-value ratio is meaningless for velocities near zero).

| kernel | variants | instruction sets | VLEN | max diff / array max | result |
|---|---|---|---|---|---|
| D3Q19 SRT, float64 | pull, aa even, aa odd | `rvv`, `rvv_ext-vf-fma`, `-vf-fma-pf128`, `-vls128-vf-fma-pf128` | 128, 256 | ≤ 5.3e-12 (per value) | all ok |
| waLBerla-wind D3Q27 cumulant, float32 | pull | `rvv`, `rvv_ext-vf-fma-pf128`, `-vls256-vf-fma` | 128, 256 | 2.99e-5 / 3.07e-5 / 3.06e-5 | all ok |

What the options do to the D3Q19 AA odd kernel (float64): `rvv` 144 `vfmul` + 125 `vfadd` + 1 `vfdiv` + 110 splats;
`rvv_ext-vf-fma` 85 `vfmacc_vf` + 39 `vfadd_vv` + 36 `vfmul_vv` + 23 `vfmul_vf` + 2 other, no splats; `-pf128` adds
19 read and 23 write prefetches (one per load and store).

**Step 5, walberla.** Deviation from plan §3.4: the code generator needs no change. An app can pass its instruction
set in `cpu_vectorize_info`, which `config_from_context` keeps; an app's CMake can build `rvv_ext-vls${WALBERLA_RISCV_VLEN}`
itself; and the `'sse'` fallback does not happen on the boards, because pystencils 1.4 finds `rvv` in AT_HWCAP. So
the only change is in the app `apps/benchmarks/UniformGridCPU` (upstream's), added only:

- `UniformGridCPU.py`: an optional fourth part of the config is the instruction set of the LBM kernels (3 lines).
- `CMakeLists.txt`: cache list `UNIFORMGRIDCPU_EXTRA_CONFIGS` of such configs, one target each (22 lines appended).
- Checked by running the generator as CMake does (`build/notes8-ugc-gen/`): `d3q19_aa_srt_rvv` (7.1 s),
  `d3q19_aa_srt_rvv_ext-vf-fma-pf128` (5.5 s), `d3q27_pull_cumulant-K17_rvv_ext-vls256-vf-fma` (31.8 s); the sweep
  collections contain the expected intrinsics. Building needs `WALBERLA_BUILD_WITH_PYTHON` (the app links
  `python_coupling`), so it happens on the K1.

**Step 6, waLBerla-wind.** `apps/BenchmarkApp_cpu_uniform` (new) plus one line in `apps/CMakeLists.txt`.

- Made with waLBerla-wind's own AppGenerator, as its README intends for custom setups: a copy of
  `generate_app.py` with `turbine_output`, `vtk_output`, `with_snapshot`, `generate_control` off and an empty
  `field_map`, run from a scratch folder named `BenchmarkApp_cpu_uniform` (the generator writes to
  `apps/<that name>`, so upstream's `GeneratedApp_*` stay untouched). `main.cpp`: 372 lines instead of 527, no
  statistics, snapshot or strain-rate code, so it is the same for pull and AA.
- Then: `LBMGeneration.py` takes `<streaming pattern>_<instruction set>` from `ctx.config` and generates the
  in-place getter pair as the generator's template does; `main.cpp` prints a checksum (sum of ρ and of |u|² over
  the interior); `CMakeLists.txt` builds the variants of `WIND_BENCHMARK_VARIANTS`; `benchmark.prm` is `input.prm`
  with one 64³ block per process, 100 steps, no turbine. The app's `README.md` lists all of it.
- Deviation from plan §3.5: no change to `StrainRateWriter`; the benchmark does not use it. Full AA support with VTK
  strain-rate output is still open.
- x86, float32, no explicit vectors (`pull_none`, `aa_none`), build 1 min 46 s:

| processes | domain | variant | sum(ρ) | sum(\|u\|²) | MLUP/s |
|---|---|---|---|---|---|
| 1 | 64³ | pull | 262143.99828010798 | 757.63847218824912 | 5.36 |
| 1 | 64³ | aa | 262143.99849921465 | 757.63847086051658 | 5.51 |
| 8 | 128³ | pull | 2097151.9898673892 | 7205.0347198385698 | 16.94 |
| 8 | 128³ | aa | 2097151.9896876812 | 7205.034717604256 | 18.70 |

  Pull and AA agree to about 1e-9 relative, float32 rounding; a wrong even/odd handling would differ at order one.
  So AA works in waLBerla-wind through the legacy core (for this setup: periodic inflow/outflow, WFB walls, pressure
  gradient driver).
- Housekeeping: running the generators writes `__pycache__` folders into the source trees. pystencils and walberla
  ignore them; waLBerla-wind has no `.gitignore`, so they were deleted by hand.

**Benchmark scripts, `scripts-legacy/`** (the user's design: Python, short, one self-describing result file per
run; `scripts/` stays as it is, it belongs to the 2.x stack).

- `experiments.py`: typed definitions instead of variant name strings (`Variant(AA, RVV_EXT, vf=True, fma=True)`);
  `bench.py` is the only place that turns them into the code generation names, and before configuring it checks
  that pystencils' `parse_options` reads every `rvv_ext` name back to the same options.
- `bench.py setup | configure | build | run [--quick] | all | list | table`, `remote.py push | start | status |
  fetch` (Banana Pi only; monte3 is not set up).
- Every `run` writes `results-legacy/<YYYYMMDD-HHMMSS>-<6 hex>/bench.json5` (JSON plus whole-line `//` comments,
  so JSON5): experiment, build, machine, software versions, branch/commit/date/uncommitted changes of this
  repository and each submodule, per variant the executable's sha256 and compile flags, every run (MLUP/s, checksum,
  load, exit code, log), and a summary; the apps' output in `logs/`. Rewritten after every run.
- Checksum: `UniformGridCPU.cpp` (walberla, added code only) now prints the same checksum as waLBerla-wind's
  benchmark app; every run is compared with `pull_none` at the same process count (tolerance 1e-6 float32,
  1e-10 float64). The waLBerla-wind benchmark app got `Parameters.warmupSteps` (untimed steps, default 0).
- `push.to.sh <machine> --repo <folder>`: the whole git repository with its `.git` (submodules' git data included),
  so the board's copy is a git repository and `bench.py` reads the git state there itself. Without `--repo`
  unchanged (the 2.x copy). Both modes neither send nor delete `results-legacy/` on the remote. Checked by pushing
  into a local folder: branch, commit and `git status` of the copy equal the original's, the remote's own runs
  survive, venvs, caches, `.claude/`, `build/` and `00_private_data/` stay out; 254 MB of git data.
- Found while testing: `WALBERLA_OPTIMIZE_FOR_LOCALHOST=ON` also vectorizes every kernel that sets no instruction
  set itself with the machine's best one; pystencils 1.4 then fails on waLBerla-wind's flow driver (`cos()`), and
  on the K1 every variant would have got `rvv` there. So it is OFF, and the machine gives `-march`
  (K1: `-march=rv64gcv_zvl256b`, what waLBerla's GNU.cmake gives GCC 14.2 there).
- Laptop, waLBerla-wind, float32, x86 (`bench.py all wind-x86`, run `20261126-120612-3dd551`, 60 steps, 3 rounds):

| processes | variant | MLUP/s median | checksum vs pull_none |
|---|---|---|---|
| 1 | pull_none | 5.90 | (reference) |
| 1 | aa_none | 6.01 | 6.7e-09 |
| 4 | pull_none | 9.44 | (reference) |
| 4 | aa_none | 10.86 | 4.4e-10 |
- Laptop, UniformGridCPU D3Q19 SRT, float64, x86 (`bench.py all ugc-x86`, run `20261126-121047-d17eef`; configure
  fetched pybind11 v2.13.6, the checksum lines compile): pull and AA agree to 3.6e-16; sum(|u|²) of the decaying
  shear flow falls from 5.72 (12 steps, quick run) to 4.89 (70 steps), so the checksum follows the flow.

| processes | variant | MLUP/s median | checksum vs pull_none |
|---|---|---|---|
| 1 | pull_none | 34.95 | (reference) |
| 1 | aa_none | 36.88 | 3.6e-16 |
| 4 | pull_none | 36.43 | (reference) |
| 4 | aa_none | 53.86 | 3.6e-16 |

- `PYTHONDONTWRITEBYTECODE=1` during code generation: no more `__pycache__` folders in waLBerla-wind's tree.

**Step 7, K1, started.** Laptop test runs deleted; `remote.py push`: the git copy on the board
(`/home/bananapi/saleh/my-e4-ws-legacy`, 428 MB) has the same branches, commits and changes as the laptop.

- `push.to.sh --repo` now sends only what git sees: git itself lists what it ignores, in the repository and in each
  submodule, and rsync gets that as excludes (rsync's own `.gitignore` reading gets the presentations' `!` rules
  wrong). Without this, 566 MB of ignored `docs/presentation6/data/` would have gone too.
- Board: GCC 14.2, CMake 3.28, Open MPI 4.1.6, Python 3.12.3. `/home` 96 % full after the push (1.4 GB free),
  `/` (with `/tmp`) 99 % (222 MB): the scripts point `TMPDIR` to the work folder. PyPI has no numpy for riscv64, so the
  venv uses the system's (Ubuntu 1.26.4, `--system-site-packages`). The load average of 2.00 comes from two kernel
  threads (`vq0`, `vq1`) in I/O wait since boot, without CPU time.
- Blocked: the board's clock is 46 h behind (no working RTC, NTP active but not synchronized), so pip fails
  (certificates "not yet valid"); make would also rebuild everything each time (the pushed files lie in the future)
  and the run times would be wrong. `remote.py start` now refuses when the clocks differ by more than 2 minutes.
  Setting the clock needs sudo on the board: the user's decision.
- The user set the board's clock (26 Nov, now within 3 s of the laptop). `remote.py start setup`: venv
  `/home/bananapi/saleh/.venv-legacy` (93 MB): lbmpy 1.4, sympy 1.12.1, joblib, the system's numpy 1.26.4;
  pystencils from the submodule. `remote.py start all wind` started 26 Nov 12:43 (laptop time): the `rvv_ext` names
  check passed on the board, configure running.
- First `all wind` stopped in the build after 2.5 h: `pull_none`, `aa_none` and `pull_rvv` built, `aa_rvv` did not
  compile (`'_size_pdfs_0' was not declared in this scope`, also `_size_pdfs_1/2`, `_size_velocity_0/1/2`, in
  `blockStreamCollide`). Cause, upstream walberla: for in-place streaming `lbmpy_walberla` also generates block-wise
  kernels (all blocks of a level in one call, `_data_<field>_dp` pointer arrays), and their call in
  `LBMSweepCollection.tmpl.cpp` defined the sizes of the first field only (`density`). Vectorized with
  `nontemporal` (waLBerla-wind sets it) and an instruction set that has `cachelineZero` (RVV, also NEON and
  VSX; not SVE, which has real nontemporal stores), every store gets a guard `offset < _size_<field>_0*_size_<field>_1*_size_<field>_2` with the sizes of
  the stored field, here `pdfs` and `velocity`. UniformGridCPU is not affected: its block-wise kernel has only `pdfs`.
- Fix (walberla, `python/lbmpy_walberla/templates/LBMSweepCollection.tmpl.cpp`, 4 lines become 7): the call
  defines the sizes of every field, all from the block's `size_1..3` (the fields of one block have the same
  interior size; the guard then only becomes stricter), `[[maybe_unused]]` for kernels without the guard. Checked
  on the laptop: regenerated `aa_rvv`, `aa_rvv_ext-vls256-vf-fma-pf128` and `aa_none` with the generator command
  CMake uses and cross-compiled them (`riscv64-linux-gnu-g++ -march=rv64gcv_zvl256b -std=gnu++20 -fsyntax-only`):
  no errors, no new warnings; the board's old `aa_rvv` file gives the 12 errors there too.
- The guard is dead code on the K1 for now: without `_zicboz` in `-march`, pystencils' `cachelineZero` is empty,
  `cachelineSize()` then returns `SIZE_MAX` and the guard is never true; the K1 does have Zicboz (its `isa` line),
  so `-march=…_zicboz` stays the experiment of plan §5.
- The code generation reruns only when the generator script changes (CMake knows no other dependency), so after
  the fix the board's generated `aa_rvv/waLBerlaWind_KernelInfo.h` was removed by hand; the three variants already
  built stay as they are. `remote.py push`, `remote.py start all wind` again (26 Nov 15:30 laptop time).
- Another job runs on the shared board account (`lu_clang_vec`, one core at 100 %, load about 3 with the two idle
  kernel threads); it does not matter for the build, but may for the timings: `bench.json5` keeps the load of
  every run.
- Second `all wind` (run `20261127-011820-469d71`, fetched): all nine variants built (about 2 h 50 min). Quick run,
  1 process, 13 steps, load about 4 from another user's jobs (not a measurement): `pull_none` 0.51, `aa_none` 0.57,
  `pull_rvv` 0.70, `aa_rvv` 0.51, `aa_rvv_ext-vf` 0.57, `-fma` 0.52, `-vf-fma` 0.62, `-vf-fma-pf128` 1.07,
  `-vls256-vf-fma-pf128` 0.67 MLUP/s; all checksums ok. All RVV variants differ from the scalar ones by the same
  5.4e-7 relative in sum(|u|²), while the scalar ones agree to 3e-10 and the RVV ones among themselves to about
  1e-8: inside the tolerance, systematic, cause not known yet.
- All 4-process runs died, `pull_none` included: `Bus error`, `Invalid address alignment`. Stack (addr2line):
  `waLBerlaWind_StorageSpecification::PackKernels::packDirection` ← `UniformGeneratedPdfPackInfo::packDataImpl` ←
  `UniformBufferedScheme::startCommunication`; faulting instruction `vsseg3e32.v`, i.e. GCC auto-vectorized the
  scalar pack kernel. `UniformBufferedScheme::writeHeader` puts a variable-length header (block ID, direction) before
  each block's data, so the pack kernel writes floats through a `float*` at an arbitrary byte offset. x86 tolerates
  it, RVV element-misaligned accesses raise SIGBUS on the K1 (notes3 saw the same), Linux does not emulate them.
  Scalar misaligned float accesses run at full speed on the X60 (6.49 vs 6.39 ns per load+store, one core).
  Affects every multi-process legacy run on the K1, UniformGridCPU too. Fix not chosen yet (asked the user).
- `docs/manual/reports/r04/` (new report 4, "RVV on waLBerla's Legacy Core"): the two stacks, legacy code generation,
  pystencils 1.4's vectorizer, upstream `rvv`, `rvv_ext`, the applications and both bugs, verification. Builds with
  `docs/manual/build.sh` (0 warnings).
- Bus error, the evidence (user: "not convinced, dig deeper"):
  - gdb on all 4 ranks of `pull_none`: `packDirection` gets buffer addresses `...6`/`...2` (mod 4 = 2) for every
    second block; the fault is `vsseg3e32.v v3,(t1)` with `t1 = 0x266ff6`, `vl = 1`. The misaligned face packs
    (dir 1, 3) pass, the first edge (dir 7, NW) faults.
  - Why mod 4 = 2: `UniformBufferedScheme::writeHeader` = `BlockID::toBuffer` (1 length byte + 1 ID byte here) +
    `buffer << dir` (4-byte enum) = 6 bytes, written with `memcpy` (`SendBuffer::put`). The generated
    `packDirection` then does `reinterpret_cast<float*>(outBuffer)` (upstream `LbmStorageSpecification.tmpl.cpp:136`).
  - Why only edges: in `packDirection` GCC made 108 scalar `fsw` (6 faces, 9 PDFs per cell: no segment store has 9
    fields), 24 `vsseg3e32.v` (12 edges, 3 PDFs) and 8 `vse32.v` (8 corners, 1 PDF).
  - Our changes: no walberla commit since the upstream pin `v7.2-88-g0c8ed8c9` and no uncommitted change touches
    `LbmStorageSpecification.tmpl.cpp`, `UniformGeneratedPdfPackInfo.h`, `UniformBufferedScheme.h`, `BlockID.h`,
    `SendBuffer.h`, `RecvBuffer.h`, `storage_specification.py`, `packing_kernels.py`. waLBerla-wind's own `LBM_CPU`,
    `LBM_CPU_CP`, `GeneratedApp_cpu_uniform` use the same pack info and scheme.
  - Minimal reproduction on the board (30 lines, the same 3-floats-per-cell loop into a byte buffer): `-O3
    -march=rv64gcv_zvl256b` or `-march=rv64gcv` → `vsseg3e32.v`, SIGBUS (`BUS_ADRALN`, `si_addr` = pc) at offsets 2
    and 6, ok at 0 and 4; `-march=rv64gc` → `fsw`, ok at every offset. One load: `vle8` at 1 or 3 ok, `vle32` at 2
    SIGBUS, at 4 and 12 ok, `vle64` at 4 SIGBUS, at 8 ok: element alignment is required, vector alignment is not.
  - Kernel 6.6.36: `CONFIG_RISCV_MISALIGNED=y` (scalar emulation), hwprobe does not know the vector misaligned key
    (-1); scalar misaligned perf reported "unknown", measured as fast as aligned. No core files left (apport keeps
    none for unpackaged programs).
  - Trigger: the V extension in `-march`. The board's GCC defaults to `rv64imafdc` (no V); upstream waLBerla's
    `OPTIMIZE_FOR_LOCALHOST` adds `-march=native`, which GCC 14 rejects on RISC-V. So upstream builds on the K1 have
    no vector code and never hit it; every RVV build does (our fork's GNU.cmake, or `scripts-legacy`'s flags).
- Upstream bug-fix patch (user: a patch based on upstream's release, not on our branches):
  `docs/bug-fix-pr/walberla-packinfo-buffer-alignment/` (patch, README with the PR text, `repro/reproduce.sh`,
  `repro/misaligned_pack.cpp`). Base: upstream v7.4 (`a7ac6d0b`, GitHub mirror `lssfau/walberla`; i10git was down
  with 502), applies unchanged to master `a99003fb`. Upstream already fixed the same problem for the pystencils_walberla
  pack infos in `bd5adb91` (2024-11-11) and documented in `UniformPackInfo` that implementations must align their data;
  `UniformGeneratedPdfPackInfo`, `NonuniformGeneratedPdfPackInfo` and `GeneratedNonUniformFieldPackInfo` do not. The
  patch adds `SendBuffer::forwardAligned<V>()` / `RecvBuffer::skipAligned<V>()` (reserve sizeof(V) more, `std::align`,
  the scheme of `bd5adb91`), uses them at 16 call sites, and tests them in `BufferTest` (119 lines added, 16 changed).
  - x86, `-fsanitize=alignment`: `InterpolationNoSlip` on 2 processes 108 misaligned `double` accesses in the generated
    packing kernels before, 0 after; `BufferTest` passes. The non-uniform tests show none before either: their header
    is 2(1+n)+4 bytes, 8 with one-byte IDs, so `double` data is aligned by chance. Unrelated report in every run:
    `field::aligned_malloc_with_offset` (`AlignedMalloc.cpp:85/98`), not changed.
  - K1, upstream v7.4 with `-march=rv64gcv_zvl256b`: `InterpolationNoSlip` on 2 processes exit 135 (bus error) before,
    ok after; `AdaptiveRefinement` 1/4 and `BufferTest` ok (2 h 26 min for both builds; logs in
    `/home/bananapi/saleh/legacy/upstream-pr/logs`, build trees removed).
  - `reproduce.sh` verified end to end on the laptop from a fresh clone and venv; `--quick` on the laptop and the K1.
  - Not yet decided: whether our walberla branch takes this patch for the K1 benchmark runs (the user decides).

## 2026-11-27

**Which ISAs crash on the misaligned buffers** (user's question). Undefined behavior on every ISA; a crash only where
element-misaligned vector accesses trap. Checked with the pack loops of `repro/misaligned_pack.cpp` (3 floats per
cell, 1 double per cell), GCC 16.2 and clang 23:
- x86 SSE2, AVX2 (`x86-64`, `x86-64-v3`): only unaligned stores into the buffer (`movups`/`vmovups`), run fine at
  offsets 0, 2, 4, 6; `-fsanitize=alignment` reports it. AVX-512 (`x86-64-v4`, `skylake-avx512`, `znver4`): only
  unaligned stores in the assembly; not run (the laptop has no AVX-512).
- AArch64 NEON/SVE: unaligned element accesses to Normal memory are allowed with Linux's `SCTLR_EL1.A = 0`; clang
  emits NEON `st3` for the edge loop, also with `+sve`. Assembly only (no ARM machine or sysroot).
- RVV 1.0: the specification lets an implementation trap; the X60 does, Linux 6.6 does not emulate it. Whether the
  SG2044 (monte3) traps is not tested.

**Alignment patch applied to walberla `rvv-support-legacy`** (user's decision; on top of the user's commit
`fb3a0b77`, uncommitted). `git apply -C1`: one context line differs in
`GeneratedNonUniformFieldPackInfo.impl.h` (`uint_t(1)` here, `uint_t{1}` in v7.4); same 119 added and 16 changed
lines as the patch. x86, `build/notes8-wind-x86` reconfigured and rebuilt (1 min 49 s, no new warnings): the
waLBerla-wind benchmark's checksums, 20 steps, are bit-identical before and after for `pull_none` and `aa_none` on 1
and 4 processes (`<128,128,64>`).

**waLBerla-wind commit redone** (the user's `50505f1` had all AppGenerator output). Unpushed, so `git reset HEAD~1`
and a new commit `341e634` in the user's name (user's request): the turbine data files (airfoils, blade, tower,
controllers; byte-identical copies of `GeneratedApp_cpu_uniform`'s) and the generated `input.prm` are left out,
their link lines removed from the app's `CMakeLists.txt`, the README says why. Checked: the benchmark runs from a
folder with only `benchmark.prm` and `windDirectionChange.wd`. New `.gitignore` with `__pycache__/` (code
generation without `PYTHONDONTWRITEBYTECODE` writes them into the tree, step 6). Old build trees keep dangling
symlinks to the removed files; harmless.

## 2026-11-28

**Banana Pi set up again** (the user emptied `~/saleh`, 16 GB free): `remote.py push` (428 MB, 48 s; the board's
copy has the same commits and uncommitted changes as the laptop, after `git checkout -- results-legacy` there:
`push` does not send `results-legacy/`, and git there saw the committed K1 run as deleted), `remote.py start setup`
(screen; venv as before), `remote.py start all wind` (screen `bench-all-wind`, with the alignment patch). The board's
other load is not ours: PolyBench/C 4.2.1 (`run_polybench_k1.sh LARGE 7 3` in `/home/bananapi/PolyBenchC-4.2.1`,
started 26 Nov 19:39 board time, one core busy), another user of the shared account.

**Step 8, monte3, prepared** (user: Python, clean, the same mechanism as the K1, but with slurm; the login node is
not RISC-V, so compiling needs a slurm job too). Nothing has run on monte3.
- `remote.py`: `--machine bananapi|monte3`; per machine a `Remote` (pushed copy, log folder, sbatch options).
  monte3: `start` = `sbatch --wrap "python3 scripts-legacy/bench.py --machine monte3 <args>"` with
  `--partition=peak --nodes=1 --exclusive --ntasks-per-node=64 --mem=0 --time=06:00:00`, refused while one of our
  `bench-` jobs is queued or running (`squeue --me`); `status` = `squeue --me` + newest log. On the login node only
  rsync, mkdir, date, sbatch, squeue run. The K1 clock hint (`sudo date`) is only offered for screen machines.
- `experiments.py`: `Machine` got `setup_python`, `vlen`, `modules`, `link_flags`, `pip_cache`, and `jobs=None`
  (one per core, at most one per 2 GB, from `/proc/meminfo`). monte3: cores 1 to 64, `-march=rv64gcv_zvl128b`,
  VLEN 128, mpirun `/opt/share/milkv/openmpi-5.0.6/bin/mpirun --bind-to core --map-by core`, modules `gcc-14.2.0`
  then `openmpi-5.0.6`, the rpath flags notes7 found necessary. Variant lists `ANY_VLEN`, `VLEN256` (K1, unchanged),
  `VLEN128`; experiments `wind-vlen128`, `ugc-vlen128`. (First version used notes7's Python and pip cache and
  `push.to.sh`; replaced, see "Self-contained" below.)
- `bench.py`: loads the machine's modules first (a bash sources the modules init, `env -0` back into the process)
  and stops if `mpicxx` is not next to the machine's `mpirun`; `configure` refuses fixed-VLEN variants of another
  VLEN (before the code generation) and passes `link_flags`; `setup` uses `pip_cache`; `all` runs `setup` if the
  venv is missing; each timing run is stopped after `RUN_LIMIT` = 600 s with its whole process group (SIGTERM,
  15 s, SIGKILL); `machine.cpus` is `len(os.sched_getaffinity(0))` instead of `os.cpu_count()` (no `/sys` read);
  `bench.json5` keeps `modules` and `link_flags`.
- Laptop-only dry run (scratchpad; fake modules init, fake MPI with 4 sleeping "ranks", fake app, fake `ssh`), with
  Python 3.14 and 3.11 (the node's system Python): VLEN refusals both ways; `rvv_ext-vls128-vf-fma-pf128` and the
  other names pass pystencils' `parse_options`; modules loaded and a missing MPI module refused; a hung run stopped
  after 3 s (limit lowered for the test) with no process left, a normal run parsed; the exact sbatch, squeue and
  screen commands printed. Audit: no frequency, governor, power, thermal, `/sys`; of `/proc` only `meminfo`,
  `loadavg` (and `cpuinfo` without `--machine`, never on monte3).

**Self-contained** (user: the scripts must not rely on anything that exists already or on other scripts; what is
missing they prepare).
- `remote.py push` does the rsync itself (`sync_repo`; `push.to.sh --repo`'s logic in Python: git lists what it
  ignores in the repository and each submodule, `results-legacy/` protected, `.claude/`, `.perfcache`, `*.zip`
  excluded as before since git does not ignore them) and makes the remote folder first (`mkdir -p`).
  `../push.to.sh` is no longer used by `scripts-legacy/`.
- `bench.py setup`: the venv's Python is the one running bench.py if it is 3.10 or newer with `ensurepip`
  (pystencils 1.4 and lbmpy 1.4 need 3.10; monte3's node has 3.11), else Python 3.12.11 built from python.org's
  source into `<work>/python-3.12.11`; pip's cache is `<work>/pip-cache`; `CC=gcc CXX=g++` for a numpy build from
  source. `Machine.setup_python` and `Machine.pip_cache` removed; monte3's venv is `~/02_ws/legacy/venv`.
- Laptop tests: `sync_repo` into a local folder (`build/push-test`, removed after): 428 MB in 3.2 s, the copy's
  commit and `git status` equal the original's for the repository and all three submodules, no ignored files,
  no `.claude/`, `results-legacy/`, `build/`, `00_private_data/`, venvs; a second sync (0.3 s) kept a run in the
  copy's `results-legacy/` and deleted a stale file. The dry run of before passes again with Python 3.11.
- Laptop test of the Python fallback (`ensurepip` made to look missing, work folder `build/python-fallback-test`,
  removed after): `setup` downloaded Python 3.12.11 from python.org, built it into `<work>/python-3.12.11`, made
  the venv on it and installed the packages, 97 s; the venv has ssl, sympy 1.12.1, lbmpy 1.4, pystencils from the
  submodule.

**K1 `all wind` with the alignment patch** (quick run `20261128-104228-013f7f`, timed run `20261128-104459-81179f`,
fetched). The patch fixes the multi-process runs: all 81 timed runs (9 variants, 1/4/8 processes, 3 rounds) end
normally; before, every 4-process run died with `Bus error` (`20261127-011820-469d71`). Medians (MLUP/s; the board
shared with another user's PolyBench job, one core busy):

| processes | `pull_none` | `aa_none` | `pull_rvv` | `aa_rvv` | `-vf-fma` | `-vf-fma-pf128` | `-vls256-vf-fma-pf128` |
|---|---|---|---|---|---|---|---|
| 1 | 0.51 | 0.55 | 0.71 | 0.50 | 0.62 | 1.06 | 0.65 |
| 4 | 1.93 | 2.04 | 2.57 | 1.87 | 2.25 | 3.87 | 2.44 |
| 8 | 3.63 | 3.73 | 4.81 | 3.33 | 3.94 | 6.55 | 4.47 |

Checksums: the scalar variants agree to 2e-9; every RVV variant differs from `pull_none` by 3.3e-6 (1 process),
3.1e-6 (4), 2.7e-6 (8) in sum(|u|²), above the then tolerance 1e-6, so the table says FAIL; the quick run (10 steps)
had 5.4e-7, so the difference grows by about 5e-8 per step. The RVV variants agree with each other to about 1e-9.
- Not RVV: the same kernel with pystencils' AVX (`pull_avx`, built on the laptop for this test only, then removed)
  gives sum(|u|²) = 757.683801, the RVV result to 1e-9, while x86 scalar gives 757.686311 (K1 scalar 757.686308).
  So pystencils' vector kernels drift from its scalar kernel the same way with AVX and with RVV.
- Not `powf`: the scalar kernel has `powf(x, 0.5f)` where the vector kernels have a square root; `powf` differs
  from `sqrtf` for 0.06 % of the floats in [1e-8, 10] (1 ULP, mostly up; same on the laptop and the K1), but
  replacing it by `sqrtf` (`LD_PRELOAD` shim, x86 scalar) moves sum(|u|²) by only 5e-9.
- Not FMA contraction: GCC fuses about 1060 multiply-adds in the scalar kernel, almost none in `pull_rvv`, about
  1700 in `aa_rvv_ext-vf-fma`, yet `pull_rvv` and `-vf-fma` agree to 1.2e-9.
- The vector select (`qr_r_prime > 0 ? qr_r_prime : 0`, `vmerge`/`vmfgt`) is right. Cause not found; it is in
  pystencils' vectorization, not in the RVV backends.
- `experiments.TOLERANCE[32]` raised from 1e-6 to 1e-5 (enough for about 200 steps; a wrong kernel differs by
  1e-3 or more). Runs keep the tolerance they ran with, so the fetched timed run still says FAIL in `bench.py table`.

**Animations** (user: an argument that makes an animation the goal instead of the speedup, since the output's load
could disturb the timing; a separate class). `scripts-legacy/animation.py`, class `Animation`; `bench.py animate
<experiment> [--variant] [--steps 2000] [--every 25] [--np 1]` and `bench.py render <folder>` (README, Animations).
- Both apps write VTK themselves, so no frame images come from the apps: UniformGridCPU has upstream's
  `Parameters.vtkWriteFrequency` (`vtk_out/vtk.pvd`); waLBerla-wind's `TurbineOutput` reads `Output.VTK` blocks,
  which waLBerla's command-line override creates (`-Output.VTK.writeFrequency=25 -Output.VTK.fields.velocity=1`), but
  the benchmark app's `main.cpp` never called the writer: it now adds it to the time loop only if an `Output.VTK`
  block exists (waLBerla-wind, uncommitted; app README updated). Without one (all timing runs) the time loop is as
  before: x86 `pull_none`, 10 + 60 steps, sum(|u|²) = 757.68631103396024 before and after, no VTK timer.
- `animate`: configure, build only the chosen variant (`bench.build` got an optional variant list), one untimed run
  (no warmup, no `RUN_LIMIT`) with the same command line as the timing (`bench.app_command`, split out of
  `time_one`) plus the VTK option, in `<work>/animations/<time>-<random>/` with `animation.json`, `app.log`,
  `vtk_out/`. `render`: in the venv (installs pyvista and matplotlib if missing; no VTK wheels for riscv64, so the
  boards' animations are rendered on the laptop after `remote.py fetch`, which now also copies
  `<work>/animations/`): the x-z slice through the middle, |u| for waLBerla-wind, u_x for UniformGridCPU (its shear
  is in z: u_x = ±0.005 above/below the middle), PNG per frame and a GIF.
- Laptop tests: `animate wind-x86` (2000 steps, 81 frames, 325 MB, 100 s) and `render` (12 s; 1.4 MB GIF): the log-law
  profile with the initial perturbation at mid-height growing into eddies. `animate ugc-x86` (80 frames): the two
  shear bands diffusing. `animate wind-x86 --np 4`: four blocks, one seamless 128 x 64 slice. `remote.py fetch`
  against the Banana Pi with no animations there: fine (`--ignore-missing-args`).

**Names** (user: self-explanatory, `<backend>.our<i>` / `<backend>.lgcy`, then the rest). Variant names are now
`<streaming>_<backend>[-<option>...]` with backend `none`, `<isa>.lgcy` (pystencils 1.4's own) or `<isa>.our<N>`
(ours): `pull_rvv.lgcy`, `aa_rvv.our1-vf-fma-pf128`. `_`, `.` and `-` each have one job (README, Names, with the
list of backends; a new one of ours gets the next number, a name is never reused).
- pystencils (our branch, uncommitted): `riscv_ext_instruction_sets.py` -> `riscv_our1_instruction_sets.py`
  (`get_vector_instruction_set_riscv_our1`, `parse_options` takes `rvv.our1[-...]`), headers
  `riscv_v_ext_{vls128,vls256,prefetch}.h` -> `rvv_our1_*.h` (C helpers `rvv_our1_prefetch_read/write`);
  `simd_instruction_sets.py` strips `.lgcy` (so `rvv.lgcy` is pystencils' unchanged `rvv`, `avx.lgcy` its `avx`) and
  picks `rvv.our1` by the part before the first `-`. Renamed with plain `mv` (nothing staged). Nothing else in
  pystencils, lbmpy or pystencils_walberla compares the name; CMake uses it as a folder name and in target names,
  which allow `.`.
- `tests/test_rvv_qemu.py`: `rvv.lgcy` instead of `rvv` under QEMU, and `rvv.lgcy` must print exactly `rvv`'s code.
- `scripts-legacy`: `Vectors.RVV_LGCY = "rvv.lgcy"`, `Vectors.RVV_OUR1 = "rvv.our1"`; `instruction_set()` uses the
  member's value. Comments and examples in walberla's UniformGridCPU, waLBerla-wind's app, `scripts/notes8`.
- Old runs keep their labels (`pull_rvv`, `aa_rvv_ext-...`). The next K1/monte3 build makes new targets (all
  vector variants recompile, about 3 h on the K1); the old executables stay in the build trees, unused.

**Backends compared** (K1, waLBerla-wind, float32, timed run `20261128-104459-81179f`; its labels are the old ones,
here in the new names). Median MLUP/s:

| variant | backend | 1 process | 4 | 8 |
|---|---|---|---|---|
| `pull_none` | scalar | 0.51 | 1.93 | 3.63 |
| `aa_none` | scalar | 0.55 | 2.04 | 3.73 |
| `pull_rvv.lgcy` | pystencils' own | 0.71 | 2.57 | 4.81 |
| `aa_rvv.lgcy` | pystencils' own | 0.50 | 1.87 | 3.33 |
| `aa_rvv.our1-vf` | ours | 0.57 | 2.10 | 3.73 |
| `aa_rvv.our1-fma` | ours | 0.52 | 1.91 | 3.45 |
| `aa_rvv.our1-vf-fma` | ours | 0.62 | 2.25 | 3.94 |
| `aa_rvv.our1-vf-fma-pf128` | ours | 1.06 | 3.87 | 6.55 |
| `aa_rvv.our1-vls256-vf-fma-pf128` | ours | 0.65 | 2.44 | 4.47 |

- Same streaming pattern (AA): our best is 2.1x, 2.1x, 2.0x `aa_rvv.lgcy`; even `-fma` alone is a little faster.
  `aa_rvv.lgcy` is slower than scalar `aa_none`.
- Best against best: `aa_rvv.our1-vf-fma-pf128` is 1.5x, 1.5x, 1.4x `pull_rvv.lgcy`. Not like for like: ours are all
  AA, and for `rvv.lgcy` pull is much faster than AA (0.71 against 0.50), so part of it may be the streaming pattern
  (a `pull_rvv.our1-vf-fma-pf128` variant would tell).
- Prefetch carries most of it: `-vf-fma` gains about 70 % from `-pf128`; without prefetch ours is below
  `pull_rvv.lgcy`.
- `vls256` (vector-length specific) is much slower than the same VLA variant (0.65 against 1.06); not investigated.
- The board was shared with another user's PolyBench job (one core busy): indicative numbers. All RVV variants agree
  with each other to about 1e-9 (checksums).

**Documented** (user: document all this in the READMEs and the progress file).
- `scripts-legacy/README.md`: Names (convention, list of backends, old names), vector length (VLA against `vls`, the
  guard header, `configure`'s VLEN check), Adding a benchmark (an experiment of a known app: only `experiments.py`;
  a new app: the places in `bench.py`; one experiment per command and one job at a time), The checksum (tolerance
  1e-5 and why), Animations, `fetch` (runs, logs, animations).
- `README.md` (top): a notes8 section (plan step 9). waLBerla-wind's app README: the VTK hook and the names.
  `docs/bug-fix-pr/.../README.md`, Testing: the K1 benchmark before and after the patch.
- The plan: §3.2 renamed, §3.7 (names, checksums, animations, MPI buffers), step 7 status, §5 like for like, §7 the
  `vls256` slowdown and the checksum drift.

**Backend 1 (`rvv.our1`): files, options and what has been run** (state of 2026-11-28). One backend whose
behaviour is chosen by options in its name, `rvv.our1[-vls<N>][-m<L>][-vf][-fma][-pf<N>]`; every option set is a
variant of it, all from the same code.

| file (pystencils submodule) | role |
|---|---|
| `backends/riscv_our1_instruction_sets.py` (about 250 lines) | `parse_options()` reads the name; `get_vector_instruction_set_riscv_our1()` builds pystencils' instruction table for those options (`vf` and `fma` through the operator templates, no printer change) |
| `include/rvv_our1_vls128.h`, `rvv_our1_vls256.h` | guard: the build stops unless `-march` promises that VLEN (`zvl128b`/`zvl256b`) |
| `include/rvv_our1_prefetch.h` | `rvv_our1_prefetch_read/write` (Zicbop `prefetch.r`/`.w`, HINT encoding, no-ops without Zicbop) for `pf<N>` |
| `backends/simd_instruction_sets.py` (upstream file, a few lines) | sends `rvv.our1...` to our module and `<isa>.lgcy` to pystencils' own |

| option | values | effect |
|---|---|---|
| `vls128`/`vls256` | none (VLA), 128, 256 | fixed vector length instead of vector-length agnostic |
| `m2`/`m4` | 1, 2, 4 | LMUL: each vector spans 1, 2 or 4 registers |
| `vf` | off/on | an operand equal in every lane is passed as a scalar (`vfadd.vf`) instead of being splatted |
| `fma` | off/on | `a*b + c`, `c - a*b`, `a*b - c` become `vfmacc`, `vfnmsac`, `vfmsac` |
| `pf<N>` | off or a distance in bytes | prefetch N bytes ahead of every vector load and store |

Without options `rvv.our1` prints exactly `rvv.lgcy`'s code (golden test), so every gain is measured against
pystencils' own backend. The options combine freely: 3 vector-length modes × 3 LMULs × `vf` × `fma` × prefetch
on/off are already 72 sets, more with other prefetch distances.

| | variants |
|---|---|
| checked under QEMU (`tests/test_rvv_qemu.py`) | VLA at VLEN 128, 256, 512: no options, `vf`, `fma`, `vf-fma`, `pf128`, `m2`, `m4-vf-fma-pf128`; VLS: `vls128` (VLEN 128, 256), `vls256` (256), `vls256-m2-vf-fma-pf128` (256) |
| benchmarked on the K1 (wind, all AA) | `vf`, `fma`, `vf-fma`, `vf-fma-pf128`, `vls256-vf-fma-pf128` |
| set up for monte3 | the same, with `vls128` instead of `vls256` |
| never measured | `m2`/`m4`; `pf` alone or at other distances; any `pull_` variant of ours |

Not built (plan §3.2): row pointers and `in_register`. The streaming pattern (`pull`/`aa`) is not part of the
backend; it is chosen separately and goes in front of the name (`aa_rvv.our1-vf-fma`).

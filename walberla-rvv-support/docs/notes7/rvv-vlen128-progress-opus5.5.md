# Progress (Opus 5.5): one RVV backend for VLEN 128 and 256, tuning knobs, the monte3 script

Plan: [`rvv-vlen128-plan-opus5.5.md`](rvv-vlen128-plan-opus5.5.md). Nothing is committed (the user commits).

## Resume here

- 2026-11-21: steps 1-3 of the plan are implemented and tested on the laptop (pystencils tests, QEMU at VLEN 128 and
  256, the CMake VLEN probe through QEMU, the LDC generator outside CMake, dry runs of the script with stubbed
  `ssh`/`rsync` and of the timing logic with fake executables). First monte3 run failed at its first write (see "monte3 runs"); fixed.
- Next: the user runs `bash scripts/notes7/monte3.sh start` on the laptop (it pushes, then submits the build job and
  the timing job), follows it with `status`, and copies the results with `fetch` (to `00_private_data/monte3/`).
  The first build job shows the real build time (the 6 h limits are generous guesses; `TIME_BUILD`, `TIME_RUN`).
- Open: K1 rebuild with the new code (optional: the kernels are byte-identical, see step 2); LMUL/prefetch sweeps
  (future work, plan §3).

## monte3 runs

- Run 20261121-142100 (build job 8547, timing job 8548): the build job failed at once. sbatch runs a copy of the
  script from slurm's spool folder (`/var/lib/slurm/slurmd/job08547/slurm_script`), and `monte3.sh` derived its paths
  from `$0`, so they pointed to `/var/lib/...`; the first `mkdir` there failed (no permission, nothing written). The
  timing job stayed pending with `DependencyNeverSatisfied`. Fix: in the job modes the repo is `SLURM_SUBMIT_DIR`
  (`submit()` starts sbatch from the repo root), and `node_env` refuses to run unless every path is under `$HOME` and
  `REPO` is the repo copy. Tested on the laptop with a spool-style copy (paths resolve to the home's `02_ws`; a wrong or
  missing submit directory is refused before any write). presentation6's `peak.sbatch` already did this; the laptop
  dry run had started the script from its real location, so it could not catch it.

- Run 20261121-142513 (build job 8549, 14:25-17:03; timing job 8550 cancelled by slurm through
  `--kill-on-invalid-dep`): `BUILD FAIL`, 18 failures, logs in `00_private_data/monte3/20261121-142513/`.
  - **GCC 14.2: all 11 variants pass, f64 and f32** (`verify-gcc-*.log`: VERIFY PASS, 11 executables, the four
    reference-solution cases and the decomposition check each), including the five explicit RVV variants built for
    VLEN 128: compile lines end in `-march=rv64gcv_zvl128b`, CMake measured VLEN 128, 900-2240 vector instructions in
    the generated sweeps. First evidence that the VLEN-128 code is correct on the SG2044.
  - Clang 17: scalar and autovec pass (VERIFY PASS, 6 executables each); the five explicit variants do not build, in
    f64 and f32 (10 failures). The error lines were not in the job output (fixed: the first 10 now are); to find out.
  - The 8 GCC-vs-Clang comparisons failed because the comparison asked for the missing Clang explicit dumps (my port
    listed every variant; presentation6 compared only existing dumps). Fixed: only existing Clang dumps.
  - Clang 17's error (user, from the build log): `__riscv_vcreate_v_f32m1x4` / `__riscv_vcreate_v_f64m1x2` undeclared
    in `rvv.hpp` (the Philox random-number functions; `vcreate` exists from Clang 18, the K1 had 18). The LBM kernels
    do not use random numbers, but every kernel includes the header. Fix: the `random` namespace of `rvv.hpp` is left
    out for Clang < 18 (kernels with random numbers do not compile there, all others do; GCC and Clang >= 18 see the
    same code as before). Checked with the laptop's Clang posing as 17 (`-D__clang_major__=17`): a kernel without random
    numbers compiles, one with them fails at `random::`; as a newer Clang both compile. RVV tests: 154 passed.

## Step 1: pystencils (fork `submodules/pystencils`)

Changed: `codegen/target.py` (component flags `_VLEN128`, `_VLEN256`; targets `RISCV_RVV256`, `RISCV_RVV128`, alias
`RISCV_RVV = RISCV_RVV256`; `Target.rvv_vlen()`; default lanes 128 → like SSE, 256 → like AVX), `codegen/config.py`
(`cpu.vectorize.rvv_lmul`), `codegen/cpu_loop_strategies.py` (lanes × LMUL; errors for LMUL ∉ {1,2,4}, non-RVV
targets, LMUL together with `lanes`), `codegen/driver.py` (`Target._RVV in target` → `RvvCpu(ctx, vlen)`),
`backend/platforms/rvv.py` (VLEN parameter of `RvvCpu` and `SelectIntrinsicsRvv`; `_lmul` generalised to mf8…m8
with the ELEN rule; RNG LMUL 1 only), `include/pystencils_runtime/rvv.hpp` (VLEN macro `PYSTENCILS_RVV_VLEN`,
default 256; guard against it; `set_*`/`horizontal_*` for all group sizes; `ctr64_to_32` from the VLEN), new
`rvv_vlen128.hpp`, `jit/cpu/compiler_info.py` (`-march=rv64gcv_zvl<VLEN>b` by target).

Deviations from the plan (simpler, same effect):
- **No `rvv_vlen256.hpp`:** VLEN 256 keeps including `rvv.hpp` (whose macro defaults to 256), so K1 code does not change
  even by one include line. Only VLEN 128 includes a wrapper (`rvv_vlen128.hpp` sets the macro, then includes rvv.hpp;
  it refuses a second VLEN in the same translation unit).
- **Reduction lane counts from the macro, not a template argument:** `horizontal_*` compute their lane count from
  `PYSTENCILS_RVV_VLEN` (the VLEN the code was generated for, never `__riscv_v_min_vlen`), so the generated reduction
  calls stay unchanged.
- **The platform takes only `vlen`:** LMUL follows from the vector width (`lanes × bits / VLEN`), so `rvv_lmul` only sets
  the lane count in the loop strategy.
- A side effect of the generalised `_lmul`: vectors wider than one register, which raised before, are now legal (e.g.
  an f32 kernel casting to f64 gets `m2`). Code that compiled before is unchanged.

Tests (laptop, `.venv-rvv`, `PYTHONPATH=src`, `-o addopts=""`):
- `test_rvv_codegen.py`, `test_rvv_target.py`: 96 tests passed before the change. After it, the only failures were the
  two "wider than a register" cases that LMUL makes legal (moved to the new grouped-type cases); every exact code
  string at VLEN 256 still matches. New: VLEN-128 types and lanes, header, LMUL 2/4 types and steps, casts across
  groups, LMUL errors, Philox at LMUL 2 refused, JIT flags and default lanes for `RISCV_RVV128`; the cross-compile test
  now also runs every kernel for VLEN 128 and for LMUL 2 (32 cases, `riscv64-linux-gnu-g++` 16.2.1).
- New `test_rvv_qemu.py`: six kernels (stencil f64/f32, f32→f64 cast, loop-counter constants, f64 sum, f32 max) on a
  5 × 23 grid, cross-compiled with `-static`, run under `qemu-riscv64 -cpu rv64,v=true,vlen=N` and compared with the
  same kernels for `GenericCPU` run through the host JIT: RVV256/LMUL1 at 256, RVV128/LMUL1 at 128, RVV128/LMUL2 at 128,
  RVV256/LMUL2 at 256, RVV128 code at vlen 256: all pass; VLEN-256 code with `zvl128b` refuses to compile. Control:
  VLEN-256 code run at vlen 128 gets 30-55 of 115 cells wrong per kernel and a wrong sum (kept as a test).
- `rvv.hpp` alone: compiles with `zvl256b` (default) and refuses `zvl128b`; `rvv_vlen128.hpp` compiles with both.
- Broad regression (`tests/nbackend tests/codegen tests/kernelcreation tests/jit`): 884 passed, 260 skipped, 16
  xfailed; one collection error, `test_gpu.py` (needs scipy, not installed in this venv; unrelated).
- Total RVV tests: 154 passed.

## Step 2: waLBerla (fork `submodules/walberla`)

Changed: new `cmake/compileroptions/RiscvVlen.cmake` (cache `WALBERLA_RISCV_VLEN`; `try_run` of an inline probe that
reads `vlenb` by CSR number 0xc22, so it needs no `-march`; only when the ISA has `v`; 128/256 only),
`GNU.cmake`/`Clang.cmake` (`-march=rv64gcv_zvl${WALBERLA_RISCV_VLEN}b`), `sweepgen/cmake/SweepgenConfig.template.py`
and `sweepgen/src/sweepgen/build_config.py` (`riscv_vlen`; the CPU target becomes `RISCV_RVV128`/`RISCV_RVV256` when
optimizing for the local host), apps `SweepgenLdcCPU.py`, `SweepgenLbmCPU.py` (explicit variant defaults to the build
config's target instead of `CurrentCPU`; new `--rvv-lmul`; docstrings). The 11 CMake variants are unchanged.

Tests (laptop):
- The probe module in a small cross-compiling CMake project with QEMU as `CMAKE_CROSSCOMPILING_EMULATOR`: measures 128
  at vlen 128 and 256 at vlen 256, honours `-DWALBERLA_RISCV_VLEN=128`, rejects 512.
- The LDC generator outside CMake with config modules like CMake's (riscv_vlen 128 / 256), against the committed code
  (exported with `git archive`, run with `--explicit-target=RISCV_RVV`), variants `explicit_cse_aa_pf` and
  `explicit_cse_aa_split`: at VLEN 256 all 9 generated kernel namespaces are **byte-identical** and the files contain the
  same lines. Only the order of the wrapper's field-declaration blocks differs, and it differs between two runs of the
  committed code too (sweepgen's wrapper code is not deterministic from run to run: a pre-existing property, not this
  change). At VLEN 128 the sources include `rvv_vlen128.hpp` and use `f64m1` with `2uLL`; with `--rvv-lmul=2`, `f64m2`
  stepping by 4.
- On a monte3 build the scalar trees keep their `-march=rv64gc` (`CMAKE_<LANG>_FLAGS_RELEASE` still come last), and no
  generated scalar or autovec file includes the RVV header (checked in presentation6's monte3 f64 trees, whose build
  target already resolved to the RVV platform).

## Step 3: `scripts/notes7/`

`monte3.sh` (one file: laptop commands `start [all|build|time]`, `status`, `fetch`, `help`; job modes `job-build`,
`job-time`) + copies of `ldc_reference.py`, `compare_fields.py`. Uses only `push.to.sh` otherwise. `push.to.sh`
excludes `/00_private_data/`, `.gitignore` ignores it, `scripts/README.md` has a row.

- Build job: module gcc-14.2.0; Python 3.12.11 from source and the venv if missing (presentation6's are reused); per
  precision f64, f32 and compiler GCC, Clang: scalar tree (`-march=rv64gc` in every file) and vector tree (waLBerla's
  flags with the measured VLEN), all 11 variants one at a time, regenerated each time; audit per variant (generated
  sweeps' last `-march` and `-O3`, 0 vector instructions in scalar executables, >0 in explicit sweeps); verification
  as presentation6 (four reference-solution cases, wall links, decomposition 1 × 32³ vs 8 × 16³ bit-identical) with the
  sha256 of every executable in `verify-<cc>-<prec>.log`; GCC vs Clang. Ends with `BUILD PASS`/`BUILD FAIL`; copies the
  verify logs to `~/02_ws/notes7/verified/`.
- Timing job (starts only after a successful build job): presentation6's protocol at 1/4/8/16/32/64 processes and the
  fair pair; refuses executables whose sha256 is not in the verify log; records load and busy cores before each
  round (no frequency or temperature); best-of table; ends with `TIME DONE`.
- Laptop tests: `help`, guards (`job-build` outside slurm, unknown command, `status` before any `start`); dry run of
  `start` / `start time` / `status` / `fetch` with stubbed `ssh` and `rsync` (exact `sbatch` lines, dependency only when
  both jobs are submitted, state file, log paths); the timing job with fake executables (verified groups timed,
  interleaved rounds, `SWEEPGEN_LDC_OUTPUT=last` for the fair pair, a group with a mismatching sha256 skipped,
  unverified compilers/precisions skipped, best-of table).

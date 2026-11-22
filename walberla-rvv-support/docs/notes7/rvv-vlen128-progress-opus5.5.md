# Progress (Opus 5.5): one RVV backend for VLEN 128 and 256, tuning knobs, the monte3 script

Plan: [`rvv-vlen128-plan-opus5.5.md`](rvv-vlen128-plan-opus5.5.md). Nothing is committed (the user commits).

## Resume here

- 2026-11-21: steps 1-3 of the plan are implemented and tested on the laptop (pystencils tests, QEMU at VLEN 128 and
  256, the CMake VLEN probe through QEMU, the LDC generator outside CMake, dry runs of the script with stubbed
  `ssh`/`rsync` and of the timing logic with fake executables). First monte3 run failed at its first write (see "monte3 runs"); fixed.
- 2026-11-22: run 20261121-183343: **BUILD PASS** (all 44 executables verified), but the timing job hung at its first
  16-process run and slurm killed it after 6 h. MPI tests (jobs 8555-8563) found the cause: the **system Open MPI
  4.1.5** (a helper thread spinning at 100 % CPU in every process: half of each core, ~10 ms per message, hangs). The
  **milkv module `openmpi-5.0.6`** works (laptop-speed messages, helper at 0 %, 2-64 processes pass). See "MPI on
  monte3" below.
- 2026-11-22, cleanup (user's request): every monte3 script uses `openmpi-5.0.6` (`monte3.sh`; presentation6's
  `setup.sh` default modules); the `mpicheck` mode and `mpi_check.c` are gone (`mpitest` with `mpi_bench` covers
  them, and is the timing job's MPI check); `mpitest` lost its diagnostic options (`--mpi`, `--mpi-module`); new build
  folder `~/02_ws/notes7/openmpi-5.0.6/` (the old 4.1.5 trees in `~/02_ws/notes7/build-*` are no longer used and can be
  deleted by the user). Tested on the laptop only.
- **Next** (the user decides and runs it; never run anything on monte3 without asking the user): a full run with the
  new MPI, `bash scripts/notes7/monte3.sh start` (build job, 6 h limit, ~2.5 h; then timing job, 8 h limit), `status`,
  `fetch`. All earlier monte3 timings (system MPI) are replaced by it.
- Open: K1 rebuild with the new code (optional: the kernels are byte-identical, see step 2); LMUL/prefetch sweeps
  (future work, plan §3).

## MPI on monte3 (decision, 2026-11-22)

| | system Open MPI 4.1.5 | milkv `openmpi-5.0.6` |
|---|---|---|
| where | openEuler package `openmpi-4.1.5-5.oe2403`, `/usr/bin/mpirun`, `/usr/lib64/openmpi` | module, `/opt/share/milkv/openmpi-5.0.6` (built on the cluster) |
| helper thread, one core per process | spins at 100 %: main 50 %, helper 50 % (job 8560) | 0 % (jobs 8562, 8563) |
| ring 1 KiB / 64 KiB, 4 processes | 10,000 us / 30,000 us | 9.6 us / 209 us |
| hangs | waLBerla 16 processes 64^3 (jobs 8552, 8555); alltoall (8555, 8560) | none at 2-64 processes, all patterns (8563) |

Since then every monte3 job loads `gcc-14.2.0`, then `openmpi-5.0.6`. Monte3 timings made with the system MPI
(job 8552) are not used: their compute probably ran on half a core.

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

- Run 20261121-183343 (build job 8551, 18:33-20:56; timing job 8552, 20:56-02:56, killed by slurm at its 6 h
  limit). Logs in `00_private_data/monte3/20261121-183343/`.
  - **Build: BUILD PASS, 0 failures.** GCC 14.2 and Clang 17 (with the `vcreate` fix), f64 and f32, all 11 variants
    each: audits pass (explicit sweeps `-march=rv64gcv_zvl128b`, VLEN 128, Clang f32 explicit 650-2856 vector
    instructions in the generated sweeps), VERIFY PASS in all four `verify-*.log`, GCC vs Clang PASS in both
    precisions. First complete evidence that the VLEN-128 code is correct on the SG2044 with both compilers.
  - **Timing: not too long, but a hang.** gcc f32 at 1, 4 and 8 processes ran normally (each group of 3 rounds 2-3
    min). The first 16-process run (gcc scalar f32, `mpirun -np 16 --bind-to core --map-by core`, 21:18:21) never
    returned and printed nothing; the job sat in it for 5.6 h. The scalar build hangs too, so the RVV code is not the
    cause. 16 was the first run with more than 8 processes on monte3 ever (verification uses at most 8, presentation6
    never timed above 8). On the laptop (Open MPI 5.0.11) presentation4's x86 build of the same app runs at 16 and
    32 processes, also with 64^3 blocks (4x2x2 blocks, 256x128x128 cells): the app's decomposition and halo exchange
    are fine at 16; the suspect is monte3's MPI (system Open MPI 4.1.5) above 8 processes. Cause not known yet.
  - Valid numbers (gcc f32, best of 3, MLUP/s all processes together; `ldc-gcc-*-f32-{1,4,8}core.log`):

    | variant | 1 | 4 | 8 |
    |---|---|---|---|
    | scalar | 1.96 | 8.17 | 15.47 |
    | scalar_cse_aa | 3.44 | 15.09 | 24.53 |
    | autovec_cse_aa | 3.44 | 14.02 | 25.95 |
    | explicit_cse | 4.54 | 12.58 | 23.74 |
    | explicit_cse_aa_pf | 5.29 | 15.38 | 30.96 |
    | explicit_cse_aa_split | 8.31 | 21.73 | 39.70 |

    explicit_cse_aa_split over scalar_cse_aa: 2.4x (1 process), 1.4x (4), 1.6x (8). GCC's autovec is no faster than
    scalar. (Fair pair, Clang and f64: not reached.)
  - Changes to `monte3.sh` (2026-11-22), all tested on the laptop only:
    - `limited <s> <cmd>`: every timing and verification run is stopped after `RUN_LIMIT` (300 s; the longest normal
      run takes well under a minute). Before stopping it lists the run's own process tree twice, 5 s apart (state,
      core, CPU time, wchan: spinning or waiting?), then SIGTERM to mpirun (which passes it on to the ranks) and 15 s
      later SIGKILL to the tree as it was. A watchdog subshell with a USR1 handshake tells "ended in time" from
      "stopped" without a race; no overhead for a normal run.
    - Timing job: first `mpi_check.c` (new; init, cores, both ring neighbours 1 KiB-4 MiB with checked bytes,
      alltoall 64 KiB, allreduce; rank 0 prints each phase so a hang shows where) at 4-64 processes (`MPI_LIMIT`
      60 s each); counts that fail are not timed. A HUNG run ends its group, and the larger counts of that compiler
      and precision are skipped (worst case 4 x ~5.5 min instead of 6 h).
    - `start mpicheck` / `job-mpicheck` (limit `TIME_CHECK` 00:40:00, worst case ~30 min): Open MPI components
      (`ompi_info`), then per count 2-64 the bare launch (`true` with `--report-bindings`) and the MPI test; at the
      first failing count the MPI test again with `--mca pml ob1`, plus `btl_vader_single_copy_mechanism none`, plus
      `btl self,tcp`, and `--bind-to none`; then the GCC f32 scalar build at 16 processes, 8^3 and 64^3 blocks (with
      the default flags, and if they fail with the first option that passed). Only diagnosis: the timing runs keep
      `--bind-to core --map-by core`.
    - Laptop tests: `limited` alone (normal exit code kept, a hang returns 124 after limit + 20 s, also with a
      command that ignores SIGTERM, no process left); `job-time` and `job-mpicheck` with a fake home in the
      scratchpad, a wrapper around the laptop's mpirun (oversubscribed) that simulates mpi_check hanging at >= 32
      processes unless `--bind-to none`, and fake executables that hang at 16 processes unless unbound: preflight
      keeps 1 4 8 16, the 16-process group is stopped and the rest of 16 skipped, fair pair runs, sha256 guard
      refuses changed executables; mpicheck finds that only `--bind-to none` helps in this simulation, the app passes
      with it; no process left. The first mpicheck dry run found a bug (an alternative `--bind-to none` was appended
      to `--bind-to core`, which Open MPI refuses): fixed, alternatives now replace the flags. `start mpicheck`,
      `status`, `help`, bad arguments with fake `ssh`/`rsync`/`push.to.sh` (exact sbatch line, state file).
  - Change requested by the user (2026-11-22): a failed MPI case is an error, not a skip. Where the preflight's MPI
    test fails, `time-<job>.out` gets an `ERROR:` block that says in words what went wrong per process count
    (`mpi_explain`: hung or exit code, and how far the test got: before MPI was up / collecting core numbers /
    neighbour exchange / alltoall / allreduce / corrupted bytes; on an exit, Open MPI's own message). Every experiment
    at such a count is `FAILED (not run)` with the reason (also in its `ldc-*.log`); after a hung run
    (`FAILED (hung)`), the rest of that compiler/precision from that count up is `FAILED (not run)` too. The job
    ends with the list of failures and `TIME FAIL ...: N experiment(s) failed` (exit 1), else `TIME DONE`. SKIPPED
    stays only for executables the build job did not verify (listed separately, counted per reason). Laptop dry run
    (fake mpirun: MPI test hangs at 32 processes, "not enough slots" at 64; fake executables hang at 16): ERROR block
    for 32 and 64, gcc f32 timed at 1/4/8, 16 hung, 27 failures listed, TIME FAIL, exit 1, no process left.
- Run 20261122-074404 (mpicheck job 8555, 18:18-18:35): launch and binding fine at 2-64 (rank r on core r);
  `mpi_check` passes at 2 and hangs at 4-64 after rank 0 finished the ring exchange, with every setting tried at 4
  (ob1, no single copy, TCP only, no binding); every rank at 100 % CPU (state R, CPU time = wall time: busy-waiting,
  not slow). The waLBerla app (GCC f32 scalar) at 16 processes: 8^3 blocks pass (0.14 s), 64^3 blocks hang (the
  hang of job 8552, reproduced in 2 min). Contradiction: the app ran 66 times at 4 and 8 processes in job 8552, so
  mpi_check trips over something the app does not; and its "hung in MPI_Alltoall" only reflects rank 0's progress.
  Not usable yet as the timing job's preflight (it would fail 4 and 8, which work): open decision.
- `mpi_bench.cpp` + `start mpitest` (2026-11-22, the user's idea: a simple C++ MPI program with knobs): patterns
  ring / halo (3D grid from MPI_Dims_create, face+edge neighbours like D3Q19, all at once) / alltoall / allreduce /
  barrier; `--bytes`, `--repeats` or `--seconds` (calibrated by doubling, slowest rank decides), `--warmup`,
  `--no-check`, `--trace` (each rank prints enter/leave per step), `--hang-rank` (test hook). `start mpitest [--np
  LIST] [--mpi LIST] [--limit S] [mpi_bench options]` checks every option on the laptop before pushing (only letters,
  digits, dots, commas travel through ssh), derives the job's time limit (runs x (limit + 25 s) + 5 min, at most
  4 h), and the job prints PASS with one line per step or FAIL in words; for a hang, which ranks were stuck in which
  step (`trace_summary`). Named MPI settings (`mpi_opts`): default, ob1, nosinglecopy, tcp, basiccoll, nobind (also
  used by mpicheck now). Laptop tests: mpi_bench at 1/2/4/16 processes, all patterns, data checked; `--seconds 0.5`
  gives 0.42-0.52 s per step; bad options exit 2; trace and hang hook; the job mode with the laptop's MPI (6 runs
  PASS; a staged hang at 16 reported as "16 of 16 ranks were stuck inside the step halo bytes=65536"); the summary
  on a made-up mixed trace (never started / inside / finished-then-stuck, rank ranges); `start mpitest` with fake
  ssh/push: sbatch line and time limit, 8 kinds of bad options refused before the push.
- Run 20261122-202713 (mpitest job 8559, 20:27-20:28, `--np 4,8,16 --pattern ring,halo --bytes
  1K,8K,32K,64K,128K,1M --repeats 50`): MPITEST PASS, all data right, no hang (the plain halo pattern at 16 does not
  reproduce the app's hang). But every exchange takes ~10.0 ms for 1-32 KiB and ~30 ms for 64 KiB-1 MiB (halo 1 MiB
  at 16: 84 ms), at 4, 8 and 16 alike; the laptop: ~10 us and ~150-230 us. The steps of 10 ms look like each message
  waits for the 10 ms scheduler tick, e.g. two busy threads taking turns on one core (MPI helper thread pinned with
  the rank); with all ranks at 100 % CPU and mpirun at 100 % (job 8555). Hypothesis, not shown. waLBerla's t_comm in
  job 8552: 20-25 ms per step at 4 and 8 processes (K1, f64, 8 processes: 12-17 ms); consistent, no proof (t_comm
  includes waiting for neighbours).
- Added for the next test: `mpi_bench` prints after each step the CPU share of each of rank 0's threads (from
  /proc/self/task: this process's own entries only), and at the end the busiest helper thread over all ranks; MPI
  setting `pe2` (`--bind-to core --map-by slot:PE=2`, two cores per process, at most 32 processes, checked on the
  laptop). Laptop: main thread 99-100 %, helper 0 %; pe2 binds rank r to two cores and passes. Proposed:
  `start mpitest --np 4 --mpi default,nobind,pe2,ob1,tcp,basiccoll --pattern ring,alltoall --bytes 1K,64K --repeats 20
  --limit 60` (job limit 13.5 min): if pe2/nobind remove the 10 ms and a helper thread shows ~100 %, the cause is a
  spinning helper thread sharing the rank's core; alltoall shows whether mpi_check's hang reproduces, and where.
- Run 20261122-203444 (mpitest job 8560, 4 processes, ring/alltoall 1K/64K): **cause of the 10 ms found**. Every
  MPI process (system Open MPI 4.1.5) has a helper thread that spins at 100 % CPU; with one core per process it shares
  the rank's core 50/50 (main 50 %, helper 50 %) and each message waits for the 10 ms turn (ring 1K 10,000 us, 64K
  30,000 us). With room for the helper (nobind, pe2): ring 1K 88-98 us, 64K 760-920 us, helper ~100 % on its own
  core. ob1 and tcp change nothing (not the transport, not libfabric). basiccoll: all 4 ranks hung inside
  alltoall 1K (a real hang besides the slowness). If the waLBerla app has the same thread, its compute also ran on
  half a core (hint: monte3 1-process scalar_cse_aa f32 3.44 MLUP/s vs K1 2.11).
- The user checked the modules on mc-peak-2 (2026-11-22): system MPI = openEuler package `openmpi-4.1.5-5.oe2403`
  (`/usr/bin/mpirun -> orterun`, `/usr/bin/mpicc -> opal_wrapper`, libmpi from `openmpi-devel` of the same build;
  module `mpi/openmpi-riscv64` points to the same files): consistent, no mix-up. `gcc-14.2.0` adds no MPI; it
  prepends `LD_LIBRARY_PATH=/opt/share/milkv/gcc-14.2.0/gcc-build-14.2.0/lib:/lib64` (so /usr/lib64 shadows RPATHs
  of anything loaded before it). Other MPIs: milkv module `openmpi-5.0.6` (`/opt/share/milkv/openmpi-5.0.6`, PATH,
  LD_LIBRARY_PATH, MPICC/MPICXX), spack `openmpi/4.1.1/gcc-13.1.1` (fedora38 tree; HPL and GROMACS linked to it).
  Compilers: GCC 14.2 `/opt/share/milkv/gcc-14.2.0/gcc-build-14.2.0/bin`, binutils 2.42 from the same module, Clang
  17.0.6 `/usr/bin/clang`.
- `start mpitest --mpi-module openmpi-5.0.6|system` (default openmpi-5.0.6, at the user's request): loads the milkv
  module after gcc-14.2.0, checks that `mpirun` is the module's and `$MPICXX` exists, compiles mpi_bench with
  `$MPICXX` (link flags `-rpath-link`/`-rpath` to the module's lib), one build per MPI
  (`~/02_ws/notes7/mpitest/<mpi>/`); records mpirun, the C++ wrapper and the compiler behind it, mpi_bench's MPI
  libraries (ldd), Open MPI's build info (ompi_info), LD_LIBRARY_PATH; `nosinglecopy` uses `btl_sm_...` with Open
  MPI 5. Laptop tests with a fake module system (`N7_MODULES_INIT`, laptop only): module path PASS (3 settings incl.
  pe2), "module does not load" and "mpirun is not the module's" stopped with a message, `--mpi-module system`
  PASS, `start mpitest` refuses unknown modules.
  - Not from this session: `submodules/walberla/sweepgen/COPYING.txt` (a symlink in git) is a regular file in the
    working tree since 2026-11-21 18:26, so git shows the submodule as modified.

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

`monte3.sh` (one file: laptop commands `start [all|build|time|mpitest]`, `status`, `fetch`, `help`; job modes
`job-build`, `job-time`, `job-mpitest`) + copies of `ldc_reference.py`, `compare_fields.py`, and `mpi_bench.cpp`.
Uses only `push.to.sh` otherwise. `push.to.sh` excludes `/00_private_data/`, `.gitignore` ignores it,
`scripts/README.md` has a row. (Current state; the entries under "monte3 runs" describe the versions of their time.)

- Every job: modules `gcc-14.2.0`, then `openmpi-5.0.6`; refuses to run unless `mpirun` and the wrappers are the
  module's; work folder `~/02_ws/notes7/openmpi-5.0.6/` (trees, verify dumps, `verified/`, `mpitest/`).
- Build job: Python 3.12.11 from source and the venv if missing (presentation6's are reused); per
  precision f64, f32 and compiler GCC, Clang: scalar tree (`-march=rv64gc` in every file) and vector tree (waLBerla's
  flags with the measured VLEN), all 11 variants one at a time, regenerated each time; audit per variant (generated
  sweeps' last `-march` and `-O3`, 0 vector instructions in scalar executables, >0 in explicit sweeps); verification
  as presentation6 (four reference-solution cases, wall links, decomposition 1 × 32³ vs 8 × 16³ bit-identical) with the
  sha256 of every executable in `verify-<cc>-<prec>.log`; GCC vs Clang. CMake gets the module's `mpicc`/`mpic++`; the
  audit also checks that `libmpi` comes from the module. Ends with `BUILD PASS`/`BUILD FAIL`; copies the verify logs
  to `~/02_ws/notes7/openmpi-5.0.6/verified/`.
- Timing job (starts only after a successful build job): MPI check with `mpi_bench` (halo, allreduce, 64 KiB) at
  4-64 processes (failure: ERROR in words, experiments at that count FAILED (not run)), then presentation6's protocol
  at 1/4/8/16/32/64 processes and the fair pair; every run stopped after 300 s; refuses executables whose sha256 is
  not in the verify log; records load and busy cores before each round (no frequency or temperature); best-of
  table, list of failures; ends with `TIME DONE` or `TIME FAIL`.
- MPI test job: `mpi_bench` at each `--np` (patterns, sizes, repeats or seconds), PASS/FAIL per run in words,
  trace summary for hangs.
- Cleanup tests (laptop, 2026-11-22; a scratch copy of the script with a fake module system whose `openmpi-5.0.6`
  is the laptop's Open MPI 5 behind an oversubscribing wrapper): `job-mpitest` at 2/4/16 PASS; `job-time` with fake
  executables in the new folder: MPI check PASS at 4-16, a staged hang at 32/64 reported in words ("32 of 32 ranks
  never reached the first step"), 1-16 timed, 32/64 FAILED (not run), TIME FAIL, no process left; `build_tree` with
  a stub cmake: configure gets the module's `mpicc`/`mpic++` and the link flags; the audit's libmpi check passes for
  the right prefix and fails for another; `start` / `start time` / `start mpitest` / `status` with fake ssh;
  removed modes and options are refused.
- Laptop tests: `help`, guards (`job-build` outside slurm, unknown command, `status` before any `start`); dry run of
  `start` / `start time` / `status` / `fetch` with stubbed `ssh` and `rsync` (exact `sbatch` lines, dependency only when
  both jobs are submitted, state file, log paths); the timing job with fake executables (verified groups timed,
  interleaved rounds, `SWEEPGEN_LDC_OUTPUT=last` for the fair pair, a group with a mismatching sha256 skipped,
  unverified compilers/precisions skipped, best-of table).

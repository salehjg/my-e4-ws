# presentation6: progress log

Started 2026-11-20 by Opus 5.5. Task from the user: clone presentation5 into `docs/presentation6` and
`scripts/presentation6`, with scripts that are independent (no calls into `scripts/presentation4` or `presentation5`)
and run unchanged on both the K1 (bananapi) and monte3. monte3 gets a `setup.sh` for a peak node and a `recon.sh`
that prints what the scripts need to know. **I have no access to monte3**: I write what to query, the user runs it
and pastes the output, and I improve `setup.sh` and the other scripts from it. Nothing in `docs/presentation5`,
`scripts/presentation4`, `scripts/presentation5` or the forks was changed. Nothing was committed.

## Resume here

- State: recon rounds 1 and 2 and setup run 1 done (results below; logs copied by the user to
  `/tmp/archive/presentation6` on the laptop). setup run 1 failed only the MPI link (gcc-14.2.0 module's linker);
  fixed with `LINK_FLAGS` (-rpath-link). **setup run 2 (job 8542, 2026-11-21): SETUP PASS in 48 s**, machine.env
  written. Next: `bash scripts/presentation6/submit.sh prepare.sh f64` (first build job; its duration sizes the rest).
- **Rule from the user (2026-11-20): monte3 is a public machine supervised by professors; nothing questionable in
  the scripts.** So: recon only reads information about the machine and our own allocation (no other users' jobs or
  processes, no security settings, no network probes, no downloads); every node-side step is an ordinary batch job
  through `peak.sbatch` with the slots slurm grants (no hiding of `SLURM_*` variables); setup builds Python from
  python.org's source in our own folder instead of fetching prebuilt binaries.
- **Only one peak node (user, 2026-11-21).** Every job is single-node (`peak.sbatch --nodes=1`; all MPI runs are local);
  jobs queue behind each other, and an exclusive job blocks the node for others, so keep `--time` realistic and
  split `all.sh` into parts (`PARTS`) once the steps check shows how long the matrix takes.
- Open decision for the user: on VLEN 128 the explicit RVV variants cannot run (see "VLEN"). The scripts skip them;
  porting the backend to VLEN 128 would be a separate piece of work.
- Deck: an unchanged copy of presentation5 (it still shows presentation4's and notes5's numbers).

## What was cloned

- `docs/presentation6/`: `slides.tex`, `figures/` (with both films), `build.sh`, `.gitignore` (header renamed),
  `board-logs/{board,x86,notes5,presentation5}` from `docs/presentation5`, byte for byte. Not copied: presentation5's
  progress file (it stays presentation5's record), `build/`.
- `scripts/presentation6/`: presentation5's scripts plus every presentation4 script they used, adapted (below).

## The machines

| | bananapi | monte3 (partition `peak`: **one node** for us, never more than one per job) |
|---|---|---|
| chip | SpacemiT K1, 8 X60 cores (2 clusters of 4) | Sophgo SG2044, 64 C920v2 cores |
| VLEN | 256 | 128 (recon 1: vlenb register) |
| clock, caches | 1.6 GHz | 2.6 GHz fixed (governor performance); L1 64 KB, L2 2 MB per 4 cores, L3 64 MB shared; 1 NUMA node |
| memory | 3.8 GB, no swap | 124 GB (MemTotal); no huge pages reserved, THP madvise |
| OS | Bianbu (Ubuntu 24.04 based) | openEuler 24.03 LTS, glibc 2.38, kernel 6.12 |
| access | ssh, jobs in `screen` | x86-64 login node (ssh port 2223), compute nodes only through slurm (`peak.sbatch`) |
| toolchain | system GCC 14.2, Clang 18.1.8, cmake 3.28.3 | module `gcc-14.2.0` (system GCC 12.3 has no `riscv_vector.h`), system Clang 17.0.6, cmake 3.27.9, Open MPI 4.1.5, llvm-objdump 17, binutils 2.41 (module: 2.42) |
| Python | 3.12 venv | system 3.11.6 and 3.10 only; lbmpy 2.1.1 needs 3.12 (`lattice.py:436` uses 3.12-only syntax) |
| repo copy | `/home/bananapi/saleh/my-e4-ws` | `/home/sjamaligolzar/02_ws/my-e4-ws` (`push.to.sh monte3`) |

## Design of scripts/presentation6

- **`machine.sh`** (sourced by every script) holds everything that differs between the machines: the machine
  (from `/proc/cpuinfo` and the host name; `P6_MACHINE` overrides, not `MACHINE`, which the laptop's shell already
  sets to the host name), VLEN, the vector trees' `-march`, compilers, usable cores, jobs, pinned core, core counts
  of the matrix, objdump, MPI launch, and the paths. It first reads `<base>/presentation6/machine.env`, which
  `setup.sh` writes from what it tested on the machine (module loads, measured VLEN, working compilers, the MPI
  launch). bananapi works without it (defaults = presentation4's setup).
- **Layout** as presentation4, so the verify logs keep working: `BUILD_ROOT/build-<cc>-<prec>[-scalar]`, verify logs
  in `BUILD_ROOT/logs`, timing logs in `LOGDIR`; both default to `<base>/presentation6`. On bananapi,
  `BUILD_ROOT=<base>/presentation4` times presentation4's verified executables without rebuilding (7 h).
- **VLEN.** pystencils' RVV backend generates code for exactly `RVV_VLEN = 256` bits (`rvv.py`; below that, "operations
  would silently process fewer lanes"), and waLBerla's configure adds `-march=rv64gcv_zvl256b` whenever the ISA has
  V. So: explicit variants only where VLEN ≥ `RVV_VLEN` (read from `rvv.py`, so a future backend change is picked up);
  elsewhere `prepare.sh`, `matrix.sh` (group rvv, part share), `steps_check.sh` and `thermal_check.sh` leave them out,
  and `build.sh` / `run.sh` refuse them. At VLEN ≠ 256 the vector trees get `-march=rv64gcv_zvl<VLEN>b` through
  `CMAKE_<LANG>_FLAGS_RELEASE`, which come after waLBerla's flags on every compile line (the same mechanism as the
  scalar trees); at 256 nothing changes against presentation4. Even if someone forced an explicit build at VLEN 128,
  `rvv.hpp`'s `#error` stops it, since `__riscv_v_min_vlen` is then 128.
- **Python.** lbmpy 2.1.1 needs Python ≥ 3.12 (wheel metadata, and `lattice.py:436` uses type-parameter syntax that
  3.11 cannot parse), so the venv does too. On monte3 `setup.sh` builds CPython 3.12.11 from python.org's source into
  `<base>/python/3.12.11` (system GCC; needs openssl, zlib, libffi headers), unless a Python ≥ 3.12 exists. numpy has no
  riscv64 wheel on PyPI, so pip builds it from source. lbmpy and pystencilssfg are
  installed with `--no-deps` (their other dependencies explicitly), so PyPI's pystencils never enters the venv and the
  repo's (on `PYTHONPATH`) is the only one; `setup.sh` fails if it finds one.
- **MPI.** `p6_mpirun` = `MPIRUN -np N MPIRUN_ARGS`; default `mpirun --bind-to core --map-by core`. Open MPI 4.1.5
  takes its slots from slurm (recon 1, in a one-task step: "not enough slots" for 8), so every node-side step runs as
  a batch job with `--ntasks-per-node=64` (`peak.sbatch`, also for recon and setup). A process started on its own
  inside a slurm step aborts in `MPI_Init` (recon 1: "OMPI was not built with SLURM's PMI support"); `setup.sh` checks
  whether that also happens in the batch job and then sets `RUN_PREFIX="mpirun -np 1 --bind-to none"` (`p6_single`
  puts it before `taskset -c CPU`; empty on bananapi, as presentation4/5). `peak.sbatch` asks for
  `--exclusive --ntasks-per-node=64 --mem=0`.
- **Entry points.** `all.sh` (parts prepare f64/f32, steps, matrix, thermal; `DRY_RUN=1`), on monte3 through
  `peak.sbatch` (12 h limit, log `../presentation6/logs/presentation6-<job>.out`). `steps_check.sh` is part of the
  default run because the 60-step choice was validated on the K1 only, and a faster core finishes 60 steps sooner.

| script | from | change |
|---|---|---|
| `machine.sh`, `recon.sh`, `setup.sh`, `all.sh`, `peak.sbatch` (runs the script named as its argument) | new | |
| `build.sh` | p4 `run.sh` | build half only; `VECTOR_FLAGS`, `OBJDUMP`, refuses unsupported variants, needs a known VLEN |
| `prepare.sh` | p4 | `build.sh`; variants and compilers from the profile; MPI launch passed to `verify.sh` |
| `check_build.py` | p4 | expected vector `-march` from `VECTOR_MARCH`; any `-mtune` (one value); `OBJDUMP` |
| `run.sh`, `matrix.sh`, `steps_check.sh`, `thermal_check.sh`, `autovec_why.sh`, `env_record.sh` | p5 | profile paths, `p6_mpirun`, `p6_single`, skips; `bc` replaced by awk; thermal/cpufreq read generically |
| `verify.sh` | p4 | usage lines; `RUN_PREFIX` before its one-process runs |
| `ldc_reference.py`, `compare_fields.py`, `check_walls.py`, `summary.py`, `steps_table.py` | p4 / p5 | usage lines only |

## Laptop tests (2026-11-20)

- `bash -n` on every script, `py_compile` on every Python file; no call into another script folder.
- Profiles printed for: autodetect (x86: `other-x86_64`, VLEN unknown), bananapi, monte3 without VLEN, monte3 VLEN 128
  (explicit no, `-march=rv64gcv_zvl128b` via `VECTOR_FLAGS`), monte3 VLEN 256 (explicit yes, waLBerla's flags).
- `all.sh DRY_RUN=1` lists the parts; without VLEN it aborts and points to `setup.sh`. `setup.sh` on x86 stops with the
  srun command. `run.sh` aborts without `VERIFY PASS` and for an explicit variant at VLEN 128. A sample
  `machine.env` is read (MPI launch replaced).
- `check_build.py`: on presentation4's x86 tree (non-RISC-V path) PASS; RISC-V path with synthetic trees: monte3-like
  (waLBerla's zvl256b then our zvl128b, C file with our `-march`, scalar target's own file) PASS, K1-like (one
  `-mtune`) PASS, a file with the wrong `-march` FAIL.
- `setup.sh` steps 5-9 on the laptop with a fake `uname` (venv in the scratchpad): MPI 8 ranks PASS, one process
  PASS, pip install PASS, a second run installs nothing; a fake one-task allocation fails the MPI step with the
  `peak.sbatch` hint. The from-source Python build downloads and configures 3.12.11; on the laptop it stops in
  `_ssl.c` because the laptop has OpenSSL 4.1 (openEuler 24.03 has OpenSSL 3.0, which 3.12 supports).
- `recon.sh --node` on the laptop runs to the end (RISC-V and module parts fail as expected on x86).

## Recon rounds

### Round 1 (2026-11-20, run by the user on mc-peak-2 inside an interactive one-task step)

- openEuler 24.03 LTS, kernel 6.12, glibc 2.38; 64 cores, 1 NUMA node, 2.6 GHz fixed; L2 2 MB per 4 cores, L3 64 MB;
  124 GB. No thermal zones exposed (64 "Processor" cooling devices only).
- **VLEN 128** (vlenb register, test program built with Clang 17). ISA string has `v` and `zicbom/zicboz`, no `zicbop`.
- Compilers: system GCC 12.3.1 (no `riscv_vector.h`), system Clang 17.0.6 (RVV intrinsics work). The `gcc-14.2.0`
  module was not really tested: recon piped `module load` into `head`, which ran it in a subshell (fixed).
- cmake 3.27.9 (enough), llvm-objdump 17, GNU objdump 2.41.
- Python: 3.11.6 and 3.10.14 only. PyPI reachable; no riscv64 wheels for numpy or cmake; lbmpy 2.1.1 refused
  (Requires-Python ≥ 3.12).
- MPI: system Open MPI 4.1.5 (slurm ras/plm built in). In the one-task step: `mpirun -np 8` "not enough slots";
  a process started alone aborts in `MPI_Init` ("direct launched using srun"); `srun --mpi=pmix` cannot load PMIx.
  (A test that hid the `SLURM_*` variables worked, but that way is dropped, see the rule under "Resume here".)
- No clock skew (newest synced file 868 s in the past). Home is NFS (245 GB free), `/tmp` is a 62 GB tmpfs.

### Round 2 and setup run 1 (2026-11-20, batch jobs 8538 and 8539 on mc-peak-2)

- Batch allocation: 64 tasks, `nproc` 64, CPUs 0-63. System Open MPI 4.1.5 with system GCC/ld: `mpirun -np 8` ranks
  on cores 0-7, environment passed on; a process started alone initialises MPI fine in a batch job (the round-1
  abort was specific to an `srun` step), so `RUN_PREFIX` stays empty, as on bananapi.
- Module gcc-14.2.0 loads (`module is-loaded`), GCC 14.2.0 at VLEN 128, its own libstdc++ works on this CPU; its
  binaries get RPATH to the module's lib directory (the module sets `LD_RUN_PATH`). Its binutils 2.42 come first on PATH.
- setup run 1 (9 min): PASS GCC 14.2.0 and Clang 17.0.6 (VLEN 128, both `-march`s), llvm-objdump 17, smoke tests
  (vector build for VLEN 128 = scalar build: 3.834238547065056e+08, 1.9173613e+08; 29 and 35 vector instructions),
  Python 3.12.11 built from source in 248 s, pip install in 247 s (numpy 2.5.5 from source, sympy 1.14.0,
  lbmpy 2.1.1, pystencilssfg 0.1.1), imports (repo pystencils and sweepgen, RISCV_RVV detected), cmake 3.27.9.
- The same smoke test built for VLEN 256 also gives the right result at VLEN 128 (both compilers): their loops
  are vector-length agnostic. So the VLEN problem is specific to the vector-length-specific code of pystencils'
  RVV backend, not to `zvl256b` as such.
- **FAIL: mpicc with the module's GCC.** Its linker (binutils 2.42 from the module, `riscv64-openEuler-linux-ld`)
  does not search the `-rpath` directory or `/usr/lib64` for the libraries libmpi itself needs (`libopen-rte`,
  `libopen-pal`, `libm`, `libhwloc`, `libevent`): undefined references. The module's Open MPI 5.0.6 fails the same
  way. Fix (2026-11-21): setup retries with `-Wl,-rpath-link,<mpicc -L dirs>:/usr/lib64` (link-time search only;
  the program does not change), tests every compiler (`OMPI_CC`), and writes it as `LINK_FLAGS` to machine.env;
  `build.sh` passes it as `CMAKE_{EXE,SHARED}_LINKER_FLAGS`. Tested on the laptop with a fake failing mpicc.
- Python build headers: openssl 3.0.12, zlib, libffi, bzip2, xz, sqlite, readline, ncurses devel present;
  libuuid-devel missing (optional).

### Setup run 2 (job 8542, 2026-11-21 00:25, mc-peak-2): SETUP PASS in 48 s

(Job 8541 before it wrote no log: the user had moved `~/02_ws/presentation6`, logs folder included, to the laptop, and
slurm does not create the `--output` folder. New `submit.sh` creates it, submits through `peak.sbatch`, prints the
log path and sets a default time limit per script.)

All checks pass; the MPI link needed and got `-Wl,-rpath-link,/usr/lib64/openmpi/lib:/usr/lib64` (gcc and clang); the
venv from run 1 was reused. machine.env: monte3, VLEN 128, compilers gcc clang, llvm-objdump, `mpirun --bind-to core
--map-by core`, no single-run prefix, the link flags, `module load gcc-14.2.0`. Profile: 64 cores, 61 build jobs, core
counts 1 4 8 16 32 64, vector trees `-march=rv64gcv_zvl128b`, Python 3.12.11.

Builds stay one variant after another (a variant's code generation and its large generated file are
single-threaded, so most of a build uses few cores). Building variants and compilers side by side was tried and
reverted on 2026-11-21: the user wants the scripts simple, easy to follow and to maintain.

### Next (to run)

On the monte3 login node, in `~/02_ws/my-e4-ws` (no push needed: no script changed since setup run 2):

```bash
bash scripts/presentation6/submit.sh prepare.sh f64
```

Builds scalar and autovec variants (3 + 3) with GCC and Clang for f64, audits them, verifies them against the NumPy
oracle and the decomposition check, and compares GCC with Clang. Logs: `~/02_ws/presentation6/logs/` (job output
`p6-prepare-f64-<id>.out`; `build-`, `check-`, `verify-<cc>-f64.log`, `compilers-f64.log`); build trees in
`~/02_ws/presentation6/build-{gcc,clang}-f64[-scalar]`.

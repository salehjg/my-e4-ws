# scripts-legacy

Configure, build, time and tabulate the benchmarks of waLBerla's **legacy core** with **pystencils 1.4**
([`docs/notes8`](../docs/notes8/rvv-legacy-wind-plan-opus5.5.md), branches `rvv-support-legacy`). Two apps, each built
in several code generation variants, so that pystencils 1.4's own RVV backend (`rvv.lgcy`) and ours (`rvv.our1`, with
options) can be compared ([Names](#names)):

- waLBerla-wind's `apps/BenchmarkApp_cpu_uniform` (D3Q27 cumulant, Guo force, QR model; float32);
- waLBerla's `apps/benchmarks/UniformGridCPU` (D3Q19 SRT, periodic shear flow; float64).

`scripts/` belongs to the 2.x stack (`rvv-support`) and is not used here.

| file | what |
|---|---|
| `experiments.py` | data only: machines, builds (one CMake tree each), variants, experiments; edit this to add something |
| `bench.py` | runs on the machine itself: `setup`, `configure`, `build`, `run`, `all`, `table` |
| `remote.py` | runs on the laptop: `push`, `start`, `status`, `fetch` (Banana Pi: screen; monte3: slurm) |
| `animation.py` | class `Animation`, for `bench.py animate` and `render` ([Animations](#animations)) |
| `uniform_grid_cpu.prm` | UniformGridCPU's parameters (waLBerla-wind's are in its app folder, `benchmark.prm`) |
| `../results-legacy/` | one folder per run, everything about it in `bench.json5` (see [The results](#the-results)) |

Python standard library only, so the board's system `python3` runs them; the code generation uses the venv, and so
does `render` (pyvista, matplotlib).
Self-contained: they use nothing outside this folder (no `push.to.sh`, nothing made by earlier scripts), and
`setup` prepares on a machine whatever is missing.

## Use

Laptop (x86; only scalar variants, to try the scripts; the venv `../.venv-legacy` exists since notes8 step 0):

```bash
python3 scripts-legacy/bench.py all wind-x86
python3 scripts-legacy/bench.py all ugc-x86      # downloads pybind11, see below
python3 scripts-legacy/bench.py animate wind-x86 # not timed: VTK files, then
python3 scripts-legacy/bench.py render build/legacy/animations/<time>-<random>   # frames/*.png, animation.gif
```

Banana Pi, from the laptop:

```bash
python3 scripts-legacy/remote.py push            # -> bananapi:/home/bananapi/saleh/my-e4-ws-legacy
python3 scripts-legacy/remote.py start setup     # once: the venv /home/bananapi/saleh/.venv-legacy
python3 scripts-legacy/remote.py start all wind  # detached in screen; a second start is refused while one runs
python3 scripts-legacy/remote.py status
python3 scripts-legacy/remote.py fetch           # runs -> results-legacy/, logs and animations -> 00_private_data/
python3 scripts-legacy/bench.py list             # the runs: id, machine, experiment, quick or timed, ok / FAIL
python3 scripts-legacy/bench.py table results-legacy/<run> [--baseline aa_rvv.lgcy] [--csv t.csv]
```

`push` (rsync) sends the whole git repository (the folder above `walberla-rvv-support`), `.git` and the
submodules' git data included, so the machine's copy is a working git repository and `bench.py` reads branch,
commit and uncommitted changes there itself. It mirrors the working tree as it is, uncommitted changes included,
but only what git sees: whatever git ignores, in the repository and in each submodule, stays (venvs, `build/`,
`00_private_data/`, presentation data). It neither sends nor deletes `results-legacy/`, so the machine's runs stay
there until `fetch`. The board's `my-e4-ws` (`../push.to.sh bananapi`) keeps the 2.x stack.

monte3 (Monte Cimone's peak node: SG2044, 64 cores, VLEN 128), from the laptop, **only after the user's go-ahead**:
every command below connects to monte3.

```bash
python3 scripts-legacy/remote.py --machine monte3 push                     # -> monte3:~/02_ws/my-e4-ws-legacy
python3 scripts-legacy/remote.py --machine monte3 start all wind-vlen128   # one slurm job, see below
python3 scripts-legacy/remote.py --machine monte3 status                   # our jobs (squeue --me), the newest log
python3 scripts-legacy/remote.py --machine monte3 fetch
```

- The login node is x86-64: everything of `bench.py`, compiling included, runs in slurm jobs on the peak node.
  `start` submits `sbatch --wrap "python3 scripts-legacy/bench.py --machine monte3 <args>"` with the options in
  `remote.REMOTES` (the whole node: `--exclusive`, 64 tasks, `--mem=0`, 6 h), for `setup`, `configure` or `build`
  alone too; `all` does it all in one job (the venv first if it is missing). On the login node only `rsync`,
  `mkdir`, `date`, `sbatch` and `squeue --me` run.
- In the job, `bench.py` first loads the modules `gcc-14.2.0` and `openmpi-5.0.6` (`experiments.MACHINES`): the
  milkv Open MPI, not the system's Open MPI 4.1.5, whose helper thread spins (docs/notes7). It stops if `mpicxx` is
  not the module's. The executables find the module's `libmpi` by rpath (`link_flags`).
- Everything lives in `~/02_ws/legacy` (builds, venv, pip cache, logs) and is made there by the first job: the
  node's Python 3.11 makes the venv, and pip builds numpy from source once (PyPI has no riscv64 wheel).
- The VLEN 128 experiments (`wind-vlen128`, `ugc-vlen128`) have `vls128` where the K1's have `vls256`; `configure`
  refuses fixed-VLEN variants that do not match the machine.

## The commands

- **`setup`**: the venv: pystencils 1.4's dependencies, jinja2, py-cpuinfo, `lbmpy==1.4` without its dependencies;
  pystencils itself comes from the submodule (`PYTHONPATH`). Made with the Python that runs `bench.py` if it is
  3.10 or newer and has `ensurepip`, else with Python 3.12.11 built from python.org's source into `<work>` (once).
  The venv sees the system's packages: PyPI has no numpy for riscv64, so on the K1 it is Ubuntu's (1.26.4); where
  the system has none, pip builds it from source, once (pip's cache is `<work>/pip-cache`).
- Compilers and pip put their temporary files into `<work>/tmp` (`TMPDIR`): the K1's root file system, which holds
  `/tmp`, is 99 % full.
- **`configure <experiment>`**: cmake into `<work>/builds/<build>`. First checks that every `rvv.our1` name means to
  pystencils (`parse_options`) what `experiments.py` says. `PYTHONPATH` is set at configure time, because the legacy
  code generation keeps it from then. The architecture flags come from `experiments.MACHINES` (K1:
  `-march=rv64gcv_zvl256b`, what waLBerla gives GCC there), with `WALBERLA_OPTIMIZE_FOR_LOCALHOST=OFF`: ON would
  also vectorize every kernel that sets no instruction set itself with the machine's best one (waLBerla-wind's flow
  driver, which pystencils 1.4 cannot vectorize).
  - waLBerla-wind: `WALBERLA_BUILD_WITH_PYTHON=OFF`, as in its CI.
  - UniformGridCPU: `WALBERLA_BUILD_WITH_PYTHON=ON`, because upstream adds the app only then
    (`apps/benchmarks/CMakeLists.txt`). ON downloads pybind11 from GitHub and compiles everything with `-fPIC`; the
    variants of one tree are compiled alike, so their comparison is fair. The app is run from a `.prm` file, not from
    upstream's Python setup scripts.
- **`build <experiment>`**: the variants' executables only.
- **`run <experiment> [--quick]`**: the presentation5 protocol: `warmup` untimed and `steps` timed time steps, every
  variant once per round in turn, `rounds` rounds, per process count. One process: `taskset -c 2`; more:
  `mpirun --bind-to core --map-by core`. Every process has its own `cells`³ block. `--quick`: 2 + 10 steps, 1 round,
  the first two process counts, as a check before timing. Each run is stopped after `RUN_LIMIT` (600 s) with all its
  processes, so that a hung `mpirun` does not use up a job (notes7 lost 5.6 h on monte3 that way).
- **`all <experiment>`**: `setup` if the venv is missing, configure, build, `run --quick`, and the timed run only if
  the quick run is clean.
- **`list`**: the runs in `results-legacy/`, oldest first.
- **`table <runs>`**: one row per run, process count and variant: runs, failed runs, median and best MLUP/s, speedup
  of the median against `--baseline` (default `pull_none`), checksum check; `--csv` writes the same rows.
- **`animate`** and **`render`**: see [Animations](#animations).

## Animations

Pictures of the flow, apart from the timing: an animation run writes VTK files and is never timed, and a timing run
writes none, so the output's load cannot touch a speedup.

```bash
python3 scripts-legacy/bench.py animate <experiment> [--variant V] [--steps N] [--every K] [--np N]
python3 scripts-legacy/bench.py render <animation folder>
```

- **`animate`** (`Animation.simulate`): configure, build the one variant (default `pull_none`), run it once: no
  warmup, no time limit (on monte3 the job's), `--np` processes with one `cells`³ block each, a VTK frame every
  `--every` steps (default 2000 steps, every 25: 81 frames, about 330 MB at 64³, 100 s on the laptop). Into
  `<work>/animations/<time>-<random>/`: `animation.json` (what ran: machine, variant, command, executable, source),
  `app.log`, `vtk_out/` (one `.pvd` series). `setup` first if the venv is missing.
- How the apps write VTK: UniformGridCPU with `-Parameters.vtkWriteFrequency=K` (upstream; 0 in timing runs).
  waLBerla-wind's benchmark app adds its VTK output to the time loop only if the configuration has an `Output.VTK`
  block (`main.cpp`); `animate` gives it on the command line (`-Output.VTK.writeFrequency=K
  -Output.VTK.fields.velocity=1`), `benchmark.prm` has none, so timing runs keep their time loop (checked: the
  same checksum to the last digit as before, no VTK entry in the timing pool).
- **`render`** (`Animation.render`): one PNG per frame (`frames/`) and `animation.gif`: the velocity in the x-z slice
  through the middle of the domain, waLBerla-wind |u| (the boundary layer over the ground), UniformGridCPU u_x (the
  shear layer), one colour scale for all frames. `bench.py` runs `animation.py` with the venv's Python and first
  installs pyvista and matplotlib there if they are missing. VTK has no riscv64 wheels: on the boards `animate`
  only, then `remote.py fetch` (to `00_private_data/legacy/<machine>/animations/`) and `render` on the laptop.

## Names

Every variant, and so every executable, log and table row, is named `<streaming>_<backend>[-<option>...]`:

- `<streaming>`: `pull` or `aa`;
- `<backend>`: `none` (no explicit vectors), `<isa>.lgcy` (pystencils 1.4's own backend for `<isa>`, e.g.
  `rvv.lgcy`) or `<isa>.our<N>` (our experimental backend `N` for `<isa>`, e.g. `rvv.our1`);
- `<option>`: an option of one of our backends, e.g. `vf`, `fma`, `pf128`, `vls256`.

`_` only separates the streaming pattern from the backend, `.` only the ISA from where the backend comes from, and
`-` only comes before an option. pystencils gets the same name: our pystencils branch maps `<isa>.lgcy` to its own
`<isa>` (any of them: `avx.lgcy` is `avx`) and picks `<isa>.our<N>` by the part before the first `-`
(`backends/simd_instruction_sets.py`).

| backend | what | options |
|---|---|---|
| `none` | scalar: no explicit vectors (GCC may still auto-vectorize) | |
| `rvv.lgcy` | pystencils 1.4's own RVV 1.0 backend (`backends/riscv_instruction_sets.py`), vector-length agnostic | |
| `rvv.our1` | ours: `rvv.lgcy` plus options (`backends/riscv_our1_instruction_sets.py`); without options it prints exactly `rvv.lgcy`'s code | `vls128`/`vls256` (fixed VLEN), `m2`/`m4` (LMUL), `vf`, `fma`, `pf<N>` (prefetch) |

A new backend of ours gets the next number (`rvv.our2`, or `avx.our1` for another ISA): its own pystencils module,
a member of `experiments.Vectors` and a row here. A name is never changed or reused. Runs before 2026-11-28 have
the old names: `rvv` is `rvv.lgcy`, `rvv_ext` is `rvv.our1` (`aa_rvv_ext-vf-fma-pf128` = `aa_rvv.our1-vf-fma-pf128`).

**Vector length.** `rvv.lgcy`, and `rvv.our1` without a `vls` option, are vector-length agnostic (VLA): the loop asks
the hardware at run time how many numbers fit in a register (`vsetvlmax`) and steps by that, and every intrinsic gets
the cells left in the row as its length, so the last pass is simply a shorter one. One binary runs on any RVV 1.0
machine. `vls128`/`vls256` make the code vector-length specific (VLS): every intrinsic gets the full lane count of
that VLEN (8 float32 numbers at 256 bits), the loop steps by it and a scalar loop does the remainder. That is only
correct on hardware with at least that VLEN, which the program cannot check at run time: a header
(`rvv_our1_vls<N>.h`) refuses to compile unless `-march` has `zvl<N>b`, and `configure` refuses a `vls` variant whose
VLEN is not the machine's (`experiments.MACHINES[...].vlen`). So the K1's experiments have `vls256`, monte3's
`vls128`.

## Variants

`experiments.Variant` has typed fields; `bench.py` alone turns them into the names that waLBerla's code generation
passes to the generator scripts (`CODEGEN_CFG`, read there as `ctx.config`):

| `Variant(...)` | waLBerla-wind target suffix | UniformGridCPU target suffix |
|---|---|---|
| `Variant()` (the reference) | `pull_none` | `d3q19_pull_srt` (upstream's target) |
| `Variant(AA, RVV_LGCY)` | `aa_rvv.lgcy` | `d3q19_aa_srt_rvv.lgcy` |
| `Variant(AA, RVV_OUR1, vf=True, fma=True, prefetch=128)` | `aa_rvv.our1-vf-fma-pf128` | `d3q19_aa_srt_rvv.our1-vf-fma-pf128` |

They are read by waLBerla-wind's `apps/BenchmarkApp_cpu_uniform/LBMGeneration.py`, by `UniformGridCPU.py` and, for
the options, by pystencils' `backends/riscv_our1_instruction_sets.parse_options`. `bench.json5` keeps the fields too.

## Adding a benchmark

**An experiment of an app that is already supported** (`App.WIND`, `App.UGC`) is one entry in
`experiments.EXPERIMENTS`, nothing else: a `Build` (one CMake tree: its name, the app, the variants, precision,
compiler; for UniformGridCPU `stencil` and `collision`, a pair that upstream's `UniformGridCPU/CMakeLists.txt` knows)
and the run's settings (`cores`, `cells`, `warmup`, `steps`, `rounds`). For example:

```python
"ugc-d3q27-cumulant": Experiment(Build("ugc-d3q27-cumulant-f64", App.UGC, VLEN256, precision=64,
                                       stencil="d3q27", collision="cumulant")),
"wind-big":           Experiment(Build("wind-f32", App.WIND, VLEN256), cells=128, steps=30),
```

A new `Build` name is a new tree, so a full build (about 3 h on the K1); `wind-big` reuses the tree and the
executables of `wind`. The variant lists (`SCALAR`, `ANY_VLEN`, `VLEN256`, `VLEN128`) can be combined, or a new one
written; every list must contain `REFERENCE` (`pull_none`).

**A new app**: a member of `experiments.App`, then the places in `bench.py` that know each app: `executable()` (the
target name), `codegen_config()` (a variant as the generator's config), `configure()` (source folder, CMake
variables) and `app_command()` (parameter file, domain); for animations `animation.VIEWS` and the VTK option in
`Animation.simulate`. The app must take the variant as its `CODEGEN_CFG`, and print waLBerla's
`- performance: ... MLUPS` line and the line `Checksum: sum(rho) = ..., sum(|u|^2) = ...`, which `time_one` reads.

**A new backend of ours**: see [Names](#names).

**Several experiments**: one `bench.py` command does one experiment (`all wind`), and `remote.py start` refuses a
second job while one is queued or running; start the next one when `remote.py status` shows the first has ended.

## The checksum

Both apps print, after the run, the sum of the density and the sum of |u|² over all interior cells. A variant is
compared with the reference variant (`pull_none`, the code waLBerla-wind ships) at the same process count and steps.
A correct variant differs by rounding only, a wrong kernel, remainder loop or AA even/odd step by 1e-3 or more.
Rounding, float32, waLBerla-wind, 70 steps: the scalar pull and AA variants agree to about 2e-9 relative; every
vector variant, pystencils' own and ours, RVV on the K1 and AVX on x86 alike, differs from the scalar reference by
about 3.3e-6, and the vector variants agree with each other to about 1e-9. pystencils' vector kernels drift from its
scalar kernel by about 5e-8 per step; the cause is not known (not `powf` against a square root, not FMA
contraction; docs/notes8 progress log, 2026-11-28). `experiments.TOLERANCE` is 1e-5 for float32 (enough for about
200 steps) and 1e-10 for float64. A run keeps the tolerance it ran with (`bench.json5`, `experiment.tolerance`), so
runs before the change from 1e-6 still show FAIL for their vector variants.
Every timed run carries its checksum, so the timed executables are the checked ones. The sums do not say where an
error is; that is what the QEMU kernel checks (`scripts/notes8/lbm_qemu_check.py`) do, cell by cell.

## The results

Every `bench.py run` makes one folder `results-legacy/<YYYYMMDD-HHMMSS>-<6 random hex digits>/` (meant to be
committed) with everything about the run in one file, `bench.json5`, and the apps' output in `logs/`:

```json5
// One run of scripts-legacy/bench.py (README.md there). JSON5: JSON plus // comment lines; NaN marks a missing value.
{
  "format": 1, "started": "2026-11-26T16:02:11+0100", "finished": "2026-11-26T16:09:40+0100",
  // what was timed (scripts-legacy/experiments.py); quick: the short check before timing
  "experiment": {"name": "wind", "quick": false, "cores": [1, 4, 8], "cells": 64, "warmup": 10, "steps": 60, ...},
  "build":    {"name": "wind-f32", "app": "wind", "precision": 32, "compiler": "gcc", "folder": "..."},
  "machine":  {"name": "bananapi", "host": "...", "uname": "...", "cpus": 8, "cxx_flags": "-march=rv64gcv_zvl256b", ...},
  "software": {"compiler": "g++ (...) 14.2.0", "cmake": "...", "mpi": "mpirun (Open MPI) ...", "python": "...", ...},
  "source":   {"walberla-rvv-support": {"branch": "rvv-support-legacy", "commit": "9ff8e8b1...", "date": "...",
                                        "changes": [" M scripts/README.md", "?? scripts-legacy/"]},
               "walberla-rvv-support/submodules/walberla": {"branch": "rvv-support-legacy", ...}, ...},
  "variants": [
    {"label": "aa_rvv.our1-vf-fma", "streaming": "aa", "vectors": "rvv.our1", "vlen": null, "lmul": 1, "vf": true,
     "fma": true, "prefetch": null, "instruction_set": "rvv.our1-vf-fma", "codegen_config": "aa_rvv.our1-vf-fma",
     "executable": "...", "sha256": "...", "cxx_flags": "..."}, ...],
  "runs": [
    {"variant": "aa_rvv.our1-vf-fma", "cores": 1, "round": 0, "load": 0.1, "returncode": 0, "seconds": 9.8,
     "mlups": 7.41, "rho_sum": 262143.99..., "u2_sum": 757.63..., "log": "logs/aa_rvv.our1-vf-fma-np1-r0.log"}, ...],
  "summary": [
    {"cores": 1, "variant": "aa_rvv.our1-vf-fma", "runs": 3, "failed": 0, "median": 7.4, "best": 7.45,
     "speedup": 1.38, "checksum": "ok 2.1e-09"}, ...]
}
```

Every comment is a whole line, so `json.loads` of the other lines reads it (`bench.load_run`), and so does any JSON5
parser. The file is rewritten after every run, so an interrupted run leaves a valid file (`"finished": null`).

Builds go to `<work>/builds/<build>/`: `build/legacy` in this checkout on the laptop (gitignored),
`/home/bananapi/saleh/legacy` on the board, where the venv `/home/bananapi/saleh/.venv-legacy` is too, and
`~/02_ws/legacy` on monte3 (with the venv): outside the pushed repository, of which `push` keeps an exact mirror.
`remote.py start` logs bench.py's output to `<work>/screen-logs/` (monte3: `slurm-logs/`); `fetch` copies them and
`<work>/animations/` to `00_private_data/legacy/<machine>/` (gitignored).
The code generation of a variant reruns only when its generator script changes (`LBMGeneration.py`,
`UniformGridCPU.py`): CMake does not know that it also depends on pystencils and walberla's Python code. After a
change there, delete the variant's generated folder in the build (e.g.
`<work>/builds/wind-f32/apps/BenchmarkApp_cpu_uniform/aa_rvv.lgcy/`) or the whole build.

## Rules

- monte3: ask the user before anything runs there (`push`, `start`, `status` and `fetch` all connect to it). Only
  slurm jobs. There the scripts read `/proc/meminfo` and `/proc/loadavg` and nothing else of the system (the jobs
  pass `--machine`, so not even `/proc/cpuinfo`): nothing under `/sys`, no frequency, governor, power or
  temperature. Other users' jobs are not looked at (`squeue --me`).
- One `bench.py` job at a time per machine (`remote.py start` refuses a second one).
- Monte Cimone results in reports: acknowledgement and DOI 10.1007/978-3-032-07612-0_44.

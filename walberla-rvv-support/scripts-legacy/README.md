# scripts-legacy

Configure, build, time and tabulate the benchmarks of waLBerla's **legacy core** with **pystencils 1.4**
([`docs/notes8`](../docs/notes8/rvv-legacy-wind-plan-opus5.5.md), branches `rvv-support-legacy`). Two apps, each built
in several code generation variants, so that pystencils 1.4's own `rvv` and our `rvv_ext` options can be compared:

- waLBerla-wind's `apps/BenchmarkApp_cpu_uniform` (D3Q27 cumulant, Guo force, QR model; float32);
- waLBerla's `apps/benchmarks/UniformGridCPU` (D3Q19 SRT, periodic shear flow; float64).

`scripts/` belongs to the 2.x stack (`rvv-support`) and is not used here.

| file | what |
|---|---|
| `experiments.py` | data only: machines, builds (one CMake tree each), variants, experiments; edit this to add something |
| `bench.py` | runs on the machine itself: `setup`, `configure`, `build`, `run`, `all`, `table` |
| `remote.py` | runs on the laptop: `push`, `start`, `status`, `fetch` (Banana Pi only) |
| `uniform_grid_cpu.prm` | UniformGridCPU's parameters (waLBerla-wind's are in its app folder, `benchmark.prm`) |
| `../results-legacy/` | one folder per run, everything about it in `bench.json5` (see [The results](#the-results)) |

Python standard library only, so the board's system `python3` runs them; the code generation uses the venv.

## Use

Laptop (x86; only scalar variants, to try the scripts; the venv `../.venv-legacy` exists since notes8 step 0):

```bash
python3 scripts-legacy/bench.py all wind-x86
python3 scripts-legacy/bench.py all ugc-x86      # downloads pybind11, see below
```

Banana Pi, from the laptop:

```bash
python3 scripts-legacy/remote.py push            # -> bananapi:/home/bananapi/saleh/my-e4-ws-legacy
python3 scripts-legacy/remote.py start setup     # once: the venv /home/bananapi/saleh/.venv-legacy
python3 scripts-legacy/remote.py start all wind  # detached in screen; a second start is refused while one runs
python3 scripts-legacy/remote.py status
python3 scripts-legacy/remote.py fetch           # the board's runs -> results-legacy/
python3 scripts-legacy/bench.py list             # the runs: id, machine, experiment, quick or timed, ok / FAIL
python3 scripts-legacy/bench.py table results-legacy/<run> [--baseline aa_rvv] [--csv t.csv]
```

`push` runs `push.to.sh bananapi --repo my-e4-ws-legacy`: the whole git repository (the folder above
`walberla-rvv-support`), `.git` and the submodules' git data included, so the board's copy is a working git
repository and `bench.py` reads branch, commit and uncommitted changes there itself. It mirrors the working tree
as it is, uncommitted changes included, without venvs, caches, `build/` and `00_private_data/`. The board's
`my-e4-ws` (plain `push.to.sh bananapi`) keeps the 2.x stack that `run.on.bananapi.sh` uses. `push.to.sh` neither
sends nor deletes `results-legacy/`, so the board's runs stay there until `fetch`.

## The commands

- **`setup`**: the venv: pystencils 1.4's dependencies, jinja2, py-cpuinfo, `lbmpy==1.4` without its dependencies;
  pystencils itself comes from the submodule (`PYTHONPATH`). The venv sees the system's packages: PyPI has no numpy
  for riscv64, so on the K1 it is Ubuntu's (1.26.4) instead of a build from source.
- Compilers and pip put their temporary files into `<work>/tmp` (`TMPDIR`): the K1's root file system, which holds
  `/tmp`, is 99 % full.
- **`configure <experiment>`**: cmake into `<work>/builds/<build>`. First checks that every `rvv_ext` name means to
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
  the first two process counts, as a check before timing.
- **`all <experiment>`**: configure, build, `run --quick`, and the timed run only if the quick run is clean.
- **`list`**: the runs in `results-legacy/`, oldest first.
- **`table <runs>`**: one row per run, process count and variant: runs, failed runs, median and best MLUP/s, speedup
  of the median against `--baseline` (default `pull_none`), checksum check; `--csv` writes the same rows.

## Variants

`experiments.Variant` has typed fields; `bench.py` alone turns them into the names that waLBerla's code generation
passes to the generator scripts (`CODEGEN_CFG`, read there as `ctx.config`):

| `Variant(...)` | waLBerla-wind target suffix | UniformGridCPU target suffix |
|---|---|---|
| `Variant()` (the reference) | `pull_none` | `d3q19_pull_srt` (upstream's target) |
| `Variant(AA, RVV)` | `aa_rvv` | `d3q19_aa_srt_rvv` |
| `Variant(AA, RVV_EXT, vf=True, fma=True, prefetch=128)` | `aa_rvv_ext-vf-fma-pf128` | `d3q19_aa_srt_rvv_ext-vf-fma-pf128` |

They are read by waLBerla-wind's `apps/BenchmarkApp_cpu_uniform/LBMGeneration.py`, by `UniformGridCPU.py` and, for
the options, by pystencils' `backends/riscv_ext_instruction_sets.parse_options`. `bench.json5` keeps the fields too.

## The checksum

Both apps print, after the run, the sum of the density and the sum of |u|² over all interior cells. A variant is
compared with the reference variant (`pull_none`, the code waLBerla-wind ships) at the same process count and steps.
A correct variant differs by rounding only (x86, float32, 100 steps: pull vs AA about 2e-9 relative), a wrong kernel,
remainder loop or AA even/odd step by 1e-3 or more; `experiments.TOLERANCE` is 1e-6 (float32) and 1e-10 (float64).
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
    {"label": "aa_rvv_ext-vf-fma", "streaming": "aa", "vectors": "rvv_ext", "vlen": null, "lmul": 1, "vf": true,
     "fma": true, "prefetch": null, "instruction_set": "rvv_ext-vf-fma", "codegen_config": "aa_rvv_ext-vf-fma",
     "executable": "...", "sha256": "...", "cxx_flags": "..."}, ...],
  "runs": [
    {"variant": "aa_rvv_ext-vf-fma", "cores": 1, "round": 0, "load": 0.1, "returncode": 0, "seconds": 9.8,
     "mlups": 7.41, "rho_sum": 262143.99..., "u2_sum": 757.63..., "log": "logs/aa_rvv_ext-vf-fma-np1-r0.log"}, ...],
  "summary": [
    {"cores": 1, "variant": "aa_rvv_ext-vf-fma", "runs": 3, "failed": 0, "median": 7.4, "best": 7.45,
     "speedup": 1.38, "checksum": "ok 2.1e-09"}, ...]
}
```

Every comment is a whole line, so `json.loads` of the other lines reads it (`bench.load_run`), and so does any JSON5
parser. The file is rewritten after every run, so an interrupted run leaves a valid file (`"finished": null`).

Builds go to `<work>/builds/<build>/`: `build/legacy` in this checkout on the laptop (gitignored),
`/home/bananapi/saleh/legacy` on the board, where the venv `/home/bananapi/saleh/.venv-legacy` is too: outside the
pushed repository, of which `push.to.sh` keeps an exact mirror.
`remote.py start` logs configure and build to `<work>/screen-logs/`; `fetch` copies them to
`00_private_data/legacy/bananapi/` (gitignored).
The code generation of a variant reruns only when its generator script changes (`LBMGeneration.py`,
`UniformGridCPU.py`): CMake does not know that it also depends on pystencils and walberla's Python code. After a
change there, delete the variant's generated folder in the build (e.g.
`<work>/builds/wind-f32/apps/BenchmarkApp_cpu_uniform/aa_rvv/`) or the whole build.

## Rules

- monte3 is not set up here. Ask the user before anything runs there. The scripts read nothing under `/sys` (no
  frequency, governor, power or temperature), so they stay usable there.
- One `bench.py` session at a time on a board (`remote.py start` refuses a second one).
- Monte Cimone results in reports: acknowledgement and DOI 10.1007/978-3-032-07612-0_44.

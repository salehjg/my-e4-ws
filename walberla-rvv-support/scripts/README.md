# scripts

Benchmarks and checks for the Banana Pi board (SpacemiT K1) and, from presentation6 on, Monte Cimone's
`peak` nodes (monte3, Sophgo SG2044). Sync with `bash push.to.sh <machine>`, then run them on the board,
detached in `screen` (monte3: through slurm). Each script finds the repo from its own
location and documents its usage in its header.

| folder | contents |
|---|---|
| `notes7/` | `docs/notes7` (RVV code for VLEN 128 and 256): `monte3.sh`, the one entry point for monte3 from the laptop (`start` = push + slurm build/verify job + timing job, `status`, `fetch` to `00_private_data/monte3/`, `help`); `ldc_reference.py`, `compare_fields.py` (copies) |
| `presentation6/` | `docs/presentation6`: presentation5 as one self-contained set for bananapi and monte3 (guide: `presentation6/README.md`): `machine.sh` the machine profile (VLEN, `-march`, compilers, cores, MPI launch), `recon.sh` read-only look at a machine, `setup.sh` venv, modules and checks (writes `machine.env`), `all.sh` / `peak.sbatch` prepare (build, audit, verify), steps check, timing matrix |
| `presentation5/` | the timing protocol of `docs/presentation5` (times presentation4's verified executables, builds nothing): `run.sh` one experiment, 60 timed steps, variants interleaved, board state recorded (`env_record.sh`); `matrix.sh` the presentation4 matrix plus the fair scalar/RVV pair with that protocol; `steps_check.sh` + `steps_table.py` the check that 60 steps measure the same as 200 |
| `presentation4/` | (step-by-step guide: `presentation4/README.md`) all numbers and checks of `docs/presentation4` (lid-driven cavity app `SweepgenLdcCPU`, GCC and Clang): `prepare.sh` builds, audits (`check_build.py`, `check_walls.py`) and verifies (`verify.sh`: NumPy oracle `ldc_reference.py` + `compare_fields.py`, decomposition) one precision; `all.sh` times all builds through `{scalar,autovec,rvv}.sh` and `run.sh`; `extras.sh` method checks (warm-up, vector-tree scalar builds), `recheck.sh` the same comparisons with interleaved runs; `speedup_check.sh` the headline speedups, interleaved; `streams_check.sh` + `streams_table.py` the stream test with the X60's counters (cliff, address offsets, the program's misses); `cavity_movie.py` the flow film (x86 build `build_x86.sh`; frames, AVI for pdfpc, GIF); `speedup_table.py` the second session; `check_figures.py` every plotted number against the logs; `summary.py` tables; `slide_numbers.py` every number of the result slides (`--tex`: the figure coordinates and table rows) |
| `presentation3/` | all whole-program numbers of `docs/presentation3`: `all.sh` runs `scalar.sh`, `autovec.sh` and `rvv.sh`, which all build and time through `run.sh` |
| `walberla-e2e/` | waLBerla end-to-end runs of `docs/notes2` and `docs/notes3`: `bench.sh` (one build dir), `all.sh` (compiler × precision), `mpi.sh`, `followup.sh` |
| `pystencils-lbm/` | standalone D2Q9 harness: `rvv_check.py` (RVV vs generic correctness), `baselines.sh` |
| `common/` | `walberla_summary.py`: merges the result logs into one table |
| `legacy-vla/` | probes for the removed VLA-era API; they no longer run, kept for reference |

Naming: one kebab-case folder per experiment; snake_case files without the folder's prefix.

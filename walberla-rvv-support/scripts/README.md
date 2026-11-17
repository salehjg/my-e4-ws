# scripts

Benchmarks and checks for the Banana Pi board (SpacemiT K1). Sync with `bash push.to.sh bananapi`,
then run them on the board, detached in `screen`. Each script finds the repo from its own
location and documents its usage in its header.

| folder | contents |
|---|---|
| `presentation3/` | all whole-program numbers of `docs/presentation3`: `all.sh` runs `scalar.sh`, `autovec.sh` and `rvv.sh`, which all build and time through `run.sh` |
| `walberla-e2e/` | waLBerla end-to-end runs of `docs/notes2` and `docs/notes3`: `bench.sh` (one build dir), `all.sh` (compiler × precision), `mpi.sh`, `followup.sh` |
| `pystencils-lbm/` | standalone D2Q9 harness: `rvv_check.py` (RVV vs generic correctness), `baselines.sh` |
| `common/` | `walberla_summary.py`: merges the result logs into one table |
| `legacy-vla/` | probes for the removed VLA-era API; they no longer run, kept for reference |

Naming: one kebab-case folder per experiment; snake_case files without the folder's prefix.

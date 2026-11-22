# scripts/presentation6

`docs/presentation6`: presentation5's builds, checks and timing protocol as one self-contained set that runs
unchanged on **bananapi** (SpacemiT K1) and **monte3** (Monte Cimone, slurm partition `peak`, Sophgo SG2044).
Everything machine-specific is in `machine.sh`, plus `<base>/presentation6/machine.env`, which `setup.sh` writes.
Explicit (RVV intrinsics) variants run only where VLEN ≥ pystencils' `RVV_VLEN` (256); elsewhere they are skipped.

```bash
bash push.to.sh monte3                     # laptop, after every change (see the last point below)
# monte3 login node, in ~/02_ws/my-e4-ws (every node-side step is a batch job on the one peak node):
bash scripts/presentation6/recon.sh 2>&1 | tee ../recon.txt                  # read-only report
bash scripts/presentation6/submit.sh setup.sh                                 # until SETUP PASS (30 min limit)
bash scripts/presentation6/submit.sh prepare.sh f64                           # build, audit, verify (4 h limit)
bash scripts/presentation6/submit.sh --time=08:00:00 all.sh                   # or PARTS="steps matrix" ...
```
On monte3, `setup.sh` loads the modules `gcc-14.2.0` and `openmpi-5.0.6` (the milkv Open MPI; the system's Open
MPI 4.1.5 has a helper thread that spins at 100 % CPU and halves every core, see `docs/notes7`). Build trees made
before this change were configured with the system MPI and are reused as they are: remove them first
(`rm -rf ~/02_ws/presentation6/build-*` on monte3), then `setup.sh` and `prepare.sh` again.

`submit.sh` creates the log folder (slurm does not: without it a job fails at once and writes nothing), submits
through `peak.sbatch` and prints the log file. Job output: `../presentation6/logs/p6-<script>-<job id>.out`; each part also writes its own log there.

On bananapi: `screen -dmS presentation6-all bash -c "bash scripts/presentation6/all.sh > ../presentation6/logs/all.log 2>&1"`
(`BUILD_ROOT=/home/bananapi/saleh/presentation4 PARTS="steps matrix"` times presentation4's verified executables).

- `all.sh` parts: `prepare.sh` (`build.sh`, `check_build.py`, `check_walls.py`, `verify.sh` with `ldc_reference.py` and
  `compare_fields.py`), `steps_check.sh` (+ `steps_table.py`), `matrix.sh` (`run.sh`, `env_record.sh`, `summary.py`),
  `thermal_check.sh`. `DRY_RUN=1` lists them.
- `push.to.sh` again after a change: fine on monte3 (no clock skew, recon round 1), and only prepare.sh builds, so a
  push never changes the timed executables. On bananapi, whose clock is ~46 h behind the laptop, sync only this folder
  once build trees exist, or the next prepare.sh rebuilds everything:
  `rsync -az --exclude __pycache__ scripts/presentation6/ bananapi:/home/bananapi/saleh/my-e4-ws/scripts/presentation6/`

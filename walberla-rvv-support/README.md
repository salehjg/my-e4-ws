# waLBerla + RVV 1.0

RISC-V Vector (RVV 1.0) support for pystencils and waLBerla, and the experiments behind it. The two forks are
submodules (`submodules/pystencils`, `submodules/walberla`). `docs/` has one folder per note or presentation (plan,
progress log, raw logs, slides); `scripts/` has the matching scripts (`scripts/README.md`). `docs/manual/` collects
the reports (`./build.sh`), `docs/papers/` the literature. `scripts-legacy/` configures, builds and times the
benchmarks of waLBerla's legacy core with pystencils 1.4 (`docs/notes8`, `scripts-legacy/README.md`; report 4
in `docs/manual/` explains that stack).

Machines:

- **bananapi**: Banana Pi BPI-F3, SpacemiT K1 (8 X60 cores, VLEN 256). `ssh bananapi`; everything under
  `/home/bananapi/saleh`; long jobs run detached in `screen`.
- **monte3**: Monte Cimone (University of Bologna), slurm partition `peak`: one Sophgo SG2044 node (64 C920v2 cores,
  VLEN 128). `ssh monte3` (x86-64 login node); compute only through slurm. Modules: `gcc-14.2.0` (GCC 14.2), then
  `openmpi-5.0.6` (milkv Open MPI 5.0.6). Not the system Open MPI 4.1.5 (`/usr/bin/mpirun`): its helper thread spins
  at 100 % CPU, takes half of each core and makes every message wait ~10 ms; some runs hang (`docs/notes7`). Never
  read or set anything about frequency, power or temperature there. Reports using its data must acknowledge the
  Monte Cimone project and cite DOI 10.1007/978-3-032-07612-0_44.

Helpers in this folder: `push.to.sh <machine>` (rsync of this folder; `--repo <remote folder>`: of the whole git
repository, with its git data), `test.on.bananapi.sh <pytest args>` (pystencils
tests on the K1), `run.on.bananapi.sh <command>` (any command on the K1, with the board venv and our pystencils).

The sections follow the order of the work. Commands run on the laptop from this folder unless a comment says otherwise.

## notes: first RVV plans (VLS and VLA)

`docs/notes/`: the first implementation plans and their progress log, an RVV primer and notes on pystencils' CPU
backends and waLBerla's code generation.

```bash
# Nothing to run any more: notes2 replaced this code (VLS and VLA modes, about 2.6k lines) with the VLS backend.
# scripts/legacy-vla/ keeps its probes (vlen_sweep, perf_probe, roofline) for reference; they need the removed API.
```

## notes2: the VLS backend for VLEN 256

`docs/notes2/rvv-vls256-only-{plan,progress}-opus5.5.md`: the RVV backend modelled on the AVX backend (fixed VLEN 256),
its tests on the K1, the D2Q9 baselines and the RVV-versus-autovec kernel experiment.

```bash
bash test.on.bananapi.sh tests/nbackend/test_rvv_codegen.py tests/nbackend/test_rvv_execution.py -q   # RVV tests on the K1
bash run.on.bananapi.sh python scripts/pystencils-lbm/rvv_check.py    # D2Q9 collide: RVV against the generic CPU code
bash run.on.bananapi.sh bash scripts/pystencils-lbm/baselines.sh      # scalar / autovec / RVV, GCC and Clang
bash run.on.bananapi.sh bash misc/rvv-vs-autovec/run.sh               # out-of-tree RVV-versus-autovec kernels
```

## notes3: toward an 8× speedup on the K1

`docs/notes3/rvv-8x-speedup-{plan,progress}-fable5.2.md`: the X60 kernel lab (memory streams, prefetcher), software
prefetch, in-place AA streaming, the direction-split loop, and the waLBerla end-to-end matrix (`SweepgenLbmCPU`).

```bash
PYTHONPATH=submodules/pystencils/src python misc/x60-lab/lab/gen.py misc/x60-lab/lab/src   # lab kernels (python with lbmpy)
bash push.to.sh bananapi
# on the board, detached (logs in /home/bananapi/saleh):
cd /home/bananapi/saleh && screen -dmS walberla-all bash -c "bash my-e4-ws/scripts/walberla-e2e/all.sh > walberla-all.log 2>&1"
screen -dmS walberla-followup bash -c "bash my-e4-ws/scripts/walberla-e2e/followup.sh > walberla-followup.log 2>&1"  # reruns, multi-core
cd /home/bananapi/saleh/my-e4-ws/misc/x60-lab/lab && bash run.sh   # the kernel lab: build and run the generated variants
```

## presentation3: the first talk

`docs/presentation3/`: a 15-minute talk on the RVV work; every whole-program number (scalar, autovec, RVV; f32, f64;
1, 4, 8 cores) comes from one session of `scripts/presentation3/all.sh`.

```bash
bash push.to.sh bananapi
# on the board, detached (about 4 h):
cd /home/bananapi/saleh/my-e4-ws && screen -dmS walberla-presentation bash -c "bash scripts/presentation3/all.sh > ../walberla-presentation.log 2>&1"
cd docs/presentation3 && ./build.sh && pdfpc build/slides.pdf    # the slides, on the laptop
```

## presentation4: the lid-driven cavity, GCC and Clang

`docs/presentation4/`: presentation3 redone on the new lid-driven-cavity app `SweepgenLdcCPU`, with Clang, truly scalar
baselines and a verification chain (NumPy reference solution, decomposition check). Guide: `scripts/presentation4/README.md`.

```bash
bash push.to.sh bananapi      # once; afterwards sync only scripts/presentation4/ (the board's clock is behind)
# on the board, in /home/bananapi/saleh/my-e4-ws, detached; prepare f64, then f32, each must end with PREPARE PASS (about 7 h):
mkdir -p ../presentation4/logs && screen -dmS presentation4-prepare bash -c "bash scripts/presentation4/prepare.sh f64 > ../presentation4/logs/prepare-f64.log 2>&1"
screen -dmS presentation4-all bash -c "bash scripts/presentation4/all.sh > ../presentation4/logs/all.log 2>&1"   # timing matrix and more (about 11 h)
bash scripts/presentation4/laptop.sh && pdfpc docs/presentation4/build/slides.pdf   # laptop: x86 film, board logs, figure checks, slides
```

## notes5: audit of presentation4

`docs/notes5/`: findings F1-F21 and the board experiments E1-E10 (`audit-findings-opus5.5.md`), proposed slide changes.
The experiments time presentation4's verified executables; nothing is rebuilt.

```bash
ssh bananapi mkdir -p /home/bananapi/saleh/notes5 && scp docs/notes5/board/* bananapi:/home/bananapi/saleh/notes5/
# on the board, one experiment at a time (audit_e1.sh ... audit_e10.sh; each header says what it measures):
screen -dmS notes5-e1 bash -c "bash /home/bananapi/saleh/notes5/audit_e1.sh > /home/bananapi/saleh/notes5/e1.log 2>&1"
```

## presentation5: presentation4 with the audit's corrections

`docs/presentation5/`: the presentation4 deck with the notes5 corrections and a shorter timing protocol (60 steps,
variants interleaved, machine state recorded). Times presentation4's verified executables. Guide: `scripts/presentation5/README.md`.

```bash
rsync -az --exclude __pycache__ scripts/presentation5/ bananapi:/home/bananapi/saleh/my-e4-ws/scripts/presentation5/
# on the board, in /home/bananapi/saleh/my-e4-ws, detached (about 1 h 45 min):
mkdir -p ../presentation5/logs && screen -dmS presentation5-matrix bash -c "bash scripts/presentation5/matrix.sh > ../presentation5/logs/matrix.log 2>&1"
cd docs/presentation5 && ./build.sh && pdfpc build/slides.pdf    # the slides, on the laptop
```

## presentation6: the same scripts on bananapi and monte3

`docs/presentation6/`: presentation5's protocol as one self-contained script set (`scripts/presentation6/`, guide in
its README) for both machines; `machine.sh` holds what differs. On monte3 (VLEN 128) the explicit RVV variants are
skipped: the backend of this version supports VLEN 256 only (notes7 adds 128). Its monte3 data (presentation6
archive) was made with the system Open MPI 4.1.5; `setup.sh` now loads `openmpi-5.0.6` (remove old build trees first,
see its README).

```bash
bash push.to.sh monte3
# monte3 login node, in ~/02_ws/my-e4-ws (each step is a batch job on the peak node; logs in ../presentation6/logs):
bash scripts/presentation6/recon.sh 2>&1 | tee ../recon.txt              # read-only report of the node
bash scripts/presentation6/submit.sh setup.sh                             # modules, Python 3.12, venv, checks: SETUP PASS
bash scripts/presentation6/submit.sh prepare.sh f64                       # build, audit, verify; then the same with f32
PARTS="steps matrix" bash scripts/presentation6/submit.sh --time=08:00:00 all.sh   # steps check and timing matrix
# bananapi instead, on the board in /home/bananapi/saleh/my-e4-ws:
mkdir -p ../presentation6/logs && screen -dmS presentation6-all bash -c "bash scripts/presentation6/all.sh > ../presentation6/logs/all.log 2>&1"
```

## notes7: one RVV backend for VLEN 128 and 256, and one script for monte3

`docs/notes7/rvv-vlen128-{plan,progress}-opus5.5.md`: targets `RISCV_RVV256` (K1) and `RISCV_RVV128` (SG2044) on one
backend, the VLEN measured by CMake, tuning knobs (LMUL, prefetch, split sizes), and `scripts/notes7/monte3.sh`, which
pushes, runs the build/verify and timing jobs on monte3 (with the milkv Open MPI 5.0.6), and fetches the logs to
`00_private_data/monte3/` (not in git). It also found why multi-process runs on monte3 were slow or hung: the system
Open MPI 4.1.5 (MPI test job `mpitest`, `mpi_bench.cpp`).

```bash
cd submodules/pystencils && PYTHONPATH=src python -m pytest -q -o addopts="" tests/nbackend/test_rvv_codegen.py tests/nbackend/test_rvv_target.py tests/nbackend/test_rvv_qemu.py && cd ../..   # RVV tests, QEMU at VLEN 128 and 256 (qemu-riscv64, riscv64-linux-gnu-g++)
bash scripts/notes7/monte3.sh start     # push, then the build/verify job and the timing job on monte3
bash scripts/notes7/monte3.sh status    # the jobs and the last lines of their logs
bash scripts/notes7/monte3.sh fetch     # the logs, to 00_private_data/monte3/<run>/
bash scripts/notes7/monte3.sh start mpitest   # optional, minutes: MPI health check (mpi_bench) at 2-64 processes
bash scripts/notes7/monte3.sh help      # what each job does, options, the rules for monte3
```

## presentation7: the K1 and the SG2044 in one deck

`docs/presentation7/`: RVV code generation for 256- and 128-bit vectors, measured on the K1 (presentation4's session)
and on the SG2044 (notes7's full monte3 run, jobs 8565/8566). Shared material first, then a K1 part, an SG2044 part,
and the cross-machine comparison. Every result number comes from `scripts/presentation7/slide_data.py`, which checks
the logs first (run counts, field hashes, energies, verification, the job's own best-of table) and writes
`docs/presentation7/tables/`. The SG2044 raw logs stay in `00_private_data/`; reports with them must acknowledge Monte
Cimone (DOI 10.1007/978-3-032-07612-0_44).

```bash
python3 scripts/presentation7/slide_data.py     # checks, then tables/ (default: the last fetched monte3 run)
cd docs/presentation7 && ./build.sh && pdfpc build/slides.pdf
```

## notes8: RVV on waLBerla's legacy core (pystencils 1.4, waLBerla-wind)

`docs/notes8/rvv-legacy-wind-{plan,progress}-opus5.5.md`: waLBerla-wind runs on waLBerla's legacy core, whose code
generation is pystencils 1.4, so the RVV work is redone there (branches `rvv-support-legacy` of this repository and
the three submodules). pystencils 1.4's own RVV backend is called `rvv.lgcy`, ours `rvv.our1` (a copy of it plus
options: `vls128`/`vls256`, `m2`/`m4`, `vf`, `fma`, `pf<N>`); every variant is named
`<streaming>_<backend>[-<option>...]`, e.g. `aa_rvv.our1-vf-fma-pf128` (`scripts-legacy/README.md`, Names).
`scripts-legacy/` builds, checks and times two apps in these variants (waLBerla-wind's `BenchmarkApp_cpu_uniform`,
float32, and waLBerla's `UniformGridCPU`, float64) on the laptop, the K1 (screen) and monte3 (slurm), one
`results-legacy/<time>-<random>/bench.json5` per run, and makes animations of the flows apart from the timing. It
found misaligned MPI buffers in waLBerla's generated pack infos (bus error on the K1 with 2 or more processes; fix
and upstream PR text in `docs/bug-fix-pr/walberla-packinfo-buffer-alignment/`).

```bash
cd submodules/pystencils && PYTHONPATH=src ../../../.venv-legacy/bin/python -m pytest -q -o addopts="" tests/test_rvv_qemu.py && cd ../..   # rvv.lgcy and rvv.our1 under QEMU at VLEN 128/256/512
python3 scripts-legacy/remote.py push && python3 scripts-legacy/remote.py start all wind   # the K1: build, check, time (screen)
python3 scripts-legacy/remote.py status; python3 scripts-legacy/remote.py fetch
python3 scripts-legacy/bench.py table results-legacy/<run>                                # medians, speedups, checksums
python3 scripts-legacy/bench.py animate wind-x86 && python3 scripts-legacy/bench.py render build/legacy/animations/<run>
```

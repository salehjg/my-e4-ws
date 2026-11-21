# Plan (Opus 5.5): one RVV backend for VLEN 128 and 256, with tuning knobs, and one script for monte3

Written 2026-11-21. Predecessors: [`../notes2/rvv-vls256-only-plan-opus5.5.md`](../notes2/rvv-vls256-only-plan-opus5.5.md)
(why the backend is VLS and AVX-like), [`../presentation6/presentation6-progress-opus5.5.md`](../presentation6/presentation6-progress-opus5.5.md)
(monte3 facts: VLEN 128, toolchain, slurm, what already works there).

## 1. Context

pystencils' RVV backend generates vector-length-specific (VLS) code for exactly 256-bit registers (SpacemiT K1).
monte3's peak node (Sophgo SG2044) has 128-bit registers, so the 5 explicit RVV variants cannot run there: VLS-256
code on VLEN 128 silently processes half the lanes (each intrinsic asks for `vl = 8` f32, the hardware gives 4, the
loop still steps by 8). presentation6 therefore skipped them on monte3, and its f64 build showed that no other build
vectorizes the main LBM loop (autovec = scalar checksums). Without explicit RVV code, monte3 has no vector numbers.

Goals, decided with the user:
1. **One backend, no duplicate.** The backend generates correct code for **VLEN 128 or 256**, selected at build time
   from the build machine's CPU (K1 → 256, SG2044 → 128), overridable. K1 code stays byte-identical to today.
2. **Tuning knobs instead of per-chip backends.** What may differ between the two microarchitectures (X60, C920v2)
   becomes a user option: LMUL, software prefetch, split block sizes, so that a later sweep (autotuning) can find the
   best combination on each machine.
3. **One script** that pushes the repo to monte3, prepares it, submits the slurm jobs (build + verify, then timing)
   and copies the results back, with help text that always says what to run next.

## 2. Where 256 is hard-coded today

| place | what |
|---|---|
| `pystencils/backend/platforms/rvv.py` | `RVV_VLEN = 256`, read only by `_lmul` (`m1` = VLEN, `mf2` = VLEN/2 for SEW ≤ 32; no `m2`+) |
| `pystencils/codegen/target.py` | `default_vector_lanes`: `256 // bits` for `RISCV_RVV` |
| `pystencils/jit/cpu/compiler_info.py` | `-march=rv64gcv_zvl256b` (JIT only) |
| `pystencils_runtime/rvv.hpp` | `#error` unless `__riscv_v_min_vlen >= 256`; reduction helpers with fixed 4/8 lanes; `ctr64_to_32` with a literal `4`; `set_*`/`horizontal_*` only for `m1`/`mf2` types |
| waLBerla `cmake/compileroptions/{GNU,Clang}.cmake` | `-march=rv64gcv_zvl256b` whenever the ISA string has `v` |
| apps `SweepgenLdcCPU`, `SweepgenLbmCPU` | explicit variants use `Target.CurrentCPU`, which on any RISC-V with V resolves to the 256 backend |

RVV type names have no fixed size (`vfloat32m1_t` = one register: 8 f32 on the K1, 4 on the SG2044). What is
VLEN-specific in the generated code are the numbers pystencils writes in (vl, loop step, constant vectors) and the
header's reduction lane counts. `/proc/cpuinfo` reports no VLEN, so it is measured from the `vlenb` register.

## 3. Design

**Target = what the hardware is (correctness). Options = how to generate (performance).**

| | what | where | chosen by |
|---|---|---|---|
| target | VLEN 128 or 256 | `Target.RISCV_RVV128`, `Target.RISCV_RVV256`; `RISCV_RVV` stays an alias of `RISCV_RVV256` | CMake measures VLEN on the build machine (overridable) |
| option | LMUL 1, 2, 4 (default 1) | new `cpu.vectorize.rvv_lmul` | per variant: app argument `--rvv-lmul` |
| option | software prefetch distance (default off) | existing `cpu.vectorize.prefetch_distance` | per variant: existing `--prefetch-distance` |
| option | split block sizes BY,GM,GP | existing app argument `--split` | per variant |

One backend class (`RvvCpu`, `SelectIntrinsicsRvv`) serves both targets, like pystencils' `X86VectorCpu` serves SSE, AVX
and AVX-512. The target fixes VLEN, the default lane count and the JIT `-march`, exactly as for x86. Vector width =
LMUL × VLEN, lanes = LMUL × VLEN / element bits; LMUL 1 at VLEN 256 gives today's code.

Tuning knobs are per-variant generator arguments, not per-build CMake settings, so a sweep can add many combinations
as extra targets of one build tree (the waLBerla libraries are built once; each combination costs only its own
generation and compile). The sweep itself is future work; this plan only provides the knobs.

```
CMake (build machine)                           sweepgen config module            app generator script
try_run vlenb probe ─► WALBERLA_RISCV_VLEN ─────► build_config.riscv_vlen ───► target RISCV_RVV<VLEN>
        │                                                                        + --rvv-lmul, --prefetch-distance, --split
        └─► -march=rv64gcv_zvl<VLEN>b (every compile line) ─► __riscv_v_min_vlen ─► checked by rvv_vlen<VLEN>.hpp
```

The generated code includes a header named after the VLEN it was generated for, which `#error`s unless the compiler
flags promise at least that VLEN: a mismatch is a compile error, never silently wrong results. Code for VLEN 128
also runs correctly (at half width) on VLEN 256 hardware; the reverse is refused.

Future knobs, listed here, not built now: loop unrolling (several vectors per iteration: may help the in-order X60
more than the out-of-order C920v2), non-temporal store hints (the SG2044 has Zihintntl), `cpu.loop_blocking`,
compiler and `-mtune`. Note for the prefetch knob: the SG2044 does not report Zicbop, so its prefetch instructions run
as no-ops there (they are encoded as hints); the sweep will show whether `_pf` variants help at all on monte3.

## 4. Implementation steps

### Step 1: pystencils (fork `submodules/pystencils`)

- `codegen/target.py`: new private flags for the VLEN; `RISCV_RVV256`, `RISCV_RVV128`, alias `RISCV_RVV =
  RISCV_RVV256`; `default_vector_lanes` → `VLEN // bits` from the target; docstrings. `CurrentCPU` on RISC-V keeps
  resolving to 256 (Python cannot measure VLEN); waLBerla passes the target explicitly (step 2).
- `codegen/config.py`: `VectorizationOptions.rvv_lmul: BasicOption[int] = BasicOption()` (1, 2 or 4; `None` = 1).
- `codegen/driver.py`: `Target._RVV in target` → `RvvCpu(ctx, vlen=<from target>, lmul=<option or 1>)`.
- `codegen/cpu_loop_strategies.py`: if `lanes` is unset on an RVV target, `lanes = lmul × default_vector_lanes`.
- `backend/platforms/rvv.py`: `RvvCpu(ctx, vlen, lmul)`; `_lmul(vtype, vlen)` generalised to register-group ratios
  ½…4 (`mf2`, `m1`, `m2`, `m4`; fractional only where SEW allows it under ELEN 64); `_sfx`, `_rvv_type` take `vlen`;
  `required_headers` → `rvv_vlen<vlen>.hpp`; reduction calls pass the lane count as a template argument; the RNG
  (Philox) stays LMUL 1 only (raises otherwise; the LBM kernels do not use it). Keep the line `RVV_VLEN = 256`
  (presentation6's `machine.sh` parses it).
- `include/pystencils_runtime/rvv.hpp`: guard `>= 128`; `set_*` and `horizontal_*` helpers for the `m2`/`m4` types
  too, horizontal ones as `template <size_t LANES>`; `ctr64_to_32` via `__riscv_vsetvlmax_e32mf2()`.
  New `rvv_vlen128.hpp`, `rvv_vlen256.hpp` (VLEN guard + `#include "rvv.hpp"`, a few lines each).
- `jit/cpu/compiler_info.py`: `-march=rv64gcv_zvl<VLEN>b` by target.
- Tests: `tests/nbackend/test_rvv_codegen.py`, `test_rvv_target.py` parametrized over the two targets and LMUL 1/2/4,
  with the existing RVV-256/LMUL-1 expectations left literally as they are (the K1 regression check); new
  `test_rvv_qemu.py` (§5).

### Step 2: waLBerla (fork `submodules/walberla`)

- New `cmake/compileroptions/RiscvVlen.cmake` (`include_guard`, included from the riscv64 branches of `GNU.cmake` and
  `Clang.cmake`): if `WALBERLA_RISCV_VLEN` is unset and the ISA has `v`, `try_run` an inline probe
  (`SOURCE_FROM_CONTENT`, `csrr vlenb`, `-march=rv64gcv`) and cache the result; print
  `RISC-V VLEN: 128 bits (measured)`; refuse values other than 128/256.
- `GNU.cmake`, `Clang.cmake`: `-march=rv64gcv_zvl${WALBERLA_RISCV_VLEN}b`. (GNU.cmake's missing C flag stays: it
  only affects sqlite3.c, which no benchmark links.)
- `sweepgen/cmake/SweepgenConfig.template.py`, `sweepgen/src/sweepgen/build_config.py`: field `riscv_vlen`; the
  build config's CPU target resolves to `Target.RISCV_RVV<riscv_vlen>` on RISC-V. The config module is already a
  dependency of every generated file, so a different VLEN regenerates everything.
- Apps `SweepgenLdcCPU.py`, `SweepgenLbmCPU.py`: the explicit variant takes the build config's target (instead of
  `Target.CurrentCPU`; `--explicit-target` still overrides); new argument `--rvv-lmul` (default 1) next to
  `--prefetch-distance` and `--split`. The 11 variants of the CMakeLists stay as they are (LMUL 1, prefetch 128 B,
  split 1,5,3 / 2,5,3), so the presentation protocol is unchanged.

### Step 3: the monte3 script (`scripts/notes7/`)

Files (folder and names per `scripts/README.md`: kebab-case folder, snake_case files):

| file | role |
|---|---|
| `monte3.sh` | the single entry point (laptop commands and the slurm job bodies) |
| `ldc_reference.py` | NumPy reference solution of the lid-driven cavity (copied from `scripts/presentation6`) |
| `compare_fields.py` | cell-by-cell field comparison (copied from `scripts/presentation6`) |

It uses nothing else in `scripts/` except `push.to.sh`. Commands, run on the laptop from the repo root:

| command | does | prints next |
|---|---|---|
| `bash scripts/notes7/monte3.sh start [all\|build\|time]` | `push.to.sh monte3`, then over `ssh monte3`: `sbatch` the build job, and the timing job with `--dependency=afterok:<build job>` | job ids, `status` and `fetch` commands |
| `bash scripts/notes7/monte3.sh status` | `squeue -u $USER`, last lines of this run's job logs | whether to wait or fetch |
| `bash scripts/notes7/monte3.sh fetch` | `rsync -a` of `monte3:02_ws/notes7/logs/` to `00_private_data/monte3/` (logs only, never build trees) | where the files are; the Monte Cimone acknowledgement and citation reminder |
| `bash scripts/notes7/monte3.sh help` | usage, what each step does, the rules it follows | |

The two job bodies are modes of the same file, started by `sbatch` with all options on the command line (no
`#SBATCH` lines): `--partition=peak --nodes=1 --exclusive --ntasks-per-node=64 --time=<limit>
--output=<base>/notes7/logs/<run>/<job>-%j.out`. The script creates the log folder before submitting.

- **Build job** (`job-build`, limit 4 h; presentation6 measured 62 min per precision for 6 variants, now 11):
  1. Environment: `module load gcc-14.2.0`; Python 3.12.11 built from python.org source into `<base>/python` if
     missing; `<base>/venv` with numpy, sympy 1.14.0, appdirs, joblib, packaging, pyyaml, fasteners, py-cpuinfo, and
     lbmpy 2.1.1 + pystencilssfg 0.1.1 without dependencies (so PyPI's pystencils never shadows the repo's). Both
     are reused when present (the presentation6 ones are).
  2. Build, per compiler (GCC 14.2, Clang 17) and precision (f64, f32): a scalar tree (`-march=rv64gc` everywhere)
     and a vector tree (waLBerla's own flags, now `zvl128b` from the measured VLEN); all 11 variants. Link flags
     `-Wl,-rpath-link,/usr/lib64/openmpi/lib:/usr/lib64` (the module's linker does not find libmpi's own
     dependencies; link-time search only).
  3. Audit (short): the generated sweeps' last `-march` (scalar `rv64gc`, vector `rv64gcv_zvl<VLEN>b`), 0 vector
     instructions in scalar executables, more than 0 in the explicit kernels, `WALBERLA_RISCV_VLEN` from the cache.
  4. Verify (presentation6's checks): every executable against `ldc_reference.py` (1 process 16³ at 100 and 101
     steps, 2 × 16³, 6 × 8³), and 1 × 32³ against 8 × 16³ bit-identical; GCC against Clang. The sha256 of every
     verified executable goes into the verify log.
- **Timing job** (`job-time`, limit set from the first run; starts only if the build job succeeded): presentation6's
  protocol: 60 timed steps after 10 warm-up, 3 interleaved rounds, groups scalar / autovec / rvv, GCC and Clang,
  f32 and f64, 1, 4, 8, 16, 32, 64 MPI processes (one 64³ block each), plus the fair pair (output only at the end).
  Refuses any executable whose sha256 is not in the verify log. Records the load and the busy cores before each
  round. A small best-of table at the end.
- **Rules it follows** (monte3 is a public cluster supervised by professors): only `sbatch` jobs that request what
  they use, on the one peak node, with realistic time limits; `mpirun` inside the allocation; writes only under
  `~/02_ws` (repo copy, `venv`, `python`, `notes7`); never reads or sets anything related to power, frequency or
  temperature; never looks at other users' jobs, processes or files; network only for the first setup (python.org,
  PyPI); no ssh to compute nodes.
- Left out on purpose (keep it simple): the 30/60/200-steps check (the timing logs show each run's wall time, so
  too-short runs are visible), the thermal check (forbidden), the full compile-command audit of all library files
  (unchanged since presentation6), any knob sweep (future work, §3).

Repo hygiene: `00_private_data/` is added to `.gitignore` and to `push.to.sh`'s excludes, so the copied results
are neither committed nor pushed back to the cluster. A row for `scripts/notes7/` in `scripts/README.md`.

## 5. Verification

1. **Laptop, pystencils tests:** `test_rvv_codegen.py` / `test_rvv_target.py` pass with the RVV-256 / LMUL-1
   expectations unchanged (proof that K1 code does not change) and with the new VLEN-128 and LMUL-2/4 expectations.
2. **Laptop, QEMU** (`test_rvv_qemu.py`, skipped if `qemu-riscv64` or `riscv64-linux-gnu-g++` are missing; both are
   installed here): a few kernels (elementwise with odd extents, f64→f32 cast, a reduction, a small 2D stencil) are
   generated for both targets and LMUL 1/2/4, cross-compiled with `-march=rv64gcv_zvl<N>b -static`, run under
   `qemu-riscv64 -cpu rv64,v=true,vlen=<N>` and compared with NumPy. Also VLEN-128 code at `vlen=256` (must work)
   and VLEN-256 code with `zvl128b` (must fail to compile: the guard).
3. **monte3, build job:** CMake prints `RISC-V VLEN: 128 bits (measured)`; compile lines end in `-march=rv64gcv_zvl128b`
   without presentation6's override; the generated explicit sources include `rvv_vlen128.hpp` and step by 2 (f64)
   / 4 (f32); all 11 variants pass the reference-solution and decomposition checks for both compilers; GCC and
   Clang agree.
4. **monte3, timing job, `fetch`:** logs arrive in `00_private_data/monte3/<run>/`.
5. **K1 (optional, later):** a rebuild with presentation6's scripts measures 256 and generates the same sources as
   presentation4 (step 1 already shows the code is identical).

## 6. Order of work

Step 1 with its local tests first (no machine time). Then step 2, then step 3 written and dry-run on the laptop (help,
command lines printed instead of submitted). Then one `start` on monte3. Nothing is committed (the user commits).
Any publication or report with monte3 data must acknowledge the Monte Cimone project and cite
DOI 10.1007/978-3-032-07612-0_44 (Monte Cimone terms).

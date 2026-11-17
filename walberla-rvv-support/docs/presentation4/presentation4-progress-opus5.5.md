# presentation4: progress log

The running record for `presentation4-plan-opus5.5.md`. Every claim names the command or log behind it.
Newest entries at the bottom.

## Status

| stage | content | state |
|---|---|---|
| 0 | plan and progress files, clone of presentation3, ignore and push rules | plan and log written; clone not started |
| 1 | app `SweepgenLdcCPU`, local x86 build, verification chain on x86 | not started |
| 2 | board: f64 trees (GCC, Clang, vector and scalar), build audit, f64 verification | not started |
| 3 | board: f32 trees and f32 verification | not started |
| 4 | board: full matrix, 1/4/8 cores, timing-stability check | not started |
| 5 | logs copied to `board-logs/`, summary tables | not started |
| 6 | slides | not started |
| 7 | final audit (nothing committed) | not started |

## 2026-11-17: planning (read-only investigation)

Nothing was changed in the repository, the submodules or on the board during planning.

**LDC codes in waLBerla, and why none of them can use the RVV backend**
- `apps/benchmarks/UniformGridCPU`: LDC scenario `ldc_setup` in `simulation_setup/benchmark_configs.py:37`.
  The N face is UBB, and W/E/S/B/T are NoSlip, all at walldistance −1. The lid velocity
  `UBB([0.05, 0, 0])` is at `UniformGridCPU.py:156`; the Scenario default is omega 1.8.
- Generators: `python/pystencils_walberla/*.py` import `pystencils.astnodes`, `pystencils.backends.cbackend`
  and `pystencils.typing`. Checked with `ls submodules/pystencils/src/pystencils`: there is no `astnodes.py`,
  no `backends/` and no `typing/` package, only `typing.py`.
- `tests/lbm_generated/LDC.cpp` uses `src/lbm_generated/sweep_collection/D3Q19SRT.h`. That file was
  pre-generated with pystencils 1.x (`sweep_collection_generation_script.py`).
- `apps/tutorials/lbm/03_LBLidDrivenCavity.cpp` uses the hand-written `lbm::D3Q19<SRT>`, `NoSlip` and `SimpleUBB`.

**The sweepgen route**
- `sweepgen/src/sweepgen/boundaries/sparse.py:215-262` (`SparseBoundary._get_kernel_assignments`):
  `streaming_pattern = "pull"` is hardcoded at line 222, with `prev_timestep = Timestep.BOTH`.
- `sweepgen/src/sweepgen/boundaries/grid_aligned.py`: only NoSlip and FreeSlip, pull indexing, no UBB.
- lbmpy 2.1.1 `advanced_streaming/indexing.py:38-41`: `BetweenTimestepsIndexing` accepts the in-place
  patterns with `prev_timestep` EVEN or ODD.
- `include/walberla/sweepgen/boundaries/GenericBoundary.hpp`: `fromLinks(pred)` visits every interior cell and
  direction, and the predicate sees `wallCell` in block-local coordinates.
- `apps/examples/FlowAroundSphere/FlowAroundSphereExample.cpp`: transforms `wallCell` to global coordinates and
  compares it with `getDomainCellBB()`. Order: stream-collide, then halo exchange, then the boundary sweeps.
- lbmpy UBB, compressible (`boundaries/boundaryconditions.py:881-905`):
  `f_in(inv d) = f_out(d) − (2/c_s²)·(c_d·u_w)·w_d·rho`, where rho is computed from all `f_out(i)` of the fluid cell.
- `geometry/initializer/BoundaryFromDomainBorder.impl.h:96-126`: walldistance −1 marks the ghost layer,
  including edges and corners, and flags are added (`addFlag`), so the classic setup gives edge cells two flags.

**Board state (`ssh bananapi`, read-only)**
- No screen sessions are running.
- `/home` has 3.1 GB free (90 % used). The existing build dirs are 108-169 MB each.
- Compilers: GCC 14.2.0 (Bianbu), Clang 18.1.8 (Bianbu), cmake 3.28.3.
- `/proc/cpuinfo`: `isa ... _zve64d ...`, `uarch : spacemit,x60`.
- Board venv with the repo's pystencils and sweepgen on PYTHONPATH: numpy 1.26.4, sympy 1.14.0, lbmpy 2.1.1, pystencilssfg 0.1.1.
- `walberla-build` and `walberla-build-gcc-f32` have `WALBERLA_CXX_SUPPORTS_RISCV_HOST_TUNE` empty, so GCC gets no
  `-mtune`. Their CXX_FLAGS include `-march=rv64gcv_zvl256b ... -O3 -DNDEBUG`.
- `walberla-build-clang-{f32,f64}`: there is no flags.make for `SweepgenLbmCPU_explicit_cse_aa_pf`, so Clang never
  built the AA targets. The last Clang runs are `docs/notes3/board-logs/e2e-clang-f{32,64}.log` (pull variants only).

**"Really scalar" check**
- Command: `llvm-objdump -d --no-show-raw-insn walberla-build/apps/benchmarks/SweepgenLbmCPU/SweepgenLbmCPU_scalar_cse_aa`.
- Result: **5,795** RVV instructions. All of them are in waLBerla library functions (`BlockForest::BlockForest`,
  `mpi::writeBufferSerialIO`, `logging::Logging::*`, `SetupBlockForest::init`, ...).
- The same count for `libc.so.6`, `libstdc++.so.6`, `libm.so.6`, `libmpi.so.40` and `libopen-pal.so.40` gives 0 each.
- Compiler defaults: `gcc -Q --help=target` reports `-march=rv64imafdc_zicsr_zifencei`. `clang -dM -E` defines no `__riscv_v`.
- Consequence for the plan: separate scalar build trees, with every file built with `-march=rv64gc -O3`.

**User decisions**
- All 11 variants, including AA and split.
- 1, 4 and 8 cores.
- Compressible SRT, with u_lid 0.05 and omega 1.8.
- waLBerla's default flags for each compiler.
- Everything at -O3.
- The scalar baselines must contain no vector code anywhere.

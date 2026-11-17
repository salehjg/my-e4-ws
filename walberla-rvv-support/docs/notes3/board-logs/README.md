# Raw board logs of notes3

Unchanged copies of the text outputs in `/home/bananapi/saleh/notes3/` on the Banana Pi
(SpacemiT K1), taken at board time 2026-11-12 20:08 CST. The board's clock runs about 1.7 days
behind the laptop's, so all dates in these files are board time. Not copied: binaries, `perf`
data files (`*.data`), the staging tarballs, and the logs of jobs still running at that time
(the jobs queued after `e2e-cg`). `e2e-cg-gcc-f32.log` (20:29 CST), `e2e-cg-gcc-f64.log` and
`e2e-halo-stage.log` (21:26 CST) were copied separately, after they were complete.
The logs of the jobs queued after `e2e-cg` (`e2e-halo`, `lab6`, `lab7`, `e2e-final`; board time
2026-11-12 22:17 to 2026-11-13 06:05 CST) were copied on 2026-11-16, after all of them had finished.

The loop numbers refer to [`../rvv-8x-speedup-progress-fable5.2.md`](../rvv-8x-speedup-progress-fable5.2.md).
The job scripts that wrote them are in `misc/x60-lab/` (`queue_*.sh`, `lab/run.sh`, `pmu_stat.sh`)
and `scripts/` (`walberla_lbm_bench.sh`, `walberla_bench_mpi.sh`).

| file | contents | loop |
|---|---|---|
| `ann-explicit_cse-f32.txt` | `perf annotate` of the explicit_cse f32 sweep | 1 |
| `pmu-gcc-f32-{explicit_cse,scalar_cse}.tsv` | vendor PMU counters of the waLBerla app (`pmu_stat.sh`) | 1 |
| `p2-stream-sweep.txt`, `p2-stream-levers.txt`, `p2-prefetch.txt` | memory probes: stream count sweep, remedies, prefetch | 2 |
| `p2-ops.txt` | per-instruction costs | 5 |
| `pmu-lab-*.tsv` | vendor PMU counters of lab kernels | 4, 7 |
| `e2e-gcc-{f32,f64}.log`, `e2e-clang-{f32,f64}.log` | waLBerla end to end with software prefetch, GCC and Clang | 6 |
| `pytest-rvv.log` | board pytest with prefetch: 130 passed | 6 |
| `lab-aa.log`, `lab-aa64.log`, `pmu-aa.log` | hand AA + direction split, f32 and f64, PMU | 7 |
| `lab2.log` | generated AA, LMUL, Clang tuning | 8 |
| `lab3.log`, `lab3-gate.log`, `lab3.ok`, `pytest-vf2.log` | `.vf`/FMA selector A/B, gates, board pytest retry: 145 passed | 10 |
| `e2e-aa-stage.log`, `e2e-aa-gcc-{f32,f64}.log` | waLBerla end to end with AA streaming and the new selector | 9 |
| `lab4.log` | compiler scheduling models | 11 |
| `lab5.log` | row pointers / constants A/B, field alignment, THP | 12 |
| `perf-e2e-{aa,pull}.{txt,run}` | profiles of the AA and pull applications | 12 |
| `e2e-mpi.log`, `walberla-mpi-np{4,8}-gcc-{f32,f64}.log` | 4 and 8 processes | 12 |
| `pytest-cg.log` | board pytest with row pointers and `in_register`: 148 passed | 12 |
| `e2e-cg-gcc-f32.log`, `e2e-cg-gcc-f64.log` | waLBerla end to end with row pointers and `in_register` | 12 |
| `e2e-halo-stage.log` | e2e-halo's staging: the keep/revert decision for the Loop 12 change | 13 |
| `e2e-halo-gcc-{f32,f64}.log`, `e2e-halo-thp-gcc-{f32,f64}.log` | waLBerla end to end with the halo copy per PDF slot, without and with transparent huge pages | 13 |
| `perf-halo-aa.{run,txt}` | profile of the AA application with the new halo copy | 13 |
| `lab6.log` | padding between the PDF slices, 4 K pages and THP | 13 |
| `lab7.log` | lab kernels without density/velocity output, with row pointers, and the generated direction-split kernels, 3 rounds | 14 |
| `e2e-final-stage.log`, `e2e-final-gcc-{f32,f64}.log` | waLBerla end to end, every target regenerated, incl. the direction-split AA target | 14 |
| `e2e-final-last-gcc-{f32,f64}.log` | the same binaries with `SWEEPGEN_LBM_OUTPUT=last` (no density/velocity output before the last step) | 14 |
| `perf-final-split.{run,txt}` | profile of the f32 split application, output only in the last step | 14 |
| `presentation3/` | all whole-program numbers of `docs/presentation3` in one session (board time 2026-11-14 09:29 to 13:18 CST): scalar, autovec and rvv experiments, f32 and f64, 1, 4 and 8 cores, written by `scripts/walberla_bench_presentation.sh`; combined table at the end of `walberla-presentation.log` | - |
| `lab/results.tsv` | every lab run (`lab/run.sh`), one line each | 3–12 |
| `queue_clang_e2e.sh`, `queue_mpi.sh` | two job scripts that were kept on the board only | 6 |

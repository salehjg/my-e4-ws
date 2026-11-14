# x60-lab: why the D3Q19 sweep stalls on the SpacemiT X60, and what fixes it

Out-of-tree probes and a kernel lab for `docs/notes3/` (plan and loop-by-loop log:
`docs/notes3/rvv-8x-speedup-{plan,progress}-fable5.2.md`). Nothing here is part of
pystencils or waLBerla; it measures levers before they are moved into the stack.

All tools run **on the board** (`ssh bananapi`, core 2). Outputs go to
`/home/bananapi/saleh/notes3/`, outside the synced repo, because `push.to.sh` mirrors the repo
with `--delete`.

## Files

| file | role |
|---|---|
| `pmu_stat.sh` | vendor-PMU campaign for one command: 7 event groups of ≤ 6 events (no multiplexing), each run at N steps and at 0 steps |
| `pmu_report.py` | subtracts the 0-step run (startup) and prints per-cell counts as a markdown table |
| `probes/pmu.hpp` | cycles/instructions via `perf_event_open` (shared by the probes and the lab driver) |
| `probes/mem.cpp` | `mem lat K`: DRAM latency and memory-level parallelism (K independent pointer chases); `mem stream R W [opts]`: R read + W write unit-stride streams, f32 `vle32`/`vse32`, with THP, base stagger, touch-ahead loads, `prefetch.r`/`prefetch.w`, `cbo.zero`, scalar loads |
| `probes/ops.cpp` | per-instruction throughput and latency (vector e32/e64 m1 and scalar FP, L1-hit loads/stores) |
| `lab/gen.py` | builds the D3Q19 update rule exactly like sweepgen's `LbmBulk` for `apps/benchmarks/SweepgenLbmCPU` and emits the kernel TU plus a separate wrapper TU (runtime strides); the bodies are identical to the ones in the waLBerla build |
| `lab/edits.py` | textual lever edits of a generated kernel (`pf=D[:r|:w]` software prefetch, `nomacro` drop ρ/u stores); `gen.py` also understands `bpf=D` = the pystencils option `cpu.vectorize.prefetch_distance` |
| `lab/hand/f32-hand-split.cpp` | hand-written direction-split D3Q19 kernel (lever M2), knobs `BY`, `GM`, `GC`, `PF` |
| `lab/driver.cpp` | runs one kernel on waLBerla's v8 field layout (fzyx, 1 ghost layer, x padded to 16 B, 16-B aligned interior), periodic ghost fill between steps, counters around the kernel calls only, checksums |
| `lab/run.sh` | builds variants (`src/<v>.cpp` or `hand/<v>.cpp`) × compilers × flags and appends to `results.tsv` |

## Usage

```bash
# laptop: generate kernel variants (lbmpy is in .venv-rvv), then sync
PYTHONPATH=submodules/pystencils/src .venv-rvv/bin/python misc/x60-lab/lab/gen.py \
    misc/x60-lab/lab/src f32-rvv-cse "f32-rvv-cse+bpf=128" f32-generic-cse_scalar
bash push.to.sh bananapi

# board
cd /home/bananapi/saleh/my-e4-ws/misc/x60-lab/lab
bash run.sh f32-rvv-cse "f32-rvv-cse+bpf=128"               # GCC -O3 (waLBerla's flags)
HAND_DEFS="-DBY=2" bash run.sh f32-hand-split@by2             # hand kernel, labelled binary
CCS=clang FLAGS=Ofast MARCH=-march=rv64gcv_zvl256b bash run.sh ...
bash ../pmu_stat.sh out.tsv 64 20 -- /home/bananapi/saleh/notes3/lab/bin/<binary>
python3 ../pmu_report.py 64 20 out.tsv

g++ -O2 -march=rv64gcv_zvl256b_zicboz probes/mem.cpp -o mem && taskset -c 2 ./mem stream 19 23 thp=1 stagger=4160 pfr=128
g++ -O2 -march=rv64gcv_zvl256b_zicbop probes/ops.cpp -o ops && taskset -c 2 ./ops
```

Variant names are `<dtype>-<target>-<flavour>[+edit...]`; a `generic` kernel whose name
contains `scalar` is built with `-march=rv64gc_zicbop` (no V), everything else with
`-march=rv64gcv_zvl256b_zicbop_zicboz` unless `MARCH` is set.

## Results in one table (64³, one core, GCC -O3; details in the progress log)

| | f32 MLUP/s | cycles/cell | vs plain scalar |
|---|---|---|---|
| scalar_cse (`-march=rv64gc`) | 1.57 | 1035 | 1.0× |
| generated explicit_cse (= waLBerla before notes3) | 2.47 | 653 | 1.6× |
| + software prefetch 128 B (`prefetch_distance=128`) | 5.2–5.3 | 303–311 | 3.3–3.4× |
| hand direction-split, 2-row blocks, groups of 5 | 6.98 | 237 | 4.4× |

## What the X60 measurements say

- DRAM latency ~357 cycles (THP) / ~500 (4 K pages); ~6 misses in flight per core.
- The hardware stream prefetcher follows ~8 read streams (6 GB/s) and gives up past ~20
  (full latency per line). The sweep has 19 read + 23 write streams.
- `prefetch.r`/`prefetch.w` (Zicbop HINT encodings) are executed although the ISA string
  does not list Zicbop. `cbo.zero` does not help. Touch-ahead loads hurt.
- Vector FP arithmetic is 1 instruction/cycle at e32 and e64 m1 (the full 256 bits), so the
  arithmetic ceiling over scalar is 8× (f32) / 4× (f64). Splats cost 4 cycles, L1 loads 2 (4 when
  misaligned), stores 2.6, `vfdiv` 38–40.

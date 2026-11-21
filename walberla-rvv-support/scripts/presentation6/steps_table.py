#!/usr/bin/env python3
"""presentation6: summarize steps_check.sh (shorter timed runs: same speed, same noise?).

Usage: python3 scripts/presentation6/steps_table.py <steps-runs.log>

Per build (cores, compiler, precision, variant) and timed step count: runs, median / best MLUP/s, the median
relative to the 200-step median, the spread (max - min) / median over the rounds, the share of the wall pass
(t_bc / seconds), the wall time per run, and the number of distinct final energies (must be 1 per step count:
the runs repeat bit for bit). Standard library only (runs on the board).
"""
import re
import statistics as st
import sys
from collections import defaultdict

KEY = re.compile(r"(\w+)=(\S+)")


def main(path):
    runs = defaultdict(list)
    for line in open(path):
        if "variant=" not in line:
            if "FAILED" in line:
                print("FAILED RUN:", line.strip())
            continue
        f = dict(KEY.findall(line))
        key = (int(f["cores"]), f["cc"], "f" + f["real_t"], f["variant"].replace("SweepgenLdcCPU_", ""))
        runs[key, int(f["steps"])].append(
            (float(f["mlups"]), float(f["t_bc"]) / float(f["seconds"]), float(f["wall"]), f["energy"]))
    builds = sorted({k for k, _ in runs})
    steps_all = sorted({s for _, s in runs}, reverse=True)
    ref = max(steps_all)
    print(f"| cores | cc | prec | variant | steps | runs | median MLUP/s | best | median / {ref}-step | best / {ref}-step "
          "| spread | wall share | wall time per run | energies |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    worst = defaultdict(float)
    worst_spread = defaultdict(float)
    for b in builds:
        base = runs.get((b, ref))
        for s in steps_all:
            r = runs.get((b, s))
            if not r:
                continue
            m = [x[0] for x in r]
            med, best = st.median(m), max(m)
            spread = (max(m) - min(m)) / med
            rel = med / st.median([x[0] for x in base]) if base else float("nan")
            relbest = best / max(x[0] for x in base) if base else float("nan")
            worst[s] = max(worst[s], abs(rel - 1))
            worst_spread[s] = max(worst_spread[s], spread)
            print(f"| {b[0]} | {b[1]} | {b[2]} | {b[3]} | {s} | {len(r)} | {med:.3f} | {best:.3f} | {rel:.4f} | "
                  f"{relbest:.4f} | {100 * spread:.2f} % | {100 * st.median(x[1] for x in r):.1f} % | "
                  f"{st.median(x[2] for x in r):.1f} s | {len({x[3] for x in r})} |")
    print()
    for s in steps_all:
        print(f"steps {s}: worst |median / {ref}-step median - 1| = {100 * worst[s]:.2f} %, "
              f"worst spread = {100 * worst_spread[s]:.2f} %")


if __name__ == "__main__":
    main(sys.argv[1])

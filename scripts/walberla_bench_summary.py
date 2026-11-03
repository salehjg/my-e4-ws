"""Combine walberla_lbm_bench.sh logs into one markdown summary.

Usage: python walberla_bench_summary.py LABEL=LOG [LABEL=LOG ...]

For each configuration (e.g. gcc-f64), it reports the best MLUP/s per SweepgenLbmCPU variant,
the speedup over that configuration's scalar build, and the checksum agreement across
variants. The checksum is the kinetic energy at the end of the run, so every variant must
agree to rounding.
"""

import pathlib
import re
import sys

VARIANTS = ["scalar", "scalar_cse", "autovec", "autovec_cse", "explicit", "explicit_cse"]

configs = {}
for arg in sys.argv[1:]:
    label, path = arg.split("=", 1)
    best, energy = {}, {}
    p = pathlib.Path(path)
    if p.exists():
        for line in p.read_text().splitlines():
            if not line.startswith("SweepgenLbmCPU variant="):
                continue
            kv = dict(re.findall(r"(\w+)=(\S+)", line))
            v = kv["variant"].replace("SweepgenLbmCPU_", "")
            best[v] = max(best.get(v, 0.0), float(kv["mlups"]))
            energy.setdefault(v, float(kv["energy"]))
    configs[label] = (best, energy)

print("## waLBerla end-to-end: SweepgenLbmCPU, best MLUP/s (speedup vs the same config's scalar)\n")
print("| variant | " + " | ".join(configs) + " |")
print("|---" * (len(configs) + 1) + "|")
for v in VARIANTS:
    cells = []
    for best, _ in configs.values():
        if v in best:
            base = best.get("scalar")
            cells.append(f"{best[v]:.2f}" + (f" ({best[v] / base:.2f}x)" if base else ""))
        else:
            cells.append("-")
    print(f"| {v} | " + " | ".join(cells) + " |")

print("\n### Checksum (kinetic energy) agreement across variants\n")
print("| config | min | max | relative spread |")
print("|---|---|---|---|")
for label, (_, energy) in configs.items():
    if energy:
        lo, hi = min(energy.values()), max(energy.values())
        print(f"| {label} | {lo:.12e} | {hi:.12e} | {(hi - lo) / abs(lo):.1e} |")
    else:
        print(f"| {label} | - | - | no results |")

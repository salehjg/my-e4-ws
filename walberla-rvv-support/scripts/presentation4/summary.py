"""Combine SweepgenLdcCPU result logs (scripts/presentation4/run.sh) into markdown tables.

Usage: python scripts/presentation4/summary.py LABEL=LOG [LABEL=LOG ...]

A label may be given more than once: its logs are combined into one column (e.g. the scalar,
autovec and rvv logs of one compiler, precision and core count). Lines that are not
"SweepgenLdcCPU variant=..." result lines are ignored.

Tables:
  1. best MLUP/s per variant and column, with the speedup over the same column's plain scalar
     build (variant "scalar")
  2. checksums per column and configuration (blocks, domain, steps): the spread of energy and mass
     over the variants, and the number of distinct field hashes (1 = all variants bit-identical;
     more is expected, see the progress log: the variants round differently, and verify.sh checks
     every one against the oracle). Repeated runs of one executable must give one hash; otherwise
     the row says NON-DETERMINISTIC.
  3. per variant and column, the share of the timed loop spent in the wall sweeps (t_bc) and in
     the halo exchange (t_comm), from the best run (rank 0's timers)
"""

import pathlib
import re
import sys

VARIANTS = ["scalar", "scalar_cse", "scalar_cse_aa", "autovec", "autovec_cse", "autovec_cse_aa",
            "explicit_cse", "explicit_cse_pf", "explicit_cse_aa", "explicit_cse_aa_pf",
            "explicit_cse_aa_split"]

columns = {}
for arg in sys.argv[1:]:
    label, path = arg.split("=", 1)
    col = columns.setdefault(label, {})
    p = pathlib.Path(path)
    if not p.exists():
        continue
    for line in p.read_text().splitlines():
        if not line.startswith("SweepgenLdcCPU variant="):
            continue
        kv = dict(re.findall(r"(\w+)=(\S+)", line))
        v = kv["variant"].replace("SweepgenLdcCPU_", "")
        best = col.get(v)
        if best is None or float(kv["mlups"]) > float(best["mlups"]):
            col[v] = kv
        col.setdefault("_runs", {}).setdefault(v, []).append(kv)

labels = list(columns)
print("## SweepgenLdcCPU (lid-driven cavity): best MLUP/s, speedup over the same column's plain scalar\n")
print("| variant | " + " | ".join(labels) + " |")
print("|---" * (len(labels) + 1) + "|")
for v in VARIANTS:
    if not any(v in c for c in columns.values()):
        continue
    cells = []
    for c in columns.values():
        if v in c:
            m = float(c[v]["mlups"])
            base = float(c["scalar"]["mlups"]) if "scalar" in c else None
            cells.append(f"{m:.2f}" + (f" ({m / base:.2f}x)" if base else ""))
        else:
            cells.append("-")
    print(f"| {v} | " + " | ".join(cells) + " |")

print("\n### Checksums across variants (all runs, per configuration)\n")
print("| column | configuration | energy min | energy max | rel. spread | mass min | mass max | distinct field hashes |")
print("|---|---|---|---|---|---|---|---|")
for label, c in columns.items():
    runs = [r for rs in c.get("_runs", {}).values() for r in rs]
    if not runs:
        print(f"| {label} | - | - | - | - | - | - | no results |")
        continue
    configs = {}
    for r in runs:
        key = f"{r.get('blocks', '?')} blocks, {r.get('domain', '?')}, {r['steps']} steps"
        configs.setdefault(key, []).append(r)
    for key, rs in configs.items():
        e = [float(r["energy"]) for r in rs]
        m = [float(r["mass"]) for r in rs]
        hashes = {r["fieldhash"] for r in rs}
        # Repeated runs of one executable on one configuration must give the same hash
        per_variant = {}
        for r in rs:
            per_variant.setdefault(r["variant"], set()).add(r["fieldhash"])
        nondet = [v.replace("SweepgenLdcCPU_", "") for v, h in per_variant.items() if len(h) > 1]
        print(f"| {label} | {key} | {min(e):.17g} | {max(e):.17g} | {(max(e) - min(e)) / abs(min(e)):.1e} | "
              f"{min(m):.17g} | {max(m):.17g} | {len(hashes)} of {len(per_variant)} variants"
              + (f" (NON-DETERMINISTIC: {', '.join(nondet)})" if nondet else "") + " |")

print("\n### Share of the timed loop in the wall sweeps / halo exchange (best run, rank 0)\n")
print("| variant | " + " | ".join(labels) + " |")
print("|---" * (len(labels) + 1) + "|")
for v in VARIANTS:
    if not any(v in c for c in columns.values()):
        continue
    cells = []
    for c in columns.values():
        if v in c and "t_bc" in c[v]:
            s = float(c[v]["seconds"])
            cells.append(f"{100 * float(c[v]['t_bc']) / s:.1f}% / {100 * float(c[v]['t_comm']) / s:.1f}%")
        else:
            cells.append("-")
    print(f"| {v} | " + " | ".join(cells) + " |")

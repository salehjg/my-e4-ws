"""Per-cell PMU numbers from pmu_stat.sh output (startup subtracted).

Usage: python pmu_report.py CELLS STEPS A.tsv [B.tsv ...]   -> markdown table, one column per file
"""
import collections, pathlib, sys

cells, steps = int(sys.argv[1]), int(sys.argv[2])
n = cells ** 3 * steps
cols, rows = [], []
for f in sys.argv[3:]:
    d = collections.defaultdict(dict)
    for line in pathlib.Path(f).read_text().splitlines():
        s, ev, v = line.split("\t")
        try:
            d[ev][int(s)] = float(v)
        except ValueError:
            pass
    per = {}
    for ev, by in d.items():
        if ev == "mlups":
            per[ev] = by[steps]
        elif steps in by and 0 in by:
            per[ev] = (by[steps] - by[0]) / n
        if ev not in rows:
            rows.append(ev)
    cols.append((pathlib.Path(f).stem, per))
print("| per cell | " + " | ".join(c for c, _ in cols) + " |")
print("|---" * (len(cols) + 1) + "|")
for ev in rows:
    print(f"| {ev} | " + " | ".join(f"{p.get(ev, float('nan')):.2f}" for _, p in cols) + " |")

"""Pivot run.sh's results.tsv (and hotloops.txt) into markdown tables (printed to stdout).

Usage: python report.py BUILD_DIR
"""

import pathlib
import sys

build = pathlib.Path(sys.argv[1])
COLS = [(cc, b) for cc in ("gcc", "clang") for b in ("scalar", "autovec", "rvv")]
KINDS = ["stream", "fused", "fused_cse", "fused_cse_neg", "fused_cse_fma", "fused_cse_vf"]
DTYPES = ["f64", "f32"]

#   results.tsv: variant, size, key=value ...   (variant = cc-dt-kind-build)
runs, sizes = {}, []
for line in (build / "results.tsv").read_text().splitlines():
    v, size, *kv = line.split("\t")
    cc, dt, kind, b = v.split("-")
    runs[cc, dt, kind, b, size] = {k: float(x) for k, x in (p.split("=") for p in kv)}
    if size not in sizes:
        sizes.append(size)


def pivot(title, metric, fmt, row_sizes):
    """One table per dtype: rows = kernel x size, columns = compiler x build."""
    for dt in DTYPES:
        print(f"\n### {title}, {dt}\n")
        print("| kernel | size | " + " | ".join(f"{cc} {b}" for cc, b in COLS) + " |")
        print("|---|---" + "|---" * len(COLS) + "|")
        for kind in KINDS:
            for size in row_sizes:
                cells = [
                    fmt.format(runs[cc, dt, kind, b, size][metric]) if (cc, dt, kind, b, size) in runs else "-"
                    for cc, b in COLS
                ]
                print(f"| {kind} | {size}² | " + " | ".join(cells) + " |")


print("## Kernel benchmark: generic scalar / autovec vs explicit RVV")
pivot("Best MLUP/s (higher is better)", "best_mlups", "{:.2f}", sizes)
pivot("Retired instructions per cell (hardware counter)", "insns_per_cell", "{:.0f}", sizes[:1])
pivot("Cycles per cell (hardware counter)", "cycles_per_cell", "{:.0f}", sizes)

#   Which hot loop actually runs: retired instructions per cell x lanes ~ that loop's length
#   (4 lanes f64 / 8 lanes f32 for rvv; the others are remainder loops the compiler vectorized).
print("\n### Hot vector loops (hotloop.py; per loop iteration)\n")
print("```")
print((build / "hotloops.txt").read_text().rstrip())
print("```")

#   All six builds of one (dtype, kernel, size) compute the same thing: their checksums may
#   only differ by floating-point reassociation (-ffast-math), i.e. a tiny relative spread.
print("\n### Checksum agreement: max relative spread across the six builds\n")
print("| dtype | kernel | size | spread |")
print("|---|---|---|---|")
for dt in DTYPES:
    for kind in KINDS:
        for size in sizes:
            sums = [runs[cc, dt, kind, b, size]["checksum"] for cc, b in COLS if (cc, dt, kind, b, size) in runs]
            ref = abs(sums[0]) or 1.0
            print(f"| {dt} | {kind} | {size}² | {(max(sums) - min(sums)) / ref:.1e} |")

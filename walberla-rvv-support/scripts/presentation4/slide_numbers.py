"""Every number the presentation4 result slides use, computed from the timing logs of all.sh.

Usage: python scripts/presentation4/slide_numbers.py [--tex] <logdir>
  <logdir> holds ldc-<gcc|clang>-<scalar|autovec|rvv>-<f32|f64>-<1|4|8>core.log (all.sh's output; in the
  repository: docs/presentation4/board-logs/board/).
  --tex  print the LaTeX pieces of the slides instead: the coordinates of the result figures
         (figures/speedup-1core-<prec>.tex, mlups-1core.tex, speedup-multicore-<prec>.tex, mlups-multicore.tex)
         and the rows of the two numbers tables (copied into the deck as printed).

Per compiler, precision and core count, from the best of the runs of each variant (highest MLUP/s, as
summary.py): MLUP/s; speedup over the plain scalar build ("scalar") and over the best scalar build
("scalar_cse_aa") of the same compiler; the gain of each optimization (one build against the build
without it); Clang against GCC; and the core scaling. A missing variant prints "-".
Lines that are not "SweepgenLdcCPU variant=..." result lines are ignored.
"""

import pathlib
import re
import sys

COMPILERS, PRECS, CORES = ("gcc", "clang"), ("f32", "f64"), (1, 4, 8)
VARIANTS = ["scalar", "scalar_cse", "scalar_cse_aa", "autovec", "autovec_cse", "autovec_cse_aa",
            "explicit_cse", "explicit_cse_pf", "explicit_cse_aa", "explicit_cse_aa_pf", "explicit_cse_aa_split"]
#   optimization: (build with it, build without it)
GAINS = [("CSE (scalar)", "scalar_cse", "scalar"),
         ("in place (scalar, CSE)", "scalar_cse_aa", "scalar_cse"),
         ("auto-vectorization (plain)", "autovec", "scalar"),
         ("auto-vectorization (CSE, in place)", "autovec_cse_aa", "scalar_cse_aa"),
         ("RVV (CSE, AB) over scalar CSE", "explicit_cse", "scalar_cse"),
         ("prefetch (AB)", "explicit_cse_pf", "explicit_cse"),
         ("in place (RVV, no prefetch)", "explicit_cse_aa", "explicit_cse"),
         ("in place (RVV, with prefetch)", "explicit_cse_aa_pf", "explicit_cse_pf"),
         ("prefetch (in place)", "explicit_cse_aa_pf", "explicit_cse_aa"),
         ("split loop (instead of prefetch)", "explicit_cse_aa_split", "explicit_cse_aa_pf"),
         ("split loop (no prefetch in either)", "explicit_cse_aa_split", "explicit_cse_aa")]


def load(logdir):
    best = {}   # (cc, prec, cores, variant) -> mlups
    for cc in COMPILERS:
        for prec in PRECS:
            for n in CORES:
                for exp in ("scalar", "autovec", "rvv"):
                    p = pathlib.Path(logdir) / f"ldc-{cc}-{exp}-{prec}-{n}core.log"
                    if not p.exists():
                        continue
                    for line in p.read_text().splitlines():
                        if not line.startswith("SweepgenLdcCPU variant="):
                            continue
                        kv = dict(re.findall(r"(\w+)=(\S+)", line))
                        v = kv["variant"].replace("SweepgenLdcCPU_", "")
                        key = (cc, prec, n, v)
                        best[key] = max(best.get(key, 0.0), float(kv["mlups"]))
    return best


def fmt(x, nd=2, suffix=""):
    return "-" if x is None else f"{x:.{nd}f}{suffix}"


def ratio(best, a, b):
    return best[a] / best[b] if a in best and b in best else None


#   figures/speedup-1core-<prec>.tex and mlups-1core.tex: x coordinate -> variant (one core)
SPEEDUP_GROUPS = [("plain", "scalar"), ("plainav", "autovec"), ("best", "scalar_cse_aa"),
                  ("bestav", "autovec_cse_aa"), ("rvv", "explicit_cse"), ("pf", "explicit_cse_pf"),
                  ("aa", "explicit_cse_aa_pf"), ("split", "explicit_cse_aa_split")]
#   figures/mlups-multicore.tex (MLUP/s of all cores together) and speedup-multicore-<prec>.tex (without "scalar",
#   the base): series -> variant
MULTICORE_SERIES = ["scalar", "scalar_cse_aa", "autovec_cse_aa", "explicit_cse_aa_pf", "explicit_cse_aa_split"]
#   numbers tables: row label -> variant
TABLE_ROWS = [("plain scalar", "scalar"), ("scalar, CSE", "scalar_cse"),
              ("scalar, CSE, in place (best scalar)", "scalar_cse_aa"), None,
              ("auto-vectorized", "autovec"), ("auto-vectorized, CSE", "autovec_cse"),
              ("auto-vectorized, CSE, in place", "autovec_cse_aa"), None,
              ("RVV, CSE", "explicit_cse"), ("RVV, CSE, prefetch", "explicit_cse_pf"),
              ("RVV, CSE, in place", "explicit_cse_aa"), ("RVV, CSE, in place, prefetch", "explicit_cse_aa_pf"),
              ("RVV, CSE, in place, split loop, no prefetch", "explicit_cse_aa_split")]


def tex(best):
    def get(cc, prec, n, v):
        if (cc, prec, n, v) not in best:
            sys.exit(f"missing: {cc} {prec} {n} cores {v}")
        return best[(cc, prec, n, v)]

    print("% figures/speedup-1core-<prec>.tex: (group, speedup over the same compiler's plain scalar)[label]")
    for cc in COMPILERS:
        for prec in PRECS:
            base = get(cc, prec, 1, "scalar")
            pts = " ".join(f"({g},{get(cc, prec, 1, v) / base:.3f})[{get(cc, prec, 1, v) / base:.2f}]"
                           for g, v in SPEEDUP_GROUPS)
            print(f"%   {cc} {prec}: {pts}")
    print("% figures/mlups-1core.tex: (group, MLUP/s)[label]")
    for cc in COMPILERS:
        for prec in PRECS:
            pts = " ".join(f"({g},{get(cc, prec, 1, v):.2f})[{get(cc, prec, 1, v):.2f}]" for g, v in SPEEDUP_GROUPS)
            print(f"%   {cc} {prec}: {pts}")
    print("% figures/mlups-multicore.tex: (cores, MLUP/s)[label]")
    for cc in COMPILERS:
        for prec in PRECS:
            for v in MULTICORE_SERIES:
                pts = " ".join(f"({n},{get(cc, prec, n, v):.2f})[{get(cc, prec, n, v):.1f}]" for n in CORES)
                print(f"%   {cc} {prec} {v}: {pts}")
    print("% figures/speedup-multicore-<prec>.tex: (cores, speedup over the same compiler's plain scalar"
          " at that core count)[label]")
    for cc in COMPILERS:
        for prec in PRECS:
            for v in MULTICORE_SERIES[1:]:
                pts = " ".join(f"({n},{get(cc, prec, n, v) / get(cc, prec, n, 'scalar'):.3f})"
                               f"[{get(cc, prec, n, v) / get(cc, prec, n, 'scalar'):.2f}]" for n in CORES)
                print(f"%   {cc} {prec} {v}: {pts}")
    for cc in COMPILERS:
        print(f"% numbers table, {cc}: MLUP/s, 1 / 4 / 8 cores, f32 f64 each")
        for row in TABLE_ROWS:
            if row is None:
                print("    \\midrule")
                continue
            label, v = row
            cells = " & ".join(f"{get(cc, prec, n, v):.2f}" for n in CORES for prec in PRECS)
            print(f"    {label} & {cells}\\\\")


def main():
    args = sys.argv[1:]
    as_tex = "--tex" in args
    args = [a for a in args if a != "--tex"]
    if len(args) != 1:
        sys.exit(__doc__)
    best = load(args[0])
    if not best:
        sys.exit(f"no result lines in {args[0]}/ldc-*.log")
    if as_tex:
        tex(best)
        return

    for n in CORES:
        print(f"\n## {n} core(s): best MLUP/s (all cores together); speedup over plain scalar | over best scalar\n")
        cols = [(cc, prec) for cc in COMPILERS for prec in PRECS]
        print("| variant | " + " | ".join(f"{cc} {prec}" for cc, prec in cols) + " |")
        print("|---" * (len(cols) + 1) + "|")
        for v in VARIANTS:
            cells = []
            for cc, prec in cols:
                k = (cc, prec, n, v)
                if k not in best:
                    cells.append("-")
                    continue
                s1 = ratio(best, k, (cc, prec, n, "scalar"))
                s2 = ratio(best, k, (cc, prec, n, "scalar_cse_aa"))
                cells.append(f"{best[k]:.3f} ({fmt(s1, 2, 'x')} \\| {fmt(s2, 2, 'x')})")
            print(f"| {v} | " + " | ".join(cells) + " |")

    print("\n## Gain of each optimization: MLUP/s with it / without it (1 core)\n")
    cols = [(cc, prec) for cc in COMPILERS for prec in PRECS]
    print("| optimization | with | without | " + " | ".join(f"{cc} {prec}" for cc, prec in cols) + " |")
    print("|---" * (len(cols) + 3) + "|")
    for name, a, b in GAINS:
        cells = [fmt(ratio(best, (cc, prec, 1, a), (cc, prec, 1, b)), 3, "x") for cc, prec in cols]
        print(f"| {name} | {a} | {b} | " + " | ".join(cells) + " |")

    print("\n## Clang against GCC: MLUP/s(clang) / MLUP/s(gcc), same variant\n")
    cols = [(prec, n) for n in CORES for prec in PRECS]
    print("| variant | " + " | ".join(f"{prec} {n}c" for prec, n in cols) + " |")
    print("|---" * (len(cols) + 1) + "|")
    for v in VARIANTS:
        cells = [fmt(ratio(best, ("clang", prec, n, v), ("gcc", prec, n, v)), 3) for prec, n in cols]
        print(f"| {v} | " + " | ".join(cells) + " |")
    print("\nAnd each compiler's RVV now (explicit_cse_aa_pf) against GCC's plain scalar build:")
    for cc in COMPILERS:
        for prec in PRECS:
            for n in CORES:
                r = ratio(best, (cc, prec, n, "explicit_cse_aa_pf"), ("gcc", prec, n, "scalar"))
                print(f"  {cc} {prec} {n}c: {fmt(r, 2, 'x')}")

    print("\n## Core scaling: MLUP/s(4 cores) / MLUP/s(1 core), MLUP/s(8) / MLUP/s(4)\n")
    print("| compiler precision | variant | 4c/1c | 8c/4c | 8c/1c |")
    print("|---|---|---|---|---|")
    for cc in COMPILERS:
        for prec in PRECS:
            for v in ("scalar", "scalar_cse_aa", "autovec_cse_aa", "explicit_cse_aa_pf", "explicit_cse_aa_split"):
                k = lambda n: (cc, prec, n, v)
                print(f"| {cc} {prec} | {v} | {fmt(ratio(best, k(4), k(1)), 2)} | {fmt(ratio(best, k(8), k(4)), 2)} "
                      f"| {fmt(ratio(best, k(8), k(1)), 2)} |")


if __name__ == "__main__":
    main()

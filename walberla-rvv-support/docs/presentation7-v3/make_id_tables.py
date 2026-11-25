#!/usr/bin/env python3
"""Write the build-ID tables of the slides from the tables that scripts/presentation7/slide_data.py wrote.

Reads tables/{kone,sg}-table-{f32,f64}.tex (one row per build, MLUP/s for every core count, GCC then Clang) and
writes:
  tables/{kone,sg}-ids.tex          one row per build ID: ingredients, streams, GCC MLUP/s on 1 core and on all cores
  tables/{kone,sg}-full-{f32,f64}.tex  the full rows with the build ID in front (backup slides)
No number is typed in here: every number is copied from the input rows. ./build.sh runs this before LaTeX.
"""
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
T = HERE / "tables"
Y, N = r"\yes", r"\no"
# ID, short name, the name the input table uses, CSE, in place, vectors, prefetch, split, streams
BUILDS = [
    (1, "plain scalar", "plain scalar", N, N, N, N, N, "42"),
    (2, "scalar + CSE", "scalar, CSE", Y, N, N, N, N, "42"),
    (3, "best scalar", "best scalar (CSE, in place)", Y, Y, N, N, N, "23"),
    (4, "auto-vectorized", "auto-vectorized", N, N, "auto", N, N, "42"),
    (5, "auto-vec.\\ + CSE", "auto-vectorized, CSE", Y, N, "auto", N, N, "42"),
    (6, "best auto-vec.", "auto-vectorized, CSE, in place", Y, Y, "auto", N, N, "23"),
    (7, "RVV", "RVV, CSE", Y, N, "RVV", N, N, "42"),
    (8, "RVV + prefetch", "RVV, CSE, prefetch", Y, N, "RVV", Y, N, "42"),
    (9, "RVV in place", "RVV, CSE, in place", Y, Y, "RVV", N, N, "23"),
    (10, "RVV in place + prefetch", "RVV, CSE, in place, prefetch", Y, Y, "RVV", Y, N, "23"),
    (11, "RVV split loop", "RVV, CSE, in place, split loop", Y, Y, "RVV", N, Y, "$\\le$7 per pass"),
]
BADGE = {"kone": r"\kid", "sg": r"\sid"}


def read_rows(machine, prec):
    rows = {}
    for line in (T / f"{machine}-table-{prec}.tex").read_text().splitlines():
        if line.startswith("%") or "&" not in line:
            continue
        cells = [c.strip() for c in line.rstrip("\\ ").split("&")]
        rows[cells[0]] = cells[1:]
    names = [b[2] for b in BUILDS]
    if sorted(rows) != sorted(names):
        raise SystemExit(f"{machine} {prec}: rows {sorted(rows)} do not match the build list")
    return rows


for m in ("kone", "sg"):
    data = {p: read_rows(m, p) for p in ("f32", "f64")}
    ncore = len(next(iter(data["f32"].values()))) // 2
    out = [f"% written by make_id_tables.py from tables/{m}-table-f32/f64.tex; do not edit by hand"]
    for i, short, name, cse, inpl, vec, pf, split, streams in BUILDS:
        nums = []
        for idx in (0, ncore - 1):                       # 1 core, all cores
            for p in ("f32", "f64"):
                v = data[p][name]
                nums += [v[idx]]                         # GCC (Clang: the full tables of the backup)
        vec_cell = {N: N, "auto": "auto", "RVV": "\\textbf{RVV}"}[vec]
        out.append(f"{BADGE[m]}{{{i}}} & {short} & {cse} & {inpl} & {vec_cell} & {pf} & {split} & {streams} & "
                   + " & ".join(nums) + r" \\")
        if i in (3, 6):
            out.append(r"\midrule")
    (T / f"{m}-ids.tex").write_text("\n".join(out) + "\n")
    for p in ("f32", "f64"):
        full = [f"% written by make_id_tables.py from tables/{m}-table-{p}.tex; do not edit by hand"]
        for i, short, name, *_ in BUILDS:
            full.append(f"{BADGE[m]}{{{i}}}\\ {short} & " + " & ".join(data[p][name]) + r" \\")
            if i in (3, 6):
                full.append(r"\midrule")
        (T / f"{m}-full-{p}.tex").write_text("\n".join(full) + "\n")
print("make_id_tables.py: wrote tables/{kone,sg}-ids.tex and tables/{kone,sg}-full-{f32,f64}.tex")

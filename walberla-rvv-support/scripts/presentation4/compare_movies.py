"""Compare two runs of cavity_movie.py, e.g. the x86 film and the board's (docs/presentation4).

Usage: python3 scripts/presentation4/compare_movies.py <log A> <slices A.npz> <log B> <slices B.npz>
  log:    the run log cavity_movie.py writes (one line per frame: steps and the app's result line)
  slices: its cache <work>/slices.npz (the middle planes ux, uy of every frame)
  In the repository: docs/presentation4/board-logs/x86/cavity-movie.log with
  build/presentation4-x86/cavity-movie-work/slices.npz (x86), and
  docs/presentation4/board-logs/board/cavity-movie-board.log with the board's movie-work/slices.npz.

Per frame: the same step count in both; the relative difference of the kinetic energy and of the mass
(the app's sums over all cells, printed with 17 digits); the largest difference of ux, uy on the plotted
middle plane, divided by the lid speed 0.05; whether the field hashes are equal (not expected between
different instruction sets: FMA contraction and summation order differ, so the last bits differ).
PASS if every frame has |dE|/E <= 1e-10 and max |du| / u_lid <= 1e-10: far above the rounding that f64
accumulates over 16000 steps of this damped flow (about 1e-12), far below anything visible (1e-3).
"""

import pathlib
import re
import sys

import numpy as np

U_LID = 0.05
TOL = 1e-10


def runs(log):
    out = {}
    for line in pathlib.Path(log).read_text().splitlines():
        m = re.match(r"frame-(\d+) steps=(\d+) (SweepgenLdcCPU .*)", line)
        if m:
            kv = dict(re.findall(r"(\w+)=(\S+)", m.group(3)))
            out[int(m.group(2))] = (float(kv["energy"]), float(kv["mass"]), kv["fieldhash"], kv["variant"], kv["compiler"])
    return out


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    ra, rb = runs(sys.argv[1]), runs(sys.argv[3])
    sa, sb = np.load(sys.argv[2], allow_pickle=False), np.load(sys.argv[4], allow_pickle=False)
    for name, s in (("A", sa), ("B", sb)):
        if s["ux"].dtype != np.float64:
            sys.exit(f"FAIL: slices {name} are {s['ux'].dtype}, not float64 (made before the cache kept f64): rerun")
    if sorted(ra) != sorted(rb) or list(sa["steps"]) != list(sb["steps"]) or sorted(ra) != list(sa["steps"]):
        sys.exit("FAIL: the two films do not have the same frame steps")
    a0, b0 = next(iter(ra.values())), next(iter(rb.values()))
    print(f"A: {a0[3]} {a0[4]}   B: {b0[3]} {b0[4]}   {len(ra)} frames\n")
    print("| frame | steps | energy A | rel. diff energy | rel. diff mass | max abs(du) / u_lid | field hash equal |")
    print("|---|---|---|---|---|---|---|")
    worst_e = worst_u = 0.0
    same_hash = 0
    for i, n in enumerate(sa["steps"]):
        ea, ma, ha = ra[int(n)][:3]
        eb, mb, hb = rb[int(n)][:3]
        de = abs(ea - eb) / abs(ea) if ea else abs(ea - eb)
        dm = abs(ma - mb) / abs(ma)
        du = max(np.abs(sa["ux"][i].astype(np.float64) - sb["ux"][i]).max(),
                 np.abs(sa["uy"][i].astype(np.float64) - sb["uy"][i]).max()) / U_LID
        worst_e, worst_u = max(worst_e, de), max(worst_u, du)
        same_hash += ha == hb
        print(f"| {i:02d} | {int(n)} | {ea:.15g} | {de:.2e} | {dm:.2e} | {du:.2e} | {'yes' if ha == hb else 'no'} |")
    ok = worst_e <= TOL and worst_u <= TOL
    print(f"\nworst: energy {worst_e:.2e}, middle plane {worst_u:.2e} (tolerance {TOL:g}); field hashes equal in "
          f"{same_hash} of {len(ra)} frames")
    print("COMPARE_MOVIES PASS" if ok else "COMPARE_MOVIES FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

"""The headline speedups of a second session (speedup_check.sh) against all.sh, for docs/presentation4.

Usage: python3 scripts/presentation4/speedup_table.py <logdir>
  <logdir> holds speedup-<cc>-<prec>-<variant>.log (speedup_check.sh) and ldc-<cc>-<exp>-<prec>-1core.log
  (all.sh); in the repository: docs/presentation4/board-logs/board/.

Per compiler and precision, one core: the runs of plain scalar (scalar), RVV in place + prefetch
(explicit_cse_aa_pf) and RVV split loop (explicit_cse_aa_split), which speedup_check.sh alternated run by
run; the best of each against all.sh's best; the speedups of both sessions; the per-round speedups (each
RVV run divided by the scalar run of the same round). It also checks that every run of one executable
has the same sha256 and field hash. The numbers go into the caption line of the two one-core results slides.
"""

import pathlib
import re
import sys

VARIANTS = ("scalar", "explicit_cse_aa_pf", "explicit_cse_aa_split")


def runs(path, variant=None):
    """[(mlups, fieldhash, sha256)] of the result lines in path (of one variant, if given)."""
    sha, out = None, []
    for line in pathlib.Path(path).read_text().splitlines():
        m = re.match(r"\s+sha256 (\w+) ", line)
        if m:
            sha = m.group(1)
        if line.startswith("SweepgenLdcCPU variant="):
            kv = dict(re.findall(r"(\w+)=(\S+)", line))
            if variant is None or kv["variant"] == f"SweepgenLdcCPU_{variant}":
                out.append((float(kv["mlups"]), kv["fieldhash"], sha))
    return out


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    d = pathlib.Path(sys.argv[1])
    ok = True
    print("| compiler, precision | variant | runs today (MLUP/s) | best today / all.sh | speedup today | speedup all.sh "
          "| today / all.sh | per round |")
    print("|---|---|---|---|---|---|---|---|")
    for cc in ("gcc", "clang"):
        for prec in ("f32", "f64"):
            today = {v: runs(d / f"speedup-{cc}-{prec}-{v}.log") for v in VARIANTS}
            before = {v: runs(d / f"ldc-{cc}-{'scalar' if v == 'scalar' else 'rvv'}-{prec}-1core.log", v) for v in VARIANTS}
            for v in VARIANTS:
                shas = {r[2] for r in today[v]} | {r[2] for r in before[v]}
                hashes = {r[1] for r in today[v]} | {r[1] for r in before[v]}
                if len(shas) != 1 or len(hashes) != 1:
                    ok = False
                    print(f"MISMATCH {cc} {prec} {v}: sha256 {shas}, field hashes {hashes}")
            bt = {v: max(r[0] for r in today[v]) for v in VARIANTS}
            bb = {v: max(r[0] for r in before[v]) for v in VARIANTS}
            for v in VARIANTS:
                cells = " ".join(f"{r[0]:.3f}" for r in today[v])
                if v == "scalar":
                    print(f"| {cc} {prec} | {v} | {cells} | {bt[v] / bb[v]:.3f} | | | | |")
                    continue
                st, sb = bt[v] / bt["scalar"], bb[v] / bb["scalar"]
                rounds = " ".join(f"{a[0] / s[0]:.2f}" for a, s in zip(today[v], today["scalar"]))
                print(f"| {cc} {prec} | {v} | {cells} | {bt[v] / bb[v]:.3f} | {st:.3f} | {sb:.3f} | {st / sb:.3f} | {rounds} |")
    print("\nsha256 and field hashes: " + ("each executable one sha256 and one field hash in both sessions" if ok
                                          else "MISMATCH, see above"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

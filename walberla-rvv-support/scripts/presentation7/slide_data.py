#!/usr/bin/env python3
"""Check the raw logs behind docs/presentation7 and write the tables and numbers its slides use.

Usage (from the repo root):
    python3 scripts/presentation7/slide_data.py [SG2044_RUN_DIR]

    SG2044_RUN_DIR  a monte3 run folder fetched by scripts/notes7/monte3.sh (private, not committed);
                    default: the run named in 00_private_data/monte3/last-run.txt

Inputs:
    K1 (SpacemiT K1, VLEN 256): docs/presentation7/board-logs/k1/ (tracked copies of presentation4's board session
        and of the notes5 fair-test rounds, byte for byte from docs/presentation6/board-logs/)
    SG2044 (Sophgo SG2044 on Monte Cimone, VLEN 128): the run folder above

Outputs (tracked, written only when every check passes):
    docs/presentation7/tables/*.dat     pgfplots tables
    docs/presentation7/tables/numbers.tex   \\nset{key}{value} for every number the slide text uses
Each output starts with a header naming the source logs and their sha256.

Exits with status 1 and a message for the first failed check. Uses only the Python standard library.
"""
import hashlib
import re
import sys
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DECK = REPO / "docs" / "presentation7"
K1_DIR = DECK / "board-logs" / "k1"
OUT = DECK / "tables"

VARIANTS = ["scalar", "scalar_cse", "scalar_cse_aa", "autovec", "autovec_cse", "autovec_cse_aa",
            "explicit_cse", "explicit_cse_pf", "explicit_cse_aa", "explicit_cse_aa_pf", "explicit_cse_aa_split"]
GROUP = {"scalar": VARIANTS[0:3], "autovec": VARIANTS[3:6], "rvv": VARIANTS[6:11]}
# short keys used in the tables and in \N{...}
SHORT = {"scalar": "plain", "scalar_cse": "cse", "scalar_cse_aa": "best", "autovec": "plainav",
         "autovec_cse": "cseav", "autovec_cse_aa": "bestav", "explicit_cse": "rvv", "explicit_cse_pf": "pf",
         "explicit_cse_aa": "aa", "explicit_cse_aa_pf": "aapf", "explicit_cse_aa_split": "split"}
COMPILERS = ["gcc", "clang"]
PRECS = ["f32", "f64"]
LINE_RE = re.compile(r"\bSweepgenLdcCPU variant=")


class CheckFailed(Exception):
    pass


def check(cond, msg):
    if not cond:
        raise CheckFailed(msg)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()[:16]


def parse_line(line):
    """key=value pairs of one SweepgenLdcCPU result line (also with a 'round=1 mode=...' prefix)."""
    kv = dict(tok.split("=", 1) for tok in line.split() if "=" in tok)
    kv["variant"] = kv["variant"].removeprefix("SweepgenLdcCPU_")
    for k in ("mlups", "seconds", "energy", "mass", "t_bulk", "t_comm", "t_bc"):
        kv[k] = float(kv[k])
    for k in ("steps", "warmup", "cells", "real_t"):
        kv[k] = int(kv[k])
    return kv


def runs_of(path):
    return [parse_line(l) for l in path.read_text().splitlines() if LINE_RE.search(l)]


def check_run(r, cc, prec, cores, steps, path):
    where = f"{path.name}: {r['variant']}"
    check(r["compiler"].lower().startswith({"gcc": "gnu", "clang": "clang"}[cc]), f"{where}: compiler {r['compiler']}")
    check(r["real_t"] == int(prec[1:]), f"{where}: real_t {r['real_t']}")
    check(r["steps"] == steps and r["warmup"] == 10, f"{where}: steps {r['steps']} warmup {r['warmup']}")
    bx, by, bz = (int(v) for v in r["blocks"].split("x"))
    check(bx * by * bz == cores, f"{where}: blocks {r['blocks']} for {cores} cores")
    check(r["cells"] == cores * 64 ** 3, f"{where}: cells {r['cells']}")


def summarize(runs, where, nruns):
    """best (max MLUP/s), min, spread; field hash identical in every run."""
    check(len(runs) == nruns, f"{where}: {len(runs)} runs, expected {nruns}")
    hashes = {r["fieldhash"] for r in runs}
    check(len(hashes) == 1, f"{where}: field hash differs between runs {sorted(hashes)}")
    best = max(runs, key=lambda r: r["mlups"])
    lo = min(r["mlups"] for r in runs)
    return {"best": best["mlups"], "min": lo, "spread": (best["mlups"] - lo) / best["mlups"], "run": best,
            "energy": best["energy"], "hash": best["fieldhash"]}


def check_energies(res, machine, cores_list):
    """All builds of one compiler/precision/core count compute the same flow (energy, relative)."""
    worst = {}
    for cc in COMPILERS:
        for prec in PRECS:
            for c in cores_list:
                e = [res[(cc, prec, c, v)]["energy"] for v in VARIANTS]
                rel = (max(e) - min(e)) / (sum(e) / len(e))
                tol = 1e-12 if prec == "f64" else 1e-5
                check(rel < tol, f"{machine} {cc} {prec} {c} cores: energies of the 11 builds differ by {rel:.2e}")
                worst[prec] = max(worst.get(prec, 0.0), rel)
    return worst


def load_machine(machine, logdir, cores_list, steps, interleaved):
    res, sources = {}, []
    for cc in COMPILERS:
        for prec in PRECS:
            for c in cores_list:
                for grp, variants in GROUP.items():
                    path = logdir / f"ldc-{cc}-{grp}-{prec}-{c}core.log"
                    check(path.is_file(), f"missing {path}")
                    sources.append(path)
                    runs = runs_of(path)
                    for r in runs:
                        check_run(r, cc, prec, c, steps, path)
                        check(r["output"] == "every", f"{path.name}: output {r['output']}")
                    for v in variants:
                        res[(cc, prec, c, v)] = summarize([r for r in runs if r["variant"] == v],
                                                          f"{path.name} {v}", 3)
                    if interleaved:   # every round runs each variant once, in the listed order
                        order = [r["variant"] for r in runs]
                        check(order == variants * 3, f"{path.name}: rounds not interleaved: {order}")
                        busy_check(path, BUSY)
    return res, sources


BUSY = []   # rounds of the SG2044 run in which some core was busy before the round started


def busy_check(path, busy):
    """Before each round the job samples every core for 1 s (nothing of ours runs then). Allowed: no core above
    3 %, or single cores up to 5 % (recorded and reported); anything more fails."""
    rounds = re.findall(r"busy cores \(>3 % over 1 s\): (.+)$", path.read_text(), re.M)
    check(len(rounds) == 3, f"{path.name}: {len(rounds)} rounds")
    for i, r in enumerate(rounds, 1):
        if r.strip() == "none":
            continue
        loads = [int(x) for x in re.findall(r"cpu\d+=(\d+)%", r)]
        check(loads and max(loads) <= 5, f"{path.name}: round {i}: busy cores {r}")
        busy.append(f"{path.name} round {i}: {r.strip()}")


# ---- verification logs -----------------------------------------------------------------------------------
def verify_errors(path):
    """VERIFY PASS, and the largest |drho|, |du| against the NumPy reference over all oracle tables."""
    text = path.read_text()
    check(text.rstrip().endswith("VERIFY PASS"), f"{path}: no VERIFY PASS at the end")
    check("RESULT FAIL" not in text, f"{path}: RESULT FAIL")
    drho = du = 0.0
    nexe = 0
    against_ref = False
    for line in text.splitlines():
        if line.startswith("against "):
            against_ref = line.rstrip().endswith("reference.npz:")
            continue
        m = re.match(r"\S*oracle-\S+/SweepgenLdcCPU_\S+\s+([0-9.e+-]+)\s+([0-9.e+-]+)\s+\d+/\d+", line)
        if m and against_ref:
            drho, du = max(drho, float(m.group(1))), max(du, float(m.group(2)))
            nexe += 1
        elif not line.strip():
            against_ref = False
    check(nexe >= 11 * 4, f"{path}: only {nexe} rows against the reference")
    return drho, du, len(re.findall(r"^\s*sha256 [0-9a-f]+ ", text, re.M))


# ---- fair test (density and velocity only at the end) ------------------------------------------------------
def fair_test_k1():
    out, sources = {}, []
    for cc, name, nrounds in (("gcc", "e2-A-output-last.log", 3), ("clang", "e10-A-clang-output-last.log", 2)):
        path = K1_DIR / "notes5" / name
        sources.append(path)
        runs = runs_of(path)
        for prec in PRECS:
            for mode in ("every", "last"):
                for v in sorted({r["variant"] for r in runs}):
                    sel = [r for r in runs if r["variant"] == v and r["output"] == mode and r["real_t"] == int(prec[1:])]
                    if not sel:
                        continue
                    for r in sel:
                        check_run(r, cc, prec, 1, 200, path)
                    out[(cc, prec, mode, v)] = summarize(sel, f"{name} {prec} {mode} {v}", nrounds)
    return out, sources


def fair_test_sg(run):
    out, sources = {}, []
    for cc in COMPILERS:
        for prec in PRECS:
            for mode in ("every", "last"):
                path = run / f"share-{cc}-{prec}-{mode}.log"
                sources.append(path)
                runs = runs_of(path)
                for r in runs:
                    check_run(r, cc, prec, 1, 60, path)
                    check(r["output"] == mode, f"{path.name}: output {r['output']}")
                for v in ("scalar_cse_aa", "explicit_cse_aa_pf", "explicit_cse_aa_split"):
                    out[(cc, prec, mode, v)] = summarize([r for r in runs if r["variant"] == v], f"{path.name} {v}", 3)
                busy_check(path, BUSY)
    return out, sources


def fair_ratio(ft, cc, prec):
    """fastest RVV build with output last over the best scalar build with output last."""
    base = ft[(cc, prec, "last", "scalar_cse_aa")]["best"]
    rvv = {v: ft[(cc, prec, "last", v)]["best"] for v in ("explicit_cse_aa_pf", "explicit_cse_aa_split")
           if (cc, prec, "last", v) in ft}
    v = max(rvv, key=rvv.get)
    return base, rvv[v], v, rvv[v] / base


# ---- SG2044 job outputs ----------------------------------------------------------------------------------
def check_sg_jobs(run):
    builds = sorted(run.glob("build-*.out"))
    times = sorted(run.glob("time-*.out"))
    check(len(builds) == 1 and len(times) == 1, f"{run}: expected one build-*.out and one time-*.out")
    btext, ttext = builds[0].read_text(), times[0].read_text()
    check(btext.rstrip().endswith("BUILD PASS"), "build job did not end with BUILD PASS")
    check(len(re.findall(r"^PASS audit ", btext, re.M)) == 44, "build job: not 44 audits")
    check(re.search(r"^FAIL", btext, re.M) is None, "build job: FAIL lines")
    check(re.search(r"^TIME DONE", ttext, re.M) is not None, "timing job did not end with TIME DONE")
    check(re.search(r"FAILED|SKIPPED|ERROR", ttext) is None, "timing job: FAILED/SKIPPED/ERROR lines")
    check("openmpi-5.0.6/bin/mpirun" in ttext and "openmpi-5.0.6/bin/mpirun" in btext, "jobs did not use openmpi-5.0.6")
    table = {}
    for m in re.finditer(r"^(ldc|share)-(\S+)\s+(\S+)\s+([0-9.]+)$", ttext, re.M):
        table[(m.group(1) + "-" + m.group(2), m.group(3))] = float(m.group(4))
    mpi = {}
    for m in re.finditer(r"^PASS np=(\d+):", ttext, re.M):
        np_ = int(m.group(1))
        log = (run / f"mpi-{np_}.log").read_text()
        halo = float(re.search(r"pattern=halo .*us_per_repeat=([0-9.]+) errors=0", log).group(1))
        helper = re.search(r"busiest helper thread (\d+)%", log).group(1)
        check(helper == "0", f"mpi-{np_}.log: helper thread at {helper}%")
        mpi[np_] = halo
    check(sorted(mpi) == [4, 8, 16, 32, 64], f"MPI check passed only at {sorted(mpi)}")
    return builds[0], times[0], table, mpi


# ---- output helpers ----------------------------------------------------------------------------------------
def header(sources, extra=""):
    lines = ["% written by scripts/presentation7/slide_data.py; do not edit by hand"]
    if extra:
        lines.append(f"% {extra}")
    lines += [f"% source {sha(p)} {p.relative_to(REPO) if p.is_relative_to(REPO) else p}" for p in sources]
    return "\n".join(lines) + "\n"


def write_dat(name, cols, rows, sources, extra=""):
    text = header(sources, extra) + " ".join(cols) + "\n"
    text += "".join(" ".join(str(x) for x in r) + "\n" for r in rows)
    (OUT / name).write_text(text)


def sci(x, digits=0):
    """x as TeX math, e.g. 2.2\\cdot 10^{-16} (no $)."""
    mant, exp = f"{x:.{digits}e}".split("e")
    return f"{mant}\\cdot 10^{{{int(exp)}}}"


def f2(x):
    return f"{x:.2f}"


def f1(x):
    return f"{x:.1f}"


def main():
    if len(sys.argv) > 2:
        sys.exit(__doc__)
    if len(sys.argv) == 2:
        run = Path(sys.argv[1]).resolve()
    else:
        last = (REPO / "00_private_data" / "monte3" / "last-run.txt").read_text()
        run = REPO / "00_private_data" / "monte3" / re.search(r"^run=(\S+)", last, re.M).group(1)
    check(run.is_dir(), f"no run folder {run}")

    machines = {
        "kone": dict(name="K1", dir=K1_DIR / "board", cores=[1, 4, 8], steps=200, interleaved=False, vlen=256),
        "sg": dict(name="SG2044", dir=run, cores=[1, 4, 8, 16, 32, 64], steps=60, interleaved=True, vlen=128),
    }
    N = {}            # key -> text for numbers.tex
    report = []
    all_sources = []
    data = {}
    for m, cfg in machines.items():
        res, src = load_machine(cfg["name"], cfg["dir"], cfg["cores"], cfg["steps"], cfg["interleaved"])
        all_sources += src
        data[m] = res
        worst = check_energies(res, cfg["name"], cfg["cores"])
        spread = max(res.values(), key=lambda s: s["spread"])
        N[f"{m}:spread"] = f1(100 * spread["spread"])
        sp = sorted(s["spread"] for s in res.values())
        N[f"{m}:spread:median"] = f1(100 * sp[len(sp) // 2])
        N[f"{m}:spread:nthree"] = str(sum(1 for x in sp if x > 0.03))
        N[f"{m}:spread:n"] = str(len(sp))
        N[f"{m}:spread:headline"] = f1(100 * max(s["spread"] for k, s in res.items() if k[3] in
                                                 ("scalar", "scalar_cse_aa", "explicit_cse_aa_pf", "explicit_cse_aa_split")))
        N[f"{m}:energyspread:f64"] = sci(worst["f64"])
        N[f"{m}:energyspread:f32"] = sci(worst["f32"])
        report.append(f"{cfg['name']}: {len(res)} configurations x 3 runs, field hash identical in every run, "
                      f"energy spread f64 {worst['f64']:.1e} f32 {worst['f32']:.1e}, largest MLUP/s spread "
                      f"{100 * spread['spread']:.1f} % ({spread['run']['variant']}, {spread['run']['compiler']}, "
                      f"real_t {spread['run']['real_t']}, blocks {spread['run']['blocks']})")
        # MLUP/s and ratios for the text
        for (cc, prec, c, v), s in res.items():
            k = f"{m}:{cc}:{prec}:{c}:{SHORT[v]}"
            N[k] = f2(s["best"])
            N[k + "/plain"] = f2(s["best"] / res[(cc, prec, c, "scalar")]["best"])
            N[k + "/best"] = f2(s["best"] / res[(cc, prec, c, "scalar_cse_aa")]["best"])
            N[k + ":percore"] = f2(s["best"] / c)
            N[k + "/one"] = f1(s["best"] / res[(cc, prec, 1, v)]["best"])   # times its own one-core speed
            N[k + ":spread"] = f1(100 * s["spread"])
        for prec in PRECS:
            for c in cfg["cores"]:
                for v in VARIANTS:
                    N[f"{m}:clang/gcc:{prec}:{c}:{SHORT[v]}"] = f2(res[("clang", prec, c, v)]["best"] /
                                                                   res[("gcc", prec, c, v)]["best"])
        # autovec against scalar: largest difference over every core count, compiler, precision
        av = max(abs(res[(cc, p, c, a)]["best"] / res[(cc, p, c, s)]["best"] - 1)
                 for cc in COMPILERS for p in PRECS for c in cfg["cores"]
                 for s, a in (("scalar", "autovec"), ("scalar_cse", "autovec_cse"), ("scalar_cse_aa", "autovec_cse_aa")))
        N[f"{m}:autovecdiff"] = f1(100 * av)
        gain = max(res[(cc, p, c, a)]["best"] / res[(cc, p, c, s_)]["best"] - 1
                   for cc in COMPILERS for p in PRECS for c in cfg["cores"]
                   for s_, a in (("scalar", "autovec"), ("scalar_cse", "autovec_cse"), ("scalar_cse_aa", "autovec_cse_aa")))
        N[f"{m}:autovecgain"] = f1(100 * gain)
        # the RVV build with the highest MLUP/s, per compiler/precision/core count
        for cc in COMPILERS:
            for p in PRECS:
                for c in cfg["cores"]:
                    fastest = max(VARIANTS, key=lambda v: res[(cc, p, c, v)]["best"])
                    N[f"{m}:fastest:{cc}:{p}:{c}"] = SHORT[fastest]
        N[f"{m}:splitfastest"] = str(sum(1 for cc in COMPILERS for p in PRECS for c in cfg["cores"]
                                         if N[f"{m}:fastest:{cc}:{p}:{c}"] == "split"))
        N[f"{m}:ncolumns"] = str(len(COMPILERS) * len(PRECS) * len(cfg["cores"]))

        # ---- tables ----
        maxc = cfg["cores"][-1]
        onecore_rows = ["plain", "plainav", "best", "bestav", "rvv", "pf", "aa", "aapf", "split"]
        inv = {v: k for k, v in SHORT.items()}
        for p in PRECS:
            rows = []
            for key in onecore_rows:
                v = inv[key]
                g, cl = res[("gcc", p, 1, v)], res[("clang", p, 1, v)]
                rows.append([key, f"{g['best']:.3f}", f"{cl['best']:.3f}",
                             f"{g['best'] / res[('gcc', p, 1, 'scalar')]['best']:.3f}",
                             f"{cl['best'] / res[('clang', p, 1, 'scalar')]['best']:.3f}",
                             int(key in ("plain", "best", "split"))])
            write_dat(f"{m}-1core-{p}.dat", ["build", "gcc", "clang", "gccspd", "clangspd", "show"], rows, src,
                      f"{cfg['name']}, {p}, one core, best of 3, MLUP/s and speedup over plain scalar of the same compiler")
            rows = []
            for c in cfg["cores"]:
                row = [c]
                for cc in COMPILERS:
                    for v in ("scalar", "scalar_cse_aa", "explicit_cse_aa_pf", "explicit_cse_aa_split"):
                        row.append(f"{res[(cc, p, c, v)]['best']:.3f}")
                        row.append(f"{res[(cc, p, c, v)]['best'] / c:.3f}")
                    row.append(f"{res[(cc, p, c, 'explicit_cse_aa_split')]['best'] / res[(cc, p, c, 'scalar_cse_aa')]['best']:.3f}")
                    row.append(f"{res[(cc, p, c, 'explicit_cse_aa_split')]['best'] / res[(cc, p, c, 'scalar')]['best']:.3f}")
                rows.append(row)
            cols = ["cores"] + [f"{cc}{SHORT[v]}{suf}" for cc in COMPILERS
                                for v in ("scalar", "scalar_cse_aa", "explicit_cse_aa_pf", "explicit_cse_aa_split")
                                for suf in ("", "pc")]
            # reorder column names to match the row layout (per compiler: 4 builds x (total, per core), 2 ratios)
            cols = ["cores"]
            for cc in COMPILERS:
                for v in ("scalar", "scalar_cse_aa", "explicit_cse_aa_pf", "explicit_cse_aa_split"):
                    cols += [f"{cc}{SHORT[v]}", f"{cc}{SHORT[v]}pc"]
                cols += [f"{cc}splitbest", f"{cc}splitplain"]
            write_dat(f"{m}-scaling-{p}.dat", cols, rows, src,
                      f"{cfg['name']}, {p}, best of 3 per core count; pc = per core; splitbest = split / best scalar")
            # time shares of the best run: kernel (t_bulk), halo exchange (t_comm), wall pass (t_bc)
            rows = []
            for c in (1, maxc):
                for v in ("scalar_cse_aa", "explicit_cse_aa_split"):
                    r = res[("gcc", p, c, v)]["run"]
                    tot = r["t_bulk"] + r["t_comm"] + r["t_bc"]
                    shares = [100 * r[k] / tot for k in ("t_bulk", "t_comm", "t_bc")]
                    rows.append([f"{SHORT[v]}{c}", f"{shares[0]:.1f}", f"{shares[1]:.1f}", f"{shares[2]:.1f}",
                                 f"{r['seconds'] / r['steps'] * 1000:.2f}"])
                    for k, val in zip(("kernel", "comm", "wall"), shares):
                        N[f"{m}:share:{p}:{c}:{SHORT[v]}:{k}"] = f"{val:.0f}"
            write_dat(f"{m}-time-{p}.dat", ["bar", "kernel", "comm", "wall", "msperstep"], rows, src,
                      f"{cfg['name']}, {p}, GCC, best run: shares of t_bulk + t_comm + t_bc in %, wall time per step in ms")
        N[f"{m}:maxcores"] = str(maxc)
        # full number tables for the backup slides: rows = 11 builds, columns = GCC then Clang, each core count
        labels = {"scalar": "plain scalar", "scalar_cse": "scalar, CSE", "scalar_cse_aa": "best scalar (CSE, in place)",
                  "autovec": "auto-vectorized", "autovec_cse": "auto-vectorized, CSE",
                  "autovec_cse_aa": "auto-vectorized, CSE, in place", "explicit_cse": "RVV, CSE",
                  "explicit_cse_pf": "RVV, CSE, prefetch", "explicit_cse_aa": "RVV, CSE, in place",
                  "explicit_cse_aa_pf": "RVV, CSE, in place, prefetch",
                  "explicit_cse_aa_split": "RVV, CSE, in place, split loop"}
        for p in PRECS:
            cols = [(cc, c) for cc in COMPILERS for c in cfg["cores"]]
            top = {col: max(VARIANTS, key=lambda v: res[(col[0], p, col[1], v)]["best"]) for col in cols}
            lines = []
            for i, v in enumerate(VARIANTS):
                if i in (3, 6):
                    lines.append("\\midrule")
                cells = []
                for col in cols:
                    val = f"{res[(col[0], p, col[1], v)]['best']:.2f}"
                    cells.append(f"\\textbf{{{val}}}" if top[col] == v else val)
                lines.append(labels[v] + " & " + " & ".join(cells) + " \\\\")
            (OUT / f"{m}-table-{p}.tex").write_text(header(src, f"{cfg['name']} {p}: best MLUP/s, all cores together; "
                                                         "bold: fastest build of the column") + "\n".join(lines) + "\n")

    # ---- K1: the numbers presentation6 printed (its GCC and Clang tables) must come out the same ----
    for key, want in (("gcc:f32:1:scalar", 1.38), ("gcc:f32:1:scalar_cse_aa", 2.00), ("gcc:f32:1:explicit_cse_aa_pf", 6.56),
                      ("gcc:f32:1:explicit_cse_aa_split", 7.68), ("gcc:f64:8:explicit_cse_aa_split", 10.35),
                      ("clang:f32:8:explicit_cse_aa_split", 19.21), ("clang:f64:1:explicit_cse_aa_split", 4.43)):
        cc, p_, c, v = key.split(":")
        got = round(data["kone"][(cc, p_, int(c), v)]["best"], 2)
        check(got == want, f"K1 {key}: {got}, presentation6 printed {want}")
    report.append("K1: 7 spot values equal presentation6's tables")

    # ---- verification ----
    verify_src = []
    for m, base in (("kone", K1_DIR / "board"), ("sg", run)):
        worst = {}
        nsha = 0
        for cc in COMPILERS:
            for p in PRECS:
                path = base / f"verify-{cc}-{p}.log"
                verify_src.append(path)
                drho, du, n = verify_errors(path)
                nsha += n
                worst[p] = max(worst.get(p, (0, 0)), (drho, du))
        for p in PRECS:
            N[f"{m}:referr:{p}"] = sci(max(worst[p]), 1)
        N[f"{m}:verified"] = str(nsha)
        report.append(f"{machines[m]['name']}: VERIFY PASS x4, {nsha} executables with sha256, max error vs reference "
                      f"f64 {max(worst['f64']):.2e}, f32 {max(worst['f32']):.2e}")

    # ---- SG2044 jobs, MPI check ----
    bfile, tfile, table, mpi = check_sg_jobs(run)
    for cc in COMPILERS:
        for p in PRECS:
            for c in machines["sg"]["cores"]:
                for grp, variants in GROUP.items():
                    for v in variants:
                        got = round(data["sg"][(cc, p, c, v)]["best"], 2)
                        want = table[(f"ldc-{cc}-{grp}-{p}-{c}core", v)]
                        check(abs(got - want) < 0.006, f"best-of differs from the job's table: {cc} {p} {c} {v} {got} {want}")
    for np_, halo in mpi.items():
        N[f"sg:mpihalo:{np_}"] = f"{halo:,.0f}"
    N["sg:busyrounds"] = str(len(BUSY))
    nrounds = sum(len(re.findall(r"^== round \d+ ", f.read_text(), re.M))
                  for f in list(run.glob("ldc-*.log")) + list(run.glob("share-*.log")))
    check(nrounds == 240, f"SG2044: {nrounds} rounds, expected 240")
    N["sg:rounds"] = str(nrounds)
    report.append(f"SG2044: rounds with a busy core before the start: {len(BUSY)} of 240 {BUSY}")
    report.append(f"SG2044: BUILD PASS (44 audits), TIME DONE, best-of = the job's table (176 values), "
                  f"MPI check PASS at {sorted(mpi)} with the helper thread at 0 %")

    # ---- fair test ----
    ftk, srck = fair_test_k1()
    fts, srcs = fair_test_sg(run)
    rows = []
    for m, ft, lanes in (("kone", ftk, {"f32": 8, "f64": 4}), ("sg", fts, {"f32": 4, "f64": 2})):
        for p in PRECS:
            row = [f"{m}{p}", lanes[p]]
            for cc in COMPILERS:
                base, rvv, v, ratio = fair_ratio(ft, cc, p)
                every = ft[(cc, p, "every", "scalar_cse_aa")]["best"]
                row += [f"{ratio:.3f}"]
                N[f"{m}:fair:{cc}:{p}"] = f2(ratio)
                N[f"{m}:fair:{cc}:{p}:base"] = f2(base)
                N[f"{m}:fair:{cc}:{p}:baseevery"] = f2(every)
                N[f"{m}:fair:{cc}:{p}:rvv"] = f2(rvv)
                N[f"{m}:fair:{cc}:{p}:which"] = SHORT[v]
                N[f"{m}:fair:{cc}:{p}:share"] = f"{100 * (ratio - 1) / (lanes[p] - 1):.0f}"
                report.append(f"fair test {m} {cc} {p}: best scalar every {every:.2f}, last {base:.2f}; "
                              f"fastest RVV last ({v}) {rvv:.2f}; ratio {ratio:.2f} of {lanes[p]} lanes")
            rows.append(row)
        N[f"{m}:lanes:f32"], N[f"{m}:lanes:f64"] = str(lanes["f32"]), str(lanes["f64"])
    # the Clang in-place + prefetch build with output last on the SG2044 (a different generated kernel)
    for p in PRECS:
        for cc in COMPILERS:
            e = fts[(cc, p, "every", "explicit_cse_aa_pf")]["best"]
            l = fts[(cc, p, "last", "explicit_cse_aa_pf")]["best"]
            N[f"sg:aapf:{cc}:{p}:every"], N[f"sg:aapf:{cc}:{p}:last"] = f2(e), f2(l)
    write_dat("cmp-fair.dat", ["group", "lanes", "gcc", "clang"], rows, srck + srcs,
              "fastest RVV build over best scalar, both with density and velocity only in the last step, one core")

    # ---- traffic estimate at the largest core count (bytes per cell x cells per second) ----
    # AA pattern: 19 values read + 19 written + 4 outputs (rho, u) written; +4 if the outputs are write-allocated
    for p, b in (("f32", 4), ("f64", 8)):
        lo, hi = (19 + 19 + 4) * b, (19 + 19 + 4 + 4) * b
        mlups = data["sg"][("gcc", p, 64, "explicit_cse_aa_split")]["best"]
        N[f"sg:bytes:{p}:lo"], N[f"sg:bytes:{p}:hi"] = str(lo), str(hi)
        N[f"sg:gbs:{p}:lo"], N[f"sg:gbs:{p}:hi"] = f"{lo * mlups / 1000:.0f}", f"{hi * mlups / 1000:.0f}"

    # ---- numbers.tex ----
    srcs_all = all_sources + verify_src + [bfile, tfile] + srck + srcs
    lines = [header(srcs_all, f"SG2044 run {run.name}")]
    lines += [f"\\nset{{{k}}}{{{v}}}" for k, v in sorted(N.items())]
    (OUT / "numbers.tex").write_text("\n".join(lines) + "\n")
    print("\n".join(report))
    print(f"wrote {len(N)} numbers and {len(list(OUT.glob('*.dat')))} tables into {OUT.relative_to(REPO)}/")


if __name__ == "__main__":
    try:
        main()
    except CheckFailed as e:
        sys.exit(f"CHECK FAILED: {e}")

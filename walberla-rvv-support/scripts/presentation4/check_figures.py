"""Check that every number plotted or tabled in docs/presentation4 equals what the scripts compute from the logs.

Usage: python3 scripts/presentation4/check_figures.py [<logdir>]
  <logdir> default: docs/presentation4/board-logs/board

The figure files hold coordinates copied from the scripts' --tex output. This check recomputes them and
compares, so a copying mistake, a stale figure or a swapped series cannot go unnoticed:
  * figures/speedup-1core-{f32,f64}, mlups-1core, mlups-multicore, speedup-multicore-{f32,f64}: against
    slide_numbers.py --tex; figures/streams: against streams_table.py --tex.
  * Every \\addplot ... coordinates {...} block must equal (same x, same printed y, same label) a subset of
    one series of the figure's own section of that output (for a per-precision figure: a series of that
    precision). Blocks whose values are all 1 (plain scalar against itself) are reported and skipped.
  * figures/stream-test: each command line's cycles per line against streams_table.py --tex.
  * The two numbers tables in slides.tex: every row of slide_numbers.py --tex must appear in the frame of
    its compiler, digit for digit (\\textbf{} ignored).
Prints one line per block and row; ends with CHECK_FIGURES PASS or CHECK_FIGURES FAIL (exit status 1).
"""

import pathlib
import re
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent
DECK = REPO / "docs/presentation4"
PAIR = re.compile(r"\(([^,()\s]+),([-0-9.]+)\)(?:\[([^\]]*)\])?")


def strip_bold(s):
    return re.sub(r"\\textbf\{([^{}]*)\}", r"\1", s)


def sections(text, kind):
    """{section: {series key: {x: (y, label)}}} and {table: [rows]} from a --tex output."""
    secs, tables, cur, table = {}, {}, None, None
    for line in text.splitlines():
        if kind == "numbers":
            m = re.match(r"% figures/([a-z0-9-]+?)(?:-<prec>)?\.tex", line)
            if m:
                cur, table = m.group(1), None
                secs.setdefault(cur, {})
                continue
            m = re.match(r"% numbers table, (\w+):", line)
            if m:
                cur, table = None, m.group(1)
                tables[table] = []
                continue
        else:   # streams_table.py --tex
            m = re.match(r"% tag (\w+)(?:, stagger.*)?: \(R, (cycles per line|l2_miss per line)\)", line)
            if m:
                cur = "streams-" + ("cycles" if m.group(2).startswith("cycles") else "late")
                key = "tag " + m.group(1)
                secs.setdefault(cur, {})
                continue
        if table and line.startswith("    ") and "&" in line:
            tables[table].append(line.strip())
            continue
        if cur and line.startswith("%   "):
            body = line[4:]
            if kind == "numbers":
                key, _, body = body.partition(":")
            secs[cur][key.strip()] = {x: (y, lab) for x, y, lab in PAIR.findall(body)}
    return secs, tables


def blocks(tex):
    """[(first line number, [(x, y, label)])] of the \\addplot coordinate blocks of a figure file."""
    out = []
    for m in re.finditer(r"\\addplot(?:\[[^\]]*(?:\[[^\]]*\][^\]]*)*\])?\s*coordinates\s*\{((?:[^{}]|\{[^{}]*\})*)\}", tex):
        body = m.group(1)
        pairs = [(x, y, strip_bold(lab)) for x, y, lab in PAIR.findall(body)]
        out.append((tex.count("\n", 0, m.start()) + 1, pairs))
    return out


FIGURES = {   # figure -> (source, section(s), required word in the series key)
    "speedup-1core-f32": ("numbers", ["speedup-1core"], "f32"),
    "speedup-1core-f64": ("numbers", ["speedup-1core"], "f64"),
    "mlups-1core": ("numbers", ["mlups-1core"], ""),
    "mlups-multicore": ("numbers", ["mlups-multicore"], ""),
    "speedup-multicore-f32": ("numbers", ["speedup-multicore"], "f32"),
    "speedup-multicore-f64": ("numbers", ["speedup-multicore"], "f64"),
    "streams": ("streams", ["streams-cycles", "streams-late"], ""),
}


def main():
    logdir = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DECK / "board-logs/board"
    run = lambda script: subprocess.run([sys.executable, str(HERE / script), "--tex", str(logdir)],
                                        capture_output=True, text=True, check=True).stdout
    streams_out = run("streams_table.py")
    data = {"numbers": sections(run("slide_numbers.py"), "numbers"), "streams": sections(streams_out, "streams")}
    fails, nblocks = 0, 0
    for fig, (src, secnames, word) in FIGURES.items():
        tex = (DECK / "figures" / f"{fig}.tex").read_text()
        for line, pairs in blocks(tex):
            nblocks += 1
            if pairs and all(float(y) == 1.0 for _, y, _ in pairs):
                print(f"skip  {fig}.tex:{line}  all values 1 (plain scalar against itself)")
                continue
            hits = []
            for sec in secnames:
                for key, series in data[src][0].get(sec, {}).items():
                    if word and word not in key.split():
                        continue
                    if all(x in series and series[x][0] == y and (not lab or lab == series[x][1]) for x, y, lab in pairs):
                        hits.append(f"{sec}: {key}")
            if hits:
                print(f"ok    {fig}.tex:{line}  {len(pairs)} points = {' | '.join(hits)}")
            else:
                fails += 1
                print(f"FAIL  {fig}.tex:{line}  {pairs} matches no series of {secnames} {word}")
    #   figures/stream-test.tex: each command line of the code box carries the computed cycles per line
    want = re.findall(r"^% figures/stream-test\.tex: (.*?) -> (\d+)", streams_out, re.M)
    shown = {}
    for line in (DECK / "figures/stream-test.tex").read_text().splitlines():
        if line.lstrip().startswith("%") or "//" not in line:
            continue
        u = re.sub(r"\\textcolor\{psgray\}\{", "", line).replace("\\ ", " ").replace("\\_", "_")
        code, _, comment = u.partition("//")
        m = re.search(r"\d+", comment)
        if m:
            shown[re.sub(r"\s+", " ", code).strip()] = m.group(0)
    for cmd, n in want:
        nblocks += 1
        if shown.get(cmd) == n:
            print(f"ok    stream-test.tex  {cmd}  -> {n}")
        else:
            fails += 1
            print(f"FAIL  stream-test.tex  {cmd}: shows {shown.get(cmd)}, computed {n}")
    if len(want) != 5:
        fails += 1
        print(f"FAIL  stream-test.tex: {len(want)} computed results instead of 5 (streams-pattern.log missing?)")
    slides = (DECK / "slides.tex").read_text()
    nrows = 0
    for cc, rows in data["numbers"][1].items():
        title = f"Numbers: every build in one session, {'GCC' if cc == 'gcc' else 'Clang'}"
        a = slides.index(f"\\begin{{frame}}{{{title}}}")
        frame = slides[a:slides.index("\\end{frame}", a)]
        #   table rows end at \\ and may span several source lines: compare whole rows, comments removed
        body = "\n".join(l.split("%")[0] if not l.lstrip().startswith("%") else "" for l in frame.splitlines())
        rules = re.compile(r"\\(?:top|mid|bottom)rule|\\cmidrule(?:\([^)]*\))?\{[^}]*\}")
        lines = {re.sub(r"\s+", " ", rules.sub("", strip_bold(r))).strip() for r in body.split("\\\\")}
        for row in rows:
            nrows += 1
            want = re.sub(r"\s+", " ", row).strip()
            if want.endswith("\\\\"):
                want = want[:-2].strip()
            if want in lines:
                print(f"ok    table {cc}: {want[:60]}")
            else:
                fails += 1
                print(f"FAIL  table {cc}: {want}  not in the frame '{title}'")
    print(f"\n{nblocks} plot blocks, {nrows} table rows: " + ("CHECK_FIGURES PASS" if not fails else f"CHECK_FIGURES FAIL ({fails})"))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()

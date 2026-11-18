"""Tables from streams_check.sh's logs (docs/presentation4, slide "The real limit: too many data streams").

Usage: python3 scripts/presentation4/streams_table.py [--tex] <logdir>
  <logdir> holds streams-probe.log and streams-ldc.log (docs/presentation4/board-logs/board/ in the repository).
  --tex  print the coordinates of figures/streams.tex instead (cycles and L2 demand misses per line), and
         the five results of figures/stream-test.tex (from streams-probe.log and streams-pattern.log).

A counter value is used only if perf counted it all the time (enabled 100.00 %); otherwise the cell shows
"mux". The stream test's own cycle counter (probes/pmu.hpp) shares the hardware with perf: in the runs of
event group 1 (cycles, instructions, ...) perf multiplexes and the probe's cyc_per_line is wrong, so the
cycles per line come from the group-2 runs (no generic cycle event there).

Stream test, per 64-byte line read: (count(reps=3) - count(reps=0)) / (3 * R * 4 MiB / 64 B).
Program, per cell update: (count(20 steps) - count(0 steps)) / (64^3 * 20); MLUP/s from the 20-step run.
"""

import collections
import pathlib
import re
import sys

EVENTS = ["l1d_prefetch_hit", "l1d_prefetch_refill", "l1d_load_miss", "l2_miss", "l2_load_access",
          "stalled_cycle_backend"]


def blocks(path):
    """Yield (header dict, program line or None, {event: (value, percent)})."""
    head, prog, ev = None, None, {}
    for line in pathlib.Path(path).read_text().splitlines():
        if line.startswith("== "):
            if head is not None:
                yield head, prog, ev
            head, prog, ev = dict(re.findall(r"(\w+)=(\S+)", line)), None, {}
        elif line.startswith(("stream ", "SweepgenLdcCPU ")):
            prog = dict(re.findall(r"(\w+)=(\S+)", line))
        elif line.startswith("perf,"):
            f = line.split(",")
            #   perf,value,unit,event,run-time,percent,...
            val = float(f[1]) if f[1] not in ("<not counted>", "<not supported>") else None
            ev[f[3]] = (val, float(f[5]) if f[5] else 0.0)
    if head is not None:
        yield head, prog, ev


def per_unit(a, b, e, units):
    if e not in a or e not in b or a[e][0] is None or b[e][0] is None:
        return "-"
    if a[e][1] < 100.0 or b[e][1] < 100.0:
        return "mux"
    return f"{(a[e][0] - b[e][0]) / units:.3f}"


def probe_data(logdir):
    runs = collections.defaultdict(dict)    # (tag, stagger, pfr, R) -> {reps: {event: (v, pct)}}
    cyc = {}
    for h, prog, ev in blocks(pathlib.Path(logdir) / "streams-probe.log"):
        key = (h["tag"], int(h["stagger"]), int(h["pfr"]), int(h["R"]))
        runs[key].setdefault(int(h["reps"]), {}).update(ev)
        if int(h["reps"]) == 3 and "cycles" not in h["events"] and prog:
            cyc[key] = (float(prog["cyc_per_line"]), float(prog["GBps"]))
    return runs, cyc


def probe(logdir):
    runs, cyc = probe_data(logdir)
    tags = sorted({k[:3] for k in runs}, key=lambda t: ("a", "b1", "b2", "c", "d").index(t[0]))
    for tag, st, pfr in tags:
        print(f"\n## stream test, tag {tag}: stagger {st} B, software prefetch {pfr} B (0 = none); per line read\n")
        print("| R | cycles/line | GB/s | " + " | ".join(EVENTS) + " |")
        print("|---" * (len(EVENTS) + 3) + "|")
        for R in sorted(k[3] for k in runs if k[:3] == (tag, st, pfr)):
            r = runs[(tag, st, pfr, R)]
            lines = 3 * R * (4 << 20) / 64
            c, g = cyc.get((tag, st, pfr, R), (float("nan"), float("nan")))
            cells = [per_unit(r.get(3, {}), r.get(0, {}), e, lines) for e in EVENTS]
            print(f"| {R} | {c:.1f} | {g:.2f} | " + " | ".join(cells) + " |")


def ldc(logdir):
    runs = collections.defaultdict(dict)    # (prec, variant) -> {steps: {event: (v, pct)}}
    mlups = {}
    for h, prog, ev in blocks(pathlib.Path(logdir) / "streams-ldc.log"):
        if "variant" not in h:
            continue
        key = (h["prec"], h["variant"])
        runs[key].setdefault(int(h["steps"]), {}).update(ev)
        if int(h["steps"]) > 0 and prog and "cycles" not in h["events"]:
            mlups[key] = float(prog["mlups"])
    print("\n## the program (GCC, 64^3, one core): per cell update, whole program\n")
    print("| precision | variant | MLUP/s | cycles/cell (1.6 GHz / MLUP/s) | " + " | ".join(EVENTS) + " |")
    print("|---" * (len(EVENTS) + 4) + "|")
    for key in runs:
        r = runs[key]
        cells = 64 ** 3 * 20
        m = mlups.get(key, float("nan"))
        print(f"| {key[0]} | {key[1]} | {m:.2f} | {1600 / m:.0f} | "
              + " | ".join(per_unit(r.get(20, {}), r.get(0, {}), e, cells) for e in EVENTS) + " |")


def pattern_runs(logdir):
    """{pfr: [cycles per line of each run]} from streams-pattern.log (19 read + 23 write streams)."""
    runs, pfr = {}, None
    path = pathlib.Path(logdir) / "streams-pattern.log"
    if not path.exists():
        return runs
    for line in path.read_text().splitlines():
        m = re.match(r"== pattern .*pfr=(\d+)", line)
        if m:
            pfr = int(m.group(1))
        elif line.startswith("stream ") and pfr is not None:
            runs.setdefault(pfr, []).append(float(dict(re.findall(r"(\w+)=(\S+)", line))["cyc_per_line"]))
    return runs


def stream_test(logdir):
    """The five runs of the slide "The stream test": (command as on the slide, cycles per line, source)."""
    runs, cyc = probe_data(logdir)
    pat = pattern_runs(logdir)
    out = []
    for cmd, key in (("./mem stream 8 0 thp=1 stagger=4160", ("a", 4160, 0, 8)),
                     ("./mem stream 24 0 thp=1 stagger=4160", ("a", 4160, 0, 24)),
                     ("./mem stream 24 0 thp=1 stagger=4160 pfr=512", ("c", 4160, 512, 24))):
        if key in cyc:
            out.append((cmd, cyc[key][0], f"streams-probe.log tag {key[0]}"))
    for cmd, pfr in (("./mem stream 19 23 thp=1 stagger=4160", 0), ("./mem stream 19 23 thp=1 stagger=4160 pfr=128", 128)):
        if pfr in pat:
            out.append((cmd, min(pat[pfr]), "streams-pattern.log, best of " + str(len(pat[pfr])) + " runs: "
                        + " ".join(f"{c:.1f}" for c in pat[pfr])))
    return out


def tex(logdir):
    runs, cyc = probe_data(logdir)
    for tag in sorted({k[:3] for k in runs}):
        ks = sorted((k for k in runs if k[:3] == tag), key=lambda k: k[3])
        print(f"% tag {tag[0]}, stagger {tag[1]} B, software prefetch {tag[2]} B: (R, cycles per line)")
        print("%   " + " ".join(f"({k[3]},{cyc[k][0]:.1f})" for k in ks if k in cyc))
        pts = []
        for k in ks:
            v = per_unit(runs[k].get(3, {}), runs[k].get(0, {}), "l2_miss", 3 * k[3] * (4 << 20) / 64)
            if v not in ("-", "mux"):
                pts.append(f"({k[3]},{v})")
        print(f"% tag {tag[0]}: (R, l2_miss per line)\n%   " + " ".join(pts))
    for cmd, c, src in stream_test(logdir):
        print(f"% figures/stream-test.tex: {cmd} -> {c:.0f}   ({c:.1f} cycles per line; {src})")


def main():
    args = [a for a in sys.argv[1:] if a != "--tex"]
    if len(args) != 1:
        sys.exit(__doc__)
    if "--tex" in sys.argv:
        tex(args[0])
        return
    probe(args[0])
    ldc(args[0])
    print("\n## the slide \"The stream test\": cycles per 64-byte line\n")
    print("| command | cycles per line | source |")
    print("|---|---|---|")
    for cmd, c, src in stream_test(args[0]):
        print(f"| `{cmd}` | {c:.1f} | {src} |")


if __name__ == "__main__":
    main()

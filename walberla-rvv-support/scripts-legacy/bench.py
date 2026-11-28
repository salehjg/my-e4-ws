#!/usr/bin/env python3
"""Configure, build and time the legacy-core benchmarks on this machine, and tabulate the results (README.md).

    python3 scripts-legacy/bench.py setup                        venv for the code generation (pystencils 1.4)
    python3 scripts-legacy/bench.py configure <experiment>       cmake
    python3 scripts-legacy/bench.py build <experiment>           the executables of its variants
    python3 scripts-legacy/bench.py run <experiment> [--quick]   time them: results-legacy/<time>-<random>/bench.json5
    python3 scripts-legacy/bench.py all <experiment>             (setup if no venv,) configure, build, run --quick, run
    python3 scripts-legacy/bench.py list                         the runs in results-legacy/
    python3 scripts-legacy/bench.py table <run folder>...        medians, speedups, checksums
    python3 scripts-legacy/bench.py animate <experiment> [...]   one variant, untimed, with VTK output (animation.py)
    python3 scripts-legacy/bench.py render <animation folder>    its PNG frames and GIF (laptop)

Experiments and machines are defined in experiments.py; the machine is recognized (--machine overrides; monte3's
jobs always pass it, so /proc/cpuinfo is not read there); its environment modules are loaded first. Standard
library only. Of the system's files it reads /proc/meminfo and /proc/loadavg, and /proc/cpuinfo without --machine:
nothing under /sys, no frequency, power or temperature.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import importlib.util
import json
import math
import os
import platform
import re
import secrets
import shutil
import signal
import statistics
import subprocess
import sys
import time
from collections import defaultdict
from pathlib import Path

sys.dont_write_bytecode = True  # no __pycache__ next to the scripts
from experiments import EXPERIMENTS, MACHINES, REFERENCE, TOLERANCE, App, Vectors

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
SUB = REPO / "submodules"
RESULTS = REPO / "results-legacy"
# Each timing run is stopped after this many seconds (the longest normal one takes about a minute), so that a hung
# mpirun does not use up a slurm job: notes7's job 8552 on monte3 lost 5.6 of its 6 hours in one mpirun.
RUN_LIMIT = 600
PYTHON_SOURCE = "3.12.11"  # built by setup only where no Python >= 3.10 with ensurepip runs bench.py
MODULES_INIT = "/usr/share/Modules/init/bash"  # defines the shell function `module` (Environment Modules)
# pystencils 1.4's dependencies (submodules/pystencils/pyproject.toml) and the code generation's (jinja2, py-cpuinfo)
PIP_PACKAGES = ["sympy==1.12.1", "numpy", "appdirs", "joblib", "pyyaml", "fasteners", "jinja2", "py-cpuinfo",
                "packaging"]
NAN = float("nan")


# ---- names: the only place that knows how the generator scripts decode them -----------------------------------

def instruction_set(v):
    """the backend's name as pystencils takes it; for rvv.our1 with the options, which pystencils'
    riscv_our1_instruction_sets.parse_options reads: rvv.our1[-vls<N>][-m<L>][-vf][-fma][-pf<N>]"""
    if v.vectors is not Vectors.RVV_OUR1:
        return v.vectors.value
    options = [f"vls{v.vlen}" if v.vlen else "", f"m{v.lmul}" if v.lmul > 1 else "",
               "vf" if v.vf else "", "fma" if v.fma else "", f"pf{v.prefetch}" if v.prefetch else ""]
    return "-".join([v.vectors.value] + [o for o in options if o])


def label(v):
    """<streaming pattern>_<backend>[-<option>...], e.g. pull_none, aa_rvv.lgcy, aa_rvv.our1-vf-fma (README, Names)"""
    return f"{v.streaming.value}_{instruction_set(v)}"


def codegen_config(b, v):
    """CODEGEN_CFG of the variant's target, which the generator script gets as ctx.config"""
    if b.app is App.WIND:  # waLBerla-wind's LBMGeneration.py splits it at the first "_"
        return label(v)
    # UniformGridCPU.py: <stencil>_<pattern>_<collision>[_<instruction set>]; no fourth part: no explicit vectors.
    # Those targets are upstream's own, so they are not passed again in UNIFORMGRIDCPU_EXTRA_CONFIGS.
    config = f"{b.stencil}_{v.streaming.value}_{b.collision}"
    return config if v.vectors is Vectors.NONE else f"{config}_{instruction_set(v)}"


def check_names(m, b):
    """The rvv.our1 names written here must mean to pystencils what experiments.py says."""
    ours = [v for v in b.variants if v.vectors is Vectors.RVV_OUR1]
    if not ours:
        return
    code = ("import json, sys\nfrom pystencils.backends.riscv_our1_instruction_sets import parse_options\n"
            "print(json.dumps([parse_options(s) for s in sys.argv[1:]]))")
    out = subprocess.run([python(m), "-c", code, *map(instruction_set, ours)], env=codegen_env(m),
                         check=True, capture_output=True, text=True).stdout
    for v, parsed in zip(ours, json.loads(out.splitlines()[-1])):
        if parsed != v.options():
            sys.exit(f"{instruction_set(v)}: pystencils reads {parsed}, experiments.py says {v.options()}")


# ---- paths and helpers ------------------------------------------------------------------------------------------

def folder(template):
    return Path(template.format(repo=REPO, base=REPO.parent))


def build_dir(m, b):
    return folder(m.work) / "builds" / b.name


def python(m):
    return folder(m.venv) / "bin" / "python"


def executable(m, b, v):
    if b.app is App.WIND:
        return build_dir(m, b) / "apps/BenchmarkApp_cpu_uniform" / f"TurbineBenchmark_cpu_uniform_{codegen_config(b, v)}"
    return build_dir(m, b) / "apps/benchmarks/UniformGridCPU" / f"UniformGridCPU_{codegen_config(b, v)}"


def codegen_env(m):
    """pystencils 1.4 from the submodule (the legacy code generation keeps PYTHONPATH from configure time); no
    __pycache__ folders in the source trees (waLBerla-wind has no .gitignore, it would look changed); temporary
    files of compilers and pip in the work folder (the K1's root file system, with /tmp, is nearly full)"""
    tmp = folder(m.work) / "tmp"
    tmp.mkdir(parents=True, exist_ok=True)
    return dict(os.environ, PYTHONPATH=str(SUB / "pystencils" / "src"), PYTHONDONTWRITEBYTECODE="1", TMPDIR=str(tmp))


def sh(cmd, **kwargs):
    cmd = [str(c) for c in cmd]
    print("+", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True, **kwargs)


def first_line(cmd, **kwargs):
    try:
        out = subprocess.run([str(c) for c in cmd], capture_output=True, text=True, **kwargs)
        return (out.stdout or out.stderr).strip().splitlines()[0]
    except (OSError, IndexError):
        return ""


def detect_machine():
    if "spacemit,x60" in Path("/proc/cpuinfo").read_text(errors="replace"):
        return "bananapi"
    if platform.machine() == "x86_64":
        return "laptop"
    sys.exit(f"unknown machine {platform.node()}: add it to experiments.MACHINES, or pass --machine")


def source_info():
    """Branch, commit and uncommitted changes (`git status --porcelain`, without results-legacy/) of this
    repository and each submodule. The boards get a whole git repository (remote.py push), so this works there too."""
    info = {}
    for d in [REPO, *sorted(p for p in SUB.iterdir() if p.is_dir())]:
        def git(*args):
            out = subprocess.run(["git", "-C", d, *args], check=True, capture_output=True, text=True).stdout
            return out.rstrip("\n")  # not strip(): the first column of git status matters
        info[str(d.relative_to(REPO.parent))] = dict(
            branch=git("branch", "--show-current"), commit=git("rev-parse", "HEAD"),
            date=git("log", "-1", "--format=%cI"),
            changes=git("status", "--porcelain", "--", ".", f":(exclude){RESULTS.name}").splitlines())
    return info


def software(m, b):
    cache = (build_dir(m, b) / "CMakeCache.txt").read_text()
    cxx = re.search(r"^CMAKE_CXX_COMPILER:\w+=(.*)$", cache, re.M).group(1)
    cxx = shutil.which(cxx) or cxx
    version ="import pystencils, lbmpy; print('pystencils', pystencils.__version__, 'lbmpy', lbmpy.__version__)"
    return dict(compiler=first_line([cxx, "--version"]), compiler_path=cxx, cmake=first_line(["cmake", "--version"]),
                mpi=first_line([m.mpirun[0], "--version"]), python=first_line([python(m), "--version"]),
                codegen=first_line([python(m), "-c", version], env=codegen_env(m)))


def describe_executable(x):
    flags = x.parent / "CMakeFiles" / f"{x.name}.dir" / "flags.make"
    cxx_flags = re.search(r"^CXX_FLAGS = (.*)$", flags.read_text(), re.M) if flags.exists() else None
    return dict(executable=str(x), sha256=hashlib.sha256(x.read_bytes()).hexdigest()[:16],
                cxx_flags=cxx_flags.group(1) if cxx_flags else "")


def process_grid(n):
    """n processes as x*y*z blocks, as even as possible: 4 -> (2, 2, 1), 8 -> (2, 2, 2)"""
    factors, p = [], 2
    while n > 1:
        while n % p:
            p += 1
        factors.append(p)
        n //= p
    dims = [1, 1, 1]
    for f in sorted(factors, reverse=True):
        dims[dims.index(min(dims))] *= f
    return sorted(dims, reverse=True)


# ---- bench.json5: JSON plus whole-line // comments (so any JSON5 parser reads it, and load_run below) ----------

HEADER = """\
// One run of scripts-legacy/bench.py (README.md there). JSON5: JSON plus // comment lines; NaN marks a missing value.
// Python: json.loads of the lines that do not start with //, or bench.load_run(<this file>).
"""
COMMENTS = {
    "experiment": "what was timed (scripts-legacy/experiments.py); quick: the short check before timing",
    "build": "the CMake tree of the executables",
    "machine": "where; nothing under /sys was read (no frequency, power or temperature)",
    "software": "versions; codegen: the venv's pystencils (the submodule's checkout) and lbmpy",
    "source": "this repository and each submodule (paths from the git root): branch, commit, its date, and the "
              "uncommitted changes at that time (git status --porcelain; empty: clean)",
    "variants": "per variant: its code generation fields and the executable that ran",
    "runs": "one per run, in the order they ran: MLUP/s from waLBerla's PerformanceEvaluation, the checksum "
            "(sum of rho and of |u|^2 over the interior), the load average before the run",
    "summary": "per process count and variant: median and best MLUP/s over the rounds, speedup of the median vs "
               "pull_none, checksum vs pull_none (largest relative difference; ok if <= experiment.tolerance)",
}


def dump(value, indent):
    """JSON: a dict one key per line; a list of dicts, or a long one, one entry per line; anything else on one line"""
    if isinstance(value, dict) and value:
        return "{\n" + ",\n".join(f"{indent}  {json.dumps(k)}: {dump(v, indent + '  ')}" for k, v in value.items()) \
            + f"\n{indent}}}"
    if isinstance(value, list) and (any(isinstance(x, (dict, list)) for x in value) or len(json.dumps(value)) > 100):
        return "[\n" + ",\n".join(f"{indent}  {json.dumps(x)}" for x in value) + f"\n{indent}]"
    return json.dumps(value)


def save_run(run_folder, data):
    lines = [HEADER + "{"]
    for i, (key, value) in enumerate(data.items()):
        if key in COMMENTS:
            lines.append(f"  // {COMMENTS[key]}")
        lines.append(f"  {json.dumps(key)}: {dump(value, '  ')}" + ("," if i < len(data) - 1 else ""))
    tmp = run_folder / "bench.json5.tmp"
    tmp.write_text("\n".join(lines) + "\n}\n")
    tmp.replace(run_folder / "bench.json5")  # a crash never leaves half a file


def load_run(path):
    path = Path(path)
    text = (path / "bench.json5" if path.is_dir() else path).read_text()
    return json.loads("\n".join(line for line in text.splitlines() if not line.lstrip().startswith("//")))


# ---- commands ---------------------------------------------------------------------------------------------------

def load_modules(m):
    """The machine's environment modules, loaded by a shell as a user would, then taken over into this process's
    environment; and a check that the MPI compiler wrapper (what CMake finds) belongs to the MPI of m.mpirun."""
    if not m.modules:
        return
    script = f"source {MODULES_INIT} && " + " && ".join(f"module load {x}" for x in m.modules)
    out = subprocess.run(["bash", "-c", script + " && env -0"], capture_output=True, text=True, check=True).stdout
    os.environ.clear()
    os.environ.update(entry.split("=", 1) for entry in out.split("\0") if "=" in entry)
    mpicxx = shutil.which("mpicxx")
    if not mpicxx or Path(mpicxx).parent != Path(m.mpirun[0]).parent:
        sys.exit(f"the modules {' '.join(m.modules)} did not take effect: mpicxx is {mpicxx}, mpirun {m.mpirun[0]}")
    print(f"modules {' '.join(m.modules)}: {mpicxx}, {first_line(['gcc', '--version'])}", flush=True)


def venv_python(m):
    """A Python that can make the venv: the one running bench.py if it is new enough (pystencils 1.4 and lbmpy 1.4
    need 3.10) and has ensurepip; else Python PYTHON_SOURCE, built from python.org's source into the work folder
    once."""
    if sys.version_info >= (3, 10) and importlib.util.find_spec("ensurepip"):
        return sys.executable
    prefix = folder(m.work) / f"python-{PYTHON_SOURCE}"
    if not (prefix / "bin" / "python3").exists():
        src, name = folder(m.work) / "tmp", f"Python-{PYTHON_SOURCE}"
        src.mkdir(parents=True, exist_ok=True)
        url = f"https://www.python.org/ftp/python/{PYTHON_SOURCE}/{name}.tgz"
        sh(["curl", "-fsSL", "-o", src / f"{name}.tgz", url])
        sh(["tar", "xzf", src / f"{name}.tgz", "-C", src])
        sh(["./configure", f"--prefix={prefix}", "--with-ensurepip=install"], cwd=src / name)
        sh(["make", "-j", compile_jobs(m)], cwd=src / name)
        sh(["make", "install"], cwd=src / name)
    return prefix / "bin" / "python3"


def setup(m, python_for_venv=None):
    """The venv of the code generation, made with whatever is missing. It sees the system's packages: PyPI has no
    numpy for riscv64, so the distribution's is used where there is one; where there is none, pip builds it (once:
    pip's cache is in the work folder)."""
    venv = python(m).parent.parent
    if not venv.exists():
        sh([python_for_venv or venv_python(m), "-m", "venv", "--system-site-packages", venv])
    pip = [python(m), "-m", "pip", "install", "--cache-dir", folder(m.work) / "pip-cache"]
    env = dict(codegen_env(m), CC="gcc", CXX="g++")  # a numpy build from source: the same compilers as the apps
    sh([*pip, *PIP_PACKAGES], env=env)
    sh([*pip, "--no-deps", "lbmpy==1.4"], env=env)  # pystencils: the submodule
    sh([python(m), "-c", "import sys, pystencils, lbmpy; print(sys.version, pystencils.__file__, lbmpy.__version__)"],
       env=codegen_env(m))


def configure(m, b):
    wrong = [label(v) for v in b.variants if v.vlen not in (None, m.vlen)]
    if wrong:  # pystencils' guard header would stop the build only after the code generation, at the first file
        sys.exit(f"this machine's VLEN is {m.vlen}, these variants need another: {' '.join(wrong)}")
    check_names(m, b)
    names = [codegen_config(b, v) for v in b.variants]
    cc, cxx = b.compiler.value
    cmd = ["cmake", "-S", SUB / ("waLBerla-wind" if b.app is App.WIND else "walberla"), "-B", build_dir(m, b),
           "-DCMAKE_BUILD_TYPE=Release", f"-DCMAKE_C_COMPILER={cc}", f"-DCMAKE_CXX_COMPILER={cxx}",
           f"-DPython_EXECUTABLE={python(m)}", "-DWALBERLA_BUILD_WITH_CODEGEN=ON",
           f"-DWALBERLA_DOUBLE_ACCURACY={'ON' if b.precision == 64 else 'OFF'}", f"-DCMAKE_CXX_FLAGS={m.cxx_flags}",
           f"-DCMAKE_EXE_LINKER_FLAGS={m.link_flags}",
           # OFF: ON would also vectorize every kernel that sets no instruction set itself with the machine's best
           # one (waLBerla-wind's flow driver: pystencils 1.4 cannot, cos()); the -march comes from the machine.
           "-DWALBERLA_OPTIMIZE_FOR_LOCALHOST=OFF"]
    if b.app is App.WIND:
        cmd += [f"-DWALBERLA_DIR={SUB / 'walberla'}", "-DWALBERLA_BUILD_WITH_PYTHON=OFF",
                f"-DWIND_BENCHMARK_VARIANTS={';'.join(names)}"]
    else:  # upstream adds UniformGridCPU only with Python (apps/benchmarks/CMakeLists.txt); it downloads pybind11
        extra = [n for v, n in zip(b.variants, names) if v.vectors is not Vectors.NONE]
        cmd += ["-DWALBERLA_BUILD_WITH_PYTHON=ON", f"-DUNIFORMGRIDCPU_EXTRA_CONFIGS={';'.join(extra)}"]
    sh(cmd, env=codegen_env(m))


def cpus():
    """the cores this process may use (in a slurm job: its allocation); unlike os.cpu_count(), it reads no /sys file"""
    return len(os.sched_getaffinity(0))


def compile_jobs(m):
    """m.jobs, or one per core and at most one per 2 GB of memory (the heaviest waLBerla files need about 1.3 GB)"""
    if m.jobs:
        return m.jobs
    kib = int(re.search(r"^MemTotal:\s+(\d+)", Path("/proc/meminfo").read_text(), re.M).group(1))
    return max(1, min(cpus(), kib // (2 * 1024 * 1024)))


def build(m, b, variants=None):
    targets = [executable(m, b, v).name for v in variants or b.variants]
    sh(["cmake", "--build", build_dir(m, b), "-j", compile_jobs(m), "--target", *targets], env=codegen_env(m))


def app_command(m, b, cells, exe, n, warmup, steps):
    """n processes, one cells^3 block each; run in the executable's folder (waLBerla-wind reads its files there)"""
    gx, gy, gz = process_grid(n)
    if b.app is App.WIND:
        prm, domain = "benchmark.prm", f"-DomainSetup.domainSize=<{gx * cells},{gy * cells},{gz * cells}>"
    else:
        prm, domain = HERE / "uniform_grid_cpu.prm", f"-DomainSetup.blocks=<{gx},{gy},{gz}>"
    launch = ["taskset", "-c", m.pin_cpu] if n == 1 else [*m.mpirun, "-np", n]
    return [str(a) for a in (*launch, exe, prm, domain, f"-DomainSetup.cellsPerBlock=<{cells},{cells},{cells}>",
                             f"-Parameters.warmupSteps={warmup}", f"-Parameters.timesteps={steps}")]


def time_one(m, b, cells, exe, n, warmup, steps, log):
    cmd = app_command(m, b, cells, exe, n, warmup, steps)
    start = time.time()
    p = subprocess.Popen(cmd, cwd=exe.parent, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                         start_new_session=True)  # its own process group: a hung run is stopped with all its ranks
    try:
        out = p.communicate(timeout=RUN_LIMIT)[0]
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGTERM)  # mpirun passes it on to its ranks
        try:
            out = p.communicate(timeout=15)[0]
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            out = p.communicate()[0]
        out += f"\n[bench.py: stopped after {RUN_LIMIT} s]\n"
    log.write_text(" ".join(cmd) + "\n\n" + out)
    mlups = re.search(r"- performance:\s*(\S+) MLUPS", out)
    checksum = re.search(r"Checksum: sum\(rho\) = (\S+), sum\(\|u\|\^2\) = (\S+)", out)
    return dict(returncode=p.returncode, seconds=round(time.time() - start, 1),
                mlups=float(mlups.group(1)) if mlups else NAN,
                rho_sum=float(checksum.group(1)) if checksum else NAN,
                u2_sum=float(checksum.group(2)) if checksum else NAN)


def run(machine, m, name, e, quick):
    b = e.build
    cores = (e.cores or m.cores)[:2] if quick else (e.cores or m.cores)
    warmup, steps, rounds = (2, 10, 1) if quick else (e.warmup, e.steps, e.rounds)
    exes = {v: executable(m, b, v) for v in b.variants}
    missing = [str(x) for x in exes.values() if not x.exists()]
    if missing:
        sys.exit("not built (bench.py build): " + " ".join(missing))
    run_folder = RESULTS / f"{time.strftime('%Y%m%d-%H%M%S')}-{secrets.token_hex(3)}"
    (run_folder / "logs").mkdir(parents=True)
    data = dict(
        format=1, started=time.strftime("%Y-%m-%dT%H:%M:%S%z"), finished=None,
        experiment=dict(name=name, quick=quick, cores=list(cores), cells=e.cells, warmup=warmup, steps=steps,
                        rounds=rounds, tolerance=TOLERANCE[b.precision]),
        build=dict(name=b.name, app=b.app.value, precision=b.precision, compiler=b.compiler.name.lower(),
                   **(dict(stencil=b.stencil, collision=b.collision) if b.app is App.UGC else {}),
                   folder=str(build_dir(m, b))),
        machine=dict(name=machine, host=platform.node(), uname=" ".join(platform.uname()), cpus=cpus(),
                     cxx_flags=m.cxx_flags, link_flags=m.link_flags, modules=list(m.modules),
                     launch_one=["taskset", "-c", str(m.pin_cpu)], launch_mpi=list(m.mpirun)),
        software=software(m, b),
        source=source_info(),
        variants=[dict(label=label(v), streaming=v.streaming.value, vectors=v.vectors.value, **v.options(),
                       instruction_set=instruction_set(v), codegen_config=codegen_config(b, v), **describe_executable(x))
                  for v, x in exes.items()],
        runs=[],
        summary=[],
    )
    save_run(run_folder, data)
    print(f"{run_folder}\n", flush=True)
    for n in cores:
        for r in range(rounds):  # the variants in turn, so that a slow phase of the machine hits all of them
            for v in b.variants:
                log = f"logs/{label(v)}-np{n}-r{r}.log"
                record = dict(variant=label(v), cores=n, round=r, load=round(os.getloadavg()[0], 2),
                              **time_one(m, b, e.cells, exes[v], n, warmup, steps, run_folder / log), log=log)
                data["runs"].append(record)
                save_run(run_folder, data)
                failed = "" if record["returncode"] == 0 else f"  FAILED: {run_folder / log}"
                print(f"np {n:2}  round {r}  {label(v):45} {record['mlups']:8.2f} MLUP/s{failed}", flush=True)
    data["summary"] = summarize(data)
    data["finished"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    save_run(run_folder, data)
    print()
    return print_table([(run_folder.name, data, data["summary"])])


def median_mlups(runs):
    values = [r["mlups"] for r in runs if r["returncode"] == 0 and not math.isnan(r["mlups"])]
    return (statistics.median(values), max(values)) if values else (NAN, NAN)


def checksum_check(runs, ref, tolerance):
    """largest relative difference of sum(rho) and sum(|u|^2) to the reference run"""
    if ref is None:
        return "-"
    diffs = [abs(r[k] - ref[k]) / (abs(ref[k]) or 1.0) for r in runs for k in ("rho_sum", "u2_sum")]
    if any(math.isnan(d) for d in diffs):
        return "missing"
    return f"{'ok' if max(diffs) <= tolerance else 'FAIL'} {max(diffs):.1e}"


def summarize(data, baseline=None):
    """One row per process count and variant of one run."""
    reference = label(REFERENCE)
    groups = defaultdict(list)  # insertion order = run order
    for r in data["runs"]:
        groups[(r["cores"], r["variant"])].append(r)
    rows = []
    for (n, variant), runs in groups.items():
        median, best = median_mlups(runs)
        base = median_mlups(groups.get((n, baseline or reference), []))[0]
        rows.append(dict(cores=n, variant=variant, runs=len(runs), failed=sum(r["returncode"] != 0 for r in runs),
                         median=round(median, 3), best=round(best, 3),
                         speedup=round(median / base, 3) if base == base else NAN,
                         checksum=checksum_check(runs, (groups.get((n, reference)) or [None])[0],
                                                 data["experiment"]["tolerance"])))
    return rows


def print_table(runs, baseline=None, csv_path=None):
    """runs: (run id, data, summary rows). Returns False if a run failed or a checksum is off."""
    rows = [dict(run=run_id, machine=data["machine"]["name"], build=data["build"]["name"],
                 steps=data["experiment"]["steps"], **row) for run_id, data, summary in runs for row in summary]
    print(f"| run | machine | build | steps | np | variant | runs | failed | MLUP/s median | best "
          f"| speedup vs {baseline or label(REFERENCE)} | checksum vs {label(REFERENCE)} |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for row in rows:
        print("| " + " | ".join(str(x) for x in row.values()) + " |")
    if csv_path and rows:
        with open(csv_path, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
    return all(row["failed"] == 0 and not row["checksum"].startswith(("FAIL", "missing")) for row in rows)


def list_runs():
    for d in sorted(RESULTS.iterdir()) if RESULTS.exists() else []:
        if (d / "bench.json5").exists():
            data = load_run(d)
            checks = {row["checksum"].split()[0] for row in data["summary"]}
            state = "unfinished" if not data["finished"] else ("FAIL" if checks - {"ok", "-"} else "ok")
            print(f"{d.name}  {data['machine']['name']:9} {data['experiment']['name']:10} "
                  f"{'quick' if data['experiment']['quick'] else 'timed':5}  {len(data['runs']):4} runs  {state}")


def render(m, folder):
    """animation.py renders in the venv, with pyvista and matplotlib, which are installed if missing"""
    if subprocess.run([python(m), "-c", "import pyvista, matplotlib"], capture_output=True).returncode:
        pip = [python(m), "-m", "pip", "install", "--cache-dir", folder(m.work) / "pip-cache"]
        if subprocess.run([str(c) for c in (*pip, "pyvista", "matplotlib")]).returncode:
            sys.exit("pyvista or matplotlib could not be installed (VTK has no riscv64 wheels): render on the laptop, "
                     "after remote.py fetch")
    sh([python(m), HERE / "animation.py", Path(folder).resolve()])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--machine", choices=MACHINES, help="default: recognized from /proc/cpuinfo")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("setup").add_argument("--python", help="Python of the new venv (default: this one if it is "
                                                                "new enough, else one built from source)")
    for command in ("configure", "build", "run", "all"):
        commands.add_parser(command).add_argument("experiment", choices=EXPERIMENTS)
    commands.choices["run"].add_argument("--quick", action="store_true",
                                         help="2 + 10 steps, 1 round, the first two process counts: a check")
    commands.add_parser("list")
    t = commands.add_parser("table")
    t.add_argument("runs", nargs="+", help="run folders (results-legacy/<time>-<random>) or their bench.json5")
    t.add_argument("--baseline", help="variant of the speedup column, e.g. aa_rvv.lgcy (default: the reference)")
    t.add_argument("--csv", help="also write the table to this CSV file")
    a = commands.add_parser("animate", help="one variant, untimed, with VTK output (animation.py)")
    a.add_argument("experiment", choices=EXPERIMENTS)
    a.add_argument("--variant", help=f"one of the experiment's, e.g. aa_rvv.lgcy (default: {label(REFERENCE)})")
    a.add_argument("--steps", type=int, default=2000, help="time steps (default: 2000)")
    a.add_argument("--every", type=int, default=25, help="a VTK frame every so many steps (default: 25)")
    a.add_argument("--np", type=int, default=1, help="processes, one block each (default: 1)")
    commands.add_parser("render", help="PNG frames and GIF of an animation (laptop)").add_argument(
        "folder", help="<work>/animations/<time>-<random>, or one fetched into 00_private_data/legacy/<machine>/")
    args = parser.parse_args()

    if args.command == "list":
        list_runs()
        return 0
    if args.command == "table":
        runs = []
        for path in args.runs:
            data = load_run(path)
            runs.append((Path(path).resolve().parent.name if path.endswith(".json5") else Path(path).name, data,
                         summarize(data, args.baseline)))
        return 0 if print_table(runs, args.baseline, args.csv) else 1
    machine = args.machine or detect_machine()
    m = MACHINES[machine]
    load_modules(m)
    if args.command == "setup" or (args.command in ("all", "animate", "render") and not python(m).exists()):
        setup(m, getattr(args, "python", None))
    if args.command == "setup":
        return 0
    if args.command == "render":
        render(m, args.folder)
        return 0
    e = EXPERIMENTS[args.experiment]
    if args.command == "animate":
        from animation import Animation  # here: animation.py imports bench.py
        variants = {label(v): v for v in e.build.variants}
        variant = args.variant or label(REFERENCE)
        if variant not in variants:
            sys.exit(f"{args.experiment} has no variant {variant}; it has {' '.join(variants)}")
        Animation.simulate(machine, m, args.experiment, e, variants[variant], args.steps, args.every, args.np)
        return 0
    if args.command in ("configure", "all"):
        configure(m, e.build)
    if args.command in ("build", "all"):
        build(m, e.build)
    if args.command == "run":
        return 0 if run(machine, m, args.experiment, e, args.quick) else 1
    if args.command == "all":
        if not run(machine, m, args.experiment, e, quick=True):
            sys.exit("the quick run failed or a checksum is off: not timing")
        return 0 if run(machine, m, args.experiment, e, quick=False) else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

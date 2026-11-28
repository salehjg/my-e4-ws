#!/usr/bin/env python3
"""The laptop side of bench.py, for the Banana Pi and monte3 (README.md).

    python3 scripts-legacy/remote.py [--machine M] push                    the whole git repository to the machine
    python3 scripts-legacy/remote.py [--machine M] start <bench.py args>   e.g. start all wind: one job at a time
    python3 scripts-legacy/remote.py [--machine M] status                  the job and the end of the newest log
    python3 scripts-legacy/remote.py [--machine M] fetch                   its runs, job logs and animations here

M is bananapi (default) or monte3. On the Banana Pi a job is a detached screen session; on monte3 a slurm job
(sbatch) on the peak node. Ask the user before anything runs on monte3: push, start, status and fetch all connect
to it (docs/notes8, step 8).
"""
from __future__ import annotations

import shlex
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

sys.dont_write_bytecode = True  # no __pycache__ next to the scripts
from bench import REPO, RESULTS
from experiments import MACHINES


@dataclass(frozen=True)
class Remote:
    root: str                   # git root of the pushed copy (push)
    logs: str                   # the jobs' output (bench.py's: setup, configure, build, runs)
    sbatch: tuple[str, ...] = ()  # slurm options of a job; none: a screen session instead


REMOTES = {
    # my-e4-ws next to the git roots is the 2.x copy (../push.to.sh)
    "bananapi": Remote("/home/bananapi/saleh/my-e4-ws-legacy", "/home/bananapi/saleh/legacy/screen-logs"),
    # the one peak node, whole: timing runs up to 64 processes, nothing else on it while they run
    "monte3": Remote("/home/sjamaligolzar/02_ws/my-e4-ws-legacy", "/home/sjamaligolzar/02_ws/legacy/slurm-logs",
                     sbatch=("--partition=peak", "--nodes=1", "--exclusive", "--ntasks-per-node=64", "--mem=0",
                             "--time=06:00:00")),
}


def repo_on(r):
    return f"{r.root}/{REPO.relative_to(REPO.parent).as_posix()}"


def ssh(host, command, **kwargs):
    return subprocess.run(["ssh", host, command], text=True, **kwargs)


def git_lines(folder, *args):
    out = subprocess.run(["git", "-C", str(folder), *args], capture_output=True, text=True, check=True).stdout
    return out.split("\n")[:-1]


def sync_repo(destination):
    """The whole git repository (the folder above walberla-rvv-support) with its .git, which also holds the submodules'
    git data, so the copy is a working git repository and bench.py reads branch, commit and uncommitted changes there
    itself. Only what git sees goes: whatever git ignores, in the repository and in each submodule, is excluded (git
    lists it; rsync's own .gitignore reading gets `!` rules wrong). --delete keeps the copy an exact mirror, except
    results-legacy/, which is neither sent nor deleted: the machine's runs stay there until fetch."""
    root = Path(git_lines(REPO, "rev-parse", "--show-toplevel")[0])
    ignored = ("ls-files", "--others", "--ignored", "--exclude-standard", "--directory")
    excludes = [f"/{p}" for p in git_lines(root, *ignored)]
    for sub in git_lines(root, "submodule", "--quiet", "foreach", "--recursive", "echo $displaypath"):
        excludes += [f"/{sub}/{p}" for p in git_lines(root / sub, *ignored)]
    results = f"/{RESULTS.relative_to(root).as_posix()}/"
    with tempfile.NamedTemporaryFile("w", suffix=".excludes") as f:
        f.write("".join(f"{e}\n" for e in excludes))
        f.flush()
        subprocess.run(["rsync", "-az", "--delete", "--delete-excluded", "--filter", f"P {results}",
                        "--exclude", results, "--exclude-from", f.name,
                        # never pushed, also where no .gitignore rule covers them
                        "--exclude", ".claude/", "--exclude", ".perfcache", "--exclude", "*.zip",
                        f"{root}/", destination], check=True)


def push(host, r):
    ssh(host, f"mkdir -p {r.root}", check=True)
    sync_repo(f"{host}:{r.root}/")
    print(f"-> {host}:{r.root}")


def start(host, r, bench_args):
    # The K1 has no working RTC and its NTP did not sync once: with a lagging clock HTTPS fails (pip, pybind11),
    # make rebuilds everything (the pushed files lie in the future) and the run times are wrong.
    skew = int(ssh(host, "date +%s", capture_output=True, check=True).stdout) - time.time()
    if abs(skew) > 120:
        fix = "" if r.sbatch else f", e.g. ssh -t {host} \"sudo date -u -s '$(date -u '+%F %T')'\""
        sys.exit(f"the clock of {host} is off by {skew / 3600:+.1f} h: set it first{fix}")
    name = "bench-" + "-".join(bench_args).replace("/", "_")[:40]
    stamp = time.strftime('%Y%m%d-%H%M%S')
    bench = f"python3 scripts-legacy/bench.py --machine {host} " + " ".join(map(shlex.quote, bench_args))
    if r.sbatch:  # squeue --me: only our own jobs (monte3 is shared; other users' jobs are not looked at)
        busy = "squeue --me --noheader --format=%j | grep -q '^bench-'"
        launch = (f"sbatch --parsable --job-name={name} --output={r.logs}/{stamp}-{name}-%j.log "
                  f"{' '.join(r.sbatch)} --wrap {shlex.quote(bench)}")
    else:
        busy = "screen -ls | grep -q '[.]bench-'"
        launch = f"screen -dmS {name} bash -c {shlex.quote(f'{bench} > {r.logs}/{stamp}-{name}.log 2>&1')}"
    ssh(host, f"if {busy}; then echo 'a bench.py job is still queued or running'; exit 1; fi; "
              f"mkdir -p {r.logs} && cd {repo_on(r)} && {launch} && echo 'started {name}, logs in {r.logs}'",
        check=True)


def status(host, r):
    jobs = ("squeue --me --noheader --format='%.10i %.45j %.9T %.10M %.10l %R' | grep 'bench-'" if r.sbatch
            else "screen -ls | grep '[.]bench-'")
    newest = f"f=$(ls -t {r.logs}/*.log 2>/dev/null | head -n 1)"
    ssh(host, f"{jobs} || echo 'no bench.py job running'; {newest}; "
              "if [ -n \"$f\" ]; then echo \"== $f\"; tail -n 20 \"$f\"; fi")


def fetch(host, r):
    """The machine's runs into results-legacy/ (run folders have unique names, so nothing is overwritten); the job
    logs (configure and build output) and the animations (bench.py animate: VTK files, for bench.py render) into
    00_private_data/legacy/<machine>/."""
    RESULTS.mkdir(exist_ok=True)
    subprocess.run(["rsync", "-az", f"{host}:{repo_on(r)}/{RESULTS.name}/", f"{RESULTS}/"], check=True)
    logs = REPO / "00_private_data" / "legacy" / host
    logs.mkdir(parents=True, exist_ok=True)
    subprocess.run(["rsync", "-az", f"{host}:{r.logs}", f"{logs}/"], check=True)
    subprocess.run(["rsync", "-az", "--ignore-missing-args", f"{host}:{MACHINES[host].work}/animations", f"{logs}/"],
                   check=True)
    print(f"-> {RESULTS}, {logs}")


def main():
    args = sys.argv[1:]
    host = "bananapi"
    if args[:1] == ["--machine"] and len(args) >= 2:
        host, args = args[1], args[2:]
    if host not in REMOTES or not args or args[0] not in ("push", "start", "status", "fetch") or (
            args[0] == "start" and len(args) < 2):
        sys.exit(__doc__)
    command, rest, r = args[0], args[1:], REMOTES[host]
    if command == "start":
        start(host, r, rest)
    else:
        {"push": push, "status": status, "fetch": fetch}[command](host, r)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""The laptop side of bench.py, for the Banana Pi (README.md).

    python3 scripts-legacy/remote.py push                     the whole git repository to the board
    python3 scripts-legacy/remote.py start <bench.py args>    e.g. start all wind: detached in screen, one at a time
    python3 scripts-legacy/remote.py status                   the running session and the end of the newest log
    python3 scripts-legacy/remote.py fetch                    the board's runs into results-legacy/

monte3 is not set up here: ask the user before anything runs there (docs/notes8, step 8).
"""
from __future__ import annotations

import shlex
import subprocess
import sys
import time

sys.dont_write_bytecode = True  # no __pycache__ next to the scripts
from bench import REPO, RESULTS
from experiments import MACHINES

HOST = "bananapi"
REMOTE_ROOT = "/home/bananapi/saleh/my-e4-ws-legacy"   # the git repository; my-e4-ws next to it is the 2.x copy
REMOTE_REPO = f"{REMOTE_ROOT}/{REPO.relative_to(REPO.parent).as_posix()}"
LOGS = f"{MACHINES[HOST].work}/screen-logs"


def ssh(command, **kwargs):
    return subprocess.run(["ssh", HOST, command], text=True, **kwargs)


def push():
    subprocess.run(["bash", str(REPO / "push.to.sh"), HOST, "--repo", REMOTE_ROOT.rsplit("/", 1)[1]], check=True)


def start(bench_args):
    # The K1 has no working RTC and its NTP did not sync once: with a lagging clock HTTPS fails (pip, pybind11),
    # make rebuilds everything (the pushed files lie in the future) and the run times are wrong.
    skew = int(ssh("date +%s", capture_output=True, check=True).stdout) - time.time()
    if abs(skew) > 120:
        sys.exit(f"the board's clock is off by {skew / 3600:+.1f} h: set it first, e.g. "
                 f"ssh -t {HOST} \"sudo date -u -s '$(date -u '+%F %T')'\"")
    name ="bench-" + "-".join(bench_args).replace("/", "_")[:40]
    log = f"{LOGS}/{time.strftime('%Y%m%d-%H%M%S')}-{name}.log"
    bench = "python3 scripts-legacy/bench.py " + " ".join(map(shlex.quote, bench_args)) + f" > {log} 2>&1"
    ssh(f"if screen -ls | grep -q '[.]bench-'; then echo 'a bench.py session is still running'; exit 1; fi; "
        f"mkdir -p {LOGS} && cd {REMOTE_REPO} && screen -dmS {name} bash -c {shlex.quote(bench)} "
        f"&& echo 'started {name}, log {log}'", check=True)


def status():
    ssh(f"screen -ls | grep '[.]bench-' || echo 'no bench.py session running'; "
        f"f=$(ls -t {LOGS}/*.log 2>/dev/null | head -n 1); if [ -n \"$f\" ]; then echo \"== $f\"; tail -n 20 \"$f\"; fi")


def fetch():
    """The board's runs into results-legacy/ (run folders have unique names, so nothing is overwritten); the
    screen logs (configure and build output) into 00_private_data/legacy/bananapi/."""
    RESULTS.mkdir(exist_ok=True)
    subprocess.run(["rsync", "-az", f"{HOST}:{REMOTE_REPO}/{RESULTS.name}/", f"{RESULTS}/"], check=True)
    logs = REPO / "00_private_data" / "legacy" / HOST
    logs.mkdir(parents=True, exist_ok=True)
    subprocess.run(["rsync", "-az", f"{HOST}:{LOGS}", f"{logs}/"], check=True)
    print(f"-> {RESULTS}, {logs}")


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("push", "start", "status", "fetch") or (
            sys.argv[1] == "start" and len(sys.argv) < 3):
        sys.exit(__doc__)
    command, args = sys.argv[1], sys.argv[2:]
    if command == "start":
        start(args)
    else:
        {"push": push, "status": status, "fetch": fetch}[command]()


if __name__ == "__main__":
    main()

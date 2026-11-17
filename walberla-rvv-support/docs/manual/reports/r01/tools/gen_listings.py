#!/usr/bin/env python3
"""Regenerate the manual's captured listings in ``generated/``.

For every ``examples/exNN_*.py`` this script

1. extracts the marked source regions (``# [name]`` ... ``# [/name]``) into
   ``generated/<example>.<name>.py`` -- these are the code snippets shown in the text;
2. runs the example in a fresh interpreter with ``MANUAL_OUT=generated/`` so that it
   writes its artifacts (generated C code, IR, printed values) next to the snippets.

Each example asserts its own results (mostly against NumPy), so a successful run also
means that every kernel shown in the manual compiled and computed the right thing.

Usage (normally via ``./build.sh listings``)::

    PYTHONPATH=<repo>/submodules/pystencils/src python -B tools/gen_listings.py [exNN ...]

The JIT cache is redirected to a temporary directory (``XDG_CACHE_HOME``), so nothing is
written to ``~/.cache``.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path

HERE = Path(__file__).resolve().parent
MANUAL = HERE.parent
EXAMPLES = MANUAL / "examples"
OUT = MANUAL / "generated"

_BEGIN = re.compile(r"^\s*# \[([A-Za-z0-9_-]+)\]\s*$")
_END = re.compile(r"^\s*# \[/([A-Za-z0-9_-]+)\]\s*$")


def extract_regions(src: Path) -> dict[str, str]:
    """Return {region name: dedented source} for all marked regions of a file."""
    regions: dict[str, list[str]] = {}
    open_regions: list[str] = []
    for lineno, line in enumerate(src.read_text().splitlines(), start=1):
        if m := _BEGIN.match(line):
            name = m.group(1)
            if name in regions:
                raise SystemExit(f"{src.name}:{lineno}: region {name!r} defined twice")
            regions[name] = []
            open_regions.append(name)
            continue
        if m := _END.match(line):
            name = m.group(1)
            if not open_regions or open_regions[-1] != name:
                raise SystemExit(f"{src.name}:{lineno}: unbalanced end of region {name!r}")
            open_regions.pop()
            continue
        for name in open_regions:
            regions[name].append(line)
    if open_regions:
        raise SystemExit(f"{src.name}: unterminated region(s) {open_regions}")
    return {k: textwrap.dedent("\n".join(v)).strip("\n") + "\n" for k, v in regions.items()}


def run_example(src: Path, cache_dir: str) -> None:
    env = dict(os.environ)
    env["MANUAL_OUT"] = str(OUT)
    env["MANUAL_PREFIX"] = src.stem
    env["XDG_CACHE_HOME"] = cache_dir
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env["PYTHONWARNINGS"] = "ignore"
    res = subprocess.run(
        [sys.executable, "-B", src.name],
        cwd=EXAMPLES,
        env=env,
        capture_output=True,
        text=True,
    )
    if res.returncode != 0:
        sys.stderr.write(res.stdout + res.stderr)
        raise SystemExit(f"example {src.name} failed (exit code {res.returncode})")


def main(argv: list[str]) -> int:
    selected = argv[1:]
    examples = sorted(EXAMPLES.glob("ex[0-9][0-9]_*.py"))
    if selected:
        examples = [e for e in examples if any(e.stem.startswith(s) for s in selected)]
    if not examples:
        raise SystemExit("no examples selected")

    OUT.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ps-manual-cache-") as cache_dir:
        for ex in examples:
            #   Remove stale artifacts of this example first.
            for old in OUT.glob(f"{ex.stem}.*"):
                old.unlink()
            for name, code in extract_regions(ex).items():
                (OUT / f"{ex.stem}.{name}.py").write_text(code)
            print(f"[gen] {ex.name} ...", flush=True)
            run_example(ex, cache_dir)

    n = len(list(OUT.iterdir()))
    print(f"[gen] done: {len(examples)} example(s), {n} file(s) in {OUT.relative_to(MANUAL)}/")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

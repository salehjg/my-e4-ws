"""Capture helper for the manual's example scripts.

This module is *not* part of the material shown in the manual. The example scripts
use it to hand their artifacts (generated code, IR dumps, printed values) to the
listing generator ``tools/gen_listings.py``:

* When the environment variable ``MANUAL_OUT`` is set (the generator does this), every
  artifact is written to ``$MANUAL_OUT/<example>.<name>.<ext>``.
* Otherwise the artifacts are printed to stdout, so every example can also be run by
  hand, e.g. ``PYTHONPATH=<pystencils>/src python examples/ex01_first_kernel.py``.

C/C++ code is passed through ``clang-format`` (if available) so that the very long lines
pystencils emits fit on a printed page; only whitespace and line breaks change.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

_OUT = os.environ.get("MANUAL_OUT")
_PREFIX = os.environ.get("MANUAL_PREFIX") or Path(sys.argv[0]).stem

#   Close to the style pystencils prints itself (3-space indent), but wrapped at 84 columns.
CLANG_FORMAT_STYLE = (
    "{BasedOnStyle: LLVM, IndentWidth: 3, ColumnLimit: 84, "
    "PointerAlignment: Left, AllowShortBlocksOnASingleLine: Never, "
    "AllowShortLoopsOnASingleLine: false, BreakBeforeBraces: Allman, "
    "SortIncludes: Never}"
)


def format_c(code: str) -> str:
    """Re-indent C/C++ code with clang-format (identity if clang-format is missing)."""
    exe = shutil.which("clang-format")
    if exe is None:
        return code
    res = subprocess.run(
        [exe, f"--style={CLANG_FORMAT_STYLE}", "--assume-filename=kernel.cpp"],
        input=code,
        capture_output=True,
        text=True,
        check=True,
    )
    return res.stdout


def save(name: str, text, ext: str = "txt") -> None:
    """Store one artifact (plain text)."""
    text = str(text).rstrip() + "\n"
    if _OUT:
        path = Path(_OUT) / f"{_PREFIX}.{name}.{ext}"
        path.write_text(text)
    else:
        print(f"===== {_PREFIX}.{name}.{ext} =====")
        print(text)


def save_c(name: str, code: str) -> None:
    """Store generated C/C++ code (reformatted for the page width)."""
    save(name, format_c(code), "c")


def save_params(name: str, kernel) -> None:
    """Store a table of a kernel's parameters: name, type, properties."""
    def short(prop) -> str:
        #   e.g. FieldShape(field=dst: float64[2d], coordinate=0) -> FieldShape(dst, 0)
        fld = getattr(prop, "field", None)
        if fld is None:
            return str(prop)
        coord = getattr(prop, "coordinate", None)
        args = fld.name if coord is None else f"{fld.name}, {coord}"
        return f"{type(prop).__name__}({args})"

    lines = []
    for p in kernel.parameters:
        props = ", ".join(sorted(short(prop) for prop in p.properties)) or "-"
        lines.append(f"{p.name:<15} {str(p.dtype):<24} {props}")
    save(name, "\n".join(lines))


def section(title: str) -> None:
    """Visual separator when running an example by hand."""
    if not _OUT:
        print(f"\n### {title}")

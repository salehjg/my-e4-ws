"""Instruction histogram of the hot vector loops in kernel binaries.

A hot loop is an innermost loop (a backward branch with no other backward branch inside)
that contains a vector FP divide: the vectorized cell loop of the BGK kernel. A binary can
have several. Clang, for example, also auto-vectorizes the scalar remainder loop of our
RVV kernel, at LMUL 2.

Why loops and not whole objects: an object also contains remainder loops and setup code
that never runs at the benchmarked sizes. Counting whole objects was misleading.

Uses llvm-objdump, because GNU objdump 2.42 cannot decode Clang's RVV code. Run it on
*linked* binaries: in .o files Clang's branch targets are still unresolved relocations.

Usage: python hotloop.py BINARY...
"""

import collections
import re
import subprocess
import sys

FMA = re.compile(r"^vf(w)?n?m(acc|add|sub|sac)\.")          # vfmadd, vfnmsub, vfmacc, ...
WHOLE_REG = re.compile(r"^v[sl][1248]r(e\d+)?\.v$")         # vs1r.v / vl1re64.v / vl2r.v ...


def loops(binary):
    out = subprocess.run(
        ["llvm-objdump", "-d", "--no-show-raw-insn", "--mattr=+v", binary],
        capture_output=True, text=True, check=True,
    ).stdout
    ins = [
        (int(m[1], 16), m[2])
        for m in (re.match(r"\s*([0-9a-f]+):\s+(\S+)\s*(.*)", line) for line in out.splitlines())
        if m
    ]
    #   (target, branch address) of every backward branch
    back = []
    for line in out.splitlines():
        m = re.match(r"\s*([0-9a-f]+):\s+(b\S*|j)\s.*?0x([0-9a-f]+)", line)
        if m and int(m[3], 16) < int(m[1], 16):
            back.append((int(m[3], 16), int(m[1], 16)))
    for start, end in back:
        if any(start <= b < end for _, b in back if b != end):
            continue   # not innermost
        body = [mn for a, mn in ins if start <= a <= end]
        if any(mn.startswith(("vfdiv", "vfrdiv")) for mn in body):
            yield body


def describe(body):
    h = collections.Counter(body)
    n = lambda pred: sum(c for mn, c in h.items() if pred(mn))   # noqa: E731
    return (
        f"{len(body)} insns | FP: mul {n(lambda m: m.startswith('vfmul'))}, "
        f"add {n(lambda m: m.startswith('vfadd'))}, sub {n(lambda m: m.startswith(('vfsub', 'vfrsub')))}, "
        f"fma {n(FMA.match)}, div {n(lambda m: 'div' in m and m.startswith('v'))} | "
        f"vle/vse {n(lambda m: re.match(r'^vl(s)?e\d+\.v$', m))}/{n(lambda m: re.match(r'^vs(s)?e\d+\.v$', m))}, "
        f"whole-reg ld/st {n(WHOLE_REG.match)}, vsetvl {n(lambda m: m.startswith('vset'))}, "
        f"LMUL2 ops {'yes' if any('2r' in m or '2re' in m for m in body) else 'no'}"
    )


for binary in sys.argv[1:]:
    name = binary.rsplit("/", 1)[-1]
    found = list(loops(binary))
    if not found:
        print(f"{name}: no vector loop with a divide")
    for body in found:
        print(f"{name}: {describe(body)}")

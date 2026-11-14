"""Source-level edits of a generated kernel (lever experiments of docs/notes3, Phase 4).

Each edit takes the generated C code and returns (new code, stats). They are deliberately
textual: the point is to measure a lever before deciding where it belongs in the stack.
"""


def apply(name: str, code: str, *, target: str, ctype: str):
    fn = EDITS.get(name.split("=")[0])
    if fn is None:
        raise ValueError(f"unknown edit {name!r}; known: {sorted(EDITS)}")
    arg = name.split("=", 1)[1] if "=" in name else None
    return fn(code, target=target, ctype=ctype, arg=arg)


EDITS = {}

import re

_ACCESS = re.compile(r"_data_(f_tmp|f|rho|u)\[([^\]]*)\]")


def _inner_loop(code: str, target: str):
    """(start, end) of the innermost cell loop's body (between its braces)."""
    pat = r"for\(int64_t ctr_0__1 = 0LL;[^\n]*\n\s*\{" if target == "rvv" else r"for\(int64_t ctr_0 = 0LL;[^\n]*\n\s*\{"
    m = re.search(pat, code)
    if not m:
        raise ValueError("inner loop not found")
    depth, i = 1, m.end()
    while depth:
        depth += {"{": 1, "}": -1}.get(code[i], 0)
        i += 1
    return m.end(), i - 1


def _prefetch(code, *, target, ctype, arg):
    """Software prefetch of every distinct field access of the cell loop, `arg` bytes ahead.

    Reads (f) get prefetch.r, writes (f_tmp, rho, u) prefetch.w (`__builtin_prefetch` with
    -march=..._zicbop). The vector loop prefetches every iteration (8 or 4 cells); the scalar
    loop every 16th cell. arg may be 'D' (bytes) or 'D:r' / 'D:w' (only reads / only writes).
    """
    dist, _, only = (arg or "256").partition(":")
    elems = int(dist) // (4 if ctype == "float" else 8)
    s, e = _inner_loop(code, target)
    body = code[s:e]
    seen = []
    for m in _ACCESS.finditer(body):
        key = (m[1], re.sub(r"\s+", "", m[2]))
        if key not in seen:
            seen.append(key)
    lines = []
    for fld, idx in seen:
        rw = 0 if fld == "f" else 1
        if (only == "r" and rw) or (only == "w" and not rw):
            continue
        lines.append(f"__builtin_prefetch(&_data_{fld}[{idx} + {elems}LL], {rw}, 3);")
    block = " ".join(lines)
    if target != "rvv":
        block = f"if ((ctr_0 & 15LL) == 0) {{ {block} }}"
    else:   # after `const int64_t ctr_0 = ctr_0__1;`
        s = code.index("\n", code.index("const int64_t ctr_0 = ctr_0__1;", s)) + 1
    code = code[:s] + "\n" + block + "\n" + code[s:]
    return code, {"prefetches": len(lines), "elems_ahead": elems}


def _no_macro_out(code, *, target, ctype, arg):
    """Drop the density/velocity stores (NOT a valid kernel: measures 4 fewer write streams)."""
    s, e = _inner_loop(code, target)
    body = code[s:e]
    n0 = len(body)
    if target == "rvv":
        body = re.sub(r"__riscv_vse(32|64)_v_f(32|64)m1\(&_data_(rho|u)\[[^\]]*\],[^;]*;", "", body)
    else:
        body = re.sub(r"_data_(rho|u)\[[^\]]*\] = [^;]*;", "", body)
    return code[:s] + body + code[e:], {"removed_chars": n0 - len(body)}


EDITS.update({"pf": _prefetch, "nomacro": _no_macro_out})

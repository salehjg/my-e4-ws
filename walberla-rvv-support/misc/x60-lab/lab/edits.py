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


#  Row pointers of pystencils' HoistRowPointers (Loop 12): `_data_rho_row`, `_data_u_row__1`, ...
_ROW = r"(?:_row(?:__\d+)?)?"


def _no_macro_out(code, *, target, ctype, arg):
    """Drop the density/velocity stores and their prefetch hints from the inner loop.

    Models a sweep without the macroscopic outputs (plan lever C6: 4 fewer write streams). Not a
    complete kernel by itself: rho/u are not written, so the driver's energy/mass come out 0.
    """
    s, e = _inner_loop(code, target)
    body = code[s:e]
    n0 = len(body)
    body, npf = re.subn(rf"pystencils::runtime::\w+::prefetch_(write|read)\(&_data_(rho|u){_ROW}\[[^\]]*\]\);", "", body)
    if target == "rvv":
        body, nst = re.subn(rf"__riscv_vse(32|64)_v_f(32|64)m1\(&_data_(rho|u){_ROW}\[[^\]]*\],[^;]*;", "", body)
    else:
        body, nst = re.subn(rf"_data_(rho|u){_ROW}\[[^\]]*\] = [^;]*;", "", body)
    return code[:s] + body + code[e:], {"removed_chars": n0 - len(body), "stores": nst, "prefetches": npf}


EDITS.update({"pf": _prefetch, "nomacro": _no_macro_out})

_ROW_ACCESS = re.compile(r"(&?)_data_(\w+)\[ctr_0 \+ ([^\]]*)\]")


def _row_pointers(code, *, target, ctype, arg):
    """Hoist one row base pointer per distinct access out of the vector x-loop (Loop 12).

    `_data_X[ctr_0 + REST]` becomes `_rp_k[ctr_0]` with `auto * const _rp_k = _data_X + (REST);`
    declared before the loop. GCC otherwise bases the induction variable of an access with a
    +-1 x offset on x itself and needs an `addi` per access (RVV loads/stores have no immediate
    offset; prefetch immediates must be multiples of 32), and spills the extra addresses.
    """
    m = re.search(r"\n(\s*)for\(int64_t ctr_0__1 = 0LL;", code)
    if not m or target != "rvv":
        raise ValueError("rp: vector inner loop not found")
    s, e = _inner_loop(code, target)
    keys = {}

    def rep(a):
        amp, fld, rest = a.groups()
        k = keys.setdefault((fld, rest), len(keys))
        return f"{amp}_rp_{k}[ctr_0]"

    body = _ROW_ACCESS.sub(rep, code[s:e])
    decls = "".join(f"\n{m[1]}auto * const _rp_{k} = _data_{fld} + ({rest});" for (fld, rest), k in keys.items())
    code = code[: m.start()] + decls + code[m.start() : s] + body + code[e:]
    return code, {"row_pointers": len(keys)}


def _opaque_constants(code, *, target, ctype, arg):
    """Make the scalar constants opaque (`asm("" : "+f"(c))` after the declaration, Loop 12).

    GCC otherwise rematerializes every scalar operand of a .vf instruction from the constant
    pool inside the loop (`lla` + `flw` per use) instead of keeping it in one of the 32 idle
    FP registers.
    """
    pat = re.compile(r"^( +)const (float|double) (__c\w*) = ([^;]*);", re.M)
    code, n = pat.subn(lambda a: f'{a[1]}{a[2]} {a[3]} = {a[4]}; __asm__("" : "+f"({a[3]}));', code)
    return code, {"opaque_constants": n}


EDITS.update({"rp": _row_pointers, "opq": _opaque_constants})

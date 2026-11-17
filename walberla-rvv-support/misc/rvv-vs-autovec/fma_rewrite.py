"""Hand-check rewrite of generated RVV code: fold negations and fuse multiply-adds.

The question it answers: how much do the missing FMAs (finding #2 in README.md) cost?
pystencils emits `a*b + c` as `vfadd(vfmul(a, b), c)` and `-x` as `vfmul(splat(-1.0), x)`,
and neither GCC nor Clang fuses or folds RVV intrinsic calls. This rewrites the emitted
source the way an FMA/negation step in the backend would, so we can measure the effect
before implementing anything in pystencils.

It parses every `__riscv_*(...)` call tree in the source, rewrites bottom-up and prints
it back. Arguments that are not intrinsic calls (pointers, symbols, `4uLL`) are kept as
opaque text. Only inline products are fused: a product that CSE turned into a declared
variable is shared, so it is left alone.

Modes:
  neg  x * splat(-1.0) -> vfneg(x);  x + vfneg(y) -> x - y;  x - vfneg(y) -> x + y
  fma  neg, plus  a*b + c -> vfmacc(c, a, b),  c - a*b -> vfnmsac(c, a, b),
       a*b - c -> vfmsac(c, a, b)      (with -a in a product absorbed into the sign)
  vf   only this: an operand that is a splat of a scalar is passed as the scalar,
       x OP splat(c) -> vfOP_vf(x, c), splat(c) OP x -> vfOP_vf / vfrsub_vf / vfrdiv_vf(x, c).
       Constants then live in scalar FP registers instead of occupying vector registers
       (what autovec does). This is the old fable branch's "broadcast folding" (D14).
"""

import collections
import re

_CALL = re.compile(r"__riscv_\w+")


#   ---- parsing: node = (name, [args]); a leaf arg is its source text

def _parse_call(s, i):
    m = _CALL.match(s, i)
    j = m.end()
    assert s[j] == "(", s[i:j + 20]
    j += 1
    args = []
    while True:
        arg, j = _parse_arg(s, j)
        args.append(arg)
        if s[j] == ",":
            j += 1
            continue
        assert s[j] == ")", s[i:j + 20]
        return (m.group(), args), j + 1


def _parse_arg(s, i):
    while s[i] == " ":
        i += 1
    if _CALL.match(s, i):
        node, j = _parse_call(s, i)
    else:
        depth, j = 0, i
        while True:
            c = s[j]
            if c in "([":
                depth += 1
            elif c in ")]":
                if depth == 0:
                    break
                depth -= 1
            elif c == "," and depth == 0:
                break
            j += 1
        node = s[i:j].strip()
    while s[j] == " ":
        j += 1
    return node, j


def _print(node):
    if isinstance(node, str):
        return node
    name, args = node
    return f"{name}(" + ", ".join(_print(a) for a in args) + ")"


#   ---- rewriting

def _op(node, op):
    """Suffix (e.g. 'f64m1') if `node` is the vector-vector intrinsic `op`, else None."""
    if isinstance(node, tuple):
        m = re.fullmatch(rf"__riscv_{op}_(?:vv|v)_(\w+)", node[0])
        if m:
            return m[1]
    return None


def _is_minus_one(node):
    return isinstance(node, tuple) and re.fullmatch(r"__riscv_vfmv_v_f_\w+", node[0]) \
        and node[1][0].replace(" ", "") in ("-1.0", "-1.0f", "-1")


def _splat_value(node):
    """The scalar expression if `node` is `__riscv_vfmv_v_f_*(value, vl)`, else None."""
    if isinstance(node, tuple) and re.fullmatch(r"__riscv_vfmv_v_f_\w+", node[0]):
        return node[1][0]
    return None


#   splat(c) OP x  ->  rOP(x, c): the reversed .vf form keeps the operand order
_REVERSED_VF = {"vfadd": "vfadd", "vfmul": "vfmul", "vfsub": "vfrsub", "vfdiv": "vfrdiv"}


def _fold_splat(node, stats):
    m = re.fullmatch(r"__riscv_(vfadd|vfsub|vfmul|vfdiv)_vv_(\w+)", node[0])
    if not m:
        return node
    op, sfx = m[1], m[2]
    a, b, vl = node[1]
    if (c := _splat_value(b)) is not None:          # x OP c
        stats["vf"] += 1
        return (f"__riscv_{op}_vf_{sfx}", [a, c, vl])
    if (c := _splat_value(a)) is not None:          # c OP x
        stats["vf"] += 1
        return (f"__riscv_{_REVERSED_VF[op]}_vf_{sfx}", [b, c, vl])
    return node


def _rewrite(node, mode, stats):
    if isinstance(node, str):
        return node
    name, args = node
    args = [_rewrite(a, mode, stats) for a in args]
    node = (name, args)
    vl = args[-1]

    if mode == "vf":
        return _fold_splat(node, stats)

    #   x * splat(-1.0) -> vfneg(x)
    if (sfx := _op(node, "vfmul")) and (_is_minus_one(args[0]) or _is_minus_one(args[1])):
        x = args[1] if _is_minus_one(args[0]) else args[0]
        stats["neg"] += 1
        return (f"__riscv_vfneg_v_{sfx}", [x, vl])
    #   x + vfneg(y) -> x - y ;  x - vfneg(y) -> x + y
    for op, flipped in (("vfadd", "vfsub"), ("vfsub", "vfadd")):
        if sfx := _op(node, op):
            a, b = args[0], args[1]
            if op == "vfadd" and _op(a, "vfneg") and not _op(b, "vfneg"):
                a, b = b, a
            if _op(b, "vfneg"):
                stats["neg-fold"] += 1
                return _rewrite((f"__riscv_{flipped}_vv_{sfx}", [a, b[1][0], vl]), mode, stats)

    if mode != "fma":
        return node

    def product(x):
        """(sign, a, b) if x is an inline product (possibly with a negated factor), else None."""
        if _op(x, "vfmul"):
            a, b = x[1][0], x[1][1]
            if _op(a, "vfneg"):
                return -1, a[1][0], b
            if _op(b, "vfneg"):
                return -1, a, b[1][0]
            return 1, a, b
        return None

    if sfx := _op(node, "vfadd"):
        for p, c in ((args[0], args[1]), (args[1], args[0])):
            if pr := product(p):
                sign, a, b = pr
                stats["fma"] += 1
                return (f"__riscv_{'vfmacc' if sign > 0 else 'vfnmsac'}_vv_{sfx}", [c, a, b, vl])
    if sfx := _op(node, "vfsub"):
        if pr := product(args[1]):          # c - a*b
            sign, a, b = pr
            stats["fma"] += 1
            return (f"__riscv_{'vfnmsac' if sign > 0 else 'vfmacc'}_vv_{sfx}", [args[0], a, b, vl])
        if pr := product(args[0]):          # a*b - c
            sign, a, b = pr
            if sign > 0:
                stats["fma"] += 1
                return (f"__riscv_vfmsac_vv_{sfx}", [args[1], a, b, vl])
    return node


def rewrite(code: str, mode: str):
    """Return (rewritten code, counts per rule)."""
    assert mode in ("neg", "fma", "vf")
    stats = collections.Counter()
    out, i = [], 0
    while (m := _CALL.search(code, i)) is not None:
        out.append(code[i:m.start()])
        node, i = _parse_call(code, m.start())
        out.append(_print(_rewrite(node, mode, stats)))
    out.append(code[i:])
    return "".join(out), stats

"""Chapter 3: assignments, assignment collections, symbols and types."""

from _manual import save, save_c, save_params

import numpy as np
import sympy as sp
import pystencils as ps

# [collection]
u, u_new = ps.fields("u, u_new: double[2D]")
alpha = sp.Symbol("alpha")                      # untyped: becomes a kernel parameter
lap = sp.Symbol("lap")                          # bound by a subexpression

ac = ps.AssignmentCollection(
    main_assignments=[ps.Assignment(u_new.center, u.center + alpha * lap)],
    subexpressions=[
        ps.Assignment(lap, u[1, 0] + u[-1, 0] + u[0, 1] + u[0, -1] - 4 * u.center)
    ],
)
heat = ps.create_kernel(ac)
# [/collection]
save("collection-ac", ac)
save_c("collection-code", heat.get_c_code())
save_params("collection-params", heat)

# [collection-run]
step = heat.compile()
u_arr = np.random.default_rng(0).random((32, 32))
u_new_arr = np.zeros_like(u_arr)
step(u=u_arr, u_new=u_new_arr, alpha=0.1)   # scalar parameters are keywords too
# [/collection-run]
ref = u_arr[1:-1, 1:-1] + 0.1 * (
    u_arr[2:, 1:-1] + u_arr[:-2, 1:-1] + u_arr[1:-1, 2:] + u_arr[1:-1, :-2]
    - 4 * u_arr[1:-1, 1:-1])
assert np.allclose(u_new_arr[1:-1, 1:-1], ref)

# [types]
x = ps.fields("x: float32[1D]")
i = ps.fields("i: int64[1D]")
scale = ps.TypedSymbol("scale", "float32")      # explicitly typed symbol

asms = [
    ps.Assignment(x.center, scale * x.center),
    ps.Assignment(i.center, ps.tcast(x.center, "int64")),  # explicit cast
]
typed = ps.create_kernel(asms)
# [/types]
save_c("types-code", typed.get_c_code())

# [piecewise]
f, g = ps.fields("f, g: double[2D]")
x0 = ps.DEFAULTS.spatial_counters[0]           # cell index ctr_0 (an int64 symbol)
clipped = sp.Piecewise(
    (0.0, f.center < 0.0),
    (1.0, f.center > 1.0),
    (f.center, True),                           # a default branch is mandatory
)
pw = ps.create_kernel([ps.Assignment(g.center, clipped + ps.tcast(x0, "double"))])
# [/piecewise]
save_c("piecewise-code", pw.get_c_code())

# [decorator]
@ps.kernel
def smooth(s):                  # optional argument s: a SymbolCreator
    s.avg @= (f[1, 0] + f[-1, 0]) / 2   # plain symbol -> subexpression
    g[0, 0] @= s.avg * s.weight         # s.weight is free -> kernel parameter

dec = ps.create_kernel(smooth)
# [/decorator]
save("decorator-asms", smooth)
save_c("decorator-code", dec.get_c_code())

# [cse]
p = ps.fields("p(4): double[2D]")
q = ps.fields("q(4): double[2D]")
rho = sum(p(k) for k in range(4))
rules = ps.AssignmentCollection(
    [ps.Assignment(q(k), p(k) / rho + (p(k) - rho) ** 2) for k in range(4)]
)
before = rules.operation_count
rules_cse = ps.simp.sympy_cse(rules)
after = rules_cse.operation_count
# [/cse]
save("cse-ac", rules_cse)
def fmt(c):
    return f"adds={c['adds']:>2}  muls={c['muls']:>2}  divs={c['divs']:>2}"


save("cse-counts", f"before CSE: {fmt(before)}\nafter CSE:  {fmt(after)}")

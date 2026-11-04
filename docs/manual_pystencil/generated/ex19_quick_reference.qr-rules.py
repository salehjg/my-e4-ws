rule = ps.Assignment(g.center, (f[1, 0] + f[-1, 0]) / 2)
t = sp.Symbol("t")                                     # untyped: default_dtype
w = ps.TypedSymbol("w", "float64")                     # explicitly typed
ac = ps.AssignmentCollection(
    main_assignments=[ps.Assignment(g.center, w * t)],
    subexpressions=[ps.Assignment(t, f[1, 0] - f[-1, 0])],
)
ac = ps.simp.sympy_cse(ac)                             # common subexpressions
cast = ps.tcast(ps.x_, "float64")                      # explicit cast of the x counter
total = ps.TypedSymbol("total", "float64")
red = ps.AddReductionAssignment(total, f.center)       # also Mul/Min/Max/Sub

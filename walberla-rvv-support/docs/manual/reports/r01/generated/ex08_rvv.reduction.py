x = ps.fields("x: float64[1D]")
w = ps.TypedSymbol("w", "float64")
cfg64 = cfg.copy()
cfg64.default_dtype = "float64"
rvv_sum = ps.create_kernel(ps.AddReductionAssignment(w, x.center), cfg64)

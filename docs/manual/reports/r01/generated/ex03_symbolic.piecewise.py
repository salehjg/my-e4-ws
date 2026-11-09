f, g = ps.fields("f, g: double[2D]")
x0 = ps.DEFAULTS.spatial_counters[0]           # cell index ctr_0 (an int64 symbol)
clipped = sp.Piecewise(
    (0.0, f.center < 0.0),
    (1.0, f.center > 1.0),
    (f.center, True),                           # a default branch is mandatory
)
pw = ps.create_kernel([ps.Assignment(g.center, clipped + ps.tcast(x0, "double"))])

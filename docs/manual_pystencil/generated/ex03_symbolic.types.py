x = ps.fields("x: float32[1D]")
i = ps.fields("i: int64[1D]")
scale = ps.TypedSymbol("scale", "float32")      # explicitly typed symbol

asms = [
    ps.Assignment(x.center, scale * x.center),
    ps.Assignment(i.center, ps.tcast(x.center, "int64")),  # explicit cast
]
typed = ps.create_kernel(asms)

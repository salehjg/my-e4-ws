x = ps.fields("x: double[1D]")
total = ps.TypedSymbol("total", "double")
peak = ps.TypedSymbol("peak", "double")

asms = [
    ps.AddReductionAssignment(total, x.center),
    ps.MaxReductionAssignment(peak, x.center),
]

cfg = ps.CreateKernelConfig()
cfg.cpu.openmp.enable = True
red = ps.create_kernel(asms, cfg)

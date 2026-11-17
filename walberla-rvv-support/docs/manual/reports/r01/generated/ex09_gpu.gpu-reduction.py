x = ps.fields("x: double[1D]")
total = ps.TypedSymbol("total", "double")
c = cfg.copy()
c.gpu.assume_warp_aligned_block_size = True       # together with an explicit
c.gpu.warp_size = 32                              # warp size: warp-level shuffles
gpu_red = ps.create_kernel(ps.AddReductionAssignment(total, x.center), c)

s = ps.fields("s: float64[2D]", layout="c")      # vectorize along a strided axis
cfg_strided = ps.CreateKernelConfig(target=ps.Target.RISCV_RVV)
cfg_strided.cpu.vectorize.enable = True          # no assume_inner_stride_one here
strided = ps.create_kernel(ps.Assignment(s.center, 3 * s.center), cfg_strided)

cfg = ps.CreateKernelConfig(target=ps.Target.X86_AVX)
cfg.cpu.openmp.enable = True
cfg.cpu.vectorize.enable = True
cfg.cpu.vectorize.assume_inner_stride_one = True   # contiguous fastest coordinate

avx = ps.create_kernel(update, cfg)

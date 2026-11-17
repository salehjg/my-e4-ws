scalar = ps.create_kernel(update)

cfg = ps.CreateKernelConfig(target=ps.Target.auto_cpu())
if cfg.target.is_vector_cpu():
    cfg.cpu.vectorize.enable = True
    cfg.cpu.vectorize.assume_inner_stride_one = True   # needs x-fastest arrays (fzyx)
simd = ps.create_kernel(update, cfg)

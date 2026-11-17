cfg = ps.CreateKernelConfig(target=ps.Target.RISCV_RVV, default_dtype="float32")
cfg.cpu.vectorize.enable = True
cfg.cpu.vectorize.assume_inner_stride_one = True
cfg.cpu.openmp.enable = True

src, dst = ps.fields("src, dst: float32[2D]")
update = ps.Assignment(dst.center, (src[1, 0] + src[-1, 0] + src[0, 1] + src[0, -1]) / 4)
rvv_jacobi = ps.create_kernel(update, cfg)
